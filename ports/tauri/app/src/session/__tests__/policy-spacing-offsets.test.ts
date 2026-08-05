// Spacing offset + frame-alignment replay policy tests (04-03 Task 2).
// PROTOCOL.md roll.setSpacingOffset: frame 1 accepts 0..144, every other
// frame -144..144, local validation before the one bridge call; the returned
// thumbnail carries the bridge-confirmed offset and a fresh imagePath, and
// changing the offset invalidates prior manual approval. project.setFrameAlignment
// saves a DRAFT that must replay through roll.setSpacingOffset after the next
// successful preview; scanning stays unavailable while replay has not
// succeeded.

import { describe, expect, it } from "vitest";
import { SessionStore } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type {
  CaptureRecipe,
  EngineError,
  ScanProject,
  Thumbnail,
} from "../wire/types";

const CAPTURE_RECIPE = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 1,
  channels: "rgbi",
} satisfies CaptureRecipe;

const REPLACEMENT_TILE: Thumbnail = {
  imagePath: "/preview/frame-1-new.png",
  boundaryRows: [10, 20],
  spacingOffset: 55,
  needsApproval: true,
};

const MINIMAL_PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-1",
  name: "Test Roll",
  carrier: "roll36",
  frameCount: 36,
  filmProcess: "positive",
  recipes: {
    archive: {
      enabled: true,
      filenameTemplate: "a.tiff",
      destination: "/out",
      fullCapturePackage: true,
    },
    positive: {
      enabled: true,
      fileFormat: "tiff",
      colorProfile: "sRgb",
      filenameTemplate: "p.tiff",
      destination: "/out",
    },
    preview: {
      enabled: false,
      fileFormat: "jpeg",
      maxLongEdgePx: 1024,
      filenameTemplate: "v.jpg",
      destination: "/out",
    },
  },
  rollMetadata: { keywords: [] },
  createdAt: "2026-07-22T09:00:00Z",
  frames: [],
};

async function waitFor(predicate: () => boolean, timeoutMs = 5000): Promise<void> {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error("waitFor timed out");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

interface SpacingStoreHandle {
  store: SessionStore;
  handle: ReturnType<typeof createScriptedTransport>;
  calls: { method: string; params: Record<string, unknown> }[];
}

function spacingStore(overrides?: {
  setSpacingOffset?: (params: Record<string, unknown>) => { result?: unknown; error?: EngineError };
}): SpacingStoreHandle {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      switch (method) {
        case "scanner.acquireThumbnails":
          return { result: { accepted: true, frames: [1, 2] } };
        case "roll.approve":
          return { result: {} };
        case "roll.setSpacingOffset":
          if (overrides?.setSpacingOffset) return overrides.setSpacingOffset(params as Record<string, unknown>);
          return { result: { thumbnail: { ...REPLACEMENT_TILE } } };
        case "project.setFrameAlignment":
          return { result: { project: MINIMAL_PROJECT } };
        case "scan.start":
          return { result: { jobId: "job-1" } };
        default:
          return { result: undefined };
      }
    },
  });
  const store = new SessionStore(handle.transport);
  return { store, handle, calls };
}

async function completePreview(
  store: SessionStore,
  handle: ReturnType<typeof createScriptedTransport>,
  calls: { method: string; params: Record<string, unknown> }[],
  frames: number[],
): Promise<string> {
  const before = calls.length;
  await store.acquireThumbnails();
  const opId = (calls[before].params as { operationId: string }).operationId;
  for (const frame of frames) {
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: { frameIndex: frame, thumbnail: { brightness: 0.5, tint: 0.1 }, operationId: opId },
    });
  }
  handle.emitEvent({
    event: "scanner.thumbnailsComplete",
    payload: { count: frames.length, operationId: opId },
  });
  expect(store.getState().latestCompletedPreviewOperationId).toBe(opId);
  return opId;
}

