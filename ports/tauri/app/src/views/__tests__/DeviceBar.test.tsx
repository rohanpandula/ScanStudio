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
const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../session", () => mocks);

const SIM_DEVICE: DeviceInfo = {
  deviceId: "sim-ls5000-0",
  model: "SUPER COOLSCAN 5000 ED",
  kind: "simulated",
  firmware: "1.0.0",
  connection: "USB",
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

  it("never renders the simulated label on a real device's card", async () => {
    const realDevice: DeviceInfo = {
      deviceId: "real-ls5000-0",
      model: "Nikon LS-5000",
      kind: "real" as DeviceInfo["kind"],
      firmware: "2.4.1",
      connection: "SCSI",
    };
    mocks.sessionStore = scriptedFixture([realDevice]);
    render(<DeviceBar />);
    const card = await screen.findByTestId(`device-card-${realDevice.deviceId}`);
    expect(card).toHaveTextContent(realDevice.model);
    expect(within(card).getByText("real")).toBeInTheDocument();
    expect(within(card).queryByText(/simulated/i)).toBeNull();
  });

  it("describes real mediaLoaded as preview registration, not film presence", async () => {
    const realDevice: DeviceInfo = {
      deviceId: "real-ls5000-0",
      model: "Nikon LS-5000",
      kind: "real",
      firmware: "1.02",
      connection: "usb",
    };
    const realStatus: ScannerStatus = {
      ...CONNECTED_STATUS,
      mediaLoaded: false,
      carrier: null,
      frameCount: null,
      transport: "idle",
      filmPresent: true,
      motionArmed: false,
    };
    const store = scriptedFixture([realDevice], realStatus);
    await store.connect(realDevice.deviceId);
    mocks.sessionStore = store;

    render(<DeviceBar />);

    expect(await screen.findByText("Preview registration")).toBeInTheDocument();
    expect(screen.getByText("Not established")).toBeInTheDocument();
    expect(screen.queryByText("No media")).toBeNull();
  });
});
