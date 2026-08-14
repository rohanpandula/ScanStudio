import { afterEach, describe, expect, it, vi } from "vitest";
import { newOperationId, writeClipboardText } from "../webApis";

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
