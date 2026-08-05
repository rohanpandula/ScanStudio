// Preview correlation policy tests (04-03 Task 1). PROTOCOL.md
// scanner.acquireThumbnails: a fresh operationId per accepted preview; while
// a preview is active the store fails closed on missing or mismatched tokens
// -- such events cannot add thumbnails, report failure, complete the preview,
// clear its busy state, or authorize a second request; generic untagged
// status events never terminate an active preview; a zero-count completion
// preceded by scanner.thumbnailsFailed is a FAILURE, not an empty success.

import { describe, expect, it } from "vitest";
import { SessionStore } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type { EngineError } from "../wire/types";

function scriptedStore() {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      if (method === "scanner.acquireThumbnails") {
        return { result: { accepted: true, frames: [1, 13, 36] } };
      }
      return { result: undefined };
    },
  });
  const store = new SessionStore(handle.transport);
  return { store, handle, calls };
}

function untaggedStatus() {
  return {
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
        activeJobId: null,
      },
    },
  };
}

describe("SessionStore preview correlation (scripted transport)", () => {
  it("fresh operationId per accepted preview", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const first = calls[0].params.operationId as string;
    expect(typeof first).toBe("string");
    expect(first.length).toBeGreaterThan(0);

    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 3, operationId: first },
    });
    expect(store.getState().latestCompletedPreviewOperationId).toBe(first);

    await store.acquireThumbnails();
    const second = calls[1].params.operationId as string;
    expect(second).not.toBe(first);

    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 3, operationId: second },
    });
    expect(store.getState().latestCompletedPreviewOperationId).toBe(second);
  });

  it("refuses a second acquireThumbnails while one is active", async () => {
    const { store, calls } = scriptedStore();

    await store.acquireThumbnails();
    let caught: unknown;
    try {
      await store.acquireThumbnails();
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeDefined();
    expect(caught).not.toBeInstanceOf(Error);
    const engineError = caught as EngineError;
    expect(engineError.code).toBe("INVALID_PARAMS");
    expect(typeof engineError.message).toBe("string");
    expect(engineError.recoverable).toBe(false);
    // No second request ever reached the wire.
    expect(calls.filter((call) => call.method === "scanner.acquireThumbnails")).toHaveLength(1);
  });

  it("rejects a thumbnail event with mismatched operationId", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const active = calls[0].params.operationId as string;

    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex: 1,
        thumbnail: { brightness: 0.5, tint: 0.1 },
        operationId: "some-other-operation",
      },
    });
    expect(store.getState().thumbnails[1]).toBeUndefined();

    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex: 1,
        thumbnail: { brightness: 0.5, tint: 0.1 },
        operationId: active,
      },
    });
    expect(store.getState().thumbnails[1]).toEqual({ brightness: 0.5, tint: 0.1 });
  });

  it("rejects a thumbnail event missing operationId while active", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const active = calls[0].params.operationId as string;

    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: { frameIndex: 1, thumbnail: { brightness: 0.5, tint: 0.1 } },
    });
    expect(store.getState().thumbnails[1]).toBeUndefined();
    // The preview itself is untouched: still active with the same token.
    expect(store.getState().activeOperationId).toBe(active);
  });

  it("thumbnailsFailed then zero-count complete resolves to failed not succeeded", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const active = calls[0].params.operationId as string;

    handle.emitEvent({
      event: "scanner.thumbnailsFailed",
      payload: { code: "BRIDGE_STREAM_STALLED", message: "preview stream stalled", operationId: active },
    });
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 0, operationId: active },
    });

    // A failed preview never sets a completed-preview token, and the store's
    // preview lane is released (the tracker resolved to "failed", not
    // "active") so a new preview can start.
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();
    expect(store.getState().activeOperationId).toBeNull();
    await store.acquireThumbnails();
    expect(calls.filter((call) => call.method === "scanner.acquireThumbnails")).toHaveLength(2);
  });

  it("untagged status does not clear the active-preview tracker", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const active = calls[0].params.operationId as string;

    handle.emitEvent(untaggedStatus());
    // The status itself was real data and applied...
    expect(store.getState().connection.status?.mediaLoaded).toBe(true);
    // ...but the untagged event must not terminate the active preview.
    expect(store.getState().activeOperationId).toBe(active);
    let caught: unknown;
    try {
      await store.acquireThumbnails();
    } catch (error) {
      caught = error;
    }
    expect((caught as EngineError).code).toBe("INVALID_PARAMS");
  });
});
