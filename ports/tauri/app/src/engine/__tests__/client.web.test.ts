/** @vitest-environment jsdom */
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  engineRequest,
  notifyWebSessionReady,
  onEngineEvent,
  WEB_CONTROL_LOST_EVENT,
} from "../client";
import {
  clearControlLeaseToken,
  getControlLeaseToken,
  setControlLeaseToken,
} from "../../controlLease";
import { SessionStore } from "../../session/store/session";
import type { EngineTransport } from "../../session/wire/codec";

afterEach(() => {
  clearControlLeaseToken();
  window.sessionStorage.clear();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("browser engine client", () => {
  it("forwards a request through the same-origin gateway and unwraps its result", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ result: { devices: [] } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(engineRequest("scanner.list", {})).resolves.toEqual({ devices: [] });
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/engine/request",
      expect.objectContaining({
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ method: "scanner.list", params: {} }),
      }),
    );
  });

  it("preserves a typed engine error from the gateway", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            error: {
              code: "SCANNER_BUSY",
              message: "a preview is active",
              recoverable: false,
            },
          }),
          { status: 409, headers: { "Content-Type": "application/json" } },
        ),
      ),
    );

    await expect(engineRequest("scanner.disconnect", {})).rejects.toEqual({
      code: "SCANNER_BUSY",
      message: "a preview is active",
      recoverable: false,
    });
  });

  it("sends the tab-scoped controller lease with engine requests", async () => {
    setControlLeaseToken("lease-for-this-tab");
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ result: {} }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await engineRequest("scanner.connect", { deviceId: "sim-ls5000-0" });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/engine/request",
      expect.objectContaining({
        headers: {
          "Content-Type": "application/json",
          "X-ScanStudio-Control-Lease": "lease-for-this-tab",
        },
      }),
    );
  });

  it("drops local control immediately when the gateway rejects an expired lease", async () => {
    setControlLeaseToken("expired-controller-lease");
    const controlLost = vi.fn();
    window.addEventListener(WEB_CONTROL_LOST_EVENT, controlLost);
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            error: {
              code: "CONTROL_LEASE_REQUIRED",
              message: "a current controller lease is required",
            },
          }),
          { status: 423, headers: { "Content-Type": "application/json" } },
        ),
      ),
    );

    await expect(engineRequest("scanner.connect", { deviceId: "sim-ls5000-0" }))
      .rejects.toMatchObject({ code: "CONTROL_LEASE_REQUIRED" });
    expect(getControlLeaseToken()).toBeNull();
    expect(controlLost).toHaveBeenCalledOnce();
    window.removeEventListener(WEB_CONTROL_LOST_EVENT, controlLost);
  });

  it("does not let a delayed stale-token 423 clear a replacement lease", async () => {
    setControlLeaseToken("stale-controller-lease");
    let resolveRequest!: (response: Response) => void;
    const pendingResponse = new Promise<Response>((resolve) => {
      resolveRequest = resolve;
    });
    const fetchMock = vi.fn().mockReturnValue(pendingResponse);
    const controlLost = vi.fn();
    window.addEventListener(WEB_CONTROL_LOST_EVENT, controlLost);
    vi.stubGlobal("fetch", fetchMock);

    const request = engineRequest("scanner.connect", { deviceId: "sim-ls5000-0" });
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
    setControlLeaseToken("replacement-controller-lease");
    resolveRequest(
      new Response(
        JSON.stringify({
          error: {
            code: "CONTROL_LEASE_REQUIRED",
            message: "the old controller lease expired",
          },
        }),
        { status: 423, headers: { "Content-Type": "application/json" } },
      ),
    );

    await expect(request).rejects.toMatchObject({ code: "CONTROL_LEASE_REQUIRED" });
    expect(getControlLeaseToken()).toBe("replacement-controller-lease");
    expect(controlLost).not.toHaveBeenCalled();
    window.removeEventListener(WEB_CONTROL_LOST_EVENT, controlLost);
  });

  it("never presents a controller lease copied through sessionStorage", async () => {
    window.sessionStorage.setItem("scanstudio.control-lease", "copied-tab-lease");
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ result: {} }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await engineRequest("scanner.connect", { deviceId: "sim-ls5000-0" });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/engine/request",
      expect.objectContaining({
        headers: { "Content-Type": "application/json" },
      }),
    );
  });

  it("delivers WebSocket event envelopes and closes cleanly", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            error: {
              code: "NOT_CONNECTED",
              message: "no scanner is connected",
              recoverable: true,
            },
          }),
          { status: 409, headers: { "Content-Type": "application/json" } },
        ),
      ),
    );
    class FakeWebSocket {
      static instance: FakeWebSocket | null = null;
      listeners = new Map<string, Array<(event: { data?: unknown }) => void>>();
      close = vi.fn();

      constructor(readonly url: string) {
        FakeWebSocket.instance = this;
      }

      addEventListener(name: string, listener: (event: { data?: unknown }) => void): void {
        const current = this.listeners.get(name) ?? [];
        current.push(listener);
        this.listeners.set(name, current);
      }

      emit(name: string, event: { data?: unknown } = {}): void {
        for (const listener of this.listeners.get(name) ?? []) listener(event);
      }
    }
    vi.stubGlobal("WebSocket", FakeWebSocket);
    const handler = vi.fn();

    const unlisten = await onEngineEvent(handler);
    notifyWebSessionReady();
    FakeWebSocket.instance?.emit("open");
    await vi.waitFor(() => {
      expect(handler).toHaveBeenCalledWith({
        event: "scanstudio.webEventStream",
        payload: { state: "ready", engineConnected: false },
      });
    });
    FakeWebSocket.instance?.emit("message", {
      data: JSON.stringify({ event: "scanner.thumbnailsComplete", payload: { count: 6 } }),
    });

    expect(handler).toHaveBeenCalledWith({
      event: "scanner.thumbnailsComplete",
      payload: { count: 6 },
    });
    unlisten();
    expect(FakeWebSocket.instance?.close).toHaveBeenCalledWith(1000, "client closed");
  });

  it("reconciles scanner status on open and reports a dropped event stream", async () => {
    const device = {
      deviceId: "sim-ls5000-0",
      model: "SUPER COOLSCAN 5000 ED",
      kind: "simulated",
      firmware: "1.03-sim",
      connection: "USB (simulated)",
      supported: true,
    };
    const status = {
      connected: true,
      adapter: null,
      mediaLoaded: true,
      carrier: "strip6",
      frameCount: 6,
      lamp: "stable",
      transport: "idle",
      activeJobId: null,
    };
    vi.stubGlobal("fetch", vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      const request = JSON.parse(String(init?.body)) as { method: string };
      const result = request.method === "scanner.list" ? { devices: [device] } : status;
      return new Response(JSON.stringify({ result }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }));

    class FakeWebSocket {
      static instance: FakeWebSocket | null = null;
      listeners = new Map<string, Array<(event: { code?: number; data?: unknown }) => void>>();
      close = vi.fn();

      constructor(readonly url: string) {
        FakeWebSocket.instance = this;
      }

      addEventListener(
        name: string,
        listener: (event: { code?: number; data?: unknown }) => void,
      ): void {
        const current = this.listeners.get(name) ?? [];
        current.push(listener);
        this.listeners.set(name, current);
      }

      emit(name: string, event: { code?: number; data?: unknown } = {}): void {
        for (const listener of this.listeners.get(name) ?? []) listener(event);
      }
    }
    vi.stubGlobal("WebSocket", FakeWebSocket);
    const handler = vi.fn();

    const unlisten = await onEngineEvent(handler);
    notifyWebSessionReady();
    FakeWebSocket.instance?.emit("open");

    await vi.waitFor(() => {
      expect(handler).toHaveBeenCalledWith({
        event: "scanstudio.webEventStream",
        payload: {
          state: "ready",
          engineConnected: true,
          device,
          status,
        },
      });
    });

    FakeWebSocket.instance?.emit("close", { code: 1006 });
    expect(handler).toHaveBeenLastCalledWith({
      event: "scanstudio.webEventStream",
      payload: { state: "disconnected" },
    });
    unlisten();
  });

  it("commits the reconnect snapshot before replaying live events received during hydration", async () => {
    const device = {
      deviceId: "sim-ls5000-0",
      model: "SUPER COOLSCAN 5000 ED",
      kind: "simulated",
      firmware: "1.03-sim",
      connection: "USB (simulated)",
      supported: true,
    };
    const snapshotStatus = {
      connected: true,
      adapter: null,
      mediaLoaded: true,
      carrier: "roll36",
      frameCount: 36,
      lamp: "stable",
      transport: "idle",
      activeJobId: null,
    };
    const liveStatus = {
      ...snapshotStatus,
      carrier: "strip6",
      frameCount: 6,
    };
    let resolveStatus!: (response: Response) => void;
    const pendingStatus = new Promise<Response>((resolve) => {
      resolveStatus = resolve;
    });
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      const request = JSON.parse(String(init?.body)) as { method: string };
      if (request.method === "scanner.list") {
        return new Response(JSON.stringify({ result: { devices: [device] } }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return pendingStatus;
    });
    vi.stubGlobal("fetch", fetchMock);

    class FakeWebSocket {
      static instance: FakeWebSocket | null = null;
      listeners = new Map<string, Array<(event: { code?: number; data?: unknown }) => void>>();
      close = vi.fn();

      constructor(readonly url: string) {
        FakeWebSocket.instance = this;
      }

      addEventListener(
        name: string,
        listener: (event: { code?: number; data?: unknown }) => void,
      ): void {
        const current = this.listeners.get(name) ?? [];
        current.push(listener);
        this.listeners.set(name, current);
      }

      emit(name: string, event: { code?: number; data?: unknown } = {}): void {
        for (const listener of this.listeners.get(name) ?? []) listener(event);
      }
    }
    vi.stubGlobal("WebSocket", FakeWebSocket);
    const handler = vi.fn();

    const unlisten = await onEngineEvent(handler);
    notifyWebSessionReady();
    FakeWebSocket.instance?.emit("open");
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));

    const liveEvent = { event: "scanner.status", payload: { status: liveStatus } };
    FakeWebSocket.instance?.emit("message", { data: JSON.stringify(liveEvent) });
    expect(handler).not.toHaveBeenCalledWith(liveEvent);

    resolveStatus(
      new Response(JSON.stringify({ result: snapshotStatus }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await vi.waitFor(() => expect(handler).toHaveBeenCalledTimes(4));
    expect(handler).toHaveBeenNthCalledWith(2, {
      event: "scanstudio.webEventStream",
      payload: {
        state: "ready",
        engineConnected: true,
        device,
        status: snapshotStatus,
      },
    });
    expect(handler).toHaveBeenNthCalledWith(3, liveEvent);
    expect(handler).toHaveBeenNthCalledWith(4, {
      event: "scanstudio.webEventStream",
      payload: {
        state: "ready",
        engineConnected: true,
        device,
        status: liveStatus,
      },
    });
    unlisten();
  });

  it("reconciles singleton observer stores after another tab connects and disconnects", async () => {
    const device = {
      deviceId: "sim-ls5000-0",
      model: "SUPER COOLSCAN 5000 ED",
      kind: "simulated" as const,
      firmware: "1.03-sim",
      connection: "USB (simulated)",
      supported: true,
    };
    const connectedStatus = {
      connected: true,
      adapter: null,
      mediaLoaded: false,
      carrier: null,
      frameCount: null,
      lamp: "stable" as const,
      transport: "idle" as const,
      activeJobId: null,
    };
    const disconnectedStatus = {
      ...connectedStatus,
      connected: false,
      lamp: "off" as const,
    };
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
        const request = JSON.parse(String(init?.body)) as { method: string };
        if (request.method === "scanner.list") {
          return new Response(JSON.stringify({ result: { devices: [device] } }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        return new Response(
          JSON.stringify({
            error: {
              code: "NOT_CONNECTED",
              message: "no scanner is connected",
              recoverable: true,
            },
          }),
          { status: 409, headers: { "Content-Type": "application/json" } },
        );
      }),
    );

    class FakeWebSocket {
      static instance: FakeWebSocket | null = null;
      listeners = new Map<string, Array<(event: { code?: number; data?: unknown }) => void>>();
      close = vi.fn();

      constructor(readonly url: string) {
        FakeWebSocket.instance = this;
      }

      addEventListener(
        name: string,
        listener: (event: { code?: number; data?: unknown }) => void,
      ): void {
        const current = this.listeners.get(name) ?? [];
        current.push(listener);
        this.listeners.set(name, current);
      }

      emit(name: string, event: { code?: number; data?: unknown } = {}): void {
        for (const listener of this.listeners.get(name) ?? []) listener(event);
      }
    }
    vi.stubGlobal("WebSocket", FakeWebSocket);

    const subscribers = new Set<(raw: unknown) => void>();
    const transport: EngineTransport = {
      async sendRequest(method: string): Promise<unknown> {
        if (method === "scanner.connect") return { device, status: connectedStatus };
        if (method === "scanner.disconnect") return {};
        return undefined;
      },
      subscribeEvents(callback): () => void {
        subscribers.add(callback);
        return () => subscribers.delete(callback);
      },
    };
    const controller = new SessionStore(transport);
    const observer = new SessionStore(transport);
    const delivered: unknown[] = [];
    const unlisten = await onEngineEvent((raw) => {
      delivered.push(raw);
      for (const subscriber of [...subscribers]) subscriber(raw);
    });
    notifyWebSessionReady();
    FakeWebSocket.instance?.emit("open");
    await vi.waitFor(() => {
      expect(delivered).toContainEqual({
        event: "scanstudio.webEventStream",
        payload: { state: "ready", engineConnected: false },
      });
    });

    await controller.connect(device.deviceId);
    expect(controller.getState().connection.device).toEqual(device);
    expect(observer.getState().connection.device).toBeNull();

    FakeWebSocket.instance?.emit("message", {
      data: JSON.stringify({ event: "scanner.status", payload: { status: connectedStatus } }),
    });
    expect(observer.getState().connection).toEqual({
      connected: true,
      device,
      status: connectedStatus,
    });

    await controller.disconnect();
    expect(controller.getState().connection.connected).toBe(false);
    expect(observer.getState().connection.connected).toBe(true);

    FakeWebSocket.instance?.emit("message", {
      data: JSON.stringify({ event: "scanner.status", payload: { status: disconnectedStatus } }),
    });
    expect(observer.getState().connection).toEqual({
      connected: false,
      device: null,
      status: null,
    });
    unlisten();
  });
});
