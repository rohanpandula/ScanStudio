/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DiagnosticTimeline } from "../../session/diagnosticTimeline";
import { setupCheckResults } from "../../session/setupCheckResults";
import type { DeviceInfo, EngineError, ScannerStatus } from "../../session/wire/types";
import DiagnosticReportActions from "../DiagnosticReportActions";

// DiagnosticReportActions imports the production `diagnosticTimeline`
// singleton from app/src/session/index.ts (which wraps the Tauri invoke
// bridge indirectly through sessionStore's sibling exports) plus the
// Tauri-facing dialog/bundle-IO/host-environment modules. Each is replaced
// with a hoisted, live-mutable holder so a test can point it at whatever it
// needs -- returning the holder object itself (not a new literal wrapping
// it) is what makes later mutations (e.g. in afterEach) visible to the
// mocked module's consumers; this mirrors DeviceBar.test.tsx's proven
// `vi.mock("../../session", () => mocks)` pattern.
const sessionMocks = vi.hoisted(() => ({ diagnosticTimeline: null as unknown }));
vi.mock("../../session", () => sessionMocks);

const dialogMocks = vi.hoisted(() => ({ save: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => dialogMocks);

const bundleIOMocks = vi.hoisted(() => ({
  readPreviewRasterBytes: vi.fn(),
  writeDiagnosticBundleFile: vi.fn(),
}));
vi.mock("../../session/diagnosticBundleIO", () => bundleIOMocks);

const hostEnvironmentMocks = vi.hoisted(() => ({
  getScanStudioVersion: vi.fn(),
  describeOperatingSystem: vi.fn(),
  describeCpuArchitecture: vi.fn(),
}));
vi.mock("../../session/hostEnvironment", () => hostEnvironmentMocks);

const clipboardMocks = vi.hoisted(() => ({ writeText: vi.fn() }));
// jsdom's Navigator.prototype defines "clipboard" as a getter that builds a
// fresh (non-mockable) stub on every access; redefine it as an own data
// property to shadow that getter (see SetupChecker.test.tsx for the same
// fix, and why plain fireEvent is used below instead of user-event --
// user-event's setup() installs its own clipboard stub).
Object.defineProperty(navigator, "clipboard", {
  configurable: true,
  value: { writeText: clipboardMocks.writeText },
});

const REAL_DEVICE: DeviceInfo = {
  deviceId: "real-ls5000-0",
  model: "Nikon LS-5000",
  kind: "real",
  firmware: "1.02",
  connection: "usb",
};

const REAL_STATUS: ScannerStatus = {
  connected: true,
  adapter: "SA-21",
  mediaLoaded: true,
  carrier: "roll36",
  frameCount: 36,
  lamp: "stable",
  transport: "idle",
  activeJobId: null,
};

const NOT_CONNECTED_ERROR: EngineError = {
  code: "NOT_CONNECTED",
  message: "NOT_CONNECTED: no device is open",
  recoverable: true,
};

function baseProps() {
  return {
    error: null as EngineError | null,
    thumbnailsFailed: null as { code: string; message: string } | null,
    device: null as DeviceInfo | null,
    status: null as ScannerStatus | null,
    thumbnails: {},
  };
}

beforeEach(() => {
  dialogMocks.save.mockReset();
  bundleIOMocks.readPreviewRasterBytes.mockReset();
  bundleIOMocks.writeDiagnosticBundleFile.mockReset();
  clipboardMocks.writeText.mockReset();
  hostEnvironmentMocks.getScanStudioVersion.mockReset();
  hostEnvironmentMocks.describeOperatingSystem.mockReset();
  hostEnvironmentMocks.describeCpuArchitecture.mockReset();
  hostEnvironmentMocks.getScanStudioVersion.mockResolvedValue("0.3.0-alpha.11");
  hostEnvironmentMocks.describeOperatingSystem.mockReturnValue("Windows 10.0.22631");
  hostEnvironmentMocks.describeCpuArchitecture.mockReturnValue("x86_64");
  clipboardMocks.writeText.mockResolvedValue(undefined);
  sessionMocks.diagnosticTimeline = new DiagnosticTimeline("test-session", 40);
  // setupCheckResults is a real, unmocked module-level singleton (error
  // report v2, item 5) shared across every test in this file -- reset it so
  // one test's probes never leak into the next.
  setupCheckResults.set([]);
});

afterEach(cleanup);

describe("DiagnosticReportActions", () => {
  it("renders nothing while there is no active error", () => {
    render(<DiagnosticReportActions {...baseProps()} />);
    expect(screen.queryByTestId("diagnostic-report-actions")).toBeNull();
  });

  it("renders once a typed error is active", () => {
    render(<DiagnosticReportActions {...baseProps()} error={NOT_CONNECTED_ERROR} />);
    expect(screen.getByTestId("diagnostic-report-actions")).toBeInTheDocument();
  });

  it("prefers thumbnailsFailed over a typed request rejection, matching HardwareErrorPanel's precedence", async () => {
    render(
      <DiagnosticReportActions
        {...baseProps()}
        error={NOT_CONNECTED_ERROR}
        thumbnailsFailed={{ code: "INTERNAL", message: "preview decode failed" }}
      />,
    );
    fireEvent.click(screen.getByTestId("copy-report"));
    await waitFor(() => expect(clipboardMocks.writeText).toHaveBeenCalled());
    const text = clipboardMocks.writeText.mock.calls[0][0] as string;
    expect(text).toContain("Error code: INTERNAL");
    expect(text).not.toContain("Error code: NOT_CONNECTED");
  });

  it("records exactly one diagnostic event with the error code when an error first appears", () => {
    const timeline = new DiagnosticTimeline("test-session", 40);
    sessionMocks.diagnosticTimeline = timeline;
    render(<DiagnosticReportActions {...baseProps()} error={NOT_CONNECTED_ERROR} />);

    expect(timeline.entries).toHaveLength(1);
    expect(timeline.entries[0].event).toBe("error.surfaced");
    expect(timeline.entries[0].fields).toEqual({ code: "NOT_CONNECTED" });
  });

  it("copies a report with the build header, scanner identity, and diagnostic events", async () => {
    const timeline = new DiagnosticTimeline("test-session", 40);
    timeline.record("device.connect.succeeded", { connected: true, kind: "real" }, "2026-08-05T00:00:00Z");
    sessionMocks.diagnosticTimeline = timeline;

    render(
      <DiagnosticReportActions
        {...baseProps()}
        error={NOT_CONNECTED_ERROR}
        device={REAL_DEVICE}
        status={REAL_STATUS}
      />,
    );

    fireEvent.click(screen.getByTestId("copy-report"));
    await waitFor(() => expect(clipboardMocks.writeText).toHaveBeenCalled());
    const text = clipboardMocks.writeText.mock.calls[0][0] as string;

    expect(text.startsWith("ScanStudio error report\n")).toBe(true);
    expect(text).toContain("ScanStudio version: 0.3.0-alpha.11");
    expect(text).toContain("Operating system: Windows 10.0.22631");
    expect(text).toContain("CPU architecture: x86_64");
    expect(text).toContain("Scanner firmware: 1.02");
    expect(text).toContain("Adapter: SA-21");
    expect(text).toContain("Holder: roll36");
    expect(text).toContain("Diagnostic session: test-session");
    expect(text).toContain("Error code: NOT_CONNECTED");
    expect(text).toContain("2026-08-05T00:00:00Z device.connect.succeeded connected=true kind=real");
    await waitFor(() => expect(screen.getByTestId("copy-report")).toHaveTextContent("Copied"));
  });

  it("appends the Windows setup check section while this session's probe results exist", async () => {
    setupCheckResults.set([
      { id: "wsl-status", status: "Ok", detail: "WSL2 with Ubuntu-24.04 default", fixCommand: null },
    ]);

    render(<DiagnosticReportActions {...baseProps()} error={NOT_CONNECTED_ERROR} />);
    fireEvent.click(screen.getByTestId("copy-report"));
    await waitFor(() => expect(clipboardMocks.writeText).toHaveBeenCalled());

    const text = clipboardMocks.writeText.mock.calls[0][0] as string;
    expect(text).toContain("Windows setup check:");
    expect(text).toContain("- wsl-status: Ok -- WSL2 with Ubuntu-24.04 default");
  });

  it("saves a diagnostic bundle zip to the chosen path and skips writing when the dialog is cancelled", async () => {
    bundleIOMocks.readPreviewRasterBytes.mockResolvedValue(null);
    dialogMocks.save.mockResolvedValueOnce(null);
    render(<DiagnosticReportActions {...baseProps()} error={NOT_CONNECTED_ERROR} />);

    fireEvent.click(screen.getByTestId("save-diagnostic-bundle"));
    await waitFor(() => expect(dialogMocks.save).toHaveBeenCalled());
    expect(bundleIOMocks.writeDiagnosticBundleFile).not.toHaveBeenCalled();

    dialogMocks.save.mockResolvedValueOnce("/chosen/ScanStudio-Diagnostics.zip");
    fireEvent.click(screen.getByTestId("save-diagnostic-bundle"));
    await waitFor(() => expect(bundleIOMocks.writeDiagnosticBundleFile).toHaveBeenCalledTimes(1));

    const [path, bytes] = bundleIOMocks.writeDiagnosticBundleFile.mock.calls[0] as [string, Uint8Array];
    expect(path).toBe("/chosen/ScanStudio-Diagnostics.zip");
    // A stored-zip local file header signature ("PK\x03\x04") -- proves a
    // real archive was assembled and handed to the writer, not empty bytes.
    expect(Array.from(bytes.slice(0, 4))).toEqual([0x50, 0x4b, 0x03, 0x04]);
    await waitFor(() => expect(screen.getByTestId("save-diagnostic-bundle")).toHaveTextContent("Saved"));
  });
});
