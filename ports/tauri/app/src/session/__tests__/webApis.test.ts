import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { newOperationId, previewImageSrc, writeClipboardText } from "../webApis";

// Both branches must emit the same RFC 4122 v4 shape so nothing downstream
// can tell which path minted the id.
const UUID_V4_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("newOperationId", () => {
  it("uses crypto.randomUUID when the context provides it", () => {
    const id = newOperationId();
    expect(id).toMatch(UUID_V4_SHAPE);
  });

  it("mints a v4-shaped id without throwing when crypto.randomUUID is absent (insecure context)", () => {
    // http://tauri.localhost on Windows WebView2 exposes a crypto object
    // with no randomUUID; an empty object reproduces that exact shape.
    vi.stubGlobal("crypto", {});
    const first = newOperationId();
    const second = newOperationId();
    expect(first).toMatch(UUID_V4_SHAPE);
    expect(second).toMatch(UUID_V4_SHAPE);
    expect(first).not.toBe(second);
  });

  it("falls back when the API exists but throws on invocation", () => {
    // The existence check and the call are separate invariants; a runtime
    // could expose the property and still refuse the call.
    vi.stubGlobal("crypto", {
      randomUUID: () => {
        throw new TypeError("Illegal invocation");
      },
    });
    expect(newOperationId()).toMatch(UUID_V4_SHAPE);
  });
});

describe("previewImageSrc", () => {
  it("uses the raw custom-scheme URL outside the wry .localhost mapping", () => {
    expect(previewImageSrc("/tmp/tile.png", { protocol: "http:", hostname: "localhost" })).toBe(
      `scanstudio-preview://localhost/?id=${encodeURIComponent("/tmp/tile.png")}`,
    );
  });

  it("maps to the document-scheme .localhost origin on Windows (https)", () => {
    expect(
      previewImageSrc("/tmp/tile.png", { protocol: "https:", hostname: "tauri.localhost" }),
    ).toBe(`https://scanstudio-preview.localhost/?id=${encodeURIComponent("/tmp/tile.png")}`);
  });

  it("tracks an http document origin on Windows the same way", () => {
    expect(
      previewImageSrc("C:\\scans\\tile.png", { protocol: "http:", hostname: "tauri.localhost" }),
    ).toBe(`http://scanstudio-preview.localhost/?id=${encodeURIComponent("C:\\scans\\tile.png")}`);
  });
});

describe("secure-context API call sites stay centralized", () => {
  it("no production source outside webApis.ts calls crypto.randomUUID or navigator.clipboard", () => {
    // Class fix for the Windows insecure-context incident: these APIs are
    // absent there, so every use must go through the guarded helpers in
    // webApis.ts. Comment lines are ignored so prose may name the APIs.
    const root = join(__dirname, "..", "..");
    const offenders: string[] = [];
    const visit = (dir: string): void => {
      for (const entry of readdirSync(dir)) {
        const full = join(dir, entry);
        if (statSync(full).isDirectory()) {
          if (entry === "__tests__" || entry === "node_modules") continue;
          visit(full);
          continue;
        }
        if (!/\.(ts|tsx)$/.test(entry) || /\.test\.(ts|tsx)$/.test(entry)) continue;
        if (full.endsWith(join("session", "webApis.ts"))) continue;
        const lines = readFileSync(full, "utf8").split("\n");
        for (const [index, line] of lines.entries()) {
          const trimmed = line.trim();
          if (trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")) {
            continue;
          }
          if (/crypto\.randomUUID|navigator\.clipboard/.test(line)) {
            offenders.push(`${full}:${index + 1}`);
          }
        }
      }
    };
    visit(root);
    expect(offenders).toEqual([]);
  });
});

describe("writeClipboardText", () => {
  it("returns true after a successful clipboard write", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    await expect(writeClipboardText("probe text")).resolves.toBe(true);
    expect(writeText).toHaveBeenCalledWith("probe text");
  });

  it("returns false when the Clipboard API is absent (insecure context)", async () => {
    vi.stubGlobal("navigator", {});
    await expect(writeClipboardText("probe text")).resolves.toBe(false);
  });

  it("returns false when the clipboard write rejects", async () => {
    const writeText = vi.fn().mockRejectedValue(new Error("denied"));
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    await expect(writeClipboardText("probe text")).resolves.toBe(false);
  });
});
