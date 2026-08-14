import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type { DeviceInfo, ScannerStatus } from "../wire/types";

/** Regression for the first live Windows validation (2026-08-13): the
 * Windows WebView2 origin http://tauri.localhost is not a secure context,
 * so crypto.randomUUID does not exist there. The store minted preview
 * operation ids with a bare crypto.randomUUID() call, which threw a
 * synchronous TypeError before any state was recorded; ContactSheet's
 * deliberate rejection-consumer then swallowed it, leaving Preview a
 * silent no-op against a connected real scanner. The store must mint ids
 * and run the full preview request path without Web Crypto.
 *
 * Mutation proof: restoring the bare crypto.randomUUID() call in
 * acquireThumbnails makes this test throw exactly like the live failure.
 */

const DEVICE: DeviceInfo = {
  deviceId: "real-ls5000",
  model: "LS-5000 ED",
  kind: "real",
  firmware: "1.20",
  connection: "usb",
};

const STATUS: ScannerStatus = {
  connected: true,
  adapter: "SA-21",
  mediaLoaded: true,
  carrier: "strip6",
  frameCount: 2,
  lamp: "stable",
  transport: "idle",
  activeJobId: null,
  // The live Windows state this test reproduces: armed and idle, so the
  // rendered Preview button would be enabled (previewDisabled false).
  motionArmed: true,
  filmPresent: true,
};

const UUID_V4_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("preview operation ids without Web Crypto (insecure context)", () => {
  it("acquireThumbnails succeeds and sends a v4-shaped operationId when crypto.randomUUID is absent", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params: params as Record<string, unknown> });
        if (method === "scanner.connect") {
          return { result: { device: DEVICE, status: STATUS } };
        }
        if (method === "scanner.acquireThumbnails") {
          return { result: { accepted: true, frames: [1, 2] } };
        }
        throw new Error(`unexpected method ${method}`);
      },
    });
    const store = new SessionStore(handle.transport);
    await store.connect(DEVICE.deviceId);

    // The exact runtime shape live Windows exposed: a crypto object that
    // has no randomUUID member at all.
    vi.stubGlobal("crypto", {});

    const result = await store.acquireThumbnails(undefined, "c41ColorNegative");
    expect(result).toEqual({ accepted: true, frames: [1, 2] });

    const request = calls.find((call) => call.method === "scanner.acquireThumbnails");
    expect(request).toBeDefined();
    expect(request?.params.operationId).toMatch(UUID_V4_SHAPE);
    expect(store.getState().activeOperationId).toBe(request?.params.operationId);
    expect(store.getState().previewOutcome).toBe("active");
    expect(store.getState().previewRequestFailure).toBeNull();
  });
});
