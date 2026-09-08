//! Create-only collection of engine-authorized calibration capture artifacts.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::calibration::{VerificationIssue, VerificationStatus};
use crate::domain::{ScanProject, ScanReceipt, WrittenFileBinding};

const MAX_ARTIFACT_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const RAW_IR_TAG: u16 = 65_010;
const RAW_IR_MARKER: &[u8] = b"scanstudio.infrared.linear.uint16.v1\0";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectionMetadata {
    pub stock: String,
    pub pass: String,
    pub slot_map: BTreeMap<u32, u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub firmware: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adapter: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operator: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub driver_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub locked_exposure: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectedFile {
    pub path: String,
    pub byte_length: u64,
    pub sha256: String,
}

struct HeldCollectedFile {
    file: CollectedFile,
    handle: File,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectionResult {
    pub destination: String,
    pub files: Vec<CollectedFile>,
    pub metadata_path: String,
    pub hashes_path: String,
}

struct SelectedReceipt<'a> {
    receipt: &'a ScanReceipt,
    physical_frame: u32,
}

struct PreflightReceipt<'a> {
    selected: SelectedReceipt<'a>,
    raw: Option<File>,
    raw_ir: Option<File>,
    meter: File,
    positive: Option<File>,
}

enum ArtifactCheckFailure {
    Unknown(String),
    Fail(String),
}

/// Verifies the selected pass's engine-bound files without creating or
/// modifying anything. A missing/unreadable binding is unknown; a bound file
/// whose identity, length, or digest disagrees is a failure. An absent pass
/// checks all passes without comparing their artifacts together.
pub fn verify_artifacts(
    project_root: &Path,
    project: &ScanProject,
    pass: Option<&str>,
) -> Vec<VerificationIssue> {
    let mut issues = Vec::new();
    let authority = match crate::render::acquire_project_output_root_authority(Some(project_root)) {
        Ok(Some(authority)) => authority,
        Ok(None) => unreachable!("project-root collection verification requires an authority"),
        Err(error) => {
            issues.push(artifact_issue(
                VerificationStatus::Unknown,
                None,
                None,
                "projectRoot",
                error.message,
            ));
            return issues;
        }
    };
    if let Err(error) = authority.verify_namespace() {
        issues.push(artifact_issue(
            VerificationStatus::Unknown,
            None,
            None,
            "projectRoot",
            error.message,
        ));
    }

    let receipts: Vec<&ScanReceipt> = project
        .frames
        .iter()
        .flat_map(|frame| frame.receipts.iter())
        .filter(|receipt| pass.is_none_or(|pass| receipt.pass_token.as_deref() == Some(pass)))
        .collect();
    if receipts.is_empty() {
        issues.push(artifact_issue(
            VerificationStatus::Unknown,
            None,
            None,
            "receipts",
            "no receipts matched the requested pass",
        ));
    }
    for receipt in &receipts {
        verify_receipt_artifacts(&authority, receipt, &mut issues);
    }

    issues
}

fn verify_receipt_artifacts(
    authority: &crate::render::ProjectOutputRootAuthority,
    receipt: &ScanReceipt,
    issues: &mut Vec<VerificationIssue>,
) {
    let Some(outputs) = receipt.outputs.as_ref() else {
        issues.push(receipt_artifact_issue(
            VerificationStatus::Unknown,
            receipt,
            "outputs",
            "receipt has no written-output bindings",
        ));
        return;
    };
    let Some(captures) = outputs.capture_bindings.as_ref() else {
        issues.push(receipt_artifact_issue(
            VerificationStatus::Unknown,
            receipt,
            "outputs.captureBindings",
            "receipt has no capture bindings",
        ));
        return;
    };
    let raw_enabled = receipt
        .output
        .as_ref()
        .is_some_and(|output| output.raw_export.enabled);
    if raw_enabled {
        check_receipt_artifact(
            authority,
            receipt,
            captures.raw_negative.as_ref(),
            outputs.raw_negative_path.as_deref(),
            "outputs.captureBindings.rawNegative",
            "raw",
            issues,
        );
        check_receipt_artifact(
            authority,
            receipt,
            captures.raw_negative_ir.as_ref(),
            outputs.raw_negative_ir_path.as_deref(),
            "outputs.captureBindings.rawNegativeIr",
            "raw infrared",
            issues,
        );
    }
    check_receipt_artifact(
        authority,
        receipt,
        captures.meter.as_ref(),
        receipt.meter_rgbi_path.as_deref(),
        "outputs.captureBindings.meter",
        "meter",
        issues,
    );
    if let Some(positive_path) = outputs.positive_path.as_deref() {
        check_receipt_artifact(
            authority,
            receipt,
            outputs
                .metadata_bindings
                .as_ref()
                .and_then(|bindings| bindings.positive.as_ref()),
            Some(positive_path),
            "outputs.metadataBindings.positive",
            "positive",
            issues,
        );
    }
    if let Some(archive_path) = outputs.archive_path.as_deref() {
        check_receipt_artifact(
            authority,
            receipt,
            outputs
                .metadata_bindings
                .as_ref()
                .and_then(|bindings| bindings.archive.as_ref()),
            Some(archive_path),
            "outputs.metadataBindings.archive",
            "archive",
            issues,
        );
    }
    if let Some(preview_path) = outputs.preview_path.as_deref() {
        check_receipt_artifact(
            authority,
            receipt,
            outputs
                .metadata_bindings
                .as_ref()
                .and_then(|bindings| bindings.preview.as_ref()),
            Some(preview_path),
            "outputs.metadataBindings.preview",
            "preview",
            issues,
        );
    }
}

