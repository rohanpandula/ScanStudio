import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const EXPECTED_PROBE_IDS = [
  "wsl_status",
  "bridge_which",
  "bridge_version",
  "usbipd_attach",
  "webview2",
];

function readRequired(label: string, absPath: string): string {
  if (!existsSync(absPath)) {
    throw new Error(`Missing required file for runbook-consistency tests: ${label} at ${absPath}`);
  }
  return readFileSync(absPath, "utf8");
}

const LINUX_RUNBOOK_PATH = resolve(
  __dirname,
  "../../runbooks/LINUX-LIVE-VALIDATION.md",
);
const WINDOWS_RUNBOOK_PATH = resolve(
  __dirname,
  "../../runbooks/WINDOWS-LIVE-VALIDATION.md",
);
const SIGNOFF_PATH = resolve(__dirname, "../../runbooks/PARITY-SIGNOFF.md");
const PROBE_SCRIPT_PATH = resolve(
  __dirname,
  "../../vendor/scanstudio-bridge/scripts/probe-linux-env.py",
);
const CHECKER_PATH = resolve(__dirname, "../src-tauri/src/wsl/checker.rs");
const WSL_LANE_PATH = resolve(__dirname, "../../runbooks/WINDOWS-WSL-LANE.md");
const VERIFY_ALL_PATH = resolve(__dirname, "../../verify-all.sh");
const INSTALL_BRIDGE_PATH = resolve(
  __dirname,
  "../../packaging/windows/install-bridge-wsl.sh",
);
const WINDOWS_ASSEMBLER_PATH = resolve(
  __dirname,
  "../../packaging/windows/assemble-staging.sh",
);
const LINUX_ASSEMBLER_PATH = resolve(
  __dirname,
  "../../packaging/linux/assemble-staging.sh",
);
const LINUX_VERIFIER_PATH = resolve(
  __dirname,
  "../../packaging/linux/verify-bundle.sh",
);
const MACOS_PACKAGER_PATH = resolve(
  __dirname,
  "../../packaging/macos/build-and-smoke.sh",
);

const runbookText = readRequired("WINDOWS-WSL-LANE.md", WSL_LANE_PATH);
const checkerText = readRequired("checker.rs", CHECKER_PATH);
const linuxRunbookText = readRequired("LINUX-LIVE-VALIDATION.md", LINUX_RUNBOOK_PATH);
const windowsRunbookText = readRequired(
  "WINDOWS-LIVE-VALIDATION.md",
  WINDOWS_RUNBOOK_PATH,
);
const signoffText = readRequired("PARITY-SIGNOFF.md", SIGNOFF_PATH);
const probeScriptText = readRequired("probe-linux-env.py", PROBE_SCRIPT_PATH);
const installBridgeText = readRequired("install-bridge-wsl.sh", INSTALL_BRIDGE_PATH);
const windowsAssemblerText = readRequired(
  "windows/assemble-staging.sh",
  WINDOWS_ASSEMBLER_PATH,
);
const linuxAssemblerText = readRequired(
  "linux/assemble-staging.sh",
  LINUX_ASSEMBLER_PATH,
);
const linuxVerifierText = readRequired("linux/verify-bundle.sh", LINUX_VERIFIER_PATH);
const macosPackagerText = readRequired("macos/build-and-smoke.sh", MACOS_PACKAGER_PATH);

const STOP_BANNER = "## STOP — LIVE HARDWARE STEPS BELOW";

const FORBIDDEN_AUTOMATION_PHRASES = [
  "the executor runs",
  "the executor executes",
  "an automated runner performs",
  "an automated runner executes",
];

