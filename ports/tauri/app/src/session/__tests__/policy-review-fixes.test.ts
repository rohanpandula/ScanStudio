// Review-driven regression tests (Phase 4 peer review, 2026-08-03):
// every HIGH/MEDIUM finding of the Phase 4 review gets a named regression
// test here. The fixes live in store/session.ts, fixtures.test.ts, and
// scripts/verify-app.sh; this file proves the fail-closed behavior holds:
//
// - HIGH 1: thumbnails are bound to the preview operationId that produced
//   them; a tile from a superseded preview cannot authorize a scan.
// - HIGH 2: scan.* events are jobId-scoped; events for another job are
//   dropped, and events arriving before the scan.start response are buffered
//   until the jobId is established.
// - HIGH 3: clearing a frame-alignment draft also clears its replay failure;
//   opening/creating a project resets preview bindings, approvals, and
//   rebuilds alignment drafts from the loaded project.
// - MEDIUM 1: getState() returns a deep clone; nested mutation cannot
//   corrupt store state.

import { describe, expect, it } from "vitest";
import { SessionStore } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type { EngineTransport } from "../wire/codec";
import type {
  CaptureRecipe,
  EngineError,
  ScanProject,
  WireEvent,
} from "../wire/types";

const CAPTURE_RECIPE = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 1,
  channels: "rgbi",
} satisfies CaptureRecipe;

const PROJECT_WITH_ALIGNED_FRAME: ScanProject = {
  schemaVersion: 4,
  id: "proj-b",
  name: "Roll B",
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
  frames: [
    { index: 2, excluded: false, alignment: { offsetRows: 9, approved: true }, receipts: [] },
  ],
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

function approvalStore(overrides?: {
  setSpacingOffset?: (params: Record<string, unknown>) => { error: EngineError };
}) {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      switch (method) {
        case "scanner.acquireThumbnails":
          return { result: { accepted: true, frames: [1, 2, 13] } };
        case "roll.approve":
          return { result: {} };
        case "roll.setSpacingOffset":
          if (overrides?.setSpacingOffset) return overrides.setSpacingOffset(params as Record<string, unknown>);
          return {
            result: {
              thumbnail: { imagePath: "/preview/frame-new.png", spacingOffset: 9 },
            },
          };
        case "project.setFrameAlignment":
          return { result: { project: PROJECT_WITH_ALIGNED_FRAME } };
        case "project.open":
          return { result: { project: PROJECT_WITH_ALIGNED_FRAME, directory: "/proj-b" } };
        case "scan.start":
          return { result: { jobId: "job-1" } };
        default:
          return { result: undefined };
      }
    },
  });
  return { store: new SessionStore(handle.transport), handle, calls };
}

async function completePreview(
  store: SessionStore,
  handle: ReturnType<typeof createScriptedTransport>,
  calls: { method: string; params: Record<string, unknown> }[],
  frames: number[],
): Promise<string> {
  const before = calls.length;
  await store.acquireThumbnails(frames);
  const opId = (calls[before].params as { operationId: string }).operationId;
  for (const frame of frames) {
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex: frame,
        thumbnail: { brightness: 0.5, tint: 0.1, needsApproval: true },
        operationId: opId,
      },
    });
  }
  handle.emitEvent({
    event: "scanner.thumbnailsComplete",
    payload: { count: frames.length, operationId: opId },
  });
  expect(store.getState().latestCompletedPreviewOperationId).toBe(opId);
  return opId;
}

