//! Offline retained-master rendering and create-only export operations.
//!
//! These operations deliberately work from engine-authored receipt bindings.
//! Display paths in a legacy receipt never become read authority, and neither
//! operation reaches a scanner backend or mutates a manifest/receipt.

use std::ffi::OsStr;
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::domain::{self, ScanProject, ScanReceipt, WrittenFileBinding};
use crate::render;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationResult {
    pub operation: String,
    pub files: Vec<OperationFile>,
    pub result_sidecar: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationFile {
    pub frame_index: u32,
    pub path: String,
    pub byte_length: u64,
    pub sha256: String,
}

fn invalid(message: impl Into<String>) -> String {
    message.into()
}

fn selected_frames(project: &ScanProject, requested: &[u32]) -> Result<Vec<u32>, String> {
    if requested.is_empty() {
        return Err(invalid("at least one frame is required"));
    }
    let mut frames = requested.to_vec();
    frames.sort_unstable();
    frames.dedup();
    for frame in &frames {
        if *frame == 0 || !project.frames.iter().any(|value| value.index == *frame) {
            return Err(invalid(format!("frame {frame} does not exist in the active project")));
        }
    }
    Ok(frames)
}

fn latest_receipt<'a>(
    project: &'a ScanProject,
    frame_index: u32,
    kind: &str,
) -> Result<&'a ScanReceipt, String> {
    let frame = project
        .frames
        .iter()
        .find(|frame| frame.index == frame_index)
        .ok_or_else(|| invalid(format!("frame {frame_index} does not exist")))?;
    frame
        .receipts
        .iter()
        .rev()
        .find(|receipt| {
            let Some(outputs) = receipt.outputs.as_ref() else { return false };
            match kind {
                "master" | "archive" => outputs
                    .metadata_bindings
                    .as_ref()
                    .and_then(|bindings| bindings.archive.as_ref())
                    .is_some(),
                "positive" => outputs
                    .metadata_bindings
                    .as_ref()
                    .and_then(|bindings| bindings.positive.as_ref())
                    .is_some(),
                "raw" => outputs
                    .capture_bindings
                    .as_ref()
                    .and_then(|bindings| bindings.raw_negative.as_ref())
                    .is_some(),
                _ => false,
            }
        })
        .ok_or_else(|| invalid(format!("frame {frame_index} has no engine-bound {kind} output")))
}

fn bound_source(
    authority: &render::ProjectOutputRootAuthority,
    binding: &WrittenFileBinding,
    recorded_path: Option<&str>,
    role: &str,
) -> Result<(File, PathBuf), String> {
    let source = crate::calibration_collection::open_bound_source(
        authority,
        binding,
        recorded_path,
        role,
    )?;
    Ok((source, authority.canonical_path().join(&binding.relative_path)))
}

fn profile(value: &str) -> Result<domain::OutputColorProfile, String> {
    match value.trim().to_ascii_lowercase().as_str() {
        "srgb" | "s-rgb" => Ok(domain::OutputColorProfile::SRgb),
        "adobergb1998" | "adobe-rgb-1998" | "adobe_rgb_1998" => {
            Ok(domain::OutputColorProfile::AdobeRgb1998)
        }
        "prophoto" | "prophotorgb" | "prophoto-rgb" => {
            Ok(domain::OutputColorProfile::ProPhotoRgb)
        }
        _ => Err(invalid("profile must be srgb, adobeRgb1998, or proPhotoRgb")),
    }
}

