const REDACTED = "<redacted>";
const REDACTED_PATH = "<redacted path>";

const SENSITIVE_LABELS = [
  "camera",
  "copyright",
  "date",
  "destination",
  "deviceId",
  "directory",
  "filename",
  "filmProcess",
  "filmStock",
  "frameNumber",
  "hash",
  "iso",
  "keywords",
  "lens",
  "log",
  "location",
  "metadata",
  "notes",
  "path",
  "photographer",
  "project",
  "projectDirectory",
  "projectPath",
  "previewPath",
  "rollId",
  "serial",
  "session",
  "sessionId",
  "settingsFingerprint",
] as const;

const SENSITIVE_KEY_PARTS = [
  "camera",
  "copyright",
  "destination",
  "deviceid",
  "directory",
  "filename",
  "filmstock",
  "filmprocess",
  "fingerprint",
  "framenumber",
  "hash",
  "keyword",
  "lens",
  "location",
  "metadata",
  "note",
  "photographer",
  "project",
  "receipt",
  "raw",
  "rollid",
  "serial",
  "settingsfingerprint",
  "table",
  "pixel",
] as const;

function escaped(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function isPathKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/gu, "");
  return normalized.includes("path") || normalized.includes("directory") || normalized.includes("destination");
}

function isSensitiveKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/gu, "");
  if (normalized === "operationid" || normalized === "evidenceid") {
    return false;
  }
  if (normalized === "date" || normalized === "iso") return true;
  return isPathKey(key) || SENSITIVE_KEY_PARTS.some((part) => normalized.includes(part));
}

/** Redacts share-facing free text without changing the local diagnostic
 * source. Explicit values cover metadata whose shape cannot be inferred;
 * label and path rules provide defense in depth for future event fields. */
export function redactShareText(text: string, sensitiveValues: readonly string[] = []): string {
  let result = text;
  for (const value of [...sensitiveValues].filter(Boolean).sort((a, b) => b.length - a.length)) {
    const replacement =
      /^(?:~|\/|[A-Za-z]:\\|\\\\)/u.test(value) ? REDACTED_PATH : REDACTED;
    result = result.replace(new RegExp(escaped(value), "gu"), replacement);
  }

  const labelPattern = SENSITIVE_LABELS.map(escaped).join("|");
  result = result.replace(
    new RegExp(
      "\\b(" + labelPattern + ")\\s*([=:])\\s*.*?(?=\\s+[A-Za-z][A-Za-z0-9_.-]*\\s*[=:]|[;,\\n]|$)",
      "giu",
    ),
    (_match, label: string, separator: string) => {
      const normalized = label.toLowerCase();
      const replacement =
        normalized.includes("path") ||
        normalized.includes("directory") ||
        normalized.includes("destination") ||
        normalized.includes("filename") ||
        normalized === "log"
          ? REDACTED_PATH
          : REDACTED;
      return label + separator + replacement;
    },
  );

  // Quoted and unquoted common Unix temporary/home/volume roots.
  result = result.replace(
    /(["']?)(?:~|\/(?:Users|Volumes|home|root|mnt|media|run\/user|private\/var\/folders|var\/folders|var\/tmp|private\/tmp|tmp))(?:\/[^\n"';,)]*)?\1/giu,
    REDACTED_PATH,
  );
  // Windows drive and UNC paths.
  result = result.replace(/[A-Za-z]:\\[^\n"';,)]*/gu, REDACTED_PATH);
  result = result.replace(/\\\\[^\\\s]+\\[^\n"';,)]*/gu, REDACTED_PATH);
  return result;
}

function sanitizeJsonValue(
  value: unknown,
  sensitiveValues: readonly string[],
  key: string | null = null,
): unknown {
  if (key !== null && isSensitiveKey(key)) {
    return isPathKey(key) ? REDACTED_PATH : REDACTED;
  }
  if (typeof value === "string") return redactShareText(value, sensitiveValues);
  if (value === null || typeof value === "number" || typeof value === "boolean") return value;
  if (Array.isArray(value)) return value.map((item) => sanitizeJsonValue(item, sensitiveValues));
  if (typeof value !== "object") return REDACTED;
  const output: Record<string, unknown> = {};
  for (const [childKey, childValue] of Object.entries(value)) {
    output[childKey] = sanitizeJsonValue(childValue, sensitiveValues, childKey);
  }
  return output;
}

/** Sanitizes each JSONL object independently. Malformed input is represented
 * by a fixed marker; its uninterpretable source bytes are never exported. */
export function sanitizeDiagnosticJsonl(
  jsonl: string,
  sensitiveValues: readonly string[] = [],
): string {
  return jsonl
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => {
      try {
        return JSON.stringify(sanitizeJsonValue(JSON.parse(line), sensitiveValues));
      } catch {
        return JSON.stringify({ event: "diagnostic.invalidLine", fields: { omitted: true } });
      }
    })
    .join("\n");
}
