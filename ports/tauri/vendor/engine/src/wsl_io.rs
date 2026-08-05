//! Windows/WSL capture-file handoff.
//!
//! The bridge runs inside WSL and must never receive a native `C:\...`
//! destination. Real captures are written to a WSL-internal staging root,
//! copied by the native Windows engine through the distro UNC share, checked
//! byte-for-byte after the copy, and checked against the bridge receipt's
//! decoded-raster `ArtifactEvidence` before the staged source is removed.

use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};

use sha2::{Digest as _, Sha256};

use crate::bridge_protocol::{BridgeArtifactEvidence, BridgeScanReceipt};
use crate::domain::Channels;
use crate::parity::image_io;

pub const DEFAULT_WSL_DISTRO: &str = "Ubuntu-24.04";
pub const WSL_STAGING_BASE: &str = "/tmp/scanstudio-wsl-staging";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WslBridgeConfig {
    pub distro: String,
}

/// Detect the app's production WSL bridge lane. `is_windows` is injected so
/// unit tests exercise the decision without running Windows. A WSL command
/// must name the exact distribution whose UNC share the finalizer will read;
/// relying on the user's mutable default distribution is never accepted.
pub fn config_for_bridge_command(
    command: &str,
    is_windows: bool,
) -> Result<Option<WslBridgeConfig>, String> {
    if !is_windows {
        return Ok(None);
    }
    let parts = command.split_ascii_whitespace().collect::<Vec<_>>();
    let Some(first) = parts.first() else {
        return Ok(None);
    };
    let program = first.replace('\\', "/");
    let name = program.rsplit('/').next().unwrap_or(&program);
    if !name.eq_ignore_ascii_case("wsl.exe") && !name.eq_ignore_ascii_case("wsl") {
        return Ok(None);
    }

    let mut distro = None;
    let mut index = 1;
    while index < parts.len() {
        match parts[index] {
            "-d" | "--distribution" => {
                let value = parts
                    .get(index + 1)
                    .ok_or("WSL bridge command omitted the distribution after -d")?;
                distro = Some(*value);
                index += 2;
            }
            value if value.starts_with("--distribution=") => {
                distro = value.split_once('=').map(|(_, value)| value);
                index += 1;
            }
            _ => index += 1,
        }
    }
    let distro = distro.ok_or_else(|| {
        format!(
            "WSL bridge command must pin -d {DEFAULT_WSL_DISTRO}; the default distribution is not an evidence boundary"
        )
    })?;
    if distro != DEFAULT_WSL_DISTRO {
        return Err(format!(
            "WSL bridge command selected distribution {distro:?}; expected {DEFAULT_WSL_DISTRO:?}"
        ));
    }
    Ok(Some(WslBridgeConfig {
        distro: distro.to_string(),
    }))
}

/// Pure validation/mapping twin of the app-layer Phase 8 path mapper.
pub fn windows_to_wsl_path(input: &str) -> Result<String, String> {
    let value = input.trim();
    if value.is_empty() {
        return Err("empty Windows path".to_string());
    }
    if value.starts_with("\\\\") || value.starts_with("//") {
        return Err(format!(
            "UNC destination is not supported for WSL output mapping: {value:?}"
        ));
    }
    let bytes = value.as_bytes();
    if bytes.len() < 3
        || !bytes[0].is_ascii_alphabetic()
        || bytes[1] != b':'
        || !matches!(bytes[2], b'\\' | b'/')
    {
        return Err(format!(
            "expected an absolute Windows drive path such as C:\\\\Scans, got {value:?}"
        ));
    }
    let drive = (bytes[0] as char).to_ascii_lowercase();
    let segments = value[3..]
        .split(['\\', '/'])
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    if segments.iter().any(|part| matches!(*part, "." | "..")) {
        return Err(format!(
            "Windows destination contains a relative path component: {value:?}"
        ));
    }
    if segments.is_empty() {
        Ok(format!("/mnt/{drive}"))
    } else {
        Ok(format!("/mnt/{drive}/{}", segments.join("/")))
    }
}

pub fn staging_root(owner_token: &str) -> Result<String, String> {
    if owner_token.is_empty()
        || owner_token == "."
        || owner_token == ".."
        || owner_token.contains(['/', '\\'])
    {
        return Err("WSL staging owner token must be one safe path component".to_string());
    }
    Ok(format!("{WSL_STAGING_BASE}/{owner_token}"))
}

pub fn wsl_path_to_unc(config: &WslBridgeConfig, input: &str) -> Result<PathBuf, String> {
    let normalized = normalize_wsl_absolute(input)?;
    if config.distro.is_empty()
        || config.distro.contains(['/', '\\'])
        || matches!(config.distro.as_str(), "." | "..")
    {
        return Err("WSL distro name is not one safe path component".to_string());
    }
    let relative = normalized.trim_start_matches('/').replace('/', "\\");
    Ok(PathBuf::from(format!(
        r"\\wsl$\{}\{}",
        config.distro, relative
    )))
}

