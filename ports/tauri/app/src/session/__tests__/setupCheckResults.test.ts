import { describe, expect, it, vi } from "vitest";
import { formatSetupCheckProbesAsText, setupCheckResults } from "../setupCheckResults";

describe("setupCheckResults", () => {
  it("starts null (never an empty array) until SetupChecker has run at least once", () => {
    // The very first assertion in the file, before any test has called
    // set() -- this is the singleton's true unstarted state, distinct from
    // "ran once and found zero probes" ([]).
    expect(setupCheckResults.get()).toBeNull();
  });

  it("notifies subscribers when results are set", () => {
    const listener = vi.fn();
    const unsubscribe = setupCheckResults.subscribe(listener);

    setupCheckResults.set([{ id: "wsl-status", status: "Ok", detail: "fine", fixCommand: null }]);

    expect(listener).toHaveBeenCalledTimes(1);
    expect(setupCheckResults.get()).toEqual([{ id: "wsl-status", status: "Ok", detail: "fine", fixCommand: null }]);
    unsubscribe();
  });

  it("stops notifying an unsubscribed listener", () => {
    const listener = vi.fn();
    const unsubscribe = setupCheckResults.subscribe(listener);
    unsubscribe();

    setupCheckResults.set([{ id: "wsl-status", status: "Ok", detail: "fine", fixCommand: null }]);

    expect(listener).not.toHaveBeenCalled();
  });
});

describe("formatSetupCheckProbesAsText", () => {
  it("renders id/status/detail and an optional fix command per line", () => {
    const text = formatSetupCheckProbesAsText([
      { id: "wsl-status", status: "Ok", detail: "WSL2 with Ubuntu-24.04 default", fixCommand: null },
      {
        id: "bridge-which",
        status: "Fail",
        detail: "scanstudio-bridge not found on PATH inside WSL",
        fixCommand: "Run install-bridge-wsl.sh inside your WSL Ubuntu-24.04 distro",
      },
    ]);

    expect(text).toBe(
      "wsl-status: Ok -- WSL2 with Ubuntu-24.04 default\n" +
        "bridge-which: Fail -- scanstudio-bridge not found on PATH inside WSL " +
        "(fix: Run install-bridge-wsl.sh inside your WSL Ubuntu-24.04 distro)",
    );
  });
});
