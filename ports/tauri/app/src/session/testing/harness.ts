// Dual-mode test harness: drives the session store against either the real
// engine subprocess (integration mode, SCANSTUDIO_ENGINE_PATH) or fully
// scripted event/response streams (fixture mode). Both transports satisfy the
// identical EngineTransport contract from wire/codec.ts. Test-only
// infrastructure: the harness owns request-id assignment here, unlike the
// production Tauri path where the Rust side owns ids.

import { spawn } from "node:child_process";
import { createInterface, type Interface as ReadlineInterface } from "node:readline";
import { decodeEnvelope, type EngineTransport } from "../wire/codec";
import type { EngineError } from "../wire/types";

const DEFAULT_REQUEST_TIMEOUT_MS = 5000;
const SHUTDOWN_GRACE_MS = 2000;

export interface SubprocessTransportOptions {
  engineBinaryPath: string;
  // Convenience for callers: the value to pass in scanner.connect's options.
  // The engine only accepts timeScale via scanner.connect, not at spawn time,
  // so the harness never sends it itself.
  timeScale?: number;
  // Bounded per-request timeout so a hung engine cannot hang the test suite.
  timeoutMs?: number;
}

export interface SubprocessTransportHandle {
  transport: EngineTransport;
  close(): Promise<void>;
  timeScale: number;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}

export async function createSubprocessTransport(
  opts: SubprocessTransportOptions,
): Promise<SubprocessTransportHandle> {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
  const child = spawn(opts.engineBinaryPath, [], {
    stdio: ["pipe", "pipe", "inherit"],
  });

  await new Promise<void>((resolve, reject) => {
    child.once("spawn", () => resolve());
    child.once("error", (error) =>
      reject(new Error(`failed to start engine binary "${opts.engineBinaryPath}": ${error.message}`)),
    );
  });

  let nextId = 1;
  let closed = false;
  const pending = new Map<number, PendingRequest>();
  const subscribers = new Set<(raw: unknown) => void>();

  const failAllPending = (error: Error): void => {
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    pending.clear();
  };

  const readline: ReadlineInterface = createInterface({ input: child.stdout });
  readline.on("line", (line) => {
    let raw: unknown;
    try {
      raw = JSON.parse(line);
    } catch {
      return;
    }
    const decoded = decodeEnvelope(raw);
    if (decoded.kind === "responseSuccess" || decoded.kind === "responseError") {
      const entry = pending.get(decoded.value.id);
      if (!entry) return;
      pending.delete(decoded.value.id);
      clearTimeout(entry.timer);
      if (decoded.kind === "responseSuccess") {
        entry.resolve(decoded.value.result);
      } else {
        entry.reject(decoded.value.error);
      }
      return;
    }
    if (decoded.kind === "event") {
      for (const callback of [...subscribers]) {
        callback(raw);
      }
    }
  });

  child.on("error", (error) => {
    failAllPending(new Error(`engine subprocess error: ${error.message}`));
  });
  child.on("exit", () => {
    failAllPending(new Error("engine subprocess exited before responding"));
  });

  const transport: EngineTransport = {
    sendRequest(method: string, params?: unknown): Promise<unknown> {
      if (closed) {
        return Promise.reject(new Error("transport is closed"));
      }
      const id = nextId++;
      return new Promise<unknown>((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`engine request "${method}" (id ${id}) timed out after ${timeoutMs}ms`));
        }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
        child.stdin.write(JSON.stringify({ id, method, params }) + "\n", (error) => {
          if (error) {
            const entry = pending.get(id);
            if (entry) {
              pending.delete(id);
              clearTimeout(entry.timer);
              entry.reject(error);
            }
          }
        });
      });
    },
    subscribeEvents(callback: (raw: unknown) => void): () => void {
      subscribers.add(callback);
      return () => {
        subscribers.delete(callback);
      };
    },
  };

  const close = async (): Promise<void> => {
    if (closed) return;
    closed = true;
    if (child.exitCode === null && child.signalCode === null) {
      try {
        child.stdin.write(
          JSON.stringify({ id: nextId++, method: "engine.shutdown", params: {} }) + "\n",
        );
      } catch {
        // Child already gone; fall through to the bounded exit wait.
      }
      await new Promise<void>((resolve) => {
        if (child.exitCode !== null || child.signalCode !== null) {
          resolve();
          return;
        }
        const timer = setTimeout(() => {
          child.off("exit", onExit);
          resolve();
        }, SHUTDOWN_GRACE_MS);
        const onExit = (): void => {
          clearTimeout(timer);
          resolve();
        };
        child.once("exit", onExit);
      });
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGKILL");
      }
    }
    failAllPending(new Error("transport closed"));
    readline.close();
  };

  return { transport, close, timeScale: opts.timeScale ?? 0.01 };
}

export interface ScriptedRequestOutcome {
  result?: unknown;
  error?: EngineError;
}

export interface ScriptedTransportHandle {
  transport: EngineTransport;
  emitEvent(raw: unknown): void;
}

export function createScriptedTransport(script?: {
  onRequest?: (method: string, params: unknown) => ScriptedRequestOutcome;
}): ScriptedTransportHandle {
  const subscribers = new Set<(raw: unknown) => void>();
  const transport: EngineTransport = {
    async sendRequest(method: string, params?: unknown): Promise<unknown> {
      if (!script?.onRequest) return undefined;
      const outcome = script.onRequest(method, params);
      if (outcome.error) throw outcome.error;
      return outcome.result;
    },
    subscribeEvents(callback: (raw: unknown) => void): () => void {
      subscribers.add(callback);
      return () => {
        subscribers.delete(callback);
      };
    },
  };
  return {
    transport,
    emitEvent(raw: unknown): void {
      for (const callback of [...subscribers]) {
        callback(raw);
      }
    },
  };
}
