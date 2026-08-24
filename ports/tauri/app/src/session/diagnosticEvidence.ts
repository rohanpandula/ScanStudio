import type { EngineError } from "./wire/types";

// These limits and field names mirror the canonical engine's version-1
// DiagnosticEvidence wire schema. Keep changes synchronized across clients.
export const DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION = 1 as const;
export const MAX_DIAGNOSTIC_EVIDENCE_BYTES = 16 * 1024;
export const MAX_DIAGNOSTIC_EVIDENCE_ARTIFACTS = 8;

const MAX_IDENTIFIER_BYTES = 128;
const MAX_BUILD_BYTES = 128;
const MAX_DEVICE_FIELD_BYTES = 96;
const MAX_HOLDER_CAPACITY = 40;
const MAX_RECORD_COUNT = 8_192;
const MAX_SOURCE_BYTES = 8 * 1024 * 1024;
const MAX_ABSOLUTE_ROW = 1_000_000_000;
const MAX_RESIDUAL_THRESHOLD_ROWS = 1_000;

export interface DiagnosticEvidenceReference {
  schemaVersion: typeof DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION;
  evidenceId: string;
  operationId: string;
  sessionEpoch: string;
}

interface DiagnosticEvidenceIdentity extends DiagnosticEvidenceReference {
  operationKind: "preview" | "scanBinding";
  builds: {
    app: string;
    engine: string;
    bridge: string;
  };
  device: {
    model: string;
    adapter: string;
    holder: "mounted" | "strip6" | "roll36";
  };
}

export interface TerminalPaddingEvidence extends DiagnosticEvidenceIdentity {
  witness: {
    kind: "terminalPadding";
    recordCount: number;
    byteCount: number;
    parity: "even" | "odd";
    housekeepingByteCount: number;
    nonzeroRgbCount: number;
    mismatchLocation: { recordIndex: number; byteOffset: number };
  };
}

export interface AffineEvidence extends DiagnosticEvidenceIdentity {
  witness: {
    kind: "affine";
    holderCapacity: number;
    anchors: Array<{
      ordinal: number;
      inputRow: number;
      observedRow: number;
      fittedRow: number;
      residualRows: number;
    }>;
    transform: {
      slope: number;
      intercept: number;
    };
    thresholds: {
      maximumMeanAbsoluteResidualRows: number;
      maximumResidualRows: number;
    };
    meanAbsoluteResidualRows: number;
    maximumResidualRows: number;
  };
}

export type DiagnosticEvidence = TerminalPaddingEvidence | AffineEvidence;

export type DiagnosticEvidenceParseResult =
  | { ok: true; value: DiagnosticEvidence }
  | { ok: false; reason: string };

export interface DiagnosticEvidenceResolution {
  evidence: DiagnosticEvidence | null;
  unavailableReason: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function utf8Length(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function boundedIdentifier(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    utf8Length(value) <= MAX_IDENTIFIER_BYTES &&
    /^[A-Za-z0-9_.:-]+$/u.test(value)
  );
}

function boundedBuild(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    utf8Length(value) <= MAX_BUILD_BYTES &&
    /^[A-Za-z0-9_.+-]+$/u.test(value)
  );
}

function boundedDeviceLabel(value: unknown): value is string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    utf8Length(value) > MAX_DEVICE_FIELD_BYTES ||
    value.includes("/") ||
    value.includes("\\")
  ) {
    return false;
  }
  return [...value].every((character) => {
    const code = character.codePointAt(0);
    return code !== undefined && code >= 0x20 && code <= 0x7e;
  });
}

function positiveDecimalEpoch(value: unknown): value is string {
  return typeof value === "string" && /^[1-9][0-9]*$/u.test(value);
}

function boundedInteger(value: unknown, minimum: number, maximum: number): value is number {
  return Number.isSafeInteger(value) && (value as number) >= minimum && (value as number) <= maximum;
}

function boundedNumber(value: unknown, minimum: number, maximum: number): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= minimum && value <= maximum;
}

