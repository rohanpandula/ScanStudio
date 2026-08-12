//! Create-only, job-scoped capture evidence packages. This module never
//! drives hardware and never rewrites bridge-owned source artifacts.

use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};

use serde::Serialize;
use sha2::{Digest, Sha256};

const MAX_EVIDENCE_ARTIFACT_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const MAX_EVIDENCE_JOURNAL_FILE_BYTES: u64 = 64 * 1024 * 1024;
const MAX_EVIDENCE_JOURNAL_BYTES: u64 = 256 * 1024 * 1024;
const MAX_EVIDENCE_JOURNAL_ENTRIES: u64 = 16_384;
const MAX_EVIDENCE_JOURNAL_DEPTH: usize = 64;
const MAX_EVIDENCE_MANIFEST_BYTES: usize = 64 * 1024 * 1024;
const PINNED_WSL_DISTRO: &str = "Ubuntu-24.04";

#[derive(Debug, Clone, PartialEq, Eq)]
struct PinnedWslAttemptsPath {
    base: PathBuf,
    input: PathBuf,
    checked_ancestors: Vec<PathBuf>,
}

#[derive(Debug, Clone, Copy)]
struct JournalLimits {
    max_file_bytes: u64,
    max_total_bytes: u64,
    max_entries: u64,
    max_depth: usize,
}

const EVIDENCE_JOURNAL_LIMITS: JournalLimits = JournalLimits {
    max_file_bytes: MAX_EVIDENCE_JOURNAL_FILE_BYTES,
    max_total_bytes: MAX_EVIDENCE_JOURNAL_BYTES,
    max_entries: MAX_EVIDENCE_JOURNAL_ENTRIES,
    max_depth: MAX_EVIDENCE_JOURNAL_DEPTH,
};

#[derive(Debug, Default)]
struct JournalCopyBudget {
    entries: u64,
    bytes: u64,
}

