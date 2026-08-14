/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../session/store/session";
import { createScriptedTransport } from "../../session/testing/harness";
import type { DeviceInfo, ScannerStatus } from "../../session/wire/types";
import DeviceBar from "../DeviceBar";

afterEach(cleanup);

// DeviceBar imports the production `sessionStore` singleton from
// app/src/session/index.ts, which wraps the Tauri invoke bridge and cannot
// run under jsdom. Replace the module with a hoisted holder that each test
// points at a fresh SessionStore built on a scripted transport.
const mocks = vi.hoisted(() => ({
  sessionStore: null as unknown,
  diagnosticTimeline: {
    record: vi.fn(),
    sessionId: "test-session",
    summaryLines: [] as string[],
    toJsonl: () => "",
  },
}));
vi.mock("../../session", () => mocks);

const SIM_DEVICE: DeviceInfo = {
  deviceId: "sim-ls5000-0",
  model: "SUPER COOLSCAN 5000 ED",
  kind: "simulated",
  firmware: "1.0.0",
  connection: "USB",
};

const REAL_DEVICE: DeviceInfo = {
  deviceId: "real-ls5000-0",
  model: "Nikon LS-5000",
  kind: "real",
  firmware: "1.02",
  connection: "usb",
};

const CONNECTED_STATUS: ScannerStatus = {
  connected: true,
  adapter: "sane",
  mediaLoaded: true,
  carrier: "roll36",
  frameCount: 36,
  lamp: "stable",
  transport: "busy",
  activeJobId: null,
};

function scriptedFixture(devices: DeviceInfo[], status?: ScannerStatus): SessionStore {
  const handle = createScriptedTransport({
    onRequest: (method) => {
      if (method === "scanner.list") return { result: { devices } };
      if (method === "scanner.connect" && status !== undefined) {
        return { result: { device: devices[0], status } };
      }
      return { result: undefined };
    },
  });
  return new SessionStore(handle.transport);
}

