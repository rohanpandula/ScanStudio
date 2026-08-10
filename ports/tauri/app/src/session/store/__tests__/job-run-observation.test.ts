// Job-run observation policy tests (06-03 Task 1): the store exposes the
// latest scan.progress fields and the last job's authoritative completion
// summary (completed/failed/skipped/stopped) so the run panel can render
// progress/ETA and badge never-reached frames as skipped after a cooperative
// stop. Both are jobId-scoped additive state.

import { describe, expect, it } from "vitest";
import { SessionStore } from "../session";
import { createScriptedTransport } from "../../testing/harness";

const CAPTURE = {
  resolutionDpi: 4000,
  bitDepth: 16 as const,
  multisamplePasses: 1 as const,
  channels: "rgbi" as const,
};

async function jobFixture(): Promise<{
  store: SessionStore;
  emitEvent: (raw: unknown) => void;
}> {
  const handle = createScriptedTransport({
    onRequest: (method) => {
      if (method === "scan.start") return { result: { jobId: "job-9" } };
      return { result: undefined };
    },
  });
  const store = new SessionStore(handle.transport);
  await store.startScan([1, 2, 3], CAPTURE);
  return { store, emitEvent: (raw) => handle.emitEvent(raw) };
}

describe("scan.progress observation (06-03)", () => {
  it("records jobPercent and etaSeconds from a correlated progress event", async () => {
    const { store, emitEvent } = await jobFixture();
    emitEvent({
      event: "scan.progress",
      payload: { jobId: "job-9", frameIndex: 2, jobPercent: 42.5, etaSeconds: 9 },
    });
    expect(store.getState().scanProgress).toEqual({ jobPercent: 42.5, etaSeconds: 9 });
  });

  it("drops progress events for a foreign job", async () => {
    const { store, emitEvent } = await jobFixture();
    emitEvent({
      event: "scan.progress",
      payload: { jobId: "job-OTHER", frameIndex: 2, jobPercent: 90, etaSeconds: 1 },
    });
    expect(store.getState().scanProgress).toBeNull();
  });

  it("clears scanProgress when the next job starts", async () => {
    const { store, emitEvent } = await jobFixture();
    emitEvent({
      event: "scan.progress",
      payload: { jobId: "job-9", frameIndex: 2, jobPercent: 50, etaSeconds: 5 },
    });
    expect(store.getState().scanProgress).not.toBeNull();
    emitEvent({
      event: "scan.completed",
      payload: {
        jobId: "job-9",
        summary: { completed: [1, 2, 3], failed: [], skipped: [], stopped: false },
      },
    });
    await store.startScan([1, 2, 3], CAPTURE);
    expect(store.getState().scanProgress).toBeNull();
  });
});

describe("lastCompletedSummary observation (06-03)", () => {
  it("records the skipped set so never-reached frames can badge as skipped", async () => {
    const { store, emitEvent } = await jobFixture();
    emitEvent({
      event: "scan.completed",
      payload: {
        jobId: "job-9",
        summary: {
          completed: [1, 2],
          failed: [],
          skipped: [3],
          stopped: true,
        },
      },
    });
    expect(store.getState().lastCompletedSummary).toEqual({
      completed: [1, 2],
      failed: [],
      skipped: [3],
      stopped: true,
    });
    expect(store.getState().jobState).toBe("stopped");
  });

  it("clears when a new job starts", async () => {
    const { store, emitEvent } = await jobFixture();
    emitEvent({
      event: "scan.completed",
      payload: {
        jobId: "job-9",
        summary: { completed: [], failed: [], skipped: [1, 2, 3], stopped: false },
      },
    });
    expect(store.getState().lastCompletedSummary).not.toBeNull();
    await store.startScan([1, 2, 3], CAPTURE);
    expect(store.getState().lastCompletedSummary).toBeNull();
  });
});
