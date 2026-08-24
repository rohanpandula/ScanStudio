import { describe, expect, it } from "vitest";
import {
  ATTENDED_BINDING_REQUIRED_REASON,
  SessionStore,
} from "../session";
import { createScriptedTransport } from "../../testing/harness";
import type { EngineError } from "../../wire/types";

const CAPTURE = {
  resolutionDpi: 4000,
  bitDepth: 16 as const,
  multisamplePasses: 1 as const,
  channels: "rgbi" as const,
};

function attendedError(message = "driver wording may change"): EngineError {
  return {
    code: "MANUAL_REVIEW_REQUIRED",
    message,
    recoverable: false,
    reason: ATTENDED_BINDING_REQUIRED_REASON,
  };
}

async function recoveryFixture(options?: { approvalFailureAt?: number }) {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  let scanNumber = 0;
  let approvalNumber = 0;
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      if (method === "scanner.acquireThumbnails") {
        return { result: { accepted: true, frames: [2, 1] } };
      }
      if (method === "roll.approve") {
        approvalNumber += 1;
        if (approvalNumber === options?.approvalFailureAt) {
          return {
            error: {
              code: "INVALID_PARAMS",
              message: "approval no longer belongs to this preview",
              recoverable: false,
            },
          };
        }
        return { result: {} };
      }
      if (method === "scan.start") {
        scanNumber += 1;
        return { result: { jobId: `job-${scanNumber}` } };
      }
      return { result: undefined };
    },
  });
  const store = new SessionStore(handle.transport);
  await store.acquireThumbnails([2, 1]);
  const previewOperationId = calls.find(
    (call) => call.method === "scanner.acquireThumbnails",
  )!.params.operationId as string;
  for (const frameIndex of [2, 1]) {
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: { frameIndex, thumbnail: { brightness: 0.5 }, operationId: previewOperationId },
    });
  }
  handle.emitEvent({
    event: "scanner.thumbnailsComplete",
    payload: { count: 2, operationId: previewOperationId },
  });
  await store.startScan([2, 1], CAPTURE);
  return { store, handle, calls, previewOperationId };
}

function failFrame(
  handle: ReturnType<typeof createScriptedTransport>,
  frameIndex: number,
  error: EngineError,
): void {
  handle.emitEvent({
    event: "scan.frameState",
    payload: { jobId: "job-1", frameIndex, state: "active", attempt: 1 },
  });
  handle.emitEvent({
    event: "scan.frameState",
    payload: { jobId: "job-1", frameIndex, state: "failed", attempt: 1, error },
  });
}

function completeZero(
  handle: ReturnType<typeof createScriptedTransport>,
  failed: number[] = [2, 1],
): void {
  handle.emitEvent({
    event: "scan.completed",
    payload: {
      jobId: "job-1",
      summary: { completed: [], failed, skipped: [], stopped: false },
    },
  });
}

