//! Create-only, job-scoped capture evidence packages. This module never
//! drives hardware and never rewrites bridge-owned source artifacts.

use std::io::Read;
use std::path::{Path, PathBuf};

use serde::Serialize;
use sha2::{Digest, Sha256};

const PINNED_WSL_DISTRO: &str = "Ubuntu-24.04";

#[derive(Debug, Clone, PartialEq, Eq)]
struct PinnedWslAttemptsPath {
    base: PathBuf,
    input: PathBuf,
    checked_ancestors: Vec<PathBuf>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EvidencePackageResult {
    pub status: String,
    pub path: Option<String>,
    pub detail: String,
}

#[derive(Debug, Clone)]
pub struct EvidenceFrame {
    pub frame_index: u32,
    pub rgb_path: PathBuf,
    pub ir_path: Option<PathBuf>,
    pub meter_path: Option<PathBuf>,
    pub bridge_receipt: serde_json::Value,
    pub engine_receipt: serde_json::Value,
    pub attempts_root: Option<PathBuf>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PackageManifest<'a> {
    schema_version: u32,
    status: &'a str,
    job_id: &'a str,
    detail: &'a str,
    effective_settings: &'a serde_json::Value,
    frames: Vec<FrameManifest>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FrameManifest {
    frame_index: u32,
    rgb: FileDigest,
    ir: Option<FileDigest>,
    meter: Option<FileDigest>,
    /// One package-relative, deduplicated copy of the bridge session's
    /// exact attempt tree. Multiple frames from one Roll share this value.
    journal_root: Option<String>,
    bridge_receipt: serde_json::Value,
    engine_receipt: serde_json::Value,
    /// Exact live paths before package rebasing. The receipt copies above are
    /// self-contained; these values preserve acquisition provenance without
    /// making replay depend on a still-running WSL distribution.
    source_provenance: ReceiptSourceProvenance,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReceiptSourceProvenance {
    attempts_root: Option<String>,
    bridge_selected_pixels_path: Option<String>,
    engine_selected_pixels_path: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FileDigest {
    /// Original bridge-reported source, retained for provenance.
    path: String,
    /// Relative self-contained package copy, never a link back to source.
    package_path: String,
    sha256: String,
}

/// Finalizes evidence only after the job's terminal bridge event. The package
/// directory is reserved create-only and its manifest is written last; an
/// existing package is therefore a hard collision.
///
/// `terminal_error`, when the caller's own job ended in failure (a bridge
/// `scan.error` such as `BATCH_INTEGRITY_ERROR`, or any other terminal
/// closure that isn't a clean completion), is folded into `base_error`
/// alongside whatever `expected_attempts_root()` itself reports — the same
/// mechanism `finalize_into` already uses to mark a package `incomplete`
/// and explain why. Before this parameter existed, a failed job's package
/// (when one was written at all) recorded every frame's own individually
/// observed outcome but never the reason the *job* itself ended, so a
/// human auditing the package later had no record of it short of engine
/// stderr, which this package outlives. `None` for the ordinary successful-
/// completion path leaves behavior exactly as it was.
pub fn finalize(
    master_destination: &Path,
    job_id: &str,
    frames: &[EvidenceFrame],
    effective_settings: &serde_json::Value,
    terminal_error: Option<&str>,
) -> Result<EvidencePackageResult, String> {
    let expected_root = expected_attempts_root().ok();
    finalize_with_optional_expected_root(
        master_destination,
        job_id,
        frames,
        effective_settings,
        expected_root.as_deref(),
        terminal_error.map(str::to_string),
    )
}

pub fn finalize_with_expected_root(
    master_destination: &Path,
    job_id: &str,
    frames: &[EvidenceFrame],
    effective_settings: &serde_json::Value,
    expected_root: &Path,
) -> Result<EvidencePackageResult, String> {
    finalize_with_optional_expected_root(
        master_destination,
        job_id,
        frames,
        effective_settings,
        Some(expected_root),
        None,
    )
}

fn finalize_with_optional_expected_root(
    master_destination: &Path,
    job_id: &str,
    frames: &[EvidenceFrame],
    effective_settings: &serde_json::Value,
    expected_root: Option<&Path>,
    base_error: Option<String>,
) -> Result<EvidencePackageResult, String> {
    validate_job_id(job_id)?;
    let root = master_destination.join("Capture Evidence");
    std::fs::create_dir_all(&root).map_err(|e| format!("create evidence root: {e}"))?;
    let final_dir = root.join(format!("{job_id}.scanstudio"));
    // `create_dir` is the create-only reservation. We never rename over an
    // existing path; a concurrent winner, file, or symlink makes this fail.
    // `manifest.json` is deliberately written last and is the validity marker.
    std::fs::create_dir(&final_dir)
        .map_err(|e| format!("create-only evidence package {}: {e}", final_dir.display()))?;
    let (status, detail) = finalize_into(
        &final_dir,
        job_id,
        frames,
        effective_settings,
        expected_root,
        base_error,
    )?;
    Ok(EvidencePackageResult {
        status,
        path: Some(final_dir.display().to_string()),
        detail,
    })
}

const BRIDGE_SELECTED_PIXELS_POINTER: &str = "/nikonBuilderInputs/selectedPixelsPath";
const ENGINE_SELECTED_PIXELS_POINTER: &str =
    "/receipt/nikonBuilderInputs/selectedPixelsPath";

fn json_string_at(value: &serde_json::Value, pointer: &str) -> Option<String> {
    value.pointer(pointer).and_then(|value| value.as_str()).map(str::to_string)
}

fn receipt_source_provenance(frame: &EvidenceFrame) -> ReceiptSourceProvenance {
    ReceiptSourceProvenance {
        attempts_root: frame
            .bridge_receipt
            .pointer("/attemptsRoot")
            .and_then(|value| value.as_str())
            .map(str::to_string)
            .or_else(|| {
                frame
                    .attempts_root
                    .as_ref()
                    .map(|path| path.display().to_string())
            }),
        bridge_selected_pixels_path: json_string_at(
            &frame.bridge_receipt,
            BRIDGE_SELECTED_PIXELS_POINTER,
        ),
        engine_selected_pixels_path: json_string_at(
            &frame.engine_receipt,
            ENGINE_SELECTED_PIXELS_POINTER,
        ),
    }
}

fn set_json_string_at(
    value: &mut serde_json::Value,
    pointer: &str,
    replacement: &str,
) -> Result<(), String> {
    let target = value
        .pointer_mut(pointer)
        .ok_or_else(|| format!("receipt path disappeared while rebasing {pointer}"))?;
    if !target.is_string() {
        return Err(format!("receipt path at {pointer} is not a string"));
    }
    *target = serde_json::Value::String(replacement.to_string());
    Ok(())
}

fn package_selected_pixels_path(
    source: &str,
    validated_attempt: &Path,
    journal_root: &str,
) -> Result<String, String> {
    let source_path = Path::new(source);
    let metadata = std::fs::symlink_metadata(source_path)
        .map_err(|error| format!("inspect selected-pixels source {source:?}: {error}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!(
            "selected-pixels source is not a regular non-symlink file: {source:?}"
        ));
    }
    let canonical = std::fs::canonicalize(source_path)
        .map_err(|error| format!("canonicalize selected-pixels source {source:?}: {error}"))?;
    let relative = canonical.strip_prefix(validated_attempt).map_err(|_| {
        format!(
            "selected-pixels source {source:?} is outside its validated attemptsRoot {}",
            validated_attempt.display()
        )
    })?;
    let mut components = Vec::new();
    for component in relative.components() {
        match component {
            std::path::Component::Normal(value) => components.push(
                value
                    .to_str()
                    .ok_or("selected-pixels package path is not valid UTF-8")?,
            ),
            _ => return Err("selected-pixels package path contains an unsafe component".into()),
        }
    }
    if components.is_empty() {
        return Err("selected-pixels package path did not identify a file".into());
    }
    Ok(format!(
        "{}/{}",
        journal_root.trim_end_matches('/'),
        components.join("/")
    ))
}

fn rebase_packaged_receipts(
    frame: &EvidenceFrame,
    validated_attempt: Option<&Path>,
    journal_root: Option<&str>,
) -> Result<(serde_json::Value, serde_json::Value), String> {
    let mut bridge = frame.bridge_receipt.clone();
    let mut engine = frame.engine_receipt.clone();
    let bridge_selected = json_string_at(&bridge, BRIDGE_SELECTED_PIXELS_POINTER);
    let engine_selected = json_string_at(&engine, ENGINE_SELECTED_PIXELS_POINTER);
    if let (Some(bridge_path), Some(engine_path)) =
        (bridge_selected.as_deref(), engine_selected.as_deref())
    {
        if bridge_path != engine_path {
            return Err(format!(
                "bridge and engine receipts disagree on selectedPixelsPath: {bridge_path:?} vs {engine_path:?}"
            ));
        }
    }

    let has_selected = bridge_selected.is_some() || engine_selected.is_some();
    let (Some(validated_attempt), Some(journal_root)) =
        (validated_attempt, journal_root)
    else {
        if has_selected {
            return Err(
                "selectedPixelsPath cannot be rebased because its attempt journal was not packaged"
                    .into(),
            );
        }
        return Ok((bridge, engine));
    };

    if bridge
        .pointer("/attemptsRoot")
        .is_some_and(|value| value.is_string())
    {
        set_json_string_at(&mut bridge, "/attemptsRoot", journal_root)?;
    }
    if let Some(source) = bridge_selected {
        let packaged = package_selected_pixels_path(&source, validated_attempt, journal_root)?;
        set_json_string_at(&mut bridge, BRIDGE_SELECTED_PIXELS_POINTER, &packaged)?;
    }
    if let Some(source) = engine_selected {
        let packaged = package_selected_pixels_path(&source, validated_attempt, journal_root)?;
        set_json_string_at(&mut engine, ENGINE_SELECTED_PIXELS_POINTER, &packaged)?;
    }
    Ok((bridge, engine))
}

fn finalize_into(
    staging: &Path,
    job_id: &str,
    frames: &[EvidenceFrame],
    effective_settings: &serde_json::Value,
    expected_root: Option<&Path>,
    base_error: Option<String>,
) -> Result<(String, String), String> {
    let mut manifests = Vec::with_capacity(frames.len());
    let mut unavailable = frames.is_empty();
    let mut reasons = Vec::new();
    let mut copied_journals = std::collections::HashMap::<PathBuf, Result<String, String>>::new();
    if let Some(error) = base_error {
        unavailable = true;
        reasons.push(error);
    }
    for frame in frames {
        let validated_attempt = match &frame.attempts_root {
            Some(root) => match validate_frame_attempts_root(root, expected_root) {
                Ok(root) => Some(root),
                Err(error) => {
                    unavailable = true;
                    reasons.push(format!(
                        "frame {} journal omitted: {error}",
                        frame.frame_index
                    ));
                    None
                }
            },
            None => {
                unavailable = true;
                reasons.push(format!(
                    "frame {} receipt omitted attemptsRoot",
                    frame.frame_index
                ));
                None
            }
        };
        let artifact_root = staging
            .join("artifacts")
            .join(format!("frame-{:04}", frame.frame_index));
        let rgb = copy_artifact(&frame.rgb_path, &artifact_root.join("rgb.tif"), staging)?;
        let ir = frame
            .ir_path
            .as_deref()
            .map(|path| copy_artifact(path, &artifact_root.join("ir.tif"), staging))
            .transpose()?;
        let meter = frame
            .meter_path
            .as_deref()
            .map(|path| copy_artifact(path, &artifact_root.join("meter.tif"), staging))
            .transpose()?;
        let journal_root = if let Some(root) = validated_attempt.as_ref() {
            let next_index = copied_journals.len() + 1;
            let result = copied_journals
                .entry(root.clone())
                .or_insert_with(|| {
                    let relative = format!("attempts/session-{next_index:04}");
                    let destination = staging.join(&relative);
                    std::fs::create_dir_all(
                        destination
                            .parent()
                            .expect("attempt destination has parent"),
                    )
                    .map_err(|e| format!("create attempts package directory: {e}"))
                    .and_then(|_| validate_tree_no_symlinks(&root))
                    .and_then(|_| copy_tree_no_symlinks(&root, &destination))
                    .map(|_| relative)
                })
                .clone();
            match result {
                Ok(relative) => Some(relative),
                Err(error) => {
                    unavailable = true;
                    reasons.push(format!(
                        "frame {} journal unavailable: {error}",
                        frame.frame_index
                    ));
                    None
                }
            }
        } else {
            None
        };
        let source_provenance = receipt_source_provenance(frame);
        let (bridge_receipt, engine_receipt) = match rebase_packaged_receipts(
            frame,
            validated_attempt.as_deref(),
            journal_root.as_deref(),
        ) {
            Ok(receipts) => receipts,
            Err(error) => {
                unavailable = true;
                reasons.push(format!(
                    "frame {} receipt paths were not package-rebased: {error}",
                    frame.frame_index
                ));
                (frame.bridge_receipt.clone(), frame.engine_receipt.clone())
            }
        };
        manifests.push(FrameManifest {
            frame_index: frame.frame_index,
            rgb,
            ir,
            meter,
            journal_root,
            bridge_receipt,
            engine_receipt,
            source_provenance,
        });
    }
    let status = if unavailable {
        "incomplete"
    } else {
        "complete"
    };
    let detail = if unavailable {
        if reasons.is_empty() {
            "Capture artifacts are self-contained; replay journals are unavailable.".to_string()
        } else {
            format!(
                "Capture artifacts are self-contained; {}",
                reasons.join("; ")
            )
        }
    } else {
        "Capture artifacts and exact bridge attempt journals copied.".to_string()
    };
    let manifest = PackageManifest {
        schema_version: 2,
        status,
        job_id,
        detail: &detail,
        effective_settings,
        frames: manifests,
    };
    let data = serde_json::to_vec_pretty(&manifest)
        .map_err(|e| format!("serialize evidence manifest: {e}"))?;
    std::fs::write(staging.join("manifest.json"), data)
        .map_err(|e| format!("write evidence manifest: {e}"))?;
    Ok((status.into(), detail))
}

fn validate_job_id(job_id: &str) -> Result<(), String> {
    let path = Path::new(job_id);
    if job_id.is_empty()
        || path.is_absolute()
        || path.components().count() != 1
        || job_id == "."
        || job_id == ".."
        || job_id.contains(['/', '\\'])
    {
        return Err("jobId must be one safe filename component".into());
    }
    Ok(())
}

fn expected_attempts_root() -> Result<PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("HOME is unavailable for attemptsRoot validation")?;
    std::fs::canonicalize(PathBuf::from(home).join(".scanstudio/coolscanpy-attempts"))
        .map_err(|e| format!("canonicalize expected attempts root: {e}"))
}

fn validate_frame_attempts_root(
    input: &Path,
    native_expected: Option<&Path>,
) -> Result<PathBuf, String> {
    if let Some(parsed) = parse_pinned_wsl_attempts_root(input)? {
        return validate_pinned_wsl_attempts_root(parsed);
    }
    let expected = native_expected.ok_or(
        "native attempts root is unavailable and receipt path is not the pinned WSL route",
    )?;
    validate_attempts_root(input, expected)
}

/// Recognize only the bridge route emitted by the Windows/WSL integration:
/// `\\wsl$\Ubuntu-24.04\home\<user>\.scanstudio\coolscanpy-attempts\<session>`.
/// The session must be exactly one direct child of the attempts base.
fn parse_pinned_wsl_attempts_root(input: &Path) -> Result<Option<PinnedWslAttemptsPath>, String> {
    let value = input
        .to_str()
        .ok_or("bridge attemptsRoot is not valid UTF-8")?;
    let lower = value.to_ascii_lowercase();
    let is_wsl_unc = lower.starts_with(r"\\wsl$\") || lower.starts_with(r"\\wsl.localhost\");
    if !is_wsl_unc {
        return Ok(None);
    }
    if value.contains('/') {
        return Err("WSL attemptsRoot must use the canonical UNC separator form".into());
    }
    let parts = value.split('\\').collect::<Vec<_>>();
    if parts.len() != 9
        || !parts[0].is_empty()
        || !parts[1].is_empty()
        || !parts[2].eq_ignore_ascii_case("wsl$")
        || !parts[3].eq_ignore_ascii_case(PINNED_WSL_DISTRO)
        || !parts[4].eq_ignore_ascii_case("home")
        || !safe_path_component(parts[5])
        || parts[6] != ".scanstudio"
        || parts[7] != "coolscanpy-attempts"
        || !safe_path_component(parts[8])
    {
        return Err(format!(
            "bridge attemptsRoot must be one direct session child under the pinned \\\\wsl$\\{PINNED_WSL_DISTRO}\\home\\<user>\\.scanstudio\\coolscanpy-attempts base"
        ));
    }

    let home = PathBuf::from(format!(r"\\wsl$\{}\home\{}", PINNED_WSL_DISTRO, parts[5]));
    let scanstudio = home.join(".scanstudio");
    let base = scanstudio.join("coolscanpy-attempts");
    Ok(Some(PinnedWslAttemptsPath {
        base: base.clone(),
        input: input.to_path_buf(),
        checked_ancestors: vec![home, scanstudio, base],
    }))
}

fn safe_path_component(value: &str) -> bool {
    !value.is_empty()
        && !matches!(value, "." | "..")
        && !value.contains(['/', '\\', ':', '*', '?', '"', '<', '>', '|'])
}

fn validate_pinned_wsl_attempts_root(parsed: PinnedWslAttemptsPath) -> Result<PathBuf, String> {
    let mut checked_route = parsed.checked_ancestors;
    checked_route.push(parsed.input.clone());
    validate_directory_route_no_symlinks(&checked_route)?;
    validate_attempts_root(&parsed.input, &parsed.base)
}

fn validate_directory_route_no_symlinks(route: &[PathBuf]) -> Result<(), String> {
    for path in route {
        let metadata = std::fs::symlink_metadata(path)
            .map_err(|error| format!("inspect WSL evidence route {}: {error}", path.display()))?;
        if metadata.file_type().is_symlink() {
            return Err(format!(
                "WSL evidence route contains a symlink: {}",
                path.display()
            ));
        }
        if !metadata.is_dir() {
            return Err(format!(
                "WSL evidence route is not a directory: {}",
                path.display()
            ));
        }
    }
    Ok(())
}

fn validate_attempts_root(input: &Path, expected: &Path) -> Result<PathBuf, String> {
    let expected = std::fs::canonicalize(expected)
        .map_err(|e| format!("canonicalize expected attempts root: {e}"))?;
    let actual = std::fs::canonicalize(input)
        .map_err(|e| format!("canonicalize bridge attemptsRoot: {e}"))?;
    if actual.parent() != Some(expected.as_path()) {
        return Err(
            "bridge attemptsRoot must be a direct child of the canonical attempts base".into(),
        );
    }
    Ok(actual)
}

fn validate_tree_no_symlinks(source: &Path) -> Result<(), String> {
    let metadata = std::fs::symlink_metadata(source)
        .map_err(|e| format!("stat evidence tree {}: {e}", source.display()))?;
    if metadata.file_type().is_symlink() {
        return Err(format!(
            "evidence tree contains symlink: {}",
            source.display()
        ));
    }
    if metadata.is_dir() {
        for entry in std::fs::read_dir(source)
            .map_err(|e| format!("read evidence directory {}: {e}", source.display()))?
        {
            validate_tree_no_symlinks(
                &entry
                    .map_err(|e| format!("read evidence entry: {e}"))?
                    .path(),
            )?;
        }
    } else if !metadata.is_file() {
        return Err(format!(
            "unsupported evidence tree entry: {}",
            source.display()
        ));
    }
    Ok(())
}

fn digest(path: &Path) -> Result<FileDigest, String> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|e| format!("stat evidence source {}: {e}", path.display()))?;
    if metadata.file_type().is_symlink() {
        return Err(format!("evidence source is a symlink: {}", path.display()));
    }
    let mut file = std::fs::File::open(path)
        .map_err(|e| format!("open evidence source {}: {e}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|e| format!("read evidence source {}: {e}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(FileDigest {
        path: path.display().to_string(),
        package_path: String::new(),
        sha256: format!("{:x}", hasher.finalize()),
    })
}

fn copy_artifact(source: &Path, destination: &Path, staging: &Path) -> Result<FileDigest, String> {
    let mut source_digest = digest(source)?;
    std::fs::create_dir_all(
        destination
            .parent()
            .ok_or("artifact destination has no parent")?,
    )
    .map_err(|e| format!("create artifact directory: {e}"))?;
    copy_file_create_only(source, destination)
        .map_err(|e| format!("copy capture artifact {}: {e}", source.display()))?;
    let copied = digest(destination)?;
    if copied.sha256 != source_digest.sha256 {
        return Err(format!(
            "capture artifact hash changed during copy: {}",
            source.display()
        ));
    }
    source_digest.package_path = destination
        .strip_prefix(staging)
        .map_err(|_| "artifact destination escaped package staging")?
        .to_string_lossy()
        .to_string();
    Ok(source_digest)
}

fn copy_tree_no_symlinks(source: &Path, destination: &Path) -> Result<(), String> {
    let metadata = std::fs::symlink_metadata(source)
        .map_err(|e| format!("stat evidence tree {}: {e}", source.display()))?;
    if metadata.file_type().is_symlink() {
        return Err(format!(
            "evidence tree contains symlink: {}",
            source.display()
        ));
    }
    if metadata.is_dir() {
        std::fs::create_dir(destination)
            .map_err(|e| format!("create evidence directory {}: {e}", destination.display()))?;
        for entry in std::fs::read_dir(source)
            .map_err(|e| format!("read evidence directory {}: {e}", source.display()))?
        {
            let entry = entry.map_err(|e| format!("read evidence entry: {e}"))?;
            copy_tree_no_symlinks(&entry.path(), &destination.join(entry.file_name()))?;
        }
    } else if metadata.is_file() {
        copy_file_create_only(source, destination)
            .map_err(|e| format!("copy evidence file {}: {e}", source.display()))?;
    } else {
        return Err(format!(
            "unsupported evidence tree entry: {}",
            source.display()
        ));
    }
    Ok(())
}

fn copy_file_create_only(source: &Path, destination: &Path) -> Result<(), String> {
    let mut input = std::fs::File::open(source)
        .map_err(|e| format!("open source {}: {e}", source.display()))?;
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)
        .map_err(|e| format!("create-only destination {}: {e}", destination.display()))?;
    std::io::copy(&mut input, &mut output)
        .map_err(|e| format!("copy into {}: {e}", destination.display()))?;
    output
        .sync_all()
        .map_err(|e| format!("sync destination {}: {e}", destination.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn temp_root() -> PathBuf {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "scanstudio-evidence-test-{}-{n}",
            crate::manifest::generate_project_id()
        ))
    }

    fn write(path: &Path, bytes: &[u8]) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }

    fn frame(root: &Path) -> EvidenceFrame {
        let attempt = root.join("attempt-1");
        let rgb = attempt.join("capture/rgb.tif");
        let ir = attempt.join("capture/ir.tif");
        let meter = attempt.join("capture/meter.tif");
        let selected_pixels = attempt.join("journal/selected-pixels.bin");
        write(&rgb, b"rgb");
        write(&ir, b"ir");
        write(&meter, b"meter");
        write(&attempt.join("journal/events.jsonl"), b"receipt\n");
        write(&selected_pixels, b"selected-pixels");
        EvidenceFrame {
            frame_index: 1,
            rgb_path: rgb,
            ir_path: Some(ir),
            meter_path: Some(meter),
            bridge_receipt: serde_json::json!({
                "attemptsRoot": attempt,
                "nikonBuilderInputs": {
                    "selectedPixelsPath": selected_pixels,
                },
            }),
            engine_receipt: serde_json::json!({
                "receipt": {
                    "frameIndex": 1,
                    "nikonBuilderInputs": {
                        "selectedPixelsPath": selected_pixels,
                    },
                },
            }),
            attempts_root: Some(attempt),
        }
    }

    #[test]
    fn package_copies_exact_attempt_tree_hashes_files_and_is_create_only() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let evidence = frame(&attempts);
        let result = finalize_with_expected_root(
            &destination,
            "job-1",
            &[evidence.clone()],
            &serde_json::json!({"dpi": 4000}),
            &attempts,
        )
        .unwrap();
        assert_eq!(result.status, "complete");
        let final_dir = PathBuf::from(result.path.unwrap());
        assert!(final_dir
            .join("attempts/session-0001/journal/events.jsonl")
            .is_file());
        assert_eq!(
            std::fs::read(final_dir.join("artifacts/frame-0001/rgb.tif")).unwrap(),
            b"rgb"
        );
        assert_eq!(
            std::fs::read(final_dir.join("artifacts/frame-0001/ir.tif")).unwrap(),
            b"ir"
        );
        assert_eq!(
            std::fs::read(final_dir.join("artifacts/frame-0001/meter.tif")).unwrap(),
            b"meter"
        );
        assert_eq!(
            std::fs::read(&evidence.rgb_path).unwrap(),
            b"rgb",
            "sources are copied, never moved"
        );
        let manifest: serde_json::Value =
            serde_json::from_slice(&std::fs::read(final_dir.join("manifest.json")).unwrap())
                .unwrap();
        assert_eq!(manifest["schemaVersion"], 2);
        assert_eq!(
            manifest["frames"][0]["rgb"]["sha256"],
            serde_json::json!(digest(&evidence.rgb_path).unwrap().sha256)
        );
        assert_eq!(
            manifest["frames"][0]["rgb"]["packagePath"],
            "artifacts/frame-0001/rgb.tif"
        );
        assert_eq!(
            manifest["frames"][0]["journalRoot"],
            "attempts/session-0001"
        );
        assert_eq!(
            manifest["frames"][0]["bridgeReceipt"]["attemptsRoot"],
            "attempts/session-0001"
        );
        assert_eq!(
            manifest["frames"][0]["bridgeReceipt"]["nikonBuilderInputs"]
                ["selectedPixelsPath"],
            "attempts/session-0001/journal/selected-pixels.bin"
        );
        assert_eq!(
            manifest["frames"][0]["engineReceipt"]["receipt"]["nikonBuilderInputs"]
                ["selectedPixelsPath"],
            "attempts/session-0001/journal/selected-pixels.bin"
        );
        assert_eq!(
            manifest["frames"][0]["sourceProvenance"]["attemptsRoot"],
            evidence.attempts_root.as_ref().unwrap().display().to_string()
        );
        assert_eq!(
            manifest["frames"][0]["sourceProvenance"]["bridgeSelectedPixelsPath"],
            evidence.bridge_receipt["nikonBuilderInputs"]["selectedPixelsPath"]
        );
        assert!(
            finalize_with_expected_root(
                &destination,
                "job-1",
                &[evidence],
                &serde_json::json!({}),
                &attempts
            )
            .is_err(),
            "existing final package is never overwritten"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    /// A job that ends in failure (e.g. a bridge `scan.error` such as
    /// `BATCH_INTEGRITY_ERROR`) must leave the terminal reason somewhere in
    /// the evidence package itself, not only in engine stderr. Exercises
    /// `finalize_with_optional_expected_root`'s `base_error` plumbing
    /// directly -- the same seam `finalize`'s new `terminal_error` parameter
    /// feeds into -- without needing the full bridge/mock_bridge subprocess
    /// harness real_backend.rs's own job-failure paths require.
    #[test]
    fn a_terminal_job_error_is_recorded_in_the_manifest_and_forces_incomplete() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let evidence = frame(&attempts);
        let result = finalize_with_optional_expected_root(
            &destination,
            "job-terminal-error",
            &[evidence],
            &serde_json::json!({"dpi": 4000}),
            Some(&attempts),
            Some("bridge scan.error (BATCH_INTEGRITY_ERROR): slot count mismatch".to_string()),
        )
        .unwrap();
        assert_eq!(
            result.status, "incomplete",
            "a terminal job error must force the package incomplete even if every attempted frame's own artifacts were fine"
        );
        assert!(
            result.detail.contains("BATCH_INTEGRITY_ERROR"),
            "detail must name the terminal error: {}",
            result.detail
        );
        let manifest: serde_json::Value = serde_json::from_slice(
            &std::fs::read(PathBuf::from(result.path.unwrap()).join("manifest.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(manifest["status"], "incomplete");
        assert!(manifest["detail"]
            .as_str()
            .unwrap()
            .contains("BATCH_INTEGRITY_ERROR"));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn frames_from_one_bridge_session_share_one_exact_journal_copy() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let first = frame(&attempts);
        let mut second = first.clone();
        second.frame_index = 2;
        second.engine_receipt = serde_json::json!({"frameIndex": 2});
        let second_artifacts = root.join("second-frame");
        second.rgb_path = second_artifacts.join("rgb.tif");
        second.ir_path = Some(second_artifacts.join("ir.tif"));
        second.meter_path = Some(second_artifacts.join("meter.tif"));
        write(&second.rgb_path, b"rgb-2");
        write(second.ir_path.as_ref().unwrap(), b"ir-2");
        write(second.meter_path.as_ref().unwrap(), b"meter-2");

        let result = finalize_with_expected_root(
            &destination,
            "shared-session",
            &[first, second],
            &serde_json::json!({"dpi": 4000}),
            &attempts,
        )
        .unwrap();
        assert_eq!(result.status, "complete");
        let package = PathBuf::from(result.path.unwrap());
        let journal_directories = std::fs::read_dir(package.join("attempts"))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(journal_directories.len(), 1);
        assert_eq!(
            std::fs::read(package.join("attempts/session-0001/journal/events.jsonl")).unwrap(),
            b"receipt\n"
        );
        let manifest: serde_json::Value =
            serde_json::from_slice(&std::fs::read(package.join("manifest.json")).unwrap()).unwrap();
        assert_eq!(
            manifest["frames"][0]["journalRoot"],
            "attempts/session-0001"
        );
        assert_eq!(
            manifest["frames"][1]["journalRoot"],
            "attempts/session-0001"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn missing_or_outside_attempt_roots_are_explicitly_incomplete_or_rejected() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let mut evidence = frame(&attempts);
        evidence.attempts_root = None;
        let incomplete = finalize_with_expected_root(
            &destination,
            "missing",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .unwrap();
        assert_eq!(incomplete.status, "incomplete");
        let incomplete_manifest: serde_json::Value = serde_json::from_slice(
            &std::fs::read(PathBuf::from(incomplete.path.unwrap()).join("manifest.json")).unwrap(),
        )
        .unwrap();
        assert!(incomplete_manifest["frames"][0]["journalRoot"].is_null());
        let outside = root.join("outside");
        let evidence = frame(&outside);
        let outside_result = finalize_with_expected_root(
            &destination,
            "outside",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .unwrap();
        assert_eq!(outside_result.status, "incomplete");
        assert!(finalize_with_expected_root(
            &destination,
            "../escape",
            &[],
            &serde_json::json!({}),
            &attempts
        )
        .is_err());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn pinned_wsl_attempts_parser_accepts_only_one_direct_session_child() {
        let valid =
            Path::new(r"\\wsl$\Ubuntu-24.04\home\rohan\.scanstudio\coolscanpy-attempts\roll-abc");
        let parsed = parse_pinned_wsl_attempts_root(valid)
            .expect("pinned WSL path should parse")
            .expect("pinned WSL path should select the WSL validator");
        assert_eq!(parsed.input, valid);
        assert_eq!(
            parsed.base.file_name().and_then(|value| value.to_str()),
            Some("coolscanpy-attempts")
        );

        for refused in [
            r"\\wsl$\Ubuntu-22.04\home\rohan\.scanstudio\coolscanpy-attempts\roll-abc",
            r"\\wsl.localhost\Ubuntu-24.04\home\rohan\.scanstudio\coolscanpy-attempts\roll-abc",
            r"\\wsl$\Ubuntu-24.04\home\rohan\.scanstudio\coolscanpy-attempts\..",
            r"\\wsl$\Ubuntu-24.04\home\rohan\.scanstudio\coolscanpy-attempts\roll-abc\nested",
            r"\\wsl$\Ubuntu-24.04\home\rohan\.scanstudio\coolscanpy-attempts\roll/abc",
        ] {
            assert!(
                parse_pinned_wsl_attempts_root(Path::new(refused)).is_err(),
                "unsafe or unpinned WSL route must fail closed: {refused}"
            );
        }
        assert!(
            parse_pinned_wsl_attempts_root(Path::new("/tmp/native-attempt"))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn canonical_attempt_validation_accepts_direct_child_and_rejects_nested_child() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let direct = attempts.join("session");
        let nested = direct.join("nested");
        std::fs::create_dir_all(&nested).unwrap();

        assert_eq!(
            validate_attempts_root(&direct, &attempts).unwrap(),
            std::fs::canonicalize(&direct).unwrap()
        );
        assert!(validate_attempts_root(&nested, &attempts).is_err());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn canonical_attempt_validation_rejects_a_symlink_outside_the_base() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let attempts = root.join("attempts");
        let outside = root.join("outside");
        std::fs::create_dir_all(&attempts).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let link = attempts.join("session-link");
        symlink(&outside, &link).unwrap();

        assert!(validate_attempts_root(&link, &attempts).is_err());
        assert!(validate_directory_route_no_symlinks(&[attempts, link]).is_err());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn disappeared_direct_child_journal_still_promotes_incomplete_artifacts() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let mut evidence = frame(&attempts);
        let journal_root = evidence.attempts_root.clone().unwrap();
        std::fs::remove_dir_all(&journal_root).unwrap();
        // Capture artifacts are independently supplied by their exact receipt
        // paths in production. Recreate only those, not the missing journal.
        let artifacts = root.join("surviving");
        evidence.rgb_path = artifacts.join("rgb.tif");
        evidence.ir_path = None;
        evidence.meter_path = None;
        write(&evidence.rgb_path, b"rgb");
        let result = finalize_with_expected_root(
            &destination,
            "disappeared",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .unwrap();
        assert_eq!(result.status, "incomplete");
        let package = PathBuf::from(result.path.unwrap());
        assert_eq!(
            std::fs::read(package.join("artifacts/frame-0001/rgb.tif")).unwrap(),
            b"rgb"
        );
        assert!(package.join("manifest.json").is_file());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_evidence_is_rejected_without_promoting_a_manifest() {
        use std::os::unix::fs::symlink;
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let mut evidence = frame(&attempts);
        let link = attempts.join("attempt-1/capture/rgb.tif");
        std::fs::remove_file(&link).unwrap();
        symlink("/etc/hosts", &link).unwrap();
        evidence.rgb_path = link;
        assert!(finalize_with_expected_root(
            &destination,
            "symlink",
            &[evidence],
            &serde_json::json!({}),
            &attempts
        )
        .is_err());
        assert!(!destination
            .join("Capture Evidence/symlink.scanstudio/manifest.json")
            .exists());
        let _ = std::fs::remove_dir_all(root);
    }
}