function holderCapacity(holder: DiagnosticEvidenceIdentity["device"]["holder"]): number {
  if (holder === "mounted") return 1;
  if (holder === "strip6") return 6;
  return 40;
}

function parseReference(value: unknown): DiagnosticEvidenceReference | null {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, ["schemaVersion", "evidenceId", "operationId", "sessionEpoch"]) ||
    value.schemaVersion !== DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION ||
    !boundedIdentifier(value.evidenceId) ||
    !boundedIdentifier(value.operationId) ||
    !positiveDecimalEpoch(value.sessionEpoch)
  ) {
    return null;
  }
  return {
    schemaVersion: DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION,
    evidenceId: value.evidenceId,
    operationId: value.operationId,
    sessionEpoch: value.sessionEpoch,
  };
}

function parseIdentity(
  value: Record<string, unknown>,
): Omit<DiagnosticEvidenceIdentity, "witness"> | null {
  if (
    value.schemaVersion !== DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION ||
    !boundedIdentifier(value.evidenceId) ||
    !boundedIdentifier(value.operationId) ||
    !positiveDecimalEpoch(value.sessionEpoch) ||
    (value.operationKind !== "preview" && value.operationKind !== "scanBinding") ||
    !isRecord(value.builds) ||
    !hasExactKeys(value.builds, ["app", "engine", "bridge"]) ||
    !boundedBuild(value.builds.app) ||
    !boundedBuild(value.builds.engine) ||
    !boundedBuild(value.builds.bridge) ||
    !isRecord(value.device) ||
    !hasExactKeys(value.device, ["model", "adapter", "holder"]) ||
    !boundedDeviceLabel(value.device.model) ||
    !boundedDeviceLabel(value.device.adapter) ||
    (value.device.holder !== "mounted" &&
      value.device.holder !== "strip6" &&
      value.device.holder !== "roll36")
  ) {
    return null;
  }
  return {
    schemaVersion: DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION,
    evidenceId: value.evidenceId,
    operationId: value.operationId,
    sessionEpoch: value.sessionEpoch,
    operationKind: value.operationKind,
    builds: {
      app: value.builds.app,
      engine: value.builds.engine,
      bridge: value.builds.bridge,
    },
    device: {
      model: value.device.model,
      adapter: value.device.adapter,
      holder: value.device.holder,
    },
  };
}

function parseTerminalWitness(value: unknown): TerminalPaddingEvidence["witness"] | null {
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "kind",
      "recordCount",
      "byteCount",
      "parity",
      "housekeepingByteCount",
      "nonzeroRgbCount",
      "mismatchLocation",
    ]) ||
    value.kind !== "terminalPadding" ||
    !boundedInteger(value.recordCount, 1, MAX_RECORD_COUNT) ||
    !boundedInteger(value.byteCount, 1, MAX_SOURCE_BYTES) ||
    (value.parity !== "even" && value.parity !== "odd") ||
    !boundedInteger(value.housekeepingByteCount, 0, value.byteCount) ||
    !boundedInteger(value.nonzeroRgbCount, 0, value.recordCount * 96 * 3) ||
    !isRecord(value.mismatchLocation) ||
    !hasExactKeys(value.mismatchLocation, ["recordIndex", "byteOffset"]) ||
    !boundedInteger(value.mismatchLocation.recordIndex, 0, value.recordCount - 1) ||
    !boundedInteger(value.mismatchLocation.byteOffset, 0, value.byteCount - 1)
  ) {
    return null;
  }
  return {
    kind: "terminalPadding",
    recordCount: value.recordCount,
    byteCount: value.byteCount,
    parity: value.parity,
    housekeepingByteCount: value.housekeepingByteCount,
    nonzeroRgbCount: value.nonzeroRgbCount,
    mismatchLocation: {
      recordIndex: value.mismatchLocation.recordIndex,
      byteOffset: value.mismatchLocation.byteOffset,
    },
  };
}

