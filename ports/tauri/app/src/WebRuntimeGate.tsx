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
  CONTROL_LEASE_HEADER,
  controlLeaseHeaders,
  getControlLeaseToken,
  setControlLeaseToken,
  type HeldControlTabLock,
} from "./controlLease";
import { isTauriRuntime } from "./runtime";
import {
  notifyWebSessionReady,
  WEB_CONTROL_LOST_EVENT,
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

interface WebSessionRead {
  session: WebSession;
  submittedLeaseToken: string | null;
}

interface ControlLeaseTiming {
  ttlMs: number;
  heartbeatIntervalMs: number;
  heartbeatTimeoutMs: number;
}

interface ActiveHeartbeat {
  leaseToken: string;
  controller: AbortController;
  timeoutId: number;
}

interface ActiveClaim {
  promise: Promise<void>;
  controller: AbortController;
  timeoutId: number | null;
}

interface ActiveControlVerification {
  leaseToken: string;
  monotonicDeadlineMs: number;
  wallDeadlineMs: number;
  timeoutId: number | null;
}

interface WebRuntimeGateProps {
  children: ReactNode;
}

const CONTROL_TAB_UNVERIFIED_MESSAGE =
  "Scanner control could not be verified for this tab. Reclaim control in this tab.";
const CONTROL_RENEWAL_OVERDUE_MESSAGE =
  "Scanner control renewal is overdue; verifying before continuing.";
const CLAIM_REQUEST_TIMEOUT_MS = 10_000;
const MIN_HEARTBEAT_TIMER_MS = 250;
const MAX_HEARTBEAT_TIMER_MS = 10_000;
const HEARTBEAT_SAFETY_MARGIN_MS = 250;

function controlLeaseSafeRemainingMs(
  monotonicDeadlineMs: number,
  wallDeadlineMs: number,
): number {
  return (
    Math.min(
      monotonicDeadlineMs - performance.now(),
      wallDeadlineMs - Date.now(),
    ) - HEARTBEAT_SAFETY_MARGIN_MS
  );
}

function controlLeaseTiming(expiresInSeconds: unknown): ControlLeaseTiming | null {
  if (
    typeof expiresInSeconds !== "number" ||
    !Number.isFinite(expiresInSeconds) ||
    expiresInSeconds <= 0
  ) {
    return null;
  }
  const ttlMs = expiresInSeconds * 1_000;
  if (!Number.isFinite(ttlMs)) return null;
  const heartbeatIntervalMs = Math.max(
    MIN_HEARTBEAT_TIMER_MS,
    Math.min(MAX_HEARTBEAT_TIMER_MS, ttlMs / 3),
  );
  const requestBudgetMs = ttlMs - heartbeatIntervalMs - HEARTBEAT_SAFETY_MARGIN_MS;
  if (requestBudgetMs < MIN_HEARTBEAT_TIMER_MS) return null;
  return {
    ttlMs,
    heartbeatIntervalMs,
    // Settle a stalled request before the next normal heartbeat tick whenever
    // the lease lifetime permits it, leaving that tick available for recovery.
    heartbeatTimeoutMs: Math.min(
      Math.max(MIN_HEARTBEAT_TIMER_MS, heartbeatIntervalMs / 2),
      requestBudgetMs,
    ),
  };
}

async function readSession(): Promise<WebSessionRead> {
  const headers = controlLeaseHeaders();
  const submittedLeaseToken = headers[CONTROL_LEASE_HEADER] ?? null;
  const response = await fetch("/api/v1/session", {
    credentials: "same-origin",
    headers,
  });
  if (response.status === 401) {
    return {
      session: { authenticated: false, control: "available" },
      submittedLeaseToken,
    };
  }
  if (!response.ok) throw new Error(`Session check failed (${response.status}).`);
  const payload = (await response.json()) as Partial<WebSession>;
  const control =
    payload.control === "owned" || payload.control === "observer"
      ? payload.control
      : "available";
  return {
    session: {
      authenticated: payload.authenticated === true,
      control,
    },
    submittedLeaseToken,
  };
}

async function post(
  path: string,
  body?: unknown,
  includeLease = false,
  signal?: AbortSignal,
): Promise<Response> {
  return fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      ...(includeLease ? controlLeaseHeaders() : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal,
  });
}

