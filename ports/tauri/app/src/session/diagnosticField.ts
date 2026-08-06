// A generic, JSON-shaped diagnostic field value. Event authors may record a
// string, a number, a boolean, or a nested array/object without the report
// renderer ever needing per-event or per-key knowledge of the shape --
// future instrumentation (e.g. detector confidence scores) starts rendering
// into every generated report the moment it starts recording a field, with
// zero coupling to formatDiagnosticFields or the error-report builder.
//
// Mirrors ScanStudioKit's DiagnosticFieldValue (app/ScanStudio/Sources/
// ScanStudioKit/SessionDiagnosticTimeline.swift) so both frontends render an
// identical compact shape for the same kind of value.
export type DiagnosticFieldValue =
  | string
  | number
  | boolean
  | null
  | DiagnosticFieldValue[]
  | { [key: string]: DiagnosticFieldValue };

export type DiagnosticFields = Record<string, DiagnosticFieldValue>;

/** Compact, single-line rendering of one field value. Never multi-line and
 * never pretty-printed JSON -- nested values still collapse into one
 * `key=value` diagnostic line. */
export function formatDiagnosticValue(value: DiagnosticFieldValue): string {
  if (value === null) return "null";
  if (typeof value === "string") return value;
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return formatNumber(value);
  if (Array.isArray(value)) {
    return "[" + value.map(formatDiagnosticValue).join(",") + "]";
  }
  const rendered = Object.keys(value)
    .sort()
    .map((key) => `${key}=${formatDiagnosticValue(value[key])}`)
    .join(",");
  return `{${rendered}}`;
}

function formatNumber(value: number): string {
  if (Number.isFinite(value) && Number.isInteger(value)) {
    return String(value);
  }
  return String(value);
}

/** Compact `key=value key2=value2` rendering of a whole fields object, keys
 * sorted for stable output -- the generic serializer every diagnostic event
 * (present or future) renders through, with no event-name or key-name
 * special-casing anywhere in this function. */
export function formatDiagnosticFields(fields: DiagnosticFields): string {
  return Object.keys(fields)
    .sort()
    .map((key) => `${key}=${formatDiagnosticValue(fields[key])}`)
    .join(" ");
}