function parseAffineWitness(
  value: unknown,
  holder: DiagnosticEvidenceIdentity["device"]["holder"],
): AffineEvidence["witness"] | null {
  const expectedCapacity = holderCapacity(holder);
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "kind",
      "holderCapacity",
      "anchors",
      "transform",
      "thresholds",
      "meanAbsoluteResidualRows",
      "maximumResidualRows",
    ]) ||
    value.kind !== "affine" ||
    value.holderCapacity !== expectedCapacity ||
    !boundedInteger(value.holderCapacity, 1, MAX_HOLDER_CAPACITY) ||
    !Array.isArray(value.anchors) ||
    value.anchors.length < 3 ||
    value.anchors.length > value.holderCapacity ||
    !isRecord(value.transform) ||
    !hasExactKeys(value.transform, ["slope", "intercept"]) ||
    !boundedNumber(value.transform.slope, Number.MIN_VALUE, MAX_ABSOLUTE_ROW) ||
    !boundedNumber(value.transform.intercept, -MAX_ABSOLUTE_ROW, MAX_ABSOLUTE_ROW) ||
    !isRecord(value.thresholds) ||
    !hasExactKeys(value.thresholds, [
      "maximumMeanAbsoluteResidualRows",
      "maximumResidualRows",
    ]) ||
    !boundedNumber(
      value.thresholds.maximumMeanAbsoluteResidualRows,
      Number.MIN_VALUE,
      MAX_RESIDUAL_THRESHOLD_ROWS,
    ) ||
    !boundedNumber(
      value.thresholds.maximumResidualRows,
      Number.MIN_VALUE,
      MAX_RESIDUAL_THRESHOLD_ROWS,
    ) ||
    !boundedNumber(value.meanAbsoluteResidualRows, 0, MAX_RESIDUAL_THRESHOLD_ROWS) ||
    !boundedNumber(value.maximumResidualRows, 0, MAX_RESIDUAL_THRESHOLD_ROWS) ||
    value.meanAbsoluteResidualRows > value.maximumResidualRows
  ) {
    return null;
  }

  const anchors: AffineEvidence["witness"]["anchors"] = [];
  const ordinals = new Set<number>();
  for (const candidate of value.anchors) {
    if (
      !isRecord(candidate) ||
      !hasExactKeys(candidate, [
        "ordinal",
        "inputRow",
        "observedRow",
        "fittedRow",
        "residualRows",
      ]) ||
      !boundedInteger(candidate.ordinal, 0, value.holderCapacity - 1) ||
      ordinals.has(candidate.ordinal) ||
      !boundedNumber(candidate.inputRow, -MAX_ABSOLUTE_ROW, MAX_ABSOLUTE_ROW) ||
      !boundedNumber(candidate.observedRow, -MAX_ABSOLUTE_ROW, MAX_ABSOLUTE_ROW) ||
      !boundedNumber(candidate.fittedRow, -MAX_ABSOLUTE_ROW, MAX_ABSOLUTE_ROW) ||
      !boundedNumber(candidate.residualRows, -MAX_ABSOLUTE_ROW, MAX_ABSOLUTE_ROW) ||
      Math.abs(
        value.transform.intercept + value.transform.slope * candidate.inputRow -
          candidate.fittedRow,
      ) > 0.01 ||
      Math.abs(
        (candidate.fittedRow - candidate.observedRow) / value.transform.slope -
          candidate.residualRows,
      ) > 0.01
    ) {
      return null;
    }
    ordinals.add(candidate.ordinal);
    anchors.push({
      ordinal: candidate.ordinal,
      inputRow: candidate.inputRow,
      observedRow: candidate.observedRow,
      fittedRow: candidate.fittedRow,
      residualRows: candidate.residualRows,
    });
  }
  const residualMagnitudes = anchors.map((anchor) => Math.abs(anchor.residualRows));
  const calculatedMean =
    residualMagnitudes.reduce((sum, residual) => sum + residual, 0) / residualMagnitudes.length;
  const calculatedMaximum = Math.max(...residualMagnitudes);
  if (
    Math.abs(calculatedMean - value.meanAbsoluteResidualRows) > 0.01 ||
    Math.abs(calculatedMaximum - value.maximumResidualRows) > 0.01 ||
    (value.meanAbsoluteResidualRows <=
      value.thresholds.maximumMeanAbsoluteResidualRows &&
      value.maximumResidualRows <= value.thresholds.maximumResidualRows)
  ) {
    return null;
  }

  return {
    kind: "affine",
    holderCapacity: value.holderCapacity,
    anchors,
    transform: {
      slope: value.transform.slope,
      intercept: value.transform.intercept,
    },
    thresholds: {
      maximumMeanAbsoluteResidualRows: value.thresholds.maximumMeanAbsoluteResidualRows,
      maximumResidualRows: value.thresholds.maximumResidualRows,
    },
    meanAbsoluteResidualRows: value.meanAbsoluteResidualRows,
    maximumResidualRows: value.maximumResidualRows,
  };
}