fn normalize_wsl_absolute(input: &str) -> Result<String, String> {
    let value = input.trim();
    if !value.starts_with('/') || value.contains('\\') {
        return Err(format!("expected an absolute WSL path, got {value:?}"));
    }
    let mut segments = Vec::new();
    for part in value.split('/') {
        if part.is_empty() {
            continue;
        }
        if matches!(part, "." | "..") {
            return Err(format!("WSL path contains a relative component: {value:?}"));
        }
        segments.push(part);
    }
    Ok(format!("/{}", segments.join("/")))
}

fn safe_wsl_component(value: &str) -> bool {
    !value.is_empty()
        && !matches!(value, "." | "..")
        && !value.contains(['/', '\\', '\0', ':', '*', '?', '"', '<', '>', '|'])
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ValidatedWslRoute {
    normalized: String,
    /// Absolute paths from the first security boundary through the leaf.
    /// Every item is inspected without following a leaf symlink before use.
    route: Vec<String>,
}

fn route_from_components(parts: &[&str]) -> Vec<String> {
    let mut route = Vec::with_capacity(parts.len());
    let mut current = String::new();
    for part in parts {
        current.push('/');
        current.push_str(part);
        route.push(current.clone());
    }
    route
}

fn validate_staging_artifact_route(input: &str) -> Result<ValidatedWslRoute, String> {
    let normalized = normalize_wsl_absolute(input)?;
    let parts = normalized
        .trim_start_matches('/')
        .split('/')
        .collect::<Vec<_>>();
    if parts.len() != 4
        || parts[0] != "tmp"
        || parts[1] != "scanstudio-wsl-staging"
        || !safe_wsl_component(parts[2])
        || !safe_wsl_component(parts[3])
    {
        return Err(format!(
            "WSL staged artifact must be one file under {WSL_STAGING_BASE}/<owner>: {input:?}"
        ));
    }
    let route = route_from_components(&parts);
    Ok(ValidatedWslRoute { normalized, route })
}

fn validate_pinned_attempts_route(input: &str) -> Result<ValidatedWslRoute, String> {
    let normalized = normalize_wsl_absolute(input)?;
    let parts = normalized
        .trim_start_matches('/')
        .split('/')
        .collect::<Vec<_>>();
    if parts.len() != 5
        || parts[0] != "home"
        || !safe_wsl_component(parts[1])
        || parts[2] != ".scanstudio"
        || parts[3] != "coolscanpy-attempts"
        || !safe_wsl_component(parts[4])
    {
        return Err(format!(
            "attemptsRoot must be one pinned session under /home/<user>/.scanstudio/coolscanpy-attempts: {input:?}"
        ));
    }
    let route = route_from_components(&parts);
    Ok(ValidatedWslRoute { normalized, route })
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ValidatedProvenanceRoutes {
    attempts: Option<ValidatedWslRoute>,
}

fn validate_provenance_routes(
    receipt: &BridgeScanReceipt,
) -> Result<ValidatedProvenanceRoutes, String> {
    let attempts = receipt
        .attempts_root
        .as_deref()
        .map(validate_pinned_attempts_route)
        .transpose()?;
    Ok(ValidatedProvenanceRoutes { attempts })
}

fn map_and_validate_route<F>(
    route: &ValidatedWslRoute,
    leaf_is_file: bool,
    mapper: &F,
) -> Result<PathBuf, String>
where
    F: Fn(&str) -> Result<PathBuf, String>,
{
    let mut mapped_leaf = None;
    for (index, item) in route.route.iter().enumerate() {
        let path = mapper(item)?;
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|error| format!("inspect WSL route {}: {error}", path.display()))?;
        if metadata.file_type().is_symlink() {
            return Err(format!("WSL route contains a symlink: {}", path.display()));
        }
        let is_leaf = index + 1 == route.route.len();
        if is_leaf && leaf_is_file {
            if !metadata.is_file() {
                return Err(format!(
                    "WSL route leaf is not a regular file: {}",
                    path.display()
                ));
            }
        } else if !metadata.is_dir() {
            return Err(format!(
                "WSL route ancestor is not a directory: {}",
                path.display()
            ));
        }
        mapped_leaf = Some(path);
    }
    mapped_leaf.ok_or("validated WSL route was unexpectedly empty".to_string())
}

fn sidecar_path(rgb: &str, label: &str) -> Result<String, String> {
    let path = Path::new(rgb);
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| format!("capture path has no UTF-8 file stem: {rgb:?}"))?;
    let parent = path
        .parent()
        .ok_or_else(|| format!("capture path has no parent: {rgb:?}"))?;
    Ok(parent
        .join(format!("{stem}_{label}.tif"))
        .to_string_lossy()
        .to_string())
}

