/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../session/store/session";
import { createScriptedTransport } from "../session/testing/harness";
import type { ScanProject } from "../session/wire/types";
import App from "../App";

afterEach(() => {
  cleanup();
  mocks.invoke.mockReset();
  vi.restoreAllMocks();
});

const mocks = vi.hoisted(() => ({ sessionStore: null as unknown, invoke: vi.fn() }));
vi.mock("../session", () => mocks);
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("../runtime", () => ({
  isTauriRuntime: () => true,
  isWebSimulatorPreview: () => false,
}));

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-app",
  name: "App Roll",
  carrier: "roll36",
  frameCount: 36,
  filmProcess: "c41ColorNegative",
  recipes: {
    archive: { enabled: true, filenameTemplate: "IMG_####.tiff", destination: "/a", fullCapturePackage: true },
    positive: {
      enabled: true,
      fileFormat: "tiff",
      colorProfile: "sRgb",
      filenameTemplate: "POS_####.tiff",
      destination: "/p",
    },
    preview: {
      enabled: true,
      fileFormat: "jpeg",
      maxLongEdgePx: 2048,
      filenameTemplate: "PRE_####.jpg",
      destination: "/v",
    },
  },
  rollMetadata: { keywords: [] },
  createdAt: "2026-08-02T00:00:00.000Z",
  frames: [],
};

const CONNECTED_STATUS = {
  connected: true,
  adapter: null,
  mediaLoaded: true,
  carrier: "roll36",
  frameCount: 36,
  lamp: "stable",
  transport: "idle",
  activeJobId: null,
};

function disconnectedStore(): SessionStore {
  const handle = createScriptedTransport({
    onRequest: (method) => {
      if (method === "scanner.list") return { result: { devices: [] } };
      return { result: undefined };
    },
  });
  return new SessionStore(handle.transport);
}

function useUserAgent(userAgent: string): void {
  vi.spyOn(window.navigator, "userAgent", "get").mockReturnValue(userAgent);
}

describe("App release surfaces", () => {
  it("removes the phase placeholder and does not expose Windows checks on other platforms", () => {
    useUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)");
    mocks.sessionStore = disconnectedStore();

    render(<App />);

    expect(screen.queryByText(/Inspector arrives/i)).toBeNull();
    expect(screen.queryByRole("button", { name: "Check Windows setup" })).toBeNull();
    expect(screen.queryByTestId("shell-inspector")).toBeNull();
    expect(mocks.invoke).not.toHaveBeenCalled();
  });

  it("runs the Windows setup probes only after the user asks for them", async () => {
    useUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
    mocks.sessionStore = disconnectedStore();
    mocks.invoke.mockImplementation((command: string) => {
      if (command === "wsl_run_checks") return Promise.resolve([]);
      if (command === "wsl_max_read_report") {
        return Promise.resolve({ maxBytes: null, entriesScanned: 0 });
      }
      if (command === "wsl_write_mode_report") return Promise.resolve("stage-then-move");
      return Promise.reject(new Error(`unexpected command ${command}`));
    });
    const user = userEvent.setup();

    render(<App />);

    const setupAction = screen.getByRole("button", { name: "Check Windows setup" });
    expect(screen.queryByTestId("setup-checker")).toBeNull();
    expect(mocks.invoke).not.toHaveBeenCalled();

    await user.click(setupAction);

    expect(await screen.findByTestId("setup-checker")).toBeInTheDocument();
    expect(mocks.invoke.mock.calls.map(([command]) => command)).toEqual([
      "wsl_run_checks",
      "wsl_max_read_report",
      "wsl_write_mode_report",
    ]);
  });
});

describe("App shell reachability (06-03 Task 2)", () => {
  it("navigates from the contact sheet into FrameDetailView and CaptureWorkflowView", async () => {
    const parseCalls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        parseCalls.push({ method, params: params as Record<string, unknown> });
        if (method === "scanner.connect") {
          return {
            result: {
              device: {
                deviceId: "sim-ls5000-0",
                model: "LS-5000 (simulated)",
                kind: "simulated" as const,
                firmware: "sim-fw-1",
                connection: "usb",
              },
              status: CONNECTED_STATUS,
            },
          };
        }
        if (method === "sim.loadMedia") return { result: CONNECTED_STATUS };
        if (method === "project.create") {
          return { result: { project: PROJECT, directory: "/tmp/app" } };
        }
        if (method === "scanner.acquireThumbnails") return { result: { accepted: true, frames: [] } };
        if (method === "scan.start") return { result: { jobId: "job-1" } };
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await act(async () => {
      await store.connect("sim-ls5000-0");
      await store.loadMedia("roll36");
      await store.createProject("App Roll", "roll36", 36, "c41ColorNegative");
    });
    mocks.sessionStore = store;
    const user = userEvent.setup();
    render(<App />);

    // Acquire a preview so the store has an active operationId, then emit
    // frame 5's thumbnail bound to it so the frame-detail view fully mounts
    // (with its Close affordance) rather than the loading placeholder.
    await act(async () => {
      await store.acquireThumbnails(undefined, "c41ColorNegative");
    });
    const acquireCall = parseCalls.find((c) => c.method === "scanner.acquireThumbnails");
    const operationId = acquireCall?.params?.operationId as string;
    act(() => {
      handle.emitEvent({
        event: "scanner.thumbnail",
        payload: { frameIndex: 5, thumbnail: { brightness: 0.5 }, operationId },
      });
    });

    // Frame-detail reachability: select exactly one frame, then inspect.
    act(() => {
      store.toggleFrameSelection(5, false);
    });
    const inspectButton = await screen.findByTestId("inspect-action");
    await user.click(inspectButton);
    expect(await screen.findByTestId("frame-detail-view")).toBeInTheDocument();

    // Return to the contact sheet, select some frames, then enter capture.
    await user.click(screen.getByTestId("frame-detail-close"));
    act(() => {
      store.selectAll();
    });
    const captureButton = await screen.findByTestId("capture-action");
    await user.click(captureButton);
    expect(await screen.findByTestId("capture-workflow-view")).toBeInTheDocument();
  });
});
