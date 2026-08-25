import { createStoredZip, type ZipEntry } from "./zip";
import {
  parseDiagnosticEvidence,
  type DiagnosticEvidence,
} from "./diagnosticEvidence";
import { redactShareText, sanitizeDiagnosticJsonl } from "./shareSafeDiagnostics";

export interface PreviewRaster {
  filename: string;
  data: Uint8Array;
}

export interface DiagnosticBundleParams {
  diagnosticsJsonl: string;
  reportText: string;
  previewRaster: PreviewRaster | null;
  unavailableRasterReason?: string | null;
  /** Film-content bytes are excluded unless true for this one invocation. */
  includePreview?: boolean;
  previewFrameIndex?: number;
  transportEvidence?: DiagnosticEvidence | null;
  unavailableEvidenceReason?: string | null;
  sensitiveValues?: string[];
}

export const MAX_DIAGNOSTIC_PREVIEW_BYTES = 8 * 1024 * 1024;
const MAX_DIAGNOSTICS_JSONL_BYTES = 1024 * 1024;
const MAX_REPORT_BYTES = 256 * 1024;

function boundedText(text: string, maximumBytes: number, replacement: string): Uint8Array {
  const encoded = new TextEncoder().encode(text);
  return encoded.length <= maximumBytes ? encoded : new TextEncoder().encode(replacement);
}

function previewContentType(data: Uint8Array): "png" | "jpg" | "tif" | null {
  if (
    data.length >= 8 &&
    data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4e && data[3] === 0x47 &&
    data[4] === 0x0d && data[5] === 0x0a && data[6] === 0x1a && data[7] === 0x0a
  ) return "png";
  if (data.length >= 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) return "jpg";
  if (
    data.length >= 4 &&
    ((data[0] === 0x49 && data[1] === 0x49 && data[2] === 0x2a && data[3] === 0x00) ||
      (data[0] === 0x4d && data[1] === 0x4d && data[2] === 0x00 && data[3] === 0x2a))
  ) return "tif";
  return null;
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
    {
      name: "diagnostics.jsonl",
      data: boundedText(
        sanitizeDiagnosticJsonl(params.diagnosticsJsonl, params.sensitiveValues),
        MAX_DIAGNOSTICS_JSONL_BYTES,
        '{"event":"diagnostic.bundleLimit","fields":{"diagnosticsOmitted":true}}',
      ),
    },
    {
      name: "report.txt",
      data: boundedText(
        redactShareText(params.reportText, params.sensitiveValues),
        MAX_REPORT_BYTES,
        "ScanStudio error report\n\nReport omitted because it exceeded the share-safe byte limit.",
      ),
    },
  ];

  const validatedPreviewType = params.previewRaster
    ? previewContentType(params.previewRaster.data)
    : null;
  const validPreview = Boolean(
    params.previewRaster &&
      params.previewRaster.data.length <= MAX_DIAGNOSTIC_PREVIEW_BYTES &&
      validatedPreviewType,
  );
  if (params.includePreview === true && params.previewRaster && validPreview) {
    const previewFilename = `preview.${validatedPreviewType}`;
    const frame = Number.isInteger(params.previewFrameIndex)
      ? `frame ${params.previewFrameIndex}`
      : "the disclosed frame";
    manifestLines.push(
      `${previewFilename}: film-content preview for ${frame}, included by explicit one-export consent`,
    );
    entries.push({ name: previewFilename, data: params.previewRaster.data });
  } else if (params.includePreview === true) {
    const reason = params.unavailableRasterReason ?? (
      params.previewRaster && params.previewRaster.data.length > MAX_DIAGNOSTIC_PREVIEW_BYTES
        ? "the preview exceeds the diagnostic bundle byte limit"
        : params.previewRaster
          ? "the preview file type is not an allowed PNG, JPEG, or TIFF image"
          : "no roll preview in this session"
    );
    manifestLines.push(
      `film preview: explicitly requested but unavailable (${redactShareText(reason, params.sensitiveValues)})`,
    );
  } else {
    manifestLines.push("film preview: excluded by privacy default");
  }

  const parsedEvidence =
    params.transportEvidence === null || params.transportEvidence === undefined
      ? null
      : parseDiagnosticEvidence(params.transportEvidence);
  if (parsedEvidence?.ok === true) {
    entries.push({
      name: "evidence-v1.json",
      data: encoder.encode(JSON.stringify(parsedEvidence.value, null, 2)),
    });
    manifestLines.push(
      `bounded evidence: included ${parsedEvidence.value.evidenceId} as evidence-v1.json (non-pixel structural witness)`,
    );
  } else if (parsedEvidence?.ok === false || params.unavailableEvidenceReason) {
    const reason =
      parsedEvidence?.ok === false
        ? parsedEvidence.reason
        : params.unavailableEvidenceReason ?? "unknown reason";
    manifestLines.push(
      `bounded evidence: unavailable (${redactShareText(reason, params.sensitiveValues)})`,
    );
  } else {
    manifestLines.push("bounded evidence: not referenced by the terminal error");
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

export interface PreviewRasterCandidate {
  frameIndex: number;
  imagePath: string | null;
}

/** Selects and names the exact candidate without reading any bytes. The UI
 * snapshots this object before asking for one-export consent. */
export function selectDiagnosticBundleRasterCandidate(
  thumbnails: Record<number, { imagePath?: string | null }>,
): PreviewRasterCandidate | null {
  const frameIndex = Object.keys(thumbnails)
    .map(Number)
    .filter((index) => Number.isFinite(index))
    .sort((a, b) => a - b)[0];
  if (frameIndex === undefined) return null;
  return {
    frameIndex,
    imagePath: thumbnails[frameIndex]?.imagePath ?? null,
  };
}

export async function resolveDiagnosticBundleRasterCandidate(
  candidate: PreviewRasterCandidate | null,
  readFile: (path: string) => Uint8Array | null | Promise<Uint8Array | null>,
): Promise<RasterResolution> {
  if (candidate === null) {
    return { raster: null, unavailableReason: "no roll preview in this session" };
  }
  if (!candidate.imagePath) {
    return { raster: null, unavailableReason: "the roll preview has no locally-known image path" };
  }
  const data = await readFile(candidate.imagePath);
  if (data === null) {
    return { raster: null, unavailableReason: "the roll preview image file is missing or unreadable" };
  }
  if (data.length > MAX_DIAGNOSTIC_PREVIEW_BYTES) {
    return { raster: null, unavailableReason: "the roll preview exceeds the 8 MiB export limit" };
  }
  const contentType = previewContentType(data);
  if (contentType === null) {
    return {
      raster: null,
      unavailableReason: "the roll preview is not a validated PNG, JPEG, or TIFF image",
    };
  }
  return {
    raster: { filename: `preview.${contentType}`, data },
    unavailableReason: null,
  };
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
  return resolveDiagnosticBundleRasterCandidate(
    selectDiagnosticBundleRasterCandidate(thumbnails),
    readFile,
  );
}
