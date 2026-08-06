import { describe, expect, it } from "vitest";
import {
  buildDiagnosticBundleEntries,
  resolveDiagnosticBundleRaster,
} from "../diagnosticBundle";

const decode = (data: Uint8Array): string => new TextDecoder().decode(data);

describe("buildDiagnosticBundleEntries", () => {
  it("includes the diagnostics log, report text, and raster when one is available", () => {
    const entries = buildDiagnosticBundleEntries({
      diagnosticsJsonl: '{"event":"session.started"}',
      reportText: "ScanStudio error report\nError code: NOT_CONNECTED",
      previewRaster: { filename: "preview.png", data: new Uint8Array([0x89, 0x50, 0x4e, 0x47]) },
    });

    expect(entries.map((entry) => entry.name).sort()).toEqual([
      "diagnostics.jsonl",
      "manifest.txt",
      "preview.png",
      "report.txt",
    ]);

    const manifest = entries.find((entry) => entry.name === "manifest.txt")!;
    expect(decode(manifest.data)).toContain("preview.png: the roll preview raster");
    expect(decode(manifest.data)).not.toContain("not available");

    const raster = entries.find((entry) => entry.name === "preview.png")!;
    expect(Array.from(raster.data)).toEqual([0x89, 0x50, 0x4e, 0x47]);
  });

  it("records the specific unavailability reason instead of silently dropping the raster", () => {
    const entries = buildDiagnosticBundleEntries({
      diagnosticsJsonl: "",
      reportText: "ScanStudio error report",
      previewRaster: null,
      unavailableRasterReason: "the roll preview image file is missing or unreadable",
    });

    expect(entries.map((entry) => entry.name).sort()).toEqual(["diagnostics.jsonl", "manifest.txt", "report.txt"]);
    const manifest = entries.find((entry) => entry.name === "manifest.txt")!;
    expect(decode(manifest.data)).toContain(
      "raster: not available in this build (the roll preview image file is missing or unreadable)",
    );
  });

  it("falls back to a generic reason when none is supplied", () => {
    const entries = buildDiagnosticBundleEntries({
      diagnosticsJsonl: "",
      reportText: "report",
      previewRaster: null,
    });
    const manifest = entries.find((entry) => entry.name === "manifest.txt")!;
    expect(decode(manifest.data)).toContain("raster: not available in this build (no roll preview in this session)");
  });
});

describe("resolveDiagnosticBundleRaster", () => {
  it("honestly reports an empty session never had a roll preview", async () => {
    const result = await resolveDiagnosticBundleRaster({}, () => new Uint8Array());
    expect(result).toEqual({ raster: null, unavailableReason: "no roll preview in this session" });
  });

  it("reports a thumbnail with no image path rather than silently skipping it", async () => {
    const result = await resolveDiagnosticBundleRaster({ 1: { imagePath: undefined } }, () => new Uint8Array());
    expect(result).toEqual({
      raster: null,
      unavailableReason: "the roll preview has no locally-known image path",
    });
  });

  it("reports a fake-filesystem miss as missing rather than silently skipping it", async () => {
    const result = await resolveDiagnosticBundleRaster({ 1: { imagePath: "/fake/frame1.tif" } }, () => null);
    expect(result).toEqual({
      raster: null,
      unavailableReason: "the roll preview image file is missing or unreadable",
    });
  });

  it("resolves the lowest-indexed frame's image against a fake filesystem, naming it by extension", async () => {
    const fakeFilesystem: Record<string, Uint8Array> = {
      "/fake/frame3.tif": new TextEncoder().encode("wrong frame"),
      "/fake/frame1.tif": new TextEncoder().encode("roll preview bytes"),
    };
    const thumbnails = {
      3: { imagePath: "/fake/frame3.tif" },
      1: { imagePath: "/fake/frame1.tif" },
    };

    const result = await resolveDiagnosticBundleRaster(thumbnails, (path) => fakeFilesystem[path] ?? null);

    expect(result.unavailableReason).toBeNull();
    expect(result.raster?.filename).toBe("preview.tif");
    expect(result.raster && decode(result.raster.data)).toBe("roll preview bytes");
  });

  it("names a raster with no file extension just 'preview'", async () => {
    const fakeFilesystem: Record<string, Uint8Array> = { "/fake/frame1": new Uint8Array([1, 2, 3]) };
    const result = await resolveDiagnosticBundleRaster(
      { 1: { imagePath: "/fake/frame1" } },
      (path) => fakeFilesystem[path] ?? null,
    );
    expect(result.raster?.filename).toBe("preview");
  });

  it("supports an async readFile, since the real implementation reads through a Tauri command", async () => {
    const result = await resolveDiagnosticBundleRaster(
      { 1: { imagePath: "/fake/frame1.tif" } },
      async (path) => {
        await Promise.resolve();
        return path === "/fake/frame1.tif" ? new Uint8Array([7, 8, 9]) : null;
      },
    );
    expect(result.raster && Array.from(result.raster.data)).toEqual([7, 8, 9]);
  });
});