pub fn validate_staged_receipt_paths(
    expected_rgb: &str,
    slot: u32,
    channels: Channels,
    receipt: &BridgeScanReceipt,
) -> Result<(), String> {
    let expected_rgb = normalize_wsl_absolute(expected_rgb)?;
    if normalize_wsl_absolute(&receipt.rgb_path)? != expected_rgb {
        return Err(format!(
            "bridge RGB receipt path {:?} does not match WSL staging target {:?} for frame {slot}",
            receipt.rgb_path, expected_rgb
        ));
    }
    let expected_ir = normalize_wsl_absolute(&sidecar_path(&expected_rgb, "IR")?)?;
    match (channels, receipt.ir_path.as_deref()) {
        (Channels::Rgbi, Some(actual)) if normalize_wsl_absolute(actual)? == expected_ir => {}
        (Channels::Rgbi, Some(actual)) => {
            return Err(format!(
                "bridge IR receipt path {actual:?} does not match WSL staging target {expected_ir:?} for frame {slot}"
            ))
        }
        (Channels::Rgbi, None) => {
            return Err(format!("bridge RGBI receipt omitted frame {slot}'s IR sidecar"))
        }
        (Channels::Rgb, Some(actual)) => {
            return Err(format!(
                "bridge RGB-only receipt unexpectedly supplied IR path {actual:?} for frame {slot}"
            ))
        }
        (Channels::Rgb, None) => {}
    }
    if let Some(actual) = receipt.meter_rgbi_path.as_deref() {
        let expected_meter = normalize_wsl_absolute(&sidecar_path(&expected_rgb, "METER")?)?;
        if normalize_wsl_absolute(actual)? != expected_meter {
            return Err(format!(
                "bridge meter receipt path {actual:?} does not match WSL staging target {expected_meter:?} for frame {slot}"
            ));
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RasterKind {
    Rgb16,
    Gray16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FileDigest {
    sha256: String,
    byte_length: u64,
}

fn digest_file(path: &Path) -> Result<FileDigest, String> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|error| format!("inspect staged artifact {}: {error}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(format!(
            "staged artifact is not a regular file: {}",
            path.display()
        ));
    }
    let file = std::fs::File::open(path)
        .map_err(|error| format!("open artifact {}: {error}", path.display()))?;
    let mut reader = std::io::BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut total = 0u64;
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|error| format!("read artifact {}: {error}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        total += read as u64;
    }
    Ok(FileDigest {
        sha256: format!("{:x}", hasher.finalize()),
        byte_length: total,
    })
}

fn verify_raster_evidence(
    path: &Path,
    kind: RasterKind,
    expected: &BridgeArtifactEvidence,
) -> Result<(), String> {
    if expected.dtype != "uint16" && expected.dtype != "<u2" {
        return Err(format!(
            "receipt evidence for {} has unsupported dtype {:?}; expected uint16",
            path.display(),
            expected.dtype
        ));
    }
    let mut hasher = Sha256::new();
    let (shape, sample_count) = match kind {
        RasterKind::Rgb16 => {
            let image = image_io::read_rgb16(path).map_err(|error| {
                format!("decode copied RGB artifact {}: {error}", path.display())
            })?;
            for pixel in &image.pixels {
                for sample in pixel {
                    hasher.update(sample.to_le_bytes());
                }
            }
            (
                vec![image.height, image.width, 3],
                image.pixels.len().saturating_mul(3),
            )
        }
        RasterKind::Gray16 => {
            let image = image_io::read_gray16(path).map_err(|error| {
                format!(
                    "decode copied grayscale artifact {}: {error}",
                    path.display()
                )
            })?;
            for sample in &image.pixels {
                hasher.update(sample.to_le_bytes());
            }
            (vec![image.height, image.width], image.pixels.len())
        }
    };
    let byte_length = sample_count as u64 * 2;
    let sha256 = format!("{:x}", hasher.finalize());
    if expected.shape != shape {
        return Err(format!(
            "copied artifact {} has decoded shape {:?}, receipt expected {:?}",
            path.display(),
            shape,
            expected.shape
        ));
    }
    if expected.byte_length != byte_length {
        return Err(format!(
            "copied artifact {} has {} decoded bytes, receipt expected {}",
            path.display(),
            byte_length,
            expected.byte_length
        ));
    }
    if expected.sha256 != sha256 {
        return Err(format!(
            "copied artifact {} has decoded SHA-256 {}, receipt expected {}",
            path.display(),
            sha256,
            expected.sha256
        ));
    }
    Ok(())
}

struct ReservedDestination {
    path: PathBuf,
    file: Option<std::fs::File>,
}

struct DestinationGroup {
    entries: Vec<ReservedDestination>,
    committed: bool,
}

impl DestinationGroup {
    fn reserve(paths: &[PathBuf]) -> Result<Self, String> {
        let mut group = Self {
            entries: Vec::with_capacity(paths.len()),
            committed: false,
        };
        for path in paths {
            if let Some(parent) = path.parent() {
                if let Err(error) = std::fs::create_dir_all(parent) {
                    let rollback = group.rollback();
                    return Err(with_rollback_detail(
                        format!("create output directory {}: {error}", parent.display()),
                        rollback,
                    ));
                }
            }
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)
            {
                Ok(file) => group.entries.push(ReservedDestination {
                    path: path.clone(),
                    file: Some(file),
                }),
                Err(error) => {
                    let rollback = group.rollback();
                    return Err(with_rollback_detail(
                        format!(
                            "reserve destination without replacing an existing file {}: {error}",
                            path.display()
                        ),
                        rollback,
                    ));
                }
            }
        }
        Ok(group)
    }

    fn take_file(&mut self, path: &Path) -> Result<std::fs::File, String> {
        self.entries
            .iter_mut()
            .find(|entry| entry.path == path)
            .and_then(|entry| entry.file.take())
            .ok_or_else(|| format!("destination was not reserved exactly once: {}", path.display()))
    }

    fn commit(&mut self) {
        self.committed = true;
    }

    fn rollback(&mut self) -> Vec<String> {
        for entry in &mut self.entries {
            entry.file.take();
        }
        let mut warnings = Vec::new();
        for entry in self.entries.drain(..) {
            if let Err(error) = std::fs::remove_file(&entry.path) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    warnings.push(format!(
                        "remove owned partial destination {}: {error}",
                        entry.path.display()
                    ));
                }
            }
        }
        warnings
    }
}

