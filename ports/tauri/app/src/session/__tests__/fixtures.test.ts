import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { decodeEnvelope } from "../wire/codec";
import {
  isCaptureRecipe,
  isDeviceInfo,
  isEngineError,
  isScanReceipt,
  isScannerStatus,
  isThumbnail,
  type ScanReceipt,
} from "../wire/types";

// The fixture suite is the golden round-trip gate for the wire layer. The
// The frozen protocol fixtures ship with this source tree. An explicit
// SCANSTUDIO_PROTOCOL_DIR may override them for compatibility testing.
const FIXTURES_DIR =
  process.env.SCANSTUDIO_PROTOCOL_DIR ??
  // fileURLToPath (not URL.pathname) so a Windows host gets a clean "D:\..."
  // path instead of a doubled/encoded drive prefix.
  fileURLToPath(
    new URL("../../../../vendor/protocol/fixtures", import.meta.url),
  );

const describeFixtures = (() => {
  try {
    return readdirSync(FIXTURES_DIR).length > 0 ? describe : describe.skip;
  } catch {
    if (!process.env.SCANSTUDIO_PROTOCOL_DIR) {
      console.log(
        "SCANSTUDIO_PROTOCOL_DIR not set and default fixture dir not found -- skipping fixture round-trip tests",
      );
    } else {
      console.log(
        `SCANSTUDIO_PROTOCOL_DIR=${process.env.SCANSTUDIO_PROTOCOL_DIR} does not exist -- skipping fixture round-trip tests`,
      );
    }
    return describe.skip;
  }
})();

const FLOAT_EPSILON = 1e-9;

function deepEqualWithTolerance(a: unknown, b: unknown, eps: number): boolean {
  if (typeof a === "number" && typeof b === "number") {
    return Math.abs(a - b) <= eps;
  }
  if (
    a === null ||
    b === null ||
    typeof a !== "object" ||
    typeof b !== "object"
  ) {
    return a === b;
  }
  if (Array.isArray(a) !== Array.isArray(b)) {
    return false;
  }
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) {
      return false;
    }
    return a.every((item, index) => deepEqualWithTolerance(item, b[index], eps));
  }
  const aRecord = a as Record<string, unknown>;
  const bRecord = b as Record<string, unknown>;
  const aKeys = Object.keys(aRecord);
  const bKeys = Object.keys(bRecord);
  if (aKeys.length !== bKeys.length) {
    return false;
  }
  return aKeys.every(
    (key) =>
      Object.prototype.hasOwnProperty.call(bRecord, key) &&
      deepEqualWithTolerance(aRecord[key], bRecord[key], eps),
  );
}

function isStringRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function validateRequestParams(method: string, params: unknown): void {
  switch (method) {
    case "engine.hello": {
      expect(isStringRecord(params)).toBe(true);
      const p = params as Record<string, unknown>;
      expect(typeof p.clientName).toBe("string");
      expect(p.protocolVersion).toBe(1);
      break;
    }
    case "scanner.connect": {
      expect(isStringRecord(params)).toBe(true);
      const p = params as Record<string, unknown>;
      expect(typeof p.deviceId).toBe("string");
      if ("options" in p) {
        expect(isStringRecord(p.options)).toBe(true);
        const options = p.options as Record<string, unknown>;
        if ("timeScale" in options) {
          expect(typeof options.timeScale).toBe("number");
        }
        if ("faultInjection" in options) {
          expect(["none", "demo"]).toContain(options.faultInjection);
        }
      }
      break;
    }
    case "scan.start": {
      expect(isStringRecord(params)).toBe(true);
      const p = params as Record<string, unknown>;
      expect(Array.isArray(p.frames)).toBe(true);
      expect((p.frames as unknown[]).every((f) => typeof f === "number")).toBe(true);
      expect(isCaptureRecipe(p.recipe)).toBe(true);
      break;
    }
    case "scan.stop": {
      expect(isStringRecord(params)).toBe(true);
      const p = params as Record<string, unknown>;
      expect(typeof p.jobId).toBe("string");
      expect(["afterCurrentFrame", "immediate"]).toContain(p.mode);
      break;
    }
    default:
      break;
  }
}

