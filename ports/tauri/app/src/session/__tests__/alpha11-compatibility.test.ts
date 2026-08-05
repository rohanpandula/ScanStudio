import { describe, expect, it } from "vitest";
import { SessionStore } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import {
  isDeviceInfo,
  isFrameAlignment,
  isOutputRecipe,
  isScanReceipt,
  isWrittenOutputs,
  type CaptureRecipe,
  type FrameAlignment,
  type ScanProject,
  type ScanReceipt,
  type ScannerStatus,
} from "../wire/types";

const CAPTURE: CaptureRecipe = {
  resolutionDpi: 4000,
  bitDepth: 16,
  multisamplePasses: 1,
  channels: "rgbi",
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
  filmPresent: true,
  motionArmed: true,
};

function projectWith(alignment?: FrameAlignment): ScanProject {
  return {
    schemaVersion: 4,
    id: "alpha11-project",
    name: "Alpha 11",
    carrier: "strip6",
    frameCount: 2,
    filmProcess: "c41ColorNegative",
    recipes: {
      archive: {
        enabled: true,
        filenameTemplate: "IMG_####.tiff",
        destination: "/archive",
        fullCapturePackage: true,
      },
      positive: {
        enabled: true,
        fileFormat: "tiff",
        colorProfile: "adobeRgb1998",
        filenameTemplate: "POS_####.tiff",
        destination: "/positive",
      },
      preview: {
        enabled: true,
        fileFormat: "jpeg",
        maxLongEdgePx: 2048,
        filenameTemplate: "PRE_####.jpg",
        destination: "/preview",
      },
      autoCrop: true,
    },
    rollMetadata: { keywords: [] },
    createdAt: "2026-08-03T12:00:00Z",
    frames: [
      { index: 1, excluded: false, ...(alignment ? { alignment } : {}), receipts: [] },
      { index: 2, excluded: false, receipts: [] },
    ],
  };
}

function fullReceipt(frameIndex = 1): ScanReceipt {
  return {
    jobId: "job-alpha11",
    frameIndex,
    startedAt: "2026-08-03T12:34:56Z",
    durationMs: 142_500,
    passes: 1,
    resolutionDpi: 4000,
    bitDepth: 16,
    channels: "rgbi",
    engineVersion: "0.3.0-alpha.11",
    deviceId: "real-ls5000-0",
    simulated: false,
    settingsFingerprint: "1a3d265e0b54bbd2",
    outputs: {
      positivePath: "/positive/POS_0001.tiff",
      previewPath: "/preview/PRE_0001.jpg",
      derivativeTransform: {
        rotationDegrees: 90,
        horizontalMirror: true,
        verticalMirror: false,
      },
    },
    rgbPath: "/capture/frame-0001_RGB.tiff",
    irPath: "/capture/frame-0001_IR.tiff",
    storageTransform: "transpose-xy-v1",
    meterRgbiPath: "/capture/frame-0001_METER.tiff",
    nikonlook: {
      bundleVersion: "nikonlook-v2",
      layerAPath: "hardwareExposure",
      gains: [1.01, 0.99, 1.03],
    },
    autoCrop: {
      mode: "image",
      applied: true,
      roi: { y1: 10, y2: 3930, x1: 12, x2: 5770 },
      sourceWidth: 5782,
      sourceHeight: 3946,
    },
  };
}

describe("alpha.11 wire compatibility", () => {
  it("accepts real devices, auto-crop recipes, transforms, and current receipt provenance", () => {
    expect(
      isDeviceInfo({
        deviceId: "real-ls5000-0",
        model: "SUPER COOLSCAN 5000 ED",
        kind: "real",
        firmware: "1.02",
        connection: "USB",
      }),
    ).toBe(true);
    expect(isOutputRecipe(projectWith().recipes)).toBe(true);
    expect(
      isFrameAlignment({
        offsetRows: 0,
        approved: false,
        derivativeTransform: {
          rotationDegrees: 270,
          horizontalMirror: false,
          verticalMirror: true,
        },
      }),
    ).toBe(true);
    expect(isWrittenOutputs(fullReceipt().outputs)).toBe(true);
    expect(isScanReceipt(fullReceipt())).toBe(true);
  });

  it("retains legacy defaults while rejecting unsupported rotations and malformed provenance", () => {
    expect(isFrameAlignment({ offsetRows: 0, approved: false })).toBe(true);
    expect(isWrittenOutputs({ positivePath: "/legacy.tiff" })).toBe(true);
    expect(
      isFrameAlignment({
        offsetRows: 0,
        approved: false,
        derivativeTransform: {
          rotationDegrees: 45,
          horizontalMirror: false,
          verticalMirror: false,
        },
      }),
    ).toBe(false);
    expect(
      isScanReceipt({
        ...fullReceipt(),
        nikonlook: { bundleVersion: "nikonlook-v2", layerAPath: "guess", gains: [1, 1, 1] },
      }),
    ).toBe(false);
  });
});

