// needsApproval gating policy tests (04-03 Task 1). PROTOCOL.md Thumbnail
// type notes: before scan.start every requested frame's current
// completed-preview thumbnail must be inspected; any needsApproval: true
// frame needs recorded approval under the SAME operationId as the current
// completed preview. A violation blocks the ENTIRE batch locally -- starting
// an approved subset and retrying the omitted frame as a second job is not
// equivalent and is structurally impossible here (no partial-subset code
// path exists).

import { describe, expect, it } from "vitest";
import { SessionStore } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type { CaptureRecipe, EngineError } from "../wire/types";

const CAPTURE_RECIPE = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 1,
  channels: "rgbi",
} satisfies CaptureRecipe;

function approvalStore() {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      switch (method) {
        case "scanner.acquireThumbnails":
          return { result: { accepted: true, frames: [1, 13] } };
        case "roll.approve":
          return { result: {} };
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

async function completePreviewWithApprovalFlags(
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

describe("SessionStore needsApproval gating (scripted transport)", () => {
  it("blocks scan.start locally when a requested frame needsApproval and has no recorded approval", async () => {
    const { store, handle, calls } = approvalStore();
    await completePreviewWithApprovalFlags(store, handle, calls, [1, 13]);

    let caught: unknown;
    try {
      await store.startScan([1, 13], CAPTURE_RECIPE);
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeDefined();
    expect(caught).not.toBeInstanceOf(Error);
    const engineError = caught as EngineError;
    expect(engineError.code).toBe("INVALID_PARAMS");
    expect(typeof engineError.message).toBe("string");
    expect(engineError.message).toMatch(/1/);
    expect(engineError.message).toMatch(/13/);
    expect(engineError.recoverable).toBe(false);
    // No wire call, and no optimistic job seeding either.
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(0);
    expect(store.getState().jobState).toBeNull();
  });

  it("allows scan.start when all needsApproval frames have matching recorded approval", async () => {
    const { store, handle, calls } = approvalStore();
    await completePreviewWithApprovalFlags(store, handle, calls, [1, 13]);

    await store.approveFrame(1);
    await store.approveFrame(13);
    const result = await store.startScan([1, 13], CAPTURE_RECIPE);

    expect(result.jobId).toBe("job-1");
    const scanCall = calls.find((call) => call.method === "scan.start");
    expect(scanCall).toBeDefined();
    expect((scanCall?.params as { frames: number[] }).frames).toEqual([1, 13]);
    expect(store.getState().jobState).toBe("queued");
  });

  it("rejects the entire batch rather than silently dropping the unapproved frame", async () => {
    const { store, handle, calls } = approvalStore();
    await completePreviewWithApprovalFlags(store, handle, calls, [1, 13]);

    // Only frame 1 is approved; frame 13 is not.
    await store.approveFrame(1);

    let caught: unknown;
    try {
      await store.startScan([1, 13], CAPTURE_RECIPE);
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeDefined();
    const engineError = caught as EngineError;
    expect(engineError.code).toBe("INVALID_PARAMS");
    expect(engineError.recoverable).toBe(false);
    expect(engineError.message).toMatch(/13/);
    // The whole batch was blocked -- nothing was filtered and submitted.
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(0);
    expect(store.getState().jobState).toBeNull();
  });

  it("approval recorded under a stale (superseded) operationId does not satisfy the gate", async () => {
    const { store, handle, calls } = approvalStore();

    await completePreviewWithApprovalFlags(store, handle, calls, [1]);
    await store.approveFrame(1);
    expect(store.getState().approvedFrames).toBeDefined();

    // A second preview supersedes the first operationId; the thumbnails are
    // re-emitted under the new token, and the old approval must not count.
    const second = await completePreviewWithApprovalFlags(store, handle, calls, [1]);
    expect(store.getState().latestCompletedPreviewOperationId).toBe(second);

    let caught: unknown;
    try {
      await store.startScan([1], CAPTURE_RECIPE);
    } catch (error) {
      caught = error;
    }
    expect((caught as EngineError).code).toBe("INVALID_PARAMS");
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(0);
  });
});
