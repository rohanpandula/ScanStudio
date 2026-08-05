// Metadata wire-wrapper tests (07-01 Task 1, RED): the five functions in
// app/src/session/store/metadata.ts each take the injected request function
// as their first parameter and call the EXACT wire methods/params documented
// in PROTOCOL.md. These tests drive them with a fake request function (no
// store, no transport), proving method/param pairing, the whole-object-swap
// payloads, the applyMetadata one-shot nil-on-failure pattern, and the
// safety property that applyMetadata never carries a client argument list
// (threat T-07-01).

import { describe, expect, it, vi } from "vitest";
import {
  applyMetadata,
  detectExifTool,
  previewMetadataCommand,
  setFrameMetadataOverride,
  setRollMetadata,
} from "../store/metadata";
import type {
  ApplyMetadataResult,
  ExifToolDetection,
  MetadataSet,
  PreviewMetadataCommandResult,
  ScanProject,
} from "../wire/types";

const DETECTION: ExifToolDetection = {
  available: true,
  path: "/usr/bin/exiftool",
  version: "12.76",
};

const PREVIEW: PreviewMetadataCommandResult = {
  available: true,
  exiftoolPath: "/usr/bin/exiftool",
  targets: ["/out/IMG_0001.tiff"],
  arguments: ["-CameraModel=Test", "-overwrite_original", "/out/IMG_0001.tiff"],
};

const APPLY: ApplyMetadataResult = {
  success: true,
  exitCode: 0,
  stdout: "    1 image files updated",
  stderr: "",
  targets: ["/out/IMG_0001.tiff"],
};

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-meta",
  name: "Metadata Roll",
  carrier: "roll36",
  frameCount: 36,
  filmProcess: "c41ColorNegative",
  recipes: {
    archive: {
      enabled: true,
      filenameTemplate: "IMG_####.tiff",
      destination: "/archive",
      fullCapturePackage: true,
    },
    positive: {
      enabled: true,
      fileFormat: "tiff",
      colorProfile: "sRgb",
      filenameTemplate: "POS_####.tiff",
      destination: "/positive",
    },
    preview: {
      enabled: true,
      fileFormat: "jpeg",
      maxLongEdgePx: 2048,
      filenameTemplate: "PRE_####.jpg",
      destination: "/preview",
    },
  },
  rollMetadata: { keywords: [] },
  createdAt: "2026-08-02T00:00:00.000Z",
  frames: [{ index: 1, excluded: false, receipts: [] }],
};

const ROLL_METADATA: MetadataSet = {
  camera: "Nikon F6",
  lens: "Nikkor 50mm f/1.4",
  filmStock: "Portra 400",
  iso: 400,
  location: "Portland",
  photographer: "Rohan",
  copyright: "2026 Rohan",
  rollId: "R-001",
  notes: "Push +1",
  keywords: ["street", "color"],
};

interface CapturedCall {
  method: string;
  params: unknown;
}

function capturingRequest(
  result: unknown,
): { request: (method: string, params?: unknown) => Promise<unknown>; calls: CapturedCall[] } {
  const calls: CapturedCall[] = [];
  const request = (method: string, params?: unknown): Promise<unknown> => {
    calls.push({ method, params });
    return Promise.resolve(result);
  };
  return { request, calls };
}

describe("detectExifTool", () => {
  it("calls exiftool.detect with empty params and returns the detection verbatim", async () => {
    const { request, calls } = capturingRequest(DETECTION);
    await expect(detectExifTool(request)).resolves.toEqual(DETECTION);
    expect(calls).toEqual([{ method: "exiftool.detect", params: {} }]);
  });

  it("propagates a rejection from the request unchanged", async () => {
    const error = { code: "INTERNAL", message: "boom", recoverable: false };
    const request = (): Promise<unknown> => Promise.reject(error);
    await expect(detectExifTool(request)).rejects.toBe(error);
    expect(vi.isMockFunction(request)).toBe(false);
  });
});

describe("previewMetadataCommand", () => {
  it("calls project.previewMetadataCommand with the frameIndex and returns the result", async () => {
    const { request, calls } = capturingRequest(PREVIEW);
    await expect(previewMetadataCommand(request, 7)).resolves.toEqual(PREVIEW);
    expect(calls).toEqual([
      { method: "project.previewMetadataCommand", params: { frameIndex: 7 } },
    ]);
  });

  it("propagates a rejection from the request unchanged", async () => {
    const error = { code: "INVALID_PARAMS", message: "no such frame", recoverable: false };
    const request = (): Promise<unknown> => Promise.reject(error);
    await expect(previewMetadataCommand(request, 99)).rejects.toBe(error);
  });
});

describe("applyMetadata", () => {
  it("calls project.applyMetadata with only frameIndex (never an argument list) and returns the result", async () => {
    const { request, calls } = capturingRequest(APPLY);
    await expect(applyMetadata(request, 1)).resolves.toEqual(APPLY);
    expect(calls).toEqual([{ method: "project.applyMetadata", params: { frameIndex: 1 } }]);
    // Safety property (T-07-01): the only param ever sent is frameIndex.
    expect(Object.keys(calls[0].params as Record<string, unknown>)).toEqual(["frameIndex"]);
  });

  it("returns null (never throws) when the request rejects", async () => {
    const request = (): Promise<unknown> =>
      Promise.reject({ code: "INVALID_PARAMS", message: "no scanned outputs yet", recoverable: false });
    await expect(applyMetadata(request, 1)).resolves.toBeNull();
  });
});

describe("setRollMetadata", () => {
  it("sends the complete MetadataSet object, never a partial diff", async () => {
    const { request, calls } = capturingRequest({ project: PROJECT });
    const result = await setRollMetadata(request, ROLL_METADATA);
    expect(calls).toEqual([{ method: "project.setRollMetadata", params: { metadata: ROLL_METADATA } }]);
    expect(result.project).toEqual(PROJECT);
  });

  it("propagates a rejection from the request unchanged", async () => {
    const error = { code: "PROJECT_NOT_FOUND", message: "no project open", recoverable: false };
    const request = (): Promise<unknown> => Promise.reject(error);
    await expect(setRollMetadata(request, ROLL_METADATA)).rejects.toBe(error);
  });
});

describe("setFrameMetadataOverride", () => {
  it("sends the complete override object, never a per-field merge", async () => {
    const { request, calls } = capturingRequest({ project: PROJECT });
    const result = await setFrameMetadataOverride(request, 3, ROLL_METADATA);
    expect(calls).toEqual([
      {
        method: "project.setFrameMetadataOverride",
        params: { frameIndex: 3, metadata: ROLL_METADATA },
      },
    ]);
    expect(result.project).toEqual(PROJECT);
  });

  it("clears the override with null, reverting to the roll-wide default", async () => {
    const { request, calls } = capturingRequest({ project: PROJECT });
    await setFrameMetadataOverride(request, 3, null);
    expect(calls).toEqual([
      { method: "project.setFrameMetadataOverride", params: { frameIndex: 3, metadata: null } },
    ]);
  });

  it("propagates a rejection from the request unchanged", async () => {
    const error = { code: "INVALID_PARAMS", message: "no such frame", recoverable: false };
    const request = (): Promise<unknown> => Promise.reject(error);
    await expect(setFrameMetadataOverride(request, 99, ROLL_METADATA)).rejects.toBe(error);
  });
});
