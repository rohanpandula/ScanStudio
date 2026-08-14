import type { DiagnosticFields } from "./diagnosticField";
import { formatDiagnosticFields } from "./diagnosticField";
import { newOperationId } from "./webApis";

export interface DiagnosticEntry {
  timestamp: string;
  sessionId: string;
  event: string;
  fields: DiagnosticFields;
}

/** Matches SessionDiagnosticEntry.summaryLine's exact shape:
 * `<timestamp> <event>` when there are no fields, else
 * `<timestamp> <event> key=value key2=value2` with keys sorted. */
export function summaryLine(entry: DiagnosticEntry): string {
  const details = formatDiagnosticFields(entry.fields);
  return details.length === 0
    ? `${entry.timestamp} ${entry.event}`
    : `${entry.timestamp} ${entry.event} ${details}`;
}

function generateSessionId(): string {
  // Delegates to the shared guarded generator: live Windows shipped without
  // crypto.randomUUID (insecure webview context), so the fallback is a real
  // production path, not a test-only nicety. See webApis.ts.
  return newOperationId();
}

/** Both report outputs show at most this many of the most recent diagnostic
 * events -- matches SessionDiagnosticTimeline's own default retention cap
 * on the mac side, so raising one without the other cannot silently
 * under-fill the report. */
export const MAXIMUM_DIAGNOSTIC_ENTRIES = 40;

/** A bounded, privacy-safe diagnostic timeline (T-ERR-02's Tauri
 * counterpart of SessionDiagnosticTimeline). Callers supply only
 * operational fields; paths, film metadata, and device identifiers do not
 * belong here.
 *
 * Scope note: unlike the mac build, this does not yet persist to a durable
 * on-disk log -- "Save Diagnostic Bundle..." (diagnosticBundle.ts) writes
 * the current in-memory window directly into diagnostics.jsonl instead, and
 * the error report's "Local log" line honestly renders "unknown" until a
 * durable Tauri-side log lands as a follow-up. */
export class DiagnosticTimeline {
  readonly sessionId: string;
  #maximumEntries: number;
  #entries: DiagnosticEntry[] = [];

  constructor(sessionId: string = generateSessionId(), maximumEntries: number = MAXIMUM_DIAGNOSTIC_ENTRIES) {
    this.sessionId = sessionId;
    this.#maximumEntries = Math.max(maximumEntries, 1);
  }

  record(event: string, fields: DiagnosticFields = {}, timestamp: string = new Date().toISOString()): void {
    this.#entries.push({ timestamp, sessionId: this.sessionId, event, fields });
    if (this.#entries.length > this.#maximumEntries) {
      this.#entries = this.#entries.slice(this.#entries.length - this.#maximumEntries);
    }
  }

  get entries(): readonly DiagnosticEntry[] {
    return this.#entries;
  }

  get summaryLines(): string[] {
    return this.#entries.map(summaryLine);
  }

  /** One JSON object per line, matching SessionDiagnosticTimeline's durable
   * on-disk shape -- the exact bytes "Save Diagnostic Bundle..." writes into
   * diagnostics.jsonl. */
  toJsonl(): string {
    return this.#entries.map((entry) => JSON.stringify(entry)).join("\n");
  }
}