export default function WebRuntimeGate({ children }: WebRuntimeGateProps) {
  const tauri = isTauriRuntime();
  const [session, setSession] = useState<WebSession | null>(null);
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [controlVerified, setControlVerified] = useState(tauri);
  const [eventStream, setEventStream] = useState<WebEventStreamState>({
    ready: tauri,
    message: tauri ? null : "Connecting to the scanner event stream…",
  });
  const claimInFlight = useRef<ActiveClaim | null>(null);
  const refreshGeneration = useRef(0);
  const controlTabLock = useRef<HeldControlTabLock | null>(null);
  const heartbeatIntervalMs = useRef(2_000);
  const heartbeatTimeoutMs = useRef(2_000);
  const controlLeaseTtlMs = useRef(6_000);
  const controlLeaseMonotonicDeadlineMs = useRef(0);
  const controlLeaseWallDeadlineMs = useRef(0);
  const heartbeatInFlight = useRef<ActiveHeartbeat | null>(null);
  const controlVerificationDeadline = useRef<ActiveControlVerification | null>(null);

  const clearControlVerificationDeadline = useCallback((): void => {
    const activeVerification = controlVerificationDeadline.current;
    controlVerificationDeadline.current = null;
    if (activeVerification !== null && activeVerification.timeoutId !== null) {
      window.clearTimeout(activeVerification.timeoutId);
      activeVerification.timeoutId = null;
    }
  }, []);

  const verifyLocalControlUntil = useCallback(
    (
      leaseToken: string,
      monotonicDeadlineMs: number,
      wallDeadlineMs: number,
    ): void => {
      clearControlVerificationDeadline();
      if (getControlLeaseToken() !== leaseToken) return;
      const activeVerification: ActiveControlVerification = {
        leaseToken,
        monotonicDeadlineMs,
        wallDeadlineMs,
        timeoutId: null,
      };
      const checkDeadline = (): void => {
        if (controlVerificationDeadline.current !== activeVerification) return;
        if (getControlLeaseToken() !== activeVerification.leaseToken) {
          controlVerificationDeadline.current = null;
          activeVerification.timeoutId = null;
          return;
        }
        const remainingMs = controlLeaseSafeRemainingMs(
          activeVerification.monotonicDeadlineMs,
          activeVerification.wallDeadlineMs,
        );
        if (remainingMs > 0) {
          activeVerification.timeoutId = window.setTimeout(
            checkDeadline,
            Math.min(MAX_HEARTBEAT_TIMER_MS, Math.max(1, remainingMs)),
          );
          return;
        }
        controlVerificationDeadline.current = null;
        activeVerification.timeoutId = null;
        refreshGeneration.current += 1;
        setControlVerified(false);
        setError(CONTROL_RENEWAL_OVERDUE_MESSAGE);
      };
      controlVerificationDeadline.current = activeVerification;
      activeVerification.timeoutId = window.setTimeout(
        checkDeadline,
        Math.min(
          MAX_HEARTBEAT_TIMER_MS,
          Math.max(
            0,
            controlLeaseSafeRemainingMs(monotonicDeadlineMs, wallDeadlineMs),
          ),
        ),
      );
      setControlVerified(true);
    },
    [clearControlVerificationDeadline],
  );

  const releaseLocalControl = useCallback((expectedLeaseToken?: string): void => {
    if (
      expectedLeaseToken !== undefined &&
      getControlLeaseToken() !== expectedLeaseToken
    ) {
      return;
    }
    const activeClaim = claimInFlight.current;
    if (activeClaim !== null) {
      if (activeClaim.timeoutId !== null) {
        window.clearTimeout(activeClaim.timeoutId);
        activeClaim.timeoutId = null;
      }
      if (!activeClaim.controller.signal.aborted) activeClaim.controller.abort();
    }
    const activeHeartbeat = heartbeatInFlight.current;
    if (
      activeHeartbeat !== null &&
      (expectedLeaseToken === undefined || activeHeartbeat.leaseToken === expectedLeaseToken)
    ) {
      window.clearTimeout(activeHeartbeat.timeoutId);
      activeHeartbeat.controller.abort();
      if (heartbeatInFlight.current === activeHeartbeat) heartbeatInFlight.current = null;
    }
    controlLeaseMonotonicDeadlineMs.current = 0;
    controlLeaseWallDeadlineMs.current = 0;
    clearControlVerificationDeadline();
    setControlVerified(false);
    clearControlLeaseToken();
    controlTabLock.current?.release();
    controlTabLock.current = null;
  }, [clearControlVerificationDeadline]);

  const commitSession = useCallback(
    (next: WebSession, submittedLeaseToken: string | null): void => {
      const activeLeaseToken = getControlLeaseToken();
      // A read started before a replacement claim must never clear or verify the
      // replacement capability after it completes.
      if (activeLeaseToken !== null && submittedLeaseToken !== activeLeaseToken) return;
      if (next.authenticated && next.control === "owned" && controlTabLock.current === null) {
        releaseLocalControl();
        setSession({ ...next, control: "observer" });
        setError(CONTROL_TAB_UNVERIFIED_MESSAGE);
        return;
      }
      if (next.authenticated && next.control === "owned") {
        if (submittedLeaseToken === null || activeLeaseToken !== submittedLeaseToken) {
          releaseLocalControl();
          setSession({ ...next, control: "observer" });
          setError(CONTROL_TAB_UNVERIFIED_MESSAGE);
          return;
        }
        if (
          controlLeaseSafeRemainingMs(
            controlLeaseMonotonicDeadlineMs.current,
            controlLeaseWallDeadlineMs.current,
          ) < MIN_HEARTBEAT_TIMER_MS
        ) {
          setControlVerified(false);
          setError(CONTROL_RENEWAL_OVERDUE_MESSAGE);
        } else {
          verifyLocalControlUntil(
            activeLeaseToken,
            controlLeaseMonotonicDeadlineMs.current,
            controlLeaseWallDeadlineMs.current,
          );
          setError(null);
        }
      }
      if (!next.authenticated || next.control !== "owned") releaseLocalControl();
      setSession(next);
    },
    [releaseLocalControl, verifyLocalControlUntil],
  );

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
        commitSession(next.session, next.submittedLeaseToken);
      }
    } catch (caught) {
      if (refreshGeneration.current === generation) {
        setError(caught instanceof Error ? caught.message : "The ScanStudio server is unavailable.");
      }
    }
  }, [commitSession]);

  const claimControl = useCallback((): Promise<void> => {
    if (claimInFlight.current !== null) return claimInFlight.current.promise;
    const controller = new AbortController();
    const activeClaim: ActiveClaim = {
      promise: Promise.resolve(),
      controller,
      timeoutId: null,
    };
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
      const claimStartedAt = performance.now();
      const claimStartedWallTime = Date.now();
      activeClaim.timeoutId = window.setTimeout(
        () => controller.abort(),
        CLAIM_REQUEST_TIMEOUT_MS,
      );
      try {
        response = await post("/api/v1/control/claim", undefined, false, controller.signal);
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
      let payload: { leaseToken?: unknown; expiresInSeconds?: unknown };
      try {
        payload = (await response.json()) as {
          leaseToken?: unknown;
          expiresInSeconds?: unknown;
        };
      } catch {
        releaseLocalControl();
        throw new Error("The scanner server returned an unreadable control lease.");
      }
      if (typeof payload.leaseToken !== "string" || payload.leaseToken.length === 0) {
        releaseLocalControl();
        throw new Error("The scanner server did not return a control lease.");
      }
      const timing = controlLeaseTiming(payload.expiresInSeconds);
      if (timing === null) {
        setControlLeaseToken(payload.leaseToken);
        void post("/api/v1/control/release", undefined, true).catch(() => undefined);
        releaseLocalControl(payload.leaseToken);
        throw new Error("The scanner server did not return a usable control lease lifetime.");
      }
      heartbeatIntervalMs.current = timing.heartbeatIntervalMs;
      heartbeatTimeoutMs.current = timing.heartbeatTimeoutMs;
      controlLeaseTtlMs.current = timing.ttlMs;
      const claimedMonotonicDeadlineMs = claimStartedAt + timing.ttlMs;
      const claimedWallDeadlineMs = claimStartedWallTime + timing.ttlMs;
      if (
        controlLeaseSafeRemainingMs(
          claimedMonotonicDeadlineMs,
          claimedWallDeadlineMs,
        ) < MIN_HEARTBEAT_TIMER_MS
      ) {
        setControlLeaseToken(payload.leaseToken);
        void post("/api/v1/control/release", undefined, true).catch(() => undefined);
        releaseLocalControl(payload.leaseToken);
        setSession((current) =>
          current === null ? current : { ...current, control: "observer" },
        );
        throw new Error(CONTROL_RENEWAL_OVERDUE_MESSAGE);
      }
      controlLeaseMonotonicDeadlineMs.current = claimedMonotonicDeadlineMs;
      controlLeaseWallDeadlineMs.current = claimedWallDeadlineMs;
      setControlLeaseToken(payload.leaseToken);
      verifyLocalControlUntil(
        payload.leaseToken,
        claimedMonotonicDeadlineMs,
        claimedWallDeadlineMs,
      );
      setError(null);
      setSession((current) =>
        current === null ? current : { ...current, control: "owned" },
      );
    })();
    activeClaim.promise = claim;
    claimInFlight.current = activeClaim;
    const clearClaim = (): void => {
      if (activeClaim.timeoutId !== null) {
        window.clearTimeout(activeClaim.timeoutId);
        activeClaim.timeoutId = null;
      }
      if (claimInFlight.current === activeClaim) claimInFlight.current = null;
    };
    void claim.then(clearClaim, clearClaim);
    return claim;
  }, [releaseLocalControl, verifyLocalControlUntil]);

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
    const releaseForPageHide = (): void => {
      refreshGeneration.current += 1;
      const headers = controlLeaseHeaders();
      if (headers[CONTROL_LEASE_HEADER] !== undefined) {
        void fetch("/api/v1/control/release", {
          method: "POST",
          credentials: "same-origin",
          headers,
          keepalive: true,
        }).catch(() => undefined);
      }
      releaseLocalControl();
      setSession((current) =>
        current === null || !current.authenticated
          ? current
          : { ...current, control: "observer" },
      );
    };
    const restorePersistedPage = (event: PageTransitionEvent): void => {
      if (!event.persisted) return;
      const activeClaim = claimInFlight.current;
      if (activeClaim === null) {
        void refresh();
        return;
      }
      const refreshAfterClaim = (): void => {
        void refresh();
      };
      void activeClaim.promise.then(refreshAfterClaim, refreshAfterClaim);
    };
    window.addEventListener("pagehide", releaseForPageHide);
    window.addEventListener("pageshow", restorePersistedPage);
    return () => {
      window.removeEventListener("pagehide", releaseForPageHide);
      window.removeEventListener("pageshow", restorePersistedPage);
    };
  }, [refresh, releaseLocalControl, tauri]);

  useEffect(() => {
    if (tauri) return;
    const loseControl = (): void => {
      refreshGeneration.current += 1;
      releaseLocalControl();
      setSession((current) =>
        current === null ? current : { ...current, control: "observer" },
      );
      setError("Scanner control expired. Reclaim control to continue.");
    };
    window.addEventListener(WEB_CONTROL_LOST_EVENT, loseControl);
    return () => window.removeEventListener(WEB_CONTROL_LOST_EVENT, loseControl);
  }, [releaseLocalControl, tauri]);

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
    const sendHeartbeat = (): void => {
      if (heartbeatInFlight.current !== null) return;
      const submittedLeaseToken = getControlLeaseToken();
      if (submittedLeaseToken === null) return;
      const requestStartedAt = performance.now();
      const requestStartedWallTime = Date.now();
      // WebKit's monotonic clock may pause during system sleep while the
      // gateway's wall-clock lease continues to expire. Either clock reaching
      // its deadline is enough to fail closed.
      const remainingVerifiedMs =
        controlLeaseSafeRemainingMs(
          controlLeaseMonotonicDeadlineMs.current,
          controlLeaseWallDeadlineMs.current,
        );
      const requestTimeoutMs =
        remainingVerifiedMs >= MIN_HEARTBEAT_TIMER_MS
          ? Math.min(heartbeatTimeoutMs.current, remainingVerifiedMs)
          : heartbeatTimeoutMs.current;
      if (remainingVerifiedMs < MIN_HEARTBEAT_TIMER_MS) {
        setControlVerified(false);
        setError("Scanner control renewal is overdue; verifying before continuing.");
      }
      const controller = new AbortController();
      const activeHeartbeat: ActiveHeartbeat = {
        leaseToken: submittedLeaseToken,
        controller,
        timeoutId: window.setTimeout(() => controller.abort(), requestTimeoutMs),
      };
      heartbeatInFlight.current = activeHeartbeat;
      void post("/api/v1/control/heartbeat", undefined, true, controller.signal)
        .then((response) => {
          if (
            heartbeatInFlight.current !== activeHeartbeat ||
            getControlLeaseToken() !== submittedLeaseToken
          ) {
            return;
          }
          if (response.status === 401) {
            releaseLocalControl(submittedLeaseToken);
            setError(null);
            setSession({ authenticated: false, control: "available" });
          } else if (response.status === 409 || response.status === 423) {
            releaseLocalControl(submittedLeaseToken);
            setSession((current) =>
              current === null ? current : { ...current, control: "observer" },
            );
            setError("Scanner control expired. Reclaim control to continue.");
          } else if (response.status !== 200) {
            setControlVerified(false);
            setError(
              `Scanner control heartbeat could not be verified (${response.status}); retrying.`,
            );
          } else {
            const renewedMonotonicDeadlineMs =
              requestStartedAt + controlLeaseTtlMs.current;
            const renewedWallDeadlineMs =
              requestStartedWallTime + controlLeaseTtlMs.current;
            if (
              controlLeaseSafeRemainingMs(
                renewedMonotonicDeadlineMs,
                renewedWallDeadlineMs,
              ) < MIN_HEARTBEAT_TIMER_MS
            ) {
              setControlVerified(false);
              setError(CONTROL_RENEWAL_OVERDUE_MESSAGE);
              return;
            }
            controlLeaseMonotonicDeadlineMs.current = renewedMonotonicDeadlineMs;
            controlLeaseWallDeadlineMs.current = renewedWallDeadlineMs;
            verifyLocalControlUntil(
              submittedLeaseToken,
              renewedMonotonicDeadlineMs,
              renewedWallDeadlineMs,
            );
            setError(null);
          }
        })
        .catch(() => {
          if (
            heartbeatInFlight.current !== activeHeartbeat ||
            getControlLeaseToken() !== submittedLeaseToken
          ) {
            return;
          }
          setControlVerified(false);
          setError(
            "The scanner server could not be reached; verifying control before continuing.",
          );
        })
        .finally(() => {
          window.clearTimeout(activeHeartbeat.timeoutId);
          if (heartbeatInFlight.current === activeHeartbeat) {
            heartbeatInFlight.current = null;
          }
        });
    };
    const heartbeat = window.setInterval(sendHeartbeat, heartbeatIntervalMs.current);
    const verifyAndSendHeartbeat = (): void => {
      refreshGeneration.current += 1;
      setControlVerified(false);
      setError(null);
      sendHeartbeat();
    };
    const resumeHeartbeat = (): void => {
      if (document.visibilityState === "visible") verifyAndSendHeartbeat();
    };
    window.addEventListener("focus", verifyAndSendHeartbeat);
    document.addEventListener("visibilitychange", resumeHeartbeat);
    return () => {
      window.clearInterval(heartbeat);
      window.removeEventListener("focus", verifyAndSendHeartbeat);
      document.removeEventListener("visibilitychange", resumeHeartbeat);
      releaseLocalControl();
    };
  }, [releaseLocalControl, session?.control, tauri, verifyLocalControlUntil]);

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
        commitSession(next.session, next.submittedLeaseToken);
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
    <ScannerControlProvider
      canControl={session.control === "owned" && controlVerified && eventStream.ready}
    >
      <div className={styles.authenticatedShell}>
        <header
          className={styles.runtimeBar}
          data-control={
            !eventStream.ready || (session.control === "owned" && !controlVerified)
              ? "offline"
              : session.control
          }
        >
          <div className={styles.runtimeIdentity}>
            <span className={styles.liveDot} aria-hidden="true" />
            <span>Browser preview</span>
          </div>
          {!eventStream.ready ? (
            <span className={styles.controlCopy} role="status">
              {eventStream.message ?? "Reconnecting to scanner events…"}
            </span>
          ) : session.control === "owned" && !controlVerified ? (
            <span className={styles.controlCopy} role="status">
              Verifying scanner control…
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
