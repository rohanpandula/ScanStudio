// Metadata store policy tests (07-01 Task 1): the additive SessionStore
// methods (detectExifTool / previewMetadataCommand / applyMetadata /
// setRollMetadata / setFrameMetadataOverride) must delegate to the metadata
// wrapper module with the exact wire method/param pairs, adopt the
// server-returned project for the setters, and mirror the metadata module's
// applyMetadata nil-on-failure pattern. Real SessionStore over
// createScriptedTransport (fixture mode), asserting the transport payloads.

import { describe, expect, it } from "vitest";
import { SessionStore } from "../session";
import { createScriptedTransport } from "../../testing/harness";
import type {
  ApplyMetadataResult,
  ExifToolDetection,
  MetadataSet,
  PreviewMetadataCommandResult,
  ScanProject,
} from "../../wire/types";

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

const DETECTION: ExifToolDetection = {
  available: true,
  path: "/usr/bin/exiftool",
  version: "12.76",
};

const PREVIEW: PreviewMetadataCommandResult = {
  available: true,
  exiftoolPath: "/usr/bin/exiftool",
  targets: ["/out/IMG_0001.tiff"],
  arguments: ["-CameraModel=Nikon F6", "-overwrite_original", "/out/IMG_0001.tiff"],
};

const APPLY: ApplyMetadataResult = {
  success: true,
  exitCode: 0,
  stdout: "    1 image files updated",
  stderr: "",
  targets: ["/out/IMG_0001.tiff"],
};

interface Call {
  method: string;
  params: Record<string, unknown>;
}

function fixture(
  onRequest: (method: string, params: unknown) => { result?: unknown; error?: never } | undefined,
): { store: SessionStore; calls: Call[] } {
  const calls: Call[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      return { result: onRequest(method, params)?.result };
    },
  });
  const store = new SessionStore(handle.transport);
  return { store, calls };
}

describe("setRollMetadata", () => {
  it("sends the complete MetadataSet and adopts the server-returned project", async () => {
    const updated = { ...PROJECT, rollMetadata: ROLL_METADATA };
    const { store, calls } = fixture(() => ({ result: { project: updated } }));
    await store.setRollMetadata(ROLL_METADATA);
    expect(calls).toEqual([
      { method: "project.setRollMetadata", params: { metadata: ROLL_METADATA } },
    ]);
    expect(store.getState().project?.rollMetadata).toEqual(ROLL_METADATA);
  });
});

describe("setFrameMetadataOverride", () => {
  it("sends the complete override object and adopts the server-returned project", async () => {
    const updated = {
      ...PROJECT,
      frames: [{ index: 3, excluded: false, receipts: [], metadataOverride: ROLL_METADATA }],
    };
    const { store, calls } = fixture(() => ({ result: { project: updated } }));
    await store.setFrameMetadataOverride(3, ROLL_METADATA);
    expect(calls).toEqual([
      {
        method: "project.setFrameMetadataOverride",
        params: { frameIndex: 3, metadata: ROLL_METADATA },
      },
    ]);
    expect(store.getState().project?.frames[0].metadataOverride).toEqual(ROLL_METADATA);
  });

  it("clears the override with null, reverting to the roll-wide default", async () => {
    const { store, calls } = fixture(() => ({ result: { project: PROJECT } }));
    await store.setFrameMetadataOverride(3, null);
    expect(calls).toEqual([
      {
        method: "project.setFrameMetadataOverride",
        params: { frameIndex: 3, metadata: null },
      },
    ]);
    expect(store.getState().project?.frames[0].metadataOverride).toBeUndefined();
  });
});

describe("detectExifTool / previewMetadataCommand / applyMetadata delegation", () => {
  it("detectExifTool calls exiftool.detect with empty params and returns the detection", async () => {
    const { store, calls } = fixture(() => ({ result: DETECTION }));
    await expect(store.detectExifTool()).resolves.toEqual(DETECTION);
    expect(calls).toEqual([{ method: "exiftool.detect", params: {} }]);
  });

  it("previewMetadataCommand calls project.previewMetadataCommand with the frameIndex", async () => {
    const { store, calls } = fixture(() => ({ result: PREVIEW }));
    await expect(store.previewMetadataCommand(7)).resolves.toEqual(PREVIEW);
    expect(calls).toEqual([
      { method: "project.previewMetadataCommand", params: { frameIndex: 7 } },
    ]);
  });

  it("applyMetadata sends only frameIndex (never an argument list) and returns the result", async () => {
    const { store, calls } = fixture(() => ({ result: APPLY }));
    await expect(store.applyMetadata(1)).resolves.toEqual(APPLY);
    expect(calls).toEqual([{ method: "project.applyMetadata", params: { frameIndex: 1 } }]);
    expect(Object.keys(calls[0].params)).toEqual(["frameIndex"]);
  });

  it("applyMetadata returns null (never throws) when the wire call rejects", async () => {
    const reject = { code: "INVALID_PARAMS", message: "frame has no scanned outputs yet", recoverable: false };
    const handle = createScriptedTransport({
      onRequest: () => ({ error: reject }),
    });
    const store = new SessionStore(handle.transport);
    await expect(store.applyMetadata(1)).resolves.toBeNull();
  });
});
