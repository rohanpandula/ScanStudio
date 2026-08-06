import { DiagnosticTimeline } from "./diagnosticTimeline";
import { SessionStore } from "./store/session";
import { createClientTransport } from "./wire/codec";

// Production session singleton: the ONLY store instance views import. It is
// wired to the Tauri invoke bridge (engine/client.ts via createClientTransport).
// Component tests replace this module with a scripted-transport store.
export const sessionStore = new SessionStore(createClientTransport());

// Production diagnostic-events singleton for the error report (T-ERR-02).
// Deliberately independent of SessionStore -- it is populated by observing
// error state at the UI layer (see DiagnosticReportActions.tsx), never by
// SessionStore itself, so this never touches SessionStore's engine-session
// internals.
export const diagnosticTimeline = new DiagnosticTimeline();

export { SessionStore };
export type { SessionState } from "./store/session";
