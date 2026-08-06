import { invoke } from "@tauri-apps/api/core";

// Thin IPC wrappers around the diagnostics.rs commands (error report v2,
// T-ERR-04). Kept separate from diagnosticBundle.ts / zip.ts so the
// bundle-assembly logic itself stays a pure, Tauri-free unit -- only this
// file talks to `invoke`.

/** Reads the roll-preview raster's bytes via the read_preview_raster
 * command -- the webview has no direct filesystem access, so this is the
 * only way to get Thumbnail.imagePath's bytes into the bundle. Returns
 * `null` on any failure (missing file, outside the allowed scope, no Tauri
 * runtime) rather than throwing, matching resolveDiagnosticBundleRaster's
 * `readFile` contract. */
export async function readPreviewRasterBytes(path: string): Promise<Uint8Array | null> {
  try {
    const bytes = await invoke<number[]>("read_preview_raster", { path });
    return new Uint8Array(bytes);
  } catch {
    return null;
  }
}

/** Writes the assembled bundle zip to `path` via the write_diagnostic_bundle
 * command. */
export async function writeDiagnosticBundleFile(path: string, bytes: Uint8Array): Promise<void> {
  await invoke("write_diagnostic_bundle", { path, bytes: Array.from(bytes) });
}