describe("runbook/checker probe-id consistency", () => {
  it("checker.rs defines every expected probe id as a double-quoted Rust string literal", () => {
    for (const id of EXPECTED_PROBE_IDS) {
      expect(checkerText.includes(`"${id}"`)).toBe(true);
    }
  });

  it("runbook mentions every expected probe id", () => {
    for (const id of EXPECTED_PROBE_IDS) {
      expect(runbookText.includes(id)).toBe(true);
    }
  });

  it("runbook names install-bridge-wsl.sh by filename", () => {
    expect(runbookText.includes("install-bridge-wsl.sh")).toBe(true);
  });

  it("runbook contains the STOP hardware-deferral banner", () => {
    expect(runbookText.includes("STOP")).toBe(true);
  });

  it("every bridge probe targets the same pinned Ubuntu-24.04 distro as the runtime", () => {
    expect(checkerText.includes("use super::bridge_cmd::WSL_DISTRO;")).toBe(true);
    expect(
      checkerText.includes('["-d", WSL_DISTRO, "-e", "which", entrypoint]'),
    ).toBe(true);
    expect(
      checkerText.includes('["-d", WSL_DISTRO, "-e", "sh", "-c", &sh_cmd]'),
    ).toBe(true);
    expect(checkerText.includes('executor.run("wsl.exe", &["-e"')).toBe(false);
    expect(runbookText.includes("pinned Ubuntu-24.04 distro")).toBe(true);
  });
});

describe("cross-platform packaging invariants", () => {
  it("Windows WSL install provisions the exact private Python and never resolves local projects remotely", () => {
    expect(installBridgeText.includes('CPYTHON_SHA256="6734c3e643c75e')).toBe(true);
    expect(installBridgeText.includes("--bundle-dir")).toBe(true);
    expect(installBridgeText.includes("--no-index")).toBe(true);
    expect(installBridgeText.includes("--no-deps")).toBe(true);
    expect(installBridgeText.includes("--require-hashes")).toBe(true);
    expect(installBridgeText.indexOf("Installing CoolscanPy from shipped")).toBeLessThan(
      installBridgeText.indexOf("Installing scanstudio-bridge from shipped"),
    );
  });

  it("Windows staging ships Python, an offline wheelhouse, and offline documentation", () => {
    for (const requiredText of [
      "CPYTHON_ARCHIVE",
      "Wheelhouse",
      "wsl-requirements.txt",
      "Documentation/README-WINDOWS.md",
      "Documentation/WINDOWS-WSL-LANE.md",
    ]) {
      expect(windowsAssemblerText.includes(requiredText), requiredText).toBe(true);
    }
  });

  it("Windows runbook uses the installer's real command-line interface", () => {
    expect(
      runbookText.includes(
        "bash /path/to/install-bridge-wsl.sh --bundle-dir /path/to/bundle-root",
      ),
    ).toBe(true);
  });

  it("strict Linux packaging builds and verifies python-sane's native CPython 3.13 module", () => {
    expect(linuxAssemblerText.includes("python_sane-2.9.2-cp313-*.whl")).toBe(true);
    expect(linuxAssemblerText.includes("libsane-dev")).toBe(true);
    expect(linuxVerifierText.includes("_sane*.so")).toBe(true);
    expect(linuxVerifierText.includes("import sane, coolscanpy, scanstudio_bridge")).toBe(true);
  });

  it("macOS asks Tauri to sign before DMG creation and verifies the mounted app", () => {
    const signingOffset = macosPackagerText.indexOf('"signingIdentity":"-"');
    const buildOffset = macosPackagerText.indexOf("npm run tauri -- build --bundles dmg");
    const mountOffset = macosPackagerText.indexOf("hdiutil attach -readonly");
    const mountedVerifyOffset = macosPackagerText.indexOf(
      'codesign --verify --deep --strict "$mounted_app"',
    );
    expect(signingOffset).toBeGreaterThanOrEqual(0);
    expect(buildOffset).toBeGreaterThan(signingOffset);
    expect(mountOffset).toBeGreaterThan(buildOffset);
    expect(mountedVerifyOffset).toBeGreaterThan(mountOffset);
  });
});

describe("HW-01/HW-02 STOP banner presence", () => {
  it.each([
    ["LINUX-LIVE-VALIDATION.md", linuxRunbookText],
    ["WINDOWS-LIVE-VALIDATION.md", windowsRunbookText],
  ])("%s contains the STOP banner heading exactly once", (name, text) => {
    expect(
      text.split(STOP_BANNER).length - 1,
      `${name} must contain the STOP banner "${STOP_BANNER}" exactly once`,
    ).toBe(1);
  });
});

