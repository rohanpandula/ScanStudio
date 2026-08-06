/** @vitest-environment jsdom */
import "@testing-library/jest-dom/vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setupCheckResults } from "../session/setupCheckResults";
import SetupChecker, { type MaxReadReport, type ProbeResult } from "./SetupChecker";

// SetupChecker calls invoke from @tauri-apps/api/core. Mock the module so no
// real Tauri runtime is needed; each test points invoke at controlled
// resolved/rejected/pending promises.
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), writeText: vi.fn() }));

vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));

// jsdom's Navigator.prototype defines "clipboard" as a getter that builds a
// fresh (non-mockable) stub on every access, so a plain
// `navigator.clipboard = ...` assignment silently lands on nothing.
// Redefining it as an own data property on this navigator instance shadows
// that getter for good.
Object.defineProperty(navigator, "clipboard", {
  configurable: true,
  value: { writeText: mocks.writeText },
});

afterEach(() => {
  cleanup();
  mocks.invoke.mockReset();
  mocks.writeText.mockReset();
});

const FIXTURE_PROBES: ProbeResult[] = [
  { id: "wsl-status", status: "Ok", detail: "WSL2 with Ubuntu-24.04 default", fixCommand: null },
  {
    id: "bridge-which",
    status: "Fail",
    detail: "scanstudio-bridge not found on PATH inside WSL",
    fixCommand: "Run install-bridge-wsl.sh inside your WSL Ubuntu-24.04 distro",
  },
  { id: "bridge-version", status: "Unknown", detail: "windows only", fixCommand: null },
];

const WRITE_MODE_TEXT =
  "stage-then-move (default): bridge writes to a WSL-internal staging directory; the app copies to the Windows destination and verifies sha256 before deleting the staged copy";

function resolveAll(probes: ProbeResult[], maxRead: MaxReadReport, writeMode: string): void {
  mocks.invoke.mockImplementation((cmd: string) => {
    if (cmd === "wsl_run_checks") return Promise.resolve(probes);
    if (cmd === "wsl_max_read_report") return Promise.resolve(maxRead);
    if (cmd === "wsl_write_mode_report") return Promise.resolve(writeMode);
    return Promise.reject(new Error(`unexpected command ${cmd}`));
  });
}

describe("SetupChecker", () => {
  it("renders OK/FAIL/UNKNOWN badges, the failing probe's fix command, and the honest no-data line", async () => {
    resolveAll(
      FIXTURE_PROBES,
      { maxBytes: null, entriesScanned: 0 },
      WRITE_MODE_TEXT,
    );
    render(<SetupChecker />);

    expect(await screen.findByText("OK")).toBeInTheDocument();
    expect(screen.getByText("FAIL")).toBeInTheDocument();
    expect(screen.getByText("UNKNOWN")).toBeInTheDocument();
    expect(
      screen.getByText("Run install-bridge-wsl.sh inside your WSL Ubuntu-24.04 distro"),
    ).toBeInTheDocument();
    expect(screen.getByText(WRITE_MODE_TEXT)).toBeInTheDocument();
    expect(
      screen.getByText(
        "no size data recorded in 0 scan.call entries (bridge telemetry does not yet emit a byte-size field on scan.call exit entries)",
      ),
    ).toBeInTheDocument();
  });

  it("renders the max single read line verbatim when telemetry recorded byte sizes", async () => {
    resolveAll(FIXTURE_PROBES, { maxBytes: 5242880, entriesScanned: 4 }, WRITE_MODE_TEXT);
    render(<SetupChecker />);

    expect(
      await screen.findByText(
        "max single read observed: 5242880 bytes across 4 scan.call entries",
      ),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(/no size data recorded in/),
    ).toBeNull();
  });

  it("shows a Checking placeholder while the in-flight invokes are pending", () => {
    mocks.invoke.mockImplementation(() => new Promise(() => {}));
    render(<SetupChecker />);
    expect(screen.getByText("Checking...")).toBeInTheDocument();
  });

  it("shares its results with the error-report builder as soon as they load", async () => {
    resolveAll(FIXTURE_PROBES, { maxBytes: null, entriesScanned: 0 }, WRITE_MODE_TEXT);
    render(<SetupChecker />);

    await screen.findByText("OK");

    expect(setupCheckResults.get()).toEqual(FIXTURE_PROBES);
  });

  it("copies id/status/detail/fix as plain text and briefly confirms the copy", async () => {
    resolveAll(FIXTURE_PROBES, { maxBytes: null, entriesScanned: 0 }, WRITE_MODE_TEXT);
    mocks.writeText.mockResolvedValue(undefined);
    render(<SetupChecker />);
    await screen.findByText("OK");

    // Plain fireEvent, not @testing-library/user-event: user-event's
    // setup() installs its own navigator.clipboard stub for copy/paste
    // simulation, silently shadowing the mock defined above.
    fireEvent.click(screen.getByTestId("copy-probes-as-text"));

    expect(mocks.writeText).toHaveBeenCalledWith(
      "wsl-status: Ok -- WSL2 with Ubuntu-24.04 default\n" +
        "bridge-which: Fail -- scanstudio-bridge not found on PATH inside WSL " +
        "(fix: Run install-bridge-wsl.sh inside your WSL Ubuntu-24.04 distro)\n" +
        "bridge-version: Unknown -- windows only",
    );
    await waitFor(() => expect(screen.getByTestId("copy-probes-as-text")).toHaveTextContent("Copied"));
  });
});
