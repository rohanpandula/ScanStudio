/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../session/store/session";
import { createScriptedTransport } from "../../session/testing/harness";
import type {
  DeviceInfo,
  EngineError,
  ScanProject,
  ScannerStatus,
} from "../../session/wire/types";
import ContactSheet from "../ContactSheet";

afterEach(cleanup);

// ContactSheet imports the production `sessionStore` singleton from
// app/src/session/index.ts (Tauri invoke bridge, unusable under jsdom).
// Replace the module with a hoisted holder each test points at a fresh
// SessionStore built on a scripted transport (DeviceBar/ProjectPanel pattern).
const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../session", () => mocks);

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

const EMPTY_STATUS: ScannerStatus = {
  ...LOADED_ROLL36,
  mediaLoaded: false,
  carrier: null,
  frameCount: null,
};

const REAL_EMPTY_ARMED: ScannerStatus = {
  ...EMPTY_STATUS,
  motionArmed: true,
  filmPresent: true,
};

const SIMULATED_DEVICE: DeviceInfo = {
  deviceId: "sim-ls5000-0",
  model: "LS-5000 (simulated)",
  kind: "simulated",
  firmware: "sim-fw-1",
  connection: "virtual",
};

const REAL_DEVICE: DeviceInfo = {
  deviceId: "real-ls5000-0",
  model: "Nikon COOLSCAN V ED",
  kind: "real",
  firmware: "1.02",
  connection: "usb",
};

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-contact",
  name: "Contact Sheet Roll",
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

interface Call {
  method: string;
  params: Record<string, unknown>;
}

interface ContactFixture {
  store: SessionStore;
  emitEvent: (raw: unknown) => void;
  calls: Call[];
}

function contactFixture(options: {
  status?: ScannerStatus;
  device?: DeviceInfo;
  project?: ScanProject | null;
  onRequest?: (
    method: string,
    params: unknown,
  ) => { result?: unknown; error?: EngineError } | undefined;
} = {}): ContactFixture {
  const calls: Call[] = [];
  const handle = createScriptedTransport({
    onRequest: (method, params) => {
      calls.push({ method, params: params as Record<string, unknown> });
      const custom = options.onRequest?.(method, params);
      if (custom !== undefined) return custom;
      if (method === "scanner.status" && options.status !== undefined) {
        return { result: options.status };
      }
      if (method === "scanner.connect" && options.device !== undefined) {
        return { result: { device: options.device, status: options.status ?? EMPTY_STATUS } };
      }
      if (method === "sim.loadMedia") return { result: LOADED_ROLL36 };
      if (method === "scanner.acquireThumbnails") {
        return { result: { accepted: true, frames: [] } };
      }
      if (method === "project.create") {
        return { result: { project: options.project ?? PROJECT, directory: "/tmp/proj" } };
      }
      return { result: undefined };
    },
  });
  return {
    store: new SessionStore(handle.transport),
    emitEvent: (raw) => handle.emitEvent(raw),
    calls,
  };
}

async function loadedWithProject(): Promise<ContactFixture> {
  const fixture = contactFixture({ status: LOADED_ROLL36 });
  await fixture.store.refreshStatus();
  await fixture.store.createProject("Contact Sheet Roll", "roll36", 36, "c41ColorNegative");
  return fixture;
}

const operationIdOf = (fixture: ContactFixture): string => {
  const call = fixture.calls.find((c) => c.method === "scanner.acquireThumbnails");
  if (call === undefined) throw new Error("no acquireThumbnails call recorded");
  return call.params.operationId as string;
};