export function parseDiagnosticEvidence(value: unknown): DiagnosticEvidenceParseResult {
  let encoded: string | undefined;
  try {
    encoded = JSON.stringify(value);
  } catch {
    return { ok: false, reason: "diagnostic evidence is not JSON-serializable" };
  }
  if (
    encoded === undefined ||
    new TextEncoder().encode(encoded).byteLength > MAX_DIAGNOSTIC_EVIDENCE_BYTES
  ) {
    return { ok: false, reason: "diagnostic evidence exceeds the byte limit" };
  }
  if (
    !isRecord(value) ||
    !hasExactKeys(value, [
      "schemaVersion",
      "evidenceId",
      "operationId",
      "sessionEpoch",
      "operationKind",
      "builds",
      "device",
      "witness",
    ])
  ) {
    return { ok: false, reason: "diagnostic evidence has an unknown or missing field" };
  }
  const identity = parseIdentity(value);
  if (identity === null || !isRecord(value.witness)) {
    return { ok: false, reason: "diagnostic evidence identity is invalid" };
  }
  const witness =
    value.witness.kind === "terminalPadding"
      ? parseTerminalWitness(value.witness)
      : value.witness.kind === "affine"
        ? parseAffineWitness(value.witness, identity.device.holder)
        : null;
  if (witness === null) {
    return { ok: false, reason: "diagnostic evidence witness is invalid or outside its bounds" };
  }
  return { ok: true, value: { ...identity, witness } as DiagnosticEvidence };
}

export function diagnosticEvidenceKey(reference: DiagnosticEvidenceReference): string {
  return [
    reference.schemaVersion,
    reference.sessionEpoch,
    reference.operationId,
    reference.evidenceId,
  ]
    .map((part) => encodeURIComponent(String(part)))
    .join(":");
}

export function reproduceTransportDecision(evidence: DiagnosticEvidence): string {
  if (evidence.witness.kind === "terminalPadding") {
    return "terminal-padding-mismatch";
  }
  return evidence.witness.meanAbsoluteResidualRows >
      evidence.witness.thresholds.maximumMeanAbsoluteResidualRows ||
    evidence.witness.maximumResidualRows > evidence.witness.thresholds.maximumResidualRows
    ? "affine-residual-exceeded"
    : "affine-within-threshold";
}

export function resolveDiagnosticEvidence(
  evidenceByKey: Readonly<Record<string, DiagnosticEvidence>>,
  error: EngineError,
): DiagnosticEvidenceResolution {
  const reference = parseReference(error.evidence);
  if (reference === null) {
    const explicitReason = error.diagnosticEvidenceUnavailableReason?.trim();
    return {
      evidence: null,
      unavailableReason:
        explicitReason && explicitReason.length > 0
          ? explicitReason
          : error.evidence === undefined
            ? "the terminal error did not reference diagnostic evidence"
            : "the terminal error carried a malformed diagnostic evidence reference",
    };
  }
  const evidence = evidenceByKey[diagnosticEvidenceKey(reference)];
  if (evidence === undefined) {
    return {
      evidence: null,
      unavailableReason:
        error.diagnosticEvidenceUnavailableReason?.trim() ||
        "the referenced diagnostic evidence is missing (" + reference.evidenceId + ")",
    };
  }
  return { evidence, unavailableReason: null };
}