fn check_receipt_artifact(
    authority: &crate::render::ProjectOutputRootAuthority,
    receipt: &ScanReceipt,
    binding: Option<&WrittenFileBinding>,
    recorded_path: Option<&str>,
    field: &str,
    role: &str,
    issues: &mut Vec<VerificationIssue>,
) {
    let Some(binding) = binding else {
        issues.push(receipt_artifact_issue(
            VerificationStatus::Unknown,
            receipt,
            field,
            format!("{role} binding is absent"),
        ));
        return;
    };
    let Some(recorded_path) = recorded_path else {
        issues.push(receipt_artifact_issue(
            VerificationStatus::Unknown,
            receipt,
            field,
            format!("{role} receipt path is absent"),
        ));
        return;
    };
    match verify_bound_source(authority, binding, Some(recorded_path), role) {
        Ok(()) => {}
        Err(ArtifactCheckFailure::Unknown(detail)) => issues.push(receipt_artifact_issue(
            VerificationStatus::Unknown,
            receipt,
            field,
            detail,
        )),
        Err(ArtifactCheckFailure::Fail(detail)) => issues.push(receipt_artifact_issue(
            VerificationStatus::Fail,
            receipt,
            field,
            detail,
        )),
    }
}

fn verify_bound_source(
    authority: &crate::render::ProjectOutputRootAuthority,
    binding: &WrittenFileBinding,
    recorded_path: Option<&str>,
    role: &str,
) -> Result<(), ArtifactCheckFailure> {
    let source = open_bound_source(authority, binding, recorded_path, role)
        .map_err(ArtifactCheckFailure::Unknown)?;
    let mut source = source;
    source
        .seek(SeekFrom::Start(0))
        .map_err(|error| ArtifactCheckFailure::Unknown(format!("rewind {role} source: {error}")))?;
    let mut hasher = Sha256::new();
    let mut remaining = binding.byte_length;
    let mut buffer = [0_u8; 64 * 1024];
    while remaining > 0 {
        let limit = usize::try_from(remaining.min(buffer.len() as u64)).unwrap();
        let read = source.read(&mut buffer[..limit]).map_err(|error| {
            ArtifactCheckFailure::Unknown(format!("read {role} source: {error}"))
        })?;
        if read == 0 {
            return Err(ArtifactCheckFailure::Fail(format!(
                "{role} source ended before its bound length"
            )));
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    let metadata = source.metadata().map_err(|error| {
        ArtifactCheckFailure::Unknown(format!("inspect {role} source after hashing: {error}"))
    })?;
    let identity = crate::exiftool::held_file_identity(&source, &metadata).ok_or_else(|| {
        ArtifactCheckFailure::Unknown(format!("{role} source identity is unavailable"))
    })?;
    if metadata.len() != binding.byte_length
        || identity.0 != binding.volume_id.unwrap()
        || identity.1 != binding.file_id.unwrap()
        || identity.2 != 1
    {
        return Err(ArtifactCheckFailure::Fail(format!(
            "{role} source identity or length changed while hashing"
        )));
    }
    let digest = format!("{:x}", hasher.finalize());
    if digest != binding.sha256 {
        return Err(ArtifactCheckFailure::Fail(format!(
            "{role} source SHA-256 does not match its binding"
        )));
    }
    Ok(())
}

fn artifact_issue(
    status: VerificationStatus,
    job_id: Option<String>,
    frame_index: Option<u32>,
    field: impl Into<String>,
    detail: impl Into<String>,
) -> VerificationIssue {
    VerificationIssue {
        status,
        job_id,
        frame_index,
        field: field.into(),
        detail: detail.into(),
    }
}

fn receipt_artifact_issue(
    status: VerificationStatus,
    receipt: &ScanReceipt,
    field: impl Into<String>,
    detail: impl Into<String>,
) -> VerificationIssue {
    artifact_issue(
        status,
        Some(receipt.job_id.clone()),
        Some(receipt.frame_index),
        field,
        detail,
    )
}

/// Copy selected, engine-bound raw capture evidence into a fresh directory.
///
/// The project root and every source are held by file descriptors. Receipt
/// pathnames are checked only as display-path consistency; they never grant
/// source authority. `project_root` must be the same output root used when the
/// receipt bindings were minted. The destination may be any existing folder;
/// its parent is held and re-verified for create-only publication.
pub fn collect(
    project_root: &Path,
    project: &ScanProject,
    selected_job_ids: Option<&[String]>,
    destination: &Path,
    metadata: &CollectionMetadata,
) -> Result<CollectionResult, String> {
    validate_component(&metadata.stock, "stock")?;
    validate_component(&metadata.pass, "pass")?;
    if metadata.slot_map.is_empty()
        || metadata.slot_map.keys().any(|slot| *slot == 0)
        || metadata.slot_map.values().any(|frame| *frame == 0)
        || metadata.slot_map.values().collect::<BTreeSet<_>>().len() != metadata.slot_map.len()
    {
        return Err(
            "slot map must contain unique positive scanner slots and physical frames".into(),
        );
    }
    if !destination.is_absolute() {
        return Err("collection destination must be an absolute path".into());
    }
    let authority = crate::render::acquire_project_output_root_authority(Some(project_root))
        .map_err(|error| error.message)?
        .ok_or("project output root authority is unavailable")?;
    authority
        .verify_namespace()
        .map_err(|error| error.message)?;
    let destination_leaf = destination
        .file_name()
        .ok_or("collection destination has no leaf name")?;
    validate_component(
        destination_leaf
            .to_str()
            .ok_or("collection destination leaf is not UTF-8")?,
        "collection destination",
    )?;
    let destination_parent_path = destination
        .parent()
        .ok_or("collection destination has no parent")?;
    let destination_parent_canonical = std::fs::canonicalize(destination_parent_path)
        .map_err(|error| format!("resolve collection destination parent: {error}"))?;
    let destination_parent =
        crate::exiftool::metadata_publish_sys::open_directory(&destination_parent_canonical)
            .map_err(|error| format!("open collection destination parent: {error}"))?;
    crate::exiftool::verify_directory_path_authority(
        &destination_parent_canonical,
        &destination_parent,
        "collection destination parent",
    )
    .map_err(|error| error.message)?;
    if destination.exists() {
        return Err(format!(
            "collection destination already exists: {}",
            destination.display()
        ));
    }

    let selected = select_receipts(
        project,
        selected_job_ids,
        &metadata.pass,
        &metadata.slot_map,
    )?;
    let preflighted = preflight_receipts(&authority, &selected)?;
    authority
        .verify_namespace()
        .map_err(|error| error.message)?;
    crate::exiftool::verify_directory_path_authority(
        &destination_parent_canonical,
        &destination_parent,
        "collection destination parent",
    )
    .map_err(|error| error.message)?;

    let destination_dir = crate::render::create_evidence_directory_nondestructive(
        &destination_parent,
        destination_leaf,
    )
    .map_err(|error| format!("create collection destination: {error}"))?;
    authority
        .verify_namespace()
        .map_err(|error| error.message)?;
    crate::exiftool::verify_directory_path_authority(
        &destination_parent_canonical,
        &destination_parent,
        "collection destination parent",
    )
    .map_err(|error| error.message)?;

    let mut files = Vec::new();
    let mut held_files = Vec::new();
    let mut metadata_frames = Vec::new();
    let mut engine_versions = BTreeSet::new();
    for mut preflight in preflighted {
        let selected = &preflight.selected;
        let receipt = selected.receipt;
        let outputs = receipt
            .outputs
            .as_ref()
            .expect("preflight validated outputs");
        let stem = format!(
            "{}_{:02}_{}",
            metadata.stock, selected.physical_frame, metadata.pass
        );
        engine_versions.insert(receipt.engine_version.clone());

        if let Some(raw_file) = preflight.raw.take() {
            let raw = outputs
                .capture_bindings
                .as_ref()
                .and_then(|bindings| bindings.raw_negative.as_ref())
                .expect("preflight validated raw binding");
            record_held(
                &mut held_files,
                &mut files,
                copy_bound_file(
                    raw_file,
                    raw,
                    &destination_dir,
                    &format!("{stem}.tif"),
                    "raw",
                )?,
            );
        }

        if let Some(raw_ir_file) = preflight.raw_ir.take() {
            let raw_ir = outputs
                .capture_bindings
                .as_ref()
                .and_then(|bindings| bindings.raw_negative_ir.as_ref())
                .expect("preflight validated raw IR binding");
            record_held(
                &mut held_files,
                &mut files,
                copy_bound_file(
                    raw_ir_file,
                    raw_ir,
                    &destination_dir,
                    &format!("{stem}-ir.tif"),
                    "raw infrared",
                )?,
            );
        }

        let meter = outputs
            .capture_bindings
            .as_ref()
            .unwrap()
            .meter
            .as_ref()
            .expect("preflight validated meter binding");
        record_held(
            &mut held_files,
            &mut files,
            copy_bound_file(
                preflight.meter,
                meter,
                &destination_dir,
                &format!("{stem}-meter.tif"),
                "meter",
            )?,
        );

        if outputs.positive_path.is_some() {
            let positive = outputs
                .metadata_bindings
                .as_ref()
                .and_then(|bindings| bindings.positive.as_ref())
                .ok_or_else(|| receipt_error(receipt, "positive binding is absent"))?;
            record_held(
                &mut held_files,
                &mut files,
                copy_bound_file(
                    preflight
                        .positive
                        .take()
                        .expect("preflight validated positive binding"),
                    positive,
                    &destination_dir,
                    &format!("{stem}-positive.tif"),
                    "positive",
                )?,
            );
        }

        let receipt_bytes = serde_json::to_vec_pretty(receipt)
            .map_err(|error| receipt_error(receipt, format!("serialize receipt: {error}")))?;
        record_held(
            &mut held_files,
            &mut files,
            write_new_file(
                &destination_dir,
                &format!("{stem}-receipt.json"),
                &receipt_bytes,
            )?,
        );
        metadata_frames.push(serde_json::json!({
            "slot": receipt.frame_index,
            "frame": selected.physical_frame,
            "jobId": receipt.job_id,
            "passToken": receipt.pass_token,
            "engineVersion": receipt.engine_version,
            "deviceId": receipt.device_id,
            "deviceModel": receipt.device_model,
            "hardwareVerification": receipt.hardware_verification,
            "simulated": receipt.simulated,
            "settingsFingerprint": receipt.settings_fingerprint,
            "resolutionDpi": receipt.resolution_dpi,
            "bitDepth": receipt.bit_depth,
            "channels": receipt.channels,
            "startedAt": receipt.started_at,
            "durationMs": receipt.duration_ms,
            "passes": receipt.passes,
            "processing": receipt.processing,
            "output": receipt.output,
            "exposureAuthority": receipt.exposure_authority,
            "meterRgbiPath": receipt.meter_rgbi_path,
        }));
    }

    let metadata_json = serde_json::json!({
        "schemaVersion": 1,
        "projectId": project.id,
        "projectName": project.name,
        "projectCreatedAt": project.created_at,
        "stock": &metadata.stock,
        "pass": &metadata.pass,
        "slotMap": &metadata.slot_map,
        "collectionContext": {
            "firmware": metadata.firmware.as_deref().unwrap_or("unknown"),
            "adapter": metadata.adapter.as_deref().unwrap_or("unknown"),
            "host": metadata.host.as_deref().unwrap_or("unknown"),
            "operator": metadata.operator.as_deref().unwrap_or("unknown"),
            "appVersion": metadata.app_version.as_deref().unwrap_or("unknown"),
            "driverVersion": metadata.driver_version.as_deref().unwrap_or("unknown"),
        },
        "capturedVersions": {
            "engine": engine_versions,
            "app": "unknown",
            "driver": "unknown",
        },
        "lockedExposure": locked_exposure_metadata(project, metadata),
        "exceptions": {
            "status": "unavailable",
            "detail": "selected receipts do not persist exception records",
        },
        "settings": &project.recipes,
        "frames": metadata_frames,
    });
    let metadata_bytes = serde_json::to_vec_pretty(&metadata_json)
        .map_err(|error| format!("serialize roll metadata: {error}"))?;
    let metadata_file = write_new_file(&destination_dir, "roll-metadata.json", &metadata_bytes)?;
    let metadata_path = destination.join("roll-metadata.json");
    record_held(&mut held_files, &mut files, metadata_file);

    let mut ledger = String::new();
    for file in &files {
        ledger.push_str(&format!(
            "{}  {}  {} bytes\n",
            file.sha256, file.path, file.byte_length
        ));
    }
    let hash_file = write_new_file(&destination_dir, "file-hashes.txt", ledger.as_bytes())?;
    let hashes_path = destination.join("file-hashes.txt");
    record_held(&mut held_files, &mut files, hash_file);
    crate::exiftool::metadata_publish_sys::sync_directory(&destination_dir)
        .map_err(|error| format!("sync collection destination: {error}"))?;
    authority
        .verify_namespace()
        .map_err(|error| error.message)?;
    crate::exiftool::verify_directory_path_authority(
        &destination_parent_canonical,
        &destination_parent,
        "collection destination parent",
    )
    .map_err(|error| error.message)?;
    crate::exiftool::verify_directory_path_authority(
        destination,
        &destination_dir,
        "collection destination",
    )
    .map_err(|error| error.message)?;
    for held in &mut held_files {
        verify_held_output(&destination_dir, held)?;
    }

    Ok(CollectionResult {
        destination: destination.display().to_string(),
        files,
        metadata_path: metadata_path.display().to_string(),
        hashes_path: hashes_path.display().to_string(),
    })
}

fn select_receipts<'a>(
    project: &'a ScanProject,
    selected_job_ids: Option<&[String]>,
    pass: &str,
    slot_map: &BTreeMap<u32, u32>,
) -> Result<Vec<SelectedReceipt<'a>>, String> {
    let mut selected = Vec::new();
    let mut seen_frames = BTreeMap::new();
    for frame in &project.frames {
        for receipt in &frame.receipts {
            if receipt.pass_token.as_deref() != Some(pass)
                || selected_job_ids.is_some_and(|ids| !ids.iter().any(|id| id == &receipt.job_id))
            {
                continue;
            }
            let physical_frame = slot_map
                .get(&receipt.frame_index)
                .copied()
                .ok_or_else(|| receipt_error(receipt, "slot map has no physical-frame entry"))?;
            if let Some(previous) = seen_frames.insert(physical_frame, receipt.job_id.clone()) {
                return Err(receipt_error(
                    receipt,
                    format!("selected frame duplicates job {previous}"),
                ));
            }
            selected.push(SelectedReceipt {
                receipt,
                physical_frame,
            });
        }
    }
    if selected.is_empty() {
        return Err("no receipts matched the requested pass and job IDs".into());
    }
    Ok(selected)
}

