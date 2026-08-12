import { isTauriRuntime } from "../runtime";
import {
  clearControlLeaseToken,
  CONTROL_LEASE_HEADER,
  controlLeaseHeaders,
  getControlLeaseToken,
} from "../controlLease";

export interface EngineError {
  code: string;
  message: string;
  recoverable: boolean;
}

export type UnlistenFn = () => void;

const WEB_REQUEST_ENDPOINT = "/api/v1/engine/request";
const WEB_EVENT_ENDPOINT = "/api/v1/engine/events";
const WEB_SESSION_READY_EVENT = "scanstudio:web-session-ready";
export const WEB_HYDRATION_TIMEOUT_MS = 10_000;
export const WEB_HYDRATION_EVENT_LIMIT = 1_024;
export const WEB_EVENT_STREAM_STATE_EVENT = "scanstudio:web-event-stream-state";
export const WEB_CONTROL_LOST_EVENT = "scanstudio:web-control-lost";

export interface WebEventStreamState {
  ready: boolean;
  message: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asEngineError(value: unknown, fallback: string): EngineError {
  if (
    typeof value === "object" &&
    value !== null &&
    "code" in value &&
    typeof value.code === "string" &&
    "message" in value &&
    typeof value.message === "string"
  ) {
    return {
      code: value.code,
      message: value.message,
      recoverable:
        "recoverable" in value && typeof value.recoverable === "boolean"
          ? value.recoverable
          : false,
    };
  }
  return { code: "INTERNAL", message: fallback, recoverable: false };
}

async function webRequest<T>(
  method: string,
  params: unknown,
  signal?: AbortSignal,
): Promise<T> {
  const leaseHeaders = controlLeaseHeaders();
  const submittedLeaseToken = leaseHeaders[CONTROL_LEASE_HEADER] ?? null;
  let response: Response;
  try {
    response = await fetch(WEB_REQUEST_ENDPOINT, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", ...leaseHeaders },
      body: JSON.stringify({ method, params }),
      signal,
    });
  } catch (error) {
    throw asEngineError(
      error,
      "The ScanStudio server could not be reached. Check the server and try again.",
    );
  }

  if (
    response.status === 423 &&
    submittedLeaseToken !== null &&
    getControlLeaseToken() === submittedLeaseToken
  ) {
    // The server is the lease authority. Fail closed immediately instead of
    // leaving the UI enabled until a background-throttled heartbeat runs.
    clearControlLeaseToken();
    window.dispatchEvent(new Event(WEB_CONTROL_LOST_EVENT));
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw asEngineError(
      null,
      `The ScanStudio server returned an unreadable response (${response.status}).`,
    );
  }

  if (
    typeof payload === "object" &&
    payload !== null &&
    "error" in payload
  ) {
    const engineError = asEngineError(
      payload.error,
      `The engine request failed (${response.status}).`,
    );
    throw engineError;
  }
  if (!response.ok) {
    throw asEngineError(
      payload,
      `The ScanStudio server refused the request (${response.status}).`,
    );
  }
  if (
    typeof payload !== "object" ||
    payload === null ||
    !("result" in payload)
  ) {
    throw asEngineError(null, "The ScanStudio server response did not contain a result.");
  }
  return payload.result as T;
}

function webSocketUrl(): string {
  const url = new URL(WEB_EVENT_ENDPOINT, window.location.href);
  url.protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return url.toString();
}

function publishWebEventStreamState(ready: boolean, message: string | null = null): void {
  window.dispatchEvent(
    new CustomEvent<WebEventStreamState>(WEB_EVENT_STREAM_STATE_EVENT, {
      detail: { ready, message },
    }),
  );
}