fn write_sidecar(directory: &Path, name: &str, value: &serde_json::Value) -> Result<String, String> {
    let canonical = std::fs::canonicalize(directory)
        .map_err(|error| format!("resolve result directory {}: {error}", directory.display()))?;
    let root = crate::exiftool::metadata_publish_sys::open_directory(&canonical)
        .map_err(|error| format!("open result directory {}: {error}", canonical.display()))?;
    crate::exiftool::verify_directory_path_authority(&canonical, &root, "result directory")
        .map_err(|error| error.message)?;
    let mut output = crate::exiftool::metadata_publish_sys::create_new_regular(&root, OsStr::new(name))
        .map_err(|error| format!("create result sidecar {}: {error}", canonical.join(name).display()))?;
    let bytes = serde_json::to_vec_pretty(value).map_err(|error| format!("encode result sidecar: {error}"))?;
    output
        .write_all(&bytes)
        .map_err(|error| format!("write result sidecar: {error}"))?;
    output
        .sync_all()
        .map_err(|error| format!("sync result sidecar: {error}"))?;
    Ok(canonical.join(name).display().to_string())
}

pub(crate) fn render(
    authority: &render::ProjectOutputRootAuthority,
    project: &ScanProject,
    params: &crate::protocol::RollRenderParams,
) -> Result<OperationResult, String> {
    let frames = selected_frames(project, &params.frames)?;
    let color_profile = profile(&params.profile)?;
    let output = Path::new(&params.output);
    if !output.is_absolute() {
        return Err(invalid("render output must be an absolute directory"));
    }
    authority.verify_namespace().map_err(|error| error.message)?;
    let mut files = Vec::new();
    for frame_index in frames {
        let receipt = latest_receipt(project, frame_index, "archive")?;
        let outputs = receipt.outputs.as_ref().ok_or_else(|| invalid("receipt has no outputs"))?;
        let binding = outputs
            .metadata_bindings
            .as_ref()
            .and_then(|bindings| bindings.archive.as_ref())
            .ok_or_else(|| invalid(format!("frame {frame_index} has no archive binding")))?;
        let (_source, archive_path) = bound_source(&authority, binding, outputs.archive_path.as_deref(), "archive")?;

        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.enabled = false;
        recipes.raw_export.enabled = false;
        recipes.preview.enabled = false;
        recipes.positive.enabled = true;
        recipes.positive.destination = output.display().to_string();
        recipes.positive.color_profile = color_profile;
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.positive.filename_template = format!("rendered-$ScanStudioSequence({frame_index})");
        let processing = receipt
            .processing
            .clone()
            .unwrap_or_default()
            .effective();
        let written = render::render_derivative_from_archive_with_processing_bound(
            &archive_path,
            frame_index,
            &processing,
            &recipes,
            receipt.storage_transform.as_deref(),
            None,
            None,
            project
                .frames
                .iter()
                .find(|value| value.index == frame_index)
                .and_then(|value| value.alignment.as_ref()),
            None,
            receipt.resolution_dpi,
            binding,
        )
        .map_err(|error| error.message)?;
        let path = written
            .positive_path
            .ok_or_else(|| invalid(format!("renderer produced no positive for frame {frame_index}")))?;
        let digest = SessionEvidenceDigest::from_path(&path)?;
        files.push(OperationFile { frame_index, path: path.display().to_string(), byte_length: digest.byte_length, sha256: digest.sha256 });
        authority.verify_namespace().map_err(|error| error.message)?;
    }
    let result_sidecar = write_sidecar(
        output,
        "render-result.json",
        &serde_json::json!({ "operation": "render", "profile": params.profile, "files": files }),
    )?;
    Ok(OperationResult { operation: "render".into(), files, result_sidecar })
}