fn preflight_receipts<'a>(
    authority: &crate::render::ProjectOutputRootAuthority,
    selected: &[SelectedReceipt<'a>],
) -> Result<Vec<PreflightReceipt<'a>>, String> {
    let mut preflighted = Vec::with_capacity(selected.len());
    for selected in selected {
        let receipt = selected.receipt;
        let outputs = receipt
            .outputs
            .as_ref()
            .ok_or_else(|| receipt_error(receipt, "outputs are absent"))?;
        let captures = outputs
            .capture_bindings
            .as_ref()
            .ok_or_else(|| receipt_error(receipt, "capture bindings are absent"))?;
        let raw_export_enabled = receipt
            .output
            .as_ref()
            .is_some_and(|output| output.raw_export.enabled);
        let (raw_file, raw_ir_file) = if raw_export_enabled {
            let raw = captures
                .raw_negative
                .as_ref()
                .ok_or_else(|| receipt_error(receipt, "raw binding is absent"))?;
            let raw_path = outputs
                .raw_negative_path
                .as_deref()
                .ok_or_else(|| receipt_error(receipt, "raw path is absent"))?;
            let raw_file = open_bound_source(authority, raw, Some(raw_path), "raw")?;
            validate_rgb_tiff(&raw_file, false)?;
            let raw_ir = captures
                .raw_negative_ir
                .as_ref()
                .ok_or_else(|| receipt_error(receipt, "raw infrared binding is absent"))?;
            let raw_ir_path = outputs
                .raw_negative_ir_path
                .as_deref()
                .ok_or_else(|| receipt_error(receipt, "raw infrared path is absent"))?;
            let raw_ir_file =
                open_bound_source(authority, raw_ir, Some(raw_ir_path), "raw infrared")?;
            validate_rgb_tiff(&raw_ir_file, true)?;
            (Some(raw_file), Some(raw_ir_file))
        } else {
            (None, None)
        };
        let meter = captures
            .meter
            .as_ref()
            .ok_or_else(|| receipt_error(receipt, "meter binding is absent"))?;
        let meter_path = receipt
            .meter_rgbi_path
            .as_deref()
            .ok_or_else(|| receipt_error(receipt, "meter path is absent"))?;
        let meter_file = open_bound_source(authority, meter, Some(meter_path), "meter")?;
        let positive = if let Some(path) = outputs.positive_path.as_deref() {
            let binding = outputs
                .metadata_bindings
                .as_ref()
                .and_then(|bindings| bindings.positive.as_ref())
                .ok_or_else(|| receipt_error(receipt, "positive binding is absent"))?;
            Some(open_bound_source(
                authority,
                binding,
                Some(path),
                "positive",
            )?)
        } else {
            None
        };
        preflighted.push(PreflightReceipt {
            selected: SelectedReceipt {
                receipt,
                physical_frame: selected.physical_frame,
            },
            raw: raw_file,
            raw_ir: raw_ir_file,
            meter: meter_file,
            positive,
        });
    }
    Ok(preflighted)
}