describe("ContactSheet", () => {
  it("renders sim.loadMedia carrier controls only for a connected simulator", async () => {
    const fixture = contactFixture({ device: SIMULATED_DEVICE, status: EMPTY_STATUS });
    await fixture.store.connect(SIMULATED_DEVICE.deviceId);
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);

    const controls = await screen.findByTestId("load-media-controls");
    expect(within(controls).getByRole("button", { name: "roll36" })).toBeInTheDocument();
    expect(within(controls).getByRole("button", { name: "strip6" })).toBeInTheDocument();
    expect(within(controls).getByRole("button", { name: "mounted" })).toBeInTheDocument();
    expect(screen.queryByTestId("preview-button")).toBeNull();

    await act(async () => {
      await user.click(within(controls).getByRole("button", { name: "strip6" }));
    });

    const loadCall = fixture.calls.find((c) => c.method === "sim.loadMedia");
    expect(loadCall?.params.carrier).toBe("strip6");
    // The loaded status swaps the controls for the grid and exposes the
    // pre-project preview flow. Film process is selected before the project
    // exists so the detected frame registration can be saved afterward.
    expect(await screen.findByTestId("contact-grid")).toBeInTheDocument();
    expect(screen.queryByTestId("load-media-controls")).toBeNull();
    expect(screen.getByTestId("preview-button")).toBeEnabled();
    expect(screen.getByLabelText("Film process for preview")).toHaveValue(
      "c41ColorNegative",
    );
  });

  it("consumes and surfaces a simulated-media load rejection", async () => {
    const fixture = contactFixture({
      device: SIMULATED_DEVICE,
      status: EMPTY_STATUS,
      onRequest: (method) =>
        method === "sim.loadMedia"
          ? {
              error: {
                code: "NOT_CONNECTED",
                message: "the simulator disconnected before media could load",
                recoverable: true,
              },
            }
          : undefined,
    });
    await fixture.store.connect(SIMULATED_DEVICE.deviceId);
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);

    await user.click(screen.getByRole("button", { name: "roll36" }));
    expect(await screen.findByTestId("media-load-error")).toHaveTextContent(
      "NOT_CONNECTED: the simulator disconnected before media could load",
    );
  });

  it("asks a disconnected user to connect without offering simulator carrier controls", () => {
    const fixture = contactFixture();
    mocks.sessionStore = fixture.store;

    render(<ContactSheet />);

    expect(screen.getByTestId("no-media-guidance")).toHaveTextContent(
      "Connect a scanner to preview film.",
    );
    expect(screen.queryByTestId("load-media-controls")).toBeNull();
    expect(fixture.calls.some((call) => call.method === "sim.loadMedia")).toBe(false);
  });

  it("offers the first real preview before a project exists and sends the selected process", async () => {
    const fixture = contactFixture({
      device: REAL_DEVICE,
      status: REAL_EMPTY_ARMED,
    });
    await fixture.store.connect(REAL_DEVICE.deviceId);
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();

    render(<ContactSheet />);

    expect(screen.getByTestId("no-media-guidance")).toHaveTextContent(
      "Load film in the scanner, then choose Preview to establish the current frame registration.",
    );
    expect(screen.queryByTestId("load-media-controls")).toBeNull();
    expect(screen.queryByTestId("active-project")).toBeNull();
    await user.selectOptions(
      screen.getByLabelText("Film process for preview"),
      "bwNegative",
    );
    const preview = screen.getByTestId("preview-button");
    await act(async () => {
      await user.click(preview);
    });
    const acquire = fixture.calls.find(
      (call) => call.method === "scanner.acquireThumbnails",
    );
    expect(acquire?.params.filmProcess).toBe("bwNegative");
    expect(fixture.calls.some((call) => call.method === "project.create")).toBe(false);
    expect(fixture.calls.some((call) => call.method === "sim.loadMedia")).toBe(false);
  });

  it.each([false, undefined])(
    "keeps real Preview visible but fail-closed when motionArmed is %s",
    async (motionArmed) => {
      const fixture = contactFixture({
        device: REAL_DEVICE,
        status: { ...EMPTY_STATUS, motionArmed, filmPresent: true },
      });
      await fixture.store.connect(REAL_DEVICE.deviceId);
      mocks.sessionStore = fixture.store;
      const user = userEvent.setup();

      render(<ContactSheet />);

      expect(screen.getByTestId("preview-button")).toBeVisible();
      expect(screen.getByTestId("preview-button")).toBeDisabled();
      expect(screen.getByTestId("preview-readiness-guidance")).toHaveTextContent(
        motionArmed === false
          ? /motion authorization.*owner-authorized/i
          : /motion readiness is unavailable.*check scanner status/i,
      );
      await user.click(screen.getByTestId("preview-button"));
      expect(
        fixture.calls.some((call) => call.method === "scanner.acquireThumbnails"),
      ).toBe(false);
    },
  );

  it("surfaces a typed scanner-status refresh failure from unknown motion readiness", async () => {
    const fixture = contactFixture({
      device: REAL_DEVICE,
      status: { ...EMPTY_STATUS, motionArmed: undefined, filmPresent: true },
      onRequest: (method) =>
        method === "scanner.status"
          ? {
              error: {
                code: "BRIDGE_UNAVAILABLE",
                message: "scanner bridge did not answer",
                recoverable: true,
              },
            }
          : undefined,
    });
    await fixture.store.connect(REAL_DEVICE.deviceId);
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);

    await user.click(screen.getByRole("button", { name: "Check scanner" }));
    expect(await screen.findByTestId("status-refresh-error")).toHaveTextContent(
      "BRIDGE_UNAVAILABLE: scanner bridge did not answer",
    );
  });

  it("terminates a synchronous preview rejection and renders the exact bridge message", async () => {
    const fixture = contactFixture({
      device: REAL_DEVICE,
      status: REAL_EMPTY_ARMED,
      onRequest: (method) =>
        method === "scanner.acquireThumbnails"
          ? {
              error: {
                code: "HW_MOTION_NOT_ARMED",
                message: "motion authorization is not armed for this process",
                recoverable: false,
              },
            }
          : undefined,
    });
    await fixture.store.connect(REAL_DEVICE.deviceId);
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    const unhandled = vi.fn();
    window.addEventListener("unhandledrejection", unhandled);

    render(<ContactSheet />);
    await act(async () => {
      await user.click(screen.getByTestId("preview-button"));
    });

    expect(await screen.findByTestId("preview-request-failure")).toHaveTextContent(
      "motion authorization is not armed for this process",
    );
    expect(unhandled).not.toHaveBeenCalled();
    window.removeEventListener("unhandledrejection", unhandled);
  });

  it("calls acquireThumbnails with the project's filmProcess and disables the button while a preview is active", async () => {
    const fixture = await loadedWithProject();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);

    const button = await screen.findByTestId("preview-button");
    expect(button).not.toBeDisabled();
    await act(async () => {
      await user.click(button);
    });

    const call = fixture.calls.find((c) => c.method === "scanner.acquireThumbnails");
    expect(call).toBeDefined();
    expect(call?.params.filmProcess).toBe("c41ColorNegative");
    expect("frames" in (call?.params ?? {})).toBe(false);
    expect(screen.getByTestId("preview-button")).toBeDisabled();

    // Completing the correlated preview releases the button again.
    act(() => {
      fixture.emitEvent({
        event: "scanner.thumbnailsComplete",
        payload: { count: 36, operationId: operationIdOf(fixture) },
      });
    });
    expect(screen.getByTestId("preview-button")).not.toBeDisabled();
  });

  it("renders tiles progressively, one frame at a time, as thumbnail events arrive", async () => {
    const fixture = await loadedWithProject();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);

    await act(async () => {
      await user.click(await screen.findByTestId("preview-button"));
    });
    const operationId = operationIdOf(fixture);

    // Nothing arrived yet: every one of the 36 frames is a pending tile.
    expect(screen.getAllByTestId("tile-pending")).toHaveLength(36);

    act(() => {
      fixture.emitEvent({
        event: "scanner.thumbnail",
        payload: {
          frameIndex: 1,
          thumbnail: { brightness: 0.4, tint: 20 },
          operationId,
        },
      });
    });
    expect(screen.getAllByTestId("tile-pending")).toHaveLength(35);
    expect(
      within(screen.getByTestId("contact-tile-1")).queryByTestId("tile-pending"),
    ).toBeNull();

    act(() => {
      fixture.emitEvent({
        event: "scanner.thumbnail",
        payload: {
          frameIndex: 2,
          thumbnail: { brightness: 0.6, tint: 240 },
          operationId,
        },
      });
    });
    expect(screen.getAllByTestId("tile-pending")).toHaveLength(34);
    expect(
      within(screen.getByTestId("contact-tile-2")).queryByTestId("tile-pending"),
    ).toBeNull();
    // Frame 3 is still pending after the first two arrivals.
    expect(
      within(screen.getByTestId("contact-tile-3")).getByTestId("tile-pending"),
    ).toBeInTheDocument();
  });

  it("renders exactly one tile mode per thumbnail: shaded brightness/tint or scanstudio-preview img", async () => {
    const fixture = await loadedWithProject();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);

    await act(async () => {
      await user.click(await screen.findByTestId("preview-button"));
    });
    const operationId = operationIdOf(fixture);

    act(() => {
      fixture.emitEvent({
        event: "scanner.thumbnail",
        payload: {
          frameIndex: 1,
          thumbnail: { brightness: 0.5, tint: 30 },
          operationId,
        },
      });
      fixture.emitEvent({
        event: "scanner.thumbnail",
        payload: {
          frameIndex: 2,
          thumbnail: { imagePath: "/scans/frames/frame-0002.png" },
          operationId,
        },
      });
    });

    // Brightness/tint tile: shaded placeholder, never an img decode attempt.
    const shaded = screen.getByTestId("contact-tile-1");
    expect(within(shaded).queryByRole("img")).toBeNull();
    expect(within(shaded).getByTestId("tile-shaded")).toBeInTheDocument();

    // imagePath tile: exactly the Phase 3 preview protocol URL, url-encoded.
    const imageTile = screen.getByTestId("contact-tile-2");
    const img = within(imageTile).getByRole("img") as HTMLImageElement;
    expect(img.src).toBe(
      "scanstudio-preview://localhost/?path=" + encodeURIComponent("/scans/frames/frame-0002.png"),
    );
  });

  it("centers a quarter-turned thumbnail in an axis-swapped card without letterbox geometry", async () => {
    const fixture = await loadedWithProject();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);
    await user.click(await screen.findByTestId("preview-button"));
    const operationId = operationIdOf(fixture);
    act(() => {
      fixture.emitEvent({
        event: "scanner.thumbnail",
        payload: {
          frameIndex: 2,
          thumbnail: { imagePath: "/scans/frames/frame-0002.png" },
          operationId,
        },
      });
      fixture.emitEvent({
        event: "scanner.thumbnailsComplete",
        payload: { count: 1, operationId },
      });
    });
    await user.click(screen.getByTestId("contact-tile-2"));
    await user.click(screen.getByTestId("rotate-focused-right"));

    const tile = screen.getByTestId("contact-tile-2");
    const image = screen.getByTestId("tile-image-2");
    expect(tile).toHaveStyle({ aspectRatio: "2 / 3" });
    expect(image).toHaveAttribute("data-axis-swapped", "true");
    expect(image).toHaveStyle({
      left: "50%",
      top: "50%",
      width: "150%",
      height: "66.6667%",
      transform: "translate(-50%, -50%) rotate(90deg) scaleX(1) scaleY(1)",
    });
  });

  it("toggles tiles on click, extends the range on shift+click, and drives selection via Select All/Clear", async () => {
    const fixture = await loadedWithProject();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);

    // Spy through to the real implementation so both the call args AND the
    // store state that drives the selected-tile class are observable.
    const originalToggle = fixture.store.toggleFrameSelection.bind(fixture.store);
    const toggleSpy = vi
      .spyOn(fixture.store, "toggleFrameSelection")
      .mockImplementation((frameIndex: number, extend: boolean) => originalToggle(frameIndex, extend));
    const selectAllSpy = vi.spyOn(fixture.store, "selectAll");
    const clearSpy = vi.spyOn(fixture.store, "clearSelection");

    await act(async () => {
      await user.click(await screen.findByTestId("contact-tile-3"));
    });
    expect(toggleSpy).toHaveBeenCalledWith(3, false);
    expect(fixture.store.getState().selectedFrameIndices).toEqual([3]);
    // The selected tile carries a distinct CSS class from an unselected one,
    // driven from state.selectedFrameIndices (never component-local state).
    const selectedTile = screen.getByTestId("contact-tile-3");
    const unselectedTile = screen.getByTestId("contact-tile-4");
    expect(selectedTile.className).not.toBe(unselectedTile.className);

    act(() => {
      fireEvent.click(screen.getByTestId("contact-tile-7"), { shiftKey: true });
    });
    expect(toggleSpy).toHaveBeenCalledWith(7, true);
    expect(fixture.store.getState().selectedFrameIndices).toEqual([3, 4, 5, 6, 7]);

    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Select All" }));
    });
    expect(selectAllSpy).toHaveBeenCalled();
    expect(fixture.store.getState().selectedFrameIndices).toHaveLength(36);

    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Clear" }));
    });
    expect(clearSpy).toHaveBeenCalled();
    expect(fixture.store.getState().selectedFrameIndices).toEqual([]);
  });

  it("edits one focused frame without changing scan selection and exposes an explicit batch action", async () => {
    const fixture = await loadedWithProject();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);

    await user.click(await screen.findByTestId("contact-tile-1"));
    fireEvent.click(screen.getByTestId("contact-tile-2"), { shiftKey: true });
    await user.selectOptions(screen.getByTestId("frame-transform-target"), "1");
    await user.click(screen.getByTestId("rotate-focused-right"));
    await user.click(screen.getByTestId("mirror-focused-horizontal"));

    expect(fixture.store.getState().selectedFrameIndices).toEqual([1, 2]);
    expect(fixture.store.frameDerivativeTransform(1)).toMatchObject({
      rotationDegrees: 90,
      horizontalMirror: true,
      verticalMirror: false,
    });
    expect(fixture.store.frameDerivativeTransform(2)).toMatchObject({
      rotationDegrees: 0,
      horizontalMirror: false,
      verticalMirror: false,
    });
    expect(screen.getByTestId("contact-tile-1")).toHaveStyle({ aspectRatio: "2 / 3" });

    await user.click(screen.getByText("Apply to selected (2)"));
    await user.click(screen.getByTestId("apply-selected-rotate-right"));
    expect(fixture.store.frameDerivativeTransform(1).rotationDegrees).toBe(180);
    expect(fixture.store.frameDerivativeTransform(2).rotationDegrees).toBe(90);
    expect(fixture.store.getState().selectedFrameIndices).toEqual([1, 2]);
  });

  it("targets the focused frame with shortcuts even while the whole roll stays selected", async () => {
    const fixture = await loadedWithProject();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);
    await user.click(await screen.findByTestId("contact-tile-3"));
    await user.click(screen.getByRole("button", { name: "Select All" }));

    fireEvent.keyDown(window, { key: "l", metaKey: true });
    expect(fixture.store.frameDerivativeTransform(3).rotationDegrees).toBe(270);
    expect(fixture.store.frameDerivativeTransform(4).rotationDegrees).toBe(0);
    expect(fixture.store.getState().selectedFrameIndices).toHaveLength(36);

    const input = document.createElement("input");
    document.body.append(input);
    fireEvent.keyDown(input, { key: "r", metaKey: true });
    expect(fixture.store.frameDerivativeTransform(3).rotationDegrees).toBe(270);
    input.remove();
  });

  it("renders the failed preview's message verbatim in a failure banner, never an empty success", async () => {
    const fixture = await loadedWithProject();
    mocks.sessionStore = fixture.store;
    const user = userEvent.setup();
    render(<ContactSheet />);

    await act(async () => {
      await user.click(await screen.findByTestId("preview-button"));
    });
    const operationId = operationIdOf(fixture);

    act(() => {
      fixture.emitEvent({
        event: "scanner.thumbnailsFailed",
        payload: {
          code: "BRIDGE_STREAM_STALLED",
          message: "preview stream stalled",
          operationId,
        },
      });
    });
    act(() => {
      fixture.emitEvent({
        event: "scanner.thumbnailsComplete",
        payload: { count: 0, operationId },
      });
    });

    const banner = await screen.findByTestId("preview-failure");
    expect(banner).toHaveTextContent("preview stream stalled");
    // No success-style completion marker exists alongside the failure.
    expect(screen.queryByTestId("preview-complete")).toBeNull();
  });
});
