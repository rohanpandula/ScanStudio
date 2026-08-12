//! Local-only "Save Diagnostic Bundle..." support (error report v2, T-ERR-04).
//!
//! This module never talks to the engine or the bridge and never decides
//! bundle contents -- the frontend assembles the zip bytes entirely
//! (`session/zip.ts` + `session/diagnosticBundle.ts`) from state it already
//! holds. This module's only jobs are (1) writing those bytes to the exact
//! path chosen by a native save dialog, and (2) reading the roll-preview
//! raster's bytes so the frontend can fold them into the bundle -- the
//! frontend cannot read the filesystem itself.

use serde::Serialize;
use tauri::Manager;
use tauri_plugin_dialog::DialogExt;

use crate::preview::PreviewAccess;
use crate::wsl::bridge_cmd::WSL_DISTRO;
use crate::wsl::pathmap::{wsl_distro_share_root, wsl_preview_paths_in_share};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticIpcError {
    code: &'static str,
    message: String,
}

fn diagnostic_error(code: &'static str, message: impl Into<String>) -> DiagnosticIpcError {
    DiagnosticIpcError {
        code,
        message: message.into(),
    }
}

fn validated_suggested_name(name: &str) -> Result<String, DiagnosticIpcError> {
    let candidate = std::path::Path::new(name);
    let is_plain_name = !name.is_empty()
        && candidate
            .parent()
            .is_some_and(|parent| parent.as_os_str().is_empty())
        && candidate.file_name().is_some_and(|file_name| file_name == name);
    if !is_plain_name || !name.to_ascii_lowercase().ends_with(".zip") {
        return Err(diagnostic_error(
            "INVALID_SAVE_NAME",
            "diagnostic bundle name must be a plain .zip filename",
        ));
    }
    Ok(name.to_string())
}

fn write_selected_bundle(path: &std::path::Path, bytes: &[u8]) -> Result<(), DiagnosticIpcError> {
    std::fs::write(path, bytes).map_err(|error| {
        diagnostic_error(
            "DIAGNOSTIC_WRITE_FAILED",
            format!("failed to write diagnostic bundle: {error}"),
        )
    })
}

/// Opens the native save panel and writes only the single path returned by
/// that panel. The renderer cannot nominate a filesystem path, and the
/// selection callback is consumed once, so overwrite consent and write
/// authority are bound to this exact save operation.
#[tauri::command]
pub async fn save_diagnostic_bundle(
    app: tauri::AppHandle,
    suggested_name: String,
    bytes: Vec<u8>,
) -> Result<bool, DiagnosticIpcError> {
    let suggested_name = validated_suggested_name(&suggested_name)?;
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.dialog()
        .file()
        .set_title("Save Diagnostic Bundle")
        .set_file_name(suggested_name)
        .add_filter("Zip Archive", &["zip"])
        .save_file(move |selection| {
            let _ = sender.send(selection);
        });
    let selection = receiver.await.map_err(|_| {
        diagnostic_error(
            "SAVE_DIALOG_FAILED",
            "diagnostic save dialog closed without a result",
        )
    })?;
    let Some(selection) = selection else {
        return Ok(false);
    };
    let path = selection.into_path().map_err(|error| {
        diagnostic_error(
            "SAVE_DIALOG_FAILED",
            format!("save dialog returned an unsupported destination: {error}"),
        )
    })?;
    tauri::async_runtime::spawn_blocking(move || write_selected_bundle(&path, &bytes))
        .await
        .map_err(|error| {
            diagnostic_error(
                "DIAGNOSTIC_WRITE_FAILED",
                format!("diagnostic save task failed: {error}"),
            )
        })??;
    Ok(true)
}

/// Reads the roll-preview raster's raw bytes for the diagnostic bundle.
/// The renderer presents only an opaque identifier previously issued for an
/// engine `imagePath`. The resolved path is still canonicalized beneath the
/// same host/WSL roots as the preview protocol before any bytes are read.
#[tauri::command]
pub fn read_preview_raster(
    app: tauri::AppHandle,
    preview_id: String,
) -> Result<Vec<u8>, DiagnosticIpcError> {
    let access = app.state::<PreviewAccess>();
    let path = access.resolve(&preview_id).ok_or_else(|| {
        diagnostic_error(
            "PREVIEW_NOT_AUTHORIZED",
            "preview identifier was not issued by the engine",
        )
    })?;
    let home = app
        .path()
        .home_dir()
        .map_err(|_| {
            diagnostic_error(
                "PREVIEW_SCOPE_UNAVAILABLE",
                "could not resolve home directory",
            )
        })?;
    if cfg!(target_os = "windows") && path.starts_with('/') {
        let share = wsl_distro_share_root(WSL_DISTRO).map_err(|_| {
            diagnostic_error(
                "PREVIEW_SCOPE_UNAVAILABLE",
                "could not resolve pinned WSL preview share",
            )
        })?;
        let (preview_root, requested) =
            wsl_preview_paths_in_share(&path, &share).map_err(|_| {
                diagnostic_error(
                    "PREVIEW_NOT_AUTHORIZED",
                    "preview path is outside the allowed WSL scope",
                )
            })?;
        return read_within_scope(&requested.to_string_lossy(), &preview_root)
            .map_err(|message| diagnostic_error("PREVIEW_READ_FAILED", message));
    }
    read_within_scope(&path, &home)
        .map_err(|message| diagnostic_error("PREVIEW_READ_FAILED", message))
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
    fn writes_the_exact_bytes_given_to_a_selected_path() {
        let dir = std::env::temp_dir().join(format!("scanstudio-diagnostics-bundle-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let path = dir.join("bundle.zip");

        let result = write_selected_bundle(&path, &[1, 2, 3, 4]);

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

        let result = write_selected_bundle(&impossible_path, &[1]);

        assert!(result.is_err());
        assert_eq!(result.unwrap_err().code, "DIAGNOSTIC_WRITE_FAILED");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn renderer_cannot_smuggle_a_destination_in_the_suggested_filename() {
        let result = validated_suggested_name("../overwrite.zip");

        assert_eq!(result.unwrap_err().code, "INVALID_SAVE_NAME");
    }
}
