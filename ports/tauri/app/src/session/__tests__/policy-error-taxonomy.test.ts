// Error taxonomy policy tests (04-03 Task 3). PROTOCOL.md Error codes:
// frameErrors' code/message/recoverable must always be exactly what the
// wire event carried -- never recomputed, never overwritten by an unrelated
// event; every local pre-wire-call policy rejection uses the identical
// {code, message, recoverable} EngineError shape; frameAttempts progress
// correctly across a FEED_JAM retry sequence (attempt 1 failed, attempt 2
// active -- the demo fault-injection shape).

import { describe, expect, it } from "vitest";
import { SessionStore } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type { ScriptedRequestOutcome } from "../testing/harness";
import { isEngineError } from "../wire/types";
import type { CaptureRecipe, EngineError } from "../wire/types";

const CAPTURE_RECIPE = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 1,
  channels: "rgbi",
} satisfies CaptureRecipe;

const FEED_JAM: EngineError = {
  code: "FEED_JAM",
  message: "Simulated feed jam on frame 13",
  recoverable: true,
};

const MANUAL_REVIEW: EngineError = {
  code: "MANUAL_REVIEW_REQUIRED",
  message: "frame 13 requires manual review before scanning",
  recoverable: false,
};

function scriptedStore(onRequest: (method: string, params: unknown) => ScriptedRequestOutcome) {
  const calls: { method: string; params: unknown }[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params });
      return onRequest(method, params);
    },
  });
  const store = new SessionStore(handle.transport);
  return { store, handle, calls };
}

