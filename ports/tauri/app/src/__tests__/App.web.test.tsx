/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "../App";
import { ScannerControlProvider } from "../scannerControl";
import { SessionStore } from "../session/store/session";
import { createScriptedTransport } from "../session/testing/harness";
import type { DeviceInfo, ScannerStatus } from "../session/wire/types";

const mocks = vi.hoisted(() => ({ sessionStore: null as unknown, invoke: vi.fn() }));
vi.mock("../session", () => mocks);
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("../runtime", () => ({
  isTauriRuntime: () => false,
  isWebSimulatorPreview: () => true,
}));

const SIMULATOR: DeviceInfo = {
  deviceId: "sim-ls5000-0",
  model: "LS-5000 (simulated)",
  kind: "simulated",
  firmware: "sim-fw-1",
  connection: "virtual",
};

const EMPTY_STATUS: ScannerStatus = {
  connected: true,
  adapter: null,
  mediaLoaded: false,
  carrier: null,
  frameCount: null,
  lamp: "stable",
  transport: "idle",
  activeJobId: null,
};

const LOADED_STATUS: ScannerStatus = {
  ...EMPTY_STATUS,
  mediaLoaded: true,
  carrier: "strip6",
  frameCount: 6,
};

function webFixture() {
  const calls: string[] = [];
  const handle = createScriptedTransport({
    onRequest: (method) => {
      calls.push(method);
      if (method === "scanner.list") return { result: { devices: [SIMULATOR] } };
      if (method === "scanner.connect") {
        return { result: { device: SIMULATOR, status: EMPTY_STATUS } };
      }
      if (method === "sim.loadMedia") return { result: LOADED_STATUS };
      return { result: undefined };
    },
  });
  return { store: new SessionStore(handle.transport), handle, calls };
}

afterEach(() => {
  cleanup();
  mocks.invoke.mockReset();
  vi.restoreAllMocks();
});

describe("App simulator web controls", () => {
  it("keeps observer-safe device discovery visible while disabling Connect", async () => {
    const fixture = webFixture();
    mocks.sessionStore = fixture.store;

    render(
      <ScannerControlProvider canControl={false}>
        <App />
      </ScannerControlProvider>,
    );

    expect(await screen.findByText(SIMULATOR.model)).toBeVisible();
    expect(screen.getByRole("button", { name: "Connect" })).toBeDisabled();
  });

  it("disables lease-protected simulator actions and omits unsupported routes", async () => {
    const fixture = webFixture();
    await fixture.store.connect(SIMULATOR.deviceId);
    mocks.sessionStore = fixture.store;

    render(
      <ScannerControlProvider canControl={false}>
        <App />
      </ScannerControlProvider>,
    );

    expect(await screen.findByRole("button", { name: "Disconnect" })).toBeDisabled();
    for (const carrier of ["roll36", "strip6", "mounted"]) {
      expect(screen.getByRole("button", { name: carrier })).toBeDisabled();
    }

    await act(async () => {
      await fixture.store.loadMedia("strip6");
    });
    act(() => fixture.store.toggleFrameSelection(1, false));

    expect(screen.getByTestId("preview-button")).toBeDisabled();
    expect(screen.queryByTestId("capture-action")).toBeNull();
    expect(screen.queryByTestId("inspect-action")).toBeNull();
    expect(
      fixture.calls.some((method) =>
        [
          "exiftool.detect",
          "project.previewMetadataCommand",
          "project.analyzeFrameDefects",
          "roll.approve",
          "roll.setSpacingOffset",
        ].includes(method),
      ),
    ).toBe(false);
  });

  it("does not mount Tauri-only diagnostic report actions for web errors", async () => {
    const fixture = webFixture();
    await fixture.store.connect(SIMULATOR.deviceId);
    await fixture.store.acquireThumbnails();
    const operationId = fixture.store.getState().activeOperationId;
    expect(operationId).not.toBeNull();
    fixture.handle.emitEvent({
      event: "scanner.thumbnailsFailed",
      payload: {
        code: "BRIDGE_STREAM_STALLED",
        message: "preview stream stalled",
        operationId,
      },
    });
    mocks.sessionStore = fixture.store;

    render(
      <ScannerControlProvider canControl={true}>
        <App />
      </ScannerControlProvider>,
    );

    expect(await screen.findByTestId("preview-failed-message")).toHaveTextContent(
      "preview stream stalled",
    );
    expect(screen.queryByTestId("diagnostic-report-actions")).toBeNull();
  });
});
