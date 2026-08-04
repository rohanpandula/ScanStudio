import * as client from "../../engine/client";
import type {
  EngineError,
  WireEvent,
  WireRequest,
  WireResponseError,
  WireResponseSuccess,
} from "./types";
import { isEngineError } from "./types";

export interface EngineTransport {
  sendRequest(method: string, params?: unknown): Promise<unknown>;
  subscribeEvents(callback: (raw: unknown) => void): () => void;
}

export type DecodedEnvelope =
  | { kind: "request"; value: WireRequest }
  | { kind: "responseSuccess"; value: WireResponseSuccess }
  | { kind: "responseError"; value: WireResponseError }
  | { kind: "event"; value: WireEvent }
  | { kind: "unknown" };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function decodeEnvelope(raw: unknown): DecodedEnvelope {
  if (!isRecord(raw)) return { kind: "unknown" };
  if (typeof raw.id === "number" && typeof raw.method === "string") {
    return { kind: "request", value: raw as unknown as WireRequest };
  }
  if (typeof raw.id === "number" && "result" in raw) {
    return { kind: "responseSuccess", value: raw as unknown as WireResponseSuccess };
  }
  if (typeof raw.id === "number" && "error" in raw && isEngineError(raw.error)) {
    return { kind: "responseError", value: raw as unknown as WireResponseError };
  }
  if (typeof raw.event === "string" && "payload" in raw) {
    return { kind: "event", value: raw as unknown as WireEvent };
  }
  return { kind: "unknown" };
}

export function decodeResponse(
  raw: unknown,
): { ok: true; result: unknown } | { ok: false; error: EngineError } {
  const decoded = decodeEnvelope(raw);
  if (decoded.kind === "responseSuccess") {
    return { ok: true, result: decoded.value.result };
  }
  if (decoded.kind === "responseError") {
    return { ok: false, error: decoded.value.error };
  }
  return {
    ok: false,
    error: { code: "INTERNAL", message: "unrecognized response envelope", recoverable: false },
  };
}

export function decodeEvent(raw: unknown): WireEvent | null {
  const decoded = decodeEnvelope(raw);
  return decoded.kind === "event" ? decoded.value : null;
}

function toEngineError(error: unknown): EngineError {
  if (isEngineError(error)) return error;
  if (typeof error === "string") {
    return { code: "INTERNAL", message: error, recoverable: false };
  }
  if (isRecord(error) && typeof error.message === "string") {
    return { code: "INTERNAL", message: error.message, recoverable: false };
  }
  return { code: "INTERNAL", message: String(error), recoverable: false };
}

export function createClientTransport(): EngineTransport {
  return {
    async sendRequest(method: string, params?: unknown): Promise<unknown> {
      try {
        return await client.engineRequest(method, params ?? {});
      } catch (error) {
        throw toEngineError(error);
      }
    },
    subscribeEvents(callback: (raw: unknown) => void): () => void {
      let cancelled = false;
      const unlistenPromise = client.onEngineEvent((payload) => {
        if (typeof payload === "string") {
          try {
            callback(JSON.parse(payload));
          } catch {
            callback(payload);
          }
          return;
        }
        callback(payload);
      });
      return () => {
        if (cancelled) return;
        cancelled = true;
        void unlistenPromise.then((unlisten) => unlisten());
      };
    },
  };
}
