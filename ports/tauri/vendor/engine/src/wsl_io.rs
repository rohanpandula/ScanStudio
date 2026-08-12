//! Windows/WSL capture-file handoff.
//!
//! The bridge runs inside WSL and receives only an unpredictable, private
//! staging directory. This module never creates or opens a user output. It
//! validates and holds WSL source identities, then copies their exact bytes
//! into already-open engine-private files supplied by `real_backend`. The
//! canonical stable-input and held-output pipeline remains the only publisher.

use std::io::{Read as _, Seek as _, Write as _};
use std::path::{Path, PathBuf};

use sha2::{Digest as _, Sha256};

use crate::bridge_protocol::{BridgeArtifactEvidence, BridgeScanReceipt};
use crate::domain::Channels;
use crate::parity::image_io;

pub const DEFAULT_WSL_DISTRO: &str = "Ubuntu-24.04";
pub const WSL_STAGING_BASE: &str = "/tmp/scanstudio-wsl-staging";
const MAX_STAGED_ARTIFACT_BYTES: u64 = 2 * 1024 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WslBridgeConfig {
    pub distro: String,
}

/// Detect the packaged Windows bridge lane. The command must pin the exact
/// distribution whose UNC share the native process will read; a mutable
/// default distribution is not an evidence boundary.
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

/// Pure validation/mapping twin of the app-layer Windows path mapper. It is
/// intentionally not used for publication: user destinations remain owned by
/// `JobOutputAuthorities` in the canonical renderer.
pub fn windows_to_wsl_path(input: &str) -> Result<String, String> {
    let value = input.trim();
    if value.is_empty() {
        return Err("empty Windows path".to_string());
    }
    if value.starts_with("\\\\") || value.starts_with("//") {
        return Err(format!(
            "UNC destination is not supported for WSL path mapping: {value:?}"
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
            "Windows path contains a relative component: {value:?}"
        ));
    }
    if segments.is_empty() {
        Ok(format!("/mnt/{drive}"))
    } else {
        Ok(format!("/mnt/{drive}/{}", segments.join("/")))
    }
}

fn safe_ascii_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && !matches!(value, "." | "..")
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn safe_owner_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

pub fn staging_root(owner_token: &str) -> Result<String, String> {
    if !safe_owner_token(owner_token) {
        return Err("WSL staging owner token must be one safe ASCII path component".to_string());
    }
    Ok(format!("{WSL_STAGING_BASE}/{owner_token}"))
}

