import { SessionStore } from "./store/session";
import { createClientTransport } from "./wire/codec";

// Production session singleton: the ONLY store instance views import. It is
// wired to the Tauri invoke bridge (engine/client.ts via createClientTransport).
// Component tests replace this module with a scripted-transport store.
export const sessionStore = new SessionStore(createClientTransport());

export { SessionStore };
export type { SessionState } from "./store/session";
