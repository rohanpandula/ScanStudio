import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION,
  MAX_DIAGNOSTIC_EVIDENCE_BYTES,
  diagnosticEvidenceKey,
  parseDiagnosticEvidence,
  reproduceTransportDecision,
  resolveDiagnosticEvidence,
  type DiagnosticEvidence,
  type DiagnosticEvidenceReference,
} from "../diagnosticEvidence";
import { SessionStore } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type { EngineError } from "../wire/types";

const REFERENCE: DiagnosticEvidenceReference = {
  schemaVersion: DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION,
  evidenceId: "ev-3de9cbb4-ccb1-47f7-9d59-d4a30aa86f91",
  operationId: "op-491c26e6-62cb-4a1d-9b8e-3a3d27e931dc",
  sessionEpoch: "7",
};

const TERMINAL_PADDING: DiagnosticEvidence = {
  ...REFERENCE,
  operationKind: "preview",
  builds: {
    app: "0.7.0-beta.12+abc1234",
    engine: "0.7.0-beta.12+abc1234",
    bridge: "0.7.3+def5678",
  },
  device: { model: "SUPER COOLSCAN 5000 ED", adapter: "SA-30", holder: "roll36" },
  witness: {
    kind: "terminalPadding",
    recordCount: 37,
    byteCount: 296,
    parity: "even",
    housekeepingByteCount: 4,
    nonzeroRgbCount: 12,
    mismatchLocation: { recordIndex: 36, byteOffset: 288 },
  },
};

const AFFINE: DiagnosticEvidence = {
  ...REFERENCE,
  evidenceId: "ev-affine-ccb1-47f7-9d59-d4a30aa86f91",
  operationKind: "preview",
  builds: TERMINAL_PADDING.builds,
  device: TERMINAL_PADDING.device,
  witness: {
    kind: "affine",
    holderCapacity: 40,
    anchors: [
      { ordinal: 0, inputRow: 0, observedRow: -126.21, fittedRow: 0, residualRows: 3.005 },
      { ordinal: 1, inputRow: 10, observedRow: 411.6, fittedRow: 420, residualRows: 0.2 },
      { ordinal: 2, inputRow: 20, observedRow: 831.6, fittedRow: 840, residualRows: 0.2 },
      { ordinal: 3, inputRow: 30, observedRow: 1251.6, fittedRow: 1260, residualRows: 0.2 },
      { ordinal: 4, inputRow: 40, observedRow: 1674.246, fittedRow: 1680, residualRows: 0.137 },
      { ordinal: 5, inputRow: 50, observedRow: 2091.6, fittedRow: 2100, residualRows: 0.2 },
    ],
    transform: { slope: 42, intercept: 0 },
    thresholds: { maximumMeanAbsoluteResidualRows: 0.5, maximumResidualRows: 3 },
    meanAbsoluteResidualRows: 0.657,
    maximumResidualRows: 3.005,
  },
};