fn open_bound_source(
    authority: &crate::render::ProjectOutputRootAuthority,
    binding: &WrittenFileBinding,
    recorded_path: Option<&str>,
    role: &str,
) -> Result<File, String> {
    validate_binding(authority, binding, recorded_path, role)?;
    let relative = validate_binding_path(binding)?;
    let source = crate::exiftool::open_regular_beneath(authority.directory_handle(), &relative)
        .map_err(|error| format!("open bound {role} source: {}", error.message))?;
    let file_metadata = source
        .metadata()
        .map_err(|error| format!("inspect bound {role} source: {error}"))?;
    let identity = crate::exiftool::held_file_identity(&source, &file_metadata)
        .ok_or_else(|| format!("{role} source identity is unavailable"))?;
    if file_metadata.len() != binding.byte_length
        || identity.0 != binding.volume_id.unwrap()
        || identity.1 != binding.file_id.unwrap()
        || identity.2 != 1
    {
        return Err(format!("{role} source no longer matches its binding"));
    }
    Ok(source)
}

fn validate_binding(
    authority: &crate::render::ProjectOutputRootAuthority,
    binding: &WrittenFileBinding,
    recorded_path: Option<&str>,
    role: &str,
) -> Result<(), String> {
    let relative = validate_binding_path(binding)?;
    if binding.byte_length > MAX_ARTIFACT_BYTES
        || binding.volume_id.is_none()
        || binding.file_id.is_none()
        || binding.sha256.len() != 64
        || !binding
            .sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(format!(
            "{role} binding is malformed or lacks stable identity"
        ));
    }
    let Some(recorded_path) = recorded_path else {
        return Err(format!("{role} receipt path is absent"));
    };
    let recorded = Path::new(recorded_path);
    if !recorded.is_absolute()
        || (recorded != authority.requested_path().join(&relative)
            && recorded != authority.canonical_path().join(&relative))
    {
        return Err(format!("{role} receipt path does not match its binding"));
    }
    Ok(())
}

