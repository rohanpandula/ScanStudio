/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import WebRuntimeGate from "../WebRuntimeGate";
import { clearControlLeaseToken, getControlLeaseToken } from "../controlLease";
import {
  WEB_CONTROL_LOST_EVENT,
  WEB_EVENT_STREAM_STATE_EVENT,
} from "../engine/client";
import { useScannerControl } from "../scannerControl";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function ControlProbe() {
  return <div>Control: {useScannerControl() ? "owned" : "observer"}</div>;
}

function markEventStreamReady(): void {
  act(() => {
    window.dispatchEvent(
      new CustomEvent(WEB_EVENT_STREAM_STATE_EVENT, {
        detail: { ready: true, message: null },
      }),
    );
  });
}

function installFakeLocks(initiallyHeld = false): {
  request: ReturnType<typeof vi.fn>;
  isHeld: () => boolean;
} {
  let held = initiallyHeld;
  const request = vi.fn(
    async (
      name: string,
      options: LockOptions,
      callback: (lock: Lock | null) => Promise<unknown> | unknown,
    ): Promise<unknown> => {
      if (options.ifAvailable === true && held) return callback(null);
      held = true;
      try {
        return await callback({ name, mode: "exclusive" } as Lock);
      } finally {
        held = false;
      }
    },
  );
  Object.defineProperty(navigator, "locks", {
    configurable: true,
    value: { request } as unknown as LockManager,
  });
  return { request, isHeld: () => held };
}

function captureIntervals(): {
  heartbeatHandlers: Array<() => void>;
  periodicRefreshHandlers: Array<() => void>;
} {
  const heartbeatHandlers: Array<() => void> = [];
  const periodicRefreshHandlers: Array<() => void> = [];
  let nextIntervalId = 1;
  vi.spyOn(window, "setInterval").mockImplementation((handler, timeout) => {
    if (typeof handler === "function") {
      const callback = handler as () => void;
      if (timeout === 60_000) periodicRefreshHandlers.push(callback);
      else if (typeof timeout === "number" && timeout >= 250 && timeout <= 10_000) {
        heartbeatHandlers.push(callback);
      }
    }
    return nextIntervalId++ as unknown as ReturnType<typeof setInterval>;
  });
  return { heartbeatHandlers, periodicRefreshHandlers };
}

