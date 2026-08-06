pub mod diagnostics;
pub mod engine;
pub mod preview;
mod wsl;

/// Diagnostics surface for the Windows WSL2 lane (08-02, WSL-03): run all
/// read-only setup probes. Never automated install/elevate — the returned
/// `fix_command` strings are display-only copy-paste text.
#[tauri::command]
fn wsl_run_checks() -> Vec<wsl::checker::ProbeResult> {
    wsl::checker::run_all_probes(
        &wsl::checker::RealCommandExecutor,
        cfg!(target_os = "windows"),
        wsl::bridge_cmd::BRIDGE_ENTRYPOINT,
    )
}

/// Risk-register telemetry readout: the largest single bulk-transfer read
/// (in bytes) seen across bridge `hw-telemetry/*.jsonl` `scan.call`/`exit`
/// entries. On Windows reads through the `wsl$` share; elsewhere reads
/// `~/.scanstudio/hw-telemetry`. Any I/O error or zero files reports the
/// honest "no data" state — this command never errors.
#[tauri::command]
fn wsl_max_read_report() -> wsl::checker::MaxReadReport {
    match telemetry_lines() {
        Some(lines) => wsl::checker::max_single_read_from_telemetry(&lines),
        None => wsl::checker::MaxReadReport {
            max_bytes: None,
            entries_scanned: 0,
        },
    }
}

/// Which WSL write mode is active, sourced from `staging::describe_write_mode`
/// (never a hardcoded string).
#[tauri::command]
fn wsl_write_mode_report() -> String {
    wsl::staging::describe_write_mode(wsl::staging::DEFAULT_WSL_WRITE_MODE).to_string()
}

/// Resolve the telemetry directories: on Windows, every user home under
/// `\\wsl$\Ubuntu-24.04\home\*\.scanstudio\hw-telemetry` (readable through the
/// `wsl$` share); elsewhere `~/.scanstudio/hw-telemetry`.
fn telemetry_dirs() -> Vec<std::path::PathBuf> {
    if cfg!(target_os = "windows") {
        let home_root = std::path::PathBuf::from(r"\\wsl$\Ubuntu-24.04\home");
        let Ok(entries) = std::fs::read_dir(&home_root) else {
            return Vec::new();
        };
        entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .map(|p| p.join(".scanstudio").join("hw-telemetry"))
            .collect()
    } else {
        match std::env::var_os("HOME") {
            Some(home) => vec![
                std::path::PathBuf::from(home)
                    .join(".scanstudio")
                    .join("hw-telemetry"),
            ],
            None => Vec::new(),
        }
    }
}

/// Read every line of the most recent 5 telemetry files (by mtime) across the
/// resolved directories. Any I/O error or zero files yields `None` so the
/// caller can return the "no data" report; never panics.
fn telemetry_lines() -> Option<Vec<String>> {
    let dirs = telemetry_dirs();
    if dirs.is_empty() {
        return None;
    }
    let mut files: Vec<(std::path::PathBuf, std::time::SystemTime)> = Vec::new();
    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().map(|e| e == "jsonl").unwrap_or(false) {
                let mtime = std::fs::metadata(&path)
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .unwrap_or(std::time::UNIX_EPOCH);
                files.push((path, mtime));
            }
        }
    }
    if files.is_empty() {
        return None;
    }
    files.sort_by(|a, b| b.1.cmp(&a.1));
    let mut lines = Vec::new();
    for (path, _) in files.into_iter().take(5) {
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        lines.extend(content.lines().map(|l| l.to_string()));
    }
    Some(lines)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_os::init())
        .register_uri_scheme_protocol("scanstudio-preview", preview::handle_request)
        .invoke_handler(tauri::generate_handler![
            engine::engine_request,
            engine::engine_state,
            wsl_run_checks,
            wsl_max_read_report,
            wsl_write_mode_report,
            diagnostics::write_diagnostic_bundle,
            diagnostics::read_preview_raster
        ])
        .setup(|app| engine::setup(app))
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| {
        engine::handle_run_event(app_handle, &event);
    });
}