describe("bounded transport evidence (#106)", () => {
  it("decodes and replays the shared canonical fixture corpus", () => {
    for (const name of [
      "evidence-42-affine",
      "evidence-43-terminal-padding",
      "evidence-68-affine",
    ]) {
      const source = readFileSync(
        new URL(
          `../../../../../../app/ScanStudio/protocol/fixtures/diagnostic-evidence-v1/${name}.json`,
          import.meta.url,
        ),
        "utf8",
      );
      const parsed = parseDiagnosticEvidence(JSON.parse(source));
      expect(parsed).toMatchObject({ ok: true });
      if (parsed.ok) {
        expect(reproduceTransportDecision(parsed.value)).not.toBe("affine-within-threshold");
      }
    }
  });
  it("accepts and reconstructs the terminal-padding and affine classifier decisions offline", () => {
    const padding = parseDiagnosticEvidence(TERMINAL_PADDING);
    const affine = parseDiagnosticEvidence(AFFINE);
    expect(padding).toEqual({ ok: true, value: TERMINAL_PADDING });
    expect(affine).toEqual({ ok: true, value: AFFINE });
    if (padding.ok && affine.ok) {
      expect(reproduceTransportDecision(padding.value)).toBe("terminal-padding-mismatch");
      expect(reproduceTransportDecision(affine.value)).toBe("affine-residual-exceeded");
    }
  });

  it("enforces holder, byte, and privacy bounds before publication", () => {
    const tooManyAnchors = structuredClone(AFFINE) as DiagnosticEvidence;
    if (tooManyAnchors.witness.kind !== "affine") throw new Error("fixture shape");
    tooManyAnchors.witness.holderCapacity = 1;
    expect(parseDiagnosticEvidence(tooManyAnchors)).toMatchObject({ ok: false });

    const forbidden = {
      ...TERMINAL_PADDING,
      serial: "SN-SECRET",
      rawExcerpt: [1, 2, 3],
      completeTransportTable: [1, 2, 3],
      path: "/Users/alice/private-roll.tif",
    };
    expect(parseDiagnosticEvidence(forbidden)).toMatchObject({ ok: false });

    const oversized = {
      ...TERMINAL_PADDING,
      builds: { ...TERMINAL_PADDING.builds, bridge: "x".repeat(MAX_DIAGNOSTIC_EVIDENCE_BYTES) },
    };
    expect(parseDiagnosticEvidence(oversized)).toMatchObject({ ok: false });
  });

  it("selects only the artifact named by the exact terminal error reference, never newest evidence", () => {
    const map = {
      [diagnosticEvidenceKey(REFERENCE)]: TERMINAL_PADDING,
      [diagnosticEvidenceKey({ ...REFERENCE, evidenceId: "ev-newest" })]: {
        ...TERMINAL_PADDING,
        evidenceId: "ev-newest",
      },
    };
    const error: EngineError = {
      code: "REFEED_REQUIRED",
      message: "preview failed",
      recoverable: false,
      evidence: REFERENCE,
    };
    expect(resolveDiagnosticEvidence(map, error)).toEqual({
      evidence: TERMINAL_PADDING,
      unavailableReason: null,
    });
    expect(resolveDiagnosticEvidence(map, { ...error, evidence: { ...REFERENCE, evidenceId: "missing" } }))
      .toMatchObject({ evidence: null, unavailableReason: expect.stringContaining("missing") });
  });

  it("stores an immutable validated artifact without allowing a conflicting duplicate to replace it", () => {
    const handle = createScriptedTransport({ onRequest: () => ({ result: undefined }) });
    const store = new SessionStore(handle.transport);
    const integrity: unknown[] = [];
    store.onIntegrityError((error) => integrity.push(error));

    handle.emitEvent({ event: "diagnostic.evidence", payload: TERMINAL_PADDING });
    handle.emitEvent({
      event: "diagnostic.evidence",
      payload: {
        ...TERMINAL_PADDING,
        witness: { ...TERMINAL_PADDING.witness, byteCount: 999 },
      },
    });

    const key = diagnosticEvidenceKey(REFERENCE);
    expect(store.getState().diagnosticEvidence[key]).toEqual(TERMINAL_PADDING);
    expect(integrity).toHaveLength(1);
  });

  it("retires prior evidence when a new preview operation is accepted", async () => {
    const handle = createScriptedTransport({
      onRequest: (method) =>
        method === "scanner.acquireThumbnails"
          ? { result: { accepted: true, frames: [1] } }
          : { result: undefined },
    });
    const store = new SessionStore(handle.transport);
    handle.emitEvent({ event: "diagnostic.evidence", payload: TERMINAL_PADDING });
    expect(Object.keys(store.getState().diagnosticEvidence)).toHaveLength(1);

    await store.acquireThumbnails([1]);

    expect(store.getState().diagnosticEvidence).toEqual({});
  });

  it("keeps the newest bounded artifact and evicts the oldest", () => {
    const handle = createScriptedTransport({ onRequest: () => ({ result: undefined }) });
    const store = new SessionStore(handle.transport);
    for (let index = 0; index < 9; index += 1) {
      handle.emitEvent({
        event: "diagnostic.evidence",
        payload: { ...TERMINAL_PADDING, evidenceId: `ev-bounded-${index}` },
      });
    }

    const evidence = store.getState().diagnosticEvidence;
    expect(Object.keys(evidence)).toHaveLength(8);
    expect(
      evidence[
        diagnosticEvidenceKey({ ...REFERENCE, evidenceId: "ev-bounded-0" })
      ],
    ).toBeUndefined();
    expect(
      evidence[
        diagnosticEvidenceKey({ ...REFERENCE, evidenceId: "ev-bounded-8" })
      ],
    ).toMatchObject({ evidenceId: "ev-bounded-8" });
  });

  it("keeps the scanner failure authoritative when its witness is malformed or unavailable", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params: params as Record<string, unknown> });
        if (method === "scanner.acquireThumbnails") {
          return { result: { accepted: true, frames: [1] } };
        }
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    const integrity: unknown[] = [];
    store.onIntegrityError((error) => integrity.push(error));
    await store.acquireThumbnails([1]);
    const operationId = calls[0].params.operationId as string;
    const malformedReference = {
      schemaVersion: 1,
      evidenceId: "missing",
      operationId,
      sessionEpoch: "/private/session/path-is-not-an-epoch",
    };

    handle.emitEvent({ event: "diagnostic.evidence", payload: { rawExcerpt: [1, 2, 3] } });
    handle.emitEvent({
      event: "scanner.thumbnailsFailed",
      payload: {
        operationId,
        code: "REFEED_REQUIRED",
        message: "scanner transport failed",
        evidence: malformedReference,
      },
    });

    const failure = store.getState().previewError;
    expect(failure).toMatchObject({
      code: "REFEED_REQUIRED",
      message: "scanner transport failed",
      recoverable: false,
    });
    expect(resolveDiagnosticEvidence(store.getState().diagnosticEvidence, failure!)).toMatchObject({
      evidence: null,
      unavailableReason: expect.stringContaining("malformed"),
    });
    expect(integrity).toHaveLength(1);
  });
});