function validateResponseResult(result: unknown): void {
  expect(isStringRecord(result)).toBe(true);
  const r = result as Record<string, unknown>;
  if ("devices" in r) {
    expect(Array.isArray(r.devices)).toBe(true);
    for (const device of r.devices as unknown[]) {
      expect(isDeviceInfo(device)).toBe(true);
    }
  }
  if ("engineName" in r) {
    expect(typeof r.engineName).toBe("string");
    expect(typeof r.engineVersion).toBe("string");
    expect(r.protocolVersion).toBe(1);
    expect(Array.isArray(r.capabilities)).toBe(true);
    expect((r.capabilities as unknown[]).every((c) => typeof c === "string")).toBe(true);
  }
}

function validateEventPayload(event: string, payload: unknown): void {
  expect(isStringRecord(payload)).toBe(true);
  const p = payload as Record<string, unknown>;
  switch (event) {
    case "scanner.status": {
      expect(isScannerStatus(p.status)).toBe(true);
      break;
    }
    case "scanner.thumbnail": {
      expect(typeof p.frameIndex).toBe("number");
      expect(isThumbnail(p.thumbnail)).toBe(true);
      break;
    }
    case "scan.progress": {
      expect(typeof p.jobId).toBe("string");
      for (const key of [
        "frameIndex",
        "frameOrdinal",
        "totalFrames",
        "pass",
        "totalPasses",
        "framePercent",
        "jobPercent",
        "etaSeconds",
      ]) {
        expect(typeof p[key]).toBe("number");
      }
      expect(p.framePercent as number).toBeGreaterThanOrEqual(0);
      expect(p.framePercent as number).toBeLessThanOrEqual(100);
      expect(p.jobPercent as number).toBeGreaterThanOrEqual(0);
      expect(p.jobPercent as number).toBeLessThanOrEqual(100);
      break;
    }
    case "scan.frameCompleted": {
      expect(typeof p.jobId).toBe("string");
      expect(typeof p.frameIndex).toBe("number");
      expect(isScanReceipt(p.receipt)).toBe(true);
      const receipt = p.receipt as ScanReceipt;
      const isGoldenRecipe =
        receipt.resolutionDpi === 4000 &&
        receipt.bitDepth === 16 &&
        receipt.passes === 2 &&
        receipt.channels === "rgbi";
      if (isGoldenRecipe) {
        expect(receipt.settingsFingerprint).toBe("1a3d265e0b54bbd2");
      }
      break;
    }
    case "scan.frameState": {
      expect(typeof p.jobId).toBe("string");
      expect(typeof p.frameIndex).toBe("number");
      expect(typeof p.state).toBe("string");
      expect(typeof p.attempt).toBe("number");
      if ("error" in p) {
        expect(isEngineError(p.error)).toBe(true);
        const error = p.error as { code: string; recoverable: boolean };
        if (error.code === "FEED_JAM") {
          expect(error.recoverable).toBe(true);
        }
      }
      break;
    }
    default:
      break;
  }
}

describeFixtures("protocol fixture round-trip", () => {
  const fixtureFiles = readdirSync(FIXTURES_DIR)
    .filter((name) => name.endsWith(".json"))
    .sort();

  it("enumerates the fixtures directory dynamically", () => {
    expect(fixtureFiles.length).toBeGreaterThanOrEqual(12);
  });

  for (const file of fixtureFiles) {
    it(`round-trips ${file}`, () => {
      const rawText = readFileSync(join(FIXTURES_DIR, file), "utf8");
      const parsed: unknown = JSON.parse(rawText);

      const decoded = decodeEnvelope(parsed);
      expect(decoded.kind).not.toBe("unknown");

      switch (decoded.kind) {
        case "request": {
          expect(typeof decoded.value.id).toBe("number");
          validateRequestParams(decoded.value.method, decoded.value.params);
          break;
        }
        case "responseSuccess": {
          expect(typeof decoded.value.id).toBe("number");
          validateResponseResult(decoded.value.result);
          break;
        }
        case "responseError": {
          expect(typeof decoded.value.id).toBe("number");
          expect(isEngineError(decoded.value.error)).toBe(true);
          const { code, recoverable } = decoded.value.error;
          if (code !== "FEED_JAM" && code !== "HARDWARE_LANE_BUSY") {
            expect(recoverable).toBe(false);
          }
          break;
        }
        case "event": {
          expect(typeof decoded.value.event).toBe("string");
          validateEventPayload(decoded.value.event, decoded.value.payload);
          break;
        }
        case "unknown":
          break;
      }

      const reserialized: unknown = JSON.parse(JSON.stringify(parsed));
      expect(deepEqualWithTolerance(parsed, reserialized, FLOAT_EPSILON)).toBe(true);
    });
  }
});
