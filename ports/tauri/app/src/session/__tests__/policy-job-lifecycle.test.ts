// Job Lifecycle policy tests for the SessionStore (04-02 Task 3).
// Deterministic sequences run through createScriptedTransport; the demo
// fault-injection case drives the real simulated engine via
// createSubprocessTransport (env-gated on SCANSTUDIO_ENGINE_PATH, matching
// the harness.test.ts pattern).
//
// The store itself implements PROTOCOL.md's job lifecycle: state machines
// enforced via assertJobTransition/assertFrameTransition, stop modes passed
// through verbatim, the real-backend skipCurrentFrame refusal, and resume =
// project.pendingFrames fed into a fresh scan.start.

import { describe, expect, it } from "vitest";
import { SessionStore } from "../store/session";
import { createScriptedTransport, createSubprocessTransport } from "../testing/harness";
import type {
  CaptureRecipe,
  EngineError,
  FrameState,
  ScanReceipt,
  WireEvent,
} from "../wire/types";

const ENGINE_PATH = process.env.SCANSTUDIO_ENGINE_PATH;
if (!ENGINE_PATH) {
  console.log("SCANSTUDIO_ENGINE_PATH not set -- skipping subprocess-transport tests");
}
const describeSubprocess = ENGINE_PATH ? describe : describe.skip;

const SIMULATED_DEVICE = {
  deviceId: "sim-ls5000-0",
  model: "SUPER COOLSCAN 5000 ED",
  kind: "simulated",
  firmware: "1.03-sim",
  connection: "USB (simulated)",
};

const REAL_DEVICE = {
  deviceId: "real-ls5000-0",
  model: "SUPER COOLSCAN 5000 ED",
  kind: "real",
  firmware: "1.0",
  connection: "USB",
};

const IDLE_STATUS = {
  connected: true,
  adapter: "SA-30 (simulated)",
  mediaLoaded: false,
  carrier: null,
  frameCount: null,
  lamp: "off",
  transport: "idle",
  activeJobId: null,
};

const CAPTURE_RECIPE = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 1,
  channels: "rgbi",
} satisfies CaptureRecipe;

const FEED_JAM_ERROR: EngineError = {
  code: "FEED_JAM",
  message: "Simulated feed jam on frame 13",
  recoverable: true,
};

function receiptFor(frameIndex: number, durationMs: number): ScanReceipt {
  return {
    jobId: "job-1",
    frameIndex,
    startedAt: "2026-07-22T09:00:00Z",
    durationMs,
    passes: 1,
    resolutionDpi: 4000,
    bitDepth: 16,
    channels: "rgbi",
    engineVersion: "0.1.0",
    deviceId: "sim-ls5000-0",
    simulated: true,
    settingsFingerprint: "1a3d265e0b54bbd2",
  };
}