pub fn wsl_path_to_unc(config: &WslBridgeConfig, input: &str) -> Result<PathBuf, String> {
    let normalized = normalize_wsl_absolute(input)?;
    if !safe_ascii_component(&config.distro) {
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
    if !value.starts_with('/') || value.contains('\\') || value.contains('\0') {
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
    if segments.is_empty() {
        return Err("WSL path must name an entry below root".to_string());
    }
    Ok(format!("/{}", segments.join("/")))
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ValidatedWslRoute {
    normalized: String,
    /// Absolute paths from the first security boundary through the leaf.
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
        || !safe_owner_token(parts[2])
        || !safe_ascii_component(parts[3])
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
        || !safe_ascii_component(parts[1])
        || parts[2] != ".scanstudio"
        || parts[3] != "coolscanpy-attempts"
        || !safe_ascii_component(parts[4])
    {
        return Err(format!(
            "attemptsRoot must be one pinned session under /home/<user>/.scanstudio/coolscanpy-attempts: {input:?}"
        ));
    }
    let route = route_from_components(&parts);
    Ok(ValidatedWslRoute { normalized, route })
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
    // This also constrains the exact owner and leaf shape before any UNC open.
    validate_staging_artifact_route(&receipt.rgb_path)?;
    let expected_ir = normalize_wsl_absolute(&sidecar_path(&expected_rgb, "IR")?)?;
    match (channels, receipt.ir_path.as_deref()) {
        (Channels::Rgbi, Some(actual)) if normalize_wsl_absolute(actual)? == expected_ir => {
            validate_staging_artifact_route(actual)?;
        }
        (Channels::Rgbi, Some(actual)) => {
            return Err(format!(
                "bridge IR receipt path {actual:?} does not match WSL staging target {expected_ir:?} for frame {slot}"
            ));
        }
        (Channels::Rgbi, None) => {
            return Err(format!(
                "bridge RGBI receipt omitted frame {slot}'s IR sidecar"
            ));
        }
        (Channels::Rgb, Some(actual)) => {
            return Err(format!(
                "bridge RGB-only receipt unexpectedly supplied IR path {actual:?} for frame {slot}"
            ));
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
        validate_staging_artifact_route(actual)?;
    }
    if let Some(actual) = receipt.raw_export_path.as_deref() {
        return Err(format!(
            "bridge receipt reported raw export {actual:?} for frame {slot}, but raw export is refused on the WSL staging lane"
        ));
    }
    if let Some(actual) = receipt.raw_export_ir_path.as_deref() {
        return Err(format!(
            "bridge receipt reported raw export IR sidecar {actual:?} for frame {slot}, but raw export is refused on the WSL staging lane"
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn metadata_is_reparse(metadata: &std::fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt as _;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_reparse(_metadata: &std::fs::Metadata) -> bool {
    false
}

#[cfg(unix)]
fn open_directory_nofollow(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt as _;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

#[cfg(windows)]
fn open_directory_nofollow(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::windows::fs::OpenOptionsExt as _;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_SHARE_READ: u32 = 0x0000_0001;
    const FILE_LIST_DIRECTORY: u32 = 0x0000_0001;
    const FILE_TRAVERSE: u32 = 0x0000_0020;
    const FILE_READ_ATTRIBUTES: u32 = 0x0000_0080;
    std::fs::OpenOptions::new()
        .access_mode(FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES)
        // Deny write/delete sharing while this route is evidence-active.
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
}

#[cfg(not(any(unix, windows)))]
fn open_directory_nofollow(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::File::open(path)
}

#[cfg(unix)]
fn open_regular_nofollow(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt as _;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

#[cfg(windows)]
fn open_regular_nofollow(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::windows::fs::OpenOptionsExt as _;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_SHARE_READ: u32 = 0x0000_0001;
    std::fs::OpenOptions::new()
        .read(true)
        // Deny writers and deletion while bytes are verified and copied.
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
}

#[cfg(not(any(unix, windows)))]
fn open_regular_nofollow(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::File::open(path)
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FileState {
    volume_id: u64,
    file_id: u64,
    links: u64,
    byte_length: u64,
}

fn regular_file_state(file: &std::fs::File, role: &str) -> Result<FileState, String> {
    let metadata = file
        .metadata()
        .map_err(|error| format!("inspect held {role}: {error}"))?;
    if !metadata.is_file() || metadata_is_reparse(&metadata) {
        return Err(format!(
            "held {role} is a reparse point or non-regular file"
        ));
    }
    let (volume_id, file_id, links) = crate::exiftool::held_file_identity(file, &metadata)
        .ok_or_else(|| format!("held {role} has no stable volume/file identity"))?;
    if links != 1 {
        return Err(format!("held {role} is not uniquely linked"));
    }
    Ok(FileState {
        volume_id,
        file_id,
        links,
        byte_length: metadata.len(),
    })
}

fn open_directory_route<F>(
    route: &ValidatedWslRoute,
    mapper: &F,
) -> Result<(PathBuf, Vec<std::fs::File>), String>
where
    F: Fn(&str) -> Result<PathBuf, String>,
{
    let mut authorities = Vec::with_capacity(route.route.len());
    let mut leaf = None;
    for item in &route.route {
        let path = mapper(item)?;
        let directory = open_directory_nofollow(&path).map_err(|error| {
            format!(
                "open WSL directory {} without following links: {error}",
                path.display()
            )
        })?;
        let metadata = directory
            .metadata()
            .map_err(|error| format!("inspect held WSL directory {}: {error}", path.display()))?;
        if !metadata.is_dir() || metadata_is_reparse(&metadata) {
            return Err(format!(
                "WSL route contains a reparse point or non-directory: {}",
                path.display()
            ));
        }
        authorities.push(directory);
        leaf = Some(path);
    }
    Ok((
        leaf.ok_or("validated WSL directory route was unexpectedly empty")?,
        authorities,
    ))
}

fn open_artifact_route<F>(
    route: &ValidatedWslRoute,
    mapper: &F,
) -> Result<(PathBuf, Vec<std::fs::File>, std::fs::File, FileState), String>
where
    F: Fn(&str) -> Result<PathBuf, String>,
{
    let (leaf, ancestors) = route
        .route
        .split_last()
        .ok_or("validated WSL artifact route was unexpectedly empty")?;
    let ancestor_route = ValidatedWslRoute {
        normalized: route.normalized.clone(),
        route: ancestors.to_vec(),
    };
    let (_, authorities) = open_directory_route(&ancestor_route, mapper)?;
    let path = mapper(leaf)?;
    let file = open_regular_nofollow(&path).map_err(|error| {
        format!(
            "open WSL staged artifact {} without following links: {error}",
            path.display()
        )
    })?;
    let state = regular_file_state(&file, "WSL staged artifact")?;
    if state.byte_length > MAX_STAGED_ARTIFACT_BYTES {
        return Err(format!(
            "WSL staged artifact {} is {} bytes, exceeding the {} byte import bound",
            path.display(),
            state.byte_length,
            MAX_STAGED_ARTIFACT_BYTES
        ));
    }
    Ok((path, authorities, file, state))
}

fn hash_exact(
    file: &mut std::fs::File,
    expected_length: u64,
    role: &str,
) -> Result<[u8; 32], String> {
    file.seek(std::io::SeekFrom::Start(0))
        .map_err(|error| format!("rewind {role}: {error}"))?;
    let mut digest = Sha256::new();
    let mut remaining = expected_length;
    let mut buffer = [0_u8; 1024 * 1024];
    while remaining > 0 {
        let wanted = usize::try_from(remaining.min(buffer.len() as u64))
            .expect("bounded WSL read size fits usize");
        let read = file
            .read(&mut buffer[..wanted])
            .map_err(|error| format!("read {role}: {error}"))?;
        if read == 0 {
            return Err(format!("{role} became shorter during exact read"));
        }
        digest.update(&buffer[..read]);
        remaining -= read as u64;
    }
    let mut extra = [0_u8; 1];
    if file
        .read(&mut extra)
        .map_err(|error| format!("read {role} tail: {error}"))?
        != 0
    {
        return Err(format!("{role} became longer during exact read"));
    }
    Ok(digest.finalize().into())
}

#[derive(Debug, Clone, Copy)]
enum EvidenceRasterKind {
    Rgb16,
    Gray16,
}

fn verify_held_artifact_evidence(
    file: &std::fs::File,
    role: &str,
    kind: EvidenceRasterKind,
    expected: &BridgeArtifactEvidence,
) -> Result<(), String> {
    if expected.dtype != "uint16" && expected.dtype != "<u2" {
        return Err(format!(
            "bridge {role} ArtifactEvidence has unsupported dtype {:?}; expected uint16",
            expected.dtype
        ));
    }
    let before = regular_file_state(file, role)?;
    let mut held = file
        .try_clone()
        .map_err(|error| format!("clone held private {role} target for evidence: {error}"))?;
    held.seek(std::io::SeekFrom::Start(0))
        .map_err(|error| format!("rewind held private {role} target for evidence: {error}"))?;
    let mut digest = Sha256::new();
    let (shape, sample_count) = match kind {
        EvidenceRasterKind::Rgb16 => {
            let image = image_io::read_rgb16_file(held).map_err(|error| {
                format!("decode held private RGB import for ArtifactEvidence: {error}")
            })?;
            for pixel in &image.pixels {
                for sample in pixel {
                    digest.update(sample.to_le_bytes());
                }
            }
            (
                vec![image.height, image.width, 3],
                image.pixels.len().saturating_mul(3),
            )
        }
        EvidenceRasterKind::Gray16 => {
            let reader = std::io::BufReader::new(held);
            let decoded = image::ImageReader::with_format(reader, image::ImageFormat::Tiff)
                .decode()
                .map_err(|error| {
                    format!("decode held private infrared import for ArtifactEvidence: {error}")
                })?
                .into_luma16();
            let width = decoded.width();
            let height = decoded.height();
            let pixels = decoded.into_raw();
            for sample in &pixels {
                digest.update(sample.to_le_bytes());
            }
            (vec![height, width], pixels.len())
        }
    };
    let actual_length = (sample_count as u64)
        .checked_mul(2)
        .ok_or_else(|| format!("decoded {role} sample count overflowed"))?;
    let actual_sha256 = format!("{:x}", digest.finalize());
    if expected.shape != shape
        || expected.byte_length != actual_length
        || expected.sha256 != actual_sha256
    {
        return Err(format!(
            "held private {role} import does not match bridge ArtifactEvidence (shape {:?}/{:?}, decoded bytes {}/{}, SHA-256 {}/{})",
            shape,
            expected.shape,
            actual_length,
            expected.byte_length,
            actual_sha256,
            expected.sha256
        ));
    }
    if regular_file_state(file, role)? != before {
        return Err(format!(
            "held private {role} identity or length changed during ArtifactEvidence validation"
        ));
    }
    Ok(())
}

#[derive(Debug)]
struct StagedArtifact {
    path: PathBuf,
    _authorities: Vec<std::fs::File>,
    file: std::fs::File,
    state: FileState,
    sha256: [u8; 32],
}

impl StagedArtifact {
    fn prepare<F>(route: ValidatedWslRoute, mapper: &F) -> Result<Self, String>
    where
        F: Fn(&str) -> Result<PathBuf, String>,
    {
        let (path, authorities, mut file, state) = open_artifact_route(&route, mapper)?;
        let sha256 = hash_exact(&mut file, state.byte_length, "WSL staged artifact")?;
        if regular_file_state(&file, "WSL staged artifact")? != state {
            return Err(format!(
                "WSL staged artifact identity or length changed while hashing {}",
                path.display()
            ));
        }
        Ok(Self {
            path,
            _authorities: authorities,
            file,
            state,
            sha256,
        })
    }

    fn copy_into(&mut self, target: &mut std::fs::File, role: &str) -> Result<(), String> {
        let target_before = regular_file_state(target, role)?;
        if target_before.byte_length != 0 {
            return Err(format!("held private {role} target was not empty"));
        }
        self.file
            .seek(std::io::SeekFrom::Start(0))
            .map_err(|error| format!("rewind staged {role}: {error}"))?;
        target
            .seek(std::io::SeekFrom::Start(0))
            .map_err(|error| format!("rewind private {role} target: {error}"))?;
        let mut digest = Sha256::new();
        let mut remaining = self.state.byte_length;
        let mut buffer = [0_u8; 1024 * 1024];
        while remaining > 0 {
            let wanted = usize::try_from(remaining.min(buffer.len() as u64))
                .expect("bounded WSL copy size fits usize");
            let read = self
                .file
                .read(&mut buffer[..wanted])
                .map_err(|error| format!("read staged {role}: {error}"))?;
            if read == 0 {
                return Err(format!("staged {role} became shorter during import"));
            }
            target
                .write_all(&buffer[..read])
                .map_err(|error| format!("write private {role} import: {error}"))?;
            digest.update(&buffer[..read]);
            remaining -= read as u64;
        }
        let mut extra = [0_u8; 1];
        if self
            .file
            .read(&mut extra)
            .map_err(|error| format!("read staged {role} tail: {error}"))?
            != 0
        {
            return Err(format!("staged {role} became longer during import"));
        }
        target
            .flush()
            .map_err(|error| format!("flush private {role} import: {error}"))?;
        target
            .sync_all()
            .map_err(|error| format!("sync private {role} import: {error}"))?;
        let copied_sha256: [u8; 32] = digest.finalize().into();
        if copied_sha256 != self.sha256
            || regular_file_state(&self.file, "WSL staged artifact")? != self.state
        {
            return Err(format!(
                "staged {role} identity, length, or SHA-256 changed between verification and import"
            ));
        }
        let target_after = regular_file_state(target, role)?;
        if target_after.volume_id != target_before.volume_id
            || target_after.file_id != target_before.file_id
            || target_after.links != target_before.links
            || target_after.byte_length != self.state.byte_length
        {
            return Err(format!(
                "held private {role} target identity or length changed during import"
            ));
        }
        let reopened = open_regular_nofollow(&self.path).map_err(|error| {
            format!(
                "reopen staged {role} name after import {}: {error}",
                self.path.display()
            )
        })?;
        if regular_file_state(&reopened, "reopened WSL staged artifact")? != self.state {
            return Err(format!(
                "staged {role} name no longer identifies the held source after import"
            ));
        }
        Ok(())
    }
}

#[derive(Debug)]
struct HeldAttemptsRoot {
    path: PathBuf,
    _authorities: Vec<std::fs::File>,
}

/// A source-only WSL capability. It owns held source and ancestor handles;
/// callers can import only through already-open private target files.
#[derive(Debug)]
pub(crate) struct PreparedStagedReceipt {
    rgb: StagedArtifact,
    ir: Option<StagedArtifact>,
    meter: Option<StagedArtifact>,
    attempts: Option<HeldAttemptsRoot>,
    stage_directory: PathBuf,
}

impl PreparedStagedReceipt {
    pub(crate) fn has_ir(&self) -> bool {
        self.ir.is_some()
    }

    pub(crate) fn has_meter(&self) -> bool {
        self.meter.is_some()
    }

    pub(crate) fn import_into(
        mut self,
        receipt: &mut BridgeScanReceipt,
        targets: HeldPrivateImportTargets<'_>,
    ) -> Result<ImportedStagedReceipt, String> {
        let HeldPrivateImportTargets {
            rgb,
            mut ir,
            mut meter,
        } = targets;
        if self.ir.is_some() != ir.is_some() || self.meter.is_some() != meter.is_some() {
            return Err("held private WSL import targets do not match the staged receipt".into());
        }
        self.rgb.copy_into(rgb.file, "RGB")?;
        if let (Some(source), Some(target)) = (self.ir.as_mut(), ir.as_mut()) {
            source.copy_into(target.file, "infrared")?;
        }
        if let (Some(source), Some(target)) = (self.meter.as_mut(), meter.as_mut()) {
            source.copy_into(target.file, "meter RGBI")?;
        }

        let rgb_evidence = receipt
            .artifacts
            .get("rgb")
            .ok_or("bridge receipt omitted required RGB ArtifactEvidence")?;
        verify_held_artifact_evidence(&*rgb.file, "RGB", EvidenceRasterKind::Rgb16, rgb_evidence)?;
        if let Some(target) = ir.as_ref() {
            let ir_evidence = receipt
                .artifacts
                .get("ir")
                .ok_or("bridge receipt supplied IR but omitted IR ArtifactEvidence")?;
            verify_held_artifact_evidence(
                &*target.file,
                "infrared",
                EvidenceRasterKind::Gray16,
                ir_evidence,
            )?;
        }

        // Commit only after every private target is fully synced and every
        // source name still identifies the held bytes.
        receipt.rgb_path = rgb.path.display().to_string();
        receipt.ir_path = ir.as_ref().map(|target| target.path.display().to_string());
        receipt.meter_rgbi_path = meter
            .as_ref()
            .map(|target| target.path.display().to_string());
        receipt.attempts_root = self
            .attempts
            .as_ref()
            .map(|value| value.path.display().to_string());

        Ok(ImportedStagedReceipt { staged: self })
    }
}

/// Cleanup is deliberately a separate, consuming step. The caller first
/// syncs the private workspace directory; if that durability step fails this
/// capability is dropped and every WSL source remains recovery-held.
#[derive(Debug)]
pub(crate) struct ImportedStagedReceipt {
    staged: PreparedStagedReceipt,
}

impl ImportedStagedReceipt {
    pub(crate) fn cleanup(self) -> Vec<String> {
        let staged = self.staged;
        let stage_directory = staged.stage_directory.clone();
        drop(staged);
        // Native Windows has no safe standard-library primitive for
        // identity-bound unlink of a WSL UNC leaf. Dropping the held handle
        // and then calling remove_file(path) would let a same-UID process
        // swap the name and make us delete its replacement. Preserve the
        // entire random staging directory until an explicit, independently
        // trusted recovery tool can retire it by identity.
        vec![format!(
            "verified WSL staging was intentionally recovery-held at {}; identity-bound UNC deletion is unavailable",
            stage_directory.display()
        )]
    }
}

pub(crate) struct HeldPrivateImportTarget<'a> {
    pub(crate) path: &'a Path,
    pub(crate) file: &'a mut std::fs::File,
}

pub(crate) struct HeldPrivateImportTargets<'a> {
    pub(crate) rgb: HeldPrivateImportTarget<'a>,
    pub(crate) ir: Option<HeldPrivateImportTarget<'a>>,
    pub(crate) meter: Option<HeldPrivateImportTarget<'a>>,
}

pub(crate) fn prepare_staged_receipt(
    config: &WslBridgeConfig,
    expected_rgb: &str,
    slot: u32,
    channels: Channels,
    receipt: &BridgeScanReceipt,
) -> Result<PreparedStagedReceipt, String> {
    prepare_staged_receipt_with_mapper(expected_rgb, slot, channels, receipt, &|path| {
        wsl_path_to_unc(config, path)
    })
}

pub(crate) fn prepare_staged_receipt_with_mapper<F>(
    expected_rgb: &str,
    slot: u32,
    channels: Channels,
    receipt: &BridgeScanReceipt,
    mapper: &F,
) -> Result<PreparedStagedReceipt, String>
where
    F: Fn(&str) -> Result<PathBuf, String>,
{
    validate_staged_receipt_paths(expected_rgb, slot, channels, receipt)?;
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
    let expected_parent = rgb_route
        .normalized
        .rsplit_once('/')
        .map(|(parent, _)| parent)
        .ok_or("WSL RGB staging path had no parent")?;
    for route in [ir_route.as_ref(), meter_route.as_ref()]
        .into_iter()
        .flatten()
    {
        if route.normalized.rsplit_once('/').map(|(parent, _)| parent) != Some(expected_parent) {
            return Err(
                "all WSL staged artifacts for one frame must share one private staging directory"
                    .into(),
            );
        }
    }

    let rgb = StagedArtifact::prepare(rgb_route, mapper)?;
    let stage_directory = rgb
        .path
        .parent()
        .ok_or("mapped WSL RGB artifact had no parent")?
        .to_path_buf();
    let ir = ir_route
        .map(|route| StagedArtifact::prepare(route, mapper))
        .transpose()?;
    let meter = meter_route
        .map(|route| StagedArtifact::prepare(route, mapper))
        .transpose()?;
    if [ir.as_ref(), meter.as_ref()]
        .into_iter()
        .flatten()
        .any(|artifact| artifact.path.parent() != Some(stage_directory.as_path()))
    {
        return Err("mapped WSL artifacts do not share one staging directory".into());
    }

    let attempts = receipt
        .attempts_root
        .as_deref()
        .map(validate_pinned_attempts_route)
        .transpose()?
        .map(|route| {
            let (path, authorities) = open_directory_route(&route, mapper)?;
            Ok::<HeldAttemptsRoot, String>(HeldAttemptsRoot {
                path,
                _authorities: authorities,
            })
        })
        .transpose()?;
    Ok(PreparedStagedReceipt {
        rgb,
        ir,
        meter,
        attempts,
        stage_directory,
    })
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
            "scanstudio-secure-wsl-{}-{}-{label}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn local_wsl_path(root: &Path, path: &str) -> Result<PathBuf, String> {
        Ok(root.join(path.trim_start_matches('/')))
    }

    fn rgb_evidence(image: &image_io::Rgb16Image) -> BridgeArtifactEvidence {
        let mut digest = Sha256::new();
        for pixel in &image.pixels {
            for sample in pixel {
                digest.update(sample.to_le_bytes());
            }
        }
        BridgeArtifactEvidence {
            sha256: format!("{:x}", digest.finalize()),
            byte_length: image.pixels.len() as u64 * 6,
            shape: vec![image.height, image.width, 3],
            dtype: "uint16".into(),
        }
    }

    fn gray_evidence(image: &image_io::Gray16Image) -> BridgeArtifactEvidence {
        let mut digest = Sha256::new();
        for sample in &image.pixels {
            digest.update(sample.to_le_bytes());
        }
        BridgeArtifactEvidence {
            sha256: format!("{:x}", digest.finalize()),
            byte_length: image.pixels.len() as u64 * 2,
            shape: vec![image.height, image.width],
            dtype: "uint16".into(),
        }
    }

    fn staged_receipt(root: &Path) -> BridgeScanReceipt {
        let rgb_path = "/tmp/scanstudio-wsl-staging/owner/capture-owner-0001.tif";
        let ir_path = "/tmp/scanstudio-wsl-staging/owner/capture-owner-0001_IR.tif";
        let attempts_root = "/home/test-user/.scanstudio/coolscanpy-attempts/session-abc";
        let rgb = local_wsl_path(root, rgb_path).unwrap();
        let ir = local_wsl_path(root, ir_path).unwrap();
        std::fs::create_dir_all(rgb.parent().unwrap()).unwrap();
        let rgb_image = image_io::Rgb16Image {
            width: 2,
            height: 1,
            pixels: vec![[1, 2, 3], [400, 500, 600]],
        };
        let ir_image = image_io::Gray16Image {
            width: 2,
            height: 1,
            pixels: vec![7, 9],
        };
        image_io::write_rgb16(&rgb, &rgb_image).unwrap();
        image_io::write_gray16(&ir, &ir_image).unwrap();
        std::fs::create_dir_all(local_wsl_path(root, attempts_root).unwrap()).unwrap();
        let mut artifacts = std::collections::HashMap::new();
        artifacts.insert("rgb".to_string(), rgb_evidence(&rgb_image));
        artifacts.insert("ir".to_string(), gray_evidence(&ir_image));
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
            raw_export_path: None,
            raw_export_ir_path: None,
        }
    }

    #[test]
    fn detects_only_the_pinned_windows_wsl_bridge_lane() {
        assert_eq!(
            config_for_bridge_command("wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge", true)
                .unwrap(),
            Some(WslBridgeConfig {
                distro: DEFAULT_WSL_DISTRO.to_string(),
            })
        );
        assert!(config_for_bridge_command("wsl.exe -e scanstudio-bridge", true).is_err());
        assert!(config_for_bridge_command("wsl.exe -d Debian -e scanstudio-bridge", true).is_err());
        assert!(config_for_bridge_command("scanstudio-bridge", true)
            .unwrap()
            .is_none());
        assert!(
            config_for_bridge_command("wsl.exe -e scanstudio-bridge", false)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn validates_windows_and_wsl_paths_without_destination_publication() {
        assert_eq!(
            windows_to_wsl_path(r"C:\Users\test-user\Scans"),
            Ok("/mnt/c/Users/test-user/Scans".to_string())
        );
        assert!(windows_to_wsl_path(r"C:Scans").is_err());
        assert!(windows_to_wsl_path(r"\\server\share\Scans").is_err());
        assert!(windows_to_wsl_path(r"C:\Scans\..\Elsewhere").is_err());
        assert_eq!(
            staging_root("0123abcd-owner").unwrap(),
            "/tmp/scanstudio-wsl-staging/0123abcd-owner"
        );
        assert!(staging_root("bad/owner").is_err());
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
    fn staged_receipt_refuses_raw_and_unpinned_routes_before_open() {
        let root = unique_dir("raw-refusal");
        std::fs::create_dir_all(&root).unwrap();
        let expected = "/tmp/scanstudio-wsl-staging/owner/capture-owner-0001.tif";
        let clean = staged_receipt(&root);
        validate_staged_receipt_paths(expected, 1, Channels::Rgbi, &clean).unwrap();
        let mut raw = clean.clone();
        raw.raw_export_path = Some("/tmp/evil.dng".into());
        assert!(
            validate_staged_receipt_paths(expected, 1, Channels::Rgbi, &raw)
                .unwrap_err()
                .contains("raw export")
        );
        let mut outside = clean;
        outside.rgb_path = "/tmp/other/capture.tif".into();
        assert!(validate_staged_receipt_paths(expected, 1, Channels::Rgbi, &outside).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn imports_into_held_private_files_and_rewrites_only_to_private_paths() {
        let root = unique_dir("private-import");
        std::fs::create_dir_all(&root).unwrap();
        let mut receipt = staged_receipt(&root);
        let expected = receipt.rgb_path.clone();
        let staged_rgb_bytes =
            std::fs::read(local_wsl_path(&root, &receipt.rgb_path).unwrap()).unwrap();
        let staged_ir_bytes =
            std::fs::read(local_wsl_path(&root, receipt.ir_path.as_deref().unwrap()).unwrap())
                .unwrap();
        let prepared =
            prepare_staged_receipt_with_mapper(&expected, 1, Channels::Rgbi, &receipt, &|path| {
                local_wsl_path(&root, path)
            })
            .unwrap();
        assert!(prepared.has_ir());
        assert!(!prepared.has_meter());
        let private = root.join("engine-private");
        std::fs::create_dir(&private).unwrap();
        let rgb_path = private.join("capture.tif");
        let ir_path = private.join("capture_IR.tif");
        let mut rgb = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&rgb_path)
            .unwrap();
        let mut ir = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&ir_path)
            .unwrap();
        let imported = prepared
            .import_into(
                &mut receipt,
                HeldPrivateImportTargets {
                    rgb: HeldPrivateImportTarget {
                        path: &rgb_path,
                        file: &mut rgb,
                    },
                    ir: Some(HeldPrivateImportTarget {
                        path: &ir_path,
                        file: &mut ir,
                    }),
                    meter: None,
                },
            )
            .unwrap();
        let cleanup_warnings = imported.cleanup();
        assert_eq!(cleanup_warnings.len(), 1);
        assert!(cleanup_warnings[0].contains("identity-bound UNC deletion is unavailable"));
        assert_eq!(receipt.rgb_path, rgb_path.display().to_string());
        assert_eq!(receipt.ir_path, Some(ir_path.display().to_string()));
        assert_eq!(std::fs::read(&rgb_path).unwrap(), staged_rgb_bytes);
        assert_eq!(std::fs::read(&ir_path).unwrap(), staged_ir_bytes);
        assert!(receipt
            .attempts_root
            .as_deref()
            .unwrap()
            .contains("coolscanpy-attempts"));
        assert!(root.join("tmp/scanstudio-wsl-staging/owner").is_dir());
        drop(rgb);
        drop(ir);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn artifact_evidence_failure_preserves_staging_and_never_rewrites_receipt() {
        let root = unique_dir("evidence-refusal");
        std::fs::create_dir_all(&root).unwrap();
        let mut receipt = staged_receipt(&root);
        let staged_rgb = receipt.rgb_path.clone();
        receipt.artifacts.get_mut("rgb").unwrap().sha256 = "0".repeat(64);
        let prepared =
            prepare_staged_receipt_with_mapper(&staged_rgb, 1, Channels::Rgbi, &receipt, &|path| {
                local_wsl_path(&root, path)
            })
            .unwrap();
        let private = root.join("engine-private");
        std::fs::create_dir(&private).unwrap();
        let rgb_path = private.join("capture.tif");
        let ir_path = private.join("capture_IR.tif");
        let user_destination = root.join("user-output.tif");
        let mut rgb = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&rgb_path)
            .unwrap();
        let mut ir = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&ir_path)
            .unwrap();
        let error = prepared
            .import_into(
                &mut receipt,
                HeldPrivateImportTargets {
                    rgb: HeldPrivateImportTarget {
                        path: &rgb_path,
                        file: &mut rgb,
                    },
                    ir: Some(HeldPrivateImportTarget {
                        path: &ir_path,
                        file: &mut ir,
                    }),
                    meter: None,
                },
            )
            .unwrap_err();
        assert!(error.contains("ArtifactEvidence"), "{error}");
        assert_eq!(receipt.rgb_path, staged_rgb);
        assert!(root.join("tmp/scanstudio-wsl-staging/owner").is_dir());
        assert!(!user_destination.exists());
        drop(rgb);
        drop(ir);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn staged_symlink_failure_creates_no_destination_and_never_touches_outside() {
        use std::os::unix::fs::symlink;

        let root = unique_dir("outside-sentinel");
        std::fs::create_dir_all(&root).unwrap();
        let receipt = staged_receipt(&root);
        let staged_rgb = local_wsl_path(&root, &receipt.rgb_path).unwrap();
        std::fs::remove_file(&staged_rgb).unwrap();
        let outside = root.join("outside");
        std::fs::create_dir(&outside).unwrap();
        let sentinel = outside.join("sentinel.tif");
        std::fs::write(&sentinel, b"outside sentinel").unwrap();
        symlink(&sentinel, &staged_rgb).unwrap();
        let user_destination = root.join("user-output.tif");

        let error = prepare_staged_receipt_with_mapper(
            &receipt.rgb_path,
            1,
            Channels::Rgbi,
            &receipt,
            &|path| local_wsl_path(&root, path),
        )
        .unwrap_err();
        assert!(error.contains("without following links") || error.contains("non-regular"));
        assert!(!user_destination.exists());
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"outside sentinel");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cleanup_uncertainty_preserves_the_staging_directory() {
        let root = unique_dir("cleanup-hold");
        std::fs::create_dir_all(&root).unwrap();
        let mut receipt = staged_receipt(&root);
        let stage = root.join("tmp/scanstudio-wsl-staging/owner");
        std::fs::write(stage.join("unexpected.txt"), b"preserve me").unwrap();
        let prepared = prepare_staged_receipt_with_mapper(
            &receipt.rgb_path,
            1,
            Channels::Rgbi,
            &receipt,
            &|path| local_wsl_path(&root, path),
        )
        .unwrap();
        let private = root.join("engine-private");
        std::fs::create_dir(&private).unwrap();
        let rgb_path = private.join("capture.tif");
        let ir_path = private.join("capture_IR.tif");
        let mut rgb = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&rgb_path)
            .unwrap();
        let mut ir = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&ir_path)
            .unwrap();
        let imported = prepared
            .import_into(
                &mut receipt,
                HeldPrivateImportTargets {
                    rgb: HeldPrivateImportTarget {
                        path: &rgb_path,
                        file: &mut rgb,
                    },
                    ir: Some(HeldPrivateImportTarget {
                        path: &ir_path,
                        file: &mut ir,
                    }),
                    meter: None,
                },
            )
            .unwrap();
        let cleanup_warnings = imported.cleanup();
        assert_eq!(cleanup_warnings.len(), 1);
        assert!(stage.is_dir());
        assert_eq!(
            std::fs::read(stage.join("unexpected.txt")).unwrap(),
            b"preserve me"
        );
        drop(rgb);
        drop(ir);
        std::fs::remove_dir_all(root).unwrap();
    }
}