describe("HW-01/HW-02 automated-execution language absence", () => {
  it.each([
    ["LINUX-LIVE-VALIDATION.md", linuxRunbookText],
    ["WINDOWS-LIVE-VALIDATION.md", windowsRunbookText],
  ])("%s contains none of the forbidden automation phrases", (name, text) => {
    for (const phrase of FORBIDDEN_AUTOMATION_PHRASES) {
      expect(
        text.includes(phrase),
        `${name} must not contain the forbidden phrase "${phrase}"`,
      ).toBe(false);
    }
  });
});

function extractLinuxProbeNames(scriptText: string): string[] {
  const ids: string[] = [];
  const re = /\bname = "([a-z0-9-]+)"/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(scriptText)) !== null) {
    ids.push(m[1]);
  }
  return [...new Set(ids)];
}

function extractLinuxRunbookSectionBNumberedIds(runbookText: string): string[] {
  const start = runbookText.indexOf("## [b] Environment Probe");
  const end = runbookText.indexOf("## [c] Install the Linux Bundle");
  if (start === -1 || end === -1) {
    throw new Error(
      "LINUX-LIVE-VALIDATION.md is missing its [b] or [c] section markers; cannot extract probe-id references",
    );
  }
  const section = runbookText.slice(start, end);
  const ids: string[] = [];
  const re = /^\s*\d+\. `([a-z0-9-]+)`/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(section)) !== null) {
    ids.push(m[1]);
  }
  return ids;
}

describe("HW-01 Linux probe-id bidirectional consistency", () => {
  const scriptIds = extractLinuxProbeNames(probeScriptText).sort();
  const runbookBNumberedIds = extractLinuxRunbookSectionBNumberedIds(
    linuxRunbookText,
  ).sort();

  it("every probe identifier defined in probe-linux-env.py appears in LINUX-LIVE-VALIDATION.md", () => {
    for (const id of scriptIds) {
      expect(
        linuxRunbookText.includes(id),
        `probe-linux-env.py defines probe id "${id}" which appears nowhere in LINUX-LIVE-VALIDATION.md`,
      ).toBe(true);
    }
  });

  it("every probe-id-shaped reference in the [b] numbered sub-steps resolves to a probe the script actually defines", () => {
    for (const id of runbookBNumberedIds) {
      expect(
        scriptIds.includes(id),
        `LINUX-LIVE-VALIDATION.md [b] section references probe id "${id}" which probe-linux-env.py does not define`,
      ).toBe(true);
    }
  });

  it("the [b] numbered sub-steps and the script's probe names match in both directions", () => {
    const missingFromRunbook = scriptIds.filter((id) => !runbookBNumberedIds.includes(id));
    const missingFromScript = runbookBNumberedIds.filter((id) => !scriptIds.includes(id));
    expect(
      missingFromRunbook,
      `probe ids missing from LINUX-LIVE-VALIDATION.md's [b] section: ${missingFromRunbook.join(", ")}`,
    ).toEqual([]);
    expect(
      missingFromScript,
      `[b] sub-step ids not defined in probe-linux-env.py: ${missingFromScript.join(", ")}`,
    ).toEqual([]);
  });
});

function extractCheckerIds(checkerText: string): {
  hyphenated: string[];
  underscored: string[];
  all: string[];
} {
  const hyphenated: string[] = [];
  const re = /id: "([a-z0-9-]+)"/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(checkerText)) !== null) {
    hyphenated.push(m[1]);
  }
  const constStart = checkerText.indexOf("pub const PROBE_IDS");
  const constEnd = checkerText.indexOf("];", constStart);
  const constBlock = checkerText.slice(constStart, constEnd);
  const underscored: string[] = [];
  const re2 = /"([a-z0-9_]+)"/g;
  while ((m = re2.exec(constBlock)) !== null) {
    underscored.push(m[1]);
  }
  return {
    hyphenated: [...new Set(hyphenated)],
    underscored: [...new Set(underscored)],
    all: [...new Set([...hyphenated, ...underscored])],
  };
}

