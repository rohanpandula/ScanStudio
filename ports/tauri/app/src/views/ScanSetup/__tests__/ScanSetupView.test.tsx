/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SessionStore } from "../../../session/store/session";
import { createScriptedTransport } from "../../../session/testing/harness";
import type { EngineError, ScanProject } from "../../../session/wire/types";
import ScanSetupView from "../ScanSetupView";

afterEach(cleanup);

const mocks = vi.hoisted(() => ({ sessionStore: null as unknown }));
vi.mock("../../../session", () => mocks);

// ScanSetupView renders OutputRecipeForm, which imports the dialog plugin.
const dialogMocks = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: dialogMocks.open }));

const PROJECT: ScanProject = {
  schemaVersion: 4,
  id: "proj-1",
  name: "Setup Roll",
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

async function connectedStore(
  scanStartResult: { result?: unknown; error?: EngineError },
): Promise<SessionStore> {
  const handle = createScriptedTransport({
    onRequest: (method) => {
      if (method === "scan.start") {
        if (scanStartResult.error) throw scanStartResult.error;
        return scanStartResult;
      }
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
            status: {
              connected: true,
              adapter: null,
              mediaLoaded: false,
              carrier: null,
              frameCount: null,
              lamp: "off" as const,
              transport: "idle" as const,
              activeJobId: null,
            },
          },
        };
      }
      if (method === "project.create") {
        return {
          result: {
            project: PROJECT,
            directory: "/Users/test/projects/setup-roll",
          },
        };
      }
      return { result: undefined };
    },
  });
  const store = new SessionStore(handle.transport);
  await act(async () => {
    await store.connect("sim-ls5000-0");
    await store.createProject("Setup Roll", "roll36", 36, "c41ColorNegative");
  });
  mocks.sessionStore = store;
  return store;
}

describe("ScanSetupView", () => {
  beforeEach(() => {
    dialogMocks.open.mockReset();
    dialogMocks.open.mockResolvedValue(null);
  });

  it("triggers Start identically via Cmd/Ctrl+Return and the button", async () => {
    const onScanStarted = vi.fn();
    await connectedStore({ result: { jobId: "job-1" } });
    const user = userEvent.setup();
    render(<ScanSetupView selectedFrames={[1, 2, 3]} onScanStarted={onScanStarted} onRequestConnect={() => undefined} />);
    await user.keyboard("{Control>}{Enter}{/Control}");
    await waitFor(() => expect(onScanStarted).toHaveBeenCalledWith("job-1", expect.anything()));
  });

  it("renders the store's approval-required rejection verbatim with the affected frame list", async () => {
    const onScanStarted = vi.fn();
    await connectedStore({
      error: {
        code: "INVALID_PARAMS",
        message:
          "scan.start blocked: frame(s) [4, 7] require operator approval of their completed preview before scanning; approve them via roll.approve and resend the original complete frame list in one scan.start",
        recoverable: false,
      },
    });
    const user = userEvent.setup();
    render(<ScanSetupView selectedFrames={[4, 7]} onScanStarted={onScanStarted} onRequestConnect={() => undefined} />);
    await user.click(screen.getByTestId("start-scan"));
    await waitFor(() => {
      expect(screen.getByTestId("scan-start-error")).toHaveTextContent("frame(s) [4, 7] require operator approval");
      expect(screen.getByTestId("scan-start-error")).toHaveAttribute("data-code", "INVALID_PARAMS");
    });
    expect(onScanStarted).not.toHaveBeenCalled();
  });

  it("renders an INVALID_PARAMS rejection naming a field verbatim next to the form", async () => {
    const onScanStarted = vi.fn();
    await connectedStore({
      error: {
        code: "INVALID_PARAMS",
        message: "recipe.bitDepth: invalid value 12 for film process c41ColorNegative",
        recoverable: false,
      },
    });
    const user = userEvent.setup();
    render(<ScanSetupView selectedFrames={[1]} onScanStarted={onScanStarted} onRequestConnect={() => undefined} />);
    await user.click(screen.getByTestId("start-scan"));
    await waitFor(() => {
      expect(screen.getByTestId("scan-start-error")).toHaveTextContent("recipe.bitDepth: invalid value 12");
    });
    expect(onScanStarted).not.toHaveBeenCalled();
  });

  it("invokes onScanStarted with the returned jobId on success", async () => {
    const onScanStarted = vi.fn();
    await connectedStore({ result: { jobId: "job-42" } });
    const user = userEvent.setup();
    render(<ScanSetupView selectedFrames={[1, 13]} onScanStarted={onScanStarted} onRequestConnect={() => undefined} />);
    await user.click(screen.getByTestId("start-scan"));
    await waitFor(() => expect(onScanStarted).toHaveBeenCalledWith("job-42", expect.anything()));
  });

  it("disables Start when no frames are selected", async () => {
    const onScanStarted = vi.fn();
    await connectedStore({ result: { jobId: "job-1" } });
    render(<ScanSetupView selectedFrames={[]} onScanStarted={onScanStarted} onRequestConnect={() => undefined} />);
    expect(screen.getByTestId("start-scan")).toBeDisabled();
  });
});
