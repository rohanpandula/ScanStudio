// Selection policy tests (05-03 Task 1) plus the preview-outcome exposure
// transitions the contact sheet's failure banner depends on. Selection is
// additive UI-only state (05-CONTEXT decision 5): no wire calls, no new
// engine-facing policy; it survives unrelated store notifications.
//
// previewOutcome exposure (orchestrator ground truth 5): SessionState mirrors
// the private #previewOutcome tracker so a failed preview is distinguishable
// from "never previewed". Transitions: acquireThumbnails accepted -> "active";
// correlated thumbnailsFailed -> "failed" (with previewError carrying the
// wire message verbatim); correlated success thumbnailsComplete -> "succeeded"
// (failed path stays "failed"); wire rejection, #resetSessionBinding
// (create/open project), and loadMedia all reset to null.

import { describe, expect, it } from "vitest";
import { SessionStore } from "../session";
import { createScriptedTransport, type ScriptedTransportHandle } from "../../testing/harness";
import type { EngineError, ScanProject, ScannerStatus } from "../../wire/types";

interface Call {
  method: string;
  params: Record<string, unknown>;
}

function scriptedFixture(
  script?: (method: string, params: unknown) => { result?: unknown; error?: EngineError } | undefined,
): { store: SessionStore; handle: ScriptedTransportHandle; calls: Call[] } {
  const calls: Call[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      const custom = script?.(method, params);
      if (custom !== undefined) return custom;
      if (method === "scanner.acquireThumbnails") {
        return { result: { accepted: true, frames: [1, 13, 36] } };
      }
      return { result: undefined };
    },
  });
  return { store: new SessionStore(handle.transport), handle, calls };
}

function emitStatus(handle: ScriptedTransportHandle, status: ScannerStatus): void {
  handle.emitEvent({ event: "scanner.status", payload: { status } });
}

const LOADED_ROLL36: ScannerStatus = {
  connected: true,
  adapter: null,
  mediaLoaded: true,
  carrier: "roll36",
  frameCount: 36,
  lamp: "stable",
  transport: "idle",
  activeJobId: null,
};

const UNLOADED: ScannerStatus = {
  connected: true,
  adapter: null,
  mediaLoaded: false,
  carrier: null,
  frameCount: null,
  lamp: "off",
  transport: "idle",
  activeJobId: null,
};

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-reset",
  name: "Reset Project",
  carrier: "roll36",
  frameCount: 36,
  filmProcess: "c41ColorNegative",
  recipes: {
    archive: {
      enabled: false,
      filenameTemplate: "scan_{frame:04d}",
      destination: "/tmp",
    },
    positive: {
      enabled: true,
      fileFormat: "tiff",
      colorProfile: "adobeRgb1998",
      filenameTemplate: "scan_{frame:04d}",
      destination: "/tmp",
    },
    preview: {
      enabled: false,
      fileFormat: "jpeg",
      maxLongEdgePx: 1024,
      filenameTemplate: "preview_{frame:04d}",
      destination: "/tmp",
    },
  },
  rollMetadata: { keywords: [] },
  createdAt: "2026-08-02T00:00:00Z",
  frames: [],
};

describe("SessionStore selection (additive UI state)", () => {
  it("toggles a frame into the selection on first click", () => {
    const { store, handle } = scriptedFixture();
    emitStatus(handle, LOADED_ROLL36);
    store.toggleFrameSelection(3, false);
    expect(store.getState().selectedFrameIndices).toEqual([3]);
  });

  it("toggles the same frame back out on a second click", () => {
    const { store, handle } = scriptedFixture();
    emitStatus(handle, LOADED_ROLL36);
    store.toggleFrameSelection(3, false);
    store.toggleFrameSelection(3, false);
    expect(store.getState().selectedFrameIndices).toEqual([]);
  });

  it("shift-extends the selection as an inclusive range from the last non-extend anchor", () => {
    const { store, handle } = scriptedFixture();
    emitStatus(handle, LOADED_ROLL36);
    store.toggleFrameSelection(3, false);
    store.toggleFrameSelection(7, true);
    expect(store.getState().selectedFrameIndices).toEqual([3, 4, 5, 6, 7]);
  });

  it("selects every frame 1..frameCount via selectAll", () => {
    const { store, handle } = scriptedFixture();
    emitStatus(handle, LOADED_ROLL36);
    store.selectAll();
    const expected = Array.from({ length: 36 }, (_, index) => index + 1);
    expect(store.getState().selectedFrameIndices).toEqual(expected);
  });

  it("empties the selection via clearSelection", () => {
    const { store, handle } = scriptedFixture();
    emitStatus(handle, LOADED_ROLL36);
    store.selectAll();
    store.clearSelection();
    expect(store.getState().selectedFrameIndices).toEqual([]);
  });

  it("keeps the selection across unrelated store notifications", () => {
    const { store, handle } = scriptedFixture();
    emitStatus(handle, LOADED_ROLL36);
    store.toggleFrameSelection(3, false);
    emitStatus(handle, { ...LOADED_ROLL36, transport: "busy", lamp: "warming" });
    expect(store.getState().selectedFrameIndices).toEqual([3]);
  });

  it("ignores a frame index outside 1..frameCount when media is loaded", () => {
    const { store, handle } = scriptedFixture();
    emitStatus(handle, LOADED_ROLL36);
    store.toggleFrameSelection(37, false);
    store.toggleFrameSelection(0, false);
    expect(store.getState().selectedFrameIndices).toEqual([]);
  });

  it("is a complete no-op when no media is loaded", () => {
    const { store, handle } = scriptedFixture();
    emitStatus(handle, UNLOADED);
    store.toggleFrameSelection(3, false);
    store.selectAll();
    store.clearSelection();
    expect(store.getState().selectedFrameIndices).toEqual([]);
  });
});

