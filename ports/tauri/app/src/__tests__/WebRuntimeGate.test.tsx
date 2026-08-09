/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import WebRuntimeGate from "../WebRuntimeGate";
import { clearControlLeaseToken, getControlLeaseToken } from "../controlLease";
import { WEB_EVENT_STREAM_STATE_EVENT } from "../engine/client";
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

afterEach(() => {
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
});
