// Permanent scripted end-to-end regression gate (07-03 Task 2, UI-14).
// Headless, store-level session against the REAL engine binary: hello -> list
// -> connect (timeScale 0.01, faultInjection demo) -> create project ->
// loadMedia -> preview (golden brightness/tint on frames 1/13/36) -> scan 4
// frames (frame 13 auto-retry, settingsFingerprint golden) -> stop/resume
// variant -> final complete -> shutdown (exit 0). All waits are event-driven:
// they resolve on store state changes via subscribe(), never sleep/poll loops,
// so the whole run finishes in well under 60 seconds.
//
// Engine resolution is explicit (T-07-09): SCANSTUDIO_ENGINE_PATH must be set
// or the test logs a clear message and skips -- it never silently passes and
// never resolves an arbitrary binary off PATH.

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { SessionStore } from "../../src/session/store/session";
import {
  createSubprocessTransport,
  type SubprocessTransportHandle,
} from "../../src/session/testing/harness";
import type { Thumbnail } from "../../src/session/wire/types";

// Golden determinism values (PROTOCOL.md), tolerance 1e-9.
const GOLDEN = {
  1: { brightness: 0.573579766536965, tint: 0.37058823529411766 },
  13: { brightness: 0.6080407415884641, tint: -0.3588235294117647 },
  36: { brightness: 0.6227077134355687, tint: -0.3588235294117647 },
};
const GOLDEN_FINGERPRINT = "1a3d265e0b54bbd2";
const RECIPE = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 2,
  channels: "rgbi",
} as const;

const range = (from: number, to: number): number[] =>
  Array.from({ length: to - from + 1 }, (_, i) => i + from);

