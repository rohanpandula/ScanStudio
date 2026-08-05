// Override-setter policy tests (06-02 Task 3): the store's three
// project.setFrame*Override wrappers must implement whole-object-swap
// semantics -- a populated recipe replaces the frame's override in full
// (never a merged patch), `null` reverts the frame to the roll default, and
// the server-returned project becomes the new authoritative project state.

import { describe, expect, it } from "vitest";
import { SessionStore } from "../session";
import { createScriptedTransport } from "../../testing/harness";
import {
  isScanProject,
  type CaptureRecipe,
  type ProcessingRecipe,
  type ScanProject,
} from "../../wire/types";

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-1",
  name: "Override Roll",
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

const CAPTURE: CaptureRecipe = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 1,
  channels: "rgbi",
};

const PROCESSING: ProcessingRecipe = {
  filmProcess: "c41ColorNegative",
  autofocusEachFrame: true,
  autoExposureEachFrame: false,
  digitalIceEnabled: true,
  digitalIceMode: "hybrid",
  softwareDustRemovalBw: false,
};

function projectWithOverrides(overrides: Partial<{ capture: CaptureRecipe }>): ScanProject {
  return {
    ...PROJECT,
    frames: [
      {
        index: 1,
        excluded: false,
        receipts: [],
        ...(overrides.capture ? { captureOverride: overrides.capture } : {}),
      },
    ],
  };
}

describe("setFrameCaptureOverride whole-object swap semantics", () => {
  it("sends the complete recipe object, never a merged patch", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params: params as Record<string, unknown> });
        return { result: { project: projectWithOverrides({ capture: CAPTURE }) } };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.setFrameCaptureOverride(1, CAPTURE);
    expect(calls[0].method).toBe("project.setFrameCaptureOverride");
    expect(calls[0].params.frameIndex).toBe(1);
    // Whole-object swap: the params payload is exactly the full recipe.
    expect(calls[0].params.capture).toEqual(CAPTURE);
    expect(store.getState().project?.frames[0].captureOverride).toEqual(CAPTURE);
  });

  it("clears the override with null, reverting to the roll default", async () => {
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        expect(method).toBe("project.setFrameCaptureOverride");
        expect((params as { capture?: unknown }).capture).toBeNull();
        return { result: { project: PROJECT } };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.setFrameCaptureOverride(1, null);
    expect(store.getState().project?.frames[0].captureOverride).toBeUndefined();
  });

  it("adopts the server-returned project as the authoritative state", async () => {
    const updated = projectWithOverrides({ capture: { ...CAPTURE, resolutionDpi: 2000 } });
    const handle = createScriptedTransport({
      onRequest: () => ({ result: { project: updated } }),
    });
    const store = new SessionStore(handle.transport);
    await store.setFrameCaptureOverride(1, CAPTURE);
    const project = store.getState().project;
    expect(project).not.toBeNull();
    expect(isScanProject(project)).toBe(true);
    expect(project?.frames[0].captureOverride?.resolutionDpi).toBe(2000);
  });
});

describe("setFrameProcessingOverride whole-object swap semantics", () => {
  it("sends the complete processing recipe object", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params: params as Record<string, unknown> });
        return { result: { project: PROJECT } };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.setFrameProcessingOverride(1, PROCESSING);
    expect(calls[0].method).toBe("project.setFrameProcessingOverride");
    expect(calls[0].params.processing).toEqual(PROCESSING);
  });
});

describe("setFrameOutputOverride whole-object swap semantics", () => {
  it("sends the complete output recipe object", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params: params as Record<string, unknown> });
        return { result: { project: PROJECT } };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.setFrameOutputOverride(1, PROJECT.recipes);
    expect(calls[0].method).toBe("project.setFrameOutputOverride");
    expect(calls[0].params.output).toEqual(PROJECT.recipes);
  });
});