function extractWindowsRunbookPreFlightIds(windowsRunbookText: string): string[] {
  const start = windowsRunbookText.indexOf("### Checker pre-flight");
  const end = windowsRunbookText.indexOf("## Scheduling and Safety Preconditions");
  if (start === -1 || end === -1) {
    throw new Error(
      "WINDOWS-LIVE-VALIDATION.md is missing its checker pre-flight or Scheduling section markers; cannot extract checker-id references",
    );
  }
  const section = windowsRunbookText.slice(start, end);
  const ids: string[] = [];
  const re = /`([a-z][a-z0-9_-]+)`/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(section)) !== null) {
    ids.push(m[1]);
  }
  return ids;
}

describe("HW-02 Windows checker-id bidirectional consistency", () => {
  const checkerIds = extractCheckerIds(checkerText);
  const runbookPreFlightIds = extractWindowsRunbookPreFlightIds(
    windowsRunbookText,
  );

  it("every probe identifier defined in checker.rs (hyphenated and underscore) appears in WINDOWS-LIVE-VALIDATION.md", () => {
    for (const id of checkerIds.all) {
      expect(
        windowsRunbookText.includes(id),
        `checker.rs defines probe id "${id}" which appears nowhere in WINDOWS-LIVE-VALIDATION.md`,
      ).toBe(true);
    }
  });

  it("every probe-id-shaped reference in the checker pre-flight section resolves to an id checker.rs defines", () => {
    for (const id of runbookPreFlightIds) {
      expect(
        checkerIds.all.includes(id),
        `WINDOWS-LIVE-VALIDATION.md pre-flight references probe id "${id}" which checker.rs does not define`,
      ).toBe(true);
    }
    expect(
      runbookPreFlightIds.length,
      `WINDOWS-LIVE-VALIDATION.md checker pre-flight must name the probe ids it references`,
    ).toBeGreaterThan(0);
  });
});

describe("HW-01/HW-02 referenced tool-path existence", () => {
  const paths: Array<[string, string]> = [
    ["probe-linux-env.py", PROBE_SCRIPT_PATH],
    ["checker.rs", CHECKER_PATH],
    ["WINDOWS-WSL-LANE.md", WSL_LANE_PATH],
    ["verify-all.sh", VERIFY_ALL_PATH],
    ["install-bridge-wsl.sh", INSTALL_BRIDGE_PATH],
    ["windows/assemble-staging.sh", WINDOWS_ASSEMBLER_PATH],
    ["linux/assemble-staging.sh", LINUX_ASSEMBLER_PATH],
    ["linux/verify-bundle.sh", LINUX_VERIFIER_PATH],
    ["macos/build-and-smoke.sh", MACOS_PACKAGER_PATH],
  ];

  it.each(paths)("%s resolves to an existing file", (name, absPath) => {
    expect(existsSync(absPath), `referenced tool path is missing: ${name} at ${absPath}`).toBe(
      true,
    );
  });
});

describe("HW-03 parity sign-off references", () => {
  it("PARITY-SIGNOFF.md references app/PARITY-NOTES.md and verify-all.sh", () => {
    expect(
      signoffText.includes("PARITY-NOTES.md"),
      "runbooks/PARITY-SIGNOFF.md must reference app/PARITY-NOTES.md",
    ).toBe(true);
    expect(
      signoffText.includes("verify-all.sh"),
      "runbooks/PARITY-SIGNOFF.md must reference verify-all.sh",
    ).toBe(true);
  });

  it("the files PARITY-SIGNOFF.md references both exist", () => {
    const parityNotesRef = resolve(__dirname, "../PARITY-NOTES.md");
    expect(
      existsSync(parityNotesRef),
      `PARITY-SIGNOFF.md references app/PARITY-NOTES.md but the file is missing at ${parityNotesRef}`,
    ).toBe(true);
    expect(
      existsSync(VERIFY_ALL_PATH),
      `PARITY-SIGNOFF.md references verify-all.sh but the file is missing at ${VERIFY_ALL_PATH}`,
    ).toBe(true);
  });
});