describe("zero-completed attended recovery (#76)", () => {
  it("promotes every zero-completed failure to a sequence error but only offers attended recovery when every failure has the typed reason", async () => {
    const fixture = await recoveryFixture();
    failFrame(fixture.handle, 2, attendedError("new driver wording A"));
    failFrame(fixture.handle, 1, attendedError("completely different wording B"));
    completeZero(fixture.handle);

    const eligible = fixture.store.getState();
    expect(eligible.sequenceError?.code).toBe("SCAN_ZERO_COMPLETED");
    expect(eligible.attendedRecovery).toMatchObject({
      sourceJobId: "job-1",
      previewOperationId: fixture.previewOperationId,
      requestedFrames: [2, 1],
      status: "available",
    });

    const mixed = await recoveryFixture();
    failFrame(mixed.handle, 2, attendedError());
    failFrame(mixed.handle, 1, {
      code: "MANUAL_REVIEW_REQUIRED",
      message: "contains the old attended wording but has no typed reason",
      recoverable: false,
    });
    completeZero(mixed.handle);
    expect(mixed.store.getState().sequenceError?.code).toBe("SCAN_ZERO_COMPLETED");
    expect(mixed.store.getState().attendedRecovery).toBeNull();
  });

  it("approves the exact ordered preview-bound frame list and performs exactly one explicit retry", async () => {
    const fixture = await recoveryFixture();
    failFrame(fixture.handle, 2, attendedError());
    failFrame(fixture.handle, 1, attendedError());
    completeZero(fixture.handle);

    const retry = await fixture.store.retryZeroCompletedWithAttendedApproval();
    expect(retry.jobId).toBe("job-2");
    expect(
      fixture.calls.filter((call) => call.method === "roll.approve").map((call) => call.params),
    ).toEqual([
      { frameIndex: 2, operationId: fixture.previewOperationId, attended: true },
      { frameIndex: 1, operationId: fixture.previewOperationId, attended: true },
    ]);
    expect(fixture.calls.filter((call) => call.method === "scan.start")).toHaveLength(2);

    await expect(fixture.store.retryZeroCompletedWithAttendedApproval()).rejects.toMatchObject({
      code: "INVALID_PARAMS",
    });
    expect(fixture.calls.filter((call) => call.method === "scan.start")).toHaveLength(2);
  });

  it("does not scan after any approval fails and never re-enables from a duplicate terminal", async () => {
    const fixture = await recoveryFixture({ approvalFailureAt: 2 });
    failFrame(fixture.handle, 2, attendedError());
    failFrame(fixture.handle, 1, attendedError());
    completeZero(fixture.handle);

    await expect(fixture.store.retryZeroCompletedWithAttendedApproval()).rejects.toMatchObject({
      code: "INVALID_PARAMS",
    });
    expect(fixture.calls.filter((call) => call.method === "scan.start")).toHaveLength(1);

    completeZero(fixture.handle);
    expect(fixture.store.getState().attendedRecovery?.status).not.toBe("available");
    await expect(fixture.store.retryZeroCompletedWithAttendedApproval()).rejects.toMatchObject({
      code: "INVALID_PARAMS",
    });
    expect(fixture.calls.filter((call) => call.method === "scan.start")).toHaveLength(1);
  });

  it("retires the action when a new preview changes the captured authorization epoch", async () => {
    const fixture = await recoveryFixture();
    failFrame(fixture.handle, 2, attendedError());
    failFrame(fixture.handle, 1, attendedError());
    completeZero(fixture.handle);
    expect(fixture.store.getState().attendedRecovery?.status).toBe("available");

    await fixture.store.acquireThumbnails([2, 1]);
    expect(fixture.store.getState().attendedRecovery).toBeNull();
    await expect(fixture.store.retryZeroCompletedWithAttendedApproval()).rejects.toMatchObject({
      code: "INVALID_PARAMS",
    });
    expect(fixture.calls.filter((call) => call.method === "scan.start")).toHaveLength(1);
  });

  it("does not let late frame details plus a duplicate completion manufacture recovery", async () => {
    const fixture = await recoveryFixture();
    completeZero(fixture.handle);
    expect(fixture.store.getState().sequenceError?.code).toBe("SCAN_ZERO_COMPLETED");
    expect(fixture.store.getState().attendedRecovery).toBeNull();

    failFrame(fixture.handle, 2, attendedError());
    failFrame(fixture.handle, 1, attendedError());
    completeZero(fixture.handle);
    expect(fixture.store.getState().attendedRecovery).toBeNull();
  });

  it("keeps partial success out of the zero-completed retry policy", async () => {
    const fixture = await recoveryFixture();
    failFrame(fixture.handle, 2, attendedError());
    fixture.handle.emitEvent({
      event: "scan.completed",
      payload: {
        jobId: "job-1",
        summary: { completed: [1], failed: [2], skipped: [], stopped: false },
      },
    });
    expect(fixture.store.getState().sequenceError).toBeNull();
    expect(fixture.store.getState().attendedRecovery).toBeNull();
    expect(fixture.store.getState().lastCompletedSummary?.completed).toEqual([1]);
  });
});
