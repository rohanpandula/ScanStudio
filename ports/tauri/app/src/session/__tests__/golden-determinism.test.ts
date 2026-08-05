// Golden determinism test (04-03 Task 3). PROTOCOL.md "Preview thumbnail
// determinism": brightness/tint are derived from FNV-1a 64 over the ASCII
// "{deviceId}:{frameIndex}" string, with the simulator's device id
// "sim-ls5000-0". The three golden (brightness, tint) rows below are lifted
// verbatim from engine/src/sim.rs (they also appear in PROTOCOL.md). This
// suite computes the FNV-1a 64 hash from scratch (BigInt port of the Rust
// algorithm) AND drives the real engine binary end-to-end through the
// SessionStore, asserting the values the store holds match the golden rows.

import { describe, expect, it } from "vitest";
import { createSubprocessTransport } from "../testing/harness";
import { SessionStore } from "../store/session";

const ENGINE_PATH = process.env.SCANSTUDIO_ENGINE_PATH;
if (!ENGINE_PATH) {
  console.log("SCANSTUDIO_ENGINE_PATH not set -- skipping golden determinism tests");
}
const describeSubprocess = ENGINE_PATH ? describe : describe.skip;

const DEVICE_ID = "sim-ls5000-0";
const FNV_OFFSET_BASIS = 14695981039346656037n;
const FNV_PRIME = 1099511628211n;
const FNV_MASK = 0xffffffffffffffffn;

/** FNV-1a 64 (BigInt), matching engine/src/sim.rs::fnv1a64. */
function fnv1a64(input: string): bigint {
  let hash = FNV_OFFSET_BASIS;
  for (const byte of new TextEncoder().encode(input)) {
    hash ^= BigInt(byte);
    hash = (hash * FNV_PRIME) & FNV_MASK;
  }
  return hash;
}

/** Brightness for a hash, matching engine/src/sim.rs::thumbnail_for. */
function brightnessOf(hash: bigint): number {
  const fraction = Number((hash >> 8n) & 0xffffn) / 65535.0;
  return 0.25 + 0.6 * fraction;
}

/** Tint for a hash, matching engine/src/sim.rs::thumbnail_for. */
function tintOf(hash: bigint): number {
  const fraction = Number((hash >> 24n) & 0xffn) / 255.0;
  return fraction - 0.5;
}

const GOLDEN: { frameIndex: number; brightness: number; tint: number }[] = [
  { frameIndex: 1, brightness: 0.573579766536965, tint: 0.37058823529411766 },
  { frameIndex: 13, brightness: 0.6080407415884641, tint: -0.3588235294117647 },
  { frameIndex: 36, brightness: 0.6227077134355687, tint: -0.3588235294117647 },
];

async function waitFor(predicate: () => boolean, timeoutMs = 20000): Promise<void> {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error("waitFor timed out");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe("golden thumbnail determinism", () => {
  it("the BigInt FNV-1a 64 port reproduces the golden brightness/tint rows from scratch", () => {
    for (const row of GOLDEN) {
      const hash = fnv1a64(`${DEVICE_ID}:${row.frameIndex}`);
      expect(brightnessOf(hash)).toBeCloseTo(row.brightness, 9);
      expect(tintOf(hash)).toBeCloseTo(row.tint, 9);
    }
  });

  describeSubprocess("against the real engine binary", () => {
    it("the engine's thumbnails for frames 1, 13, 36 match the golden rows, read from store state", async () => {
      const handle = await createSubprocessTransport({
        engineBinaryPath: ENGINE_PATH as string,
        timeScale: 0.01,
      });
      try {
        await handle.transport.sendRequest("engine.hello", {
          clientName: "golden-determinism",
          protocolVersion: 1,
        });
        const store = new SessionStore(handle.transport);
        await store.connect(DEVICE_ID, { timeScale: handle.timeScale });
        await store.loadMedia("roll36");

        await store.acquireThumbnails([1, 13, 36]);
        // The preview completes when thumbnailsComplete (with the correlating
        // operationId) arrives and the store records the token.
        await waitFor(
          () => store.getState().latestCompletedPreviewOperationId !== null,
        );
        expect(store.getState().thumbnails[1]).toBeDefined();
        expect(store.getState().thumbnails[13]).toBeDefined();
        expect(store.getState().thumbnails[36]).toBeDefined();

        for (const row of GOLDEN) {
          const thumbnail = store.getState().thumbnails[row.frameIndex];
          expect(thumbnail?.brightness).toBeCloseTo(row.brightness, 9);
          expect(thumbnail?.tint).toBeCloseTo(row.tint, 9);
        }
      } finally {
        await handle.close();
      }
    });

    it("the engine's preview operationId correlates with the acquireThumbnails request (request/event token match)", async () => {
      const handle = await createSubprocessTransport({
        engineBinaryPath: ENGINE_PATH as string,
        timeScale: 0.01,
      });
      try {
        await handle.transport.sendRequest("engine.hello", {
          clientName: "golden-determinism",
          protocolVersion: 1,
        });
        const store = new SessionStore(handle.transport);
        await store.connect(DEVICE_ID, { timeScale: handle.timeScale });
        await store.loadMedia("roll36");

        await store.acquireThumbnails([1, 13, 36]);
        await waitFor(
          () => store.getState().latestCompletedPreviewOperationId !== null,
        );
        const token = store.getState().latestCompletedPreviewOperationId;
        // The request/event correlation fired: the token is a UUID the engine
        // echoed back, and the in-flight preview is no longer active.
        expect(token).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
        expect(store.getState().activeOperationId).toBeNull();
        expect(store.getState().thumbnails[1]).toBeDefined();
      } finally {
        await handle.close();
      }
    });
  });
});