impl JournalCopyBudget {
    fn record_entry(
        &mut self,
        source: &Path,
        file_bytes: u64,
        limits: JournalLimits,
    ) -> Result<(), String> {
        let entries = self
            .entries
            .checked_add(1)
            .ok_or("evidence journal entry count overflow")?;
        if entries > limits.max_entries {
            return Err(format!(
                "evidence journal exceeds the {} entry limit at {}",
                limits.max_entries,
                source.display()
            ));
        }
        if file_bytes > limits.max_file_bytes {
            return Err(format!(
                "evidence journal file exceeds the {} byte limit: {}",
                limits.max_file_bytes,
                source.display()
            ));
        }
        let bytes = self
            .bytes
            .checked_add(file_bytes)
            .ok_or("evidence journal aggregate byte count overflow")?;
        if bytes > limits.max_total_bytes {
            return Err(format!(
                "evidence journals exceed the {} aggregate byte limit at {}",
                limits.max_total_bytes,
                source.display()
            ));
        }
        self.entries = entries;
        self.bytes = bytes;
        Ok(())
    }
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
    /// Exact live paths before package rebasing. Receipt copies are
    /// self-contained; provenance remains explicit for later audit.
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
/// closure that isn't a clean completion), is folded into `base_error` — the
/// same mechanism `finalize_into` uses to mark a package `incomplete` and
/// explain why. Native HOME is optional on the Windows port; each receipt's
/// pinned WSL attempts route is validated independently below.
pub(crate) fn finalize(
    package: &crate::render::ReservedEvidencePackage,
    job_id: &str,
    frames: &[EvidenceFrame],
    effective_settings: &serde_json::Value,
    terminal_error: Option<&str>,
) -> Result<EvidencePackageResult, String> {
    let expected_root = expected_attempts_root().ok();
    finalize_with_optional_expected_root(
        package,
        job_id,
        frames,
        effective_settings,
        expected_root.as_deref(),
        terminal_error.map(str::to_string),
    )
}

#[cfg(test)]
pub(crate) fn finalize_with_expected_root(
    package: &crate::render::ReservedEvidencePackage,
    job_id: &str,
    frames: &[EvidenceFrame],
    effective_settings: &serde_json::Value,
    expected_root: &Path,
) -> Result<EvidencePackageResult, String> {
    finalize_with_optional_expected_root(
        package,
        job_id,
        frames,
        effective_settings,
        Some(expected_root),
        None,
    )
}

fn finalize_with_optional_expected_root(
    package: &crate::render::ReservedEvidencePackage,
    job_id: &str,
    frames: &[EvidenceFrame],
    effective_settings: &serde_json::Value,
    expected_root: Option<&Path>,
    base_error: Option<String>,
) -> Result<EvidencePackageResult, String> {
    validate_job_id(job_id)?;
    if package.job_id() != job_id {
        return Err("held evidence package authority belongs to a different jobId".into());
    }
    package
        .verify_namespace()
        .map_err(|error| format!("verify held evidence package authority: {error}"))?;
    let (status, detail) = finalize_into(
        package,
        job_id,
        frames,
        effective_settings,
        expected_root,
        base_error,
    )?;
    Ok(EvidencePackageResult {
        status,
        path: Some(package.final_path().display().to_string()),
        detail,
    })
}

const BRIDGE_SELECTED_PIXELS_POINTER: &str = "/nikonBuilderInputs/selectedPixelsPath";
const ENGINE_SELECTED_PIXELS_POINTER: &str = "/receipt/nikonBuilderInputs/selectedPixelsPath";

fn json_string_at(value: &serde_json::Value, pointer: &str) -> Option<String> {
    value
        .pointer(pointer)
        .and_then(|value| value.as_str())
        .map(str::to_string)
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
    if metadata_is_link_or_reparse(&metadata) || !metadata.is_file() {
        return Err(format!(
            "selected-pixels source is not a regular non-link file: {source:?}"
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
        let std::path::Component::Normal(value) = component else {
            return Err("selected-pixels package path contains an unsafe component".into());
        };
        validate_portable_component(value).map_err(|error| {
            format!("selected-pixels package path contains an unsafe component: {error}")
        })?;
        components.push(
            value
                .to_str()
                .ok_or("selected-pixels package path is not valid UTF-8")?,
        );
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
    let (Some(validated_attempt), Some(journal_root)) = (validated_attempt, journal_root) else {
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
    package: &crate::render::ReservedEvidencePackage,
    job_id: &str,
    frames: &[EvidenceFrame],
    effective_settings: &serde_json::Value,
    expected_root: Option<&Path>,
    base_error: Option<String>,
) -> Result<(String, String), String> {
    let mut manifests = Vec::with_capacity(frames.len());
    let mut published_files = Vec::<PackageFileProof>::new();
    let mut unavailable = frames.is_empty();
    let mut reasons = Vec::new();
    let mut copied_journals = std::collections::HashMap::<PathBuf, Result<String, String>>::new();
    let mut journal_budget = JournalCopyBudget::default();
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
        let artifact_root =
            PathBuf::from("artifacts").join(format!("frame-{:04}", frame.frame_index));
        let (rgb, rgb_proof) =
            copy_artifact(&frame.rgb_path, &artifact_root.join("rgb.tif"), package)?;
        published_files.push(rgb_proof);
        let ir = frame
            .ir_path
            .as_deref()
            .map(|path| copy_artifact(path, &artifact_root.join("ir.tif"), package))
            .transpose()?;
        let ir = ir.map(|(digest, proof)| {
            published_files.push(proof);
            digest
        });
        let meter = frame
            .meter_path
            .as_deref()
            .map(|path| copy_artifact(path, &artifact_root.join("meter.tif"), package))
            .transpose()?;
        let meter = meter.map(|(digest, proof)| {
            published_files.push(proof);
            digest
        });
        let journal_root = if let Some(root) = validated_attempt.as_ref() {
            let result = if let Some(result) = copied_journals.get(root) {
                result.clone()
            } else {
                let next_index = copied_journals.len() + 1;
                let relative = format!("attempts/session-{next_index:04}");
                let result = copy_tree_no_symlinks(
                    root,
                    Path::new(&relative),
                    package,
                    &mut published_files,
                    &mut journal_budget,
                    0,
                    EVIDENCE_JOURNAL_LIMITS,
                )
                .map(|_| relative);
                copied_journals.insert(root.clone(), result.clone());
                result
            };
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
    let data = serialize_json_bounded(&manifest, MAX_EVIDENCE_MANIFEST_BYTES)?;
    commit_manifest_authoritatively(package, &data, &published_files, || Ok(()))?;
    Ok((status.into(), detail))
}

struct BoundedJsonBuffer {
    bytes: Vec<u8>,
    maximum: usize,
}

impl Write for BoundedJsonBuffer {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let next = self.bytes.len().checked_add(bytes.len()).ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "evidence manifest serialized length overflow",
            )
        })?;
        if next > self.maximum {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "evidence manifest exceeds the {} byte authority limit",
                    self.maximum
                ),
            ));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn serialize_json_bounded<T: Serialize>(value: &T, maximum: usize) -> Result<Vec<u8>, String> {
    let mut output = BoundedJsonBuffer {
        bytes: Vec::new(),
        maximum,
    };
    serde_json::to_writer_pretty(&mut output, value)
        .map_err(|error| format!("serialize bounded evidence manifest: {error}"))?;
    Ok(output.bytes)
}

pub(crate) fn validate_job_id(job_id: &str) -> Result<(), String> {
    let path = Path::new(job_id);
    if job_id.is_empty()
        || path.is_absolute()
        || path.components().count() != 1
        || job_id.contains(['/', '\\'])
    {
        return Err("jobId must be one safe filename component".into());
    }
    validate_portable_component(std::ffi::OsStr::new(job_id))
        .map_err(|error| format!("jobId must be one safe filename component: {error}"))
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
    validate_portable_component(std::ffi::OsStr::new(value)).is_ok()
}

fn validate_pinned_wsl_attempts_root(parsed: PinnedWslAttemptsPath) -> Result<PathBuf, String> {
    let mut checked_route = parsed.checked_ancestors;
    checked_route.push(parsed.input.clone());
    validate_directory_route_no_links(&checked_route)?;
    validate_attempts_root(&parsed.input, &parsed.base)
}

fn validate_directory_route_no_links(route: &[PathBuf]) -> Result<(), String> {
    for path in route {
        let metadata = std::fs::symlink_metadata(path)
            .map_err(|error| format!("inspect WSL evidence route {}: {error}", path.display()))?;
        if metadata_is_link_or_reparse(&metadata) {
            return Err(format!(
                "WSL evidence route contains a symlink or reparse point: {}",
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
    let expected_input_metadata = std::fs::symlink_metadata(expected)
        .map_err(|e| format!("inspect expected attempts root: {e}"))?;
    if metadata_is_link_or_reparse(&expected_input_metadata) || !expected_input_metadata.is_dir() {
        return Err("expected attempts root must be a real directory".into());
    }
    let input_metadata = std::fs::symlink_metadata(input)
        .map_err(|e| format!("inspect bridge attemptsRoot: {e}"))?;
    if metadata_is_link_or_reparse(&input_metadata) || !input_metadata.is_dir() {
        return Err("bridge attemptsRoot must be a real directory".into());
    }
    let expected = std::fs::canonicalize(expected)
        .map_err(|e| format!("canonicalize expected attempts root: {e}"))?;
    let actual = std::fs::canonicalize(input)
        .map_err(|e| format!("canonicalize bridge attemptsRoot: {e}"))?;
    let actual_metadata = std::fs::symlink_metadata(&actual)
        .map_err(|e| format!("inspect canonical bridge attemptsRoot: {e}"))?;
    if metadata_is_link_or_reparse(&actual_metadata) || !actual_metadata.is_dir() {
        return Err("canonical bridge attemptsRoot must be a real directory".into());
    }
    if actual.parent() != Some(expected.as_path()) {
        return Err(
            "bridge attemptsRoot must be a direct child of the canonical attempts base".into(),
        );
    }
    let leaf = actual
        .file_name()
        .ok_or("bridge attemptsRoot has no final component")?;
    validate_portable_component(leaf)
        .map_err(|error| format!("bridge attemptsRoot has an unsafe component: {error}"))?;
    Ok(actual)
}

fn metadata_is_link_or_reparse(metadata: &std::fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt as _;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
        return metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0;
    }
    #[cfg(not(windows))]
    false
}

fn validate_portable_component(component: &std::ffi::OsStr) -> Result<(), String> {
    let value = component
        .to_str()
        .ok_or("component is not valid UTF-8 and cannot be represented safely on Windows")?;
    if value.is_empty() || value == "." || value == ".." {
        return Err("component is empty or relative".into());
    }
    if value.ends_with(['.', ' ']) {
        return Err("component has Windows-ambiguous trailing dot or space".into());
    }
    if value.chars().any(|character| {
        character <= '\u{1f}'
            || matches!(
                character,
                '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
            )
    }) {
        return Err("component contains Windows-forbidden or alternate-stream syntax".into());
    }
    let device_base = value
        .split('.')
        .next()
        .unwrap_or(value)
        .trim_end_matches(['.', ' ']);
    let upper = device_base.to_ascii_uppercase();
    let numbered_device = upper
        .strip_prefix("COM")
        .or_else(|| upper.strip_prefix("LPT"))
        .is_some_and(|suffix| {
            (suffix.len() == 1 && matches!(suffix.as_bytes()[0], b'1'..=b'9'))
                || matches!(suffix, "¹" | "²" | "³")
        });
    if matches!(
        upper.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CLOCK$" | "CONIN$" | "CONOUT$"
    ) || numbered_device
    {
        return Err("component is a reserved Windows device name".into());
    }
    Ok(())
}

#[derive(Debug)]
struct PackageFileProof {
    relative_path: PathBuf,
    file: std::fs::File,
}

fn digest_reader_exact(
    reader: &mut std::fs::File,
    expected_len: u64,
    label: &Path,
) -> Result<String, String> {
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    let mut remaining = expected_len;
    while remaining != 0 {
        let requested = usize::try_from(remaining.min(buffer.len() as u64)).map_err(|_| {
            format!(
                "evidence file length does not fit memory limits: {}",
                label.display()
            )
        })?;
        let count = reader
            .read(&mut buffer[..requested])
            .map_err(|e| format!("read evidence file {}: {e}", label.display()))?;
        if count == 0 {
            return Err(format!(
                "evidence file became shorter than its declared {} bytes: {}",
                expected_len,
                label.display()
            ));
        }
        hasher.update(&buffer[..count]);
        remaining -= count as u64;
    }
    let mut tail = [0_u8; 1];
    if reader
        .read(&mut tail)
        .map_err(|e| format!("check evidence file length {}: {e}", label.display()))?
        != 0
    {
        return Err(format!(
            "evidence file grew beyond its declared {} bytes: {}",
            expected_len,
            label.display()
        ));
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn metadata_is_sparse(metadata: &std::fs::Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        return metadata.len() != 0 && metadata.blocks().saturating_mul(512) < metadata.len();
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt as _;
        const FILE_ATTRIBUTE_SPARSE_FILE: u32 = 0x0000_0200;
        return metadata.file_attributes() & FILE_ATTRIBUTE_SPARSE_FILE != 0;
    }
    #[cfg(not(any(unix, windows)))]
    false
}

fn validate_source_snapshot(
    file: &std::fs::File,
    metadata: &std::fs::Metadata,
    source: &Path,
    max_bytes: u64,
) -> Result<((u64, u64, u64), u64), String> {
    if !metadata.is_file() {
        return Err(format!(
            "evidence source is not a regular file: {}",
            source.display()
        ));
    }
    let identity = crate::exiftool::held_file_identity(file, metadata).ok_or_else(|| {
        format!(
            "cannot establish held evidence source identity: {}",
            source.display()
        )
    })?;
    if identity.2 != 1 {
        return Err(format!(
            "evidence source does not have exactly one hard link: {}",
            source.display()
        ));
    }
    let length = metadata.len();
    if length > max_bytes {
        return Err(format!(
            "evidence source exceeds the {} byte limit: {}",
            max_bytes,
            source.display()
        ));
    }
    if metadata_is_sparse(metadata) {
        return Err(format!(
            "evidence source is sparse and cannot be copied authoritatively: {}",
            source.display()
        ));
    }
    Ok((identity, length))
}

fn open_source_regular_nofollow(path: &Path) -> Result<std::fs::File, String> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt as _;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        const FILE_FLAG_SEQUENTIAL_SCAN: u32 = 0x0800_0000;
        const FILE_SHARE_READ: u32 = 0x0000_0001;
        const FILE_SHARE_WRITE: u32 = 0x0000_0002;
        options
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN);
    }
    let file = options.open(path).map_err(|e| {
        format!(
            "open evidence source without following links {}: {e}",
            path.display()
        )
    })?;
    let metadata = file
        .metadata()
        .map_err(|e| format!("inspect held evidence source {}: {e}", path.display()))?;
    if !metadata.is_file() {
        return Err(format!(
            "evidence source is not a regular file: {}",
            path.display()
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if metadata.nlink() != 1 {
            return Err(format!(
                "evidence source has multiple hard links: {}",
                path.display()
            ));
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt as _;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(format!(
                "evidence source is a Windows reparse point: {}",
                path.display()
            ));
        }
    }
    Ok(file)
}

#[cfg(test)]
fn digest(path: &Path) -> Result<FileDigest, String> {
    let mut file = open_source_regular_nofollow(path)?;
    let metadata = file
        .metadata()
        .map_err(|e| format!("inspect evidence source {}: {e}", path.display()))?;
    let (_, length) =
        validate_source_snapshot(&file, &metadata, path, MAX_EVIDENCE_ARTIFACT_BYTES)?;
    let sha256 = digest_reader_exact(&mut file, length, path)?;
    Ok(FileDigest {
        path: path.display().to_string(),
        package_path: String::new(),
        sha256,
    })
}

fn validate_package_relative(path: &Path) -> Result<Vec<std::ffi::OsString>, String> {
    if path.as_os_str().is_empty() || path.is_absolute() {
        return Err("evidence package path must be a non-empty relative path".into());
    }
    let mut components = Vec::new();
    for component in path.components() {
        let std::path::Component::Normal(component) = component else {
            return Err(format!(
                "evidence package path contains an unsafe component: {}",
                path.display()
            ));
        };
        validate_portable_component(component).map_err(|error| {
            format!(
                "evidence package path contains an unsafe component {:?}: {error}",
                component
            )
        })?;
        components.push(component.to_os_string());
    }
    if components.is_empty() {
        return Err("evidence package path has no components".into());
    }
    Ok(components)
}

fn open_or_create_package_directory(
    package: &crate::render::ReservedEvidencePackage,
    relative: &Path,
) -> Result<std::fs::File, String> {
    package
        .verify_namespace()
        .map_err(|error| format!("verify evidence package namespace: {error}"))?;
    let components = if relative.as_os_str().is_empty() {
        Vec::new()
    } else {
        validate_package_relative(relative)?
    };
    let mut current = package
        .directory_handle()
        .try_clone()
        .map_err(|e| format!("retain held evidence package directory: {e}"))?;
    for component in components {
        let next =
            match crate::exiftool::metadata_publish_sys::open_child_directory(&current, &component)
            {
                Ok(directory) => directory,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    match crate::render::create_evidence_directory_nondestructive(
                        &current, &component,
                    ) {
                        Ok(directory) => {
                            crate::exiftool::metadata_publish_sys::sync_directory(&current)
                                .map_err(|e| format!("sync evidence package directory: {e}"))?;
                            directory
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                            crate::exiftool::metadata_publish_sys::open_child_directory(
                                &current, &component,
                            )
                            .map_err(|e| {
                                format!(
                                    "open raced evidence package directory component {:?}: {e}",
                                    component
                                )
                            })?
                        }
                        Err(error) => {
                            return Err(format!(
                                "create evidence package directory component {:?}: {error}",
                                component
                            ))
                        }
                    }
                }
                Err(error) => {
                    return Err(format!(
                "open evidence package directory component {:?} without following links: {error}",
                component
            ))
                }
            };
        current = next;
    }
    package
        .verify_namespace()
        .map_err(|error| format!("revalidate evidence package namespace: {error}"))?;
    Ok(current)
}

fn create_package_file(
    package: &crate::render::ReservedEvidencePackage,
    relative: &Path,
) -> Result<std::fs::File, String> {
    let components = validate_package_relative(relative)?;
    let (leaf, parent_components) = components
        .split_last()
        .ok_or("evidence package file has no leaf")?;
    let mut parent_relative = PathBuf::new();
    for component in parent_components {
        parent_relative.push(component);
    }
    let parent = open_or_create_package_directory(package, &parent_relative)?;
    let file =
        crate::exiftool::metadata_publish_sys::create_new_regular(&parent, leaf).map_err(|e| {
            format!(
                "create-only evidence package file {}: {e}",
                relative.display()
            )
        })?;
    crate::exiftool::metadata_publish_sys::sync_directory(&parent)
        .map_err(|e| format!("sync evidence file parent {}: {e}", relative.display()))?;
    package
        .verify_namespace()
        .map_err(|error| format!("revalidate evidence package after file creation: {error}"))?;
    Ok(file)
}

fn cleanup_staged_manifest(
    package: &crate::render::ReservedEvidencePackage,
    temporary_name: &std::ffi::OsStr,
    staged: &std::fs::File,
) -> Result<(), String> {
    package
        .retire_exact_root_file(temporary_name, staged)
        .map_err(|error| error.message)
}

fn rollback_committed_manifest(
    package: &crate::render::ReservedEvidencePackage,
    manifest_file: &std::fs::File,
) -> Result<(), String> {
    package
        .retire_exact_root_file(std::ffi::OsStr::new("manifest.json"), manifest_file)
        .map_err(|error| error.message)
}

fn commit_manifest_authoritatively<F>(
    package: &crate::render::ReservedEvidencePackage,
    data: &[u8],
    published_files: &[PackageFileProof],
    after_commit: F,
) -> Result<(), String>
where
    F: FnOnce() -> Result<(), String>,
{
    for proof in published_files {
        package
            .verify_regular_file(&proof.relative_path, &proof.file)
            .map_err(|error| {
                format!("verify packaged evidence before manifest staging: {error}")
            })?;
    }
    package.verify_namespace().map_err(|error| {
        format!("verify held evidence package before manifest staging: {error}")
    })?;

    let temporary_name = std::ffi::OsString::from(format!(
        ".manifest-{}.tmp",
        crate::manifest::generate_project_id()
    ));
    validate_portable_component(&temporary_name)
        .map_err(|error| format!("generate safe evidence manifest staging name: {error}"))?;
    let temporary_relative = PathBuf::from(&temporary_name);
    let mut manifest_file = create_package_file(package, &temporary_relative)?;
    let staged = (|| -> Result<(), String> {
        manifest_file
            .write_all(data)
            .map_err(|e| format!("write staged evidence manifest: {e}"))?;
        manifest_file
            .sync_all()
            .map_err(|e| format!("sync staged evidence manifest: {e}"))?;
        package
            .verify_regular_file(&temporary_relative, &manifest_file)
            .map_err(|error| format!("verify staged evidence manifest identity: {error}"))?;
        for proof in published_files {
            package
                .verify_regular_file(&proof.relative_path, &proof.file)
                .map_err(|error| {
                    format!("verify packaged evidence before manifest commit: {error}")
                })?;
        }
        package.verify_namespace().map_err(|error| {
            format!("verify held evidence package before manifest commit: {error}")
        })?;
        Ok(())
    })();
    if let Err(error) = staged {
        return match cleanup_staged_manifest(package, &temporary_name, &manifest_file) {
            Ok(()) => Err(error),
            Err(cleanup) => Err(format!(
                "{error}; HOLD: staged evidence manifest cleanup could not be proven: {cleanup}"
            )),
        };
    }

    if let Err(error) = crate::exiftool::metadata_publish_sys::rename_exclusive(
        package.directory_handle(),
        &temporary_name,
        package.directory_handle(),
        std::ffi::OsStr::new("manifest.json"),
    ) {
        let primary = format!("create-only authoritative evidence manifest commit: {error}");
        return match cleanup_staged_manifest(package, &temporary_name, &manifest_file) {
            Ok(()) => Err(primary),
            Err(cleanup) => Err(format!(
                "{primary}; HOLD: staged evidence manifest cleanup could not be proven: {cleanup}"
            )),
        };
    }

    // The exclusive rename above is the namespace commit point. A later
    // ordering or identity error is never reported as success. First attempt
    // a held-directory, exact-identity rollback; preserve any namespace whose
    // identity or durability cannot be proved and surface an explicit HOLD.
    let post_commit = (|| -> Result<(), String> {
        after_commit()?;
        crate::exiftool::metadata_publish_sys::sync_directory(package.directory_handle())
            .map_err(|e| format!("sync committed evidence package directory: {e}"))?;
        package
            .verify_regular_file(Path::new("manifest.json"), &manifest_file)
            .map_err(|error| format!("verify committed evidence manifest identity: {error}"))?;
        package.verify_namespace().map_err(|error| {
            format!("verify held evidence package after manifest commit: {error}")
        })?;
        Ok(())
    })();
    match post_commit {
        Ok(()) => Ok(()),
        Err(primary) => match rollback_committed_manifest(package, &manifest_file) {
            Ok(()) => Err(format!(
                "{primary}; authoritative manifest was rolled back and completion was not reported"
            )),
            Err(rollback) => Err(format!(
                "{primary}; HOLD: committed manifest rollback could not be proven: {rollback}"
            )),
        },
    }
}

#[derive(Debug, Clone, Copy)]
struct SourceSnapshot {
    identity: (u64, u64, u64),
    length: u64,
}

fn held_source_snapshot(
    file: &std::fs::File,
    source: &Path,
    max_bytes: u64,
) -> Result<SourceSnapshot, String> {
    let metadata = file
        .metadata()
        .map_err(|e| format!("inspect held evidence source {}: {e}", source.display()))?;
    let (identity, length) = validate_source_snapshot(file, &metadata, source, max_bytes)?;
    Ok(SourceSnapshot { identity, length })
}

fn copy_held_artifact_with_hook<F>(
    mut input: std::fs::File,
    snapshot: SourceSnapshot,
    source: &Path,
    destination: &Path,
    package: &crate::render::ReservedEvidencePackage,
    after_snapshot: F,
) -> Result<(FileDigest, PackageFileProof), String>
where
    F: FnOnce() -> Result<(), String>,
{
    after_snapshot()?;
    let mut output = create_package_file(package, destination)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    let mut remaining = snapshot.length;
    while remaining != 0 {
        let requested = usize::try_from(remaining.min(buffer.len() as u64)).map_err(|_| {
            format!(
                "capture artifact length does not fit memory limits: {}",
                source.display()
            )
        })?;
        let count = input
            .read(&mut buffer[..requested])
            .map_err(|e| format!("read capture artifact {}: {e}", source.display()))?;
        if count == 0 {
            return Err(format!(
                "capture artifact became shorter than its declared {} bytes: {}",
                snapshot.length,
                source.display()
            ));
        }
        output
            .write_all(&buffer[..count])
            .map_err(|e| format!("copy capture artifact into {}: {e}", destination.display()))?;
        hasher.update(&buffer[..count]);
        remaining -= count as u64;
    }
    let mut tail = [0_u8; 1];
    if input
        .read(&mut tail)
        .map_err(|e| format!("check capture artifact length {}: {e}", source.display()))?
        != 0
    {
        return Err(format!(
            "capture artifact grew beyond its declared {} bytes: {}",
            snapshot.length,
            source.display()
        ));
    }
    let after_metadata = input
        .metadata()
        .map_err(|e| format!("reinspect held evidence source {}: {e}", source.display()))?;
    let (after_identity, after_length) =
        validate_source_snapshot(&input, &after_metadata, source, snapshot.length)?;
    if after_identity != snapshot.identity || after_length != snapshot.length {
        return Err(format!(
            "capture artifact identity or length changed during copy: {}",
            source.display()
        ));
    }
    output
        .sync_all()
        .map_err(|e| format!("sync capture artifact {}: {e}", destination.display()))?;
    let output_metadata = output
        .metadata()
        .map_err(|e| format!("inspect packaged artifact {}: {e}", destination.display()))?;
    if output_metadata.len() != snapshot.length {
        return Err(format!(
            "packaged artifact length differs from its held source: {}",
            destination.display()
        ));
    }
    let source_hash = format!("{:x}", hasher.finalize());
    output
        .seek(std::io::SeekFrom::Start(0))
        .map_err(|e| format!("rewind packaged artifact {}: {e}", destination.display()))?;
    let copied_hash = digest_reader_exact(&mut output, snapshot.length, destination)?;
    if copied_hash != source_hash {
        return Err(format!(
            "capture artifact hash changed during copy: {}",
            source.display()
        ));
    }
    output.seek(std::io::SeekFrom::Start(0)).map_err(|e| {
        format!(
            "rewind held packaged artifact {}: {e}",
            destination.display()
        )
    })?;
    Ok((
        FileDigest {
            path: source.display().to_string(),
            package_path: destination.to_string_lossy().to_string(),
            sha256: source_hash,
        },
        PackageFileProof {
            relative_path: destination.to_path_buf(),
            file: output,
        },
    ))
}

fn copy_artifact(
    source: &Path,
    destination: &Path,
    package: &crate::render::ReservedEvidencePackage,
) -> Result<(FileDigest, PackageFileProof), String> {
    let input = open_source_regular_nofollow(source)?;
    let snapshot = held_source_snapshot(&input, source, MAX_EVIDENCE_ARTIFACT_BYTES)?;
    copy_held_artifact_with_hook(input, snapshot, source, destination, package, || Ok(()))
}

fn copy_tree_no_symlinks(
    source: &Path,
    destination: &Path,
    package: &crate::render::ReservedEvidencePackage,
    published_files: &mut Vec<PackageFileProof>,
    budget: &mut JournalCopyBudget,
    depth: usize,
    limits: JournalLimits,
) -> Result<(), String> {
    // The destination is always held and handle-relative. Journal sources are
    // reopened no-follow and copied to an exact snapshotted length, but their
    // ancestor traversal still begins in the OS-private bridge scratch
    // namespace. An already-running malicious same-UID Unix process remains
    // able to race that source namespace; closing that residual requires the
    // live bridge to transfer file descriptors or run in a stronger sandbox.
    if depth > limits.max_depth {
        return Err(format!(
            "evidence journal exceeds the {} level depth limit at {}",
            limits.max_depth,
            source.display()
        ));
    }
    let metadata = std::fs::symlink_metadata(source)
        .map_err(|e| format!("stat evidence tree {}: {e}", source.display()))?;
    if metadata_is_link_or_reparse(&metadata) {
        return Err(format!(
            "evidence tree contains symlink: {}",
            source.display()
        ));
    }
    if metadata.is_dir() {
        budget.record_entry(source, 0, limits)?;
        open_or_create_package_directory(package, destination)?;
        for entry in std::fs::read_dir(source)
            .map_err(|e| format!("read evidence directory {}: {e}", source.display()))?
        {
            let entry = entry.map_err(|e| format!("read evidence entry: {e}"))?;
            let file_name = entry.file_name();
            validate_portable_component(&file_name).map_err(|error| {
                format!(
                    "evidence journal contains an unsafe imported component {:?}: {error}",
                    file_name
                )
            })?;
            copy_tree_no_symlinks(
                &entry.path(),
                &destination.join(&file_name),
                package,
                published_files,
                budget,
                depth.saturating_add(1),
                limits,
            )?;
        }
    } else if metadata.is_file() {
        let input = open_source_regular_nofollow(source)?;
        let snapshot = held_source_snapshot(&input, source, limits.max_file_bytes)?;
        budget.record_entry(source, snapshot.length, limits)?;
        let (_, proof) =
            copy_held_artifact_with_hook(input, snapshot, source, destination, package, || Ok(()))
                .map_err(|e| format!("copy evidence file {}: {e}", source.display()))?;
        published_files.push(proof);
    } else {
        return Err(format!(
            "unsupported evidence tree entry: {}",
            source.display()
        ));
    }
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

    fn unreserved_authorities(
        project: &Path,
        destination: &Path,
    ) -> crate::render::JobOutputAuthorities {
        std::fs::create_dir_all(project).unwrap();
        let mut output = crate::domain::OutputRecipe::default();
        output.archive.destination = destination.display().to_string();
        output.archive.filename_template = "master.tif".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        crate::render::acquire_job_output_authorities(
            Some(project),
            &[1],
            &crate::domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .unwrap()
    }

    fn reserved_authorities(
        project: &Path,
        destination: &Path,
        job_id: &str,
    ) -> crate::render::JobOutputAuthorities {
        let mut authorities = unreserved_authorities(project, destination);
        authorities.reserve_evidence_packages(job_id).unwrap();
        authorities
    }

    fn only_package(
        authorities: &crate::render::JobOutputAuthorities,
    ) -> &crate::render::ReservedEvidencePackage {
        assert_eq!(authorities.reserved_evidence_packages().len(), 1);
        &authorities.reserved_evidence_packages()[0]
    }

    #[test]
    fn portable_components_reject_ads_devices_and_windows_normalization() {
        for unsafe_component in [
            "file:stream",
            "CON",
            "con.txt",
            "PRN.log",
            "COM1",
            "lpt9.jsonl",
            "CLOCK$",
            "clock$.txt",
            "CONIN$",
            "conout$.log",
            "COM¹",
            "LPT³.txt",
            "name.",
            "name ",
            "question?mark",
            "bad\0name",
        ] {
            assert!(
                validate_portable_component(std::ffi::OsStr::new(unsafe_component)).is_err(),
                "{unsafe_component:?} must be rejected on every host platform"
            );
            assert!(
                validate_job_id(unsafe_component).is_err(),
                "unsafe portable component must also be rejected as a jobId"
            );
        }
        for safe_component in ["job-1", "capture.tif", "attempt_0001"] {
            validate_portable_component(std::ffi::OsStr::new(safe_component)).unwrap();
            validate_job_id(safe_component).unwrap();
        }
    }

    #[test]
    fn pinned_wsl_attempts_parser_accepts_only_one_portable_direct_session_child() {
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
            r"\\wsl$\Ubuntu-24.04\home\CON\.scanstudio\coolscanpy-attempts\roll-abc",
            r"\\wsl$\Ubuntu-24.04\home\rohan\.scanstudio\coolscanpy-attempts\roll.",
            r"\\wsl$\Ubuntu-24.04\home\rohan\.scanstudio\coolscanpy-attempts\file:stream",
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
        assert!(
            validate_frame_attempts_root(Path::new("/tmp/native-attempt"), None)
                .unwrap_err()
                .contains("native attempts root is unavailable")
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
    fn wsl_route_validation_rejects_links_before_canonicalization() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let attempts = root.join("attempts");
        let outside = root.join("outside");
        std::fs::create_dir_all(&attempts).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let link = attempts.join("session-link");
        symlink(&outside, &link).unwrap();

        assert!(validate_attempts_root(&link, &attempts).is_err());
        assert!(validate_directory_route_no_links(&[attempts, link]).is_err());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn attempts_root_must_be_a_directory() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let mut evidence = frame(&attempts);
        let file_root = attempts.join("not-a-directory");
        write(&file_root, b"not a journal tree");
        evidence.attempts_root = Some(file_root);
        let authorities = reserved_authorities(&root, &destination, "attempt-file");

        let result = finalize_with_expected_root(
            only_package(&authorities),
            "attempt-file",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .unwrap();
        assert_eq!(result.status, "incomplete");
        assert!(result.detail.contains("real directory"));
        let manifest: serde_json::Value = serde_json::from_slice(
            &std::fs::read(PathBuf::from(result.path.unwrap()).join("manifest.json")).unwrap(),
        )
        .unwrap();
        assert!(manifest["frames"][0]["journalRoot"].is_null());

        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn unsafe_imported_journal_component_is_omitted_cross_platform() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let evidence = frame(&attempts);
        write(
            &attempts.join("attempt-1/journal/receipt:alternate-stream"),
            b"unsafe",
        );
        let authorities = reserved_authorities(&root, &destination, "unsafe-journal-name");

        let result = finalize_with_expected_root(
            only_package(&authorities),
            "unsafe-journal-name",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .unwrap();
        assert_eq!(result.status, "incomplete");
        assert!(result.detail.contains("unsafe imported component"));
        let package = PathBuf::from(result.path.unwrap());
        let manifest: serde_json::Value =
            serde_json::from_slice(&std::fs::read(package.join("manifest.json")).unwrap()).unwrap();
        assert!(manifest["frames"][0]["journalRoot"].is_null());
        assert!(!package
            .join("attempts/session-0001/journal/receipt:alternate-stream")
            .exists());

        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn sparse_artifact_is_rejected_before_manifest_commit() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let evidence = frame(&attempts);
        let sparse = std::fs::File::create(&evidence.rgb_path).unwrap();
        sparse.set_len(1024 * 1024).unwrap();
        sparse.sync_all().unwrap();
        let authorities = reserved_authorities(&root, &destination, "sparse-artifact");

        let error = finalize_with_expected_root(
            only_package(&authorities),
            "sparse-artifact",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .expect_err("sparse capture data must not become authoritative evidence");
        assert!(error.contains("sparse"));
        assert!(!only_package(&authorities)
            .final_path()
            .join("manifest.json")
            .exists());

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn growing_artifact_copy_is_bounded_and_never_commits_a_manifest() {
        let root = temp_root();
        let destination = root.join("destination");
        let source = root.join("source.tif");
        write(&source, b"stable-prefix");
        let authorities = reserved_authorities(&root, &destination, "growing-artifact");
        let package = only_package(&authorities);
        let input = open_source_regular_nofollow(&source).unwrap();
        let snapshot = held_source_snapshot(&input, &source, MAX_EVIDENCE_ARTIFACT_BYTES).unwrap();

        let result = copy_held_artifact_with_hook(
            input,
            snapshot,
            &source,
            Path::new("artifacts/frame-0001/rgb.tif"),
            package,
            || {
                let mut growing = std::fs::OpenOptions::new()
                    .append(true)
                    .open(&source)
                    .map_err(|e| e.to_string())?;
                growing.write_all(b"-growth").map_err(|e| e.to_string())?;
                growing.sync_all().map_err(|e| e.to_string())
            },
        );
        let error = match result {
            Err(error) => error,
            Ok(_) => panic!("a source that grows after its held snapshot must fail"),
        };
        assert!(error.contains("grew beyond"));
        assert!(!package.final_path().join("manifest.json").exists());

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn journal_depth_entry_and_aggregate_limits_fail_closed() {
        let root = temp_root();
        let destination = root.join("destination");

        let deep_authorities = reserved_authorities(&root, &destination, "deep-journal");
        let deep_source = root.join("deep-source");
        write(&deep_source.join("one/two/three/receipt"), b"x");
        let mut proofs = Vec::new();
        let mut budget = JournalCopyBudget::default();
        let deep_limits = JournalLimits {
            max_file_bytes: 1024,
            max_total_bytes: 1024,
            max_entries: 100,
            max_depth: 1,
        };
        let deep_error = copy_tree_no_symlinks(
            &deep_source,
            Path::new("attempts/session-0001"),
            only_package(&deep_authorities),
            &mut proofs,
            &mut budget,
            0,
            deep_limits,
        )
        .expect_err("deep journals must stop at the configured bound");
        assert!(deep_error.contains("depth limit"));
        assert!(!only_package(&deep_authorities)
            .final_path()
            .join("manifest.json")
            .exists());

        let wide_authorities = reserved_authorities(&root, &destination, "wide-journal");
        let wide_source = root.join("wide-source");
        write(&wide_source.join("one"), b"1");
        write(&wide_source.join("two"), b"2");
        let mut proofs = Vec::new();
        let mut budget = JournalCopyBudget::default();
        let wide_limits = JournalLimits {
            max_file_bytes: 1024,
            max_total_bytes: 1024,
            max_entries: 2,
            max_depth: 10,
        };
        let wide_error = copy_tree_no_symlinks(
            &wide_source,
            Path::new("attempts/session-0001"),
            only_package(&wide_authorities),
            &mut proofs,
            &mut budget,
            0,
            wide_limits,
        )
        .expect_err("wide journals must stop at the configured bound");
        assert!(wide_error.contains("entry limit"));
        assert!(!only_package(&wide_authorities)
            .final_path()
            .join("manifest.json")
            .exists());

        let aggregate_authorities = reserved_authorities(&root, &destination, "aggregate-journal");
        let aggregate_source = root.join("aggregate-source");
        write(&aggregate_source.join("receipt"), b"four");
        let mut proofs = Vec::new();
        let mut budget = JournalCopyBudget::default();
        let aggregate_limits = JournalLimits {
            max_file_bytes: 1024,
            max_total_bytes: 3,
            max_entries: 10,
            max_depth: 10,
        };
        let aggregate_error = copy_tree_no_symlinks(
            &aggregate_source,
            Path::new("attempts/session-0001"),
            only_package(&aggregate_authorities),
            &mut proofs,
            &mut budget,
            0,
            aggregate_limits,
        )
        .expect_err("aggregate journal bytes must stop at the configured bound");
        assert!(aggregate_error.contains("aggregate byte limit"));
        assert!(!only_package(&aggregate_authorities)
            .final_path()
            .join("manifest.json")
            .exists());

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn manifest_precommit_proof_failure_leaves_no_authoritative_name() {
        let root = temp_root();
        let destination = root.join("destination");
        let authorities = reserved_authorities(&root, &destination, "proof-failure");
        let package = only_package(&authorities);
        let mut held = create_package_file(package, Path::new("proof.bin")).unwrap();
        held.write_all(b"proof").unwrap();
        held.sync_all().unwrap();
        let mismatched_proof = PackageFileProof {
            relative_path: PathBuf::from("missing-proof.bin"),
            file: held,
        };

        assert!(commit_manifest_authoritatively(
            package,
            br#"{"status":"complete"}"#,
            &[mismatched_proof],
            || Ok(())
        )
        .is_err());
        assert!(!package.final_path().join("manifest.json").exists());

        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(windows)]
    #[test]
    fn postcommit_ordering_failure_rolls_back_and_is_returned_as_an_error() {
        let root = temp_root();
        let destination = root.join("destination");
        let authorities = reserved_authorities(&root, &destination, "sync-ambiguity");
        let package = only_package(&authorities);
        let data = br#"{"status":"complete"}"#;

        let error = commit_manifest_authoritatively(package, data, &[], || {
            Err("injected post-commit ordering ambiguity".into())
        })
        .expect_err("post-commit ambiguity must never return successful completion");
        assert!(error.contains("ordering ambiguity"));
        assert!(error.contains("rolled back"));
        assert!(!package.final_path().join("manifest.json").exists());

        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn postcommit_ordering_failure_is_recovery_held_without_name_unlink() {
        let root = temp_root();
        let destination = root.join("destination");
        let authorities = reserved_authorities(&root, &destination, "sync-hold");
        let package = only_package(&authorities);
        let data = br#"{"status":"complete"}"#;

        let error = commit_manifest_authoritatively(package, data, &[], || {
            Err("injected post-commit ordering ambiguity".into())
        })
        .expect_err("post-commit ambiguity must never return successful completion");
        assert!(error.contains("ordering ambiguity"));
        assert!(error.contains("HOLD"));
        assert_eq!(
            std::fs::read(package.final_path().join("manifest.json")).unwrap(),
            data
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn evidence_manifest_serializer_stops_at_the_configured_byte_bound() {
        let value = serde_json::json!({"receipt": "0123456789abcdef"});
        let error = serialize_json_bounded(&value, 8)
            .expect_err("serialization must stop before growing beyond the configured bound");
        assert!(error.contains("8 byte authority limit"), "{error}");

        let encoded = serialize_json_bounded(&serde_json::json!({"ok": true}), 64)
            .expect("ordinary bounded evidence manifest serializes");
        assert!(encoded.len() <= 64);
    }

    #[cfg(unix)]
    #[test]
    fn postcommit_replacement_is_preserved_as_an_explicit_hold() {
        let root = temp_root();
        let destination = root.join("destination");
        let authorities = reserved_authorities(&root, &destination, "rollback-hold");
        let package = only_package(&authorities);
        let committed = package.final_path().join("manifest.json");
        let displaced = root.join("displaced-original-manifest");

        let error =
            commit_manifest_authoritatively(package, br#"{"status":"complete"}"#, &[], || {
                std::fs::rename(&committed, &displaced).map_err(|e| e.to_string())?;
                std::fs::write(&committed, b"replacement").map_err(|e| e.to_string())?;
                Err("injected post-commit replacement".into())
            })
            .expect_err("an ambiguous replacement must not report completion");
        assert!(error.contains("HOLD"));
        assert_eq!(std::fs::read(&committed).unwrap(), b"replacement");
        assert!(displaced.is_file());

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn package_copies_exact_attempt_tree_hashes_files_and_is_create_only() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let evidence = frame(&attempts);
        let authorities = reserved_authorities(&root, &destination, "job-1");
        let result = finalize_with_expected_root(
            only_package(&authorities),
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
            manifest["frames"][0]["bridgeReceipt"]["nikonBuilderInputs"]["selectedPixelsPath"],
            "attempts/session-0001/journal/selected-pixels.bin"
        );
        assert_eq!(
            manifest["frames"][0]["engineReceipt"]["receipt"]["nikonBuilderInputs"]
                ["selectedPixelsPath"],
            "attempts/session-0001/journal/selected-pixels.bin"
        );
        assert_eq!(
            manifest["frames"][0]["sourceProvenance"]["attemptsRoot"],
            evidence
                .attempts_root
                .as_ref()
                .unwrap()
                .display()
                .to_string()
        );
        assert_eq!(
            manifest["frames"][0]["sourceProvenance"]["bridgeSelectedPixelsPath"],
            evidence.bridge_receipt["nikonBuilderInputs"]["selectedPixelsPath"]
        );
        assert!(
            finalize_with_expected_root(
                only_package(&authorities),
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
        let authorities = reserved_authorities(&root, &destination, "job-terminal-error");
        let result = finalize_with_optional_expected_root(
            only_package(&authorities),
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

        let authorities = reserved_authorities(&root, &destination, "shared-session");
        let result = finalize_with_expected_root(
            only_package(&authorities),
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
        let missing_authorities = reserved_authorities(&root, &destination, "missing");
        let incomplete = finalize_with_expected_root(
            only_package(&missing_authorities),
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
        let outside_authorities = reserved_authorities(&root, &destination, "outside");
        let outside_result = finalize_with_expected_root(
            only_package(&outside_authorities),
            "outside",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .unwrap();
        assert_eq!(outside_result.status, "incomplete");
        assert!(validate_job_id("../escape").is_err());
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
        let authorities = reserved_authorities(&root, &destination, "disappeared");
        let result = finalize_with_expected_root(
            only_package(&authorities),
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
        let authorities = reserved_authorities(&root, &destination, "symlink");
        assert!(finalize_with_expected_root(
            only_package(&authorities),
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

    #[cfg(unix)]
    #[test]
    fn planted_capture_evidence_link_is_rejected_before_package_reservation() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let destination = root.join("destination");
        let outside = root.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("sentinel"), b"unchanged").unwrap();
        let mut authorities = unreserved_authorities(&root, &destination);
        symlink(&outside, destination.join("Capture Evidence")).unwrap();

        let error = authorities
            .reserve_evidence_packages("pre-motion-link")
            .expect_err("a planted evidence-root link must fail before bridge dispatch");
        assert_eq!(error.code, crate::protocol::ErrorCode::InvalidParams);
        assert_eq!(
            std::fs::read(outside.join("sentinel")).unwrap(),
            b"unchanged"
        );
        assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 1);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn exact_package_collision_is_rejected_during_pre_motion_reservation() {
        let root = temp_root();
        let destination = root.join("destination");
        let mut authorities = unreserved_authorities(&root, &destination);
        let existing = destination.join("Capture Evidence/collision.scanstudio");
        std::fs::create_dir_all(&existing).unwrap();
        std::fs::write(existing.join("foreign"), b"preserve").unwrap();

        let error = authorities
            .reserve_evidence_packages("collision")
            .expect_err("an existing package must fail before bridge dispatch");
        assert_eq!(error.code, crate::protocol::ErrorCode::ArchiveCollision);
        assert_eq!(
            std::fs::read(existing.join("foreign")).unwrap(),
            b"preserve"
        );
        assert!(authorities.reserved_evidence_packages().is_empty());

        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn held_destination_swap_cannot_redirect_package_writes_outside() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let displaced = root.join("destination-held");
        let outside = root.join("outside");
        let evidence = frame(&attempts);
        let authorities = reserved_authorities(&root, &destination, "destination-swap");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("sentinel"), b"unchanged").unwrap();
        std::fs::rename(&destination, &displaced).unwrap();
        symlink(&outside, &destination).unwrap();

        let error = finalize_with_expected_root(
            only_package(&authorities),
            "destination-swap",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .expect_err("a replaced archive destination must invalidate held evidence authority");
        assert!(error.contains("authority") || error.contains("without following"));
        assert_eq!(
            std::fs::read(outside.join("sentinel")).unwrap(),
            b"unchanged"
        );
        assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 1);

        let _ = std::fs::remove_file(&destination);
        let _ = std::fs::remove_dir_all(&displaced);
        let _ = std::fs::remove_dir_all(&outside);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn held_package_swap_cannot_promote_a_manifest_into_replacement() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let outside = root.join("outside");
        let displaced = root.join("package-held");
        let evidence = frame(&attempts);
        let authorities = reserved_authorities(&root, &destination, "package-swap");
        let package_path = only_package(&authorities).final_path().to_path_buf();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("sentinel"), b"unchanged").unwrap();
        std::fs::rename(&package_path, &displaced).unwrap();
        symlink(&outside, &package_path).unwrap();

        assert!(finalize_with_expected_root(
            only_package(&authorities),
            "package-swap",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .is_err());
        assert_eq!(
            std::fs::read(outside.join("sentinel")).unwrap(),
            b"unchanged"
        );
        assert!(!outside.join("manifest.json").exists());

        let _ = std::fs::remove_file(&package_path);
        let _ = std::fs::remove_dir_all(&displaced);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn manifest_symlink_collision_preserves_outside_sentinel() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let outside = root.join("outside");
        let evidence = frame(&attempts);
        let authorities = reserved_authorities(&root, &destination, "manifest-link");
        std::fs::create_dir_all(&outside).unwrap();
        let sentinel = outside.join("sentinel");
        std::fs::write(&sentinel, b"unchanged").unwrap();
        symlink(
            &sentinel,
            only_package(&authorities)
                .final_path()
                .join("manifest.json"),
        )
        .unwrap();

        assert!(finalize_with_expected_root(
            only_package(&authorities),
            "manifest-link",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .is_err());
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"unchanged");

        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn manifest_hardlink_collision_preserves_outside_sentinel() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let outside = root.join("outside");
        let evidence = frame(&attempts);
        let authorities = reserved_authorities(&root, &destination, "manifest-hardlink");
        std::fs::create_dir_all(&outside).unwrap();
        let sentinel = outside.join("sentinel");
        std::fs::write(&sentinel, b"unchanged").unwrap();
        std::fs::hard_link(
            &sentinel,
            only_package(&authorities)
                .final_path()
                .join("manifest.json"),
        )
        .unwrap();

        assert!(finalize_with_expected_root(
            only_package(&authorities),
            "manifest-hardlink",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .is_err());
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"unchanged");

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn artifact_collision_preserves_foreign_bytes_and_never_promotes_manifest() {
        let root = temp_root();
        let attempts = root.join("attempts");
        let destination = root.join("destination");
        let evidence = frame(&attempts);
        let authorities = reserved_authorities(&root, &destination, "artifact-collision");
        let package = only_package(&authorities);
        let foreign = package.final_path().join("artifacts/frame-0001/rgb.tif");
        write(&foreign, b"foreign");

        assert!(finalize_with_expected_root(
            package,
            "artifact-collision",
            &[evidence],
            &serde_json::json!({}),
            &attempts,
        )
        .is_err());
        assert_eq!(std::fs::read(&foreign).unwrap(), b"foreign");
        assert!(!package.final_path().join("manifest.json").exists());

        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn physical_archive_aliases_share_one_reserved_evidence_package() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let physical = root.join("physical");
        let first_alias = root.join("first-alias");
        let second_alias = root.join("second-alias");
        std::fs::create_dir_all(&physical).unwrap();
        symlink(&physical, &first_alias).unwrap();
        symlink(&physical, &second_alias).unwrap();

        let mut output = crate::domain::OutputRecipe::default();
        output.archive.destination = first_alias.display().to_string();
        output.archive.filename_template = "master-####.tif".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let mut second_output = output.clone();
        second_output.archive.destination = second_alias.display().to_string();
        let mut overrides = std::collections::HashMap::new();
        overrides.insert(
            2,
            crate::domain::FrameOverrides {
                output: Some(second_output),
                ..crate::domain::FrameOverrides::default()
            },
        );
        let mut authorities = crate::render::acquire_job_output_authorities(
            None,
            &[1, 2],
            &crate::domain::CaptureRecipe::default(),
            &output,
            &overrides,
        )
        .unwrap();
        authorities.reserve_evidence_packages("aliases").unwrap();

        assert_eq!(authorities.reserved_evidence_packages().len(), 1);
        assert_eq!(
            authorities.reserved_evidence_packages()[0].eligible_slots(),
            &[1, 2]
        );

        let _ = std::fs::remove_dir_all(root);
    }
}