async function waitFor(predicate: () => boolean, timeoutMs = 20000): Promise<void> {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error("waitFor timed out");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe("SessionStore job lifecycle (scripted transport)", () => {
  it("job creation via scan.start only reaches jobState=queued (assertJobTransition enforced)", async () => {
    const calls: { method: string; params: unknown }[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params });
        if (method === "scan.start") return { result: { jobId: "job-1" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    const integrityErrors: unknown[] = [];
    store.onIntegrityError((error) => integrityErrors.push(error));

    await store.startScan([1], CAPTURE_RECIPE);
    expect(store.getState().jobState).toBe("queued");
    expect(store.getState().jobId).toBe("job-1");

    // An illegal queued -> completed event is surfaced, never applied.
    handle.emitEvent({
      event: "scan.jobState",
      payload: { jobId: "job-1", state: "completed" },
    } satisfies WireEvent);
    expect(integrityErrors).toHaveLength(1);
    expect(store.getState().jobState).toBe("queued");

    // Same-state events are not legal transitions either.
    handle.emitEvent({
      event: "scan.jobState",
      payload: { jobId: "job-1", state: "queued" },
    } satisfies WireEvent);
    expect(integrityErrors).toHaveLength(2);
    expect(store.getState().jobState).toBe("queued");

    // The legal queued -> scanning transition still applies afterwards.
    handle.emitEvent({
      event: "scan.jobState",
      payload: { jobId: "job-1", state: "scanning" },
    } satisfies WireEvent);
    expect(integrityErrors).toHaveLength(2);
    expect(store.getState().jobState).toBe("scanning");

    // Unknown event names are silently ignored (forward compatibility).
    handle.emitEvent({ event: "scanner.thumbnailsComplete", payload: { count: 1 } });
    expect(integrityErrors).toHaveLength(2);
    expect(store.getState().jobState).toBe("scanning");
  });

  it("scan.frameState events update per-frame state and attempt count", async () => {
    const handle = createScriptedTransport({
      onRequest: (method) => {
        if (method === "scan.start") return { result: { jobId: "job-1" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    const integrityErrors: unknown[] = [];
    store.onIntegrityError((error) => integrityErrors.push(error));

    await store.startScan([13], CAPTURE_RECIPE);
    expect(store.getState().frameStates[13]).toBe("waiting");

    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 1 },
    } satisfies WireEvent);
    expect(store.getState().frameStates[13]).toBe("active");
    expect(store.getState().frameAttempts[13]).toBe(1);
    expect(store.getState().frameErrors[13]).toBeUndefined();

    handle.emitEvent({
      event: "scan.frameState",
      payload: {
        jobId: "job-1",
        frameIndex: 13,
        state: "failed",
        attempt: 1,
        error: FEED_JAM_ERROR,
      },
    } satisfies WireEvent);
    expect(store.getState().frameStates[13]).toBe("failed");
    expect(store.getState().frameAttempts[13]).toBe(1);
    expect(store.getState().frameErrors[13]).toEqual(FEED_JAM_ERROR);

    // The automatic retry: failed -> active with attempt 2 clears the error.
    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 2 },
    } satisfies WireEvent);
    expect(store.getState().frameStates[13]).toBe("active");
    expect(store.getState().frameAttempts[13]).toBe(2);
    expect(store.getState().frameErrors[13]).toBeUndefined();

    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "completed", attempt: 2 },
    } satisfies WireEvent);
    expect(store.getState().frameStates[13]).toBe("completed");
    expect(store.getState().frameAttempts[13]).toBe(2);

    // An illegal transition from a terminal frame state is surfaced, and the
    // stale attempt count is never applied.
    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 3 },
    } satisfies WireEvent);
    expect(integrityErrors).toHaveLength(1);
    expect(store.getState().frameStates[13]).toBe("completed");
    expect(store.getState().frameAttempts[13]).toBe(2);
  });

  it("scan.frameCompleted attaches the receipt for that frame", async () => {
    const handle = createScriptedTransport({
      onRequest: (method) => {
        if (method === "scan.start") return { result: { jobId: "job-1" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);

    await store.startScan([1, 13], CAPTURE_RECIPE);
    const first = receiptFor(13, 1900);
    handle.emitEvent({
      event: "scan.frameCompleted",
      payload: { jobId: "job-1", frameIndex: 13, receipt: first },
    } satisfies WireEvent);
    expect(store.getState().frameReceipts[13]).toEqual([first]);

    // A receipt for a job the store never started is dropped (jobId scoping,
    // review fix) -- receipts only attach once the re-scan's own job exists.
    const foreign = receiptFor(13, 2100);
    handle.emitEvent({
      event: "scan.frameCompleted",
      payload: { jobId: "job-2", frameIndex: 13, receipt: foreign },
    } satisfies WireEvent);
    expect(store.getState().frameReceipts[13]).toEqual([first]);

    handle.emitEvent({
      event: "scan.completed",
      payload: {
        jobId: "job-1",
        summary: { completed: [13], failed: [], skipped: [1], stopped: false },
      },
    } satisfies WireEvent);

    // A later job re-scanning the same frame appends, preserving history.
    await store.startScan([13], CAPTURE_RECIPE);
    const second = { ...receiptFor(13, 2100), jobId: "job-1" };
    handle.emitEvent({
      event: "scan.frameCompleted",
      payload: { jobId: "job-1", frameIndex: 13, receipt: second },
    } satisfies WireEvent);
    expect(store.getState().frameReceipts[13]).toEqual([first, second]);

    // Frames without a receipt simply have no entry.
    expect(store.getState().frameReceipts[1]).toBeUndefined();
  });

  it("scan.completed resolves a non-terminal jobState from the summary without overwriting an already-terminal one", async () => {
    const handle = createScriptedTransport({
      onRequest: (method) => {
        if (method === "scan.start") return { result: { jobId: "job-1" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);

    await store.startScan([1], CAPTURE_RECIPE);
    handle.emitEvent({
      event: "scan.jobState",
      payload: { jobId: "job-1", state: "scanning" },
    } satisfies WireEvent);

    // Job-level failure only ever arrives as its own scan.jobState event;
    // a summary with failed frames but stopped:false resolves to completed.
    handle.emitEvent({
      event: "scan.completed",
      payload: {
        jobId: "job-1",
        summary: { completed: [1], failed: [], skipped: [], stopped: false },
      },
    } satisfies WireEvent);
    expect(store.getState().jobState).toBe("completed");

    // A later summary (even one claiming stopped) must not overwrite a
    // jobState that already reached a terminal value.
    handle.emitEvent({
      event: "scan.completed",
      payload: {
        jobId: "job-1",
        summary: { completed: [], failed: [], skipped: [], stopped: true },
      },
    } satisfies WireEvent);
    expect(store.getState().jobState).toBe("completed");
  });

  it("stop{afterCurrentFrame} and stop{immediate} both pass mode through verbatim", async () => {
    const calls: { method: string; params: unknown }[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params });
        if (method === "scan.stop") {
          const mode = (params as { mode: string }).mode;
          return { result: { acknowledged: true, mode } };
        }
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);

    await store.stopJob("job-1", "afterCurrentFrame");
    await store.stopJob("job-1", "immediate");

    expect(calls).toEqual([
      { method: "scan.stop", params: { jobId: "job-1", mode: "afterCurrentFrame" } },
      { method: "scan.stop", params: { jobId: "job-1", mode: "immediate" } },
    ]);
  });

  it("skipCurrentFrame is refused locally with no wire call when device kind is not simulated", async () => {
    const calls: { method: string; params: unknown }[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params });
        if (method === "scanner.connect") {
          const deviceId = (params as { deviceId: string }).deviceId;
          if (deviceId === REAL_DEVICE.deviceId) {
            return { result: { device: REAL_DEVICE, status: { ...IDLE_STATUS } } };
          }
          return { result: { device: SIMULATED_DEVICE, status: { ...IDLE_STATUS } } };
        }
        if (method === "scan.skipCurrentFrame") return { result: { acknowledged: true } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);

    await store.connect(REAL_DEVICE.deviceId);
    await expect(store.skipCurrentFrame("job-1")).rejects.toThrow(
      /setFrameExcluded.*afterCurrentFrame|afterCurrentFrame.*scan\.start|not supported.*real/i,
    );
    expect(calls.some((call) => call.method === "scan.skipCurrentFrame")).toBe(false);

    // Reconnecting to the simulated device re-enables the wire forward.
    await store.connect(SIMULATED_DEVICE.deviceId);
    await expect(store.skipCurrentFrame("job-1")).resolves.toMatchObject({ acknowledged: true });
    expect(calls).toContainEqual({ method: "scan.skipCurrentFrame", params: { jobId: "job-1" } });
  });

  it("resumeJob calls project.pendingFrames then scan.start with exactly the returned frame list", async () => {
    const calls: { method: string; params: unknown }[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params });
        if (method === "project.pendingFrames") {
          return {
            result: {
              frames: [2, 5, 7],
              totalFrames: 36,
              completedCount: 29,
              excludedCount: 0,
            },
          };
        }
        if (method === "scan.start") return { result: { jobId: "job-resume-1" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);

    await store.resumeJob(CAPTURE_RECIPE);
    expect(calls[0].method).toBe("project.pendingFrames");
    expect((calls[1].params as { frames: number[] }).frames).toEqual([2, 5, 7]);
    expect((calls[1].params as { recipe: typeof CAPTURE_RECIPE }).recipe).toEqual(CAPTURE_RECIPE);
    expect(store.getState().jobId).toBe("job-resume-1");
    expect(store.getState().jobState).toBe("queued");
  });
});

describeSubprocess("job lifecycle against the real simulated engine", () => {
  it("demo fault-injection: frame 13 attempt 1 fails FEED_JAM recoverable:true, attempt 2 succeeds active (integration mode, env-gated)", async () => {
    const handle = await createSubprocessTransport({
      engineBinaryPath: ENGINE_PATH as string,
      timeScale: 0.01,
    });
    const store = new SessionStore(handle.transport);
    const integrityErrors: unknown[] = [];
    store.onIntegrityError((error) => integrityErrors.push(error));

    interface FrameSnapshot {
      jobState: string | null;
      f13: FrameState | undefined;
      a13: number | undefined;
      e13: EngineError | undefined;
    }
    const snapshots: FrameSnapshot[] = [];
    store.subscribe(() => {
      const state = store.getState();
      snapshots.push({
        jobState: state.jobState,
        f13: state.frameStates[13],
        a13: state.frameAttempts[13],
        e13: state.frameErrors[13] === undefined ? undefined : { ...state.frameErrors[13] },
      });
    });

    try {
      await handle.transport.sendRequest("engine.hello", {
        clientName: "policy-job-lifecycle-test",
        protocolVersion: 1,
      });
      await store.connect(SIMULATED_DEVICE.deviceId, {
        timeScale: handle.timeScale,
        faultInjection: "demo",
      });
      await store.loadMedia("roll36");
      const { jobId } = await store.startScan([13], CAPTURE_RECIPE);

      await waitFor(() => store.getState().jobState === "completed");

      expect(integrityErrors).toEqual([]);
      expect(store.getState().jobId).toBe(jobId);

      // Reduce the recorded snapshots to the steps where frame 13's own
      // state, attempt, or attached error actually changed.
      const reduced: Array<{ f13: FrameState; a13?: number; code?: string }> = [];
      for (const snap of snapshots) {
        if (snap.f13 === undefined) continue;
        const last = reduced[reduced.length - 1];
        if (
          !last ||
          last.f13 !== snap.f13 ||
          last.a13 !== snap.a13 ||
          last.code !== snap.e13?.code
        ) {
          reduced.push({ f13: snap.f13, a13: snap.a13, code: snap.e13?.code });
        }
      }
      expect(reduced).toEqual([
        { f13: "waiting", a13: undefined, code: undefined },
        { f13: "active", a13: 1, code: undefined },
        { f13: "failed", a13: 1, code: "FEED_JAM" },
        { f13: "active", a13: 2, code: undefined },
        { f13: "completed", a13: 2, code: undefined },
      ]);

      const jamSnapshot = snapshots.find(
        (snap) => snap.f13 === "failed" && snap.a13 === 1 && snap.e13 !== undefined,
      );
      expect(jamSnapshot?.e13?.code).toBe("FEED_JAM");
      expect(jamSnapshot?.e13?.recoverable).toBe(true);

      const receipts = store.getState().frameReceipts[13];
      expect(receipts).toHaveLength(1);
      expect(receipts[0].frameIndex).toBe(13);
      expect(receipts[0].simulated).toBe(true);
    } finally {
      await handle.close();
    }
  });
});
