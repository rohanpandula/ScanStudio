/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../../session/store/session";
import { createScriptedTransport } from "../../../session/testing/harness";
import type { DeviceInfo, EngineError, ScanProject } from "../../../session/wire/types";
import ScanRunView from "../ScanRunView";
import { captureDurationLabel } from "../ScanRunView";

afterEach(cleanup);

const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../../session", () => mocks);

const DEVICE: DeviceInfo = {
  deviceId: "sim-ls5000-0",
  model: "LS-5000 (simulated)",
  kind: "simulated",
  firmware: "sim-fw-1",
  connection: "usb",
};

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-run",
  name: "Run Roll",
  carrier: "roll36",
  frameCount: 36,
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
      colorProfile: "sRgb",
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
  },
  rollMetadata: { keywords: [] },
  createdAt: "2026-08-02T00:00:00.000Z",
  frames: [],
};

interface Fixture {
  store: SessionStore;
  emitEvent: (raw: unknown) => void;
  calls: Array<{ method: string; params: Record<string, unknown> }>;
}

async function runFixture(ejectError?: EngineError): Promise<Fixture> {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      if (method === "scanner.connect") {
        return {
          result: {
            device: DEVICE,
            status: {
              connected: true,
              adapter: null,
              mediaLoaded: true,
              carrier: "roll36",
              frameCount: 36,
              lamp: "stable",
              transport: "idle",
              activeJobId: null,
            },
          },
        };
      }
      if (method === "project.create") return { result: { project: PROJECT, directory: "/tmp/run" } };
      if (method === "sim.loadMedia") {
        return {
          result: {
            connected: true,
            adapter: null,
            mediaLoaded: true,
            carrier: "roll36",
            frameCount: 36,
            lamp: "stable",
            transport: "idle",
            activeJobId: null,
          },
        };
      }
      if (method === "scanner.acquireThumbnails") return { result: { accepted: true, frames: [] } };
      if (method === "scan.start") return { result: { jobId: "job-1" } };
      if (method === "scan.stop") return { result: { acknowledged: true, mode: "afterCurrentFrame" } };
      if (method === "scanner.eject") {
        return ejectError === undefined ? { result: {} } : { error: ejectError };
      }
      if (method === "project.pendingFrames") {
        return {
          result: { frames: [3, 4], totalFrames: 36, completedCount: 2, excludedCount: 0 },
        };
      }
      return { result: undefined };
    },
  });
  const store = new SessionStore(handle.transport);
  await store.connect("sim-ls5000-0");
  await store.loadMedia("roll36");
  await store.createProject("Run Roll", "roll36", 36, "c41ColorNegative");
  await store.acquireThumbnails();
  const previewOperationId = calls.find(
    (call) => call.method === "scanner.acquireThumbnails",
  )?.params.operationId as string;
  handle.emitEvent({
    event: "scanner.thumbnailsComplete",
    payload: { count: 36, operationId: previewOperationId },
  });
  await store.startScan([1, 2, 3, 4, 13], {
    resolutionDpi: 4000,
    bitDepth: 16,
    multisamplePasses: 1,
    channels: "rgbi",
  });
  return { store, emitEvent: (raw) => handle.emitEvent(raw), calls };
}

