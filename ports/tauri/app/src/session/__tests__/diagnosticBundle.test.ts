import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  buildDiagnosticBundleEntries,
  buildDiagnosticBundleZip,
  resolveDiagnosticBundleRaster,
} from "../diagnosticBundle";
import type { DiagnosticEvidence } from "../diagnosticEvidence";

const decode = (data: Uint8Array): string => new TextDecoder().decode(data);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const TIFF = new Uint8Array([0x49, 0x49, 0x2a, 0x00, 1, 2, 3]);

interface SharedPrivacyFixture {
  username: string;
  absolutePaths: string[];
  projectName: string;
  filmMetadata: string[];
  deviceIdentifier: string;
  rasterMarker: string;
}

const SHARED_PRIVACY_FIXTURE = JSON.parse(
  readFileSync(
    new URL(
      "../../../../../../app/ScanStudio/Tests/ScanStudioKitTests/Fixtures/diagnostic-share-safety.json",
      import.meta.url,
    ),
    "utf8",
  ),
) as SharedPrivacyFixture;

describe("buildDiagnosticBundleEntries", () => {
  it("excludes film imagery by default even when preview bytes were supplied", () => {
    const entries = buildDiagnosticBundleEntries({
      diagnosticsJsonl: '{"event":"session.started"}',
      reportText: "ScanStudio error report\nError code: NOT_CONNECTED",
      previewRaster: { filename: "preview.png", data: PNG },
    });

    expect(entries.map((entry) => entry.name).sort()).toEqual(["diagnostics.jsonl", "manifest.txt", "report.txt"]);

    const manifest = entries.find((entry) => entry.name === "manifest.txt")!;
    expect(decode(manifest.data)).toContain("film preview: excluded by privacy default");
    expect(entries.find((entry) => entry.name === "preview.png")).toBeUndefined();
  });

  it("includes exactly the disclosed frame tile after explicit one-export consent", () => {
    const entries = buildDiagnosticBundleEntries({
      diagnosticsJsonl: '{"event":"session.started"}',
      reportText: "ScanStudio error report\nError code: NOT_CONNECTED",
      previewRaster: { filename: "preview.png", data: PNG },
      previewFrameIndex: 3,
      includePreview: true,
    });

    expect(entries.map((entry) => entry.name).sort()).toEqual([
      "diagnostics.jsonl",
      "manifest.txt",
      "preview.png",
      "report.txt",
    ]);
    expect(decode(entries.find((entry) => entry.name === "manifest.txt")!.data)).toContain(
      "preview.png: film-content preview for frame 3, included by explicit one-export consent",
    );
    expect(Array.from(entries.find((entry) => entry.name === "preview.png")!.data)).toEqual([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ]);
  });

  it("records the specific unavailability reason instead of silently dropping the raster", () => {
    const entries = buildDiagnosticBundleEntries({
      diagnosticsJsonl: "",
      reportText: "ScanStudio error report",
      previewRaster: null,
      unavailableRasterReason: "the roll preview image file is missing or unreadable",
      includePreview: true,
    });

    expect(entries.map((entry) => entry.name).sort()).toEqual(["diagnostics.jsonl", "manifest.txt", "report.txt"]);
    const manifest = entries.find((entry) => entry.name === "manifest.txt")!;
    expect(decode(manifest.data)).toContain(
      "film preview: explicitly requested but unavailable (the roll preview image file is missing or unreadable)",
    );
  });

  it("falls back to a generic reason when none is supplied", () => {
    const entries = buildDiagnosticBundleEntries({
      diagnosticsJsonl: "",
      reportText: "report",
      previewRaster: null,
      includePreview: true,
    });
    const manifest = entries.find((entry) => entry.name === "manifest.txt")!;
    expect(decode(manifest.data)).toContain(
      "film preview: explicitly requested but unavailable (no roll preview in this session)",
    );
  });

  it("builds an extracted default ZIP with no private route value or raster bytes", () => {
    const secrets = [
      "/Users/alice/Photo Work/private-roll.scanstudio",
      "/tmp/session/preview.tif",
      "Kodak Gold 200",
      "Leica M6",
      "coolscan3:usb:libusb:000:013",
      "SN-ABC-123",
      "PRIVATE_RASTER_BYTES",
    ];
    const zip = buildDiagnosticBundleZip({
      diagnosticsJsonl: JSON.stringify({
        event: "scan.failed",
        fields: {
          projectPath: secrets[0],
          previewPath: secrets[1],
          filmStock: secrets[2],
          camera: secrets[3],
          deviceId: secrets[4],
          serial: secrets[5],
        },
      }),
      reportText:
        `error path=${secrets[0]}; filmStock=${secrets[2]}; camera=${secrets[3]}; ` +
        `deviceId=${secrets[4]}; serial=${secrets[5]}`,
      previewRaster: {
        filename: "private-roll-preview.tif",
        data: new TextEncoder().encode(secrets[6]),
      },
    });

    const view = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
    const extracted: Array<{ name: string; data: Uint8Array }> = [];
    let offset = 0;
    while (offset + 30 <= zip.length && view.getUint32(offset, true) === 0x04034b50) {
      const size = view.getUint32(offset + 18, true);
      const nameLength = view.getUint16(offset + 26, true);
      const extraLength = view.getUint16(offset + 28, true);
      const nameStart = offset + 30;
      const dataStart = nameStart + nameLength + extraLength;
      extracted.push({
        name: decode(zip.slice(nameStart, nameStart + nameLength)),
        data: zip.slice(dataStart, dataStart + size),
      });
      offset = dataStart + size;
    }
    const searchable = extracted
      .map((entry) => `${entry.name}\n${decode(entry.data)}`)
      .join("\n");
    for (const secret of secrets) expect(searchable).not.toContain(secret);
    expect(extracted.map((entry) => entry.name).sort()).toEqual([
      "diagnostics.jsonl",
      "manifest.txt",
      "report.txt",
    ]);
  });

  it("passes the shared Swift/TypeScript privacy corpus through every default ZIP route", () => {
    const fixture = SHARED_PRIVACY_FIXTURE;
    const secrets = [
      fixture.username,
      ...fixture.absolutePaths,
      fixture.projectName,
      ...fixture.filmMetadata,
      fixture.deviceIdentifier,
      fixture.rasterMarker,
    ];
    const zip = buildDiagnosticBundleZip({
      diagnosticsJsonl: JSON.stringify({
        event: "preview.failed",
        fields: {
          projectPath: fixture.absolutePaths[0],
          filmStock: fixture.filmMetadata[0],
          camera: fixture.filmMetadata[1],
          lens: fixture.filmMetadata[2],
          deviceId: fixture.deviceIdentifier,
        },
      }),
      reportText:
        "project=" + fixture.projectName +
        "; path=" + fixture.absolutePaths[1] +
        "; filmStock=" + fixture.filmMetadata[0] +
        "; deviceId=" + fixture.deviceIdentifier,
      previewRaster: {
        filename: fixture.projectName + ".tif",
        data: new TextEncoder().encode(fixture.rasterMarker),
      },
      sensitiveValues: secrets,
    });
    const searchable = decode(zip);
    for (const secret of secrets) expect(searchable).not.toContain(secret);
  });

  it("exports only the validated non-pixel witness selected for the terminal error", () => {
    const evidence: DiagnosticEvidence = {
      schemaVersion: 1,
      evidenceId: "ev-export",
      operationId: "op-export",
      sessionEpoch: "7",
      operationKind: "preview",
      builds: { app: "app-1", engine: "engine-1", bridge: "bridge-1" },
      device: { model: "LS-5000", adapter: "SA-30", holder: "roll36" },
      witness: {
        kind: "terminalPadding",
        recordCount: 37,
        byteCount: 296,
        parity: "even",
        housekeepingByteCount: 4,
        nonzeroRgbCount: 12,
        mismatchLocation: { recordIndex: 36, byteOffset: 288 },
      },
    };
    const entries = buildDiagnosticBundleEntries({
      diagnosticsJsonl: "",
      reportText: "report",
      previewRaster: null,
      transportEvidence: evidence,
    });

    expect(entries.map((entry) => entry.name).sort()).toEqual([
      "diagnostics.jsonl",
      "evidence-v1.json",
      "manifest.txt",
      "report.txt",
    ]);
    expect(JSON.parse(decode(entries.find((entry) => entry.name === "evidence-v1.json")!.data)))
      .toEqual(evidence);
    expect(decode(entries.find((entry) => entry.name === "manifest.txt")!.data)).toContain(
      "bounded evidence: included ev-export as evidence-v1.json",
    );
  });

  it("revalidates evidence at the final ZIP boundary and refuses arbitrary fields", () => {
    const entries = buildDiagnosticBundleEntries({
      diagnosticsJsonl: "",
      reportText: "report",
      previewRaster: null,
      transportEvidence: {
        schemaVersion: 1,
        evidenceId: "unsafe",
        rawExcerpt: "PRIVATE_FILM_BYTES",
        path: "/Users/private/evidence.bin",
      } as unknown as DiagnosticEvidence,
    });
    const searchable = entries
      .map((entry) => entry.name + "\n" + decode(entry.data))
      .join("\n");
    expect(entries.some((entry) => entry.name === "evidence-v1.json")).toBe(false);
    expect(searchable).not.toContain("PRIVATE_FILM_BYTES");
    expect(searchable).not.toContain("/Users/private");
    expect(searchable).toContain("bounded evidence: unavailable");
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
      "/fake/frame3.tif": TIFF,
      "/fake/frame1.tif": TIFF,
    };
    const thumbnails = {
      3: { imagePath: "/fake/frame3.tif" },
      1: { imagePath: "/fake/frame1.tif" },
    };

    const result = await resolveDiagnosticBundleRaster(thumbnails, (path) => fakeFilesystem[path] ?? null);

    expect(result.unavailableReason).toBeNull();
    expect(result.raster?.filename).toBe("preview.tif");
    expect(result.raster && Array.from(result.raster.data)).toEqual(Array.from(TIFF));
  });

  it("names a raster from validated content rather than its path extension", async () => {
    const fakeFilesystem: Record<string, Uint8Array> = { "/fake/frame1": PNG };
    const result = await resolveDiagnosticBundleRaster(
      { 1: { imagePath: "/fake/frame1" } },
      (path) => fakeFilesystem[path] ?? null,
    );
    expect(result.raster?.filename).toBe("preview.png");
  });

  it("supports an async readFile, since the real implementation reads through a Tauri command", async () => {
    const result = await resolveDiagnosticBundleRaster(
      { 1: { imagePath: "/fake/frame1.tif" } },
      async (path) => {
        await Promise.resolve();
        return path === "/fake/frame1.tif" ? TIFF : null;
      },
    );
    expect(result.raster && Array.from(result.raster.data)).toEqual(Array.from(TIFF));
  });
});