fn validate_binding_path(binding: &WrittenFileBinding) -> Result<PathBuf, String> {
    let path = PathBuf::from(&binding.relative_path);
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err("capture binding path is not a safe relative path".into());
    }
    Ok(path)
}

fn record_held(
    held_files: &mut Vec<HeldCollectedFile>,
    files: &mut Vec<CollectedFile>,
    held: HeldCollectedFile,
) {
    files.push(held.file.clone());
    held_files.push(held);
}

fn copy_bound_file(
    source: File,
    binding: &WrittenFileBinding,
    destination_dir: &File,
    name: &str,
    role: &str,
) -> Result<HeldCollectedFile, String> {
    validate_component(name, role)?;
    let mut output = crate::exiftool::metadata_publish_sys::create_new_regular(
        destination_dir,
        OsStr::new(name),
    )
    .map_err(|error| format!("create {role} output {name}: {error}"))?;
    let digest = crate::evidence_package::copy_held_file(
        source,
        Path::new(&binding.relative_path),
        &mut output,
        Path::new(name),
        binding.byte_length,
    )?;
    if digest != binding.sha256 {
        return Err(format!("{role} copied bytes do not match receipt binding"));
    }
    Ok(HeldCollectedFile {
        file: CollectedFile {
            path: name.into(),
            byte_length: binding.byte_length,
            sha256: digest,
        },
        handle: output,
    })
}

fn write_new_file(
    destination_dir: &File,
    name: &str,
    bytes: &[u8],
) -> Result<HeldCollectedFile, String> {
    validate_component(name, "collection output")?;
    let mut output = crate::exiftool::metadata_publish_sys::create_new_regular(
        destination_dir,
        OsStr::new(name),
    )
    .map_err(|error| format!("create collection output {name}: {error}"))?;
    output
        .write_all(bytes)
        .map_err(|error| format!("write collection output {name}: {error}"))?;
    output
        .sync_all()
        .map_err(|error| format!("sync collection output {name}: {error}"))?;
    Ok(HeldCollectedFile {
        file: CollectedFile {
            path: name.into(),
            byte_length: bytes.len() as u64,
            sha256: format!("{:x}", Sha256::digest(bytes)),
        },
        handle: output,
    })
}

