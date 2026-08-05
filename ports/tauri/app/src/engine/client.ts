import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export interface EngineError {
  code: string;
  message: string;
  recoverable: boolean;
}

export async function engineRequest<T = unknown>(
  method: string,
  params: unknown = {},
): Promise<T> {
  return invoke<T>("engine_request", { method, params });
}

export async function engineState(): Promise<{ running: boolean; pid: number | null }> {
  return invoke("engine_state");
}

export function onEngineEvent(handler: (payload: unknown) => void): Promise<UnlistenFn> {
  return listen<unknown>("engine://event", (e) => handler(e.payload));
}
