//! Local-only "Save Diagnostic Bundle..." support (error report v2, T-ERR-04).
//!
//! This module never talks to the engine or the bridge and never decides
//! bundle contents -- the frontend assembles the zip bytes entirely
//! (`session/zip.ts` + `session/diagnosticBundle.ts`) from state it already
//! holds. This module's only jobs are (1) writing those bytes to a
//! user-chosen path from the save dialog, and (2) reading the roll-preview
//! raster's bytes so the frontend can fold them into the bundle -- the
//! frontend cannot read the filesystem itself.

use tauri::Manager;

/// Writes `bytes` verbatim to `path`, overwriting any existing file. Returns
/// a plain, display-safe error string on failure (no panics).
#[tauri::command]
pub fn write_diagnostic_bundle(path: String, bytes: Vec<u8>) -> Result<(), String> {
    std::fs::write(&path, bytes).map_err(|error| format!("failed to write {path}: {error}"))
}

/// Reads the roll-preview raster's raw bytes for the diagnostic bundle.
/// `path` is always a `Thumbnail.imagePath` the frontend already holds from
/// the engine's own preview response -- never a new engine/bridge round
/// trip, only a local read of a file the app already knows about (the same
/// path the `scanstudio-preview://` scheme already reads to render the
/// contact sheet).
///
/// Scoped exactly like that scheme handler (`crate::preview`): only a path
/// that canonicalizes to somewhere under the user's home directory is
/// readable. Known gap (follow-up): on Windows, a real-hardware preview
/// lives under the pinned WSL share rather than the Windows home directory
/// (see `crate::preview::handle_with_windows_wsl_share`), so this command
/// currently reports it as unavailable there rather than reusing that
/// second scope -- the bundle still saves, with the raster honestly marked
/// not available.
#[tauri::command]
pub fn read_preview_raster(app: tauri::AppHandle, path: String) -> Result<Vec<u8>, String> {
    let home = app
        .path()
        .home_dir()
        .map_err(|_| "could not resolve home directory".to_string())?;
    read_within_scope(&path, &home)
}

fn read_within_scope(path: &str, allowed_root: &std::path::Path) -> Result<Vec<u8>, String> {
    let canonical_root = std::fs::canonicalize(allowed_root)
        .map_err(|_| "could not resolve home directory".to_string())?;
    let canonical = std::fs::canonicalize(path)
        .map_err(|_| "preview raster path not found or inaccessible".to_string())?;
    if !canonical.starts_with(&canonical_root) {
        return Err("preview raster path is outside the allowed scope".to_string());
    }
    std::fs::read(&canonical).map_err(|error| format!("failed to read preview raster: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_the_exact_bytes_given() {
        let dir = std::env::temp_dir().join(format!("scanstudio-diagnostics-bundle-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let path = dir.join("bundle.zip");

        let result = write_diagnostic_bundle(path.to_string_lossy().into_owned(), vec![1, 2, 3, 4]);

        assert!(result.is_ok());
        assert_eq!(std::fs::read(&path).unwrap(), vec![1, 2, 3, 4]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_within_scope_returns_bytes_for_a_path_under_the_allowed_root() {
        let dir = std::env::temp_dir().join(format!("scanstudio-diagnostics-raster-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let file = dir.join("preview.png");
        std::fs::write(&file, [1, 2, 3, 4]).expect("write fixture");

        let result = read_within_scope(&file.to_string_lossy(), &dir);

        assert_eq!(result.unwrap(), vec![1, 2, 3, 4]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_within_scope_refuses_a_path_outside_the_allowed_root() {
        let allowed_root = std::env::temp_dir().join(format!("scanstudio-diagnostics-raster-scope-{}", std::process::id()));
        std::fs::create_dir_all(&allowed_root).expect("create allowed root");
        let outside_dir = std::env::temp_dir().join(format!("scanstudio-diagnostics-raster-outside-{}", std::process::id()));
        std::fs::create_dir_all(&outside_dir).expect("create outside dir");
        let outside_file = outside_dir.join("secret.png");
        std::fs::write(&outside_file, [9]).expect("write outside fixture");

        let result = read_within_scope(&outside_file.to_string_lossy(), &allowed_root);

        assert_eq!(result, Err("preview raster path is outside the allowed scope".to_string()));
        let _ = std::fs::remove_dir_all(&allowed_root);
        let _ = std::fs::remove_dir_all(&outside_dir);
    }

    #[test]
    fn read_within_scope_reports_a_missing_file_honestly() {
        let dir = std::env::temp_dir().join(format!("scanstudio-diagnostics-raster-missing-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let missing = dir.join("never-created.png");

        let result = read_within_scope(&missing.to_string_lossy(), &dir);

        assert_eq!(result, Err("preview raster path not found or inaccessible".to_string()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reports_a_display_safe_error_instead_of_panicking() {
        // A path through a file (not a directory) as a parent component
        // cannot be created on any platform -- a deterministic, portable
        // way to force a write failure without touching a real restricted
        // path.
        let dir = std::env::temp_dir().join(format!("scanstudio-diagnostics-bundle-test-err-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let blocking_file = dir.join("not-a-directory");
        std::fs::write(&blocking_file, b"x").expect("write blocking file");
        let impossible_path = blocking_file.join("bundle.zip");

        let result = write_diagnostic_bundle(impossible_path.to_string_lossy().into_owned(), vec![1]);

        assert!(result.is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
