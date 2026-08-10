import { describe, expect, it } from "vitest";
import { SessionStore, preProjectPreviewRegistration } from "../store/session";
import { createScriptedTransport } from "../testing/harness";
import type { DeviceInfo, ScanProject, ScannerStatus } from "../wire/types";

const DEVICE: DeviceInfo = {
  deviceId: "sim-strip",
  model: "LS-5000 (simulated)",
  kind: "simulated",
  firmware: "sim-1",
  connection: "virtual",
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
};

function project(filmProcess: ScanProject["filmProcess"] = "bwNegative"): ScanProject {
  return {
    schemaVersion: 4,
    id: "project-attached",
    name: "Attached strip",
    carrier: "strip6",
    frameCount: 2,
    filmProcess,
    recipes: {
      archive: {
        enabled: false,
        filenameTemplate: "scan_{frame:04d}",
        destination: "/tmp/attached",
      },
      positive: {
        enabled: true,
        fileFormat: "tiff",
        colorProfile: "adobeRgb1998",
        filenameTemplate: "scan_{frame:04d}",
        destination: "/tmp/attached",
      },
      preview: {
        enabled: false,
        fileFormat: "jpeg",
        maxLongEdgePx: 1024,
        filenameTemplate: "preview_{frame:04d}",
        destination: "/tmp/attached",
      },
    },
    rollMetadata: { keywords: [] },
    createdAt: "2026-08-10T00:00:00Z",
    frames: [1, 2].map((index) => ({ index, excluded: false, receipts: [] })),
  };
}

function fixture() {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  let persistedProject = project();
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      if (method === "scanner.connect") return { result: { device: DEVICE, status: STATUS } };
      if (method === "scanner.acquireThumbnails") {
        return { result: { accepted: true, frames: [1, 2] } };
      }
      if (method === "project.create") {
        persistedProject = project();
        return { result: { project: persistedProject, directory: "/tmp/attached" } };
      }
      if (method === "project.setFrameAlignment") {
        const request = params as {
          frameIndex: number;
          alignment: ScanProject["frames"][number]["alignment"] | null;
        };
        persistedProject = {
          ...persistedProject,
          frames: persistedProject.frames.map((frame) => {
            if (frame.index !== request.frameIndex) return frame;
            if (request.alignment === null) {
              const { alignment: _removed, ...withoutAlignment } = frame;
              return withoutAlignment;
            }
            return { ...frame, alignment: request.alignment };
          }),
        };
        return { result: { project: persistedProject } };
      }
      if (method === "project.open") {
        return { result: { project: persistedProject, directory: "/tmp/attached" } };
      }
      if (method === "scan.start") return { result: { jobId: "job-active" } };
      return { result: undefined };
    },
  });
  return { store: new SessionStore(handle.transport), handle, calls };
}

async function completePreview() {
  const value = fixture();
  await value.store.connect(DEVICE.deviceId);
  value.store.setPreviewFilmProcess("bwNegative");
  await value.store.acquireThumbnails();
  const operationId = value.calls.find(
    (call) => call.method === "scanner.acquireThumbnails",
  )?.params.operationId as string;
  for (const frameIndex of [1, 2]) {
    value.handle.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex,
        thumbnail: { brightness: frameIndex / 3 },
        operationId,
      },
    });
  }
  value.handle.emitEvent({
    event: "scanner.thumbnailsComplete",
    payload: { count: 2, operationId },
  });
  return { ...value, operationId };
}