describe("alpha.11 session policy", () => {
  it("persists selected frame transforms before scan.start and restores them from a project", async () => {
    let project = projectWith();
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, rawParams) => {
        const params = rawParams as Record<string, unknown>;
        calls.push({ method, params });
        if (method === "project.create") return { result: { project, directory: "/project" } };
        if (method === "project.setFrameAlignment") {
          const frameIndex = params.frameIndex as number;
          const alignment = params.alignment as FrameAlignment;
          project = {
            ...project,
            frames: project.frames.map((frame) =>
              frame.index === frameIndex ? { ...frame, alignment } : frame,
            ),
          };
          return { result: { project } };
        }
        if (method === "scan.start") return { result: { jobId: "job-alpha11" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.createProject("Alpha 11", "strip6", 2, "c41ColorNegative");
    store.rotateFrames([1], 90);
    store.toggleHorizontalMirror([1]);
    await store.startScan([1], CAPTURE);

    expect(calls.map((call) => call.method)).toEqual([
      "project.create",
      "project.setFrameAlignment",
      "scan.start",
    ]);
    expect(calls[1].params.alignment).toEqual({
      offsetRows: 0,
      approved: false,
      derivativeTransform: {
        rotationDegrees: 90,
        horizontalMirror: true,
        verticalMirror: false,
      },
    });
    expect(store.frameDerivativeTransform(1)).toEqual(
      (calls[1].params.alignment as FrameAlignment).derivativeTransform,
    );
  });

  it("revalidates film registration after an awaited transform save before scan.start", async () => {
    let project = projectWith();
    let emitEvent: ((raw: unknown) => void) | null = null;
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, rawParams) => {
        const params = rawParams as Record<string, unknown>;
        calls.push({ method, params });
        if (method === "project.create") return { result: { project, directory: "/project" } };
        if (method === "project.setFrameAlignment") {
          const frameIndex = params.frameIndex as number;
          const alignment = params.alignment as FrameAlignment;
          project = {
            ...project,
            frames: project.frames.map((frame) =>
              frame.index === frameIndex ? { ...frame, alignment } : frame,
            ),
          };
          emitEvent?.({
            event: "scanner.status",
            payload: {
              status: {
                ...STATUS,
                mediaLoaded: false,
                frameCount: null,
                filmPresent: false,
              },
            },
          });
          return { result: { project } };
        }
        if (method === "scan.start") return { result: { jobId: "must-not-start" } };
        return { result: undefined };
      },
    });
    emitEvent = handle.emitEvent;
    const store = new SessionStore(handle.transport);
    await store.createProject("Alpha 11", "strip6", 2, "c41ColorNegative");
    store.rotateFrames([1], 90);

    await expect(store.startScan([1], CAPTURE)).rejects.toMatchObject({
      code: "INVALID_PARAMS",
      recoverable: false,
    });
    expect(calls.filter((call) => call.method === "project.setFrameAlignment")).toHaveLength(1);
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(0);
    expect(store.getState()).toMatchObject({
      scanStartPending: false,
      jobState: null,
    });
  });

  it("invalidates a lost registration, preserves finished receipts, and blocks capture until a fresh preview", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, rawParams) => {
        const params = rawParams as Record<string, unknown>;
        calls.push({ method, params });
        if (method === "sim.loadMedia") return { result: STATUS };
        if (method === "project.create") {
          return { result: { project: projectWith(), directory: "/project" } };
        }
        if (method === "scanner.acquireThumbnails") {
          return { result: { accepted: true, frames: [1, 2] } };
        }
        if (method === "scan.start") return { result: { jobId: "job-alpha11" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.loadMedia("strip6");
    await store.createProject("Alpha 11", "strip6", 2, "c41ColorNegative");
    await store.acquireThumbnails();
    const operationId = calls.find((call) => call.method === "scanner.acquireThumbnails")
      ?.params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex: 1,
        thumbnail: { imagePath: "/preview/frame-1.tiff" },
        operationId,
      },
    });
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 2, operationId },
    });
    store.toggleFrameSelection(1, false);
    await store.startScan([1, 2], CAPTURE);
    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-alpha11", frameIndex: 1, state: "active", attempt: 1 },
    });
    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-alpha11", frameIndex: 1, state: "completed", attempt: 1 },
    });
    handle.emitEvent({
      event: "scan.frameCompleted",
      payload: { jobId: "job-alpha11", frameIndex: 1, receipt: fullReceipt(1) },
    });
    handle.emitEvent({
      event: "scan.frameState",
      payload: { jobId: "job-alpha11", frameIndex: 2, state: "active", attempt: 1 },
    });
    handle.emitEvent({
      event: "scan.frameState",
      payload: {
        jobId: "job-alpha11",
        frameIndex: 2,
        state: "failed",
        attempt: 1,
        error: {
          code: "FILM_FEED_INTERRUPTED",
          message: "verified medium not present while positioning frame 2",
          recoverable: false,
        },
      },
    });

    const state = store.getState();
    expect(state.filmFeedInterrupted?.code).toBe("FILM_FEED_INTERRUPTED");
    expect(state.connection.status).toMatchObject({ mediaLoaded: false, frameCount: null });
    expect(state.latestCompletedPreviewOperationId).toBeNull();
    expect(state.thumbnails).toEqual({});
    expect(state.selectedFrameIndices).toEqual([]);
    expect(state.frameReceipts[1]).toEqual([fullReceipt(1)]);

    await expect(store.startScan([2], CAPTURE)).rejects.toMatchObject({
      code: "FILM_FEED_INTERRUPTED",
      recoverable: false,
    });
    expect(calls.filter((call) => call.method === "scan.start")).toHaveLength(1);
  });
});
