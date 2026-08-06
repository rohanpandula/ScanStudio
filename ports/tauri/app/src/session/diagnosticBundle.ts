import { createStoredZip, type ZipEntry } from "./zip";

export interface PreviewRaster {
  filename: string;
  data: Uint8Array;
}

export interface DiagnosticBundleParams {
  diagnosticsJsonl: string;
  reportText: string;
  previewRaster: PreviewRaster | null;
  unavailableRasterReason?: string | null;
}

/** Assembles "Save Diagnostic Bundle..."'s contents (T-ERR-04) from
 * already-in-memory data -- no filesystem access here, mirroring
 * DiagnosticBundleBuilder
 * (app/ScanStudio/Sources/ScanStudioKit/DiagnosticBundle.swift). */
export function buildDiagnosticBundleEntries(params: DiagnosticBundleParams): ZipEntry[] {
  const encoder = new TextEncoder();
  const manifestLines = [
    "ScanStudio diagnostic bundle",
    "",
    "diagnostics.jsonl: this session's diagnostic events, one JSON object per line",
    "report.txt: the generated error report at the time of export",
  ];
  const entries: ZipEntry[] = [
    { name: "diagnostics.jsonl", data: encoder.encode(params.diagnosticsJsonl) },
    { name: "report.txt", data: encoder.encode(params.reportText) },
  ];

  if (params.previewRaster) {
    manifestLines.push(`${params.previewRaster.filename}: the roll preview raster`);
    entries.push({ name: params.previewRaster.filename, data: params.previewRaster.data });
  } else {
    const reason = params.unavailableRasterReason ?? "no roll preview in this session";
    manifestLines.push(`raster: not available in this build (${reason})`);
  }

  entries.push({ name: "manifest.txt", data: encoder.encode(manifestLines.join("\n")) });
  return entries;
}

/** The complete zip bytes for "Save Diagnostic Bundle...". */
export function buildDiagnosticBundleZip(params: DiagnosticBundleParams): Uint8Array {
  return createStoredZip(buildDiagnosticBundleEntries(params));
}

export interface RasterResolution {
  raster: PreviewRaster | null;
  unavailableReason: string | null;
}

/** Resolves the diagnostic bundle's preview raster from state the frontend
 * already holds -- Thumbnail.imagePath, exactly what the contact sheet
 * already reads (scanstudio-preview://) to render preview tiles -- never a
 * new bridge/engine wire method. `readFile` is injectable (and may be
 * async, since the real implementation reads through a Tauri command --
 * the webview has no direct filesystem access) so this is testable against
 * a fake filesystem with zero real disk I/O. Mirrors
 * DiagnosticBundleRasterPolicy
 * (app/ScanStudio/Sources/ScanStudioKit/DiagnosticBundle.swift): picks the
 * lowest-indexed frame with a known, readable image path. */
export async function resolveDiagnosticBundleRaster(
  thumbnails: Record<number, { imagePath?: string | null }>,
  readFile: (path: string) => Uint8Array | null | Promise<Uint8Array | null>,
): Promise<RasterResolution> {
  const indices = Object.keys(thumbnails)
    .map(Number)
    .filter((index) => Number.isFinite(index))
    .sort((a, b) => a - b);
  if (indices.length === 0) {
    return { raster: null, unavailableReason: "no roll preview in this session" };
  }

  const imagePath = thumbnails[indices[0]]?.imagePath;
  if (!imagePath) {
    return { raster: null, unavailableReason: "the roll preview has no locally-known image path" };
  }

  const data = await readFile(imagePath);
  if (data === null) {
    return { raster: null, unavailableReason: "the roll preview image file is missing or unreadable" };
  }

  const dotIndex = imagePath.lastIndexOf(".");
  const slashIndex = Math.max(imagePath.lastIndexOf("/"), imagePath.lastIndexOf("\\"));
  const extension = dotIndex > slashIndex ? imagePath.slice(dotIndex + 1) : "";
  const filename = extension.length === 0 ? "preview" : `preview.${extension}`;
  return { raster: { filename, data }, unavailableReason: null };
}