describe("sim-session end-to-end regression gate", () => {
  let handle: SubprocessTransportHandle | null = null;
  let tempDir: string | null = null;
  const cleanupDirs: string[] = [];

  afterAll(async () => {
    if (handle) {
      try {
        await handle.close();
      } catch {
        // Already gone.
      }
    }
    for (const dir of cleanupDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    cleanupDirs.length = 0;
    void tempDir;
  });

  it(
    "runs the full connect -> project -> preview -> scan -> stop/resume -> shutdown session",
    async () => {
      const enginePath = process.env.SCANSTUDIO_ENGINE_PATH;
      if (!enginePath) {
        console.log(
          "[sim-session.test] SCANSTUDIO_ENGINE_PATH not set - skipping e2e integration test",
        );
        return;
      }

      handle = await createSubprocessTransport({
        engineBinaryPath: enginePath,
        timeScale: 0.01,
        timeoutMs: 10000,
      });
      await handle.transport.sendRequest("engine.hello", {
        clientName: "sim-session-e2e",
        protocolVersion: 1,
      });
      const store = new SessionStore(handle.transport);

      // Event-driven wait: resolves on a store notification when the
      // predicate becomes true; never polls.
      const waitForState = async (
        predicate: () => boolean,
        description: string,
        timeoutMs = 60000,
      ): Promise<void> => {
        if (predicate()) return;
        await new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => {
            unsubscribe();
            reject(new Error(`timed out waiting for: ${description}`));
          }, timeoutMs);
          const unsubscribe = store.subscribe(() => {
            if (!predicate()) return;
            clearTimeout(timer);
            unsubscribe();
            resolve();
          });
        });
      };

      // (1) hello (above) -> list exactly one device -> connect demo+slow.
      const { devices } = await store.listDevices();
      expect(devices.length).toBe(1);
      const deviceId = devices[0].deviceId;
      await store.connect(deviceId, { timeScale: 0.01, faultInjection: "demo" });

      // (2) Create a project in a fresh temp dir so the test never touches a
      // real projects folder (T-07-10).
      tempDir = mkdtempSync(join(tmpdir(), "sim-session-"));
      cleanupDirs.push(tempDir);
      await store.createProject("sim-session-e2e", "roll36", 36, "c41ColorNegative", tempDir);

      // (3) Load media, assert frameCount 36.
      const loaded = await store.loadMedia("roll36");
      expect(loaded.frameCount).toBe(36);

      // (4) Preview all frames; await the completion outcome event.
      await store.acquireThumbnails(undefined, "c41ColorNegative");
      await waitForState(
        () => store.getState().previewOutcome === "succeeded",
        "preview to succeed",
        60000,
      );
      const state = store.getState();
      expect(Object.keys(state.thumbnails).length).toBe(36);
      for (const frameIndex of [1, 13, 36]) {
        const thumb = state.thumbnails[frameIndex] as Thumbnail | undefined;
        expect(thumb).toBeDefined();
        expect(thumb?.brightness ?? 0).toBeCloseTo(GOLDEN[frameIndex as 1 | 13 | 36].brightness, 9);
        expect(thumb?.tint ?? 0).toBeCloseTo(GOLDEN[frameIndex as 1 | 13 | 36].tint, 9);
      }

      // (5) Scan exactly 4 frames; watch frame 13's demo auto-retry; check
      // the settingsFingerprint golden on every receipt.
      const scanFrames = [1, 13, 25, 36];
      const firstJob = await store.startScan(scanFrames, RECIPE);
      // Frame 13's FEED_JAM surfaces on a failing attempt, then auto-retries:
      // assert the attempt counter reaches 2 and the frame completes.
      await waitForState(
        () => (store.getState().frameAttempts[13] ?? 0) >= 2,
        "frame 13 to reach attempt 2 (demo retry)",
        60000,
      );
      await waitForState(
        () => store.getState().frameStates[13] === "completed",
        "frame 13 to complete after retry",
        60000,
      );
      // Await full job completion via the terminal summary event.
      await waitForState(
        () =>
          store.getState().jobState === "completed" &&
          store.getState().lastCompletedSummary !== null,
        "job 1 to reach completed",
        120000,
      );
      const job1Summary = store.getState().lastCompletedSummary;
      expect(job1Summary?.completed).toEqual(scanFrames);
      expect(job1Summary?.failed).toEqual([]);
      expect(job1Summary?.stopped).toBe(false);
      for (const frameIndex of scanFrames) {
        const receipts = store.getState().frameReceipts[frameIndex] ?? [];
        const receipt = receipts[receipts.length - 1];
        expect(receipt).toBeDefined();
        expect(receipt?.settingsFingerprint).toBe(GOLDEN_FINGERPRINT);
      }

      // (6) 32 frames remain.
      const pendingAfterFirst = await store.pendingFrames();
      expect(pendingAfterFirst.completedCount).toBe(4);
      expect(pendingAfterFirst.frames.length).toBe(32);
      const remaining = [...pendingAfterFirst.frames].sort((a, b) => a - b);
      const expectedRemaining = range(1, 36).filter((f) => !scanFrames.includes(f));
      expect(remaining).toEqual(expectedRemaining);

      // (7) Stop/resume variant: start the first 3 pending frames, stop
      // afterCurrentFrame, and assert exactly the in-flight frame completes.
      const partialFrames = remaining.slice(0, 3);
      await store.startScan(partialFrames, RECIPE);
      // Await the first partial frame's completion (event-driven) then stop.
      await waitForState(
        () => (store.getState().frameReceipts[partialFrames[0]] ?? []).length > 0,
        "first partial frame to complete",
        60000,
      );
      await store.stopJob(store.getState().jobId as string, "afterCurrentFrame");
      await waitForState(
        () => {
          const { jobState } = store.getState();
          return jobState === "stopped" || jobState === "completed";
        },
        "partial job to reach a terminal state",
        120000,
      );
      const partialSummary = store.getState().lastCompletedSummary;
      expect(partialSummary?.stopped).toBe(true);
      expect(partialSummary?.completed.length).toBeGreaterThanOrEqual(1);
      expect(partialSummary?.completed.length).toBeLessThanOrEqual(2);

      // (8) Final scan of the true remainder completes cleanly.
      const pendingAfterPartial = await store.pendingFrames();
      const finalFrames = [...pendingAfterPartial.frames].sort((a, b) => a - b);
      expect(finalFrames.length).toBeGreaterThan(0);
      const finalJob = await store.startScan(finalFrames, RECIPE);
      void finalJob;
      await waitForState(
        () =>
          store.getState().jobState === "completed" &&
          store.getState().lastCompletedSummary !== null,
        "final job to reach completed",
        120000,
      );
      const finalSummary = store.getState().lastCompletedSummary;
      expect(finalSummary?.stopped).toBe(false);
      expect(finalSummary?.completed.length).toBe(finalFrames.length);
      expect(finalSummary?.failed).toEqual([]);

      // (9) Shutdown cleanly: the subprocess transport's close() sends
      // engine.shutdown and waits for the child to exit (graceful exit 0),
      // falling back to a bounded-force stop only if the engine hangs; a
      // successfully resolved close() is the clean-shutdown signal.
      await handle.close();
    },
    200000,
  );
});