describe("SessionStore error taxonomy (scripted transport)", () => {
  it("preserves error.recoverable verbatim from scan.frameState events (true and false cases)", async () => {
    const { store, handle } = scriptedStore((method) =>
      method === "scan.start" ? { result: { jobId: "job-1" } } : { result: undefined },
    );
    await store.startScan([13], CAPTURE_RECIPE);

    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 1 },
    });
    handle.emitEvent({
      event: "scan.frameState",
      payload: {
        jobId: "job-1",
        frameIndex: 13,
        state: "failed",
        attempt: 1,
        error: FEED_JAM,
      },
    });
    expect(store.getState().frameErrors[13]).toEqual(FEED_JAM);
    expect(store.getState().frameErrors[13]?.recoverable).toBe(true);

    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 2 },
    });
    handle.emitEvent({
      event: "scan.frameState",
      payload: {
        jobId: "job-1",
        frameIndex: 13,
        state: "failed",
        attempt: 2,
        error: MANUAL_REVIEW,
      },
    });
    expect(store.getState().frameErrors[13]).toEqual(MANUAL_REVIEW);
    expect(store.getState().frameErrors[13]?.recoverable).toBe(false);
  });

  it("tracks per-frame attempt count across a FEED_JAM retry sequence matching the demo fault-injection shape (attempt 1 failed, attempt 2 active)", async () => {
    const { store, handle } = scriptedStore((method) =>
      method === "scan.start" ? { result: { jobId: "job-1" } } : { result: undefined },
    );
    await store.startScan([13], CAPTURE_RECIPE);
    expect(store.getState().frameStates[13]).toBe("waiting");

    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 1 },
    });
    expect(store.getState().frameStates[13]).toBe("active");
    expect(store.getState().frameAttempts[13]).toBe(1);

    handle.emitEvent({
      event: "scan.frameState",
      payload: {
        jobId: "job-1",
        frameIndex: 13,
        state: "failed",
        attempt: 1,
        error: FEED_JAM,
      },
    });
    expect(store.getState().frameStates[13]).toBe("failed");
    expect(store.getState().frameAttempts[13]).toBe(1);
    expect(store.getState().frameErrors[13]).toEqual(FEED_JAM);

    // The engine automatically retries once: attempt 2 goes active and the
    // error is cleared (the jam is resolved).
    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 2 },
    });
    expect(store.getState().frameStates[13]).toBe("active");
    expect(store.getState().frameAttempts[13]).toBe(2);
    expect(store.getState().frameErrors[13]).toBeUndefined();

    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "completed", attempt: 2 },
    });
    expect(store.getState().frameStates[13]).toBe("completed");
    expect(store.getState().frameAttempts[13]).toBe(2);
  });

  it("a local pre-validation rejection (from needsApproval gating or recipe mirroring) uses the identical EngineError shape as a wire-sourced error", async () => {
    // Local rejection: needsApproval gating.
    const { store, handle, calls } = scriptedStore((method) => {
      switch (method) {
        case "scanner.acquireThumbnails":
          return { result: { accepted: true, frames: [1] } };
        default:
          return { result: undefined };
      }
    });
    await store.acquireThumbnails();
    const opId = calls[0].params as { operationId: string };
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex: 1,
        thumbnail: { brightness: 0.5, tint: 0.1, needsApproval: true },
        operationId: opId.operationId,
      },
    });
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId: opId.operationId },
    });

    let local: unknown;
    try {
      await store.startScan([1], CAPTURE_RECIPE);
    } catch (error) {
      local = error;
    }

    // Wire-sourced rejection: scan.start itself fails.
    const { store: wireStore } = scriptedStore((method) => {
      if (method === "scan.start") {
        return {
          error: { code: "SCANNER_BUSY", message: "lane busy", recoverable: false },
        };
      }
      return { result: undefined };
    });
    let wire: unknown;
    try {
      await wireStore.startScan([1], CAPTURE_RECIPE);
    } catch (error) {
      wire = error;
    }

    expect(isEngineError(local)).toBe(true);
    expect(isEngineError(wire)).toBe(true);
    // Both are plain {code, message, recoverable} objects with no other
    // fields -- the identical EngineError shape.
    expect(Object.keys(local as EngineError).sort()).toEqual(["code", "message", "recoverable"]);
    expect(Object.keys(wire as EngineError).sort()).toEqual(["code", "message", "recoverable"]);
    expect(local).toMatchObject({ code: "INVALID_PARAMS", recoverable: false });
    expect(typeof (local as EngineError).message).toBe("string");
  });

  it("never overwrites a wire-sourced error's code/message/recoverable fields when a subsequent unrelated event arrives", async () => {
    const { store, handle } = scriptedStore((method) =>
      method === "scan.start" ? { result: { jobId: "job-1" } } : { result: undefined },
    );
    await store.startScan([13], CAPTURE_RECIPE);

    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 1 },
    });
    handle.emitEvent({
      event: "scan.frameState",
      payload: {
        jobId: "job-1",
        frameIndex: 13,
        state: "failed",
        attempt: 1,
        error: FEED_JAM,
      },
    });
    expect(store.getState().frameErrors[13]).toEqual(FEED_JAM);

    // Unrelated events must not touch the recorded error.
    handle.emitEvent({
      event: "scan.jobState",
      payload: { jobId: "job-1", state: "scanning" },
    });
    handle.emitEvent({
      event: "scanner.status",
      payload: {
        status: {
          connected: true,
          adapter: null,
          mediaLoaded: true,
          carrier: "roll36",
          frameCount: 36,
          lamp: "stable",
          transport: "busy",
          activeJobId: "job-1",
        },
      },
    });
    handle.emitEvent({
      event: "scan.progress",
      payload: {
        jobId: "job-1",
        frameIndex: 13,
        frameOrdinal: 1,
        totalFrames: 1,
        pass: 1,
        totalPasses: 1,
        framePercent: 40,
        jobPercent: 40,
        etaSeconds: 1.5,
      },
    });

    expect(store.getState().frameErrors[13]).toEqual(FEED_JAM);
    expect(store.getState().frameErrors[13]?.code).toBe("FEED_JAM");
    expect(store.getState().frameErrors[13]?.message).toBe(FEED_JAM.message);
    expect(store.getState().frameErrors[13]?.recoverable).toBe(true);
  });
});