describe("SessionStore preview outcome exposure", () => {
  it("is null initially", () => {
    const { store } = scriptedFixture();
    expect(store.getState().previewOutcome).toBeNull();
    expect(store.getState().previewError).toBeNull();
    expect(store.getState().previewRequestFailure).toBeNull();
    expect(store.getState().previewFilmProcessSelection).toBe("c41ColorNegative");
    expect(store.getState().previewFilmProcess).toBeNull();
  });

  it("commits the selected film process only on a correlated successful completion", async () => {
    const { store, handle, calls } = scriptedFixture();
    store.setPreviewFilmProcess("bwNegative");
    await store.acquireThumbnails();
    const active = calls[0].params.operationId as string;

    expect(calls[0].params.filmProcess).toBe("bwNegative");
    expect(store.getState().previewFilmProcess).toBeNull();

    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 3, operationId: "another-operation" },
    });
    expect(store.getState().previewFilmProcess).toBeNull();

    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 3, operationId: active },
    });
    expect(store.getState().previewFilmProcess).toBe("bwNegative");
  });

  it("invalidates a completed registration when the pre-project process changes", async () => {
    const { store, handle, calls } = scriptedFixture();
    await store.acquireThumbnails(undefined, "bwNegative");
    const active = calls[0].params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 3, operationId: active },
    });
    expect(store.getState().previewFilmProcess).toBe("bwNegative");

    store.setPreviewFilmProcess("positive");

    expect(store.getState().previewFilmProcessSelection).toBe("positive");
    expect(store.getState().previewFilmProcess).toBeNull();
    expect(store.getState().previewOutcome).toBeNull();
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();
  });

  it("tracks active -> failed and stays failed across the correlated failure pair", async () => {
    const { store, handle, calls } = scriptedFixture();
    await store.acquireThumbnails();
    expect(store.getState().previewOutcome).toBe("active");
    expect(store.getState().previewError).toBeNull();
    const active = calls[0].params.operationId as string;

    handle.emitEvent({
      event: "scanner.thumbnailsFailed",
      payload: { code: "BRIDGE_STREAM_STALLED", message: "preview stream stalled", operationId: active },
    });
    expect(store.getState().previewOutcome).toBe("failed");
    expect(store.getState().previewError).toEqual({
      code: "BRIDGE_STREAM_STALLED",
      message: "preview stream stalled",
    });

    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 0, operationId: active },
    });
    // A zero-count completion preceded by a failure is a FAILURE, not an
    // empty success: the outcome stays "failed" and the error survives.
    expect(store.getState().previewOutcome).toBe("failed");
    expect(store.getState().previewError?.message).toBe("preview stream stalled");
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();
  });

  it("tracks active -> succeeded on the correlated success pair", async () => {
    const { store, handle, calls } = scriptedFixture();
    await store.acquireThumbnails();
    expect(store.getState().previewOutcome).toBe("active");
    const active = calls[0].params.operationId as string;

    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 3, operationId: active },
    });
    expect(store.getState().previewOutcome).toBe("succeeded");
    expect(store.getState().previewError).toBeNull();
    expect(store.getState().latestCompletedPreviewOperationId).toBe(active);
  });

  it("resets to null when the wire rejects the preview request", async () => {
    const { store } = scriptedFixture((method) => {
      if (method === "scanner.acquireThumbnails") {
        return {
          error: {
            code: "SCANNER_BUSY",
            message: "scanner is busy",
            recoverable: false,
          },
        };
      }
      return undefined;
    });
    await expect(store.acquireThumbnails()).rejects.toMatchObject({ code: "SCANNER_BUSY" });
    expect(store.getState().previewOutcome).toBeNull();
    expect(store.getState().previewError).toBeNull();
    expect(store.getState().activeOperationId).toBeNull();
    expect(store.getState().previewRequestFailure?.error).toEqual({
      code: "SCANNER_BUSY",
      message: "scanner is busy",
      recoverable: false,
    });
  });

  it("resets to null on loadMedia", async () => {
    const { store, handle, calls } = scriptedFixture((method) => {
      if (method === "sim.loadMedia") return { result: LOADED_ROLL36 };
      return undefined;
    });
    await store.acquireThumbnails();
    const active = calls[0].params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnailsFailed",
      payload: { code: "BRIDGE_STREAM_STALLED", message: "preview stream stalled", operationId: active },
    });
    expect(store.getState().previewOutcome).toBe("failed");
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 0, operationId: active },
    });

    await store.loadMedia("roll36");
    expect(store.getState().previewOutcome).toBeNull();
    expect(store.getState().previewError).toBeNull();
    expect(store.getState().previewRequestFailure).toBeNull();
    expect(store.getState().previewFilmProcess).toBeNull();
  });

  it("resets to null on a project change (#resetSessionBinding)", async () => {
    const { store, handle, calls } = scriptedFixture((method) => {
      if (method === "project.create") return { result: { project: PROJECT, directory: "/tmp/reset" } };
      return undefined;
    });
    await store.acquireThumbnails();
    const active = calls[0].params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnailsFailed",
      payload: { code: "BRIDGE_STREAM_STALLED", message: "preview stream stalled", operationId: active },
    });
    expect(store.getState().previewOutcome).toBe("failed");
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 0, operationId: active },
    });

    await store.createProject("Reset Project", "roll36", 36, "c41ColorNegative", "/tmp/reset");
    expect(store.getState().previewOutcome).toBeNull();
    expect(store.getState().previewError).toBeNull();
    expect(store.getState().previewRequestFailure).toBeNull();
    expect(store.getState().previewFilmProcess).toBeNull();
  });
});
