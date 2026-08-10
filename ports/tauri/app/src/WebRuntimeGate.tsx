import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import {
  acquireControlTabLock,
  clearControlLeaseToken,
  controlLeaseHeaders,
  setControlLeaseToken,
  type HeldControlTabLock,
} from "./controlLease";
import { isTauriRuntime } from "./runtime";
import {
  notifyWebSessionReady,
  WEB_EVENT_STREAM_STATE_EVENT,
  type WebEventStreamState,
} from "./engine/client";
import { ScannerControlProvider } from "./scannerControl";
import styles from "./WebRuntimeGate.module.css";

type ControlState = "available" | "owned" | "observer";

interface WebSession {
  authenticated: boolean;
  control: ControlState;
}

interface WebRuntimeGateProps {
  children: ReactNode;
}

const CONTROL_TAB_UNVERIFIED_MESSAGE =
  "Scanner control could not be verified for this tab. Reclaim control in this tab.";

async function readSession(): Promise<WebSession> {
  const response = await fetch("/api/v1/session", {
    credentials: "same-origin",
    headers: controlLeaseHeaders(),
  });
  if (response.status === 401) return { authenticated: false, control: "available" };
  if (!response.ok) throw new Error(`Session check failed (${response.status}).`);
  const payload = (await response.json()) as Partial<WebSession>;
  const control =
    payload.control === "owned" || payload.control === "observer"
      ? payload.control
      : "available";
  return {
    authenticated: payload.authenticated === true,
    control,
  };
}

