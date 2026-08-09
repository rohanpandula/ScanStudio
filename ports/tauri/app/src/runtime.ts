export function isTauriRuntime(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export function isWebRuntime(): boolean {
  return typeof window !== "undefined" && !isTauriRuntime();
}

export function isWebSimulatorPreview(): boolean {
  return isWebRuntime() && import.meta.env.MODE === "web";
}