describe("Phase 4 peer-review fixes", () => {
  it("stale thumbnail bound to a superseded preview blocks scan.start (cross-preview frame subsets fail closed)", async () => {
    const { store, handle, calls } = approvalStore();

    // Preview A covers only frame 1; preview B covers only frame 13. Frame
    // 1's tile is bound to A's operationId, which is no longer current.
    await completePreview(store, handle, calls, [1]);
    await completePreview(store, handle, calls, [13]);
    await store.approveFrame(13);

    let caught: unknown;
    try {
      await store.startScan([1, 13], CAPTURE_RECIPE);
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeDefined();
    const engineError = caught as EngineError;
    expect(engineError.code).toBe("INVALID_PARAMS");
    expect(engineError.message).toMatch(/superseded preview/);
    expect(engineError.message).toMatch(/1/);
    // Frame 13's approval exists and its tile is current; frame 1's stale
    // tile blocks the WHOLE batch -- no partial-subset submission.
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(0);

    // A fresh preview covering both frames re-binds the tiles, and with
    // every needsApproval tile approved the batch then passes.
    await completePreview(store, handle, calls, [1, 13]);
    await store.approveFrame(1);
    await store.approveFrame(13);
    await expect(store.startScan([1, 13], CAPTURE_RECIPE)).resolves.toMatchObject({
      jobId: "job-1",
    });
  });

  it("scan events for a stale jobId are dropped, never applied to the current job", async () => {
    const { store, handle } = approvalStore();
    const integrityErrors: unknown[] = [];
    store.onIntegrityError((error) => integrityErrors.push(error));

    await store.startScan([1], CAPTURE_RECIPE);
    handle.emitEvent({
      event: "scan.jobState",
      payload: { jobId: "job-1", state: "scanning" },
    } satisfies WireEvent);
    expect(store.getState().jobState).toBe("scanning");

    // A completed event for a DIFFERENT job must not resolve this job --
    // dropped silently, no integrity error, no state change.
    handle.emitEvent({
      event: "scan.jobState",
      payload: { jobId: "job-999", state: "completed" },
    } satisfies WireEvent);
    expect(store.getState().jobState).toBe("scanning");
    expect(integrityErrors).toHaveLength(0);

    // Frame events for the foreign job are dropped too.
    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-999", frameIndex: 1, state: "completed", attempt: 1 },
    } satisfies WireEvent);
    expect(store.getState().frameStates[1]).toBe("waiting");
    expect(integrityErrors).toHaveLength(0);
  });

  it("scan events arriving before the scan.start response are buffered and applied once the jobId is established", async () => {
    let subscribe: ((raw: unknown) => void) | undefined;
    let resolveStart: ((value: unknown) => void) | undefined;
    const transport: EngineTransport = {
      sendRequest: (method) => {
        if (method === "scan.start") {
          return new Promise((resolve) => {
            resolveStart = (value) => resolve(value);
          });
        }
        return Promise.resolve(undefined);
      },
      subscribeEvents: (callback) => {
        subscribe = callback;
        return () => {};
      },
    };
    const store = new SessionStore(transport);
    const integrityErrors: unknown[] = [];
    store.onIntegrityError((error) => integrityErrors.push(error));

    const pending = store.startScan([1], CAPTURE_RECIPE);

    // The engine can enqueue the job's first events ahead of the response
    // line (single-writer stdout). They arrive while jobId is still null.
    subscribe!({
      event: "scan.jobState",
      payload: { jobId: "job-early", state: "scanning" },
    } satisfies WireEvent);
    subscribe!({
      event: "scan.frameState",
      payload: { jobId: "job-early", frameIndex: 1, state: "active", attempt: 1 },
    } satisfies WireEvent);
    // A stale event from a previous job arriving in the same window.
    subscribe!({
      event: "scan.jobState",
      payload: { jobId: "job-old", state: "completed" },
    } satisfies WireEvent);
    // Buffered: nothing applied yet.
    expect(store.getState().jobState).toBe("queued");
    expect(store.getState().frameStates[1]).toBe("waiting");

    resolveStart!({ jobId: "job-early" });
    await pending;

    expect(store.getState().jobState).toBe("scanning");
    expect(store.getState().frameStates[1]).toBe("active");
    expect(store.getState().frameAttempts[1]).toBe(1);
    expect(integrityErrors).toHaveLength(0);

    // The stale job's event was dropped during the replay, not applied.
    expect(store.getState().jobState).toBe("scanning");
  });

  it("clearing a frame alignment draft removes a prior replay failure", async () => {
    const { store, handle, calls } = approvalStore({
      setSpacingOffset: () => ({
        error: {
          code: "INTERNAL",
          message: "replay refused",
          recoverable: false,
        } satisfies EngineError,
      }),
    });

    // Save a draft, then complete a preview: the automatic replay fails and
    // the frame lands in failedFrameAlignmentReplayIndices (the replay runs
    // asynchronously after thumbnailsComplete, so wait for it).
    await store.setFrameAlignmentDraft(2, { offsetRows: 9, approved: true });
    await completePreview(store, handle, calls, [2]);
    await waitFor(() => store.getState().failedFrameAlignmentReplayIndices.has(2));
    expect(store.getState().failedFrameAlignmentReplayIndices.has(2)).toBe(true);

    // Scanning stays unavailable while the replay has not succeeded (with
    // frame 2 approved, the only remaining block is the replay gate).
    await store.approveFrame(2);
    let caught: unknown;
    try {
      await store.startScan([2], CAPTURE_RECIPE);
    } catch (error) {
      caught = error;
    }
    expect((caught as EngineError).message).toMatch(/replay/i);
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(0);

    // Clearing the draft removes both the draft and its replay failure; the
    // approval recorded above remains valid (same preview token).
    await store.setFrameAlignmentDraft(2, null);
    expect(store.getState().failedFrameAlignmentReplayIndices.has(2)).toBe(false);
    await expect(store.startScan([2], CAPTURE_RECIPE)).resolves.toMatchObject({
      jobId: "job-1",
    });
  });

  it("opening a project resets preview bindings, approvals, and rebuilds alignment drafts from the loaded project", async () => {
    const { store, handle, calls } = approvalStore();

    // Approval + preview state from project A.
    await completePreview(store, handle, calls, [1]);
    await store.approveFrame(1);
    expect(store.getState().approvedFrames).not.toEqual({});
    expect(store.getState().latestCompletedPreviewOperationId).not.toBeNull();

    // Open project B: token cleared, approvals unreachable, drafts rebuilt
    // from B's own frames, replay-failure set empty.
    await store.openProject("/proj-b");
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();
    expect(store.getState().approvedFrames).toEqual({});
    expect(store.getState().frameAlignmentDrafts[2]).toEqual({
      offsetRows: 9,
      approved: true,
    });
    expect(store.getState().failedFrameAlignmentReplayIndices.size).toBe(0);
    expect(store.getState().jobId).toBeNull();

    // Nothing from project A leaks: frame 1's tile is now unbound (its
    // provenance belonged to project A's preview), so scanning it fails
    // closed until a fresh preview under project B re-binds it.
    let caught: unknown;
    try {
      await store.startScan([1], CAPTURE_RECIPE);
    } catch (error) {
      caught = error;
    }
    expect((caught as EngineError).code).toBe("INVALID_PARAMS");
    expect((caught as EngineError).message).toMatch(/superseded preview/);
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(0);

    // A fresh preview + approval under project B restores scanning.
    await completePreview(store, handle, calls, [1]);
    await store.approveFrame(1);
    await expect(store.startScan([1], CAPTURE_RECIPE)).resolves.toMatchObject({
      jobId: "job-1",
    });
  });

  it("getState() returns a deep snapshot: mutating nested collections cannot corrupt store state", async () => {
    const { store, handle, calls } = approvalStore();
    await completePreview(store, handle, calls, [1]);
    await store.approveFrame(1);
    await store.startScan([1], CAPTURE_RECIPE);

    const snap = store.getState();
    // Nested mutations on the snapshot must not reach the store.
    snap.frameStates[1] = "completed";
    snap.frameAttempts[1] = 99;
    snap.failedFrameAlignmentReplayIndices.add(5);
    snap.frameReceipts[1] = [];
    snap.thumbnails[7] = { brightness: 0.9, tint: 0.4 };

    const fresh = store.getState();
    expect(fresh.frameStates[1]).toBe("waiting");
    expect(fresh.frameAttempts[1]).toBeUndefined();
    expect(fresh.failedFrameAlignmentReplayIndices.has(5)).toBe(false);
    expect(fresh.frameReceipts[1]).toBeUndefined();
    expect(fresh.thumbnails[7]).toBeUndefined();
  });
});
