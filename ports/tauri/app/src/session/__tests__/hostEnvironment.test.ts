import { afterEach, describe, expect, it, vi } from "vitest";
import { describeCpuArchitecture, describeOperatingSystem, getScanStudioVersion } from "../hostEnvironment";

// hostEnvironment calls straight into @tauri-apps/api/app and
// @tauri-apps/plugin-os. Mock both so no real Tauri runtime is needed, the
// same pattern SetupChecker.test.tsx uses for @tauri-apps/api/core. Vitest
// hoists vi.mock calls above every import in this file, so the mock is in
// place before hostEnvironment.ts's own imports resolve.
const mocks = vi.hoisted(() => ({
  getVersion: vi.fn(),
  platform: vi.fn(),
  version: vi.fn(),
  arch: vi.fn(),
}));

vi.mock("@tauri-apps/api/app", () => ({ getVersion: mocks.getVersion }));
vi.mock("@tauri-apps/plugin-os", () => ({
  platform: mocks.platform,
  version: mocks.version,
  arch: mocks.arch,
}));

afterEach(() => {
  mocks.getVersion.mockReset();
  mocks.platform.mockReset();
  mocks.version.mockReset();
  mocks.arch.mockReset();
});

describe("getScanStudioVersion", () => {
  it("returns the packaged version", async () => {
    mocks.getVersion.mockResolvedValue("0.3.0");
    await expect(getScanStudioVersion()).resolves.toBe("0.3.0");
  });

  it("returns null (never a fabricated value) when the call fails", async () => {
    mocks.getVersion.mockRejectedValue(new Error("no tauri runtime"));
    await expect(getScanStudioVersion()).resolves.toBeNull();
  });

  it("returns null for an empty version string instead of an empty header field", async () => {
    mocks.getVersion.mockResolvedValue("");
    await expect(getScanStudioVersion()).resolves.toBeNull();
  });
});

describe("describeOperatingSystem", () => {
  it("combines the platform's friendly name and version", () => {
    mocks.platform.mockReturnValue("windows");
    mocks.version.mockReturnValue("10.0.22631");
    expect(describeOperatingSystem()).toBe("Windows 10.0.22631");
  });

  it("maps macos to macOS", () => {
    mocks.platform.mockReturnValue("macos");
    mocks.version.mockReturnValue("15.4.1");
    expect(describeOperatingSystem()).toBe("macOS 15.4.1");
  });

  it("maps linux to Linux", () => {
    mocks.platform.mockReturnValue("linux");
    mocks.version.mockReturnValue("6.8.0");
    expect(describeOperatingSystem()).toBe("Linux 6.8.0");
  });

  it("returns null when the plugin is unavailable, never a guess", () => {
    mocks.platform.mockImplementation(() => {
      throw new Error("plugin unavailable outside a Tauri webview");
    });
    expect(describeOperatingSystem()).toBeNull();
  });
});

describe("describeCpuArchitecture", () => {
  it("returns the plugin-resolved architecture verbatim", () => {
    mocks.arch.mockReturnValue("aarch64");
    expect(describeCpuArchitecture()).toBe("aarch64");
  });

  it("returns null when unavailable instead of sniffing a user-agent string", () => {
    mocks.arch.mockImplementation(() => {
      throw new Error("plugin unavailable outside a Tauri webview");
    });
    expect(describeCpuArchitecture()).toBeNull();
  });
});
