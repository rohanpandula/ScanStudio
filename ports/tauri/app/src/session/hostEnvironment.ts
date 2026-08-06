import { getVersion } from "@tauri-apps/api/app";
import { arch as pluginArch, platform as pluginPlatform, version as pluginVersion } from "@tauri-apps/plugin-os";

const PLATFORM_NAMES: Record<string, string> = {
  windows: "Windows",
  macos: "macOS",
  linux: "Linux",
  ios: "iOS",
  android: "Android",
  freebsd: "FreeBSD",
  dragonfly: "DragonFly BSD",
  netbsd: "NetBSD",
  openbsd: "OpenBSD",
  solaris: "Solaris",
};

/** ScanStudio's own packaged version (tauri.conf.json's "version" field,
 * read at runtime) -- the Tauri counterpart of the mac build's
 * ScanStudioRelease stamp (T-ERR-01). `null` (never a fabricated string)
 * when the plugin call fails for any reason, so the report renders its
 * honest "unknown" instead. */
export async function getScanStudioVersion(): Promise<string | null> {
  try {
    const version = await getVersion();
    return version.length === 0 ? null : version;
  } catch {
    return null;
  }
}

/** "<OS name> <OS version>", e.g. "Windows 10.0.22631" or "macOS 15.4.1".
 * Both pieces come from @tauri-apps/plugin-os, resolved at compile time --
 * deliberately not sniffed from navigator.userAgent, which is known to
 * misreport CPU family on Apple Silicon Macs (WKWebView's UA string still
 * says "Intel Mac OS X" there for web-compatibility reasons). `null` when
 * the plugin is unavailable (e.g. running outside a Tauri webview, as in
 * unit tests), never a guess. */
export function describeOperatingSystem(): string | null {
  try {
    const name = PLATFORM_NAMES[pluginPlatform()] ?? pluginPlatform();
    const osVersion = pluginVersion();
    return osVersion.length === 0 ? name : `${name} ${osVersion}`;
  } catch {
    return null;
  }
}

/** CPU architecture, e.g. "aarch64"/"x86_64" -- resolved by the OS plugin at
 * compile time, not sniffed from a user-agent string. `null` when
 * unavailable rather than a guess. */
export function describeCpuArchitecture(): string | null {
  try {
    return pluginArch();
  } catch {
    return null;
  }
}