describe("SessionStore spacing offsets (scripted transport)", () => {
  it("frame 1 accepts offsetRows 0 and 144 but rejects -1 and 145", async () => {
    const { store, handle, calls } = spacingStore();
    await completePreview(store, handle, calls, [1]);

    await store.setSpacingOffset(1, 0);
    await store.setSpacingOffset(1, 144);

    for (const offset of [-1, 145]) {
      let caught: unknown;
      try {
        await store.setSpacingOffset(1, offset);
      } catch (error) {
        caught = error;
      }
      expect(caught).toBeDefined();
      expect(caught).not.toBeInstanceOf(Error);
      expect(caught as EngineError).toMatchObject({ code: "INVALID_PARAMS", recoverable: false });
    }
    // Only the two accepted values ever reached the wire.
    expect(calls.filter((call) => call.method === "roll.setSpacingOffset")).toHaveLength(2);
  });

  it("frame 2 accepts -144 and 144 but rejects -145 and 145", async () => {
    const { store, handle, calls } = spacingStore();
    await completePreview(store, handle, calls, [2]);

    await store.setSpacingOffset(2, -144);
    await store.setSpacingOffset(2, 144);

    for (const offset of [-145, 145]) {
      let caught: unknown;
      try {
        await store.setSpacingOffset(2, offset);
      } catch (error) {
        caught = error;
      }
      expect(caught as EngineError).toMatchObject({ code: "INVALID_PARAMS", recoverable: false });
    }
    expect(calls.filter((call) => call.method === "roll.setSpacingOffset")).toHaveLength(2);
  });

  it("setSpacingOffset requires a valid completed-preview operationId", async () => {
    const { store, calls } = spacingStore();

    let caught: unknown;
    try {
      await store.setSpacingOffset(1, 50);
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeDefined();
    expect(caught as EngineError).toMatchObject({ code: "INVALID_PARAMS", recoverable: false });
    expect(calls.filter((call) => call.method === "roll.setSpacingOffset")).toHaveLength(0);
  });

  it("successful response replaces the frame thumbnail with the server-returned replacement tile", async () => {
    const { store, handle, calls } = spacingStore();
    const opId = await completePreview(store, handle, calls, [1]);
    expect(store.getState().thumbnails[1]).toEqual({ brightness: 0.5, tint: 0.1 });

    await store.setSpacingOffset(1, 50);
    expect(calls).toContainEqual({
      method: "roll.setSpacingOffset",
      params: { frameIndex: 1, offsetRows: 50, operationId: opId },
    });
    // The store trusts the server-returned spacingOffset (55), never the
    // locally requested value (50) -- the tile is stored verbatim.
    expect(store.getState().thumbnails[1]).toEqual(REPLACEMENT_TILE);
    expect(store.getState().thumbnails[1]?.spacingOffset).toBe(55);
  });

  it("setting spacing offset invalidates prior recorded approval for that frame", async () => {
    const { store, handle, calls } = spacingStore();
    const opId = await completePreview(store, handle, calls, [1]);

    await store.approveFrame(1);
    expect(store.getState().approvedFrames[opId]).toContain(1);

    await store.setSpacingOffset(1, 50);
    expect(store.getState().approvedFrames[opId]).toBeUndefined();
  });

  it("a frame alignment draft replays through setSpacingOffset after the next successful preview", async () => {
    const { store, handle, calls } = spacingStore();

    await store.setFrameAlignmentDraft(1, { offsetRows: 30, approved: true });
    const opId = await completePreview(store, handle, calls, [1]);

    await waitFor(() => calls.some((call) => call.method === "roll.setSpacingOffset"));
    const replay = calls.find((call) => call.method === "roll.setSpacingOffset");
    expect(replay?.params).toEqual({ frameIndex: 1, offsetRows: 30, operationId: opId });
    // The bridge-confirmed replacement tile is installed.
    expect(store.getState().thumbnails[1]).toEqual(REPLACEMENT_TILE);
    expect(store.getState().failedFrameAlignmentReplayIndices.has(1)).toBe(false);
  });

  it("does not replay a transform-only alignment through the real-device spacing method", async () => {
    const { store, handle, calls } = spacingStore();

    await store.setFrameAlignmentDraft(1, {
      offsetRows: 0,
      approved: false,
      derivativeTransform: {
        rotationDegrees: 90,
        horizontalMirror: false,
        verticalMirror: true,
      },
    });
    await completePreview(store, handle, calls, [1]);
    await Promise.resolve();

    expect(calls.filter((call) => call.method === "roll.setSpacingOffset")).toHaveLength(0);
    expect(store.getState().pendingFrameAlignmentReplayIndices.size).toBe(0);
    expect(store.getState().failedFrameAlignmentReplayIndices.size).toBe(0);
    await expect(store.startScan([1], CAPTURE_RECIPE)).resolves.toMatchObject({ jobId: "job-1" });
  });

  it("blocks scan.start while a non-zero spacing offset is still restoring", async () => {
    const { store, handle, calls } = spacingStore({
      setSpacingOffset: () => ({
        result: { thumbnail: { ...REPLACEMENT_TILE, needsApproval: false } },
      }),
    });
    await store.setFrameAlignmentDraft(1, { offsetRows: 30, approved: false });
    await store.acquireThumbnails();
    const acquireCalls = calls.filter((call) => call.method === "scanner.acquireThumbnails");
    const acquire = acquireCalls[acquireCalls.length - 1];
    const operationId = acquire?.params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex: 1,
        thumbnail: { brightness: 0.5, tint: 0.1 },
        operationId,
      },
    });
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId },
    });

    expect(store.getState().pendingFrameAlignmentReplayIndices.has(1)).toBe(true);
    await expect(store.startScan([1], CAPTURE_RECIPE)).rejects.toMatchObject({
      code: "INVALID_PARAMS",
      recoverable: false,
    });
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(0);

    await waitFor(() => store.getState().pendingFrameAlignmentReplayIndices.size === 0);
    await expect(store.startScan([1], CAPTURE_RECIPE)).resolves.toMatchObject({ jobId: "job-1" });
  });

  it("a failed replay keeps that frame excluded from startScan until replay succeeds", async () => {
    let spacingFails = true;
    const calls: { method: string; params: Record<string, unknown> }[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params: params as Record<string, unknown> });
        switch (method) {
          case "scanner.acquireThumbnails":
            return { result: { accepted: true, frames: [1] } };
          case "roll.setSpacingOffset":
            if (spacingFails) {
              return {
                error: { code: "SCANNER_BUSY", message: "bridge lane busy", recoverable: false },
              };
            }
            // A neutral replacement tile (no needsApproval flag): this test
            // isolates the replay gate, so the tile must not also trip the
            // needsApproval gate.
            return {
              result: { thumbnail: { ...REPLACEMENT_TILE, needsApproval: false } },
            };
          case "project.setFrameAlignment":
            return { result: { project: MINIMAL_PROJECT } };
          case "scan.start":
            return { result: { jobId: "job-1" } };
          default:
            return { result: undefined };
        }
      },
    });
    const store = new SessionStore(handle.transport);

    await store.setFrameAlignmentDraft(1, { offsetRows: 30, approved: true });
    await completePreview(store, handle, calls, [1]);
    await waitFor(() => calls.some((call) => call.method === "roll.setSpacingOffset"));
    expect(store.getState().failedFrameAlignmentReplayIndices.has(1)).toBe(true);

    // Replay has not succeeded: scanning must stay unavailable, whole batch.
    let caught: unknown;
    try {
      await store.startScan([1], CAPTURE_RECIPE);
    } catch (error) {
      caught = error;
    }
    expect(caught as EngineError).toMatchObject({ code: "INVALID_PARAMS", recoverable: false });
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(0);
    expect(store.getState().jobState).toBeNull();

    // A fresh preview replays the draft again; this time it succeeds and the
    // frame becomes scannable.
    spacingFails = false;
    await completePreview(store, handle, calls, [1]);
    await waitFor(() => store.getState().failedFrameAlignmentReplayIndices.size === 0);
    await expect(store.startScan([1], CAPTURE_RECIPE)).resolves.toMatchObject({ jobId: "job-1" });
  });
});