describe("pre-project preview attachment", () => {
  it("recognizes only an exact, fully correlated completed registration", async () => {
    const { store, operationId } = await completePreview();
    expect(preProjectPreviewRegistration(store.getState())).toEqual({
      operationId,
      carrier: "strip6",
      frameCount: 2,
      filmProcess: "bwNegative",
    });
  });

  it("keeps the completed token through the real backend's correlated terminal status", async () => {
    const emptyStatus: ScannerStatus = {
      ...STATUS,
      mediaLoaded: false,
      carrier: null,
      frameCount: null,
      motionArmed: true,
      filmPresent: true,
    };
    const realDevice: DeviceInfo = { ...DEVICE, kind: "real" };
    let operationId = "";
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        if (method === "scanner.connect") {
          return { result: { device: realDevice, status: emptyStatus } };
        }
        if (method === "scanner.acquireThumbnails") {
          operationId = (params as Record<string, unknown>).operationId as string;
          return { result: { accepted: true, frames: [1, 2] } };
        }
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.connect(realDevice.deviceId);
    store.setPreviewFilmProcess("bwNegative");
    await store.acquireThumbnails();
    for (const frameIndex of [1, 2]) {
      handle.emitEvent({
        event: "scanner.thumbnail",
        payload: { frameIndex, thumbnail: { brightness: 0.5 }, operationId },
      });
    }
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 2, operationId },
    });
    expect(preProjectPreviewRegistration(store.getState())).toBeNull();

    handle.emitEvent({
      event: "scanner.status",
      payload: { status: STATUS, operationId },
    });

    expect(store.getState().latestCompletedPreviewOperationId).toBe(operationId);
    expect(preProjectPreviewRegistration(store.getState())).toMatchObject({
      operationId,
      carrier: "strip6",
      frameCount: 2,
      filmProcess: "bwNegative",
    });
  });

  it("waits for this real preview's correlated status instead of reusing an old same-count holder", async () => {
    const realDevice: DeviceInfo = { ...DEVICE, kind: "real" };
    const priorStatus: ScannerStatus = {
      ...STATUS,
      carrier: "mounted",
      frameCount: 1,
      motionArmed: true,
      filmPresent: true,
    };
    const detectedStatus: ScannerStatus = {
      ...priorStatus,
      carrier: "strip6",
    };
    let operationId = "";
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        if (method === "scanner.connect") {
          return { result: { device: realDevice, status: priorStatus } };
        }
        if (method === "scanner.acquireThumbnails") {
          operationId = (params as Record<string, unknown>).operationId as string;
          return { result: { accepted: true, frames: [1] } };
        }
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.connect(realDevice.deviceId);
    store.setPreviewFilmProcess("bwNegative");
    await store.acquireThumbnails();
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: { frameIndex: 1, thumbnail: { brightness: 0.5 }, operationId },
    });
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId },
    });

    expect(store.getState().previewOutcome).toBe("succeeded");
    expect(preProjectPreviewRegistration(store.getState())).toBeNull();

    handle.emitEvent({
      event: "scanner.status",
      payload: { status: detectedStatus, operationId },
    });
    expect(preProjectPreviewRegistration(store.getState())).toMatchObject({
      operationId,
      carrier: "strip6",
      frameCount: 1,
    });
  });

  it("drops out-of-range tiles when a correlated real re-preview detects fewer frames", async () => {
    const realDevice: DeviceInfo = { ...DEVICE, kind: "real" };
    const firstStatus: ScannerStatus = {
      ...STATUS,
      motionArmed: true,
      filmPresent: true,
    };
    const secondStatus: ScannerStatus = {
      ...firstStatus,
      adapter: "MA-21",
      carrier: "mounted",
      frameCount: 1,
    };
    const operationIds: string[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        if (method === "scanner.connect") {
          return { result: { device: realDevice, status: firstStatus } };
        }
        if (method === "scanner.acquireThumbnails") {
          const operationId = (params as Record<string, unknown>).operationId as string;
          operationIds.push(operationId);
          return { result: { accepted: true, frames: operationIds.length === 1 ? [1, 2] : [1] } };
        }
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.connect(realDevice.deviceId);
    await store.acquireThumbnails();
    for (const frameIndex of [1, 2]) {
      handle.emitEvent({
        event: "scanner.thumbnail",
        payload: {
          frameIndex,
          thumbnail: { brightness: 0.5 },
          operationId: operationIds[0],
        },
      });
    }
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 2, operationId: operationIds[0] },
    });
    handle.emitEvent({
      event: "scanner.status",
      payload: { status: firstStatus, operationId: operationIds[0] },
    });
    expect(Object.keys(store.getState().thumbnails).map(Number)).toEqual([1, 2]);

    await store.acquireThumbnails();
    expect(store.getState().thumbnails).toEqual({});
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex: 1,
        thumbnail: { brightness: 0.6 },
        operationId: operationIds[1],
      },
    });
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId: operationIds[1] },
    });
    handle.emitEvent({
      event: "scanner.status",
      payload: { status: secondStatus, operationId: operationIds[1] },
    });

    expect(Object.keys(store.getState().thumbnails).map(Number)).toEqual([1]);
    expect(preProjectPreviewRegistration(store.getState())).toMatchObject({
      operationId: operationIds[1],
      carrier: "mounted",
      frameCount: 1,
    });
  });

  it("keeps an invalidated preview lane locked until its correlated terminal", async () => {
    const { store, handle, calls } = fixture();
    await store.connect(DEVICE.deviceId);
    await store.acquireThumbnails();
    const operationId = calls.find(
      (call) => call.method === "scanner.acquireThumbnails",
    )?.params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: { frameIndex: 1, thumbnail: { brightness: 0.5 }, operationId },
    });

    handle.emitEvent({
      event: "scanner.status",
      payload: { status: { ...STATUS, carrier: "mounted", frameCount: 1 } },
    });

    expect(store.getState().activeOperationId).toBe(operationId);
    expect(store.getState().previewOutcome).toBe("active");
    expect(store.getState().thumbnails).toEqual({});
    await expect(store.acquireThumbnails()).rejects.toMatchObject({
      code: "INVALID_PARAMS",
      message: expect.stringMatching(/already active/),
    });

    handle.emitEvent({
      event: "scanner.thumbnailsFailed",
      payload: {
        code: "BRIDGE_STREAM_STALLED",
        message: "stale worker failed after its media was retired",
        operationId,
      },
    });
    expect(store.getState().previewOutcome).toBe("active");
    expect(store.getState().previewError).toBeNull();

    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId },
    });
    expect(store.getState().activeOperationId).toBeNull();
    expect(store.getState().previewOutcome).toBeNull();
    expect(store.getState().latestCompletedPreviewOperationId).toBeNull();
    expect(store.getState().previewFilmProcess).toBeNull();
  });

  it("refuses preview and project changes until a failed worker releases its lane", async () => {
    const { store, handle, calls } = fixture();
    await store.connect(DEVICE.deviceId);
    await store.acquireThumbnails();
    const activeOperationId = store.getState().activeOperationId;

    await expect(
      store.createProject("Unsafe", "strip6", 2, "c41ColorNegative"),
    ).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    await expect(store.openProject("/tmp/unsafe")).rejects.toMatchObject({
      code: "INVALID_PARAMS",
    });
    await expect(
      store.startScan([1], {
        resolutionDpi: 4000,
        bitDepth: 16,
        multisamplePasses: 1,
        channels: "rgbi",
      }),
    ).rejects.toMatchObject({ code: "INVALID_PARAMS" });

    expect(calls.some((call) => call.method === "project.create")).toBe(false);
    expect(calls.some((call) => call.method === "project.open")).toBe(false);
    expect(store.getState().activeOperationId).toBe(activeOperationId);
    expect(store.getState().previewOutcome).toBe("active");

    handle.emitEvent({
      event: "scanner.thumbnailsFailed",
      payload: {
        code: "BRIDGE_STREAM_STALLED",
        message: "worker is winding down",
        operationId: activeOperationId,
      },
    });
    expect(store.getState().previewOutcome).toBe("failed");
    expect(store.getState().activeOperationId).toBe(activeOperationId);

    await expect(store.acquireThumbnails()).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    await expect(
      store.createProject("Unsafe", "strip6", 2, "c41ColorNegative"),
    ).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    await expect(store.openProject("/tmp/unsafe")).rejects.toMatchObject({
      code: "INVALID_PARAMS",
    });
    expect(calls.filter((call) => call.method === "scanner.acquireThumbnails")).toHaveLength(1);
    expect(calls.some((call) => call.method === "project.create")).toBe(false);
    expect(calls.some((call) => call.method === "project.open")).toBe(false);

    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 0, operationId: activeOperationId },
    });
    expect(store.getState().activeOperationId).toBeNull();
  });

  it("blocks previews and project switches while a scan owns the session", async () => {
    const { store, handle, calls } = fixture();
    await store.createProject("Scanning", "strip6", 2, "bwNegative");
    await store.startScan([1], {
      resolutionDpi: 4000,
      bitDepth: 16,
      multisamplePasses: 1,
      channels: "rgbi",
    });
    handle.emitEvent({
      event: "scan.jobState",
      payload: { jobId: "job-active", state: "scanning" },
    });
    const wireCount = calls.length;

    await expect(store.acquireThumbnails()).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    await expect(
      store.createProject("Other", "strip6", 2, "bwNegative"),
    ).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    await expect(store.openProject("/tmp/other")).rejects.toMatchObject({
      code: "INVALID_PARAMS",
    });
    await expect(
      store.startScan([2], {
        resolutionDpi: 4000,
        bitDepth: 16,
        multisamplePasses: 1,
        channels: "rgbi",
      }),
    ).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    expect(calls).toHaveLength(wireCount);
    expect(store.getState().jobId).toBe("job-active");
    expect(store.getState().jobState).toBe("scanning");
  });

  it("locks preview, project actions, and transforms across a slow project boundary", async () => {
    let resolveCreate!: (value: unknown) => void;
    const createResponse = new Promise<unknown>((resolve) => {
      resolveCreate = resolve;
    });
    const calls: string[] = [];
    const handle = createScriptedTransport({
      onRequest: (method) => {
        calls.push(method);
        if (method === "project.create") return { result: createResponse };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);

    const creating = store.createProject("Slow", "strip6", 2, "bwNegative");
    expect(store.getState().projectChangePending).toBe(true);
    expect(store.frameTransformsAreEditable()).toBe(false);
    store.rotateFrames([1], 90);
    expect(store.getState().frameAlignmentDrafts).toEqual({});

    await expect(store.acquireThumbnails()).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    await expect(store.openProject("/tmp/other")).rejects.toMatchObject({
      code: "INVALID_PARAMS",
    });
    await expect(
      store.createProject("Other", "strip6", 2, "bwNegative"),
    ).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    await expect(store.setSpacingOffset(1, 0)).rejects.toMatchObject({
      code: "INVALID_PARAMS",
    });
    expect(calls).toEqual(["project.create"]);

    resolveCreate({ project: project(), directory: "/tmp/attached" });
    await creating;
    expect(store.getState().projectChangePending).toBe(false);
    expect(store.getState().project?.id).toBe("project-attached");
  });

  it("publishes a store-wide lock while a device connection change is in flight", async () => {
    let resolveConnect!: (value: unknown) => void;
    const connectResponse = new Promise<unknown>((resolve) => {
      resolveConnect = resolve;
    });
    const calls: string[] = [];
    const handle = createScriptedTransport({
      onRequest: (method) => {
        calls.push(method);
        if (method === "scanner.connect") return { result: connectResponse };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    const connecting = store.connect(DEVICE.deviceId);

    expect(store.getState().connectionChangePending).toBe(true);
    await expect(store.acquireThumbnails()).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    await expect(
      store.createProject("Blocked", "strip6", 2, "bwNegative"),
    ).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    expect(calls).toEqual(["scanner.connect"]);

    handle.emitEvent({ event: "scanner.status", payload: { status: STATUS } });
    expect(store.getState().connection).toMatchObject({
      connected: false,
      device: null,
    });

    resolveConnect({ device: DEVICE, status: STATUS });
    await connecting;
    expect(store.getState().connectionChangePending).toBe(false);
    expect(store.getState().connection.connected).toBe(true);
  });

  it("waits for an in-flight spacing adjustment before attaching and persisting the project", async () => {
    let resolveSpacing!: (value: unknown) => void;
    const spacingResponse = new Promise<unknown>((resolve) => {
      resolveSpacing = resolve;
    });
    let operationId = "";
    let persistedProject = project();
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        const request = params as Record<string, unknown>;
        calls.push({ method, params: request });
        if (method === "scanner.connect") {
          return { result: { device: DEVICE, status: STATUS } };
        }
        if (method === "scanner.acquireThumbnails") {
          operationId = request.operationId as string;
          return { result: { accepted: true, frames: [1, 2] } };
        }
        if (method === "roll.setSpacingOffset") return { result: spacingResponse };
        if (method === "project.create") {
          persistedProject = project();
          return { result: { project: persistedProject, directory: "/tmp/attached" } };
        }
        if (method === "project.setFrameAlignment") {
          const frameIndex = request.frameIndex as number;
          const alignment = request.alignment as ScanProject["frames"][number]["alignment"];
          persistedProject = {
            ...persistedProject,
            frames: persistedProject.frames.map((frame) =>
              frame.index === frameIndex ? { ...frame, alignment } : frame,
            ),
          };
          return { result: { project: persistedProject } };
        }
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.connect(DEVICE.deviceId);
    store.setPreviewFilmProcess("bwNegative");
    await store.acquireThumbnails();
    for (const frameIndex of [1, 2]) {
      handle.emitEvent({
        event: "scanner.thumbnail",
        payload: { frameIndex, thumbnail: { brightness: 0.5 }, operationId },
      });
    }
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 2, operationId },
    });

    const adjusting = store.setSpacingOffset(1, 12);
    expect(store.getState().frameAlignmentMutationPending).toBe(true);
    await expect(
      store.createProject("Too soon", "strip6", 2, "bwNegative"),
    ).rejects.toMatchObject({ code: "INVALID_PARAMS" });
    expect(calls.some((call) => call.method === "project.create")).toBe(false);

    resolveSpacing({ thumbnail: { brightness: 0.5, spacingOffset: 12 } });
    await adjusting;
    expect(store.getState().frameAlignmentDrafts[1]?.offsetRows).toBe(12);

    await store.createProject("Attached", "strip6", 2, "bwNegative");
    expect(
      calls.find((call) => call.method === "project.setFrameAlignment")?.params,
    ).toMatchObject({ frameIndex: 1, alignment: { offsetRows: 12 } });
    expect(
      store.getState().project?.frames.find((frame) => frame.index === 1)?.alignment
        ?.offsetRows,
    ).toBe(12);
  });

  it("does not replay unsaved alignment from one physical roll onto the next", async () => {
    const { store, handle, calls } = await completePreview();
    store.rotateFrames([1], 90);
    expect(store.getState().frameAlignmentDrafts[1]).toBeDefined();

    handle.emitEvent({
      event: "scanner.status",
      payload: {
        status: { ...STATUS, carrier: "mounted", frameCount: 1 },
      },
    });

    expect(store.getState().frameAlignmentDrafts).toEqual({});
    await store.acquireThumbnails();
    const acquireCalls = calls.filter(
      (call) => call.method === "scanner.acquireThumbnails",
    );
    const secondOperationId = acquireCalls[acquireCalls.length - 1]
      .params.operationId as string;
    handle.emitEvent({
      event: "scanner.thumbnail",
      payload: {
        frameIndex: 1,
        thumbnail: { brightness: 0.5 },
        operationId: secondOperationId,
      },
    });
    handle.emitEvent({
      event: "scanner.thumbnailsComplete",
      payload: { count: 1, operationId: secondOperationId },
    });

    expect(preProjectPreviewRegistration(store.getState())).toMatchObject({
      operationId: secondOperationId,
      carrier: "mounted",
      frameCount: 1,
    });
    expect(store.getState().frameAlignmentDrafts).toEqual({});
  });

  it("preserves preview identity, tiles, selection, focus, and transforms when saving it", async () => {
    const { store, operationId, calls } = await completePreview();
    store.toggleFrameSelection(1, false);
    store.focusFrame(1);
    store.rotateFrames([1], 90);

    await store.createProject("Attached strip", "strip6", 2, "bwNegative");
    const state = store.getState();

    expect(state.project?.id).toBe("project-attached");
    expect(state.latestCompletedPreviewOperationId).toBe(operationId);
    expect(state.previewOutcome).toBe("succeeded");
    expect(state.previewFilmProcess).toBe("bwNegative");
    expect(Object.keys(state.thumbnails).map(Number)).toEqual([1, 2]);
    expect(state.thumbnailOperationIds).toEqual({ 1: operationId, 2: operationId });
    expect(state.selectedFrameIndices).toEqual([1]);
    expect(state.focusedFrameIndex).toBe(1);
    expect(state.frameAlignmentDrafts[1]?.derivativeTransform?.rotationDegrees).toBe(90);
    expect(
      calls.find((call) => call.method === "project.setFrameAlignment")?.params,
    ).toMatchObject({
      frameIndex: 1,
      alignment: {
        derivativeTransform: { rotationDegrees: 90 },
      },
    });
    expect(
      state.project?.frames.find((frame) => frame.index === 1)?.alignment
        ?.derivativeTransform?.rotationDegrees,
    ).toBe(90);

    await store.openProject("/tmp/attached");
    expect(
      store.getState().frameAlignmentDrafts[1]?.derivativeTransform?.rotationDegrees,
    ).toBe(90);
  });

  it("refuses a process conflicting with the attached project's authority before the wire", async () => {
    const { store, calls } = await completePreview();
    await store.createProject("Attached strip", "strip6", 2, "bwNegative");
    const before = calls.filter(
      (call) => call.method === "scanner.acquireThumbnails",
    ).length;

    await expect(store.acquireThumbnails(undefined, "positive")).rejects.toMatchObject({
      code: "INVALID_PARAMS",
      message: expect.stringMatching(/filmProcess conflicts/),
    });
    expect(
      calls.filter((call) => call.method === "scanner.acquireThumbnails"),
    ).toHaveLength(before);
  });

  it("surfaces a malformed project.create result as a typed internal error", async () => {
    const handle = createScriptedTransport({
      onRequest: (method) =>
        method === "project.create"
          ? { result: { project: null, directory: "/tmp/bad" } }
          : { result: undefined },
    });
    const store = new SessionStore(handle.transport);

    await expect(
      store.createProject("Bad", "strip6", 2, "bwNegative"),
    ).rejects.toMatchObject({
      code: "INTERNAL",
      message: "project.create returned an invalid project",
    });
    expect(store.getState().project).toBeNull();
    expect(store.getState().projectChangePending).toBe(false);
  });

  it("fully invalidates the attachment when a saved project is opened", async () => {
    const { store } = await completePreview();
    await store.openProject("/tmp/attached");
    const state = store.getState();

    expect(state.latestCompletedPreviewOperationId).toBeNull();
    expect(state.previewFilmProcess).toBeNull();
    expect(state.previewOutcome).toBeNull();
    // The prior tiles may remain visible as stale context, but clearing their
    // provenance makes them unusable for approval or scan authorization.
    expect(Object.keys(state.thumbnails).map(Number)).toEqual([1, 2]);
    expect(state.thumbnailOperationIds).toEqual({});
  });
});
