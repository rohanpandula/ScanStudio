// Builds "the report" text (error report v2, T-ERR-01/02/03/05): a
// build-identifying header that never silently drops a field, up to the
// last 40 diagnostic events, and -- when the Windows setup checker has run
// this session -- its probe results. Pure and synchronous: callers resolve
// every value (version, OS, diagnostics, probes) up front via
// ErrorReportContext, mirroring ErrorPresentationPolicy.make's contract on
// the mac side (app/ScanStudio/Sources/ScanStudioKit/ErrorPresentation.swift)
// so both frontends render the same shape for the same inputs.

/** Both report outputs show at most this many of the most recent diagnostic
 * events -- matches DiagnosticTimeline's own retention cap. */
export const MAXIMUM_RECENT_DIAGNOSTIC_EVENTS = 40;

const UNKNOWN = "unknown";

export interface SetupCheckProbeSummary {
  id: string;
  status: string;
  detail: string;
}

export interface ErrorReportContext {
  scanStudioVersion?: string | null;
  operatingSystem?: string | null;
  cpuArchitecture?: string | null;
  scannerFirmware?: string | null;
  scannerAdapter?: string | null;
  scannerHolder?: string | null;
  /** Local-only diagnostics log location. Tauri does not yet persist a
   * durable on-disk log (see diagnosticTimeline.ts) -- omit or pass `null`
   * until that lands, and this renders the header's honest "unknown" rather
   * than a fabricated path. */
  diagnosticLogPath?: string | null;
  diagnosticSessionId?: string | null;
  engineVersion?: string | null;
  connectionSummary?: string | null;
  errorCode: string;
  errorMessage: string;
  recentDiagnosticEvents: string[];
  /** The Windows setup checker's most recent probe results, when it has run
   * this session (item 5). Omitted entirely from the report when `null` or
   * empty -- never an empty "Windows setup check:" section. */
  setupCheckProbes?: SetupCheckProbeSummary[] | null;
}

function rendered(value: string | null | undefined): string {
  const trimmed = (value ?? "").trim();
  return trimmed.length === 0 ? UNKNOWN : trimmed;
}

export function buildErrorReportText(context: ErrorReportContext): string {
  const lines: string[] = ["ScanStudio error report"];

  // Build-identifying header (T-ERR-01): every field always renders,
  // falling back to "unknown" rather than being silently omitted.
  lines.push(`ScanStudio version: ${rendered(context.scanStudioVersion)}`);
  lines.push(`Operating system: ${rendered(context.operatingSystem)}`);
  lines.push(`CPU architecture: ${rendered(context.cpuArchitecture)}`);
  lines.push(`Scanner firmware: ${rendered(context.scannerFirmware)}`);
  lines.push(`Adapter: ${rendered(context.scannerAdapter)}`);
  lines.push(`Holder: ${rendered(context.scannerHolder)}`);

  // Near the top, per T-ERR-02, and only when actually known -- unlike the
  // header fields above this is not forced to "unknown" when absent.
  if (context.diagnosticLogPath) {
    lines.push(`Local log: ${context.diagnosticLogPath}`);
  }
  if (context.diagnosticSessionId) {
    lines.push(`Diagnostic session: ${context.diagnosticSessionId}`);
  }
  if (context.engineVersion) {
    lines.push(`Engine version: ${context.engineVersion}`);
  }
  if (context.connectionSummary) {
    lines.push(`Connection state: ${context.connectionSummary}`);
  }
  lines.push(`Error code: ${context.errorCode}`);
  lines.push("");
  lines.push("Message:");
  lines.push(context.errorMessage);

  if (context.recentDiagnosticEvents.length > 0) {
    lines.push("");
    lines.push("Recent diagnostic events:");
    for (const event of context.recentDiagnosticEvents.slice(-MAXIMUM_RECENT_DIAGNOSTIC_EVENTS)) {
      lines.push(`- ${event}`);
    }
  }

  if (context.setupCheckProbes && context.setupCheckProbes.length > 0) {
    lines.push("");
    lines.push("Windows setup check:");
    for (const probe of context.setupCheckProbes) {
      lines.push(`- ${probe.id}: ${probe.status} -- ${probe.detail}`);
    }
  }

  lines.push("");
  lines.push("No images, receipts, or raw logs are attached automatically.");

  return lines.join("\n");
}