function listenToWebEvents(handler: (payload: unknown) => void): UnlistenFn {
  let socket: WebSocket | null = null;
  let retryTimer: number | null = null;
  let stopped = false;
  let retryDelayMs = 500;
  let singletonDevice: unknown = null;
  let abortActiveHydration: (() => void) | null = null;

  const deliver = (payload: unknown): void => {
    handler(payload);
    if (
      !isRecord(payload) ||
      payload.event !== "scanner.status" ||
      !isRecord(payload.payload) ||
      !isRecord(payload.payload.status) ||
      typeof payload.payload.status.connected !== "boolean"
    ) {
      return;
    }
    const status = payload.payload.status;
    if (status.connected === false) {
      handler({
        event: "scanstudio.webEventStream",
        payload: { state: "ready", engineConnected: false },
      });
    } else if (singletonDevice !== null) {
      handler({
        event: "scanstudio.webEventStream",
        payload: {
          state: "ready",
          engineConnected: true,
          device: singletonDevice,
          status,
        },
      });
    }
  };

  const markDisconnected = (): void => {
    handler({
      event: "scanstudio.webEventStream",
      payload: { state: "disconnected" },
    });
    publishWebEventStreamState(
      false,
      "Reconnecting to the scanner event stream…",
    );
  };

  const connect = (): void => {
    if (stopped || socket !== null) return;
    const candidate = new WebSocket(webSocketUrl());
    const pendingEvents: unknown[] = [];
    let hydrating = true;
    let hydrationFailed = false;
    let hydrationController: AbortController | null = null;
    let hydrationTimer: number | null = null;
    socket = candidate;
    const cancelHydration = (): void => {
      if (hydrationTimer !== null) {
        window.clearTimeout(hydrationTimer);
        hydrationTimer = null;
      }
      hydrationController?.abort();
      hydrationController = null;
      if (abortActiveHydration === cancelHydration) abortActiveHydration = null;
    };
    abortActiveHydration = cancelHydration;
    const failHydration = (message: string, reason: string): void => {
      if (!hydrating || stopped || socket !== candidate) return;
      hydrating = false;
      hydrationFailed = true;
      pendingEvents.splice(0);
      cancelHydration();
      publishWebEventStreamState(false, message);
      candidate.close(1011, reason);
    };
    const commitHydration = (snapshot: unknown): void => {
      if (!hydrating || stopped || socket !== candidate) return;
      handler(snapshot);
      if (stopped || socket !== candidate) return;
      hydrating = false;
      for (const pending of pendingEvents.splice(0)) deliver(pending);
      publishWebEventStreamState(true);
    };
    candidate.addEventListener("open", () => {
      retryDelayMs = 500;
      const controller = new AbortController();
      hydrationController = controller;
      hydrationTimer = window.setTimeout(
        () => controller.abort(),
        WEB_HYDRATION_TIMEOUT_MS,
      );
      void (async () => {
        try {
          const listed = await webRequest<{ devices?: unknown }>(
            "scanner.list",
            {},
            controller.signal,
          );
          if (!Array.isArray(listed.devices) || listed.devices.length !== 1) {
            throw new Error("The scanner inventory could not be restored.");
          }
          singletonDevice = listed.devices[0];
          const status = await webRequest<unknown>(
            "scanner.status",
            {},
            controller.signal,
          );
          if (stopped || socket !== candidate) return;
          commitHydration({
            event: "scanstudio.webEventStream",
            payload: {
              state: "ready",
              engineConnected: true,
              device: listed.devices[0],
              status,
            },
          });
        } catch (error) {
          if (stopped || socket !== candidate) return;
          const engineError = asEngineError(error, "The scanner state could not be restored.");
          if (engineError.code === "NOT_CONNECTED") {
            commitHydration({
              event: "scanstudio.webEventStream",
              payload: { state: "ready", engineConnected: false },
            });
            return;
          }
          failHydration(
            "Scanner state could not be restored; reconnecting…",
            "state reconciliation failed",
          );
        } finally {
          cancelHydration();
        }
      })();
    });
    candidate.addEventListener("message", (event) => {
      let payload: unknown;
      try {
        payload = JSON.parse(String(event.data));
      } catch {
        payload = event.data;
      }
      if (hydrationFailed) return;
      if (hydrating) {
        if (pendingEvents.length >= WEB_HYDRATION_EVENT_LIMIT) {
          failHydration(
            "Scanner event reconciliation overflowed; reconnecting…",
            "state reconciliation overflow",
          );
          return;
        }
        pendingEvents.push(payload);
      } else deliver(payload);
    });
    candidate.addEventListener("close", (event) => {
      if (socket !== candidate) return;
      cancelHydration();
      socket = null;
      if (stopped) return;
      markDisconnected();
      if (event.code === 4401 || event.code === 4403) return;
      retryTimer = window.setTimeout(connect, retryDelayMs);
      retryDelayMs = Math.min(retryDelayMs * 2, 10_000);
    });
  };

  const sessionReady = (): void => {
    if (retryTimer !== null) {
      window.clearTimeout(retryTimer);
      retryTimer = null;
    }
    retryDelayMs = 500;
    connect();
  };
  markDisconnected();
  window.addEventListener(WEB_SESSION_READY_EVENT, sessionReady);
  return () => {
    stopped = true;
    window.removeEventListener(WEB_SESSION_READY_EVENT, sessionReady);
    if (retryTimer !== null) window.clearTimeout(retryTimer);
    abortActiveHydration?.();
    socket?.close(1000, "client closed");
    socket = null;
  };
}

export function notifyWebSessionReady(): void {
  if (typeof window !== "undefined") {
    window.dispatchEvent(new Event(WEB_SESSION_READY_EVENT));
  }
}

export async function engineRequest<T = unknown>(
  method: string,
  params: unknown = {},
): Promise<T> {
  if (!isTauriRuntime()) return webRequest<T>(method, params);
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>("engine_request", { method, params });
}

export async function engineState(): Promise<{ running: boolean; pid: number | null }> {
  if (!isTauriRuntime()) {
    const response = await fetch("/healthz", { credentials: "same-origin" });
    if (!response.ok) return { running: false, pid: null };
    const payload = (await response.json()) as { engine?: { running?: boolean; pid?: number | null } };
    return {
      running: payload.engine?.running === true,
      pid: payload.engine?.pid ?? null,
    };
  }
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke("engine_state");
}

export function onEngineEvent(handler: (payload: unknown) => void): Promise<UnlistenFn> {
  if (!isTauriRuntime()) return Promise.resolve(listenToWebEvents(handler));
  return import("@tauri-apps/api/event").then(({ listen }) =>
    listen<unknown>("engine://event", (event) => handler(event.payload)),
  );
}