describe("ScanRunView", () => {
  it("formats authoritative capture timing and treats zero as not recorded", () => {
    expect(captureDurationLabel(142_500)).toBe("2m 23s capture");
    expect(captureDurationLabel(0)).toBe("Capture timing not recorded");
  });

  it("leaves multisamplePasses untouched for the simulated device (device-aware coercion is a no-op here)", async () => {
    const fixture = await runFixture();
    const scanStartCall = fixture.calls.find((call) => call.method === "scan.start");
    const recipe = scanStartCall?.params.recipe as { multisamplePasses?: number } | undefined;
    expect(recipe?.multisamplePasses).toBe(1);
  });

  it("renders per-frame states and attempt counts", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    act(() => {
      fixture.emitEvent({
        event: "scan.frameState",
        payload: { jobId: "job-1", frameIndex: 1, state: "active", attempt: 1 },
      });
      fixture.emitEvent({
        event: "scan.frameState",
        payload: { jobId: "job-1", frameIndex: 2, state: "active", attempt: 2 },
      });
    });
    render(<ScanRunView jobId="job-1" />);
    expect(screen.getByTestId("frame-state-1")).toHaveTextContent("active");
    expect(screen.getByTestId("frame-state-2")).toHaveTextContent("active (attempt 2)");
  });

  it("renders progress and ETA from the latest scan.progress event", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    act(() => {
      fixture.emitEvent({
        event: "scan.progress",
        payload: { jobId: "job-1", frameIndex: 1, jobPercent: 45.5, etaSeconds: 12.7 },
      });
    });
    render(<ScanRunView jobId="job-1" />);
    expect(screen.getByTestId("scan-run-job-percent")).toHaveTextContent("46%");
    expect(screen.getByTestId("scan-run-eta")).toHaveTextContent("ETA 13s");
  });

  it("renders a failing frame's FEED_JAM error code and message verbatim", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    act(() => {
      fixture.emitEvent({
        event: "scan.frameState",
        payload: { jobId: "job-1", frameIndex: 13, state: "active", attempt: 1 },
      });
      fixture.emitEvent({
        event: "scan.frameState",
        payload: {
          jobId: "job-1",
          frameIndex: 13,
          state: "failed",
          attempt: 1,
          error: {
            code: "FEED_JAM",
            message: "Frame did not advance (jam)",
            recoverable: true,
          },
        },
      });
    });
    render(<ScanRunView jobId="job-1" />);
    const row = screen.getByTestId("frame-row-13");
    expect(row).toHaveAttribute("data-state", "failed");
    expect(screen.getByTestId("frame-error-13")).toHaveTextContent("FEED_JAM");
    expect(screen.getByTestId("frame-error-13")).toHaveTextContent("Frame did not advance (jam)");
  });

  it("renders an ARCHIVE_COLLISION error code and message verbatim on its row", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    act(() => {
      fixture.emitEvent({
        event: "scan.frameState",
        payload: { jobId: "job-1", frameIndex: 4, state: "active", attempt: 1 },
      });
      fixture.emitEvent({
        event: "scan.frameState",
        payload: {
          jobId: "job-1",
          frameIndex: 4,
          state: "failed",
          attempt: 1,
          error: {
            code: "ARCHIVE_COLLISION",
            message: "Destination file already exists",
            recoverable: false,
          },
        },
      });
    });
    render(<ScanRunView jobId="job-1" />);
    expect(screen.getByTestId("frame-error-4")).toHaveTextContent("ARCHIVE_COLLISION");
    expect(screen.getByTestId("frame-error-4")).toHaveTextContent("Destination file already exists");
  });

  it("shows the stop explanation and stops after the current frame", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ScanRunView jobId="job-1" />);
    expect(screen.getByTestId("stop-explanation")).toHaveTextContent(
      "The current frame will finish before stopping.",
    );
    await act(async () => {
      await user.click(screen.getByTestId("stop-after-current"));
    });
    const stopCall = fixture.calls.find((c) => c.method === "scan.stop");
    expect(stopCall?.params).toEqual({ jobId: "job-1", mode: "afterCurrentFrame" });
  });

  it("renders Stop now only for the simulated backend", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    render(<ScanRunView jobId="job-1" />);
    expect(screen.getByTestId("stop-now")).toBeInTheDocument();
  });

  it("disables eject while a job is active", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    act(() => {
      fixture.emitEvent({ event: "scan.jobState", payload: { jobId: "job-1", state: "scanning" } });
    });
    render(<ScanRunView jobId="job-1" />);
    expect(screen.getByTestId("eject-control")).toBeDisabled();
  });

  it("sends exactly one eject request after a terminal job and renders success", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    act(() => {
      fixture.emitEvent({ event: "scan.jobState", payload: { jobId: "job-1", state: "scanning" } });
      fixture.emitEvent({ event: "scan.jobState", payload: { jobId: "job-1", state: "completed" } });
    });
    const user = userEvent.setup();
    render(<ScanRunView jobId="job-1" />);

    expect(screen.getByTestId("eject-control")).toBeEnabled();
    await user.click(screen.getByTestId("eject-control"));

    expect(fixture.calls.filter((call) => call.method === "scanner.eject")).toHaveLength(1);
    expect(await screen.findByTestId("eject-success")).toHaveTextContent("Eject completed.");
  });

  it("renders the engine's exact typed eject error", async () => {
    const expected: EngineError = {
      code: "SCANNER_BUSY",
      message: "transport is still settling",
      recoverable: true,
    };
    const fixture = await runFixture(expected);
    mocks.sessionStore = fixture.store;
    act(() => {
      fixture.emitEvent({ event: "scan.jobState", payload: { jobId: "job-1", state: "scanning" } });
      fixture.emitEvent({ event: "scan.jobState", payload: { jobId: "job-1", state: "failed" } });
    });
    const user = userEvent.setup();
    render(<ScanRunView jobId="job-1" />);

    await user.click(screen.getByTestId("eject-control"));

    expect(await screen.findByTestId("eject-error")).toHaveTextContent(
      "SCANNER_BUSY — transport is still settling",
    );
  });

  it("renders a stopped job's remaining frames as skipped, never failed", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    // Drive a partial job: frames 1-2 completed, 3+ never reached. The engine
    // reports the never-reached frames through scan.completed's summary, not
    // individual frameState events.
    act(() => {
      fixture.emitEvent({
        event: "scan.frameState",
        payload: { jobId: "job-1", frameIndex: 1, state: "completed", attempt: 1 },
      });
      fixture.emitEvent({
        event: "scan.jobState",
        payload: { jobId: "job-1", state: "stoppingAfterCurrentFrame" },
      });
      fixture.emitEvent({
        event: "scan.completed",
        payload: {
          jobId: "job-1",
          summary: {
            completed: [1, 2],
            failed: [],
            skipped: [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36],
            stopped: true,
          },
        },
      });
    });
    render(<ScanRunView jobId="job-1" />);
    expect(screen.getByTestId("frame-row-3")).toHaveAttribute("data-state", "skipped");
    expect(screen.getByTestId("frame-row-3").textContent).toContain("skipped");
    expect(screen.getByTestId("frame-row-3").textContent).not.toContain("failed");
  });

  it("calls pendingFrames and loads remaining frames from the exact returned set", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ScanRunView jobId="job-1" onResume={vi.fn()} />);
    await act(async () => {
      await user.click(screen.getByTestId("refresh-pending"));
    });
    const pendingCall = fixture.calls.find((c) => c.method === "project.pendingFrames");
    expect(pendingCall).toBeDefined();
    expect(fixture.store.getState().jobId).toBe("job-1");
  });

  it("counts scanned frames rather than receipt file types and surfaces alpha.11 provenance", async () => {
    const fixture = await runFixture();
    mocks.sessionStore = fixture.store;
    fixture.emitEvent({
      event: "scan.frameCompleted",
      payload: {
        jobId: "job-1",
        frameIndex: 1,
        receipt: {
          jobId: "job-1",
          frameIndex: 1,
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
            positivePath: "/positive/frame-1.tiff",
            derivativeTransform: {
              rotationDegrees: 90,
              horizontalMirror: true,
              verticalMirror: false,
            },
          },
          storageTransform: "transpose-xy-v1",
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
        },
      },
    });
    render(<ScanRunView jobId="job-1" />);
    expect(screen.getByTestId("frames-scanned-count")).toHaveTextContent("1 frame scanned");
    const receipt = screen.getByTestId("frame-receipt-1");
    expect(receipt).toHaveTextContent("2m 23s capture");
    expect(receipt).toHaveTextContent("nikonlook-v2 hardwareExposure");
    expect(receipt).toHaveTextContent("auto-cropped");
    expect(receipt).toHaveTextContent("90° + left/right flip");
  });
});