afterEach(() => {
  vi.useRealTimers();
  cleanup();
  clearControlLeaseToken();
  window.sessionStorage.clear();
  Reflect.deleteProperty(navigator, "locks");
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("WebRuntimeGate", () => {
  it("logs in, claims a tab-scoped control lease, and opens the app", async () => {
    const locks = installFakeLocks();
    let authenticated = false;
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input);
      if (path === "/api/v1/session" && init?.method !== "POST") {
        return jsonResponse({ authenticated, control: "available" });
      }
      if (path === "/api/v1/session/login") {
        authenticated = true;
        return jsonResponse({ authenticated: true });
      }
      if (path === "/api/v1/control/claim") {
        return jsonResponse({ leaseToken: "tab-lease", expiresInSeconds: 30 });
      }
      throw new Error(`unexpected request ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);
    const user = userEvent.setup();

    const { unmount } = render(
      <WebRuntimeGate>
        <div>
          Scanner workspace
          <ControlProbe />
        </div>
      </WebRuntimeGate>,
    );

    const token = await screen.findByLabelText("Access token");
    await user.type(token, "local-secret");
    await user.click(screen.getByRole("button", { name: "Open ScanStudio" }));

    expect(await screen.findByText("Scanner workspace")).toBeVisible();
    markEventStreamReady();
    expect(await screen.findByText("This browser has scanner control")).toBeVisible();
    expect(screen.getByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("tab-lease");
    expect(window.sessionStorage.getItem("scanstudio.control-lease")).toBeNull();
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/session/login",
      expect.objectContaining({ body: JSON.stringify({ token: "local-secret" }) }),
    );
    expect(locks.isHeld()).toBe(true);
    unmount();
    await waitFor(() => expect(locks.isHeld()).toBe(false));
    expect(getControlLeaseToken()).toBeNull();
  });

  it("demotes an expired controller as soon as an engine request reports lease loss", async () => {
    const locks = installFakeLocks();
    const intervals = vi.spyOn(window, "setInterval");
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "short-lived-lease", expiresInSeconds: 5 });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    expect(locks.isHeld()).toBe(true);
    expect(
      intervals.mock.calls.some(([, timeout]) => timeout === 5_000 / 3),
    ).toBe(true);

    act(() => window.dispatchEvent(new Event(WEB_CONTROL_LOST_EVENT)));

    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(screen.getByText("Scanner control expired. Reclaim control to continue.")).toBeVisible();
    expect(getControlLeaseToken()).toBeNull();
    await waitFor(() => expect(locks.isHeld()).toBe(false));
  });

  it("keeps a second no-Locks page observing when the server lease is already owned", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ error: { code: "CONTROL_LOCKED" } }, 409);
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <div>
          Scanner workspace
          <ControlProbe />
        </div>
      </WebRuntimeGate>,
    );

    expect(await screen.findByText("Scanner workspace")).toBeVisible();
    markEventStreamReady();
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Try to take control" })).toBeVisible();
    });
    expect(window.sessionStorage.getItem("scanstudio.control-lease")).toBeNull();
    expect(getControlLeaseToken()).toBeNull();
    expect(screen.getByText("Control: observer")).toBeVisible();
  });

  it("does not let a stale session refresh erase a newly claimed lease", async () => {
    installFakeLocks();
    let sessionReads = 0;
    let resolveStaleRefresh: ((response: Response) => void) | null = null;
    let runPeriodicRefresh: (() => void) | null = null;
    vi.spyOn(window, "setInterval").mockImplementation((handler, timeout) => {
      if (timeout === 60_000 && typeof handler === "function") {
        runPeriodicRefresh = handler as () => void;
      }
      return setTimeout(() => undefined, 0);
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          sessionReads += 1;
          if (sessionReads === 1) {
            return jsonResponse({ authenticated: true, control: "observer" });
          }
          return new Promise<Response>((resolve) => {
            resolveStaleRefresh = resolve;
          });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "new-tab-lease", expiresInSeconds: 30 });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByRole("button", { name: "Try to take control" })).toBeVisible();

    act(() => runPeriodicRefresh?.());
    await waitFor(() => expect(sessionReads).toBe(2));
    fireEvent.click(screen.getByRole("button", { name: "Try to take control" }));
    expect(await screen.findByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("new-tab-lease");
    expect(window.sessionStorage.getItem("scanstudio.control-lease")).toBeNull();

    await act(async () => {
      resolveStaleRefresh?.(jsonResponse({ authenticated: true, control: "observer" }));
      await Promise.resolve();
    });
    expect(screen.getByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("new-tab-lease");
    expect(window.sessionStorage.getItem("scanstudio.control-lease")).toBeNull();
  });

  it("retains a successful claim when the periodic refresh fires while it is in flight", async () => {
    const locks = installFakeLocks();
    let sessionReads = 0;
    let resolveClaim: ((response: Response) => void) | null = null;
    let runPeriodicRefresh: (() => void) | null = null;
    vi.spyOn(window, "setInterval").mockImplementation((handler, timeout) => {
      if (timeout === 60_000 && typeof handler === "function") {
        runPeriodicRefresh = handler as () => void;
      }
      return setTimeout(() => undefined, 0);
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          sessionReads += 1;
          return jsonResponse({ authenticated: true, control: "observer" });
        }
        if (path === "/api/v1/control/claim") {
          return new Promise<Response>((resolve) => {
            resolveClaim = resolve;
          });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    fireEvent.click(await screen.findByRole("button", { name: "Try to take control" }));
    await waitFor(() => expect(locks.request).toHaveBeenCalled());
    await waitFor(() => expect(resolveClaim).not.toBeNull());
    expect(runPeriodicRefresh).not.toBeNull();

    act(() => runPeriodicRefresh?.());
    await act(async () => {
      resolveClaim?.(jsonResponse({ leaseToken: "delayed-tab-lease", expiresInSeconds: 30 }));
      await Promise.resolve();
    });

    expect(await screen.findByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("delayed-tab-lease");
    expect(locks.isHeld()).toBe(true);
    expect(sessionReads).toBe(1);
    expect(window.sessionStorage.getItem("scanstudio.control-lease")).toBeNull();
  });

  it("does not verify a successful claim that arrives after its safe deadline", async () => {
    const locks = installFakeLocks();
    captureIntervals();
    let wallTime = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => wallTime);
    let resolveClaim: ((response: Response) => void) | null = null;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path === "/api/v1/session") {
        return jsonResponse({ authenticated: true, control: "available" });
      }
      if (path === "/api/v1/control/claim") {
        return new Promise<Response>((resolve) => {
          resolveClaim = resolve;
        });
      }
      if (path === "/api/v1/control/release") {
        return jsonResponse({ released: true });
      }
      throw new Error(`unexpected request ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    fireEvent.click(await screen.findByRole("button", { name: "Try to take control" }));
    expect(resolveClaim).not.toBeNull();

    wallTime += 1_100;
    await act(async () => {
      resolveClaim?.(jsonResponse({ leaseToken: "late-claim-lease", expiresInSeconds: 1 }));
      await Promise.resolve();
    });

    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(
      screen.getByText("Scanner control renewal is overdue; verifying before continuing."),
    ).toBeVisible();
    expect(getControlLeaseToken()).toBeNull();
    await waitFor(() => expect(locks.isHeld()).toBe(false));
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/control/release",
      expect.objectContaining({
        headers: { "X-ScanStudio-Control-Lease": "late-claim-lease" },
      }),
    );
  });

  it("expires a late but initially usable claim at its local safe deadline", async () => {
    vi.useFakeTimers();
    const locks = installFakeLocks();
    let resolveClaim: ((response: Response) => void) | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "observer" });
        }
        if (path === "/api/v1/control/claim") {
          return new Promise<Response>((resolve) => {
            resolveClaim = resolve;
          });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    fireEvent.click(screen.getByRole("button", { name: "Try to take control" }));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4_000);
    });
    expect(resolveClaim).not.toBeNull();

    await act(async () => {
      resolveClaim?.(jsonResponse({ leaseToken: "watchdog-claim-lease", expiresInSeconds: 5 }));
      await Promise.resolve();
    });
    expect(screen.getByText("Control: owned")).toBeVisible();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(751);
    });
    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBe("watchdog-claim-lease");
    expect(locks.isHeld()).toBe(true);
  });

  it("aborts a stalled claim on pagehide and waits for it before persisted restore", async () => {
    const locks = installFakeLocks();
    let sessionReads = 0;
    let claimCount = 0;
    let stalledClaimSignal: AbortSignal | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          sessionReads += 1;
          return jsonResponse({
            authenticated: true,
            control: sessionReads === 1 ? "observer" : "available",
          });
        }
        if (path === "/api/v1/control/claim") {
          claimCount += 1;
          if (claimCount === 1) {
            stalledClaimSignal = init?.signal ?? null;
            return new Promise<Response>((_resolve, reject) => {
              init?.signal?.addEventListener(
                "abort",
                () => reject(new DOMException("claim aborted", "AbortError")),
                { once: true },
              );
            });
          }
          return jsonResponse({
            leaseToken: "restored-after-claim-lease",
            expiresInSeconds: 30,
          });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    fireEvent.click(await screen.findByRole("button", { name: "Try to take control" }));
    await waitFor(() => expect(stalledClaimSignal).not.toBeNull());

    const pagehide = new Event("pagehide") as PageTransitionEvent;
    Object.defineProperty(pagehide, "persisted", { value: true });
    const pageshow = new Event("pageshow") as PageTransitionEvent;
    Object.defineProperty(pageshow, "persisted", { value: true });
    await act(async () => {
      window.dispatchEvent(pagehide);
      window.dispatchEvent(pageshow);
      await Promise.resolve();
    });

    expect((stalledClaimSignal as AbortSignal | null)?.aborted).toBe(true);
    expect(await screen.findByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("restored-after-claim-lease");
    expect(sessionReads).toBe(2);
    expect(claimCount).toBe(2);
    expect(locks.isHeld()).toBe(true);
  });

  it("times out a stalled claim, cleans it up, and permits a retry", async () => {
    const locks = installFakeLocks();
    let claimCount = 0;
    let stalledClaimSignal: AbortSignal | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "observer" });
        }
        if (path === "/api/v1/control/claim") {
          claimCount += 1;
          if (claimCount === 1) {
            stalledClaimSignal = init?.signal ?? null;
            return new Promise<Response>((_resolve, reject) => {
              init?.signal?.addEventListener(
                "abort",
                () => reject(new DOMException("claim timed out", "AbortError")),
                { once: true },
              );
            });
          }
          return jsonResponse({ leaseToken: "retry-lease", expiresInSeconds: 30 });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    const claimButton = await screen.findByRole("button", { name: "Try to take control" });
    vi.useFakeTimers();
    await act(async () => {
      fireEvent.click(claimButton);
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(stalledClaimSignal).not.toBeNull();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });
    expect((stalledClaimSignal as AbortSignal | null)?.aborted).toBe(true);
    expect(screen.getByText("The scanner server could not be reached.")).toBeVisible();
    expect(getControlLeaseToken()).toBeNull();
    expect(locks.isHeld()).toBe(false);

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Try to take control" }));
      await Promise.resolve();
    });
    expect(screen.getByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("retry-lease");
    expect(claimCount).toBe(2);
    expect(locks.isHeld()).toBe(true);
  });

  it("omits a duplicated tab's copied lease and lets the server reject its claim", async () => {
    window.sessionStorage.setItem("scanstudio.control-lease", "copied-tab-lease");
    const locks = installFakeLocks(true);
    let sessionHeaders: HeadersInit | undefined;
    let claimHeaders: HeadersInit | undefined;
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input);
      if (path === "/api/v1/session") {
        sessionHeaders = init?.headers;
        return jsonResponse({ authenticated: true, control: "observer" });
      }
      if (path === "/api/v1/control/claim") {
        claimHeaders = init?.headers;
        return jsonResponse({ error: { code: "CONTROL_LOCKED" } }, 409);
      }
      throw new Error(`unexpected request ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByRole("button", { name: "Try to take control" })).toBeVisible();
    expect(sessionHeaders).toEqual({});
    expect(window.sessionStorage.getItem("scanstudio.control-lease")).toBeNull();
    expect(getControlLeaseToken()).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Try to take control" }));
    await waitFor(() => {
      expect(
        fetchMock.mock.calls.some(([input]) => String(input) === "/api/v1/control/claim"),
      ).toBe(true);
    });
    expect(locks.request).toHaveBeenCalledWith(
      "scanstudio-controller-tab",
      expect.objectContaining({ ifAvailable: true, mode: "exclusive" }),
      expect.any(Function),
    );
    expect(claimHeaders).toEqual({});
    expect(screen.getByText("Control: observer")).toBeVisible();
  });

  it("can reclaim an expired server lease while another page still holds the advisory lock", async () => {
    const locks = installFakeLocks(true);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "observer" });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "replacement-lease", expiresInSeconds: 30 });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    fireEvent.click(await screen.findByRole("button", { name: "Try to take control" }));

    expect(await screen.findByText("Control: owned")).toBeVisible();
    expect(locks.request).toHaveBeenCalled();
    expect(locks.isHeld()).toBe(true);
    expect(getControlLeaseToken()).toBe("replacement-lease");
    expect(window.sessionStorage.getItem("scanstudio.control-lease")).toBeNull();
  });

  it("claims control with a page-scoped in-memory lease when Web Locks is unavailable", async () => {
    Reflect.deleteProperty(navigator, "locks");
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path === "/api/v1/session") {
        return jsonResponse({ authenticated: true, control: "available" });
      }
      if (path === "/api/v1/control/claim") {
        return jsonResponse({ leaseToken: "insecure-context-lease", expiresInSeconds: 30 });
      }
      throw new Error(`unexpected request ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();

    expect(await screen.findByText("Control: owned")).toBeVisible();
    expect(
      fetchMock.mock.calls.some(([input]) => String(input) === "/api/v1/control/claim"),
    ).toBe(true);
    expect(window.sessionStorage.getItem("scanstudio.control-lease")).toBeNull();
    expect(getControlLeaseToken()).toBe("insecure-context-lease");
  });

  it("releases its browser lock when a successful claim has malformed JSON", async () => {
    const locks = installFakeLocks();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          return new Response("not JSON", { status: 200 });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );

    expect(
      await screen.findByText("The scanner server returned an unreadable control lease."),
    ).toBeVisible();
    await waitFor(() => expect(locks.isHeld()).toBe(false));
    expect(getControlLeaseToken()).toBeNull();
    expect(screen.getByText("Control: observer")).toBeVisible();
  });

  it("keeps a transiently unverified lease and restores control without reclaiming", async () => {
    const locks = installFakeLocks();
    const intervals = captureIntervals();
    let claimCount = 0;
    let heartbeatCount = 0;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path === "/api/v1/session") {
        return jsonResponse({ authenticated: true, control: "available" });
      }
      if (path === "/api/v1/control/claim") {
        claimCount += 1;
        return jsonResponse({ leaseToken: "retained-lease", expiresInSeconds: 30 });
      }
      if (path === "/api/v1/control/heartbeat") {
        heartbeatCount += 1;
        if (heartbeatCount === 1) throw new Error("offline");
        if (heartbeatCount === 2) return jsonResponse({ error: { code: "TEMPORARY" } }, 503);
        return jsonResponse({ expiresInSeconds: 30 });
      }
      throw new Error(`unexpected request ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => expect(intervals.heartbeatHandlers).toHaveLength(1));

    act(() => intervals.heartbeatHandlers[0]?.());
    expect(
      await screen.findByText(
        "The scanner server could not be reached; verifying control before continuing.",
      ),
    ).toBeVisible();
    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBe("retained-lease");
    expect(locks.isHeld()).toBe(true);

    act(() => intervals.heartbeatHandlers[0]?.());
    expect(
      await screen.findByText(
        "Scanner control heartbeat could not be verified (503); retrying.",
      ),
    ).toBeVisible();
    expect(getControlLeaseToken()).toBe("retained-lease");
    expect(locks.isHeld()).toBe(true);

    act(() => intervals.heartbeatHandlers[0]?.());
    expect(await screen.findByText("This browser has scanner control")).toBeVisible();
    expect(screen.getByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("retained-lease");
    expect(locks.isHeld()).toBe(true);
    expect(claimCount).toBe(1);
  });

  it("clears and demotes when a matching heartbeat authoritatively rejects the lease", async () => {
    const locks = installFakeLocks();
    const intervals = captureIntervals();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "expired-lease", expiresInSeconds: 30 });
        }
        if (path === "/api/v1/control/heartbeat") {
          return jsonResponse({ error: { code: "CONTROL_LEASE_REQUIRED" } }, 423);
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => expect(intervals.heartbeatHandlers).toHaveLength(1));

    act(() => intervals.heartbeatHandlers[0]?.());
    expect(await screen.findByText("Control: observer")).toBeVisible();
    expect(screen.getByText("Scanner control expired. Reclaim control to continue.")).toBeVisible();
    expect(screen.getByRole("button", { name: "Try to take control" })).toBeVisible();
    expect(getControlLeaseToken()).toBeNull();
    await waitFor(() => expect(locks.isHeld()).toBe(false));
  });

  it("does not restore a released token from a stale owned session read", async () => {
    const locks = installFakeLocks();
    const intervals = captureIntervals();
    let sessionReads = 0;
    let resolveOwnedSession: ((response: Response) => void) | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          sessionReads += 1;
          if (sessionReads === 1) {
            return jsonResponse({ authenticated: true, control: "available" });
          }
          return new Promise<Response>((resolve) => {
            resolveOwnedSession = resolve;
          });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "session-read-lease", expiresInSeconds: 30 });
        }
        if (path === "/api/v1/control/heartbeat") {
          return jsonResponse({ error: { code: "CONTROL_LEASE_REQUIRED" } }, 423);
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => {
      expect(intervals.periodicRefreshHandlers).toHaveLength(1);
      expect(intervals.heartbeatHandlers).toHaveLength(1);
    });

    act(() => intervals.periodicRefreshHandlers[0]?.());
    await waitFor(() => expect(resolveOwnedSession).not.toBeNull());
    act(() => intervals.heartbeatHandlers[0]?.());
    expect(await screen.findByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBeNull();
    await waitFor(() => expect(locks.isHeld()).toBe(false));

    await act(async () => {
      resolveOwnedSession?.(jsonResponse({ authenticated: true, control: "owned" }));
      await Promise.resolve();
    });
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBeNull();
    expect(locks.isHeld()).toBe(false);
  });

  it("ignores an old heartbeat rejection after a replacement claim", async () => {
    const locks = installFakeLocks();
    const intervals = captureIntervals();
    let claimCount = 0;
    let resolveOldHeartbeat: ((response: Response) => void) | null = null;
    let oldHeartbeatSignal: AbortSignal | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          claimCount += 1;
          return jsonResponse({
            leaseToken: claimCount === 1 ? "old-lease" : "replacement-lease",
            expiresInSeconds: 30,
          });
        }
        if (path === "/api/v1/control/heartbeat") {
          oldHeartbeatSignal = init?.signal ?? null;
          return new Promise<Response>((resolve) => {
            resolveOldHeartbeat = resolve;
          });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => expect(intervals.heartbeatHandlers).toHaveLength(1));
    act(() => intervals.heartbeatHandlers[0]?.());
    await waitFor(() => expect(resolveOldHeartbeat).not.toBeNull());

    act(() => window.dispatchEvent(new Event(WEB_CONTROL_LOST_EVENT)));
    expect((oldHeartbeatSignal as AbortSignal | null)?.aborted).toBe(true);
    fireEvent.click(await screen.findByRole("button", { name: "Try to take control" }));
    expect(await screen.findByText("This browser has scanner control")).toBeVisible();
    expect(getControlLeaseToken()).toBe("replacement-lease");
    expect(locks.isHeld()).toBe(true);

    await act(async () => {
      resolveOldHeartbeat?.(
        jsonResponse({ error: { code: "CONTROL_LEASE_REQUIRED" } }, 423),
      );
      await Promise.resolve();
    });
    expect(screen.getByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("replacement-lease");
    expect(locks.isHeld()).toBe(true);
  });

  it("fails closed on focus and allows only one heartbeat request in flight", async () => {
    installFakeLocks();
    const intervals = captureIntervals();
    let heartbeatCount = 0;
    let resolveHeartbeat: ((response: Response) => void) | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "single-flight-lease", expiresInSeconds: 30 });
        }
        if (path === "/api/v1/control/heartbeat") {
          heartbeatCount += 1;
          if (heartbeatCount === 1) {
            return new Promise<Response>((resolve) => {
              resolveHeartbeat = resolve;
            });
          }
          return jsonResponse({ expiresInSeconds: 30 });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => expect(intervals.heartbeatHandlers).toHaveLength(1));

    act(() => {
      window.dispatchEvent(new Event("focus"));
      window.dispatchEvent(new Event("focus"));
    });
    expect(heartbeatCount).toBe(1);
    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();

    await act(async () => {
      resolveHeartbeat?.(jsonResponse({ expiresInSeconds: 30 }));
      await Promise.resolve();
    });
    expect(screen.getByText("Control: owned")).toBeVisible();
    act(() => intervals.heartbeatHandlers[0]?.());
    await waitFor(() => expect(heartbeatCount).toBe(2));
  });

  it("does not let an older owned session read undo focus verification", async () => {
    installFakeLocks();
    const intervals = captureIntervals();
    let sessionReads = 0;
    let resolveOwnedSession: ((response: Response) => void) | null = null;
    let heartbeatStarted = false;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          sessionReads += 1;
          if (sessionReads === 1) {
            return jsonResponse({ authenticated: true, control: "available" });
          }
          return new Promise<Response>((resolve) => {
            resolveOwnedSession = resolve;
          });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "focus-proof-lease", expiresInSeconds: 30 });
        }
        if (path === "/api/v1/control/heartbeat") {
          heartbeatStarted = true;
          return new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener(
              "abort",
              () => reject(new DOMException("heartbeat aborted", "AbortError")),
              { once: true },
            );
          });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => {
      expect(intervals.periodicRefreshHandlers).toHaveLength(1);
      expect(intervals.heartbeatHandlers).toHaveLength(1);
    });

    act(() => intervals.periodicRefreshHandlers[0]?.());
    await waitFor(() => expect(resolveOwnedSession).not.toBeNull());
    act(() => window.dispatchEvent(new Event("focus")));
    expect(heartbeatStarted).toBe(true);
    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();

    await act(async () => {
      resolveOwnedSession?.(jsonResponse({ authenticated: true, control: "owned" }));
      await Promise.resolve();
    });
    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBe("focus-proof-lease");
  });

  it("does not restore control from an owned session response after the safe deadline", async () => {
    installFakeLocks();
    const intervals = captureIntervals();
    let wallTime = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => wallTime);
    let sessionReads = 0;
    let resolveOwnedSession: ((response: Response) => void) | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          sessionReads += 1;
          if (sessionReads === 1) {
            return jsonResponse({ authenticated: true, control: "available" });
          }
          return new Promise<Response>((resolve) => {
            resolveOwnedSession = resolve;
          });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "stale-proof-lease", expiresInSeconds: 1 });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => expect(intervals.periodicRefreshHandlers).toHaveLength(1));

    act(() => intervals.periodicRefreshHandlers[0]?.());
    await waitFor(() => expect(resolveOwnedSession).not.toBeNull());
    wallTime += 1_100;
    await act(async () => {
      resolveOwnedSession?.(jsonResponse({ authenticated: true, control: "owned" }));
      await Promise.resolve();
    });

    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBe("stale-proof-lease");
  });

  it("expires a late owned session proof at the existing local safe deadline", async () => {
    vi.useFakeTimers();
    installFakeLocks();
    let sessionReads = 0;
    let resolveOwnedSession: ((response: Response) => void) | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          sessionReads += 1;
          if (sessionReads === 1) {
            return jsonResponse({ authenticated: true, control: "available" });
          }
          return new Promise<Response>((resolve) => {
            resolveOwnedSession = resolve;
          });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "watchdog-session-lease", expiresInSeconds: 5 });
        }
        if (path === "/api/v1/control/heartbeat") {
          return new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener(
              "abort",
              () => reject(new DOMException("heartbeat aborted", "AbortError")),
              { once: true },
            );
          });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(screen.getByText("Control: owned")).toBeVisible();

    const pageshow = new Event("pageshow") as PageTransitionEvent;
    Object.defineProperty(pageshow, "persisted", { value: true });
    act(() => window.dispatchEvent(pageshow));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(resolveOwnedSession).not.toBeNull();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4_000);
      resolveOwnedSession?.(jsonResponse({ authenticated: true, control: "owned" }));
      await Promise.resolve();
    });
    expect(screen.getByText("Control: owned")).toBeVisible();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(751);
    });
    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBe("watchdog-session-lease");
  });

  it("fails closed when wall time passes the lease deadline during a monotonic-clock pause", async () => {
    const locks = installFakeLocks();
    const intervals = captureIntervals();
    let wallTime = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => wallTime);
    let resolveHeartbeat: ((response: Response) => void) | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "sleep-lease", expiresInSeconds: 1 });
        }
        if (path === "/api/v1/control/heartbeat") {
          return new Promise<Response>((resolve) => {
            resolveHeartbeat = resolve;
          });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => expect(intervals.heartbeatHandlers).toHaveLength(1));

    // Model macOS sleep: wall time advances beyond the lease while the
    // monotonic performance clock used by the page does not.
    wallTime += 1_100;
    act(() => intervals.heartbeatHandlers[0]?.());
    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBe("sleep-lease");
    expect(locks.isHeld()).toBe(true);

    await act(async () => {
      resolveHeartbeat?.(jsonResponse({ expiresInSeconds: 1 }));
      await Promise.resolve();
    });
    expect(screen.getByText("This browser has scanner control")).toBeVisible();
    expect(screen.getByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("sleep-lease");
  });

  it("does not restore control when a heartbeat 200 settles after its safe deadline", async () => {
    const locks = installFakeLocks();
    const intervals = captureIntervals();
    let wallTime = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => wallTime);
    let resolveHeartbeat: ((response: Response) => void) | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "late-heartbeat-lease", expiresInSeconds: 1 });
        }
        if (path === "/api/v1/control/heartbeat") {
          return new Promise<Response>((resolve) => {
            resolveHeartbeat = resolve;
          });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => expect(intervals.heartbeatHandlers).toHaveLength(1));

    act(() => intervals.heartbeatHandlers[0]?.());
    await waitFor(() => expect(resolveHeartbeat).not.toBeNull());
    wallTime += 1_100;
    await act(async () => {
      resolveHeartbeat?.(jsonResponse({ expiresInSeconds: 1 }));
      await Promise.resolve();
    });

    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(
      screen.getByText("Scanner control renewal is overdue; verifying before continuing."),
    ).toBeVisible();
    expect(getControlLeaseToken()).toBe("late-heartbeat-lease");
    expect(locks.isHeld()).toBe(true);
  });

  it("expires a late heartbeat 200 at its renewed local safe deadline", async () => {
    vi.useFakeTimers();
    const locks = installFakeLocks();
    let resolveHeartbeat: ((response: Response) => void) | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          return jsonResponse({ leaseToken: "watchdog-heartbeat-lease", expiresInSeconds: 5 });
        }
        if (path === "/api/v1/control/heartbeat") {
          return new Promise<Response>((resolve) => {
            resolveHeartbeat = resolve;
          });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(screen.getByText("Control: owned")).toBeVisible();

    act(() => window.dispatchEvent(new Event("focus")));
    expect(resolveHeartbeat).not.toBeNull();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4_000);
      resolveHeartbeat?.(jsonResponse({ expiresInSeconds: 5 }));
      await Promise.resolve();
    });
    expect(screen.getByText("Control: owned")).toBeVisible();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(751);
    });
    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBe("watchdog-heartbeat-lease");
    expect(locks.isHeld()).toBe(true);
  });

  it("times out a stalled heartbeat and recovers before the granted lease expires", async () => {
    const locks = installFakeLocks();
    const intervals = captureIntervals();
    let claimCount = 0;
    let heartbeatCount = 0;
    let stalledHeartbeatAborted = false;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          return jsonResponse({ authenticated: true, control: "available" });
        }
        if (path === "/api/v1/control/claim") {
          claimCount += 1;
          return jsonResponse({ leaseToken: "stalled-lease", expiresInSeconds: 1 });
        }
        if (path === "/api/v1/control/heartbeat") {
          heartbeatCount += 1;
          if (heartbeatCount === 1) {
            return new Promise<Response>((_resolve, reject) => {
              init?.signal?.addEventListener(
                "abort",
                () => {
                  stalledHeartbeatAborted = true;
                  reject(new DOMException("heartbeat timed out", "AbortError"));
                },
                { once: true },
              );
            });
          }
          return jsonResponse({ expiresInSeconds: 1 });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => expect(intervals.heartbeatHandlers).toHaveLength(1));

    vi.useFakeTimers();
    act(() => intervals.heartbeatHandlers[0]?.());
    expect(screen.getByText("Control: owned")).toBeVisible();
    await act(async () => {
      // A one-second grant times the stalled request out before the next
      // heartbeat tick, well before the server-side lease can expire.
      await vi.advanceTimersByTimeAsync(334);
    });
    expect(stalledHeartbeatAborted).toBe(true);
    expect(screen.getByText("Verifying scanner control…")).toBeVisible();
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBe("stalled-lease");
    expect(locks.isHeld()).toBe(true);

    await act(async () => {
      intervals.heartbeatHandlers[0]?.();
      await Promise.resolve();
    });
    expect(screen.getByText("This browser has scanner control")).toBeVisible();
    expect(screen.getByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("stalled-lease");
    expect(heartbeatCount).toBe(2);
    expect(claimCount).toBe(1);
  });

  it("sends a same-origin keepalive release with the page-scoped token on pagehide", async () => {
    const locks = installFakeLocks();
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input);
      if (path === "/api/v1/session") {
        return jsonResponse({ authenticated: true, control: "available" });
      }
      if (path === "/api/v1/control/claim") {
        return jsonResponse({ leaseToken: "pagehide-lease", expiresInSeconds: 30 });
      }
      if (path === "/api/v1/control/release") {
        return jsonResponse({ released: true });
      }
      throw new Error(`unexpected request ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();

    act(() => window.dispatchEvent(new Event("pagehide")));
    expect(fetchMock).toHaveBeenCalledWith("/api/v1/control/release", {
      method: "POST",
      credentials: "same-origin",
      headers: { "X-ScanStudio-Control-Lease": "pagehide-lease" },
      keepalive: true,
    });
    expect(getControlLeaseToken()).toBeNull();
    await waitFor(() => expect(locks.isHeld()).toBe(false));
  });

  it("refreshes and reclaims immediately after a persisted page is restored", async () => {
    const locks = installFakeLocks();
    const intervals = captureIntervals();
    let sessionReads = 0;
    let claimCount = 0;
    let released = false;
    let resolveStaleSession: ((response: Response) => void) | null = null;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const path = String(input);
        if (path === "/api/v1/session") {
          sessionReads += 1;
          if (sessionReads === 1) {
            return jsonResponse({ authenticated: true, control: "available" });
          }
          if (sessionReads === 2) {
            return new Promise<Response>((resolve) => {
              resolveStaleSession = resolve;
            });
          }
          return jsonResponse({
            authenticated: true,
            control: released ? "available" : "observer",
          });
        }
        if (path === "/api/v1/control/claim") {
          claimCount += 1;
          return jsonResponse({
            leaseToken: claimCount === 1 ? "cached-page-lease" : "restored-page-lease",
            expiresInSeconds: 30,
          });
        }
        if (path === "/api/v1/control/release") {
          released = true;
          return jsonResponse({ released: true });
        }
        throw new Error(`unexpected request ${path}`);
      }),
    );

    render(
      <WebRuntimeGate>
        <ControlProbe />
      </WebRuntimeGate>,
    );
    markEventStreamReady();
    expect(await screen.findByText("Control: owned")).toBeVisible();
    await waitFor(() => expect(intervals.periodicRefreshHandlers).toHaveLength(1));

    act(() => intervals.periodicRefreshHandlers[0]?.());
    await waitFor(() => expect(resolveStaleSession).not.toBeNull());
    const pagehide = new Event("pagehide") as PageTransitionEvent;
    Object.defineProperty(pagehide, "persisted", { value: true });
    act(() => window.dispatchEvent(pagehide));
    expect(screen.getByText("Control: observer")).toBeVisible();
    expect(getControlLeaseToken()).toBeNull();
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(locks.isHeld()).toBe(false);

    const pageshow = new Event("pageshow") as PageTransitionEvent;
    Object.defineProperty(pageshow, "persisted", { value: true });
    act(() => window.dispatchEvent(pageshow));
    expect(await screen.findByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("restored-page-lease");
    expect(sessionReads).toBe(3);
    expect(claimCount).toBe(2);

    await act(async () => {
      resolveStaleSession?.(jsonResponse({ authenticated: true, control: "owned" }));
      await Promise.resolve();
    });
    expect(screen.getByText("Control: owned")).toBeVisible();
    expect(getControlLeaseToken()).toBe("restored-page-lease");
  });
});