impl Drop for DestinationGroup {
    fn drop(&mut self) {
        if !self.committed {
            let _ = self.rollback();
        }
    }
}

fn with_rollback_detail(reason: String, rollback: Vec<String>) -> String {
    if rollback.is_empty() {
        reason
    } else {
        format!("{reason}; destination rollback was incomplete: {}", rollback.join("; "))
    }
}

/// Copy one staged TIFF into a destination already reserved with create-new.
/// The raw source/destination digests prove byte identity; decoded evidence
/// proves those bytes still represent the raster bound by the bridge receipt.
fn copy_verified_file(
    source: &Path,
    destination: &Path,
    destination_file: std::fs::File,
    raster_evidence: Option<(RasterKind, &BridgeArtifactEvidence)>,
) -> Result<(), String> {
    let source_digest = digest_file(source)?;
    let source_file = std::fs::File::open(source)
        .map_err(|error| format!("open staged artifact {}: {error}", source.display()))?;
    let mut reader = std::io::BufReader::new(source_file);
    let mut writer = std::io::BufWriter::new(destination_file);
    std::io::copy(&mut reader, &mut writer).map_err(|error| {
        format!(
            "copy staged artifact {} to {}: {error}",
            source.display(),
            destination.display()
        )
    })?;
    writer
        .flush()
        .map_err(|error| format!("flush copied artifact {}: {error}", destination.display()))?;
    writer
        .get_ref()
        .sync_all()
        .map_err(|error| format!("sync copied artifact {}: {error}", destination.display()))?;
    drop(writer);

    let destination_digest = digest_file(destination)?;
    if source_digest != destination_digest {
        return Err(format!(
            "copied artifact {} is not byte-identical to staged source {} (source {} bytes {}, destination {} bytes {})",
            destination.display(),
            source.display(),
            source_digest.byte_length,
            source_digest.sha256,
            destination_digest.byte_length,
            destination_digest.sha256,
        ));
    }
    if let Some((kind, evidence)) = raster_evidence {
        verify_raster_evidence(destination, kind, evidence)?;
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FinalizeReceiptOutcome {
    pub cleanup_warnings: Vec<String>,
}

/// Finalize all files for one completed WSL frame and rewrite the receipt to
/// native Windows paths before the rest of the engine validates/renders it.
/// All native destinations are reserved before the first copy and rolled back
/// together on any failure. The receipt is accepted and rewritten before
/// staged cleanup; cleanup is best-effort and can never turn verified native
/// masters back into a failed frame.
pub fn finalize_receipt(
    config: &WslBridgeConfig,
    receipt: &mut BridgeScanReceipt,
    final_rgb: &Path,
) -> Result<FinalizeReceiptOutcome, String> {
    finalize_receipt_with(
        receipt,
        final_rgb,
        |path| wsl_path_to_unc(config, path),
        |path, is_directory| {
            let result = if is_directory {
                std::fs::remove_dir(path)
            } else {
                std::fs::remove_file(path)
            };
            result.map_err(|error| error.to_string())
        },
    )
}

fn finalize_receipt_with<F, C>(
    receipt: &mut BridgeScanReceipt,
    final_rgb: &Path,
    mapper: F,
    mut cleanup: C,
) -> Result<FinalizeReceiptOutcome, String>
where
    F: Fn(&str) -> Result<PathBuf, String>,
    C: FnMut(&Path, bool) -> Result<(), String>,
{
    let rgb_evidence = receipt
        .artifacts
        .get("rgb")
        .cloned()
        .ok_or("bridge receipt omitted required RGB ArtifactEvidence")?;
    let rgb_route = validate_staging_artifact_route(&receipt.rgb_path)?;
    let ir_route = receipt
        .ir_path
        .as_deref()
        .map(validate_staging_artifact_route)
        .transpose()?;
    let meter_route = receipt
        .meter_rgbi_path
        .as_deref()
        .map(validate_staging_artifact_route)
        .transpose()?;
    let staging_parent = rgb_route
        .normalized
        .rsplit_once('/')
        .map(|(parent, _)| parent)
        .ok_or("WSL RGB staging path had no parent")?;
    for route in [ir_route.as_ref(), meter_route.as_ref()]
        .into_iter()
        .flatten()
    {
        if route.normalized.rsplit_once('/').map(|(parent, _)| parent)
            != Some(staging_parent)
        {
            return Err("all WSL staged artifacts for one frame must share one private staging directory".into());
        }
    }
    let provenance = validate_provenance_routes(receipt)?;

    // Validate every WSL ancestor and leaf before creating any native output.
    let rgb_source = map_and_validate_route(&rgb_route, true, &mapper)?;
    let ir_source = ir_route
        .as_ref()
        .map(|route| map_and_validate_route(route, true, &mapper))
        .transpose()?;
    let meter_source = meter_route
        .as_ref()
        .map(|route| map_and_validate_route(route, true, &mapper))
        .transpose()?;
    let final_attempts_root = provenance
        .attempts
        .as_ref()
        .map(|route| map_and_validate_route(route, false, &mapper))
        .transpose()?;
    let final_ir = receipt
        .ir_path
        .as_ref()
        .map(|_| {
            crate::render::archive_sidecar_path(final_rgb, "IR").map_err(|e| e.message.clone())
        })
        .transpose()?;
    let final_meter = receipt
        .meter_rgbi_path
        .as_ref()
        .map(|_| {
            crate::render::archive_sidecar_path(final_rgb, "METER").map_err(|e| e.message.clone())
        })
        .transpose()?;

    let ir_evidence = if ir_source.is_some() {
        Some(
            receipt
                .artifacts
                .get("ir")
                .cloned()
                .ok_or("bridge receipt supplied an IR path but omitted IR ArtifactEvidence")?,
        )
    } else {
        None
    };
    let mut final_paths = vec![final_rgb.to_path_buf()];
    final_paths.extend(final_ir.iter().cloned());
    final_paths.extend(final_meter.iter().cloned());
    let mut destinations = DestinationGroup::reserve(&final_paths)?;
    let copy_result = (|| {
        let file = destinations.take_file(final_rgb)?;
        copy_verified_file(
            &rgb_source,
            final_rgb,
            file,
            Some((RasterKind::Rgb16, &rgb_evidence)),
        )?;
        if let (Some(source), Some(destination), Some(evidence)) =
            (ir_source.as_deref(), final_ir.as_deref(), ir_evidence.as_ref())
        {
            let file = destinations.take_file(destination)?;
            copy_verified_file(
                source,
                destination,
                file,
                Some((RasterKind::Gray16, evidence)),
            )?;
        }
        if let (Some(source), Some(destination)) =
            (meter_source.as_deref(), final_meter.as_deref())
        {
            // Current CoolScanPy receipts bind RGB and IR array evidence but
            // do not publish a separate meter ArtifactEvidence. Raw source/
            // destination digests still prove this copy byte-identical.
            let file = destinations.take_file(destination)?;
            copy_verified_file(source, destination, file, None)?;
        }
        Ok::<(), String>(())
    })();
    if let Err(reason) = copy_result {
        let rollback = destinations.rollback();
        return Err(with_rollback_detail(reason, rollback));
    }
    destinations.commit();

    // Receipt acceptance is the commit point. Nothing below can make this
    // verified native capture fail or revert these paths to WSL-owned names.
    receipt.rgb_path = final_rgb.display().to_string();
    receipt.ir_path = final_ir.map(|path| path.display().to_string());
    receipt.meter_rgbi_path = final_meter.map(|path| path.display().to_string());
    receipt.attempts_root = final_attempts_root.map(|path| path.display().to_string());
    let staged_sources = [Some(rgb_source), ir_source, meter_source];
    let stage_directory = staged_sources
        .iter()
        .flatten()
        .next()
        .and_then(|path| path.parent())
        .map(Path::to_path_buf);
    let mut cleanup_warnings = Vec::new();
    for source in staged_sources.into_iter().flatten() {
        if let Err(error) = cleanup(&source, false) {
            cleanup_warnings.push(format!(
                "remove verified WSL staged artifact {}: {error}",
                source.display()
            ));
        }
    }
    if let Some(directory) = stage_directory {
        if let Err(error) = cleanup(&directory, true) {
            cleanup_warnings.push(format!(
                "remove private WSL staging directory {}: {error}",
                directory.display()
            ));
        }
    }
    Ok(FinalizeReceiptOutcome { cleanup_warnings })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge_protocol::{
        BridgeClippingTelemetry, BridgeExposureVector, BridgeFocusDetailTelemetry,
        BridgeTransportSmearAssessment,
    };

    fn unique_dir(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "scanstudio-wsl-io-{}-{}-{label}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn rgb_evidence(image: &image_io::Rgb16Image) -> BridgeArtifactEvidence {
        let mut hasher = Sha256::new();
        for pixel in &image.pixels {
            for sample in pixel {
                hasher.update(sample.to_le_bytes());
            }
        }
        BridgeArtifactEvidence {
            sha256: format!("{:x}", hasher.finalize()),
            byte_length: image.pixels.len() as u64 * 6,
            shape: vec![image.height, image.width, 3],
            dtype: "uint16".to_string(),
        }
    }

    fn gray_evidence(image: &image_io::Gray16Image) -> BridgeArtifactEvidence {
        let mut hasher = Sha256::new();
        for sample in &image.pixels {
            hasher.update(sample.to_le_bytes());
        }
        BridgeArtifactEvidence {
            sha256: format!("{:x}", hasher.finalize()),
            byte_length: image.pixels.len() as u64 * 2,
            shape: vec![image.height, image.width],
            dtype: "uint16".to_string(),
        }
    }

    fn local_wsl_path(root: &Path, path: &str) -> Result<PathBuf, String> {
        Ok(root.join(path.trim_start_matches('/')))
    }

    fn local_cleanup(path: &Path, is_directory: bool) -> Result<(), String> {
        let result = if is_directory {
            std::fs::remove_dir(path)
        } else {
            std::fs::remove_file(path)
        };
        result.map_err(|error| error.to_string())
    }

    fn staged_receipt(root: &Path) -> BridgeScanReceipt {
        let rgb_path = "/tmp/scanstudio-wsl-staging/owner/capture-owner-0001.tif";
        let ir_path = "/tmp/scanstudio-wsl-staging/owner/capture-owner-0001_IR.tif";
        let attempts_root =
            "/home/test-user/.scanstudio/coolscanpy-attempts/session-abc";
        let rgb = image_io::Rgb16Image {
            width: 2,
            height: 1,
            pixels: vec![[1, 2, 3], [400, 500, 600]],
        };
        let ir = image_io::Gray16Image {
            width: 2,
            height: 1,
            pixels: vec![7, 9],
        };
        let rgb_file = local_wsl_path(root, rgb_path).unwrap();
        let ir_file = local_wsl_path(root, ir_path).unwrap();
        std::fs::create_dir_all(rgb_file.parent().unwrap()).unwrap();
        image_io::write_rgb16(&rgb_file, &rgb).unwrap();
        image_io::write_gray16(&ir_file, &ir).unwrap();
        std::fs::create_dir_all(local_wsl_path(root, attempts_root).unwrap()).unwrap();

        let mut artifacts = std::collections::HashMap::new();
        artifacts.insert("rgb".to_string(), rgb_evidence(&rgb));
        artifacts.insert("ir".to_string(), gray_evidence(&ir));
        BridgeScanReceipt {
            version: 1,
            slot: 1,
            spacing_offset: 0,
            dpi: 4000,
            depth: 16,
            device_id: "ls5000-usb-0".into(),
            device_model: "SUPER COOLSCAN 5000 ED".into(),
            reviewed_fingerprint_sha256: "a".repeat(64),
            fresh_fingerprint_sha256: "a".repeat(64),
            manual_approval: None,
            exposure: BridgeExposureVector {
                focus_position: 800,
                exposure_multiplier: 1.0,
                red_exposure_us: 1200.0,
                green_exposure_us: 950.0,
                blue_exposure_us: 1400.0,
            },
            split_alignment: None,
            clipping: BridgeClippingTelemetry {
                fractions: (0.0, 0.0, 0.0),
                clip_level: 0.995,
                warning_fraction: 0.02,
                warning: false,
            },
            focus_detail: BridgeFocusDetailTelemetry {
                method: "laplacian-variance".into(),
                verdict: "measured".into(),
                score: Some(180.0),
                texture_span: 0.7,
            },
            transport_smear: BridgeTransportSmearAssessment {
                verdict: "clean".into(),
                start_row: None,
                suffix_rows: 0,
                minimum_matches: 0,
                tail_median_rms: None,
                tail_min_corr: None,
                pre_tail_median_rms: None,
                texture_span: None,
                reason: "no repeated tail rows detected".into(),
            },
            artifacts,
            storage_transform: "swapaxes01-scanner-native-to-nikon-render-parity-v2".into(),
            rgb_path: rgb_path.into(),
            ir_path: Some(ir_path.into()),
            meter_rgbi_path: None,
            attempts_root: Some(attempts_root.into()),
            exposure_authority: None,
            started_at: None,
            capture_duration_ms: None,
        }
    }

    #[test]
    fn detects_only_the_windows_wsl_bridge_lane() {
        assert_eq!(
            config_for_bridge_command(
                "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge",
                true
            )
            .unwrap(),
            Some(WslBridgeConfig {
                distro: DEFAULT_WSL_DISTRO.to_string()
            })
        );
        assert!(config_for_bridge_command("wsl.exe -e scanstudio-bridge", true).is_err());
        assert!(config_for_bridge_command(
            "wsl.exe -d Debian -e scanstudio-bridge",
            true
        )
        .is_err());
        assert!(config_for_bridge_command("scanstudio-bridge", true)
            .unwrap()
            .is_none());
        assert!(config_for_bridge_command("wsl.exe -e scanstudio-bridge", false)
            .unwrap()
            .is_none());
    }

    #[test]
    fn maps_windows_destinations_and_rejects_ambiguous_paths() {
        assert_eq!(
            windows_to_wsl_path(r"C:\Users\test-user\Scans"),
            Ok("/mnt/c/Users/test-user/Scans".to_string())
        );
        assert!(windows_to_wsl_path(r"C:Scans").is_err());
        assert!(windows_to_wsl_path(r"\\server\share\Scans").is_err());
        assert!(windows_to_wsl_path(r"C:\Scans\..\Elsewhere").is_err());
    }

    #[test]
    fn maps_absolute_wsl_paths_to_the_pinned_distro_share() {
        let config = WslBridgeConfig {
            distro: DEFAULT_WSL_DISTRO.to_string(),
        };
        assert_eq!(
            wsl_path_to_unc(&config, "/tmp/scanstudio/frame.tif")
                .unwrap()
                .to_string_lossy(),
            r"\\wsl$\Ubuntu-24.04\tmp\scanstudio\frame.tif"
        );
        assert!(wsl_path_to_unc(&config, "relative/frame.tif").is_err());
        assert!(wsl_path_to_unc(&config, "/tmp/../frame.tif").is_err());
    }

    #[test]
    fn verified_copy_matches_raw_file_and_receipt_raster_evidence() {
        let root = unique_dir("verified");
        std::fs::create_dir_all(&root).unwrap();
        let source = root.join("source.tif");
        let destination = root.join("dest.tif");
        let image = image_io::Rgb16Image {
            width: 2,
            height: 1,
            pixels: vec![[1, 2, 3], [400, 500, 600]],
        };
        image_io::write_rgb16(&source, &image).unwrap();
        let mut hasher = Sha256::new();
        for pixel in &image.pixels {
            for sample in pixel {
                hasher.update(sample.to_le_bytes());
            }
        }
        let evidence = BridgeArtifactEvidence {
            sha256: format!("{:x}", hasher.finalize()),
            byte_length: 12,
            shape: vec![1, 2, 3],
            dtype: "uint16".to_string(),
        };

        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&destination)
            .unwrap();
        copy_verified_file(
            &source,
            &destination,
            file,
            Some((RasterKind::Rgb16, &evidence)),
        )
        .unwrap();
        assert_eq!(
            std::fs::read(&source).unwrap(),
            std::fs::read(&destination).unwrap()
        );
        assert!(
            source.exists(),
            "group finalization owns staged-source deletion"
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn receipt_evidence_mismatch_is_hard_and_preserves_both_files() {
        let root = unique_dir("mismatch");
        std::fs::create_dir_all(&root).unwrap();
        let source = root.join("source.tif");
        let destination = root.join("dest.tif");
        image_io::write_gray16(
            &source,
            &image_io::Gray16Image {
                width: 1,
                height: 1,
                pixels: vec![42],
            },
        )
        .unwrap();
        let evidence = BridgeArtifactEvidence {
            sha256: "0".repeat(64),
            byte_length: 2,
            shape: vec![1, 1],
            dtype: "uint16".to_string(),
        };

        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&destination)
            .unwrap();
        let error = copy_verified_file(
            &source,
            &destination,
            file,
            Some((RasterKind::Gray16, &evidence)),
        )
        .unwrap_err();
        assert!(error.contains("receipt expected"));
        assert!(source.exists());
        assert!(destination.exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn destination_group_collision_rolls_back_and_retry_succeeds() {
        let root = unique_dir("transactional-retry");
        let mut receipt = staged_receipt(&root);
        let final_rgb = root.join("native/Archive_0001.tif");
        let final_ir = crate::render::archive_sidecar_path(&final_rgb, "IR").unwrap();
        std::fs::create_dir_all(final_ir.parent().unwrap()).unwrap();
        std::fs::write(&final_ir, b"existing-ir").unwrap();

        let error = finalize_receipt_with(
            &mut receipt,
            &final_rgb,
            |path| local_wsl_path(&root, path),
            local_cleanup,
        )
        .unwrap_err();
        assert!(error.contains("reserve destination"));
        assert!(!final_rgb.exists(), "owned RGB placeholder must roll back");
        assert_eq!(std::fs::read(&final_ir).unwrap(), b"existing-ir");
        assert!(local_wsl_path(&root, &receipt.rgb_path).unwrap().is_file());

        std::fs::remove_file(&final_ir).unwrap();
        let outcome = finalize_receipt_with(
            &mut receipt,
            &final_rgb,
            |path| local_wsl_path(&root, path),
            local_cleanup,
        )
        .unwrap();
        assert!(outcome.cleanup_warnings.is_empty());
        assert_eq!(receipt.rgb_path, final_rgb.display().to_string());
        assert!(final_rgb.is_file());
        assert!(final_ir.is_file());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn later_sidecar_verification_failure_rolls_back_all_destinations_for_retry() {
        let root = unique_dir("transactional-sidecar-retry");
        let mut receipt = staged_receipt(&root);
        let final_rgb = root.join("native/Archive_0001.tif");
        let final_ir = crate::render::archive_sidecar_path(&final_rgb, "IR").unwrap();
        let correct_ir_sha = receipt.artifacts["ir"].sha256.clone();
        receipt.artifacts.get_mut("ir").unwrap().sha256 = "0".repeat(64);

        let error = finalize_receipt_with(
            &mut receipt,
            &final_rgb,
            |path| local_wsl_path(&root, path),
            local_cleanup,
        )
        .unwrap_err();
        assert!(error.contains("receipt expected"));
        assert!(!final_rgb.exists(), "verified RGB must roll back with failed IR");
        assert!(!final_ir.exists(), "failed IR destination must roll back");
        assert!(local_wsl_path(&root, &receipt.rgb_path).unwrap().is_file());
        assert!(local_wsl_path(&root, receipt.ir_path.as_deref().unwrap())
            .unwrap()
            .is_file());

        receipt.artifacts.get_mut("ir").unwrap().sha256 = correct_ir_sha;
        let outcome = finalize_receipt_with(
            &mut receipt,
            &final_rgb,
            |path| local_wsl_path(&root, path),
            local_cleanup,
        )
        .unwrap();
        assert!(outcome.cleanup_warnings.is_empty());
        assert!(final_rgb.is_file());
        assert!(final_ir.is_file());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cleanup_failure_is_nonfatal_after_receipt_acceptance() {
        let root = unique_dir("cleanup-warning");
        let mut receipt = staged_receipt(&root);
        let staged_rgb = local_wsl_path(&root, &receipt.rgb_path).unwrap();
        let final_rgb = root.join("native/Archive_0001.tif");

        let outcome = finalize_receipt_with(
            &mut receipt,
            &final_rgb,
            |path| local_wsl_path(&root, path),
            |_path, _is_directory| Err("injected cleanup refusal".to_string()),
        )
        .unwrap();
        assert!(!outcome.cleanup_warnings.is_empty());
        assert_eq!(receipt.rgb_path, final_rgb.display().to_string());
        assert!(final_rgb.is_file());
        assert!(staged_rgb.is_file(), "failed cleanup preserves staged source");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn attempts_root_leaf_symlink_is_rejected_before_native_output() {
        use std::os::unix::fs::symlink;

        let root = unique_dir("attempts-symlink");
        let mut receipt = staged_receipt(&root);
        let attempts = local_wsl_path(&root, receipt.attempts_root.as_ref().unwrap()).unwrap();
        let relocated = root.join("relocated-attempts");
        std::fs::rename(&attempts, &relocated).unwrap();
        symlink(&relocated, &attempts).unwrap();
        let final_rgb = root.join("native/Archive_0001.tif");

        let error = finalize_receipt_with(
            &mut receipt,
            &final_rgb,
            |path| local_wsl_path(&root, path),
            local_cleanup,
        )
        .unwrap_err();
        assert!(error.contains("contains a symlink"));
        assert!(!final_rgb.exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn staging_directory_symlink_is_rejected_before_native_output() {
        use std::os::unix::fs::symlink;

        let root = unique_dir("stage-symlink");
        let mut receipt = staged_receipt(&root);
        let stage = local_wsl_path(
            &root,
            "/tmp/scanstudio-wsl-staging/owner",
        )
        .unwrap();
        let relocated = root.join("relocated-stage");
        std::fs::rename(&stage, &relocated).unwrap();
        symlink(&relocated, &stage).unwrap();
        let final_rgb = root.join("native/Archive_0001.tif");

        let error = finalize_receipt_with(
            &mut receipt,
            &final_rgb,
            |path| local_wsl_path(&root, path),
            local_cleanup,
        )
        .unwrap_err();
        assert!(error.contains("contains a symlink"));
        assert!(!final_rgb.exists());
        std::fs::remove_dir_all(root).unwrap();
    }
}