pub(crate) fn export(
    authority: &render::ProjectOutputRootAuthority,
    project: &ScanProject,
    params: &crate::protocol::RollExportParams,
) -> Result<OperationResult, String> {
    let requested = params.frames.clone().unwrap_or_else(|| project.frames.iter().filter(|frame| !frame.receipts.is_empty()).map(|frame| frame.index).collect());
    let frames = selected_frames(project, &requested)?;
    let destination = Path::new(&params.to);
    if !destination.is_absolute() {
        return Err(invalid("export destination must be an absolute directory path"));
    }
    if params.template.trim().is_empty()
        || Path::new(&params.template).is_absolute()
        || Path::new(&params.template).components().count() != 1
        || params.template.contains("..")
    {
        return Err(invalid("export template must be one relative file-name pattern"));
    }
    let kind = params.kind.trim().to_ascii_lowercase();
    if !matches!(kind.as_str(), "positive" | "raw" | "master") {
        return Err(invalid("kind must be positive, raw, or master"));
    }
    let destination_leaf = destination
        .file_name()
        .ok_or_else(|| invalid("export destination has no directory name"))?;
    let destination_parent = destination
        .parent()
        .ok_or_else(|| invalid("export destination has no parent directory"))?;
    let canonical_parent = std::fs::canonicalize(destination_parent).map_err(|error| {
        format!(
            "resolve export destination parent {}: {error}",
            destination_parent.display()
        )
    })?;
    let parent_handle = crate::exiftool::metadata_publish_sys::open_directory(&canonical_parent)
        .map_err(|error| format!("open export destination parent: {error}"))?;
    crate::exiftool::verify_directory_path_authority(
        &canonical_parent,
        &parent_handle,
        "export destination parent",
    )
    .map_err(|error| error.message)?;
    if destination.exists() {
        return Err(invalid(format!(
            "export destination already exists: {}",
            destination.display()
        )));
    }
    let destination_handle = render::create_evidence_directory_nondestructive(
        &parent_handle,
        destination_leaf,
    )
    .map_err(|error| format!("create export destination: {error}"))?;
    let canonical_destination = std::fs::canonicalize(destination).map_err(|error| {
        format!(
            "resolve created export destination {}: {error}",
            destination.display()
        )
    })?;
    crate::exiftool::verify_directory_path_authority(
        &canonical_destination,
        &destination_handle,
        "export destination",
    )
    .map_err(|error| error.message)?;
    authority.verify_namespace().map_err(|error| error.message)?;
    let mut files = Vec::new();
    for frame_index in frames {
        let receipt = latest_receipt(project, frame_index, &kind)?;
        let outputs = receipt.outputs.as_ref().ok_or_else(|| invalid("receipt has no outputs"))?;
        let (binding, recorded, role) = match kind.as_str() {
            "positive" => (
                outputs.metadata_bindings.as_ref().and_then(|value| value.positive.as_ref()),
                outputs.positive_path.as_deref(),
                "positive",
            ),
            "master" => (
                outputs.metadata_bindings.as_ref().and_then(|value| value.archive.as_ref()),
                outputs.archive_path.as_deref(),
                "master",
            ),
            "raw" => (
                outputs.capture_bindings.as_ref().and_then(|value| value.raw_negative.as_ref()),
                outputs.raw_negative_path.as_deref(),
                "raw",
            ),
            _ => unreachable!(),
        };
        let binding = binding.ok_or_else(|| invalid(format!("frame {frame_index} has no {role} binding")))?;
        let (input, source_path) = bound_source(&authority, binding, recorded, role)?;
        let metadata = crate::exiftool::resolve_effective_metadata(project, frame_index)
            .map_err(|error| error.message)?;
        let materialized = render::materialize_filename_tokens_with_pass(
            &params.template,
            &metadata,
            receipt.pass_token.as_deref(),
        );
        let name = render::resolve_filename(&materialized, frame_index);
        if Path::new(&name).components().count() != 1 {
            return Err(invalid("export template resolved to an unsafe path"));
        }
        let mut output = crate::exiftool::metadata_publish_sys::create_new_regular(&destination_handle, OsStr::new(&name))
            .map_err(|error| format!("create export {}: {error}", canonical_destination.join(&name).display()))?;
        let digest = crate::evidence_package::copy_held_file(input, &source_path, &mut output, Path::new(&name), binding.byte_length)?;
        if digest != binding.sha256 {
            return Err(invalid(format!("{role} binding hash changed while exporting frame {frame_index}")));
        }
        files.push(OperationFile { frame_index, path: canonical_destination.join(&name).display().to_string(), byte_length: binding.byte_length, sha256: digest });
        authority.verify_namespace().map_err(|error| error.message)?;
        crate::exiftool::verify_directory_path_authority(&canonical_destination, &destination_handle, "export destination")
            .map_err(|error| error.message)?;
    }
    let result_sidecar = write_sidecar(
        &canonical_destination,
        "export-result.json",
        &serde_json::json!({ "operation": "export", "kind": kind, "template": params.template, "files": files }),
    )?;
    Ok(OperationResult { operation: "export".into(), files, result_sidecar })
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataApplyFile {
    pub frame_index: u32,
    pub path: String,
    pub source_sha256: String,
    pub output_sha256: String,
    pub readback_verified: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataApplyResult {
    pub operation: String,
    pub dry_run: bool,
    pub exiftool_available: bool,
    pub exiftool_path: Option<String>,
    pub targets: Vec<String>,
    pub arguments: Vec<String>,
    pub fingerprint: String,
    pub files: Vec<MetadataApplyFile>,
    pub result_sidecar: Option<String>,
}

fn metadata_apply_binding<'a>(
    outputs: &'a domain::WrittenOutputs,
    kind: &str,
) -> Result<(&'a WrittenFileBinding, Option<&'a str>, &'static str), String> {
    match kind {
        "positive" => outputs
            .metadata_bindings
            .as_ref()
            .and_then(|bindings| bindings.positive.as_ref())
            .map(|binding| (binding, outputs.positive_path.as_deref(), "positive"))
            .ok_or_else(|| invalid("receipt has no engine-bound positive output")),
        "master" => outputs
            .metadata_bindings
            .as_ref()
            .and_then(|bindings| bindings.archive.as_ref())
            .map(|binding| (binding, outputs.archive_path.as_deref(), "master"))
            .ok_or_else(|| invalid("receipt has no engine-bound retained master")),
        "raw" => outputs
            .capture_bindings
            .as_ref()
            .and_then(|bindings| bindings.raw_negative.as_ref())
            .map(|binding| (binding, outputs.raw_negative_path.as_deref(), "raw"))
            .ok_or_else(|| invalid("receipt has no engine-bound raw output")),
        _ => Err(invalid("kind must be positive, raw, or master")),
    }
}

fn metadata_readback(
    detection: &crate::exiftool::ExifToolDetection,
    path: &Path,
    arguments: &[String],
) -> Result<(), String> {
    let output = crate::exiftool::execute_exiftool(
        detection,
        &["-j".into(), path.display().to_string()],
    )
    .map_err(|error| error.message)?;
    if !output.status.success() {
        return Err(format!(
            "ExifTool metadata readback failed for {}: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let value: serde_json::Value = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("ExifTool metadata readback was not JSON: {error}"))?;
    let object = value
        .as_array()
        .and_then(|items| items.first())
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| "ExifTool metadata readback contained no target object".to_string())?;
    for argument in arguments {
        let Some((tag, expected)) = argument.strip_prefix('-').and_then(|value| value.split_once('=')) else {
            continue;
        };
        let short_tag = tag.rsplit(':').next().unwrap_or(tag).trim_end_matches('+');
        let found = object.iter().find_map(|(key, value)| {
            let key_short = key.rsplit(':').next().unwrap_or(key);
            (key_short == short_tag).then(|| value.to_string())
        });
        let Some(found) = found else {
            return Err(format!("ExifTool readback omitted {short_tag} for {}", path.display()));
        };
        let expected_digits: String = expected.chars().filter(char::is_ascii_digit).collect();
        let found_digits: String = found.chars().filter(char::is_ascii_digit).collect();
        let matches = found.contains(expected)
            || (short_tag.eq_ignore_ascii_case("DateCreated")
                && !expected_digits.is_empty()
                && found_digits.starts_with(&expected_digits));
        if !matches {
            return Err(format!(
                "ExifTool readback for {short_tag} did not contain the requested value"
            ));
        }
    }
    Ok(())
}

pub(crate) fn metadata_apply(
    authority: &render::ProjectOutputRootAuthority,
    project: &ScanProject,
    params: &crate::protocol::RollMetadataApplyParams,
) -> Result<MetadataApplyResult, String> {
    let frames = selected_frames(project, &params.frames)?;
    let kind = params.kind.trim().to_ascii_lowercase();
    if !matches!(kind.as_str(), "positive" | "raw" | "master") {
        return Err(invalid("kind must be positive, raw, or master"));
    }
    let destination = Path::new(&params.to);
    if !destination.is_absolute() {
        return Err(invalid("metadata apply destination must be an absolute directory path"));
    }
    if params.template.trim().is_empty()
        || Path::new(&params.template).is_absolute()
        || Path::new(&params.template).components().count() != 1
        || params.template.contains("..")
    {
        return Err(invalid("metadata apply template must be one relative file-name pattern"));
    }

    let mut targets = Vec::with_capacity(frames.len());
    for frame_index in frames {
        let receipt = latest_receipt(project, frame_index, &kind)?;
        let outputs = receipt
            .outputs
            .as_ref()
            .ok_or_else(|| invalid(format!("frame {frame_index} has no written outputs")))?;
        let (binding, recorded, role) = metadata_apply_binding(outputs, &kind)?;
        let metadata = crate::exiftool::resolve_effective_metadata(project, frame_index)
            .map_err(|error| error.message)?;
        let materialized = render::materialize_filename_tokens_with_pass(
            &params.template,
            &metadata,
            receipt.pass_token.as_deref(),
        );
        let name = render::resolve_filename(&materialized, frame_index);
        if Path::new(&name).components().count() != 1 {
            return Err(invalid("metadata apply template resolved to an unsafe path"));
        }
        targets.push((frame_index, name, binding.clone(), recorded.map(str::to_owned), role));
    }
    let metadata_arguments = crate::exiftool::build_exiftool_arguments(&params.metadata);
    let detection = crate::exiftool::detect_exiftool();
    let target_paths: Vec<String> = targets
        .iter()
        .map(|(_, name, _, _, _)| destination.join(name).display().to_string())
        .collect();
    let mut arguments = metadata_arguments.clone();
    if !metadata_arguments.is_empty() {
        arguments.push("-overwrite_original".into());
        arguments.extend(target_paths.iter().cloned());
    }
    let fingerprint = crate::exiftool::metadata_approval_fingerprint(&arguments, &detection);
    let base_result = |files, sidecar| MetadataApplyResult {
        operation: "metadata.apply".into(),
        dry_run: params.dry_run,
        exiftool_available: detection.available,
        exiftool_path: detection.path.clone(),
        targets: target_paths.clone(),
        arguments: arguments.clone(),
        fingerprint: fingerprint.clone(),
        files,
        result_sidecar: sidecar,
    };
    if params.dry_run {
        return Ok(base_result(Vec::new(), None));
    }
    if metadata_arguments.is_empty() {
        return Err(invalid("metadata apply requires at least one metadata field"));
    }
    if !detection.available {
        return Err(invalid(
            "ExifTool is not available — install it or set SCANSTUDIO_EXIFTOOL_PATH",
        ));
    }

    let destination_leaf = destination
        .file_name()
        .ok_or_else(|| invalid("metadata apply destination has no directory name"))?;
    let destination_parent = destination
        .parent()
        .ok_or_else(|| invalid("metadata apply destination has no parent directory"))?;
    let canonical_parent = std::fs::canonicalize(destination_parent)
        .map_err(|error| format!("resolve metadata apply parent: {error}"))?;
    let parent_handle = crate::exiftool::metadata_publish_sys::open_directory(&canonical_parent)
        .map_err(|error| format!("open metadata apply parent: {error}"))?;
    crate::exiftool::verify_directory_path_authority(&canonical_parent, &parent_handle, "metadata apply parent")
        .map_err(|error| error.message)?;
    if destination.exists() {
        return Err(invalid(format!(
            "metadata apply destination already exists: {}",
            destination.display()
        )));
    }
    let destination_handle = render::create_evidence_directory_nondestructive(&parent_handle, destination_leaf)
        .map_err(|error| format!("create metadata apply destination: {error}"))?;
    let canonical_destination = std::fs::canonicalize(destination)
        .map_err(|error| format!("resolve metadata apply destination: {error}"))?;
    let mut files = Vec::with_capacity(targets.len());
    for (frame_index, name, binding, recorded, role) in targets {
        let (input, source_path) = bound_source(authority, &binding, recorded.as_deref(), role)?;
        let destination_name = name.clone();
        let destination_path = canonical_destination.join(&destination_name);
        let file = crate::exiftool::with_private_exiftool_copy(
            input,
            &source_path,
            &binding,
            &detection,
            &metadata_arguments,
            |transformed, staged_path, transformed_binding| {
                metadata_readback(&detection, staged_path, &metadata_arguments)?;
                let mut output = crate::exiftool::metadata_publish_sys::create_new_regular(
                    &destination_handle,
                    OsStr::new(&destination_name),
                )
                .map_err(|error| format!("create metadata copy {}: {error}", destination_path.display()))?;
                let output_sha256 = crate::evidence_package::copy_held_file(
                    transformed.try_clone().map_err(|error| format!("clone private metadata output: {error}"))?,
                    staged_path,
                    &mut output,
                    Path::new(&destination_name),
                    transformed_binding.byte_length,
                )?;
                if output_sha256 != transformed_binding.sha256 {
                    return Err(format!("{role} output hash changed while publishing frame {frame_index}"));
                }
                output
                    .sync_all()
                    .map_err(|error| format!("sync metadata copy: {error}"))?;
                Ok(MetadataApplyFile {
                    frame_index,
                    path: destination_path.display().to_string(),
                    source_sha256: binding.sha256.clone(),
                    output_sha256,
                    readback_verified: true,
                })
            },
        )?;
        files.push(file);
    }
    authority.verify_namespace().map_err(|error| error.message)?;
    crate::exiftool::verify_directory_path_authority(&canonical_destination, &destination_handle, "metadata apply destination")
        .map_err(|error| error.message)?;
    let sidecar = write_sidecar(
        &canonical_destination,
        "metadata-apply-result.json",
        &serde_json::json!({
            "operation": "metadata.apply",
            "metadata": params.metadata,
            "targets": files,
            "sourceFilesRemainUntouched": true,
        }),
    )?;
    Ok(base_result(files, Some(sidecar)))
}

/// A bounded streaming digest used for operation result records.
pub(crate) struct SessionEvidenceDigest {
    pub byte_length: u64,
    pub sha256: String,
}

impl SessionEvidenceDigest {
    fn from_path(path: &Path) -> Result<Self, String> {
        use sha2::{Digest, Sha256};
        use std::io::Read;
        let mut file = File::open(path).map_err(|error| format!("open rendered output {}: {error}", path.display()))?;
        let mut hasher = Sha256::new();
        let mut length = 0_u64;
        let mut buffer = [0_u8; 64 * 1024];
        loop {
            let count = file.read(&mut buffer).map_err(|error| format!("read rendered output {}: {error}", path.display()))?;
            if count == 0 { break; }
            length = length.checked_add(count as u64).ok_or("rendered output length overflow")?;
            hasher.update(&buffer[..count]);
        }
        Ok(Self { byte_length: length, sha256: format!("{:x}", hasher.finalize()) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{MetadataOutputBindings, ProjectFrame, WrittenOutputs};
    use sha2::{Digest, Sha256};

    fn bound_file(root: &Path, path: &Path) -> WrittenFileBinding {
        let canonical_root = std::fs::canonicalize(root).unwrap();
        let canonical_path = std::fs::canonicalize(path).unwrap();
        let bytes = std::fs::read(&canonical_path).unwrap();
        let file = File::open(&canonical_path).unwrap();
        let metadata = file.metadata().unwrap();
        let identity = crate::exiftool::held_file_identity(&file, &metadata).unwrap();
        WrittenFileBinding {
            relative_path: canonical_path
                .strip_prefix(&canonical_root)
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            sha256: format!("{:x}", Sha256::digest(&bytes)),
            byte_length: bytes.len() as u64,
            volume_id: Some(identity.0),
            file_id: Some(identity.1),
        }
    }

    #[test]
    fn sidecar_is_create_only_and_collision_preserves_original() {
        let directory = std::env::temp_dir().join(format!(
            "scanstudio-render-export-test-{}",
            crate::manifest::generate_project_id()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let first = write_sidecar(&directory, "result.json", &serde_json::json!({"ok": true})).unwrap();
        let original = std::fs::read(&first).unwrap();
        let error = write_sidecar(&directory, "result.json", &serde_json::json!({"ok": false}))
            .expect_err("a result sidecar must never overwrite an existing file");
        assert!(error.contains("create result sidecar"));
        assert_eq!(std::fs::read(&first).unwrap(), original);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn profile_and_frame_selection_are_explicit() {
        assert_eq!(profile("sRGB").unwrap(), domain::OutputColorProfile::SRgb);
        assert!(profile("unknown").is_err());
        let project = ScanProject {
            schema_version: 1,
            id: "test".into(),
            name: "test".into(),
            carrier: domain::MediaCarrier::Roll36,
            frame_count: 2,
            film_process: domain::FilmProcess::C41ColorNegative,
            recipes: domain::OutputRecipe::default(),
            roll_metadata: domain::MetadataSet::default(),
            roll_exposure_lock: None,
            created_at: "now".into(),
            frames: vec![],
        };
        assert!(selected_frames(&project, &[1]).is_err());
    }

    #[test]
    fn retained_master_render_export_and_tamper_refusal_preserve_original() {
        let root = std::env::temp_dir().join(format!(
            "scanstudio-render-export-retained-{}",
            crate::manifest::generate_project_id()
        ));
        std::fs::create_dir_all(&root).unwrap();

        let mut capture_output = domain::OutputRecipe::default();
        capture_output.archive.destination = root.display().to_string();
        capture_output.archive.filename_template = "master-####.tif".into();
        capture_output.positive.enabled = false;
        capture_output.preview.enabled = false;
        capture_output.raw_export.enabled = false;
        let written = render::render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::C41ColorNegative,
            2,
            1,
            16,
            &capture_output,
            None,
            None,
        )
        .unwrap();
        let archive = written.archive_path.unwrap();
        let original = std::fs::read(&archive).unwrap();
        let binding = bound_file(&root, &archive);

        let event: serde_json::Value = serde_json::from_str(include_str!(
            "../../protocol/fixtures/09-frame-completed-event.json"
        ))
        .unwrap();
        let mut receipt: ScanReceipt = serde_json::from_value(event["payload"]["receipt"].clone())
            .unwrap();
        receipt.job_id = "retained-render-export".into();
        receipt.frame_index = 1;
        receipt.pass_token = Some("A".into());
        receipt.storage_transform = Some(render::STORAGE_TRANSFORM_SWAPAXES01.into());
        receipt.output = Some(capture_output.clone());
        receipt.processing = Some(domain::ProcessingRecipe {
            film_process: domain::FilmProcess::C41ColorNegative,
            ..domain::ProcessingRecipe::default()
        });
        receipt.outputs = Some(WrittenOutputs {
            archive_path: Some(archive.display().to_string()),
            positive_path: None,
            preview_path: None,
            raw_negative_path: None,
            raw_negative_ir_path: None,
            metadata_bindings: Some(MetadataOutputBindings {
                archive: Some(binding),
                ..MetadataOutputBindings::default()
            }),
            capture_bindings: None,
            derivative_transform: domain::DerivativeTransform::default(),
        });
        let project = ScanProject {
            schema_version: 1,
            id: "retained-render-export".into(),
            name: "retained-render-export".into(),
            carrier: domain::MediaCarrier::Roll36,
            frame_count: 1,
            film_process: domain::FilmProcess::C41ColorNegative,
            recipes: capture_output,
            roll_metadata: domain::MetadataSet {
                film_stock: Some("TestStock".into()),
                ..domain::MetadataSet::default()
            },
            roll_exposure_lock: None,
            created_at: "2026-09-08T00:00:00Z".into(),
            frames: vec![ProjectFrame {
                index: 1,
                excluded: false,
                capture_override: None,
                processing_override: None,
                output_override: None,
                alignment: None,
                metadata_override: None,
                skip_records: vec![],
                receipts: vec![receipt],
            }],
        };
        let authority = render::acquire_project_output_root_authority(Some(&root))
            .unwrap()
            .unwrap();

        let metadata = domain::MetadataSet {
            camera: Some("Test Camera".into()),
            lens: Some("Test Lens".into()),
            film_stock: Some("Test Stock".into()),
            date: Some(domain::PartialDate::Exact {
                date: "2026-09-08".into(),
            }),
            notes: Some("retained-copy metadata".into()),
            ..domain::MetadataSet::default()
        };
        let dry_run_destination = root.join("metadata-dry-run");
        let dry_run = metadata_apply(
            &authority,
            &project,
            &crate::protocol::RollMetadataApplyParams {
                frames: vec![1],
                to: dry_run_destination.display().to_string(),
                template: "$Pass-####.tif".into(),
                kind: "master".into(),
                metadata: metadata.clone(),
                dry_run: true,
            },
        )
        .unwrap();
        assert!(dry_run.dry_run);
        assert!(!dry_run_destination.exists(), "dry-run must not create a destination");

        let collision_destination = root.join("metadata-collision");
        std::fs::create_dir(&collision_destination).unwrap();
        let collision = metadata_apply(
            &authority,
            &project,
            &crate::protocol::RollMetadataApplyParams {
                frames: vec![1],
                to: collision_destination.display().to_string(),
                template: "$Pass-####.tif".into(),
                kind: "master".into(),
                metadata: metadata.clone(),
                dry_run: false,
            },
        );
        assert!(collision.is_err(), "existing destination must be refused");
        assert_eq!(std::fs::read(&archive).unwrap(), original);

        let metadata_destination = root.join("metadata-applied");
        let applied = metadata_apply(
            &authority,
            &project,
            &crate::protocol::RollMetadataApplyParams {
                frames: vec![1],
                to: metadata_destination.display().to_string(),
                template: "$Pass-####.tif".into(),
                kind: "master".into(),
                metadata,
                dry_run: false,
            },
        )
        .unwrap();
        assert_eq!(applied.files.len(), 1);
        assert!(applied.files[0].readback_verified);
        assert_eq!(std::fs::read(&archive).unwrap(), original);

        let rendered = root.join("rendered");
        let result = render(
            &authority,
            &project,
            &crate::protocol::RollRenderParams {
                frames: vec![1],
                profile: "adobeRgb1998".into(),
                output: rendered.display().to_string(),
            },
        )
        .unwrap();
        assert_eq!(result.files.len(), 1);
        assert!(!result.files[0].path.is_empty());
        assert_eq!(std::fs::read(&archive).unwrap(), original);

        let exported = root.join("exported");
        let export_result = export(
            &authority,
            &project,
            &crate::protocol::RollExportParams {
                to: exported.display().to_string(),
                template: "$Pass-####.tif".into(),
                kind: "master".into(),
                frames: Some(vec![1]),
            },
        )
        .unwrap();
        assert_eq!(export_result.files.len(), 1);
        assert!(exported.join("A-0001.tif").is_file());
        assert_eq!(std::fs::read(&archive).unwrap(), original);

        let mut tampered = original.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 0x01;
        std::fs::write(&archive, tampered).unwrap();
        let error = render(
            &authority,
            &project,
            &crate::protocol::RollRenderParams {
                frames: vec![1],
                profile: "adobeRgb1998".into(),
                output: root.join("tampered-render").display().to_string(),
            },
        )
        .expect_err("a changed retained master must fail its engine binding");
        assert!(error.contains("binding"), "unexpected refusal: {error}");

        let _ = std::fs::remove_dir_all(root);
    }
}
