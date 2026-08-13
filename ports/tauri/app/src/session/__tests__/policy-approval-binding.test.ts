// Approval binding policy tests (04-03 Task 1). PROTOCOL.md roll.approve:
// operationId must exactly equal the token from the most recent successfully
// completed preview; the binding includes the device-session epoch and bridge
// process generation, implemented as the OBSERVABLE CONTRACT -- the token is
// cleared on each of the six named triggers (starting another preview, a
// failed preview, media reset, eject, disconnect, reconnect), per the plan's
// discretion note. Local validation happens before any wire call.

import { describe, expect, it } from "vitest";
import { SessionStore } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type { DeviceInfo, EngineError, ScannerStatus } from "../wire/types";

const SIMULATED_DEVICE: DeviceInfo = {
  deviceId: "sim-ls5000-0",
  model: "SUPER COOLSCAN 5000 ED",
  kind: "simulated",
  firmware: "1.03-sim",
  connection: "USB (simulated)",
};

const EMPTY_STATUS: ScannerStatus = {
  connected: true,
  adapter: "SA-30 (simulated)",
  mediaLoaded: false,
  carrier: null,
  frameCount: null,
  lamp: "off",
  transport: "idle",
  activeJobId: null,
};

function scriptedStore() {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      switch (method) {
        case "scanner.connect":
          return { result: { device: SIMULATED_DEVICE, status: { ...EMPTY_STATUS } } };
        case "scanner.acquireThumbnails":
          return { result: { accepted: true, frames: [1] } };
        case "scanner.disconnect":
          return { result: {} };
        case "sim.loadMedia":
          return {
            result: {
              ...EMPTY_STATUS,
              connected: true,
              mediaLoaded: true,
              carrier: "roll36",
              frameCount: 36,
            },
          };
        case "roll.approve":
          return { result: {} };
        default:
          return { result: undefined };
      }
    },
  });
  const store = new SessionStore(handle.transport);
  return { store, handle, calls };
}

describe("SessionStore approval binding (scripted transport)", () => {
  it("rejects locally with no wire call when no completed preview exists", async () => {
    const { store, calls } = scriptedStore();

    let caught: unknown;
    try {
      await store.approveFrame(1);
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeDefined();
    expect(caught).not.toBeInstanceOf(Error);
    const engineError = caught as EngineError;
    expect(engineError.code).toBe("INVALID_PARAMS");
    expect(engineError.recoverable).toBe(false);
    expect(calls.filter((call) => call.method === "roll.approve")).toHaveLength(0);
  });

  it("records the frameIndex as approved when the token matches", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const opId = calls[0].params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId: opId },
    });

    await store.approveFrame(1);
    expect(calls).toContainEqual({
      method: "roll.approve",
      params: { frameIndex: 1, operationId: opId },
    });
    expect(store.getState().approvedFrames[opId]).toContain(1);
  });

  // Attended binding (feed-detector round; ScanStudio #24/#16/#42).

  it("an ordinary approval never puts attended on the wire", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const opId = calls[0].params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId: opId },
    });

    await store.approveFrame(1);
    const approve = calls.find((call) => call.method === "roll.approve");
    expect(approve?.params).toEqual({ frameIndex: 1, operationId: opId });
    expect(approve?.params).not.toHaveProperty("attended");
  });

  it("an attended approval opts in explicitly on the wire", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const opId = calls[0].params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId: opId },
    });

    await store.approveFrame(1, { attended: true });
    expect(calls).toContainEqual({
      method: "roll.approve",
      params: { frameIndex: 1, operationId: opId, attended: true },
    });
    expect(store.getState().approvedFrames[opId]).toContain(1);
  });

  it("approveEveryFrameAttended approves the whole batch and refuses an empty one", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const opId = calls[0].params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId: opId },
    });

    await store.approveEveryFrameAttended([1, 2, 3]);
    const approvals = calls.filter((call) => call.method === "roll.approve");
    expect(approvals).toHaveLength(3);
    for (const approval of approvals) {
      expect(approval.params.attended).toBe(true);
      expect(approval.params.operationId).toBe(opId);
    }
    expect(store.getState().approvedFrames[opId]).toEqual([1, 2, 3]);

    let caught: unknown;
    try {
      await store.approveEveryFrameAttended([]);
    } catch (error) {
      caught = error;
    }
    expect((caught as EngineError).code).toBe("INVALID_PARAMS");
    expect(calls.filter((call) => call.method === "roll.approve")).toHaveLength(3);
  });

  it("starting a new preview clears a prior completed token immediately", async () => {
    const { store, handle, calls } = scriptedStore();

    await store.acquireThumbnails();
    const first = calls[0].params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId: first },
    });
    expect(store.getState().latestCompletedPreviewOperationId).toBe(first);

    // Cleared at call time -- before the second preview completes.
    await store.acquireThumbnails();
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();
    expect(store.getState().activeOperationId).toBe(calls[1].params.operationId);
  });

  it("media reset / eject-via-status / disconnect / reconnect each clear a prior completed token", async () => {
    const { store, handle, calls } = scriptedStore();

    async function completePreview(): Promise<string> {
      const before = calls.length;
      await store.acquireThumbnails();
      const opId = (calls[before].params as { operationId: string }).operationId;
      handle.emitEvent({
        event: "scanner.thumbnailsComplete",
        payload: { count: 1, operationId: opId },
      });
      expect(store.getState().latestCompletedPreviewOperationId).toBe(opId);
      return opId;
    }

    await store.connect("sim-ls5000-0");

    // (3) Media reset: a succeeding sim.loadMedia clears the token.
    await completePreview();
    await store.loadMedia("roll36");
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();

    // (4a) Eject-via-status: mediaLoaded true -> false flips the token away.
    await completePreview();
    handle.emitEvent({
      event: "scanner.status",
      payload: {
        status: { ...EMPTY_STATUS, connected: true, mediaLoaded: false, carrier: "roll36", frameCount: 36 },
      },
    });
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();

    // (4b) Eject-via-status: a carrier/frameCount change is the same trigger.
    await completePreview();
    handle.emitEvent({
      event: "scanner.status",
      payload: {
        status: { ...EMPTY_STATUS, connected: true, mediaLoaded: true, carrier: "strip6", frameCount: 6 },
      },
    });
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();

    // (5) Disconnect: scanner.disconnect succeeding clears the token.
    await completePreview();
    await store.disconnect();
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();

    // (6) Reconnect: a new successful scanner.connect clears the token.
    await store.connect("sim-ls5000-0");
    await completePreview();
    await store.connect("sim-ls5000-0");
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();
  });
});