fn verify_held_output(destination_dir: &File, held: &mut HeldCollectedFile) -> Result<(), String> {
    let metadata = held
        .handle
        .metadata()
        .map_err(|error| format!("inspect collection output {}: {error}", held.file.path))?;
    let identity =
        crate::exiftool::held_file_identity(&held.handle, &metadata).ok_or_else(|| {
            format!(
                "collection output identity is unavailable: {}",
                held.file.path
            )
        })?;
    let reopened = crate::exiftool::metadata_publish_sys::open_regular(
        destination_dir,
        OsStr::new(&held.file.path),
    )
    .map_err(|error| format!("re-open collection output {}: {error}", held.file.path))?;
    let reopened_metadata = reopened.metadata().map_err(|error| {
        format!(
            "inspect re-opened collection output {}: {error}",
            held.file.path
        )
    })?;
    let reopened_identity = crate::exiftool::held_file_identity(&reopened, &reopened_metadata)
        .ok_or_else(|| {
            format!(
                "re-opened collection output identity is unavailable: {}",
                held.file.path
            )
        })?;
    if identity != reopened_identity
        || metadata.len() != held.file.byte_length
        || reopened_metadata.len() != held.file.byte_length
    {
        return Err(format!(
            "collection output {} was replaced or changed",
            held.file.path
        ));
    }
    held.handle
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("rewind collection output {}: {error}", held.file.path))?;
    let mut hasher = Sha256::new();
    let mut remaining = held.file.byte_length;
    let mut buffer = [0_u8; 64 * 1024];
    while remaining > 0 {
        let limit = usize::try_from(remaining.min(buffer.len() as u64)).unwrap();
        let read = held
            .handle
            .read(&mut buffer[..limit])
            .map_err(|error| format!("read collection output {}: {error}", held.file.path))?;
        if read == 0 {
            return Err(format!(
                "collection output {} ended before its ledger length",
                held.file.path
            ));
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    let digest = format!("{:x}", hasher.finalize());
    if digest != held.file.sha256 {
        return Err(format!(
            "collection output {} no longer matches its ledger hash",
            held.file.path
        ));
    }
    Ok(())
}

fn validate_rgb_tiff(file: &File, infrared: bool) -> Result<(), String> {
    // The decoder checks the TIFF's structural sample type only. The
    // engine-bound capture binding and receipt provide provenance; tags alone
    // do not establish a linear transfer function.
    let mut decoder = tiff::decoder::Decoder::new(
        file.try_clone()
            .map_err(|error| format!("clone TIFF source: {error}"))?,
    )
    .map_err(|error| format!("decode raw export TIFF header: {error}"))?;
    let expected = if infrared {
        tiff::ColorType::Gray(16)
    } else {
        tiff::ColorType::RGB(16)
    };
    if decoder
        .colortype()
        .map_err(|error| format!("read raw export TIFF color type: {error}"))?
        != expected
    {
        return Err(if infrared {
            "raw infrared TIFF is not the engine-bound Gray16 export contract"
        } else {
            "raw RGB TIFF is not the engine-bound RGB16 export contract"
        }
        .into());
    }
    if infrared
        && decoder
            .get_tag_u8_vec(tiff::tags::Tag::Unknown(RAW_IR_TAG))
            .map_err(|error| format!("read raw infrared TIFF marker: {error}"))?
            != RAW_IR_MARKER
    {
        return Err("raw infrared TIFF lacks the uint16 marker contract".into());
    }
    Ok(())
}

fn locked_exposure_metadata(
    project: &ScanProject,
    metadata: &CollectionMetadata,
) -> serde_json::Value {
    project
        .roll_exposure_lock
        .as_ref()
        .map(|lock| {
            serde_json::json!({
                "source": "project.rollExposureLock",
                "slot": lock.slot,
                "rgbTicks10ns": lock.rgb_exposures_raw_10ns,
                "irMeteredTicks10ns": lock.ir_metered_exposure_raw_10ns,
                "meterEvidencePath": lock.meter_evidence_path,
                "meterEvidenceSha256": lock.meter_evidence_sha256,
                "journalPath": lock.journal_path,
                "journalSha256": lock.journal_sha256,
            })
        })
        .or_else(|| metadata.locked_exposure.clone())
        .unwrap_or_else(|| serde_json::json!({ "source": "auto" }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{
        CaptureRecipe, FilmProcess, FrameAlignment, MediaCarrier, MetadataOutputBindings,
        MetadataSet, OutputRecipe, ProjectFrame, ScanProject, WrittenOutputs,
    };
    use std::collections::BTreeMap;

    fn tiny_tiff(infrared: bool, valid_marker: bool) -> Vec<u8> {
        use std::io::Cursor;
        use tiff::encoder::colortype::{Gray16, RGB16};
        use tiff::encoder::TiffEncoder;
        use tiff::tags::Tag;

        let mut output = Cursor::new(Vec::new());
        {
            let mut encoder = TiffEncoder::new(&mut output).unwrap();
            if infrared {
                let mut image = encoder.new_image::<Gray16>(1, 1).unwrap();
                let marker = if valid_marker {
                    RAW_IR_MARKER
                } else {
                    b"wrong-marker\0"
                };
                image
                    .encoder()
                    .write_tag(Tag::Unknown(RAW_IR_TAG), marker)
                    .unwrap();
                image.write_data(&[0x1234]).unwrap();
            } else {
                let image = encoder.new_image::<RGB16>(1, 1).unwrap();
                image.write_data(&[0x1111, 0x2222, 0x3333]).unwrap();
            }
        }
        output.into_inner()
    }

    fn fixture_receipt(job_id: &str, frame_index: u32, pass: &str) -> ScanReceipt {
        let event: serde_json::Value = serde_json::from_str(include_str!(
            "../../protocol/fixtures/09-frame-completed-event.json"
        ))
        .unwrap();
        let mut receipt: ScanReceipt =
            serde_json::from_value(event["payload"]["receipt"].clone()).unwrap();
        receipt.job_id = job_id.into();
        receipt.frame_index = frame_index;
        receipt.pass_token = Some(pass.into());
        receipt.simulated = false;
        receipt
    }

    fn bind_file(root: &Path, name: &str, bytes: &[u8]) -> WrittenFileBinding {
        let path = root.join(name);
        std::fs::write(&path, bytes).unwrap();
        let file = File::open(&path).unwrap();
        let metadata = file.metadata().unwrap();
        let identity = crate::exiftool::held_file_identity(&file, &metadata).unwrap();
        WrittenFileBinding {
            relative_path: name.into(),
            sha256: format!("{:x}", Sha256::digest(bytes)),
            byte_length: bytes.len() as u64,
            volume_id: Some(identity.0),
            file_id: Some(identity.1),
        }
    }

    fn with_outputs(
        mut receipt: ScanReceipt,
        root: &Path,
        raw_enabled: bool,
        prefix: &str,
    ) -> ScanReceipt {
        let meter_bytes = format!("meter-{prefix}").into_bytes();
        let positive_bytes = format!("positive-{prefix}").into_bytes();
        let meter_name = format!("{prefix}-meter.bin");
        let positive_name = format!("{prefix}-positive.tif");
        let meter = bind_file(root, &meter_name, &meter_bytes);
        let positive = bind_file(root, &positive_name, &positive_bytes);
        let (raw_negative, raw_negative_ir, raw_negative_path, raw_negative_ir_path) =
            if raw_enabled {
                let raw_name = format!("{prefix}-raw.tif");
                let ir_name = format!("{prefix}-raw-ir.tif");
                let raw_bytes = tiny_tiff(false, true);
                let ir_bytes = tiny_tiff(true, true);
                let raw = bind_file(root, &raw_name, &raw_bytes);
                let ir = bind_file(root, &ir_name, &ir_bytes);
                (
                    Some(raw),
                    Some(ir),
                    Some(root.join(&raw_name).display().to_string()),
                    Some(root.join(&ir_name).display().to_string()),
                )
            } else {
                (None, None, None, None)
            };
        receipt.meter_rgbi_path = Some(root.join(&meter_name).display().to_string());
        receipt.output = Some(OutputRecipe {
            raw_export: crate::domain::RawExportRecipe {
                enabled: raw_enabled,
                ..Default::default()
            },
            ..OutputRecipe::default()
        });
        receipt.outputs = Some(WrittenOutputs {
            archive_path: None,
            positive_path: Some(root.join(&positive_name).display().to_string()),
            preview_path: None,
            raw_negative_path,
            raw_negative_ir_path,
            metadata_bindings: Some(MetadataOutputBindings {
                positive: Some(positive),
                ..Default::default()
            }),
            capture_bindings: Some(crate::domain::CaptureOutputBindings {
                raw_negative,
                raw_negative_ir,
                meter: Some(meter),
            }),
            derivative_transform: Default::default(),
        });
        receipt
    }

    fn collection_project(receipts: Vec<ScanReceipt>) -> ScanProject {
        ScanProject {
            schema_version: 1,
            id: "collection-project".into(),
            name: "collection-project".into(),
            carrier: MediaCarrier::Roll36,
            frame_count: receipts.len() as u32,
            film_process: FilmProcess::C41ColorNegative,
            recipes: OutputRecipe::default(),
            roll_metadata: MetadataSet::default(),
            roll_exposure_lock: None,
            created_at: "2026-09-08T00:00:00Z".into(),
            frames: receipts
                .into_iter()
                .map(|receipt| ProjectFrame {
                    index: receipt.frame_index,
                    excluded: false,
                    capture_override: Some(CaptureRecipe::default()),
                    processing_override: None,
                    output_override: None,
                    alignment: Some(FrameAlignment::draft(0)),
                    metadata_override: None,
                    receipts: vec![receipt],
                })
                .collect(),
        }
    }

    #[test]
    fn tiff_contract_and_create_only_output_refuse_bad_inputs() {
        let root = std::env::temp_dir().join(format!(
            "scanstudio-collection-helper-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let rgb = root.join("rgb.tif");
        let ir = root.join("ir.tif");
        std::fs::write(&rgb, tiny_tiff(false, true)).unwrap();
        std::fs::write(&ir, tiny_tiff(true, true)).unwrap();
        validate_rgb_tiff(&File::open(&rgb).unwrap(), false).unwrap();
        validate_rgb_tiff(&File::open(&ir).unwrap(), true).unwrap();

        std::fs::write(&ir, tiny_tiff(true, false)).unwrap();
        assert!(validate_rgb_tiff(&File::open(&ir).unwrap(), true).is_err());
        std::fs::remove_file(&ir).unwrap();
        assert!(File::open(&ir).is_err());

        let destination = root.join("destination");
        std::fs::create_dir(&destination).unwrap();
        let destination_handle =
            crate::exiftool::metadata_publish_sys::open_directory(&destination).unwrap();
        write_new_file(&destination_handle, "same", b"one").unwrap();
        assert!(write_new_file(&destination_handle, "same", b"two").is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn collect_and_verify_bound_a_and_b_artifacts_create_only() {
        let root = std::env::temp_dir().join(format!(
            "scanstudio-collection-flow-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let mut a = with_outputs(fixture_receipt("job-a", 1, "A1"), &root, true, "a");
        let archive_name = "a-archive.tif";
        let archive = bind_file(&root, archive_name, b"archive-a");
        a.outputs.as_mut().unwrap().archive_path =
            Some(root.join(archive_name).display().to_string());
        a.outputs
            .as_mut()
            .unwrap()
            .metadata_bindings
            .as_mut()
            .unwrap()
            .archive = Some(archive);
        let b = with_outputs(fixture_receipt("job-b", 2, "B"), &root, false, "b");
        let project = collection_project(vec![a.clone(), b.clone()]);
        let export_parent = root.join("exports");
        std::fs::create_dir(&export_parent).unwrap();
        let metadata_a = CollectionMetadata {
            stock: "stock".into(),
            pass: "A1".into(),
            slot_map: BTreeMap::from([(1, 20)]),
            firmware: None,
            adapter: None,
            host: None,
            operator: None,
            app_version: None,
            driver_version: None,
            locked_exposure: None,
        };
        let source_before = std::fs::read(root.join("a-raw.tif")).unwrap();
        let verified = verify_artifacts(&root, &project, Some("A1"));
        assert!(
            verified.is_empty(),
            "unexpected artifact issues: {verified:?}"
        );
        let out_a = export_parent.join("a");
        let result_a = collect(&root, &project, None, &out_a, &metadata_a).unwrap();
        assert!(result_a
            .files
            .iter()
            .any(|file| file.path == "stock_20_A1.tif"));
        assert_eq!(
            std::fs::read(out_a.join("stock_20_A1.tif")).unwrap(),
            source_before
        );
        let ledger = std::fs::read_to_string(&result_a.hashes_path).unwrap();
        assert!(ledger.contains(&format!(
            "{}  stock_20_A1.tif",
            a.outputs
                .as_ref()
                .unwrap()
                .capture_bindings
                .as_ref()
                .unwrap()
                .raw_negative
                .as_ref()
                .unwrap()
                .sha256
        )));
        assert_eq!(
            std::fs::read(root.join("a-raw.tif")).unwrap(),
            source_before
        );

        let metadata_b = CollectionMetadata {
            stock: "stock".into(),
            pass: "B".into(),
            slot_map: BTreeMap::from([(2, 21)]),
            ..metadata_a.clone()
        };
        let out_b = export_parent.join("b");
        collect(&root, &project, None, &out_b, &metadata_b).unwrap();
        assert!(!out_b.join("stock_21_B.tif").exists());
        assert!(out_b.join("stock_21_B-meter.tif").exists());

        let mut corrupt = project.clone();
        corrupt.frames[0].receipts[0]
            .outputs
            .as_mut()
            .unwrap()
            .capture_bindings
            .as_mut()
            .unwrap()
            .meter
            .as_mut()
            .unwrap()
            .sha256 = "0".repeat(64);
        let corrupt_report = verify_artifacts(&root, &corrupt, Some("A1"));
        assert!(corrupt_report.iter().any(
            |issue| issue.field.ends_with("meter") && issue.job_id.as_deref() == Some("job-a")
        ));
        corrupt.frames[0].receipts[0]
            .outputs
            .as_mut()
            .unwrap()
            .metadata_bindings
            .as_mut()
            .unwrap()
            .archive
            .as_mut()
            .unwrap()
            .sha256 = "f".repeat(64);
        assert!(verify_artifacts(&root, &corrupt, Some("A1"))
            .iter()
            .any(|issue| issue.field.ends_with("archive")
                && issue.status == VerificationStatus::Fail));
        assert!(collect(&root, &project, None, &out_a, &metadata_a).is_err());
        let mut invalid_slots = metadata_a.clone();
        invalid_slots.slot_map = BTreeMap::from([(1, 0)]);
        assert!(collect(
            &root,
            &project,
            None,
            &export_parent.join("invalid"),
            &invalid_slots
        )
        .is_err());
        assert!(collect(
            &root,
            &project,
            None,
            Path::new("relative-collection-destination"),
            &metadata_a
        )
        .is_err());
        std::fs::remove_file(root.join("a-meter.bin")).unwrap();
        assert_eq!(
            verify_artifacts(&root, &project, Some("A1"))
                .iter()
                .find(|issue| issue.field.ends_with("meter"))
                .map(|issue| issue.status),
            Some(VerificationStatus::Unknown)
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}

fn receipt_error(receipt: &ScanReceipt, detail: impl Into<String>) -> String {
    format!(
        "frame {} job {}: {}",
        receipt.frame_index,
        receipt.job_id,
        detail.into()
    )
}

fn validate_component(value: &str, label: &str) -> Result<(), String> {
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.ends_with(['.', ' '])
        || value.chars().any(|character| {
            character <= '\u{1f}'
                || matches!(
                    character,
                    '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
                )
        })
    {
        return Err(format!("{label} is not a safe filename component"));
    }
    Ok(())
}
