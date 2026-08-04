// Real-engine integration flow test (06-03 Task 3): preview -> select all ->
// scan -> cooperative stop after frame 2 -> resume the pending set -> demo
// fault-injection retry on frame 13 -> completed-summary math across both
// jobs. Store-level only (no webview/DOM), driving the Phase 4 harness in
// integration mode against the real engine subprocess, matching the
// core-workflow and skeleton precedents.

import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SessionStore } from "../../src/session/store/session";
import {
  createSubprocessTransport,
  type SubprocessTransportHandle,
} from "../../src/session/testing/harness";
import type { EngineError } from "../../src/session/wire/types";

const range = (from: number, to: number): number[] =>
  Array.from({ length: to - from + 1 }, (_, i) => i + from);

describe("capture workflow integration against the real engine binary", () => {
  let handle: SubprocessTransportHandle | null = null;
  const tempDirs: string[] = [];

  afterEach(async () => {
    if (handle) {
      try {
        await handle.close();
      } catch {
        // Engine already gone; nothing to reclaim.
      }
      handle = null;
    }
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  const pollUntil = async (
    predicate: () => boolean,
    description: string,
    timeoutMs = 30000,
    intervalMs = 5,
  ): Promise<void> => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (predicate()) return;
      await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
    throw new Error(`timed out waiting for: ${description}`);
  };

  const withDeadline = <T>(
    promise: Promise<T>,
    description: string,
    timeoutMs: number,
  ): Promise<T> =>
    Promise.race([
      promise,
      new Promise<T>((_, reject) =>
        setTimeout(() => reject(new Error(`timed out waiting for: ${description}`)), timeoutMs),
      ),
    ]);

  it(
    "preview -> scan -> stop after frame 2 -> resume -> frame-13 auto-retry -> summary math",
    async () => {
      const enginePath = process.env.SCANSTUDIO_ENGINE_PATH;
      if (!enginePath) {
        console.log(
          "[captureWorkflow.test] SCANSTUDIO_ENGINE_PATH not set - skipping integration test",
        );
        return;
      }

      handle = await createSubprocessTransport({
        engineBinaryPath: enginePath,
        timeScale: 0.01,
        timeoutMs: 10000,
      });

      // engine.hello is mandatory as the first request (the production Tauri
      // client performs this handshake on init; the subprocess transport does
      // not, per the harness's documented contract).
      await handle.transport.sendRequest("engine.hello", {
        clientName: "capture-workflow-test",
        protocolVersion: 1,
      });

      const store = new SessionStore(handle.transport);

      // (1) Device list -> connect to the one simulated device, demo fault
      // injection enabled (frame 13's first attempt fails and auto-retries).
      const { devices } = await store.listDevices();
      expect(devices.length).toBe(1);
      const deviceId = devices[0].deviceId;
      expect(deviceId).toBe("sim-ls5000-0");
      await store.connect(deviceId, { timeScale: 0.01, faultInjection: "demo" });

      // (2) Load the roll.
      await store.loadMedia("roll36");

      // (3) Create a roll36 C-41 project in a fresh, per-run temp directory.
      const root = mkdtempSync(join(tmpdir(), "capture-workflow-"));
      tempDirs.push(root);
      const { directory } = await store.createProject(
        "capture-workflow-it",
        "roll36",
        36,
        "c41ColorNegative",
        root,
      );

      // The manifest is real on disk, not just store state (schemaVersion 4).
      const candidates = readdirSync(directory).filter((f) => f.endsWith(".json"));
      if (candidates.length !== 1) {
        throw new Error(
          `expected exactly one .json manifest in ${directory}, found ${candidates.length}; ` +
            `directory listing: ${JSON.stringify(readdirSync(directory))}`,
        );
      }
      const manifest = JSON.parse(
        readFileSync(join(directory, candidates[0]), "utf8"),
      ) as {
        schemaVersion?: number;
        name?: string;
        frameCount?: number;
      };
      expect(manifest.schemaVersion).toBe(4);
      expect(manifest.name).toBe("capture-workflow-it");
      expect(manifest.frameCount).toBe(36);

      // (4) Acquire thumbnails and await the store's previewOutcome.
      await store.acquireThumbnails(undefined, "c41ColorNegative");
      await pollUntil(
        () => store.getState().previewOutcome === "succeeded",
        "preview to succeed",
        30000,
      );
      expect(store.getState().latestCompletedPreviewOperationId).not.toBeNull();
      expect(Object.keys(store.getState().thumbnails)).toHaveLength(36);

      // (5) Select all 36 frames client-side (1..36; pure array, no wire call).
      const allFrames = range(1, 36);

      // (6) Start job 1 over every frame with the documented default recipe.
      const recipe = {
        resolutionDpi: 4000,
        bitDepth: 16,
        multisamplePasses: 1,
        channels: "rgbi",
      } as const;
      const start1 = await store.startScan(allFrames, recipe);

      // (7) Issue the cooperative stop. We wait for frame 1 to reach its
      // stable terminal "completed" state (reliable to observe even under
      // full-suite CPU load, unlike a transient "active" window) and then
      // stop afterCurrentFrame. Under load the engine may finish one or two
      // more frames between our observation and the stop landing, so the
      // assertions below are written against the engine's AUTHORITATIVE
      // manifest-backed project.pendingFrames (not the in-memory completion
      // summary, whose exact frame list is timing-sensitive under load).
      await pollUntil(
        () => store.getState().frameStates[1] === "completed",
        "frame 1 to complete",
        30000,
        2,
      );
      const stopResult = await store.stopJob(start1.jobId, "afterCurrentFrame");
      expect(stopResult.acknowledged).toBe(true);

      // (8) Terminal job state. The cooperative stop resolves to stopped, with
      // nothing failed. (Unreached frames are never "failed"; they are simply
      // absent from the completed set and authoritatively listed by
      // project.pendingFrames, asserted next.)
      await pollUntil(() => {
        const { jobState } = store.getState();
        return jobState === "stopped" || jobState === "completed";
      }, "job 1 to reach a terminal state", 30000);
      const job1Summary = store.getState().lastCompletedSummary;
      expect(job1Summary).not.toBeNull();
      expect(job1Summary!.stopped).toBe(true);
      expect(job1Summary!.failed).toEqual([]);
      expect(job1Summary!.completed.length).toBeGreaterThanOrEqual(1);

      // (9) The engine's own resume set (manifest-backed, read fresh from disk
      // per PROTOCOL.md) is the authoritative remainder -- never a
      // client-recomputed list. It must be internally consistent and still
      // contain frame 13 so the resumed job exercises its demo fault-injection
      // retry (the stop landed at frame ~1-2, far before 13).
      const pending = await store.pendingFrames();
      expect(pending.totalFrames).toBe(36);
      expect(pending.excludedCount).toBe(0);
      expect(pending.frames.length).toBeGreaterThanOrEqual(1);
      expect(pending.completedCount).toBe(36 - pending.frames.length);
      expect(pending.frames).toContain(13);

      // (10) Resume as a fresh job over the pending set (includes frame 13,
      // whose demo fault the engine auto-retries). The store records
      // frameErrors[13] only on the failing attempt and CLEARS it on the
      // immediate error-less retry, so the error is never observable by
      // polling -- capture it through a subscriber (invoked synchronously when
      // the failed attempt's state change is applied, before the retry event).
      let feedJamError: { code: string; message: string; recoverable: boolean } | null = null;
      let resolveFeedJam: (() => void) | undefined;
      const feedJamObserved = new Promise<void>((resolve) => {
        resolveFeedJam = resolve;
      });
      const unsubscribe = store.subscribe(() => {
        if (feedJamError !== null) return;
        const error = store.getState().frameErrors[13];
        if (error !== undefined && error.code === "FEED_JAM") {
          feedJamError = error;
          resolveFeedJam?.();
        }
      });
      try {
        const start2 = await store.startScan(pending.frames, recipe);
        expect(start2.jobId).not.toBe(start1.jobId);

        // Frame 13's FEED_JAM error on attempt 1, then the auto-retry.
        const error = await withDeadline(
          feedJamObserved.then(() => feedJamError),
          "frame 13 FEED_JAM error to be recorded",
          60000,
        );
        const assertError = error as EngineError;
        expect(assertError.code).toBe("FEED_JAM");
        expect(assertError.recoverable).toBe(true);

        await pollUntil(
          () => (store.getState().frameAttempts[13] ?? 0) >= 2,
          "frame 13 to reach attempt 2",
          60000,
        );
        await pollUntil(
          () => store.getState().frameStates[13] === "completed",
          "frame 13 to complete after its retry",
          60000,
        );
        expect(store.getState().frameAttempts[13]).toBe(2);

        // (11) The resumed job completes cleanly: nothing failed, nothing
        // skipped, not stopped.
        await pollUntil(
          () => store.getState().jobState === "completed",
          "job 2 to reach completed",
          180000,
        );
        const job2Summary = store.getState().lastCompletedSummary;
        expect(job2Summary).not.toBeNull();
        expect(job2Summary!.stopped).toBe(false);
        expect(job2Summary!.failed).toEqual([]);
        expect(job2Summary!.skipped).toEqual([]);
        expect(job2Summary!.completed).toContain(13);

        // (12) End-to-end arithmetic, manifest-authoritative: after the resume
        // completes, every one of the 36 frames has a receipt -- pendingFrames
        // is empty and completedCount is 36. This proves job 1 + job 2
        // partitioned the whole roll, independent of the in-memory summaries'
        // exact (timing-sensitive) frame lists.
        const finalPending = await store.pendingFrames();
        expect(finalPending.frames).toEqual([]);
        expect(finalPending.completedCount).toBe(36);
        expect(finalPending.totalFrames).toBe(36);
      } finally {
        unsubscribe();
      }
    },
    180000,
  );
});