async function post(path: string, body?: unknown, includeLease = false): Promise<Response> {
  return fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      ...(includeLease ? controlLeaseHeaders() : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

export default function WebRuntimeGate({ children }: WebRuntimeGateProps) {
  const tauri = isTauriRuntime();
  const [session, setSession] = useState<WebSession | null>(null);
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [eventStream, setEventStream] = useState<WebEventStreamState>({
    ready: tauri,
    message: tauri ? null : "Connecting to the scanner event stream…",
  });
  const claimInFlight = useRef<Promise<void> | null>(null);
  const refreshGeneration = useRef(0);
  const controlTabLock = useRef<HeldControlTabLock | null>(null);

  const releaseLocalControl = useCallback((): void => {
    clearControlLeaseToken();
    controlTabLock.current?.release();
    controlTabLock.current = null;
  }, []);

  const commitSession = useCallback((next: WebSession): void => {
    if (next.authenticated && next.control === "owned" && controlTabLock.current === null) {
      releaseLocalControl();
      setSession({ ...next, control: "observer" });
      setError(CONTROL_TAB_UNVERIFIED_MESSAGE);
      return;
    }
    if (!next.authenticated || next.control !== "owned") releaseLocalControl();
    setSession(next);
  }, [releaseLocalControl]);

  const refresh = useCallback(async (): Promise<void> => {
    // A claim is the authoritative ownership transition. Starting a session
    // read while it is pending would supersede its generation and could leave
    // a successful server lease without the page retaining its token.
    if (claimInFlight.current !== null) return;
    const generation = ++refreshGeneration.current;
    setError(null);
    try {
      const next = await readSession();
      if (refreshGeneration.current === generation) {
        commitSession(next);
      }
    } catch (caught) {
      if (refreshGeneration.current === generation) {
        setError(caught instanceof Error ? caught.message : "The ScanStudio server is unavailable.");
      }
    }
  }, [commitSession]);

  const claimControl = useCallback((): Promise<void> => {
    if (claimInFlight.current !== null) return claimInFlight.current;
    const claim = (async (): Promise<void> => {
      const generation = ++refreshGeneration.current;
      setError(null);
      if (controlTabLock.current === null) {
        const localGuard = await acquireControlTabLock();
        if (refreshGeneration.current !== generation) {
          localGuard.release();
          return;
        }
        controlTabLock.current = localGuard;
      }
      let response: Response;
      try {
        response = await post("/api/v1/control/claim");
      } catch {
        releaseLocalControl();
        if (refreshGeneration.current === generation) {
          throw new Error("The scanner server could not be reached.");
        }
        return;
      }
      if (refreshGeneration.current !== generation) {
        releaseLocalControl();
        return;
      }
      if (response.status === 401) {
        releaseLocalControl();
        setSession({ authenticated: false, control: "available" });
        return;
      }
      if (response.status === 409 || response.status === 423) {
        releaseLocalControl();
        setSession((current) =>
          current === null ? current : { ...current, control: "observer" },
        );
        return;
      }
      if (!response.ok) {
        releaseLocalControl();
        throw new Error(`Control request failed (${response.status}).`);
      }
      let payload: { leaseToken?: unknown };
      try {
        payload = (await response.json()) as { leaseToken?: unknown };
      } catch {
        releaseLocalControl();
        throw new Error("The scanner server returned an unreadable control lease.");
      }
      if (typeof payload.leaseToken !== "string" || payload.leaseToken.length === 0) {
        releaseLocalControl();
        throw new Error("The scanner server did not return a control lease.");
      }
      setControlLeaseToken(payload.leaseToken);
      setError(null);
      setSession((current) =>
        current === null ? current : { ...current, control: "owned" },
      );
    })();
    claimInFlight.current = claim;
    const clearClaim = (): void => {
      if (claimInFlight.current === claim) claimInFlight.current = null;
    };
    void claim.then(clearClaim, clearClaim);
    return claim;
  }, [releaseLocalControl]);

  useEffect(() => {
    if (tauri) return;
    // A duplicated tab inherits sessionStorage. Clear that untrusted legacy
    // copy before the first session read. Active leases only live in this
    // page's module memory and are never restored from browser storage.
    releaseLocalControl();
    void refresh();
    return () => {
      refreshGeneration.current += 1;
      releaseLocalControl();
    };
  }, [refresh, releaseLocalControl, tauri]);

  useEffect(() => {
    if (tauri) return;
    const update = (event: Event): void => {
      const detail = (event as CustomEvent<WebEventStreamState>).detail;
      if (
        typeof detail === "object" &&
        detail !== null &&
        typeof detail.ready === "boolean"
      ) {
        setEventStream({
          ready: detail.ready,
          message: typeof detail.message === "string" ? detail.message : null,
        });
      }
    };
    window.addEventListener(WEB_EVENT_STREAM_STATE_EVENT, update);
    return () => window.removeEventListener(WEB_EVENT_STREAM_STATE_EVENT, update);
  }, [tauri]);

  useEffect(() => {
    if (tauri || session?.authenticated !== true || session.control !== "available") return;
    void claimControl().catch((caught) => {
      setError(caught instanceof Error ? caught.message : "Scanner control could not be claimed.");
    });
  }, [claimControl, session, tauri]);

  useEffect(() => {
    if (!tauri && session?.authenticated === true) notifyWebSessionReady();
  }, [session?.authenticated, tauri]);

  useEffect(() => {
    if (tauri || session?.authenticated !== true) return;
    const interval = window.setInterval(() => void refresh(), 60_000);
    return () => window.clearInterval(interval);
  }, [refresh, session?.authenticated, tauri]);

  useEffect(() => {
    if (tauri || session?.control !== "owned") return;
    const heartbeat = window.setInterval(() => {
      const generation = ++refreshGeneration.current;
      void post("/api/v1/control/heartbeat", undefined, true)
        .then((response) => {
          if (refreshGeneration.current !== generation) return;
          if (response.status === 401) {
            releaseLocalControl();
            setSession({ authenticated: false, control: "available" });
          } else if (response.status === 409 || response.status === 423) {
            releaseLocalControl();
            setSession((current) =>
              current === null ? current : { ...current, control: "observer" },
            );
          } else if (!response.ok) {
            releaseLocalControl();
            setSession((current) =>
              current === null ? current : { ...current, control: "observer" },
            );
            setError(`Scanner control heartbeat failed (${response.status}).`);
          } else {
            setError(null);
          }
        })
        .catch(() => {
          if (refreshGeneration.current !== generation) return;
          releaseLocalControl();
          setSession((current) =>
            current === null ? current : { ...current, control: "observer" },
          );
          setError("The scanner server could not be reached; control was released locally.");
        });
    }, 10_000);
    const release = (): void => {
      const headers = controlLeaseHeaders();
      void fetch("/api/v1/control/release", {
        method: "POST",
        credentials: "same-origin",
        headers,
        keepalive: true,
      });
      releaseLocalControl();
    };
    window.addEventListener("pagehide", release);
    return () => {
      window.clearInterval(heartbeat);
      window.removeEventListener("pagehide", release);
      releaseLocalControl();
    };
  }, [releaseLocalControl, session?.control, tauri]);

  if (tauri) return children;

  const logIn = async (event: FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault();
    if (token.length === 0 || busy) return;
    setBusy(true);
    setError(null);
    try {
      const generation = ++refreshGeneration.current;
      releaseLocalControl();
      const response = await post("/api/v1/session/login", { token });
      if (!response.ok) {
        setError(response.status === 401 ? "That access token was not accepted." : `Login failed (${response.status}).`);
        return;
      }
      setToken("");
      const next = await readSession();
      if (refreshGeneration.current === generation) {
        commitSession(next);
      }
    } catch {
      setError("The ScanStudio server could not be reached.");
    } finally {
      setBusy(false);
    }
  };

  if (session === null) {
    return (
      <main className={styles.loginSurface}>
        <div className={styles.loginContent} aria-live="polite">
          <div className={styles.brandMark} aria-hidden="true" />
          <h1 className={styles.title}>ScanStudio</h1>
          <p className={styles.statusCopy}>{error ?? "Connecting to the scanner server…"}</p>
          {error !== null && (
            <button className={styles.primaryButton} type="button" onClick={() => void refresh()}>
              Try again
            </button>
          )}
        </div>
      </main>
    );
  }

  if (!session.authenticated) {
    return (
      <main className={styles.loginSurface}>
        <form className={styles.loginContent} onSubmit={(event) => void logIn(event)}>
          <div className={styles.brandMark} aria-hidden="true" />
          <h1 className={styles.title}>ScanStudio</h1>
          <p className={styles.statusCopy}>
            Enter the access token configured on the scanner server.
          </p>
          <label className={styles.label} htmlFor="scanstudio-access-token">
            Access token
          </label>
          <input
            id="scanstudio-access-token"
            className={styles.tokenInput}
            type="password"
            autoComplete="current-password"
            value={token}
            onChange={(event) => setToken(event.target.value)}
            autoFocus
          />
          {error !== null && <p className={styles.error} role="alert">{error}</p>}
          <button className={styles.primaryButton} type="submit" disabled={token.length === 0 || busy}>
            {busy ? "Connecting…" : "Open ScanStudio"}
          </button>
        </form>
      </main>
    );
  }

  return (
    <ScannerControlProvider canControl={session.control === "owned" && eventStream.ready}>
      <div className={styles.authenticatedShell}>
        <header
          className={styles.runtimeBar}
          data-control={eventStream.ready ? session.control : "offline"}
        >
          <div className={styles.runtimeIdentity}>
            <span className={styles.liveDot} aria-hidden="true" />
            <span>Browser preview</span>
          </div>
          {!eventStream.ready ? (
            <span className={styles.controlCopy} role="status">
              {eventStream.message ?? "Reconnecting to scanner events…"}
            </span>
          ) : session.control === "owned" ? (
            <span className={styles.controlCopy}>This browser has scanner control</span>
          ) : (
            <div className={styles.observerControls}>
              <span className={styles.controlCopy}>Viewing only — another browser has control</span>
              <button
                className={styles.claimButton}
                type="button"
                onClick={() => {
                  void claimControl().catch((caught) => {
                    setError(
                      caught instanceof Error
                        ? caught.message
                        : "Scanner control could not be claimed.",
                    );
                  });
                }}
              >
                Try to take control
              </button>
            </div>
          )}
        </header>
        {error !== null && (
          <p className={styles.runtimeError} role="alert">
            {error}
          </p>
        )}
        <div className={styles.appFrame}>{children}</div>
      </div>
    </ScannerControlProvider>
  );
}