describe("DeviceBar", () => {
  it("rescan asks the engine for a fresh device list and renders what arrives (WV-2)", async () => {
    // Live Windows finding: discovery ran only at launch, so a WSL bridge
    // stack that turned healthy afterwards left the real scanner invisible
    // until a full app restart. Rescan replaces the restart.
    const handle = createScriptedTransport({
      onRequest: (method) => {
        if (method === "scanner.list") return { result: { devices: [SIM_DEVICE] } };
        if (method === "scanner.rescan") {
          return { result: { devices: [SIM_DEVICE, REAL_DEVICE] } };
        }
        return { result: undefined };
      },
    });
    mocks.sessionStore = new SessionStore(handle.transport);
    const user = userEvent.setup();
    render(<DeviceBar />);
    expect(await screen.findByText(SIM_DEVICE.model)).toBeInTheDocument();
    expect(screen.queryByText(REAL_DEVICE.model)).toBeNull();

    await act(async () => {
      await user.click(screen.getByTestId("rescan-devices"));
    });
    expect(await screen.findByText(REAL_DEVICE.model)).toBeInTheDocument();
  });

  it("rescan is disabled while a device is connected (the engine refuses it then)", async () => {
    const store = scriptedFixture([SIM_DEVICE], CONNECTED_STATUS);
    mocks.sessionStore = store;
    const user = userEvent.setup();
    render(<DeviceBar />);
    const connectButton = await screen.findByRole("button", { name: "Connect" });
    expect(screen.getByTestId("rescan-devices")).toBeEnabled();
    await act(async () => {
      await user.click(connectButton);
    });
    expect(screen.getByTestId("rescan-devices")).toBeDisabled();
  });

  it("renders the model and a badge whose text is traceable to the device's kind field", async () => {
    mocks.sessionStore = scriptedFixture([SIM_DEVICE]);
    render(<DeviceBar />);
    expect(await screen.findByText(SIM_DEVICE.model)).toBeInTheDocument();
    const badge = screen.getByText(SIM_DEVICE.kind);
    expect(badge).toBeInTheDocument();
  });

  it("calls connect with that device's deviceId when Connect is clicked", async () => {
    const store = scriptedFixture([SIM_DEVICE], CONNECTED_STATUS);
    mocks.sessionStore = store;
    const connectSpy = vi.spyOn(store, "connect");
    const user = userEvent.setup();
    render(<DeviceBar />);
    await screen.findByText(SIM_DEVICE.model);
    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Connect" }));
    });
    expect(connectSpy).toHaveBeenCalledWith(SIM_DEVICE.deviceId);
  });

  it("renders Disconnect and live ScannerStatus fields verbatim when connected", async () => {
    const store = scriptedFixture([SIM_DEVICE], CONNECTED_STATUS);
    await store.connect(SIM_DEVICE.deviceId);
    mocks.sessionStore = store;
    const disconnectSpy = vi.spyOn(store, "disconnect");
    const user = userEvent.setup();
    render(<DeviceBar />);
    await screen.findByText(SIM_DEVICE.model);
    expect(screen.getByText("Media loaded")).toBeInTheDocument();
    expect(screen.getByText("36 frames")).toBeInTheDocument();
    expect(screen.getByText("stable")).toBeInTheDocument();
    expect(screen.getByText("busy")).toBeInTheDocument();
    await act(async () => {
      await user.click(screen.getByRole("button", { name: "Disconnect" }));
    });
    expect(disconnectSpy).toHaveBeenCalled();
  });

  it("only lets the active device disconnect when multiple devices are listed", async () => {
    const store = scriptedFixture([SIM_DEVICE, REAL_DEVICE], CONNECTED_STATUS);
    await store.connect(SIM_DEVICE.deviceId);
    mocks.sessionStore = store;
    const connectSpy = vi.spyOn(store, "connect");
    const user = userEvent.setup();

    render(<DeviceBar />);

    const activeCard = await screen.findByTestId(`device-card-${SIM_DEVICE.deviceId}`);
    const inactiveCard = screen.getByTestId(`device-card-${REAL_DEVICE.deviceId}`);
    expect(within(activeCard).getByRole("button", { name: "Disconnect" })).toBeEnabled();
    expect(within(activeCard).getByText("Active")).toBeInTheDocument();
    expect(within(inactiveCard).queryByRole("button", { name: "Disconnect" })).toBeNull();
    const inactiveConnect = within(inactiveCard).getByRole("button", { name: "Connect" });
    expect(inactiveConnect).toBeDisabled();
    expect(inactiveCard).toHaveTextContent("Disconnect active device first");
    expect(screen.getAllByRole("button", { name: "Disconnect" })).toHaveLength(1);

    await user.click(inactiveConnect);
    expect(connectSpy).not.toHaveBeenCalled();
  });

  it("releases the active card when the engine reports an asynchronous disconnect", async () => {
    const handle = createScriptedTransport({
      onRequest: (method) => {
        if (method === "scanner.list") return { result: { devices: [SIM_DEVICE] } };
        if (method === "scanner.connect") {
          return { result: { device: SIM_DEVICE, status: CONNECTED_STATUS } };
        }
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.connect(SIM_DEVICE.deviceId);
    mocks.sessionStore = store;
    render(<DeviceBar />);
    expect(await screen.findByText("Active")).toBeInTheDocument();

    act(() => {
      handle.emitEvent({
        event: "scanner.status",
        payload: {
          status: {
            ...CONNECTED_STATUS,
            connected: false,
            mediaLoaded: false,
            carrier: null,
            frameCount: null,
            transport: "idle",
          },
        },
      });
    });

    expect(screen.queryByText("Active")).toBeNull();
    expect(screen.getByRole("button", { name: "Connect" })).toBeEnabled();
    expect(store.getState().connection).toMatchObject({
      connected: false,
      device: null,
    });
  });

  it("consumes and surfaces a typed connection rejection", async () => {
    const handle = createScriptedTransport({
      onRequest: (method) => {
        if (method === "scanner.list") return { result: { devices: [SIM_DEVICE] } };
        if (method === "scanner.connect") {
          return {
            error: {
              code: "ALREADY_CONNECTED",
              message: "another scanner session already owns the bridge",
              recoverable: true,
            },
          };
        }
        return { result: undefined };
      },
    });
    mocks.sessionStore = new SessionStore(handle.transport);
    const user = userEvent.setup();
    render(<DeviceBar />);

    await user.click(await screen.findByRole("button", { name: "Connect" }));
    const panel = await screen.findByTestId("hardware-error-panel");
    expect(panel).toHaveTextContent("ALREADY_CONNECTED");
    expect(panel).toHaveTextContent("another scanner session already owns the bridge");
  });

  it("normalizes a malformed connection rejection without trusting missing fields", async () => {
    const store = scriptedFixture([SIM_DEVICE]);
    vi.spyOn(store, "connect").mockRejectedValue({
      code: "BROKEN_ADAPTER",
      message: "adapter returned an incomplete error",
    });
    mocks.sessionStore = store;
    const user = userEvent.setup();
    render(<DeviceBar />);

    await user.click(await screen.findByRole("button", { name: "Connect" }));
    const panel = await screen.findByTestId("hardware-error-panel");
    expect(panel).toHaveTextContent("BROKEN_ADAPTER");
    expect(panel).toHaveTextContent("adapter returned an incomplete error");
  });

  it("never renders the simulated label on a real device's card", async () => {
    mocks.sessionStore = scriptedFixture([REAL_DEVICE]);
    render(<DeviceBar />);
    const card = await screen.findByTestId(`device-card-${REAL_DEVICE.deviceId}`);
    expect(card).toHaveTextContent(REAL_DEVICE.model);
    expect(within(card).getByText("real")).toBeInTheDocument();
    expect(within(card).queryByText(/simulated/i)).toBeNull();
  });

  it("describes real mediaLoaded as preview registration, not film presence", async () => {
    const realStatus: ScannerStatus = {
      ...CONNECTED_STATUS,
      mediaLoaded: false,
      carrier: null,
      frameCount: null,
      transport: "idle",
      filmPresent: true,
      motionArmed: false,
    };
    const store = scriptedFixture([REAL_DEVICE], realStatus);
    await store.connect(REAL_DEVICE.deviceId);
    mocks.sessionStore = store;

    render(<DeviceBar />);

    expect(await screen.findByText("Preview registration")).toBeInTheDocument();
    expect(screen.getByText("Not established")).toBeInTheDocument();
    expect(screen.queryByText("No media")).toBeNull();
  });

  it("routes an immediate motion refusal into the typed hardware panel and diagnostics", async () => {
    const readyStatus: ScannerStatus = {
      ...CONNECTED_STATUS,
      transport: "idle",
      motionArmed: true,
      filmPresent: true,
    };
    const handle = createScriptedTransport({
      onRequest: (method) => {
        if (method === "scanner.list") return { result: { devices: [REAL_DEVICE] } };
        if (method === "scanner.connect") {
          return { result: { device: REAL_DEVICE, status: readyStatus } };
        }
        if (method === "scanner.acquireThumbnails") {
          return {
            error: {
              code: "HW_MOTION_NOT_ARMED",
              message: "motion authorization expired",
              recoverable: false,
            },
          };
        }
        return { result: undefined };
      },
    });
    const store = new SessionStore(handle.transport);
    await store.connect(REAL_DEVICE.deviceId);
    await expect(store.acquireThumbnails()).rejects.toMatchObject({
      code: "HW_MOTION_NOT_ARMED",
    });
    mocks.sessionStore = store;

    render(<DeviceBar />);

    const panel = await screen.findByTestId("hardware-error-panel");
    expect(panel).toHaveAttribute("data-code", "HW_MOTION_NOT_ARMED");
    expect(panel).toHaveTextContent("motion authorization expired");
    expect(screen.getByTestId("diagnostic-report-actions")).toBeInTheDocument();
  });
});
