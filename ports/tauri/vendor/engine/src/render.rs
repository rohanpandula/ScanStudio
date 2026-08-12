//! Renders deterministic simulated frame data to real files per an
//! `OutputRecipe` (REC-01/REC-02/REC-03). When retained, archive writes are
//! strict create-only: the archive is PROJECT.md's "regenerable derivatives"
//! boundary — the capture master, never touched again once written.
//! Positive/preview writes may overwrite an existing file; they are the
//! regenerable derivatives, by design.

use std::io::{Read as _, Seek as _, Write as _};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use crate::domain;
use crate::parity::image_io;
use crate::processing::ice;
use crate::protocol;

// ---------------------------------------------------------------------
// Held output-destination authority
// ---------------------------------------------------------------------

/// One exact output leaf authorized before a scan job is dispatched.
///
/// The final path is display/provenance data only. All namespace mutations
/// are performed relative to the already-open destination directory below,
/// so replacing an ancestor with a symlink after preflight cannot redirect a
/// temporary or final write. The namespace is revalidated before publication
/// to turn a detected swap into a typed refusal rather than a hidden write to
/// a directory which is no longer reachable at the approved path.
#[derive(Debug, Clone)]
pub(crate) struct AuthorizedOutputLeaf {
    destination: HeldDestinationDirectory,
    final_name: std::ffi::OsString,
    final_path: PathBuf,
    create_only: bool,
    role: &'static str,
}

impl AuthorizedOutputLeaf {
    pub(crate) fn final_path(&self) -> &Path {
        &self.final_path
    }

    fn with_sibling_name(
        &self,
        final_name: std::ffi::OsString,
        final_path: PathBuf,
        role: &'static str,
    ) -> Result<Self, domain::EngineError> {
        validate_single_output_leaf_name(&final_name, role)?;
        Ok(Self {
            destination: self.destination.clone(),
            final_name,
            final_path,
            create_only: true,
            role,
        })
    }
}

/// Exact archive/derivative leaves for one frame. Archive sidecars share the
/// archive directory capability but have independently-authorized leaf names.
#[derive(Debug, Clone, Default)]
pub(crate) struct FrameOutputAuthorities {
    pub(crate) archive: Option<AuthorizedOutputLeaf>,
    pub(crate) archive_ir: Option<AuthorizedOutputLeaf>,
    pub(crate) archive_meter: Option<AuthorizedOutputLeaf>,
    pub(crate) positive: Option<AuthorizedOutputLeaf>,
    pub(crate) preview: Option<AuthorizedOutputLeaf>,
    pub(crate) raw: Option<AuthorizedOutputLeaf>,
    pub(crate) raw_ir: Option<AuthorizedOutputLeaf>,
    pub(crate) raw_marker: Option<AuthorizedOutputLeaf>,
}

/// Held destination authority for every frame in one accepted scan job.
/// These handles move into the worker and stay alive through final
/// publication; pathname preflight is never the authority itself.
#[derive(Debug, Clone)]
pub struct JobOutputAuthorities {
    project_root: Option<ProjectOutputRootAuthority>,
    frames: std::collections::HashMap<u32, FrameOutputAuthorities>,
    evidence_destinations: Vec<EvidenceDestinationAuthority>,
    reserved_evidence_packages: Vec<ReservedEvidencePackage>,
}

impl JobOutputAuthorities {
    pub(crate) fn frame(
        &self,
        frame_index: u32,
    ) -> Result<&FrameOutputAuthorities, domain::EngineError> {
        self.frames.get(&frame_index).ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("scan job omitted held output authority for frame {frame_index}"),
            )
        })
    }

    pub(crate) fn project_root(&self) -> Option<&ProjectOutputRootAuthority> {
        self.project_root.as_ref()
    }

    /// Reserves every requested full-capture package before the bridge sees
    /// `scan.start`. The exact package directories are created relative to
    /// the already-held archive destinations and remain open for the entire
    /// job. A pre-existing file, directory, link, or reparse point is thus a
    /// synchronous collision rather than a post-motion surprise.
    pub(crate) fn reserve_evidence_packages(
        &mut self,
        job_id: &str,
    ) -> Result<(), domain::EngineError> {
        self.reserve_evidence_packages_with_hook(job_id, |_, _| Ok(()))
    }

    fn reserve_evidence_packages_with_hook<Hook>(
        &mut self,
        job_id: &str,
        mut after_reservation: Hook,
    ) -> Result<(), domain::EngineError>
    where
        Hook: FnMut(usize, &ReservedEvidencePackage) -> Result<(), domain::EngineError>,
    {
        crate::evidence_package::validate_job_id(job_id).map_err(|error| {
            output_authority_error(format!("invalid evidence package job id: {error}"))
        })?;
        if !self.reserved_evidence_packages.is_empty() {
            return Err(output_authority_error(
                "capture evidence packages were already reserved for this job",
            ));
        }

        let package_name = std::ffi::OsString::from(format!("{job_id}.scanstudio"));
        validate_single_output_leaf_name(&package_name, "capture evidence package")?;

        // Resolve each fixed `Capture Evidence` child from the already-held
        // archive destination. Never reconstruct an archive destination from
        // the recipe string here.
        let mut evidence_roots = Vec::<(HeldDestinationDirectory, Vec<u32>)>::new();
        let mut physical_roots = std::collections::HashMap::<(u64, u64), usize>::new();
        for requested in &self.evidence_destinations {
            let root = acquire_held_child_directory(
                &requested.destination,
                std::ffi::OsStr::new("Capture Evidence"),
                "capture evidence root",
            )?;
            let identity = held_directory_identity(&root)?;
            if let Some(index) = physical_roots.get(&identity).copied() {
                evidence_roots[index]
                    .1
                    .extend(requested.eligible_slots.iter().copied());
            } else {
                physical_roots.insert(identity, evidence_roots.len());
                evidence_roots.push((root, requested.eligible_slots.clone()));
            }
        }
        for (_, slots) in &mut evidence_roots {
            slots.sort_unstable();
            slots.dedup();
        }

        // Check the whole graph before creating any package directory so an
        // ordinary planted collision cannot leave partial reservations in a
        // different destination.
        for (root, _) in &evidence_roots {
            if destination_sys::leaf_entry_exists(&root.inner, &package_name)? {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::ArchiveCollision,
                    format!(
                        "capture evidence package already exists at {}; refusing before capture",
                        root.inner.display_path.join(&package_name).display()
                    ),
                )
                .with_recoverable(true));
            }
        }

        let mut reserved = Vec::with_capacity(evidence_roots.len());
        for (root, eligible_slots) in evidence_roots {
            destination_sys::verify_namespace(&root.inner)?;
            let directory = match destination_sys::create_held_directory(
                &root.inner.directory,
                &package_name,
            ) {
                Ok(directory) => directory,
                Err(error) => {
                    let code = if error.kind() == std::io::ErrorKind::AlreadyExists {
                        protocol::ErrorCode::ArchiveCollision
                    } else {
                        protocol::ErrorCode::InvalidParams
                    };
                    let primary = domain::EngineError::new(
                        code,
                        format!(
                            "create-only capture evidence package {} before capture: {error}",
                            root.inner.display_path.join(&package_name).display()
                        ),
                    )
                    .with_recoverable(true);
                    return Err(with_evidence_reservation_rollback(primary, reserved));
                }
            };
            let package = ReservedEvidencePackage {
                parent: root,
                directory: Arc::new(directory),
                final_name: package_name.clone(),
                final_path: PathBuf::new(),
                job_id: job_id.to_string(),
                eligible_slots,
            }
            .with_display_path();
            reserved.push(package);
            let package = reserved
                .last()
                .expect("the newly-created evidence reservation was retained");
            if let Err(error) = crate::exiftool::metadata_publish_sys::sync_directory(
                &package.parent.inner.directory,
            )
            .map_err(|error| {
                output_authority_error(format!(
                    "sync capture evidence parent {} after reservation: {error}",
                    package.parent.inner.display_path.display()
                ))
            }) {
                return Err(with_evidence_reservation_rollback(error, reserved));
            }
            if let Err(error) = package.verify_namespace() {
                return Err(with_evidence_reservation_rollback(error, reserved));
            }
            let reservation_index = reserved.len() - 1;
            if let Err(error) = after_reservation(reservation_index, package) {
                return Err(with_evidence_reservation_rollback(error, reserved));
            }
        }
        self.reserved_evidence_packages = reserved;
        Ok(())
    }

    /// Retires create-only package directories while the request is still
    /// known not to have crossed the bridge motion boundary. A non-empty,
    /// replaced, or otherwise ambiguous reservation is preserved and reported
    /// rather than recursively removed.
    pub(crate) fn rollback_pre_motion_evidence_reservations(
        &mut self,
    ) -> Result<(), domain::EngineError> {
        rollback_reserved_evidence_packages(std::mem::take(&mut self.reserved_evidence_packages))
    }

    pub(crate) fn reserved_evidence_packages(&self) -> &[ReservedEvidencePackage] {
        &self.reserved_evidence_packages
    }
}

#[derive(Debug, Clone)]
struct EvidenceDestinationAuthority {
    destination: HeldDestinationDirectory,
    eligible_slots: Vec<u32>,
}

/// Opaque, job-bound authority for one exact `<job>.scanstudio` directory.
/// `final_path` is display/provenance only; all package contents are created
/// relative to `directory` and every commit revalidates the parent/name pair.
#[derive(Debug, Clone)]
pub(crate) struct ReservedEvidencePackage {
    parent: HeldDestinationDirectory,
    directory: Arc<std::fs::File>,
    final_name: std::ffi::OsString,
    final_path: PathBuf,
    job_id: String,
    eligible_slots: Vec<u32>,
}

impl ReservedEvidencePackage {
    fn with_display_path(mut self) -> Self {
        self.final_path = self.parent.inner.display_path.join(&self.final_name);
        self
    }

    pub(crate) fn job_id(&self) -> &str {
        &self.job_id
    }

    pub(crate) fn final_path(&self) -> &Path {
        &self.final_path
    }

    pub(crate) fn directory_handle(&self) -> &std::fs::File {
        self.directory.as_ref()
    }

    pub(crate) fn eligible_slots(&self) -> &[u32] {
        &self.eligible_slots
    }

    pub(crate) fn verify_namespace(&self) -> Result<(), domain::EngineError> {
        destination_sys::verify_namespace(&self.parent.inner)?;
        let reopened = crate::exiftool::metadata_publish_sys::open_child_directory(
            &self.parent.inner.directory,
            &self.final_name,
        )
        .map_err(|error| {
            output_authority_error(format!(
                "capture evidence package authority changed at {}: {error}",
                self.final_path.display()
            ))
        })?;
        if directory_handle_identity(self.directory_handle())?
            != directory_handle_identity(&reopened)?
        {
            return Err(output_authority_error(format!(
                "capture evidence package authority changed at {}; refusing redirected write",
                self.final_path.display()
            )));
        }
        Ok(())
    }

    pub(crate) fn verify_regular_file(
        &self,
        relative: &Path,
        expected: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        if relative.as_os_str().is_empty() || relative.is_absolute() {
            return Err(output_authority_error(
                "evidence package file proof must use a non-empty relative path",
            ));
        }
        let mut components = Vec::<std::ffi::OsString>::new();
        for component in relative.components() {
            let std::path::Component::Normal(component) = component else {
                return Err(output_authority_error(format!(
                    "evidence package file proof contains an unsafe component: {}",
                    relative.display()
                )));
            };
            components.push(component.to_os_string());
        }
        let (leaf, parents) = components
            .split_last()
            .ok_or_else(|| output_authority_error("evidence package file proof has no leaf"))?;
        self.verify_namespace()?;
        let mut directory = self.directory_handle().try_clone().map_err(|error| {
            output_authority_error(format!(
                "retain evidence package directory while verifying {}: {error}",
                relative.display()
            ))
        })?;
        for component in parents {
            directory =
                crate::exiftool::metadata_publish_sys::open_child_directory(&directory, component)
                    .map_err(|error| {
                        output_authority_error(format!(
                "open evidence package proof parent {:?} without following links: {error}",
                component
            ))
                    })?;
        }
        let reopened = crate::exiftool::metadata_publish_sys::open_regular(&directory, leaf)
            .map_err(|error| {
                output_authority_error(format!(
                    "reopen evidence package file {} without following links: {error}",
                    relative.display()
                ))
            })?;
        if regular_file_handle_identity(expected)? != regular_file_handle_identity(&reopened)? {
            return Err(output_authority_error(format!(
                "evidence package file identity changed at {}; refusing complete status",
                relative.display()
            )));
        }
        self.verify_namespace()
    }

    /// Retires one exact held package file only on platforms whose kernel can
    /// bind deletion to the already-open file object. Unix `unlinkat` is
    /// parent-relative but still name-based, so a same-UID process could swap
    /// a replacement between identity verification and unlink. In that case
    /// the package is deliberately recovery-held instead.
    pub(crate) fn retire_exact_root_file(
        &self,
        name: &std::ffi::OsStr,
        expected: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        let relative = Path::new(name);
        if relative.components().count() != 1
            || !matches!(
                relative.components().next(),
                Some(std::path::Component::Normal(_))
            )
        {
            return Err(output_authority_error(
                "exact evidence cleanup requires one normal root-file component",
            ));
        }
        self.verify_regular_file(relative, expected)?;
        destination_sys::delete_exact_regular_file(expected)?;
        crate::exiftool::metadata_publish_sys::sync_directory(self.directory_handle()).map_err(
            |error| {
                output_authority_error(format!(
                    "sync evidence package after exact cleanup of {name:?}: {error}"
                ))
            },
        )?;
        match crate::exiftool::metadata_publish_sys::open_regular(self.directory_handle(), name) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(output_authority_error(format!(
                    "HOLD: cannot prove evidence package name {name:?} is vacant after exact cleanup: {error}"
                )))
            }
            Ok(_) => {
                return Err(output_authority_error(format!(
                    "HOLD: evidence package name {name:?} was repopulated during exact cleanup; preserving the replacement"
                )))
            }
        }
        self.verify_namespace()
    }

    fn rollback_empty_reservation(self) -> Result<(), domain::EngineError> {
        self.verify_namespace()?;
        let entries =
            crate::exiftool::metadata_publish_sys::read_directory_names(self.directory_handle())
                .map_err(|error| {
                    output_authority_error(format!(
                        "inspect pre-motion evidence reservation {} before rollback: {error}",
                        self.final_path.display()
                    ))
                })?;
        if !entries.is_empty() {
            return Err(output_authority_error(format!(
                "pre-motion evidence reservation {} is no longer empty; preserving it for recovery",
                self.final_path.display()
            )));
        }
        let ReservedEvidencePackage {
            parent,
            directory,
            final_name,
            final_path,
            ..
        } = self;
        let directory = Arc::try_unwrap(directory).map_err(|_| {
            output_authority_error(format!(
                "pre-motion evidence reservation {} still has live consumers; preserving it for recovery",
                final_path.display()
            ))
        })?;
        destination_sys::remove_exact_empty_directory(
            &parent.inner,
            &final_name,
            directory,
            "pre-motion evidence reservation",
        )?;
        crate::exiftool::metadata_publish_sys::sync_directory(&parent.inner.directory).map_err(
            |error| {
                output_authority_error(format!(
                    "sync evidence parent after rolling back {}: {error}",
                    final_path.display()
                ))
            },
        )?;
        destination_sys::verify_namespace(&parent.inner)?;
        if destination_sys::leaf_entry_exists(&parent.inner, &final_name)? {
            return Err(output_authority_error(format!(
                "pre-motion evidence reservation name reappeared at {}; preserving the new entry",
                final_path.display()
            )));
        }
        Ok(())
    }
}

/// Creates one directory relative to a held parent without a best-effort
/// name deletion if the post-create open fails. Evidence publication uses
/// this wrapper instead of the shared metadata helper because, on Unix, an
/// unlink after a failed open could remove a same-UID replacement.
pub(crate) fn create_evidence_directory_nondestructive(
    parent: &std::fs::File,
    name: &std::ffi::OsStr,
) -> std::io::Result<std::fs::File> {
    destination_sys::create_held_directory(parent, name)
}

fn rollback_reserved_evidence_packages(
    packages: Vec<ReservedEvidencePackage>,
) -> Result<(), domain::EngineError> {
    let mut failures = Vec::new();
    for package in packages.into_iter().rev() {
        let path = package.final_path().to_path_buf();
        if let Err(error) = package.rollback_empty_reservation() {
            failures.push(format!("{}: {}", path.display(), error.message));
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "one or more pre-motion evidence reservations require recovery: {}",
                failures.join("; ")
            ),
        ))
    }
}

fn with_evidence_reservation_rollback(
    mut primary: domain::EngineError,
    reservations: Vec<ReservedEvidencePackage>,
) -> domain::EngineError {
    if let Err(cleanup) = rollback_reserved_evidence_packages(reservations) {
        primary.message = format!(
            "{}; pre-motion evidence rollback was incomplete: {}",
            primary.message, cleanup.message
        );
        primary = primary.with_recoverable(false);
    }
    primary
}

/// The active project root captured once, before any pathname-based output
/// preflight. Later leaf acquisition must derive from this exact held handle;
/// re-canonicalizing the project path would silently authorize a replacement
/// installed between preflight and backend dispatch.
#[derive(Debug, Clone)]
pub(crate) struct ProjectOutputRootAuthority {
    requested_path: PathBuf,
    canonical_path: PathBuf,
    root: Arc<std::fs::File>,
}

impl ProjectOutputRootAuthority {
    pub(crate) fn requested_path(&self) -> &Path {
        &self.requested_path
    }

    pub(crate) fn canonical_path(&self) -> &Path {
        &self.canonical_path
    }

    pub(crate) fn directory_handle(&self) -> &std::fs::File {
        self.root.as_ref()
    }

    #[cfg(any(unix, windows))]
    pub(crate) fn verify_namespace(&self) -> Result<(), domain::EngineError> {
        let requested_now = std::fs::canonicalize(self.requested_path()).map_err(|error| {
            output_authority_error(format!(
                "project-root requested namespace changed at {}: {error}",
                self.requested_path().display()
            ))
        })?;
        destination_sys::verify_root(&requested_now, self.directory_handle()).map_err(|_| {
            output_authority_error(format!(
                "project-root requested namespace changed at {}",
                self.requested_path().display()
            ))
        })?;
        destination_sys::verify_root(self.canonical_path(), self.directory_handle())
    }

    #[cfg(not(any(unix, windows)))]
    pub(crate) fn verify_namespace(&self) -> Result<(), domain::EngineError> {
        Err(output_authority_error(
            "project-root namespace verification is unsupported on this platform",
        ))
    }
}

#[derive(Debug, Clone)]
struct HeldDestinationDirectory {
    inner: Arc<HeldDestinationDirectoryInner>,
}

#[cfg(unix)]
#[derive(Debug)]
struct HeldDestinationDirectoryInner {
    root: std::fs::File,
    root_path: PathBuf,
    relative_components: Vec<std::ffi::OsString>,
    directory: std::fs::File,
    display_path: PathBuf,
}

#[cfg(windows)]
#[derive(Debug)]
struct HeldDestinationDirectoryInner {
    root: std::fs::File,
    root_path: PathBuf,
    /// Every component is opened without FILE_SHARE_DELETE, so none can be
    /// renamed or removed while this capability is alive.
    component_guards: Vec<std::fs::File>,
    directory: std::fs::File,
    display_path: PathBuf,
}

#[cfg(not(any(unix, windows)))]
#[derive(Debug)]
struct HeldDestinationDirectoryInner;

fn output_authority_error(message: impl Into<String>) -> domain::EngineError {
    domain::EngineError::new(protocol::ErrorCode::InvalidParams, message.into())
        .with_recoverable(true)
}

fn validate_single_output_leaf_name(
    name: &std::ffi::OsStr,
    role: &str,
) -> Result<(), domain::EngineError> {
    let path = Path::new(name);
    if name.is_empty()
        || !matches!(
            (path.components().next(), path.components().count()),
            (Some(std::path::Component::Normal(_)), 1)
        )
    {
        return Err(output_authority_error(format!(
            "{role} output leaf must be one relative file name"
        )));
    }
    #[cfg(windows)]
    {
        let value = name.to_str().ok_or_else(|| {
            output_authority_error(format!(
                "{role} output leaf is not valid Unicode for Win32 publication"
            ))
        })?;
        if let Some(reason) = invalid_windows_output_leaf_reason(value) {
            return Err(output_authority_error(format!(
                "{role} output leaf {value:?} is unsafe on Windows: {reason}"
            )));
        }
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn invalid_windows_output_leaf_reason(value: &str) -> Option<&'static str> {
    if value.ends_with('.') || value.ends_with(' ') {
        return Some("trailing dots or spaces are normalized by Win32");
    }
    if value.chars().any(|character| {
        character <= '\u{1f}'
            || matches!(
                character,
                '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*'
            )
    }) {
        return Some("it contains a reserved Win32 character or ADS separator");
    }
    let basename = value.split('.').next().unwrap_or_default();
    let basename_bytes = basename.as_bytes();
    let numbered_device = basename_bytes.len() == 4
        && (basename_bytes[..3].eq_ignore_ascii_case(b"COM")
            || basename_bytes[..3].eq_ignore_ascii_case(b"LPT"))
        && matches!(basename_bytes[3], b'1'..=b'9');
    let reserved_device = ["CON", "PRN", "AUX", "NUL", "CLOCK$"]
        .iter()
        .any(|reserved| basename.eq_ignore_ascii_case(reserved));
    if reserved_device || numbered_device {
        return Some("it uses a reserved Win32 device basename");
    }
    None
}

#[cfg(windows)]
#[repr(C)]
struct WindowsFileTime {
    low_date_time: u32,
    high_date_time: u32,
}

#[cfg(windows)]
#[repr(C)]
struct WindowsByHandleFileInformation {
    file_attributes: u32,
    creation_time: WindowsFileTime,
    last_access_time: WindowsFileTime,
    last_write_time: WindowsFileTime,
    volume_serial_number: u32,
    file_size_high: u32,
    file_size_low: u32,
    number_of_links: u32,
    file_index_high: u32,
    file_index_low: u32,
}

#[cfg(windows)]
fn windows_file_identity(file: &std::fs::File) -> std::io::Result<(u64, u64, u64)> {
    use std::os::windows::io::AsRawHandle as _;

    #[link(name = "Kernel32")]
    extern "system" {
        fn GetFileInformationByHandle(
            file: *mut std::ffi::c_void,
            information: *mut WindowsByHandleFileInformation,
        ) -> i32;
    }

    let mut information = std::mem::MaybeUninit::<WindowsByHandleFileInformation>::uninit();
    let result = unsafe {
        GetFileInformationByHandle(file.as_raw_handle().cast(), information.as_mut_ptr())
    };
    if result == 0 {
        return Err(std::io::Error::last_os_error());
    }
    let information = unsafe { information.assume_init() };
    Ok((
        u64::from(information.volume_serial_number),
        (u64::from(information.file_index_high) << 32) | u64::from(information.file_index_low),
        u64::from(information.number_of_links),
    ))
}

#[cfg(unix)]
mod destination_sys {
    use super::*;
    use std::ffi::CString;
    use std::os::fd::{AsRawFd as _, FromRawFd as _};
    use std::os::unix::ffi::OsStrExt as _;
    use std::os::unix::fs::MetadataExt as _;

    fn c_name(name: &std::ffi::OsStr, label: &str) -> Result<CString, domain::EngineError> {
        CString::new(name.as_bytes())
            .map_err(|_| output_authority_error(format!("{label} contains an embedded NUL byte")))
    }

    fn open_directory_path_nofollow(path: &Path) -> std::io::Result<std::fs::File> {
        let c_path = CString::new(path.as_os_str().as_bytes()).map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "path contains NUL")
        })?;
        let fd = unsafe {
            libc::open(
                c_path.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(unsafe { std::fs::File::from_raw_fd(fd) })
        }
    }

    fn open_directory_at(
        parent: &std::fs::File,
        name: &std::ffi::OsStr,
    ) -> Result<std::fs::File, std::io::Error> {
        let name = CString::new(name.as_bytes()).map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "path component contains NUL",
            )
        })?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(unsafe { std::fs::File::from_raw_fd(fd) })
        }
    }

    fn mkdir_at(parent: &std::fs::File, name: &std::ffi::OsStr) -> std::io::Result<()> {
        let name = CString::new(name.as_bytes()).map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "path component contains NUL",
            )
        })?;
        let result = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
        if result == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    pub(super) fn create_held_directory(
        parent: &std::fs::File,
        name: &std::ffi::OsStr,
    ) -> std::io::Result<std::fs::File> {
        mkdir_at(parent, name)?;
        open_directory_at(parent, name).map_err(|error| {
            // There is no identity-bound directory unlink on supported Unix
            // targets. Never follow a failed post-mkdir open with an unlinkat
            // that could delete a same-UID replacement installed meanwhile.
            std::io::Error::new(
                error.kind(),
                format!(
                    "HOLD: created directory could not be opened authoritatively and was preserved: {error}"
                ),
            )
        })
    }

    pub(super) fn delete_exact_regular_file(
        _file: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        Err(output_authority_error(
            "HOLD: Unix has no identity-bound regular-file deletion primitive; preserving the held evidence file",
        ))
    }

    pub(super) fn remove_exact_empty_directory(
        _held_parent: &HeldDestinationDirectoryInner,
        _name: &std::ffi::OsStr,
        _directory: std::fs::File,
        role: &str,
    ) -> Result<(), domain::EngineError> {
        Err(output_authority_error(format!(
            "HOLD: Unix has no identity-bound directory deletion primitive; preserving the held {role}"
        )))
    }

    /// The filesystem-collation oracle is an intentionally narrow exception
    /// to recovery-held publisher rollback. Its random, engine-created names
    /// contain no user data and live under an already-held destination. Unix
    /// cannot make unlink conditional on inode identity, so a same-UID racer
    /// can at worst force a cleanup error or swap another entry it already had
    /// authority to remove; it cannot redirect a write or mutate outside data.
    pub(super) fn delete_ephemeral_probe_leaf(
        parent: &std::fs::File,
        name: &std::ffi::OsStr,
        expected: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        let reopened =
            crate::exiftool::metadata_publish_sys::open_regular(parent, name).map_err(|error| {
                output_authority_error(format!("reopen ephemeral alias-probe leaf: {error}"))
            })?;
        if regular_file_handle_identity(&reopened)? != regular_file_handle_identity(expected)? {
            return Err(output_authority_error(
                "ephemeral alias-probe leaf identity changed; preserving the replacement",
            ));
        }
        crate::exiftool::metadata_publish_sys::unlink(parent, name).map_err(|error| {
            output_authority_error(format!("retire ephemeral alias-probe leaf: {error}"))
        })
    }

    pub(super) fn remove_ephemeral_probe_directory(
        held_parent: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
        directory: std::fs::File,
    ) -> Result<(), domain::EngineError> {
        verify_namespace(held_parent)?;
        let expected = directory_handle_identity(&directory)?;
        if !crate::exiftool::metadata_publish_sys::read_directory_names(&directory)
            .map_err(|error| {
                output_authority_error(format!("inspect emptied alias-probe directory: {error}"))
            })?
            .is_empty()
        {
            return Err(output_authority_error(
                "ephemeral alias-probe directory gained content; preserving it",
            ));
        }
        let reopened = crate::exiftool::metadata_publish_sys::open_child_directory(
            &held_parent.directory,
            name,
        )
        .map_err(|error| {
            output_authority_error(format!("reopen ephemeral alias-probe directory: {error}"))
        })?;
        if directory_handle_identity(&reopened)? != expected {
            return Err(output_authority_error(
                "ephemeral alias-probe directory identity changed; preserving the replacement",
            ));
        }
        drop(reopened);
        drop(directory);
        crate::exiftool::metadata_publish_sys::remove_directory(&held_parent.directory, name)
            .map_err(|error| {
                output_authority_error(format!("retire ephemeral alias-probe directory: {error}"))
            })
    }

    pub(super) fn open_or_create_directory_chain(
        root: &std::fs::File,
        components: &[std::ffi::OsString],
        role: &str,
    ) -> Result<std::fs::File, domain::EngineError> {
        let mut current = root.try_clone().map_err(|error| {
            output_authority_error(format!("retain project-root authority for {role}: {error}"))
        })?;
        ensure_identity_safe_filesystem(&current, role)?;
        for component in components {
            match open_directory_at(&current, component) {
                Ok(next) => current = next,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    match mkdir_at(&current, component) {
                        Ok(()) => current.sync_all().map_err(|error| {
                            output_authority_error(format!(
                                "sync parent after securely creating {role} destination component {:?}: {error}",
                                component
                            ))
                        })?,
                        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(error) => {
                            return Err(output_authority_error(format!(
                                "securely create {role} destination component {:?}: {error}",
                                component
                            )))
                        }
                    }
                    current = open_directory_at(&current, component).map_err(|error| {
                        output_authority_error(format!(
                            "securely open newly-created {role} destination component {:?} without following links: {error}",
                            component
                        ))
                    })?;
                }
                Err(error) => {
                    return Err(output_authority_error(format!(
                        "securely open {role} destination component {:?} without following links: {error}",
                        component
                    )))
                }
            }
            ensure_identity_safe_filesystem(&current, role)?;
        }
        Ok(current)
    }

    fn open_existing_directory_chain(
        root: &std::fs::File,
        components: &[std::ffi::OsString],
        role: &str,
    ) -> Result<std::fs::File, domain::EngineError> {
        let mut current = root.try_clone().map_err(|error| {
            output_authority_error(format!("retain project-root authority for {role}: {error}"))
        })?;
        for component in components {
            current = open_directory_at(&current, component).map_err(|error| {
                output_authority_error(format!(
                    "revalidate existing {role} destination component {:?} without following links: {error}",
                    component
                ))
            })?;
        }
        Ok(current)
    }

    fn same_directory_identity(
        left: &std::fs::File,
        right: &std::fs::File,
    ) -> std::io::Result<bool> {
        let left = left.metadata()?;
        let right = right.metadata()?;
        Ok(left.is_dir()
            && right.is_dir()
            && left.dev() == right.dev()
            && left.ino() == right.ino())
    }

    pub(super) fn verify_namespace(
        held: &HeldDestinationDirectoryInner,
    ) -> Result<(), domain::EngineError> {
        let reopened_root = open_directory_path_nofollow(&held.root_path).map_err(|error| {
            output_authority_error(format!(
                "project-root authority changed before output publication at {}: {error}",
                held.root_path.display()
            ))
        })?;
        if !same_directory_identity(&held.root, &reopened_root).map_err(|error| {
            output_authority_error(format!("compare held project-root identity: {error}"))
        })? {
            return Err(output_authority_error(format!(
                "project-root authority changed before output publication at {}",
                held.root_path.display()
            )));
        }
        // Publication is validation-only. Never recreate a component which
        // disappeared after authority acquisition: doing so would mutate a
        // replacement namespace before refusing the race.
        let reopened = open_existing_directory_chain(
            &held.root,
            &held.relative_components,
            "existing output",
        )?;
        if !same_directory_identity(&held.directory, &reopened).map_err(|error| {
            output_authority_error(format!("compare held output-directory identity: {error}"))
        })? {
            return Err(output_authority_error(format!(
                "output destination authority changed before publication at {}; refusing redirected write",
                held.display_path.display()
            )));
        }
        Ok(())
    }

    pub(super) fn reserve_private_sibling(
        held: &HeldDestinationDirectoryInner,
        final_name: &std::ffi::OsStr,
        purpose: &str,
    ) -> Result<(std::ffi::OsString, std::fs::File), domain::EngineError> {
        verify_namespace(held)?;
        let final_display = final_name.to_string_lossy();
        for _ in 0..128 {
            let token = super::publication_token()?;
            let candidate = std::ffi::OsString::from(format!(
                ".{final_display}.scanstudio-{purpose}-{token}.tmp"
            ));
            let c_candidate = c_name(&candidate, "temporary output leaf")?;
            let fd = unsafe {
                libc::openat(
                    held.directory.as_raw_fd(),
                    c_candidate.as_ptr(),
                    libc::O_RDWR
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600,
                )
            };
            if fd >= 0 {
                return Ok((candidate, unsafe { std::fs::File::from_raw_fd(fd) }));
            }
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                continue;
            }
            return Err(output_authority_error(format!(
                "reserve private {purpose} sibling in {}: {error}",
                held.display_path.display()
            )));
        }
        Err(output_authority_error(format!(
            "could not reserve a unique private {purpose} sibling in {}",
            held.display_path.display()
        )))
    }

    pub(super) fn unlink_leaf(
        held: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
        _file: &std::fs::File,
    ) -> std::io::Result<()> {
        let name = CString::new(name.as_bytes()).map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "leaf contains NUL")
        })?;
        let result = unsafe { libc::unlinkat(held.directory.as_raw_fd(), name.as_ptr(), 0) };
        if result == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    pub(super) fn leaf_entry_exists(
        held: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
    ) -> Result<bool, domain::EngineError> {
        verify_namespace(held)?;
        let name = c_name(name, "authorized output leaf")?;
        let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
        let result = unsafe {
            libc::fstatat(
                held.directory.as_raw_fd(),
                name.as_ptr(),
                metadata.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if result == 0 {
            Ok(true)
        } else {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::NotFound {
                Ok(false)
            } else {
                Err(output_authority_error(format!(
                    "inspect authorized output leaf without following links: {error}"
                )))
            }
        }
    }

    pub(super) fn publish(
        held: &HeldDestinationDirectoryInner,
        temporary: &std::ffi::OsStr,
        final_name: &std::ffi::OsStr,
        temporary_file: &std::fs::File,
        create_only: bool,
        role: &str,
    ) -> Result<(), domain::EngineError> {
        verify_namespace(held)?;
        let temporary_c = c_name(temporary, "temporary output leaf")?;
        let final_c = c_name(final_name, "final output leaf")?;
        let result = if create_only {
            unsafe {
                libc::linkat(
                    held.directory.as_raw_fd(),
                    temporary_c.as_ptr(),
                    held.directory.as_raw_fd(),
                    final_c.as_ptr(),
                    0,
                )
            }
        } else {
            unsafe {
                libc::renameat(
                    held.directory.as_raw_fd(),
                    temporary_c.as_ptr(),
                    held.directory.as_raw_fd(),
                    final_c.as_ptr(),
                )
            }
        };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            let code = if create_only && error.kind() == std::io::ErrorKind::AlreadyExists {
                protocol::ErrorCode::ArchiveCollision
            } else {
                protocol::ErrorCode::Internal
            };
            return Err(domain::EngineError::new(
                code,
                format!(
                    "failed to publish {role} at {}: {error}",
                    held.display_path.join(final_name).display()
                ),
            )
            .with_recoverable(true));
        }
        if create_only {
            unlink_leaf(held, temporary, temporary_file).map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("published {role} but could not retire its private sibling: {error}"),
                )
            })?;
        }
        held.directory.sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("sync output destination after publishing {role}: {error}"),
            )
        })?;
        Ok(())
    }

    pub(super) fn verify_leaf_identity(
        held: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
        file: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        verify_namespace(held)?;
        let name = c_name(name, "published output leaf")?;
        let fd = unsafe {
            libc::openat(
                held.directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(output_authority_error(format!(
                "cannot reopen published output relative to held destination: {}",
                std::io::Error::last_os_error()
            )));
        }
        let reopened = unsafe { std::fs::File::from_raw_fd(fd) };
        let expected = file.metadata().map_err(|error| {
            output_authority_error(format!("inspect held published output: {error}"))
        })?;
        let actual = reopened.metadata().map_err(|error| {
            output_authority_error(format!("inspect reopened published output: {error}"))
        })?;
        if !expected.is_file()
            || !actual.is_file()
            || expected.dev() != actual.dev()
            || expected.ino() != actual.ino()
            || expected.nlink() != 1
            || actual.nlink() != 1
        {
            return Err(output_authority_error(
                "published output identity is not the unique file held by the engine",
            ));
        }
        Ok(())
    }

    pub(super) fn remove_published_leaf(
        held: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
        file: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        verify_leaf_identity(held, name, file)?;
        unlink_leaf(held, name, file).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("rollback authorized publication: {error}"),
            )
        })?;
        held.directory.sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("sync destination after publication rollback: {error}"),
            )
        })
    }

    pub(super) fn open_root(path: &Path) -> Result<std::fs::File, domain::EngineError> {
        if !path.is_absolute() {
            return Err(output_authority_error(format!(
                "canonical output root is not absolute: {}",
                path.display()
            )));
        }
        let filesystem_root = open_directory_path_nofollow(Path::new("/")).map_err(|error| {
            output_authority_error(format!("securely open filesystem root: {error}"))
        })?;
        let mut components = Vec::new();
        for component in path.components() {
            match component {
                std::path::Component::RootDir => {}
                std::path::Component::Normal(value) => components.push(value.to_os_string()),
                _ => {
                    return Err(output_authority_error(format!(
                        "canonical output root contains an unsafe component: {}",
                        path.display()
                    )))
                }
            }
        }
        open_existing_directory_chain(&filesystem_root, &components, "canonical output root")
    }

    pub(super) fn open_project_root(path: &Path) -> Result<std::fs::File, domain::EngineError> {
        open_root(path)
    }

    pub(super) fn verify_root(
        path: &Path,
        held: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        let reopened = open_root(path)?;
        if same_directory_identity(held, &reopened).map_err(|error| {
            output_authority_error(format!("compare held project-root identity: {error}"))
        })? {
            Ok(())
        } else {
            Err(output_authority_error(format!(
                "project-root authority changed at {}",
                path.display()
            )))
        }
    }
}

#[cfg(windows)]
mod destination_sys {
    use super::*;
    use std::os::windows::ffi::OsStrExt as _;
    use std::os::windows::fs::{MetadataExt as _, OpenOptionsExt as _};
    use std::os::windows::io::AsRawHandle as _;

    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_FLAG_WRITE_THROUGH: u32 = 0x8000_0000;
    const FILE_SHARE_READ: u32 = 0x0000_0001;
    const FILE_SHARE_WRITE: u32 = 0x0000_0002;
    const FILE_SHARE_DELETE: u32 = 0x0000_0004;
    const FILE_LIST_DIRECTORY: u32 = 0x0000_0001;
    const FILE_TRAVERSE: u32 = 0x0000_0020;
    const FILE_READ_ATTRIBUTES: u32 = 0x0000_0080;
    const GENERIC_READ: u32 = 0x8000_0000;
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const DELETE_ACCESS: u32 = 0x0001_0000;
    const FILE_RENAME_INFO_CLASS: u32 = 3;
    const FILE_DISPOSITION_INFO_CLASS: u32 = 4;

    #[link(name = "Kernel32")]
    extern "system" {
        fn SetFileInformationByHandle(
            file: *mut std::ffi::c_void,
            information_class: u32,
            information: *mut std::ffi::c_void,
            buffer_size: u32,
        ) -> i32;
    }

    #[repr(C)]
    struct FileRenameInfoHeader {
        replace_if_exists: u8,
        root_directory: *mut std::ffi::c_void,
        file_name_length: u32,
        file_name: [u16; 1],
    }

    #[repr(C)]
    struct FileDispositionInfo {
        delete_file: u8,
    }

    fn metadata_is_safe_directory(metadata: &std::fs::Metadata) -> bool {
        metadata.is_dir() && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
    }

    fn metadata_is_safe_file(metadata: &std::fs::Metadata) -> bool {
        metadata.is_file() && metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT == 0
    }

    fn open_directory_path_nofollow_with_access(
        path: &Path,
        access: u32,
    ) -> std::io::Result<std::fs::File> {
        let file = std::fs::OpenOptions::new()
            .access_mode(access)
            // In particular, omit FILE_SHARE_DELETE. Windows will refuse a
            // rename/delete of this exact ancestor while the job holds it.
            // Project-root handles may also carry GENERIC_WRITE so the
            // anchored manifest can be synced. Every concurrent directory
            // reopen must acknowledge that access while still omitting
            // FILE_SHARE_DELETE, which is the replacement/rename guard.
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
            .open(path)?;
        let metadata = file.metadata()?;
        if metadata_is_safe_directory(&metadata) {
            Ok(file)
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "destination component is not a normal directory or is a reparse point",
            ))
        }
    }

    fn open_directory_path_nofollow(path: &Path) -> std::io::Result<std::fs::File> {
        open_directory_path_nofollow_with_access(
            path,
            FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | GENERIC_WRITE,
        )
    }

    pub(super) fn create_held_directory(
        parent: &std::fs::File,
        name: &std::ffi::OsStr,
    ) -> std::io::Result<std::fs::File> {
        // The Windows helper performs one handle-relative FILE_CREATE via
        // NtCreateFile, so it has no post-create pathname cleanup window.
        crate::exiftool::metadata_publish_sys::create_directory(parent, name)
    }

    pub(super) fn delete_exact_regular_file(
        file: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        let mut disposition = FileDispositionInfo { delete_file: 1 };
        let result = unsafe {
            SetFileInformationByHandle(
                file.as_raw_handle().cast(),
                FILE_DISPOSITION_INFO_CLASS,
                (&mut disposition as *mut FileDispositionInfo).cast(),
                std::mem::size_of::<FileDispositionInfo>() as u32,
            )
        };
        if result == 0 {
            Err(output_authority_error(format!(
                "delete exact held evidence file: {}",
                std::io::Error::last_os_error()
            )))
        } else {
            Ok(())
        }
    }

    pub(super) fn remove_exact_empty_directory(
        held_parent: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
        directory: std::fs::File,
        role: &str,
    ) -> Result<(), domain::EngineError> {
        verify_namespace(held_parent)?;
        let expected_identity = directory_identity(&directory).map_err(|error| {
            output_authority_error(format!(
                "inspect held {role} before exact deletion: {error}"
            ))
        })?;
        let entries = crate::exiftool::metadata_publish_sys::read_directory_names(&directory)
            .map_err(|error| {
                output_authority_error(format!(
                    "inspect held {role} before exact deletion: {error}"
                ))
            })?;
        if !entries.is_empty() {
            return Err(output_authority_error(format!(
                "HOLD: held {role} is no longer empty; preserving it"
            )));
        }

        // The original directory handle intentionally omitted delete sharing,
        // so release it before obtaining DELETE access. A replacement which
        // wins that narrow open window is detected by the identity comparison
        // and is never deleted; once this second handle is open its own share
        // mask prevents a later replacement.
        drop(directory);
        let path = held_parent.display_path.join(name);
        let deletable = open_directory_path_nofollow_with_access(
            &path,
            FILE_LIST_DIRECTORY
                | FILE_TRAVERSE
                | FILE_READ_ATTRIBUTES
                | GENERIC_WRITE
                | DELETE_ACCESS,
        )
        .map_err(|error| {
            output_authority_error(format!(
                "HOLD: reopen held {role} with exact-delete access at {}: {error}",
                path.display()
            ))
        })?;
        if directory_identity(&deletable).map_err(|error| {
            output_authority_error(format!("inspect deletable {role} identity: {error}"))
        })? != expected_identity
        {
            return Err(output_authority_error(format!(
                "HOLD: {role} identity changed before exact deletion at {}; preserving the replacement",
                path.display()
            )));
        }
        if !crate::exiftool::metadata_publish_sys::read_directory_names(&deletable)
            .map_err(|error| {
                output_authority_error(format!("reinspect deletable {role}: {error}"))
            })?
            .is_empty()
        {
            return Err(output_authority_error(format!(
                "HOLD: {role} gained content before exact deletion at {}; preserving it",
                path.display()
            )));
        }
        let mut disposition = FileDispositionInfo { delete_file: 1 };
        let result = unsafe {
            SetFileInformationByHandle(
                deletable.as_raw_handle().cast(),
                FILE_DISPOSITION_INFO_CLASS,
                (&mut disposition as *mut FileDispositionInfo).cast(),
                std::mem::size_of::<FileDispositionInfo>() as u32,
            )
        };
        if result == 0 {
            return Err(output_authority_error(format!(
                "HOLD: exact-delete held {role} at {}: {}",
                path.display(),
                std::io::Error::last_os_error()
            )));
        }
        drop(deletable);
        match std::fs::symlink_metadata(&path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(output_authority_error(format!(
                "HOLD: verify exact {role} deletion at {}: {error}",
                path.display()
            ))),
            Ok(_) => Err(output_authority_error(format!(
                "HOLD: a replacement appeared at retired {role} {}; preserving it",
                path.display()
            ))),
        }
    }

    pub(super) fn delete_ephemeral_probe_leaf(
        _parent: &std::fs::File,
        _name: &std::ffi::OsStr,
        expected: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        delete_exact_regular_file(expected)
    }

    pub(super) fn remove_ephemeral_probe_directory(
        held_parent: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
        directory: std::fs::File,
    ) -> Result<(), domain::EngineError> {
        remove_exact_empty_directory(held_parent, name, directory, "output-name alias probe")
    }

    fn directory_identity(file: &std::fs::File) -> std::io::Result<(u64, u64)> {
        let metadata = file.metadata()?;
        if !metadata_is_safe_directory(&metadata) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "directory authority became a reparse point or non-directory",
            ));
        }
        let (volume, index, _) = windows_file_identity(file)?;
        Ok((volume, index))
    }

    pub(super) fn open_or_create_directory_chain(
        root: &std::fs::File,
        root_path: &Path,
        components: &[std::ffi::OsString],
        role: &str,
    ) -> Result<(std::fs::File, Vec<std::fs::File>), domain::EngineError> {
        let mut current_path = root_path.to_path_buf();
        let mut guards = Vec::with_capacity(components.len());
        // Prove the caller's held root still names root_path before walking.
        let reopened_root = open_directory_path_nofollow(root_path).map_err(|error| {
            output_authority_error(format!("securely reopen output root for {role}: {error}"))
        })?;
        if directory_identity(root).map_err(|error| {
            output_authority_error(format!("inspect held output root for {role}: {error}"))
        })? != directory_identity(&reopened_root).map_err(|error| {
            output_authority_error(format!("inspect reopened output root for {role}: {error}"))
        })? {
            return Err(output_authority_error(format!(
                "output root changed while acquiring {role} destination authority"
            )));
        }
        ensure_identity_safe_filesystem(&reopened_root, role)?;
        for component in components {
            current_path.push(component);
            match open_directory_path_nofollow(&current_path) {
                Ok(directory) => guards.push(directory),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    match std::fs::create_dir(&current_path) {
                        Ok(()) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(error) => {
                            return Err(output_authority_error(format!(
                                "securely create {role} destination component {}: {error}",
                                current_path.display()
                            )))
                        }
                    }
                    let directory = open_directory_path_nofollow(&current_path).map_err(|error| {
                        output_authority_error(format!(
                            "securely open new {role} destination component {} without traversing a reparse point: {error}",
                            current_path.display()
                        ))
                    })?;
                    guards.push(directory);
                }
                Err(error) => {
                    return Err(output_authority_error(format!(
                        "securely open {role} destination component {} without traversing a reparse point: {error}",
                        current_path.display()
                    )))
                }
            }
            let current = guards.last().expect("component open pushes one guard");
            ensure_identity_safe_filesystem(current, role)?;
        }
        let directory = guards
            .last()
            .unwrap_or(&reopened_root)
            .try_clone()
            .map_err(|error| {
                output_authority_error(format!("retain {role} destination handle: {error}"))
            })?;
        Ok((directory, guards))
    }

    pub(super) fn verify_namespace(
        held: &HeldDestinationDirectoryInner,
    ) -> Result<(), domain::EngineError> {
        let reopened_root = open_directory_path_nofollow(&held.root_path).map_err(|error| {
            output_authority_error(format!(
                "project-root authority changed before output publication at {}: {error}",
                held.root_path.display()
            ))
        })?;
        if directory_identity(&held.root).map_err(|error| {
            output_authority_error(format!("inspect held project root: {error}"))
        })? != directory_identity(&reopened_root).map_err(|error| {
            output_authority_error(format!("inspect reopened project root: {error}"))
        })? {
            return Err(output_authority_error(
                "project-root identity changed before output publication",
            ));
        }
        let reopened = open_directory_path_nofollow(&held.display_path).map_err(|error| {
            output_authority_error(format!(
                "output destination authority changed before publication at {}: {error}",
                held.display_path.display()
            ))
        })?;
        if directory_identity(&held.directory).map_err(|error| {
            output_authority_error(format!("inspect held output destination: {error}"))
        })? != directory_identity(&reopened).map_err(|error| {
            output_authority_error(format!("inspect reopened output destination: {error}"))
        })? {
            return Err(output_authority_error(format!(
                "output destination authority changed before publication at {}; refusing redirected write",
                held.display_path.display()
            )));
        }
        // Re-inspect every pinned component. File-share restrictions prevent
        // replacement; the metadata check also catches any unsupported
        // filesystem which reports a reparse transition in place.
        for guard in &held.component_guards {
            let metadata = guard.metadata().map_err(|error| {
                output_authority_error(format!("inspect pinned destination component: {error}"))
            })?;
            if !metadata_is_safe_directory(&metadata) {
                return Err(output_authority_error(
                    "a pinned destination component became a reparse point",
                ));
            }
        }
        Ok(())
    }

    pub(super) fn reserve_private_sibling(
        held: &HeldDestinationDirectoryInner,
        final_name: &std::ffi::OsStr,
        purpose: &str,
    ) -> Result<(std::ffi::OsString, std::fs::File), domain::EngineError> {
        verify_namespace(held)?;
        let final_display = final_name.to_string_lossy();
        for _ in 0..128 {
            let token = super::publication_token()?;
            let candidate = std::ffi::OsString::from(format!(
                ".{final_display}.scanstudio-{purpose}-{token}.tmp"
            ));
            let path = held.display_path.join(&candidate);
            match std::fs::OpenOptions::new()
                .access_mode(GENERIC_READ | GENERIC_WRITE | DELETE_ACCESS)
                .share_mode(FILE_SHARE_READ)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH)
                .create_new(true)
                .open(&path)
            {
                Ok(file) => {
                    let metadata = file.metadata().map_err(|error| {
                        output_authority_error(format!("inspect private output sibling: {error}"))
                    })?;
                    if !metadata_is_safe_file(&metadata) {
                        return Err(output_authority_error(
                            "private output sibling is a reparse point or non-file",
                        ));
                    }
                    return Ok((candidate, file));
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => {
                    return Err(output_authority_error(format!(
                        "reserve private {purpose} sibling in {}: {error}",
                        held.display_path.display()
                    )))
                }
            }
        }
        Err(output_authority_error(format!(
            "could not reserve a unique private {purpose} sibling in {}",
            held.display_path.display()
        )))
    }

    pub(super) fn unlink_leaf(
        _held: &HeldDestinationDirectoryInner,
        _name: &std::ffi::OsStr,
        file: &std::fs::File,
    ) -> std::io::Result<()> {
        let mut disposition = FileDispositionInfo { delete_file: 1 };
        let result = unsafe {
            SetFileInformationByHandle(
                file.as_raw_handle().cast(),
                FILE_DISPOSITION_INFO_CLASS,
                (&mut disposition as *mut FileDispositionInfo).cast(),
                std::mem::size_of::<FileDispositionInfo>() as u32,
            )
        };
        if result == 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    pub(super) fn leaf_entry_exists(
        held: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
    ) -> Result<bool, domain::EngineError> {
        verify_namespace(held)?;
        match std::fs::symlink_metadata(held.display_path.join(name)) {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(output_authority_error(format!(
                "inspect authorized Windows output leaf without following reparse points: {error}"
            ))),
        }
    }

    pub(super) fn publish(
        held: &HeldDestinationDirectoryInner,
        _temporary: &std::ffi::OsStr,
        final_name: &std::ffi::OsStr,
        temporary_file: &std::fs::File,
        create_only: bool,
        role: &str,
    ) -> Result<(), domain::EngineError> {
        verify_namespace(held)?;
        let wide: Vec<u16> = final_name.encode_wide().collect();
        let file_name_offset = std::mem::offset_of!(FileRenameInfoHeader, file_name);
        let byte_length = wide
            .len()
            .checked_mul(std::mem::size_of::<u16>())
            .ok_or_else(|| output_authority_error("final output leaf is too long"))?;
        let total = file_name_offset
            .checked_add(byte_length)
            .ok_or_else(|| output_authority_error("final output rename buffer is too large"))?;
        // `Vec<u8>` only guarantees byte alignment; casting its pointer to
        // FILE_RENAME_INFO would be undefined behaviour on Windows. Back the
        // variable-sized record with pointer-aligned words while still
        // passing the exact byte length required by the API.
        let word = std::mem::size_of::<usize>();
        let word_count = total
            .checked_add(word - 1)
            .ok_or_else(|| output_authority_error("final output rename buffer is too large"))?
            / word;
        let mut buffer = vec![0_usize; word_count];
        let buffer_bytes = buffer.as_mut_ptr().cast::<u8>();
        let header = buffer_bytes.cast::<FileRenameInfoHeader>();
        unsafe {
            std::ptr::write(
                header,
                FileRenameInfoHeader {
                    replace_if_exists: (!create_only) as u8,
                    root_directory: held.directory.as_raw_handle().cast(),
                    file_name_length: byte_length as u32,
                    file_name: [0],
                },
            );
            std::ptr::copy_nonoverlapping(
                wide.as_ptr().cast::<u8>(),
                buffer_bytes.add(file_name_offset),
                byte_length,
            );
        }
        let result = unsafe {
            SetFileInformationByHandle(
                temporary_file.as_raw_handle().cast(),
                FILE_RENAME_INFO_CLASS,
                buffer_bytes.cast(),
                total as u32,
            )
        };
        if result == 0 {
            let error = std::io::Error::last_os_error();
            let code = if create_only && error.kind() == std::io::ErrorKind::AlreadyExists {
                protocol::ErrorCode::ArchiveCollision
            } else {
                protocol::ErrorCode::Internal
            };
            return Err(domain::EngineError::new(
                code,
                format!(
                    "failed to publish {role} at {}: {error}",
                    held.display_path.join(final_name).display()
                ),
            )
            .with_recoverable(true));
        }
        temporary_file.sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("sync published {role}: {error}"),
            )
        })?;
        Ok(())
    }

    pub(super) fn verify_leaf_identity(
        held: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
        file: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        verify_namespace(held)?;
        let reopened = std::fs::OpenOptions::new()
            .access_mode(GENERIC_READ | FILE_READ_ATTRIBUTES)
            // The original publication handle owns WRITE+DELETE access and
            // itself omitted delete sharing. This verifier requests only
            // read access, but its share mask must acknowledge all access
            // already held by that original handle.
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(held.display_path.join(name))
            .map_err(|error| {
                output_authority_error(format!(
                    "reopen published output without following reparse point: {error}"
                ))
            })?;
        let expected = file.metadata().map_err(|error| {
            output_authority_error(format!("inspect held published output: {error}"))
        })?;
        let actual = reopened.metadata().map_err(|error| {
            output_authority_error(format!("inspect reopened published output: {error}"))
        })?;
        let expected_identity = windows_file_identity(file).map_err(|error| {
            output_authority_error(format!("query held published output identity: {error}"))
        })?;
        let actual_identity = windows_file_identity(&reopened).map_err(|error| {
            output_authority_error(format!("query reopened published output identity: {error}"))
        })?;
        if !metadata_is_safe_file(&expected)
            || !metadata_is_safe_file(&actual)
            || expected_identity.2 != 1
            || expected_identity != actual_identity
        {
            return Err(output_authority_error(
                "published output identity is not the unique non-reparse file held by the engine",
            ));
        }
        Ok(())
    }

    pub(super) fn remove_published_leaf(
        held: &HeldDestinationDirectoryInner,
        name: &std::ffi::OsStr,
        file: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        verify_leaf_identity(held, name, file)?;
        let mut disposition = FileDispositionInfo { delete_file: 1 };
        let result = unsafe {
            SetFileInformationByHandle(
                file.as_raw_handle().cast(),
                FILE_DISPOSITION_INFO_CLASS,
                (&mut disposition as *mut FileDispositionInfo).cast(),
                std::mem::size_of::<FileDispositionInfo>() as u32,
            )
        };
        if result == 0 {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "rollback authorized publication {}: {}",
                    held.display_path.join(name).display(),
                    std::io::Error::last_os_error()
                ),
            ));
        }
        Ok(())
    }

    pub(super) fn open_root(path: &Path) -> Result<std::fs::File, domain::EngineError> {
        open_directory_path_nofollow(path).map_err(|error| {
            output_authority_error(format!(
                "securely open canonical output root {}: {error}",
                path.display()
            ))
        })
    }

    pub(super) fn open_project_root(path: &Path) -> Result<std::fs::File, domain::EngineError> {
        open_directory_path_nofollow_with_access(
            path,
            FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | GENERIC_WRITE,
        )
        .map_err(|error| {
            output_authority_error(format!(
                "securely open writable canonical project root {}: {error}",
                path.display()
            ))
        })
    }

    pub(super) fn verify_root(
        path: &Path,
        held: &std::fs::File,
    ) -> Result<(), domain::EngineError> {
        let reopened = open_directory_path_nofollow(path).map_err(|error| {
            output_authority_error(format!(
                "project-root authority changed at {}: {error}",
                path.display()
            ))
        })?;
        if directory_identity(held).map_err(|error| {
            output_authority_error(format!("inspect held project root: {error}"))
        })? == directory_identity(&reopened).map_err(|error| {
            output_authority_error(format!("inspect reopened project root: {error}"))
        })? {
            Ok(())
        } else {
            Err(output_authority_error(format!(
                "project-root authority changed at {}",
                path.display()
            )))
        }
    }
}

fn publication_token() -> Result<String, domain::EngineError> {
    let mut random = [0_u8; 16];
    getrandom::fill(&mut random).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("generate private output publication token: {error}"),
        )
    })?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(unix)]
fn acquire_destination_directory(
    root_path: &Path,
    root: &std::fs::File,
    destination: &Path,
    role: &str,
) -> Result<HeldDestinationDirectory, domain::EngineError> {
    let relative = destination.strip_prefix(root_path).map_err(|_| {
        output_authority_error(format!(
            "{role} destination is outside the held output root: {}",
            destination.display()
        ))
    })?;
    let mut relative_components = Vec::new();
    for component in relative.components() {
        let std::path::Component::Normal(component) = component else {
            return Err(output_authority_error(format!(
                "{role} destination contains an unsafe path component"
            )));
        };
        relative_components.push(component.to_os_string());
    }
    let directory =
        destination_sys::open_or_create_directory_chain(root, &relative_components, role)?;
    Ok(HeldDestinationDirectory {
        inner: Arc::new(HeldDestinationDirectoryInner {
            root: root.try_clone().map_err(|error| {
                output_authority_error(format!("retain canonical output root: {error}"))
            })?,
            root_path: root_path.to_path_buf(),
            relative_components,
            directory,
            display_path: destination.to_path_buf(),
        }),
    })
}

#[cfg(windows)]
fn acquire_destination_directory(
    root_path: &Path,
    root: &std::fs::File,
    destination: &Path,
    role: &str,
) -> Result<HeldDestinationDirectory, domain::EngineError> {
    let relative = destination.strip_prefix(root_path).map_err(|_| {
        output_authority_error(format!(
            "{role} destination is outside the held output root: {}",
            destination.display()
        ))
    })?;
    let mut relative_components = Vec::new();
    for component in relative.components() {
        let std::path::Component::Normal(component) = component else {
            return Err(output_authority_error(format!(
                "{role} destination contains an unsafe path component"
            )));
        };
        relative_components.push(component.to_os_string());
    }
    let (directory, component_guards) = destination_sys::open_or_create_directory_chain(
        root,
        root_path,
        &relative_components,
        role,
    )?;
    Ok(HeldDestinationDirectory {
        inner: Arc::new(HeldDestinationDirectoryInner {
            root: root.try_clone().map_err(|error| {
                output_authority_error(format!("retain canonical output root: {error}"))
            })?,
            root_path: root_path.to_path_buf(),
            component_guards,
            directory,
            display_path: destination.to_path_buf(),
        }),
    })
}

#[cfg(not(any(unix, windows)))]
fn acquire_destination_directory(
    _root_path: &Path,
    _root: &std::fs::File,
    destination: &Path,
    role: &str,
) -> Result<HeldDestinationDirectory, domain::EngineError> {
    Err(output_authority_error(format!(
        "{role} destination {} is refused: this platform build has no reparse-safe handle-relative publication primitive",
        destination.display()
    )))
}

#[cfg(any(unix, windows))]
fn acquire_held_child_directory(
    parent: &HeldDestinationDirectory,
    name: &std::ffi::OsStr,
    role: &str,
) -> Result<HeldDestinationDirectory, domain::EngineError> {
    acquire_held_child_directory_with_hook(parent, name, role, || Ok(()))
}

#[cfg(unix)]
fn acquire_held_child_directory_with_hook(
    parent: &HeldDestinationDirectory,
    name: &std::ffi::OsStr,
    role: &str,
    before_relative_acquire: impl FnOnce() -> Result<(), domain::EngineError>,
) -> Result<HeldDestinationDirectory, domain::EngineError> {
    validate_single_output_leaf_name(name, role)?;
    destination_sys::verify_namespace(&parent.inner)?;
    before_relative_acquire()?;
    let (directory, created) = match crate::exiftool::metadata_publish_sys::open_child_directory(
        &parent.inner.directory,
        name,
    ) {
        Ok(directory) => (directory, false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match destination_sys::create_held_directory(&parent.inner.directory, name) {
                Ok(directory) => (directory, true),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (
                    crate::exiftool::metadata_publish_sys::open_child_directory(
                        &parent.inner.directory,
                        name,
                    )
                    .map_err(|error| {
                        output_authority_error(format!(
                            "securely open concurrently-created {role} below the held destination: {error}"
                        ))
                    })?,
                    false,
                ),
                Err(error) => {
                    return Err(output_authority_error(format!(
                        "securely create {role} below the held destination: {error}"
                    )))
                }
            }
        }
        Err(error) => {
            return Err(output_authority_error(format!(
                "securely open {role} below the held destination without following links: {error}"
            )))
        }
    };
    if created {
        crate::exiftool::metadata_publish_sys::sync_directory(&parent.inner.directory).map_err(
            |error| {
                output_authority_error(format!("sync held parent after creating {role}: {error}"))
            },
        )?;
    }
    ensure_identity_safe_filesystem(&directory, role)?;
    let mut relative_components = parent.inner.relative_components.clone();
    relative_components.push(name.to_os_string());
    let child = HeldDestinationDirectory {
        inner: Arc::new(HeldDestinationDirectoryInner {
            root: parent.inner.root.try_clone().map_err(|error| {
                output_authority_error(format!("retain output root for {role}: {error}"))
            })?,
            root_path: parent.inner.root_path.clone(),
            relative_components,
            directory,
            display_path: parent.inner.display_path.join(name),
        }),
    };
    destination_sys::verify_namespace(&parent.inner)?;
    destination_sys::verify_namespace(&child.inner)?;
    Ok(child)
}

#[cfg(windows)]
fn acquire_held_child_directory_with_hook(
    parent: &HeldDestinationDirectory,
    name: &std::ffi::OsStr,
    role: &str,
    before_relative_acquire: impl FnOnce() -> Result<(), domain::EngineError>,
) -> Result<HeldDestinationDirectory, domain::EngineError> {
    validate_single_output_leaf_name(name, role)?;
    destination_sys::verify_namespace(&parent.inner)?;
    before_relative_acquire()?;
    let (directory, created) = match crate::exiftool::metadata_publish_sys::open_child_directory(
        &parent.inner.directory,
        name,
    ) {
        Ok(directory) => (directory, false),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match destination_sys::create_held_directory(&parent.inner.directory, name) {
                Ok(directory) => (directory, true),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (
                    crate::exiftool::metadata_publish_sys::open_child_directory(
                        &parent.inner.directory,
                        name,
                    )
                    .map_err(|error| {
                        output_authority_error(format!(
                            "securely open concurrently-created {role} below the held destination: {error}"
                        ))
                    })?,
                    false,
                ),
                Err(error) => {
                    return Err(output_authority_error(format!(
                        "securely create {role} below the held destination: {error}"
                    )))
                }
            }
        }
        Err(error) => {
            return Err(output_authority_error(format!(
                "securely open {role} below the held destination without following links: {error}"
            )))
        }
    };
    if created {
        crate::exiftool::metadata_publish_sys::sync_directory(&parent.inner.directory).map_err(
            |error| {
                output_authority_error(format!("sync held parent after creating {role}: {error}"))
            },
        )?;
    }
    ensure_identity_safe_filesystem(&directory, role)?;
    let mut component_guards = parent
        .inner
        .component_guards
        .iter()
        .map(|guard| {
            guard.try_clone().map_err(|error| {
                output_authority_error(format!(
                    "retain pinned output ancestor while acquiring {role}: {error}"
                ))
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    component_guards.push(directory.try_clone().map_err(|error| {
        output_authority_error(format!("retain pinned {role} directory: {error}"))
    })?);
    let child = HeldDestinationDirectory {
        inner: Arc::new(HeldDestinationDirectoryInner {
            root: parent.inner.root.try_clone().map_err(|error| {
                output_authority_error(format!("retain output root for {role}: {error}"))
            })?,
            root_path: parent.inner.root_path.clone(),
            component_guards,
            directory,
            display_path: parent.inner.display_path.join(name),
        }),
    };
    destination_sys::verify_namespace(&parent.inner)?;
    destination_sys::verify_namespace(&child.inner)?;
    Ok(child)
}

#[cfg(not(any(unix, windows)))]
fn acquire_held_child_directory(
    _parent: &HeldDestinationDirectory,
    _name: &std::ffi::OsStr,
    role: &str,
) -> Result<HeldDestinationDirectory, domain::EngineError> {
    Err(output_authority_error(format!(
        "{role} is refused: this platform has no held child-directory authority",
    )))
}

fn absolute_lexical(path: &Path) -> Result<PathBuf, domain::EngineError> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|error| output_authority_error(format!("resolve output path: {error}")))?
            .join(path)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    Ok(normalized)
}

#[cfg(windows)]
fn validate_windows_local_output_path(path: &Path, role: &str) -> Result<(), domain::EngineError> {
    use std::os::windows::ffi::OsStrExt as _;
    use std::path::Prefix;

    #[link(name = "Kernel32")]
    extern "system" {
        fn GetDriveTypeW(root_path_name: *const u16) -> u32;
    }

    const DRIVE_UNKNOWN: u32 = 0;
    const DRIVE_NO_ROOT_DIR: u32 = 1;
    const DRIVE_REMOTE: u32 = 4;

    let mut volume_root = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::Prefix(prefix) => {
                if matches!(prefix.kind(), Prefix::UNC(..) | Prefix::VerbatimUNC(..)) {
                    return Err(output_authority_error(format!(
                        "{role} output on UNC/SMB storage is refused before capture: Windows handle-relative atomic rename does not support a nonzero RootDirectory for network filesystems"
                    )));
                }
                volume_root.push(component.as_os_str());
            }
            std::path::Component::RootDir => volume_root.push(component.as_os_str()),
            _ => break,
        }
    }
    if volume_root.as_os_str().is_empty() {
        return Err(output_authority_error(format!(
            "{role} output has no absolute Windows volume root: {}",
            path.display()
        )));
    }
    let mut wide: Vec<u16> = volume_root.as_os_str().encode_wide().collect();
    wide.push(0);
    let drive_type = unsafe { GetDriveTypeW(wide.as_ptr()) };
    if matches!(drive_type, DRIVE_UNKNOWN | DRIVE_NO_ROOT_DIR | DRIVE_REMOTE) {
        return Err(output_authority_error(format!(
            "{role} output volume {} cannot prove local handle-relative publication support; refusing before capture",
            volume_root.display()
        )));
    }
    Ok(())
}

fn ensure_identity_safe_filesystem(
    directory: &std::fs::File,
    role: &str,
) -> Result<(), domain::EngineError> {
    crate::exiftool::ensure_supported_metadata_filesystem(directory).map_err(|error| {
        output_authority_error(format!(
            "{role} filesystem cannot provide identity-safe publication: {error}; refusing before capture"
        ))
    })
}

#[cfg(any(unix, windows))]
fn held_output_root(
    project_root: Option<&Path>,
) -> Result<(PathBuf, std::fs::File), domain::EngineError> {
    let is_project_root = project_root.is_some();
    let root_path = match project_root {
        Some(root) => std::fs::canonicalize(root).map_err(|error| {
            output_authority_error(format!(
                "cannot canonicalize active project root {}: {error}",
                root.display()
            ))
        })?,
        None => {
            #[cfg(unix)]
            {
                PathBuf::from("/")
            }
            #[cfg(windows)]
            {
                return Err(output_authority_error(
                    "a project root is required for reparse-safe Windows output publication",
                ));
            }
        }
    };
    let root = if is_project_root {
        destination_sys::open_project_root(&root_path)?
    } else {
        destination_sys::open_root(&root_path)?
    };
    Ok((root_path, root))
}

#[cfg(not(any(unix, windows)))]
fn held_output_root(
    _project_root: Option<&Path>,
) -> Result<(PathBuf, std::fs::File), domain::EngineError> {
    Err(output_authority_error(
        "output publication is refused: this platform build has no reparse-safe handle-relative directory authority",
    ))
}

/// Captures the active project directory before server-side filesystem
/// validation begins. `None` is a supported no-project mode; every output in
/// that mode obtains an independent filesystem/volume-root authority later.
pub(crate) fn acquire_project_output_root_authority(
    project_root: Option<&Path>,
) -> Result<Option<ProjectOutputRootAuthority>, domain::EngineError> {
    let Some(project_root) = project_root else {
        return Ok(None);
    };
    let requested_path = absolute_lexical(project_root)?;
    #[cfg(windows)]
    validate_windows_local_output_path(&requested_path, "project root")?;
    let (canonical_path, root) = held_output_root(Some(&requested_path))?;
    ensure_identity_safe_filesystem(&root, "project root")?;
    Ok(Some(ProjectOutputRootAuthority {
        requested_path,
        canonical_path,
        root: Arc::new(root),
    }))
}

fn authorize_leaf(
    root_path: &Path,
    root: &std::fs::File,
    final_path: PathBuf,
    role: &'static str,
    create_only: bool,
) -> Result<AuthorizedOutputLeaf, domain::EngineError> {
    let final_path = absolute_lexical(&final_path)?;
    #[cfg(windows)]
    validate_windows_local_output_path(&final_path, role)?;
    let destination = final_path.parent().ok_or_else(|| {
        output_authority_error(format!("{role} output has no destination directory"))
    })?;
    let final_name = final_path
        .file_name()
        .ok_or_else(|| output_authority_error(format!("{role} output has no final leaf name")))?;
    validate_single_output_leaf_name(final_name, role)?;
    let held = acquire_destination_directory(root_path, root, destination, role)?;
    Ok(AuthorizedOutputLeaf {
        destination: held,
        final_name: final_name.to_os_string(),
        final_path,
        create_only,
        role,
    })
}

fn canonical_authorized_final_path(
    project_root: Option<&Path>,
    canonical_root: &Path,
    requested: PathBuf,
    role: &str,
) -> Result<PathBuf, domain::EngineError> {
    let requested = absolute_lexical(&requested)?;
    let Some(project_root) = project_root else {
        let final_name = requested.file_name().ok_or_else(|| {
            output_authority_error(format!("{role} output has no final leaf name"))
        })?;
        let mut ancestor = requested
            .parent()
            .ok_or_else(|| {
                output_authority_error(format!("{role} output has no destination directory"))
            })?
            .to_path_buf();
        let mut missing = Vec::<std::ffi::OsString>::new();
        let canonical_ancestor = loop {
            match std::fs::canonicalize(&ancestor) {
                Ok(value) => break value,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    let component = ancestor.file_name().ok_or_else(|| {
                        output_authority_error(format!(
                            "cannot resolve an existing ancestor for {role} destination {}",
                            requested.display()
                        ))
                    })?;
                    missing.push(component.to_os_string());
                    if !ancestor.pop() {
                        return Err(output_authority_error(format!(
                            "cannot resolve an existing ancestor for {role} destination {}",
                            requested.display()
                        )));
                    }
                }
                Err(error) => {
                    return Err(output_authority_error(format!(
                        "canonicalize {role} destination ancestor {}: {error}",
                        ancestor.display()
                    )))
                }
            }
        };
        let mut physical = canonical_ancestor;
        for component in missing.iter().rev() {
            physical.push(component);
        }
        physical.push(final_name);
        return Ok(physical);
    };
    let project_root = absolute_lexical(project_root)?;
    let relative = requested
        .strip_prefix(&project_root)
        .or_else(|_| requested.strip_prefix(canonical_root))
        .map_err(|_| {
            output_authority_error(format!(
                "{role} output is outside the canonical active project root: {}",
                requested.display()
            ))
        })?;
    if relative
        .components()
        .any(|component| !matches!(component, std::path::Component::Normal(_)))
    {
        return Err(output_authority_error(format!(
            "{role} output contains an unsafe component beneath the project root"
        )));
    }
    Ok(canonical_root.join(relative))
}

/// Rewrites a destination expressed through an alias of the exact held
/// project root (for example macOS `/var` versus `/private/var`) onto that
/// root's physical namespace. Only an ancestor whose opened identity equals
/// the already-approved root is accepted. Components below that ancestor are
/// appended lexically and remain visible to the later no-follow component
/// walk, so a symlink/junction inside the project is not laundered by this
/// compatibility normalization.
fn normalize_project_destination_alias(
    project_root: &ProjectOutputRootAuthority,
    requested: &Path,
) -> Result<Option<PathBuf>, domain::EngineError> {
    if !requested.is_absolute() {
        return Ok(None);
    }
    let requested = absolute_lexical(requested)?;
    let mut ancestor = requested.clone();
    let mut suffix = Vec::<std::ffi::OsString>::new();
    loop {
        if let Ok(canonical_ancestor) = std::fs::canonicalize(&ancestor) {
            if destination_sys::verify_root(&canonical_ancestor, project_root.directory_handle())
                .is_ok()
            {
                let mut normalized = project_root.canonical_path().to_path_buf();
                for component in suffix.iter().rev() {
                    normalized.push(component);
                }
                return Ok(Some(normalized));
            }
        }
        let Some(component) = ancestor.file_name() else {
            break;
        };
        suffix.push(component.to_os_string());
        if !ancestor.pop() {
            break;
        }
    }
    Ok(None)
}

pub(crate) fn normalize_output_recipe_project_aliases(
    project_root: &ProjectOutputRootAuthority,
    output: &mut domain::OutputRecipe,
) -> Result<(), domain::EngineError> {
    project_root.verify_namespace()?;
    for destination in [
        &mut output.archive.destination,
        &mut output.positive.destination,
        &mut output.preview.destination,
        &mut output.raw_export.destination,
    ] {
        if let Some(normalized) =
            normalize_project_destination_alias(project_root, Path::new(destination))?
        {
            *destination = normalized.display().to_string();
        }
    }
    project_root.verify_namespace()
}

fn source_matches_authorized_final(
    source: &Path,
    output: &AuthorizedOutputLeaf,
) -> Result<bool, domain::EngineError> {
    if absolute_lexical(source)? == output.final_path {
        return Ok(true);
    }
    Ok(std::fs::canonicalize(source)
        .map(|canonical| canonical == output.final_path)
        .unwrap_or(false))
}

#[cfg(any(unix, windows))]
fn independent_filesystem_root(path: &Path) -> Result<PathBuf, domain::EngineError> {
    #[cfg(unix)]
    {
        let _ = path;
        Ok(PathBuf::from("/"))
    }
    #[cfg(windows)]
    {
        let mut root = PathBuf::new();
        for component in path.components() {
            match component {
                std::path::Component::Prefix(_) | std::path::Component::RootDir => {
                    root.push(component.as_os_str());
                }
                _ => break,
            }
        }
        if root.as_os_str().is_empty() {
            Err(output_authority_error(format!(
                "raw output has no absolute Windows volume root: {}",
                path.display()
            )))
        } else {
            Ok(root)
        }
    }
}

#[cfg(not(any(unix, windows)))]
fn independent_filesystem_root(_path: &Path) -> Result<PathBuf, domain::EngineError> {
    Err(output_authority_error(
        "this platform has no supported held filesystem-root authority",
    ))
}

fn authorize_independent_leaf_with_policy(
    requested: PathBuf,
    role: &'static str,
    create_only: bool,
) -> Result<AuthorizedOutputLeaf, domain::EngineError> {
    // Resolve existing linked ancestors once, then open the resulting normal
    // component chain from its held filesystem/volume root. From this point
    // onward the retained handles, not the original pathname, authorize raw
    // publication.
    let canonical = canonical_authorized_final_path(None, Path::new("/"), requested.clone(), role)?;
    let root_path = independent_filesystem_root(&canonical)?;
    let root = destination_sys::open_root(&root_path)?;
    authorize_leaf(&root_path, &root, canonical, role, create_only)
}

fn authorize_independent_leaf(
    requested: PathBuf,
    role: &'static str,
) -> Result<AuthorizedOutputLeaf, domain::EngineError> {
    authorize_independent_leaf_with_policy(requested, role, true)
}

fn authorize_metadata_leaf(
    project_root: Option<&ProjectOutputRootAuthority>,
    requested: PathBuf,
    role: &'static str,
    create_only: bool,
) -> Result<AuthorizedOutputLeaf, domain::EngineError> {
    let Some(project_root) = project_root else {
        return authorize_independent_leaf_with_policy(requested, role, create_only);
    };
    project_root.verify_namespace()?;
    let canonical = canonical_authorized_final_path(
        Some(project_root.requested_path()),
        project_root.canonical_path(),
        requested,
        role,
    )?;
    let output = authorize_leaf(
        project_root.canonical_path(),
        project_root.root.as_ref(),
        canonical,
        role,
        create_only,
    )?;
    project_root.verify_namespace()?;
    Ok(output)
}

fn requested_path_is_beneath_project_root(
    project_root: &ProjectOutputRootAuthority,
    requested: &Path,
) -> Result<bool, domain::EngineError> {
    let requested = absolute_lexical(requested)?;
    let relative = requested
        .strip_prefix(project_root.requested_path())
        .or_else(|_| requested.strip_prefix(project_root.canonical_path()));
    Ok(relative
        .map(|relative| {
            relative
                .components()
                .all(|component| matches!(component, std::path::Component::Normal(_)))
        })
        .unwrap_or(false))
}

fn held_directory_identity(
    directory: &HeldDestinationDirectory,
) -> Result<(u64, u64), domain::EngineError> {
    directory_handle_identity(&directory.inner.directory)
}

fn directory_handle_identity(directory: &std::fs::File) -> Result<(u64, u64), domain::EngineError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        let metadata = directory.metadata().map_err(|error| {
            output_authority_error(format!("inspect held output directory identity: {error}"))
        })?;
        if !metadata.is_dir() {
            return Err(output_authority_error(
                "held output directory identity is not a directory",
            ));
        }
        return Ok((metadata.dev(), metadata.ino()));
    }
    #[cfg(windows)]
    {
        let (volume, index, _) = windows_file_identity(directory).map_err(|error| {
            output_authority_error(format!(
                "query held Windows output directory identity: {error}"
            ))
        })?;
        if !directory
            .metadata()
            .map_err(|error| {
                output_authority_error(format!("inspect held Windows output directory: {error}"))
            })?
            .is_dir()
        {
            return Err(output_authority_error(
                "held Windows output directory identity is not a directory",
            ));
        }
        return Ok((volume, index));
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = directory;
        Err(output_authority_error(
            "held output directory identity is unavailable on this platform",
        ))
    }
}

fn regular_file_handle_identity(
    file: &std::fs::File,
) -> Result<(u64, u64, u64), domain::EngineError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        let metadata = file.metadata().map_err(|error| {
            output_authority_error(format!("inspect held evidence file identity: {error}"))
        })?;
        if !metadata.is_file() || metadata.nlink() != 1 {
            return Err(output_authority_error(
                "held evidence file is not one unique regular file",
            ));
        }
        return Ok((metadata.dev(), metadata.ino(), metadata.nlink()));
    }
    #[cfg(windows)]
    {
        let metadata = file.metadata().map_err(|error| {
            output_authority_error(format!("inspect held Windows evidence file: {error}"))
        })?;
        let (volume, index, links) = windows_file_identity(file).map_err(|error| {
            output_authority_error(format!(
                "query held Windows evidence file identity: {error}"
            ))
        })?;
        if !metadata.is_file() || links != 1 {
            return Err(output_authority_error(
                "held Windows evidence file is not one unique regular file",
            ));
        }
        return Ok((volume, index, links));
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = file;
        Err(output_authority_error(
            "evidence file identity verification is unavailable on this platform",
        ))
    }
}

fn physical_output_leaf_key(
    output: &AuthorizedOutputLeaf,
) -> Result<(u64, u64, Vec<u32>), domain::EngineError> {
    let (volume, directory) = held_directory_identity(&output.destination)?;
    #[cfg(unix)]
    let leaf = {
        use std::os::unix::ffi::OsStrExt as _;
        output
            .final_name
            .as_os_str()
            .as_bytes()
            .iter()
            .map(|byte| u32::from(*byte))
            .collect()
    };
    #[cfg(windows)]
    let leaf = output
        .final_name
        .to_string_lossy()
        .to_lowercase()
        .encode_utf16()
        .map(u32::from)
        .collect();
    #[cfg(not(any(unix, windows)))]
    let leaf = Vec::new();
    Ok((volume, directory, leaf))
}

/// Asks the destination filesystem itself whether a set of otherwise-
/// distinct names collide under its real normalization/upcase table. APFS
/// may treat NFC and NFD spellings as one leaf, and NTFS has case aliases
/// that Rust's Unicode lowercase mapping does not model. One random, held,
/// handle-relative directory probes every planned name for this physical
/// destination, then is completely retired before capture.
#[cfg(any(target_os = "macos", windows))]
fn validate_filesystem_output_leaf_collation(
    outputs: &[(u32, &'static str, &AuthorizedOutputLeaf)],
) -> Result<(), domain::EngineError> {
    if outputs.len() < 2 {
        return Ok(());
    }
    let directory = &outputs[0].2.destination;
    destination_sys::verify_namespace(&directory.inner)?;
    let mut reserved_probe = None;
    for _ in 0..128 {
        let candidate = std::ffi::OsString::from(format!(
            ".scanstudio-output-alias-probe-{}",
            publication_token()?
        ));
        match destination_sys::create_held_directory(&directory.inner.directory, &candidate) {
            Ok(probe) => {
                reserved_probe = Some((candidate, probe));
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(output_authority_error(format!(
                    "create held output-name alias probe in {}: {error}",
                    directory.inner.display_path.display()
                )))
            }
        }
    }
    let (probe_name, probe) = reserved_probe.ok_or_else(|| {
        output_authority_error(format!(
            "could not reserve an output-name alias probe in {}",
            directory.inner.display_path.display()
        ))
    })?;

    let mut created = Vec::<(u32, &'static str, std::ffi::OsString, std::fs::File)>::new();
    let outcome = (|| -> Result<(), domain::EngineError> {
        crate::exiftool::metadata_publish_sys::sync_directory(&directory.inner.directory).map_err(
            |error| {
                output_authority_error(format!(
                    "sync output destination after creating alias probe: {error}"
                ))
            },
        )?;
        for (frame_index, role, output) in outputs {
            match crate::exiftool::metadata_publish_sys::create_new_regular(
                &probe,
                &output.final_name,
            ) {
                Ok(file) => created.push((*frame_index, *role, output.final_name.clone(), file)),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    let alias = crate::exiftool::metadata_publish_sys::open_regular(
                        &probe,
                        &output.final_name,
                    )
                    .map_err(|open_error| {
                        output_authority_error(format!(
                            "identify colliding output-name probe {:?}: {open_error}",
                            output.final_name
                        ))
                    })?;
                    let alias_identity = regular_file_handle_identity(&alias)?;
                    let prior = created
                        .iter()
                        .find(|(_, _, _, file)| {
                            regular_file_handle_identity(file).ok() == Some(alias_identity)
                        })
                        .map(|(frame, role, name, _)| (*frame, *role, name.clone()));
                    let prior = prior
                        .map(|(frame, role, name)| format!("frame {frame} {role} ({name:?})"))
                        .unwrap_or_else(|| "another planned output".to_string());
                    return Err(output_authority_error(format!(
                        "physical output collision: frame {frame_index} {role} ({:?}) aliases {prior} under the destination filesystem's filename collation",
                        output.final_name
                    )));
                }
                Err(error) => {
                    return Err(output_authority_error(format!(
                        "probe output leaf name {:?} on the destination filesystem: {error}",
                        output.final_name
                    )))
                }
            }
        }
        Ok(())
    })();

    let cleanup = (|| -> Result<(), domain::EngineError> {
        for (_, _, name, file) in created.iter().rev() {
            destination_sys::delete_ephemeral_probe_leaf(&probe, name, file).map_err(|error| {
                output_authority_error(format!(
                    "HOLD: retire exact held output-name alias probe leaf {name:?}: {}",
                    error.message
                ))
            })?;
        }
        crate::exiftool::metadata_publish_sys::sync_directory(&probe).map_err(|error| {
            output_authority_error(format!("sync emptied output-name alias probe: {error}"))
        })?;
        let remaining = crate::exiftool::metadata_publish_sys::read_directory_names(&probe)
            .map_err(|error| {
                output_authority_error(format!(
                    "HOLD: reinspect output-name alias probe after exact leaf deletion: {error}"
                ))
            })?;
        if !remaining.is_empty() {
            return Err(output_authority_error(format!(
                "HOLD: output-name alias probe was repopulated during cleanup; preserving entries {remaining:?}"
            )));
        }
        Ok(())
    })();
    drop(created);
    let retire_directory = (|| -> Result<(), domain::EngineError> {
        cleanup?;
        destination_sys::remove_ephemeral_probe_directory(&directory.inner, &probe_name, probe)?;
        crate::exiftool::metadata_publish_sys::sync_directory(&directory.inner.directory).map_err(
            |error| {
                output_authority_error(format!(
                    "sync output destination after alias probe retirement: {error}"
                ))
            },
        )?;
        destination_sys::verify_namespace(&directory.inner)
    })();

    match (outcome, retire_directory) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(primary), Ok(())) => Err(primary),
        (Ok(()), Err(cleanup)) => Err(cleanup),
        (Err(mut primary), Err(cleanup)) => {
            primary.message = format!(
                "{}; output-name alias probe cleanup was incomplete: {}",
                primary.message, cleanup.message
            );
            Err(primary.with_recoverable(false))
        }
    }
}

fn validate_physical_output_authority_graph(
    authorities: &JobOutputAuthorities,
) -> Result<(), domain::EngineError> {
    let mut seen =
        std::collections::HashMap::<(u64, u64, Vec<u32>), (u32, &'static str, PathBuf)>::new();
    #[cfg(any(target_os = "macos", windows))]
    let mut filesystem_groups = std::collections::HashMap::<
        (u64, u64),
        Vec<(u32, &'static str, &AuthorizedOutputLeaf)>,
    >::new();
    for (frame_index, frame) in &authorities.frames {
        let outputs = [
            ("archive RGB", frame.archive.as_ref()),
            ("archive IR", frame.archive_ir.as_ref()),
            ("archive meter", frame.archive_meter.as_ref()),
            ("positive", frame.positive.as_ref()),
            ("preview", frame.preview.as_ref()),
            ("raw negative", frame.raw.as_ref()),
            ("raw infrared", frame.raw_ir.as_ref()),
            ("raw commit marker", frame.raw_marker.as_ref()),
        ];
        for (role, output) in outputs {
            let Some(output) = output else {
                continue;
            };
            let key = physical_output_leaf_key(output)?;
            if let Some((other_frame, other_role, other_path)) = seen.get(&key) {
                return Err(output_authority_error(format!(
                    "physical output collision: frame {frame_index} {role} ({}) aliases frame {other_frame} {other_role} ({}) through the same held directory and leaf",
                    output.final_path.display(),
                    other_path.display()
                )));
            }
            #[cfg(any(target_os = "macos", windows))]
            filesystem_groups
                .entry((key.0, key.1))
                .or_default()
                .push((*frame_index, role, output));
            seen.insert(key, (*frame_index, role, output.final_path.clone()));
        }
    }
    #[cfg(any(target_os = "macos", windows))]
    for outputs in filesystem_groups.values() {
        validate_filesystem_output_leaf_collation(outputs)?;
    }
    Ok(())
}

fn validate_authorized_create_only_vacancy(
    authorities: &JobOutputAuthorities,
) -> Result<(), domain::EngineError> {
    for (frame_index, frame) in &authorities.frames {
        for output in [
            frame.archive.as_ref(),
            frame.archive_ir.as_ref(),
            frame.archive_meter.as_ref(),
            frame.positive.as_ref(),
            frame.preview.as_ref(),
            frame.raw.as_ref(),
            frame.raw_ir.as_ref(),
            frame.raw_marker.as_ref(),
        ]
        .into_iter()
        .flatten()
        {
            if output.create_only
                && destination_sys::leaf_entry_exists(
                    &output.destination.inner,
                    &output.final_name,
                )?
            {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::ArchiveCollision,
                    format!(
                        "frame {frame_index} {} target already exists at {}; refusing before capture",
                        output.role,
                        output.final_path.display()
                    ),
                )
                .with_recoverable(true));
            }
        }
    }
    Ok(())
}

/// Opens/creates every metadata-capable destination from one canonical root,
/// no-follow component by no-follow component, and retains the resulting
/// directory handles for the full job. With an active project, every archive,
/// positive, and preview must remain beneath its canonical root. Without one
/// (supported by low-level/test callers), Unix uses the held filesystem root
/// as the capability anchor. Platforms lacking equivalent reparse-safe
/// handle-relative primitives fail closed.
pub(crate) fn acquire_job_output_authorities_with_project_root(
    project_root: Option<&ProjectOutputRootAuthority>,
    frames: &[u32],
    recipe: &domain::CaptureRecipe,
    output: &domain::OutputRecipe,
    overrides: &std::collections::HashMap<u32, domain::FrameOverrides>,
) -> Result<JobOutputAuthorities, domain::EngineError> {
    #[cfg(windows)]
    {
        // The real bridge and source-snapshot pipeline use the OS-private
        // temporary root after scanner dispatch. Prove its legacy file IDs
        // are NTFS-safe now, before any destination directory is created or
        // hardware can move.
        let temporary_root = std::fs::canonicalize(std::env::temp_dir()).map_err(|error| {
            output_authority_error(format!(
                "cannot canonicalize private engine temporary root before capture: {error}"
            ))
        })?;
        validate_windows_local_output_path(&temporary_root, "private engine temporary root")?;
        let temporary_handle = destination_sys::open_root(&temporary_root)?;
        ensure_identity_safe_filesystem(&temporary_handle, "private engine temporary root")?;
    }
    if let Some(project_root) = project_root {
        project_root.verify_namespace()?;
    }
    let mut authorities = JobOutputAuthorities {
        project_root: project_root.cloned(),
        frames: std::collections::HashMap::new(),
        evidence_destinations: Vec::new(),
        reserved_evidence_packages: Vec::new(),
    };
    for frame_index in frames {
        let frame_overrides = overrides.get(frame_index);
        let effective_output = frame_overrides
            .and_then(|value| value.output.as_ref())
            .unwrap_or(output);
        let effective_recipe = frame_overrides
            .and_then(|value| value.capture.as_ref())
            .unwrap_or(recipe);
        let mut frame = FrameOutputAuthorities::default();
        if effective_output.archive.enabled {
            let requested_archive_path =
                resolve_archive_output_path(effective_output, *frame_index);
            let archive = authorize_metadata_leaf(
                project_root,
                requested_archive_path.clone(),
                "archive RGB",
                true,
            )?;
            if effective_recipe.channels == domain::Channels::Rgbi {
                let ir_path = archive_sidecar_path(&archive.final_path, "IR")?;
                let ir = archive.with_sibling_name(
                    ir_path
                        .file_name()
                        .expect("archive IR sidecar has leaf")
                        .to_os_string(),
                    ir_path,
                    "archive IR sidecar",
                )?;
                frame.archive_ir = Some(ir);
            }
            let meter_path = archive_sidecar_path(&archive.final_path, "METER")?;
            let meter = archive.with_sibling_name(
                meter_path
                    .file_name()
                    .expect("archive meter sidecar has leaf")
                    .to_os_string(),
                meter_path,
                "archive meter sidecar",
            )?;
            frame.archive_meter = Some(meter);
            if effective_output.archive.full_capture_package {
                authorities
                    .evidence_destinations
                    .push(EvidenceDestinationAuthority {
                        destination: archive.destination.clone(),
                        eligible_slots: vec![*frame_index],
                    });
            }
            frame.archive = Some(archive);
        }
        if effective_output.positive.enabled {
            let requested_positive_path = resolve_output_path(
                &effective_output.positive.destination,
                &effective_output.positive.filename_template,
                *frame_index,
                effective_output.positive.file_format,
            );
            let positive = authorize_metadata_leaf(
                project_root,
                requested_positive_path,
                "positive",
                is_reserved_sequence_template(&effective_output.positive.filename_template),
            )?;
            frame.positive = Some(positive);
        }
        if effective_output.preview.enabled {
            let requested_preview_path = resolve_output_path(
                &effective_output.preview.destination,
                &effective_output.preview.filename_template,
                *frame_index,
                effective_output.preview.file_format,
            );
            let preview = authorize_metadata_leaf(
                project_root,
                requested_preview_path,
                "preview",
                is_reserved_sequence_template(&effective_output.preview.filename_template),
            )?;
            frame.preview = Some(preview);
        }
        if effective_output.raw_export.enabled {
            let raw_path = resolve_raw_export_output_path(effective_output, *frame_index);
            let raw = match project_root {
                Some(project_root)
                    if requested_path_is_beneath_project_root(project_root, &raw_path)? =>
                {
                    authorize_metadata_leaf(
                        Some(project_root),
                        raw_path.clone(),
                        "raw negative",
                        true,
                    )?
                }
                _ => authorize_independent_leaf(raw_path.clone(), "raw negative")?,
            };
            if effective_recipe.channels == domain::Channels::Rgbi
                && effective_output.raw_export.tiff_infrared == domain::RawTiffInfrared::Sidecar
            {
                let raw_ir_path = raw_export_ir_sidecar_path(&raw.final_path);
                let marker_path = raw_export_pair_commit_marker_path(&raw.final_path)?;
                let raw_ir = raw.with_sibling_name(
                    raw_ir_path
                        .file_name()
                        .expect("raw IR sidecar has leaf")
                        .to_os_string(),
                    raw_ir_path,
                    "raw infrared sidecar",
                )?;
                let marker = raw.with_sibling_name(
                    marker_path
                        .file_name()
                        .expect("raw marker has leaf")
                        .to_os_string(),
                    marker_path,
                    "raw pair commit marker",
                )?;
                frame.raw_ir = Some(raw_ir);
                frame.raw_marker = Some(marker);
            }
            frame.raw = Some(raw);
        }
        authorities.frames.insert(*frame_index, frame);
    }
    validate_physical_output_authority_graph(&authorities)?;
    validate_authorized_create_only_vacancy(&authorities)?;
    if let Some(project_root) = project_root {
        project_root.verify_namespace()?;
    }
    Ok(authorities)
}

/// Convenience path for direct backend/test callers. Server dispatch must use
/// `acquire_project_output_root_authority` before preflight and then call the
/// held-root variant above so it never re-blesses a replacement project path.
pub(crate) fn acquire_job_output_authorities(
    project_root: Option<&Path>,
    frames: &[u32],
    recipe: &domain::CaptureRecipe,
    output: &domain::OutputRecipe,
    overrides: &std::collections::HashMap<u32, domain::FrameOverrides>,
) -> Result<JobOutputAuthorities, domain::EngineError> {
    let project_root = acquire_project_output_root_authority(project_root)?;
    acquire_job_output_authorities_with_project_root(
        project_root.as_ref(),
        frames,
        recipe,
        output,
        overrides,
    )
}

// ---------------------------------------------------------------------
// Output publication provenance
// ---------------------------------------------------------------------

/// Opaque evidence that a final output leaf still names the exact file the
/// engine encoded.  Keeping the already-open file descriptor is load-bearing:
/// receipt capabilities are later minted from this descriptor and may only be
/// attached after a fresh no-follow open of `final_path` resolves to the same
/// filesystem identity.  A pathname observed after rendering is never, by
/// itself, publication authority.
#[derive(Debug)]
pub(crate) struct PublishedFileProof {
    final_path: PathBuf,
    file: std::fs::File,
}

impl PublishedFileProof {
    pub(crate) fn final_path(&self) -> &Path {
        &self.final_path
    }

    pub(crate) fn try_clone_file(&self) -> Result<std::fs::File, domain::EngineError> {
        let mut cloned = self.file.try_clone().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to retain the published-file identity for {}: {error}",
                    self.final_path.display()
                ),
            )
        })?;
        cloned.seek(std::io::SeekFrom::Start(0)).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to rewind the retained published-file identity for {}: {error}",
                    self.final_path.display()
                ),
            )
        })?;
        Ok(cloned)
    }
}

/// The metadata-capable subset of one render's publications.  Raw exports are
/// intentionally absent because ExifTool never receives write authority for
/// them.  Fields are crate-private so only the render/publish paths can create
/// these proofs.
#[derive(Debug, Default)]
pub(crate) struct MetadataPublicationProofs {
    pub(crate) archive: Option<PublishedFileProof>,
    /// Retained with the receipt lifetime so a sidecar publication can never
    /// lose its identity proof before the frame outcome is finalized. These
    /// are not ExifTool targets.
    #[allow(dead_code)]
    pub(crate) archive_ir: Option<PublishedFileProof>,
    #[allow(dead_code)]
    pub(crate) archive_meter: Option<PublishedFileProof>,
    pub(crate) positive: Option<PublishedFileProof>,
    pub(crate) preview: Option<PublishedFileProof>,
}

#[cfg(unix)]
fn publication_identity(
    _file: &std::fs::File,
    metadata: &std::fs::Metadata,
) -> (Option<u64>, Option<u64>, Option<u64>) {
    use std::os::unix::fs::MetadataExt as _;
    (
        Some(metadata.dev()),
        Some(metadata.ino()),
        Some(metadata.nlink()),
    )
}

#[cfg(windows)]
fn publication_identity(
    file: &std::fs::File,
    _metadata: &std::fs::Metadata,
) -> (Option<u64>, Option<u64>, Option<u64>) {
    windows_file_identity(file)
        .map(|(volume, index, links)| (Some(volume), Some(index), Some(links)))
        .unwrap_or((None, None, None))
}

#[cfg(not(any(unix, windows)))]
fn publication_identity(
    _file: &std::fs::File,
    _metadata: &std::fs::Metadata,
) -> (Option<u64>, Option<u64>, Option<u64>) {
    (None, None, None)
}

#[cfg(windows)]
fn publication_is_reparse_point(metadata: &std::fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt as _;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn publication_is_reparse_point(_metadata: &std::fs::Metadata) -> bool {
    false
}

fn open_published_leaf_nofollow(path: &Path) -> Result<std::fs::File, domain::EngineError> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt as _;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    options.open(path).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "cannot verify published output {} with a no-follow open: {error}",
                path.display()
            ),
        )
        .with_recoverable(true)
    })
}

fn verify_published_file_identity(
    path: &Path,
    held_file: &std::fs::File,
) -> Result<(), domain::EngineError> {
    let held = held_file.metadata().map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("cannot inspect the engine-authored output handle: {error}"),
        )
    })?;
    let linked = std::fs::symlink_metadata(path).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "cannot inspect published output {}: {error}",
                path.display()
            ),
        )
        .with_recoverable(true)
    })?;
    let opened = open_published_leaf_nofollow(path)?;
    let opened_metadata = opened.metadata().map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "cannot inspect no-follow output {}: {error}",
                path.display()
            ),
        )
    })?;

    let held_identity = publication_identity(held_file, &held);
    let opened_identity = publication_identity(&opened, &opened_metadata);
    let stable_identity = held_identity.0.is_some()
        && held_identity.1.is_some()
        && held_identity.2 == Some(1)
        && opened_identity == held_identity;
    if !held.is_file()
        || !linked.is_file()
        || !opened_metadata.is_file()
        || linked.file_type().is_symlink()
        || publication_is_reparse_point(&held)
        || publication_is_reparse_point(&linked)
        || publication_is_reparse_point(&opened_metadata)
        || !stable_identity
        || held.len() != linked.len()
        || held.len() != opened_metadata.len()
    {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "published output identity changed or is not uniquely linkable: {}",
                path.display()
            ),
        )
        .with_recoverable(true));
    }
    Ok(())
}

fn published_file_proof(
    final_path: &Path,
    file: std::fs::File,
) -> Result<PublishedFileProof, domain::EngineError> {
    verify_published_file_identity(final_path, &file)?;
    Ok(PublishedFileProof {
        final_path: final_path.to_path_buf(),
        file,
    })
}

/// Opens a bridge-authored archive without following its final leaf and keeps
/// that identity alive for the entire derivative render.  This is deliberately
/// fail-closed on platforms/filesystems that cannot expose a stable unique
/// file identity.
fn open_existing_file_proof(path: &Path) -> Result<PublishedFileProof, domain::EngineError> {
    let file = open_published_leaf_nofollow(path)?;
    published_file_proof(path, file)
}

// ---------------------------------------------------------------------
// Frame geometry
// ---------------------------------------------------------------------

/// Mirrors the Swift `ScanSizeEstimator.uncompressedBytes` dimension math
/// exactly (native 3946x5782 for Mounted, 3946x5959 otherwise, scaled by
/// `resolutionDpi / 4000`) -- do not invent different numbers.
pub fn frame_dimensions(carrier: domain::MediaCarrier, resolution_dpi: u32) -> (u32, u32) {
    let native_width = 3946.0_f64;
    let native_height = if carrier == domain::MediaCarrier::Mounted {
        5782.0_f64
    } else {
        5959.0_f64
    };
    let scale = resolution_dpi as f64 / 4000.0;
    let width = (native_width * scale).round().max(1.0) as u32;
    let height = (native_height * scale).round().max(1.0) as u32;
    (width, height)
}

/// Resolves an absolute vertical crop region from a detected frame boundary
/// and a user-approved relative offset. A retained archive master is never
/// cropped; this region is applied only when producing derived output. Width is
/// always unchanged; only top/bottom rows are shifted by the relative intent
/// and clamped to the image bounds.
///
/// Returns `(top, bottom_inclusive, new_height)`. `bottom_inclusive` is the
/// last row included in the crop (i.e., the range is `[top, bottom_inclusive]`
/// inclusive), so callers can compute `new_height` as
/// `bottom_inclusive - top + 1`.
pub fn resolve_aligned_crop(
    boundary_top: u32,
    boundary_bottom: u32,
    offset_rows: i64,
    image_height: u32,
) -> (u32, u32, u32) {
    let shifted_top = (boundary_top as i64 + offset_rows).clamp(0, image_height as i64 - 1) as u32;
    let shifted_bottom = (boundary_bottom as i64 + offset_rows)
        .clamp(shifted_top as i64, image_height as i64 - 1) as u32;
    let new_height = shifted_bottom - shifted_top + 1;
    (shifted_top, shifted_bottom, new_height)
}

/// Detects one frame's film ROI on its raw archive raster (stored
/// orientation) using the parity-proven NegPy AUTO_FRAME_EDGE port and the
/// exact parameters validated by the parity harness. Detection only reads
/// the buffer; a degenerate or out-of-bounds result fails open to the full
/// derivative and is recorded in the receipt.
fn detect_auto_crop(raw: &[[f64; 3]], width: u32, height: u32) -> domain::AutoCropOutcome {
    let pixels: Vec<[f32; 3]> = raw
        .iter()
        .map(|pixel| [pixel[0] as f32, pixel[1] as f32, pixel[2] as f32])
        .collect();
    let image = crate::processing::geometry::GeometryImage {
        width,
        height,
        pixels,
    };
    let roi = crate::processing::geometry::autocrop_roi(
        &image,
        crate::processing::geometry::AutocropMode::Image,
        0,
        1.0,
        "3:2",
        crate::processing::geometry::AUTOCROP_DETECT_RES,
        None,
    );
    let usable = roi.y1 < roi.y2 && roi.x1 < roi.x2 && roi.y2 <= height && roi.x2 <= width;
    if usable {
        domain::AutoCropOutcome {
            mode: "image".to_string(),
            applied: true,
            roi: Some(domain::AutoCropRoi {
                y1: roi.y1,
                y2: roi.y2,
                x1: roi.x1,
                x2: roi.x2,
            }),
            source_width: width,
            source_height: height,
            reason: None,
        }
    } else {
        domain::AutoCropOutcome {
            mode: "image".to_string(),
            applied: false,
            roi: None,
            source_width: width,
            source_height: height,
            reason: Some(format!(
                "detected ROI y{}..{} x{}..{} is not a usable region of the {}x{} raster; derivatives left uncropped",
                roi.y1, roi.y2, roi.x1, roi.x2, width, height
            )),
        }
    }
}

fn auto_crop_deferred_to_alignment(width: u32, height: u32) -> domain::AutoCropOutcome {
    domain::AutoCropOutcome {
        mode: "image".to_string(),
        applied: false,
        roi: None,
        source_width: width,
        source_height: height,
        reason: Some(
            "approved manual frame alignment supersedes auto-crop for this frame".to_string(),
        ),
    }
}

/// Extracts a half-open ROI from a row-major `[0,1]` float buffer.
fn crop_to_roi(
    buffer: &[[f64; 3]],
    width: u32,
    roi: &domain::AutoCropRoi,
) -> (Vec<[f64; 3]>, u32, u32) {
    let new_width = roi.x2 - roi.x1;
    let new_height = roi.y2 - roi.y1;
    let mut cropped = Vec::with_capacity((new_width as usize) * (new_height as usize));
    for row in roi.y1..roi.y2 {
        let start = (row * width + roi.x1) as usize;
        cropped.extend_from_slice(&buffer[start..start + new_width as usize]);
    }
    (cropped, new_width, new_height)
}

/// Applies an approved vertical crop to a row-major `[0,1]` float buffer.
/// Unapproved alignments and missing boundaries are treated as no-ops:
/// the full buffer is returned unchanged. This is the render-side half of
/// the archive-immutability guarantee.
pub fn apply_alignment_crop(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
) -> (Vec<[f64; 3]>, u32, u32) {
    let Some(alignment) = alignment else {
        return (raw.to_vec(), width, height);
    };
    if !alignment.approved {
        return (raw.to_vec(), width, height);
    }
    let Some((boundary_top, boundary_bottom)) = detected_boundary else {
        return (raw.to_vec(), width, height);
    };
    let (top, _bottom, new_height) =
        resolve_aligned_crop(boundary_top, boundary_bottom, alignment.offset_rows, height);
    let start = (top * width) as usize;
    let end = start + (new_height * width) as usize;
    let cropped = raw[start..end].to_vec();
    (cropped, width, new_height)
}

// ---------------------------------------------------------------------
// Synthetic defect generation (DEF-02)
// ---------------------------------------------------------------------

/// Lower bound for a generated `DefectInstance.severity` draw. Mirrors
/// `processing::ice::DefectMap.score`'s own `[0.0,1.0]` convention (see
/// `domain::DefectInstance`'s doc comment) without calling into that frozen
/// module.
pub const DEFECT_SEVERITY_FLOOR: f32 = 0.15;
/// `severity >= this` classifies `Uncertain` (amber, least-certain); below
/// it, `WillCorrect` (red, confident) -- mirrors the mid-range-vs-near-1.0
/// band shape `processing::ice::DefectMap`'s own doc comment documents for
/// Phase 17.
pub const DEFECT_CLASSIFICATION_THRESHOLD: f32 = 0.78;
pub const MIN_DEFECT_COUNT: u32 = 3;
pub const MAX_DEFECT_COUNT: u32 = 40;

/// Resolves a raw `[0.0,1.0]` severity into DEF-02's red("will correct")/
/// amber("uncertain") classification band. See `DEFECT_CLASSIFICATION_THRESHOLD`.
pub fn classify_defect_severity(severity: f32) -> domain::DefectClassification {
    if severity >= DEFECT_CLASSIFICATION_THRESHOLD {
        domain::DefectClassification::Uncertain
    } else {
        domain::DefectClassification::WillCorrect
    }
}

/// Deterministic `[0.0,1.0)` value stream seeded from `seed`: each value
/// re-hashes the previous `u64` state (formatted as lowercase hex) through
/// `fnv1a64` again, then takes the top 32 bits of the new state over
/// `2^32` for a half-open unit-interval value. A private, reusable helper so
/// every field draw in `generate_synthetic_defects` pulls its own next value
/// off one single stream instead of reimplementing this ad hoc per call site.
fn defect_seed_stream(seed: u64) -> impl Iterator<Item = f64> {
    let mut state = seed;
    std::iter::from_fn(move || {
        state = crate::sim::fnv1a64(&format!("{state:x}"));
        Some((state >> 32) as f64 / 4294967296.0)
    })
}

/// Deterministic, seeded synthetic dust/scratch defect generator for DEF-02.
/// A pure function of its three arguments (SIM-03): identical arguments
/// always return a byte-identical `Vec`; a different `frame_index` (all else
/// equal) varies the result. Returns an empty `Vec` whenever
/// `processing.digital_ice_enabled` is `false` -- real dust/scratch
/// detection fundamentally requires the infrared channel, so an "off"
/// result is never fabricated (see 05-01-PLAN.md's scope_decision notes).
pub fn generate_synthetic_defects(
    frame_index: u32,
    capture: &domain::CaptureRecipe,
    processing: &domain::ProcessingRecipe,
) -> Vec<domain::DefectInstance> {
    if !processing.digital_ice_enabled {
        return Vec::new();
    }

    let seed_string = format!(
        "defects:{frame_index}:{}:{:?}:{:?}",
        capture.resolution_dpi, processing.film_process, processing.digital_ice_mode
    );
    let seed = crate::sim::fnv1a64(&seed_string);
    let mut stream = defect_seed_stream(seed);
    let mut draw = || stream.next().expect("defect_seed_stream never terminates");

    let total = MIN_DEFECT_COUNT + (draw() * (MAX_DEFECT_COUNT - MIN_DEFECT_COUNT) as f64) as u32;

    let mut instances = Vec::with_capacity(total as usize);
    for id in 0..total {
        // ~85% Dust, ~15% Scratch.
        let is_scratch = draw() >= 0.85;
        let center_x = (0.04 + draw() * (0.96 - 0.04)) as f32;
        let center_y = (0.04 + draw() * (0.96 - 0.04)) as f32;
        let severity =
            (DEFECT_SEVERITY_FLOOR as f64 + draw() * (1.0 - DEFECT_SEVERITY_FLOOR as f64)) as f32;
        let classification = classify_defect_severity(severity);

        let (kind, radius, end_x, end_y) = if is_scratch {
            let half_width = (0.002 + draw() * (0.005 - 0.002)) as f32;
            let angle = draw() * std::f64::consts::TAU;
            let length = 0.05 + draw() * (0.22 - 0.05);
            let end_x = (center_x as f64 + length * angle.cos()).clamp(0.0, 1.0) as f32;
            let end_y = (center_y as f64 + length * angle.sin()).clamp(0.0, 1.0) as f32;
            (
                domain::DefectKind::Scratch,
                half_width,
                Some(end_x),
                Some(end_y),
            )
        } else {
            let radius = (0.006 + draw() * (0.018 - 0.006)) as f32;
            (domain::DefectKind::Dust, radius, None, None)
        };

        instances.push(domain::DefectInstance {
            id,
            kind,
            severity,
            classification,
            center_x,
            center_y,
            radius,
            end_x,
            end_y,
        });
    }

    instances
}

// ---------------------------------------------------------------------
// Real (IR-derived) defect clustering (PROC-02)
// ---------------------------------------------------------------------

/// Threshold for classifying a connected component as a scratch rather than
/// dust: a component whose bounding-box long edge is at least this many
/// times its short edge is treated as an elongated defect trace.
const SCRATCH_ASPECT_RATIO_THRESHOLD: f32 = 3.0;
/// Minimum long-edge pixel length for the scratch classification above to
/// apply. A tiny blob with a coincidentally high aspect ratio still reads as
/// dust.
const SCRATCH_MIN_LENGTH_PX: u32 = 6;
/// Normalized-radius sanity floor. Prevents a degenerate single-pixel
/// component from reporting a zero radius.
const DEFECT_INSTANCE_RADIUS_MIN: f32 = 0.001;
/// Normalized-radius sanity ceiling. Prevents an edge-spanning component
/// from reporting an absurd radius.
const DEFECT_INSTANCE_RADIUS_MAX: f32 = 0.25;

/// Clusters a real `processing::ice::DefectMap` (frozen — called not
/// modified) into the same `Vec<domain::DefectInstance>` shape that
/// `generate_synthetic_defects` produces. This is the real-data counterpart
/// to the synthetic generator above: identical wire shape, but the pixels
/// come from actual IR-derived defect scoring rather than seeded synthesis.
///
/// The function is pure and deterministic: any `score > 0.0` pixel is
/// treated as a confirmed defect pixel (the frozen `ice::detect_defects`
/// already applied its own neighborhood confirmation before writing a
/// nonzero score), and components are discovered in raster order.
pub fn cluster_defect_map(map: &ice::DefectMap) -> Vec<domain::DefectInstance> {
    let components = find_defect_components(map);
    components
        .into_iter()
        .enumerate()
        .map(|(id, pixels)| defect_instance_from_component(id as u32, &pixels, map))
        .collect()
}

fn find_defect_components(map: &ice::DefectMap) -> Vec<Vec<(u32, u32)>> {
    if map.width == 0 || map.height == 0 {
        return Vec::new();
    }

    let width = map.width as usize;
    let height = map.height as usize;
    let mut visited = vec![false; width * height];
    let mut components = Vec::new();

    for y in 0..height {
        for x in 0..width {
            let idx = y * width + x;
            if visited[idx] || map.score[idx] <= 0.0 {
                continue;
            }

            let mut pixels = Vec::new();
            let mut queue = std::collections::VecDeque::new();
            queue.push_back((x, y));
            visited[idx] = true;

            while let Some((cx, cy)) = queue.pop_front() {
                pixels.push((cx as u32, cy as u32));
                for dy in -1..=1 {
                    for dx in -1..=1 {
                        if dy == 0 && dx == 0 {
                            continue;
                        }
                        let nx = cx as i64 + dx;
                        let ny = cy as i64 + dy;
                        if nx < 0 || nx >= width as i64 || ny < 0 || ny >= height as i64 {
                            continue;
                        }
                        let nidx = ny as usize * width + nx as usize;
                        if !visited[nidx] && map.score[nidx] > 0.0 {
                            visited[nidx] = true;
                            queue.push_back((nx as usize, ny as usize));
                        }
                    }
                }
            }

            components.push(pixels);
        }
    }

    components
}

fn defect_instance_from_component(
    id: u32,
    pixels: &[(u32, u32)],
    map: &ice::DefectMap,
) -> domain::DefectInstance {
    debug_assert!(
        !pixels.is_empty(),
        "component must contain at least one pixel"
    );

    let width = map.width;
    let height = map.height;

    let mut severity = 0.0_f32;
    let mut min_x = u32::MAX;
    let mut max_x = u32::MIN;
    let mut min_y = u32::MAX;
    let mut max_y = u32::MIN;
    let mut sum_x = 0.0_f64;
    let mut sum_y = 0.0_f64;

    for &(x, y) in pixels {
        let idx = y as usize * width as usize + x as usize;
        let score = map.score[idx];
        if score > severity {
            severity = score;
        }
        if x < min_x {
            min_x = x;
        }
        if x > max_x {
            max_x = x;
        }
        if y < min_y {
            min_y = y;
        }
        if y > max_y {
            max_y = y;
        }
        sum_x += x as f64;
        sum_y += y as f64;
    }

    let classification = classify_defect_severity(severity);
    let mean_x = sum_x / pixels.len() as f64;
    let mean_y = sum_y / pixels.len() as f64;

    let bbox_w = max_x - min_x + 1;
    let bbox_h = max_y - min_y + 1;
    let long_extent = bbox_w.max(bbox_h);
    let short_extent = bbox_w.min(bbox_h).max(1);
    let is_scratch = (long_extent as f32 / short_extent as f32) >= SCRATCH_ASPECT_RATIO_THRESHOLD
        && long_extent >= SCRATCH_MIN_LENGTH_PX;

    let normalize_x = |value: f64| (value / width as f64).clamp(0.0, 1.0) as f32;
    let normalize_y = |value: f64| (value / height as f64).clamp(0.0, 1.0) as f32;
    let clamp_radius =
        |value: f32| value.clamp(DEFECT_INSTANCE_RADIUS_MIN, DEFECT_INSTANCE_RADIUS_MAX);

    if !is_scratch {
        let center_x = normalize_x(mean_x);
        let center_y = normalize_y(mean_y);
        let pixel_radius = (pixels.len() as f32 / std::f32::consts::PI).sqrt();
        let radius = clamp_radius(pixel_radius / width as f32);

        return domain::DefectInstance {
            id,
            kind: domain::DefectKind::Dust,
            severity,
            classification,
            center_x,
            center_y,
            radius,
            end_x: None,
            end_y: None,
        };
    }

    // Scratch: principal-axis end points.
    let mut cov_xx = 0.0_f64;
    let mut cov_yy = 0.0_f64;
    let mut cov_xy = 0.0_f64;
    for &(x, y) in pixels {
        let dx = x as f64 - mean_x;
        let dy = y as f64 - mean_y;
        cov_xx += dx * dx;
        cov_yy += dy * dy;
        cov_xy += dx * dy;
    }
    let n = pixels.len() as f64;
    cov_xx /= n;
    cov_yy /= n;
    cov_xy /= n;

    let theta = 0.5 * (2.0 * cov_xy).atan2(cov_xx - cov_yy);
    let dir = (theta.cos(), theta.sin());

    let mut min_proj = f64::INFINITY;
    let mut max_proj = f64::NEG_INFINITY;
    let mut endpoint_a = pixels[0];
    let mut endpoint_b = pixels[0];
    for &(x, y) in pixels {
        let proj = (x as f64 - mean_x) * dir.0 + (y as f64 - mean_y) * dir.1;
        if proj < min_proj {
            min_proj = proj;
            endpoint_a = (x, y);
        }
        if proj > max_proj {
            max_proj = proj;
            endpoint_b = (x, y);
        }
    }

    let center_x = normalize_x(endpoint_a.0 as f64);
    let center_y = normalize_y(endpoint_a.1 as f64);
    let end_x = Some(normalize_x(endpoint_b.0 as f64));
    let end_y = Some(normalize_y(endpoint_b.1 as f64));

    let length_px = ((endpoint_b.0 as f64 - endpoint_a.0 as f64).powi(2)
        + (endpoint_b.1 as f64 - endpoint_a.1 as f64).powi(2))
    .sqrt()
    .max(1.0);
    let radius = clamp_radius((pixels.len() as f32 / (2.0 * length_px as f32)) / width as f32);

    domain::DefectInstance {
        id,
        kind: domain::DefectKind::Scratch,
        severity,
        classification,
        center_x,
        center_y,
        radius,
        end_x,
        end_y,
    }
}

/// Loads a real archive RGB+IR capture pair from disk, runs the frozen
/// `ice::detect_defects` algorithm on it, and clusters the resulting defect
/// map into `domain::DefectInstance`s. Mirrors
/// `generate_synthetic_defects`'s ICE-off contract: when
/// `processing.digital_ice_enabled` is false, no filesystem I/O is performed
/// and an empty `Vec` is returned immediately.
pub fn real_frame_defects(
    rgb_path: &std::path::Path,
    ir_path: &std::path::Path,
    processing: &domain::ProcessingRecipe,
) -> Result<Vec<domain::DefectInstance>, domain::EngineError> {
    if !processing.digital_ice_enabled {
        return Ok(Vec::new());
    }

    let rgb_image = image_io::read_rgb16(rgb_path).map_err(|err| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to read RGB archive at {}: {err}",
                rgb_path.display()
            ),
        )
    })?;
    let ir_image = image_io::read_gray16(ir_path).map_err(|err| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("failed to read IR archive at {}: {err}", ir_path.display()),
        )
    })?;

    if rgb_image.width != ir_image.width || rgb_image.height != ir_image.height {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "RGB/IR dimension mismatch — rgb {}x{}, ir {}x{}",
                rgb_image.width, rgb_image.height, ir_image.width, ir_image.height
            ),
        ));
    }

    let frame = ice::IceInputFrame {
        width: rgb_image.width,
        height: rgb_image.height,
        rgb: rgb_image.pixels,
        ir: ir_image.pixels,
    };
    let params = ice::IceParameters::for_main_scan(&frame);
    let map = ice::detect_defects(&frame, &params);
    Ok(cluster_defect_map(&map))
}

/// Honestly-synthetic deterministic frame data: a cheap wave field, not a
/// photographic simulation, sized to whatever `width`/`height` the caller
/// passes. Reuses `sim::fnv1a64`/`sim::thumbnail_for` so the same
/// device/frame always reproduces byte-identical pixels.
pub fn generate_sim_frame(
    device_id: &str,
    frame_index: u32,
    width: u32,
    height: u32,
) -> Vec<[f64; 3]> {
    let base = crate::sim::thumbnail_for(device_id, frame_index);
    let base_brightness = base
        .brightness
        .expect("sim::thumbnail_for always sets brightness");
    let base_tint = base.tint.expect("sim::thumbnail_for always sets tint");
    let seed = crate::sim::fnv1a64(&format!("{device_id}:{frame_index}"));

    let mut pixels = Vec::with_capacity(width as usize * height as usize);
    for y in 0..height {
        let fy = y as f64 / height.max(1) as f64;
        for x in 0..width {
            let fx = x as f64 / width.max(1) as f64;
            let mut pixel = [0.0_f64; 3];
            for (c, sample) in pixel.iter_mut().enumerate() {
                let phase = ((seed >> (c * 8)) & 0xFF) as f64 / 255.0;
                let wave =
                    ((fx * 6.0 + fy * 4.0 + phase * std::f64::consts::TAU).sin() + 1.0) / 2.0;
                *sample = (base_brightness + base_tint * (c as f64 - 1.0) * 0.3 + wave * 0.15)
                    .clamp(0.0, 1.0);
            }
            pixels.push(pixel);
        }
    }
    pixels
}

// ---------------------------------------------------------------------
// Filename/path resolution
// ---------------------------------------------------------------------

/// A job-local marker produced only when the default single-`#` template is
/// reserved for a concrete output number. It never reaches a project
/// manifest: the editable recipe remains `ScanStudio#`, while every backend
/// receives an exact per-frame filename for this one job.
const RESERVED_SEQUENCE_PREFIX: &str = domain::OutputRecipe::RESERVED_FILENAME_MARKER_PREFIX;
const RESERVED_SEQUENCE_SUFFIX: &str = ")";

/// A single hash is the new auto-number token. Multi-hash runs remain the
/// established frame-number convention (`####` -> the scanner slot), so
/// existing custom templates keep their exact behavior.
fn is_auto_sequence_template(template: &str) -> bool {
    template
        .chars()
        .filter(|character| *character == '#')
        .count()
        == 1
}

pub(crate) fn is_reserved_sequence_template(template: &str) -> bool {
    template.contains(RESERVED_SEQUENCE_PREFIX)
}

/// Returns the user-facing recipe suitable for durable receipts. Sequence
/// reservation is an engine-only dispatch detail: exact bridge names use the
/// private marker, while manifests and receipts retain the editable `#` token.
pub(crate) fn receipt_output_recipe(output: &domain::OutputRecipe) -> domain::OutputRecipe {
    let mut receipt_output = output.clone();
    for template in [
        &mut receipt_output.archive.filename_template,
        &mut receipt_output.positive.filename_template,
        &mut receipt_output.preview.filename_template,
        &mut receipt_output.raw_export.filename_template,
    ] {
        *template = restore_reserved_sequence_template(template);
    }
    receipt_output
}

fn restore_reserved_sequence_template(template: &str) -> String {
    let Some(start) = template.find(RESERVED_SEQUENCE_PREFIX) else {
        return template.to_string();
    };
    let number_start = start + RESERVED_SEQUENCE_PREFIX.len();
    let Some(number_end_offset) = template[number_start..].find(RESERVED_SEQUENCE_SUFFIX) else {
        return template.to_string();
    };
    let number_end = number_start + number_end_offset;
    if template[number_start..number_end]
        .parse::<u32>()
        .ok()
        .filter(|number| *number > 0)
        .is_none()
        || template[number_end + RESERVED_SEQUENCE_SUFFIX.len()..]
            .contains(RESERVED_SEQUENCE_PREFIX)
    {
        return template.to_string();
    }
    format!(
        "{}#{}",
        &template[..start],
        &template[number_end + RESERVED_SEQUENCE_SUFFIX.len()..]
    )
}

fn reserve_sequence_template(template: &str, number: u32) -> String {
    debug_assert!(is_auto_sequence_template(template));
    template.replacen(
        '#',
        &format!("{RESERVED_SEQUENCE_PREFIX}{number}{RESERVED_SEQUENCE_SUFFIX}"),
        1,
    )
}

fn resolve_reserved_sequence_template(template: &str) -> Option<String> {
    let start = template.find(RESERVED_SEQUENCE_PREFIX)?;
    let number_start = start + RESERVED_SEQUENCE_PREFIX.len();
    let number_end = template[number_start..].find(RESERVED_SEQUENCE_SUFFIX)? + number_start;
    let number = template[number_start..number_end]
        .parse::<u32>()
        .ok()
        .filter(|number| *number > 0)?;
    let marker_end = number_end + RESERVED_SEQUENCE_SUFFIX.len();
    if template[marker_end..].contains(RESERVED_SEQUENCE_PREFIX) {
        return None;
    }
    Some(format!(
        "{}{}{}",
        &template[..start],
        number,
        &template[marker_end..]
    ))
}

/// Splices `frame_index`, zero-padded to the run length of the first `#`
/// run in `template`, in place of that run. A template with no marker gets
/// the same stable four-digit suffix as an implicit `"_####"` marker.
pub fn resolve_filename(template: &str, frame_index: u32) -> String {
    if let Some(filename) = resolve_reserved_sequence_template(template) {
        return filename;
    }
    match template.find('#') {
        Some(start) => {
            let run_len = template[start..].chars().take_while(|&c| c == '#').count();
            let end = start + run_len;
            let replacement = format!("{:0width$}", frame_index, width = run_len);
            format!("{}{}{}", &template[..start], replacement, &template[end..])
        }
        None => {
            let path = std::path::Path::new(template);
            let recognized_output_extension = path
                .extension()
                .and_then(|value| value.to_str())
                .is_some_and(|value| {
                    OutputNameKind::Tiff.recognizes_extension(value)
                        || OutputNameKind::Jpeg.recognizes_extension(value)
                        || OutputNameKind::Dng.recognizes_extension(value)
                });
            if recognized_output_extension {
                let stem = path
                    .file_stem()
                    .and_then(|value| value.to_str())
                    .unwrap_or(template);
                format!(
                    "{stem}_{frame_index:04}.{}",
                    path.extension()
                        .and_then(|value| value.to_str())
                        .expect("recognized extension is UTF-8")
                )
            } else {
                format!("{template}_{frame_index:04}")
            }
        }
    }
}

fn reserve_auto_sequence_templates(recipes: &mut domain::OutputRecipe, number: u32) {
    let mut templates = Vec::new();
    if recipes.archive.enabled {
        templates.push(&mut recipes.archive.filename_template);
    }
    if recipes.positive.enabled {
        templates.push(&mut recipes.positive.filename_template);
    }
    if recipes.preview.enabled {
        templates.push(&mut recipes.preview.filename_template);
    }
    if recipes.raw_export.enabled {
        templates.push(&mut recipes.raw_export.filename_template);
    }
    for template in templates {
        if is_auto_sequence_template(template) {
            *template = reserve_sequence_template(template, number);
        }
    }
}

fn has_auto_sequence_template(recipes: &domain::OutputRecipe) -> bool {
    (recipes.archive.enabled && is_auto_sequence_template(&recipes.archive.filename_template))
        || (recipes.positive.enabled
            && is_auto_sequence_template(&recipes.positive.filename_template))
        || (recipes.preview.enabled
            && is_auto_sequence_template(&recipes.preview.filename_template))
        || (recipes.raw_export.enabled
            && is_auto_sequence_template(&recipes.raw_export.filename_template))
}

/// Returns the planned auto-numbered names, including archive sidecars. The
/// caller passes a recipe where its single-`#` tokens have already been
/// replaced with a job-local reserved-number marker.
fn reserved_sequence_paths(
    recipes: &domain::OutputRecipe,
    include_ir_sidecar: bool,
    include_meter_sidecar: bool,
) -> Result<Vec<std::path::PathBuf>, domain::EngineError> {
    let mut paths = Vec::new();
    if recipes.archive.enabled && is_reserved_sequence_template(&recipes.archive.filename_template)
    {
        let archive = resolve_archive_output_path(recipes, 0);
        paths.push(archive.clone());
        if include_ir_sidecar {
            paths.push(archive_sidecar_path(&archive, "IR")?);
        }
        if include_meter_sidecar {
            paths.push(archive_sidecar_path(&archive, "METER")?);
        }
    }
    if recipes.positive.enabled
        && is_reserved_sequence_template(&recipes.positive.filename_template)
    {
        paths.push(resolve_output_path(
            &recipes.positive.destination,
            &recipes.positive.filename_template,
            0,
            recipes.positive.file_format,
        ));
    }
    if recipes.preview.enabled && is_reserved_sequence_template(&recipes.preview.filename_template)
    {
        paths.push(resolve_output_path(
            &recipes.preview.destination,
            &recipes.preview.filename_template,
            0,
            recipes.preview.file_format,
        ));
    }
    if recipes.raw_export.enabled
        && is_reserved_sequence_template(&recipes.raw_export.filename_template)
    {
        let raw = resolve_raw_export_output_path(recipes, 0);
        paths.push(raw.clone());
        if include_ir_sidecar
            && recipes.raw_export.tiff_infrared == domain::RawTiffInfrared::Sidecar
        {
            paths.push(raw_export_ir_sidecar_path(&raw));
            paths.push(raw_export_pair_commit_marker_path(&raw)?);
        }
    }
    Ok(paths)
}

fn authorized_sequence_directory_names(
    project_root: Option<&ProjectOutputRootAuthority>,
    destination: &Path,
    role: &str,
) -> Result<Vec<std::ffi::OsString>, domain::EngineError> {
    let requested = absolute_lexical(destination)?;
    let held = if let Some(project_root) = project_root {
        if requested_path_is_beneath_project_root(project_root, &requested)? {
            let relative = requested
                .strip_prefix(project_root.requested_path())
                .or_else(|_| requested.strip_prefix(project_root.canonical_path()))
                .expect("project-relative check accepted one held-root prefix");
            let physical = project_root.canonical_path().join(relative);
            acquire_destination_directory(
                project_root.canonical_path(),
                project_root.directory_handle(),
                &physical,
                role,
            )?
        } else {
            acquire_independent_sequence_directory(&requested, role)?
        }
    } else {
        acquire_independent_sequence_directory(&requested, role)?
    };
    destination_sys::verify_namespace(&held.inner)?;
    let names = crate::exiftool::metadata_publish_sys::read_directory_names(&held.inner.directory)
        .map_err(|error| {
            output_authority_error(format!(
                "enumerate held {role} sequence destination {}: {error}",
                held.inner.display_path.display()
            ))
        })?;
    destination_sys::verify_namespace(&held.inner)?;
    Ok(names)
}

fn acquire_independent_sequence_directory(
    requested: &Path,
    role: &str,
) -> Result<HeldDestinationDirectory, domain::EngineError> {
    let probe_leaf = requested.join(".scanstudio-sequence-authority");
    let canonical_probe = canonical_authorized_final_path(None, Path::new("/"), probe_leaf, role)?;
    let physical = canonical_probe.parent().ok_or_else(|| {
        output_authority_error(format!(
            "{role} sequence destination has no parent: {}",
            requested.display()
        ))
    })?;
    #[cfg(windows)]
    validate_windows_local_output_path(physical, role)?;
    let root_path = independent_filesystem_root(physical)?;
    let root = destination_sys::open_root(&root_path)?;
    ensure_identity_safe_filesystem(&root, role)?;
    acquire_destination_directory(&root_path, &root, physical, role)
}

fn highest_sequence_number_in_names(
    names: &[std::ffi::OsString],
    template: &str,
) -> Result<u32, domain::EngineError> {
    let stem_template = std::path::Path::new(template)
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("sequence template has no usable file name: {template}"),
            )
        })?;
    let marker = stem_template
        .find('#')
        .expect("single-hash template has marker");
    let prefix = stem_template[..marker].to_ascii_lowercase();
    let suffix = stem_template[marker + 1..].to_ascii_lowercase();
    Ok(names.iter().fold(0_u32, |highest, name| {
        let stem = std::path::Path::new(name)
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let number = stem
            .strip_prefix(&prefix)
            .and_then(|remaining| remaining.strip_suffix(&suffix))
            .and_then(|digits| digits.parse::<u32>().ok())
            .filter(|number| *number > 0)
            .unwrap_or(0);
        highest.max(number)
    }))
}

fn highest_existing_sequence_for_recipe_authorized(
    project_root: Option<&ProjectOutputRootAuthority>,
    recipes: &domain::OutputRecipe,
) -> Result<u32, domain::EngineError> {
    let mut highest = 0;
    if recipes.archive.enabled && is_auto_sequence_template(&recipes.archive.filename_template) {
        let names = authorized_sequence_directory_names(
            project_root,
            Path::new(&recipes.archive.destination),
            "archive",
        )?;
        let template = normalize_output_filename_template(
            &recipes.archive.filename_template,
            domain::OutputFileFormat::Tiff,
        );
        highest = highest.max(highest_sequence_number_in_names(&names, &template)?);
    }
    if recipes.positive.enabled && is_auto_sequence_template(&recipes.positive.filename_template) {
        let names = authorized_sequence_directory_names(
            project_root,
            Path::new(&recipes.positive.destination),
            "positive",
        )?;
        let template = normalize_output_filename_template(
            &recipes.positive.filename_template,
            recipes.positive.file_format,
        );
        highest = highest.max(highest_sequence_number_in_names(&names, &template)?);
    }
    if recipes.preview.enabled && is_auto_sequence_template(&recipes.preview.filename_template) {
        let names = authorized_sequence_directory_names(
            project_root,
            Path::new(&recipes.preview.destination),
            "preview",
        )?;
        let template = normalize_output_filename_template(
            &recipes.preview.filename_template,
            recipes.preview.file_format,
        );
        highest = highest.max(highest_sequence_number_in_names(&names, &template)?);
    }
    if recipes.raw_export.enabled
        && is_auto_sequence_template(&recipes.raw_export.filename_template)
    {
        let names = authorized_sequence_directory_names(
            project_root,
            Path::new(&recipes.raw_export.destination),
            "raw export",
        )?;
        let template = normalize_raw_export_filename_template(
            &recipes.raw_export.filename_template,
            recipes.raw_export.file_format,
        );
        highest = highest.max(highest_sequence_number_in_names(&names, &template)?);
    }
    Ok(highest)
}

fn authorized_sequence_stem_exists(
    project_root: Option<&ProjectOutputRootAuthority>,
    path: &Path,
) -> Result<bool, domain::EngineError> {
    let parent = path.parent().ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "sequence output has no destination folder: {}",
                path.display()
            ),
        )
    })?;
    let expected_stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "sequence output has no usable file name: {}",
                    path.display()
                ),
            )
        })?;
    let names = authorized_sequence_directory_names(project_root, parent, "auto-sequence")?;
    Ok(names.iter().any(|name| {
        std::path::Path::new(name)
            .file_stem()
            .and_then(|value| value.to_str())
            .is_some_and(|value| value.eq_ignore_ascii_case(expected_stem))
    }))
}

/// Returns the largest positive number already used by this one single-`#`
/// template in its selected destination. The comparison is intentionally by
/// file stem, so `ScanStudio12.tif` and `ScanStudio12.jpg` are one consumed
/// visible sequence number while `ScanStudio12_IR.tif` is not mistaken for
/// the user-facing `ScanStudio12` output.
#[cfg(test)]
fn highest_existing_sequence_number(
    destination: &str,
    template: &str,
    format: domain::OutputFileFormat,
) -> Result<u32, domain::EngineError> {
    if !is_auto_sequence_template(template) {
        return Ok(0);
    }
    let normalized = normalize_output_filename_template(template, format);
    let stem_template = std::path::Path::new(&normalized)
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("sequence template has no usable file name: {template}"),
            )
        })?;
    let marker = stem_template
        .find('#')
        .expect("single-hash template has marker");
    let prefix = stem_template[..marker].to_ascii_lowercase();
    let suffix = stem_template[marker + 1..].to_ascii_lowercase();
    let parent = std::path::Path::new(destination);
    match std::fs::read_dir(parent) {
        Ok(mut entries) => entries.try_fold(0_u32, |highest, entry| {
            let entry = entry.map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!("read output destination {}: {error}", parent.display()),
                )
            })?;
            let entry_path = entry.path();
            let stem = entry_path
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            let Some(number) = stem
                .strip_prefix(&prefix)
                .and_then(|remaining| remaining.strip_suffix(&suffix))
                .and_then(|digits| digits.parse::<u32>().ok())
                .filter(|number| *number > 0)
            else {
                return Ok(highest);
            };
            Ok(highest.max(number))
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("read output destination {}: {error}", parent.display()),
        )),
    }
}

/// Converts the new single-`#` sequence token into exact, per-frame names
/// before either backend receives a job. It allocates consecutive positive
/// integers in request order and skips a number whenever *any* enabled
/// auto-named archive/IR/meter/positive/preview target already has that stem
/// in its own effective destination. Legacy multi-hash templates are never
/// touched.
pub(crate) fn reserve_auto_sequence_filenames(
    project_root: Option<&ProjectOutputRootAuthority>,
    frames: &[u32],
    recipe: &domain::CaptureRecipe,
    processing: &domain::ProcessingRecipe,
    recipes: &domain::OutputRecipe,
    overrides: &mut std::collections::HashMap<u32, domain::FrameOverrides>,
) -> Result<(), domain::EngineError> {
    if let Some(project_root) = project_root {
        project_root.verify_namespace()?;
    }
    let base_recipe = recipe.effective_for_process(processing.film_process);
    let mut highest_existing = 0_u32;
    for frame_index in frames {
        let frame_output = overrides
            .get(frame_index)
            .and_then(|value| value.output.as_ref())
            .unwrap_or(recipes);
        highest_existing = highest_existing.max(highest_existing_sequence_for_recipe_authorized(
            project_root,
            frame_output,
        )?);
    }
    let mut next_number = highest_existing.checked_add(1).ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            "no positive filename sequence number remains available",
        )
    })?;

    for frame_index in frames {
        let frame_values = overrides.get(frame_index);
        let frame_output = frame_values
            .and_then(|value| value.output.as_ref())
            .unwrap_or(recipes)
            .clone();
        if !has_auto_sequence_template(&frame_output) {
            continue;
        }
        let frame_processing = frame_values
            .and_then(|value| value.processing.as_ref())
            .unwrap_or(processing)
            .effective();
        let frame_recipe = frame_values
            .and_then(|value| value.capture.as_ref())
            .unwrap_or(recipe)
            .effective_for_process(frame_processing.film_process);
        let include_ir_sidecar = base_recipe.channels == domain::Channels::Rgbi
            || frame_recipe.channels == domain::Channels::Rgbi;

        loop {
            let mut candidate_output = frame_output.clone();
            reserve_auto_sequence_templates(&mut candidate_output, next_number);
            let occupied = reserved_sequence_paths(&candidate_output, include_ir_sidecar, true)?
                .iter()
                .try_fold(false, |occupied, path| {
                    Ok::<_, domain::EngineError>(
                        occupied || authorized_sequence_stem_exists(project_root, path)?,
                    )
                })?;
            if !occupied {
                let frame_values = overrides.entry(*frame_index).or_default();
                frame_values.output = Some(candidate_output);
                next_number = next_number.checked_add(1).ok_or_else(|| {
                    domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        "no positive filename sequence number remains available",
                    )
                })?;
                break;
            }
            next_number = next_number.checked_add(1).ok_or_else(|| {
                domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    "no positive filename sequence number remains available",
                )
            })?;
        }
    }
    if let Some(project_root) = project_root {
        project_root.verify_namespace()?;
    }
    Ok(())
}

/// Output templates are file *names*, never paths. Validate before any
/// backend joins a template to its selected destination so simulator and
/// bridge jobs fail the same way rather than allowing `..` or an absolute
/// component to escape the operator's chosen folder.
pub fn validate_user_output_recipe_paths(
    recipes: &domain::OutputRecipe,
) -> Result<(), domain::EngineError> {
    debug_assert_eq!(
        recipes.contains_reserved_filename_marker(),
        [
            recipes.archive.filename_template.as_str(),
            recipes.positive.filename_template.as_str(),
            recipes.preview.filename_template.as_str(),
            recipes.raw_export.filename_template.as_str(),
        ]
        .into_iter()
        .any(is_reserved_sequence_template)
    );
    for (label, template) in [
        ("archive", recipes.archive.filename_template.as_str()),
        ("positive", recipes.positive.filename_template.as_str()),
        ("preview", recipes.preview.filename_template.as_str()),
        ("raw export", recipes.raw_export.filename_template.as_str()),
    ] {
        if is_reserved_sequence_template(template) {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "{label} filename template contains a reserved engine marker; use # for automatic numbering"
                ),
            ));
        }
    }
    validate_output_recipe_paths(recipes)
}

pub fn validate_output_recipe_paths(
    recipes: &domain::OutputRecipe,
) -> Result<(), domain::EngineError> {
    let mut outputs = Vec::new();
    if recipes.archive.enabled {
        outputs.push((
            "archive",
            recipes.archive.destination.as_str(),
            recipes.archive.filename_template.as_str(),
        ));
    }
    if recipes.positive.enabled {
        outputs.push((
            "positive",
            recipes.positive.destination.as_str(),
            recipes.positive.filename_template.as_str(),
        ));
    }
    if recipes.preview.enabled {
        outputs.push((
            "preview",
            recipes.preview.destination.as_str(),
            recipes.preview.filename_template.as_str(),
        ));
    }
    if recipes.raw_export.enabled {
        outputs.push((
            "raw export",
            recipes.raw_export.destination.as_str(),
            recipes.raw_export.filename_template.as_str(),
        ));
    }
    for (label, destination, template) in outputs {
        let path = std::path::Path::new(template);
        if destination.trim().is_empty()
            || template.trim().is_empty()
            || template.contains(['/', '\\', '\0'])
            || !matches!(
                (path.components().next(), path.components().count()),
                (Some(std::path::Component::Normal(_)), 1)
            )
        {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "{label} destination must be non-empty and its filename template must be one relative file name, without traversal"
                ),
            ));
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OutputNameKind {
    Tiff,
    Jpeg,
    Dng,
}

impl OutputNameKind {
    fn chosen_extension(self) -> &'static str {
        match self {
            Self::Tiff => "tif",
            Self::Jpeg => "jpg",
            Self::Dng => "dng",
        }
    }

    fn recognizes_extension(self, extension: &str) -> bool {
        match self {
            Self::Tiff => {
                extension.eq_ignore_ascii_case("tif") || extension.eq_ignore_ascii_case("tiff")
            }
            Self::Jpeg => {
                extension.eq_ignore_ascii_case("jpg") || extension.eq_ignore_ascii_case("jpeg")
            }
            Self::Dng => extension.eq_ignore_ascii_case("dng"),
        }
    }
}

fn output_name_kind(format: domain::OutputFileFormat) -> OutputNameKind {
    match format {
        domain::OutputFileFormat::Tiff => OutputNameKind::Tiff,
        domain::OutputFileFormat::Jpeg => OutputNameKind::Jpeg,
    }
}

/// The single extension policy used by server preflight, simulator writes,
/// real bridge slot maps, real derivative writes, and receipts. Only a
/// terminal extension belonging to the requested format is preserved.
/// Dotted metadata such as `EF50mmF1.8STM` therefore still receives `.tif`.
pub(crate) fn normalize_output_filename_template(
    filename_template: &str,
    format: domain::OutputFileFormat,
) -> String {
    let kind = output_name_kind(format);
    let recognized = std::path::Path::new(filename_template)
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| kind.recognizes_extension(value));
    if recognized {
        filename_template.to_string()
    } else {
        format!("{filename_template}.{}", kind.chosen_extension())
    }
}

pub(crate) fn normalize_raw_export_filename_template(
    filename_template: &str,
    format: domain::RawExportFormat,
) -> String {
    let kind = match format {
        domain::RawExportFormat::LinearDng => OutputNameKind::Dng,
        domain::RawExportFormat::LinearTiff => OutputNameKind::Tiff,
    };
    let path = std::path::Path::new(filename_template);
    let extension = path.extension().and_then(|value| value.to_str());
    if extension.is_some_and(|value| kind.recognizes_extension(value)) {
        return filename_template.to_string();
    }
    let is_known_output_extension = extension.is_some_and(|value| {
        OutputNameKind::Tiff.recognizes_extension(value)
            || OutputNameKind::Jpeg.recognizes_extension(value)
            || OutputNameKind::Dng.recognizes_extension(value)
    });
    if is_known_output_extension {
        let stem = path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or(filename_template);
        return format!("{stem}.{}", kind.chosen_extension());
    }
    format!("{filename_template}.{}", kind.chosen_extension())
}

pub(crate) fn resolve_output_path(
    destination: &str,
    filename_template: &str,
    frame_index: u32,
    format: domain::OutputFileFormat,
) -> std::path::PathBuf {
    let normalized = normalize_output_filename_template(filename_template, format);
    std::path::Path::new(destination).join(resolve_filename(&normalized, frame_index))
}

pub(crate) fn resolve_archive_output_path(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
) -> std::path::PathBuf {
    resolve_output_path(
        &recipes.archive.destination,
        &recipes.archive.filename_template,
        frame_index,
        domain::OutputFileFormat::Tiff,
    )
}

pub(crate) fn resolve_raw_export_output_path(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
) -> std::path::PathBuf {
    let normalized = normalize_raw_export_filename_template(
        &recipes.raw_export.filename_template,
        recipes.raw_export.file_format,
    );
    std::path::Path::new(&recipes.raw_export.destination)
        .join(resolve_filename(&normalized, frame_index))
}

pub(crate) fn raw_export_ir_sidecar_path(raw_export_path: &std::path::Path) -> std::path::PathBuf {
    let stem = raw_export_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("raw-negative");
    raw_export_path.with_file_name(format!("{stem}-ir.tif"))
}

pub(crate) fn archive_sidecar_path(
    archive_path: &std::path::Path,
    suffix: &str,
) -> Result<std::path::PathBuf, domain::EngineError> {
    let stem = archive_path
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "archive output has no usable file name: {}",
                    archive_path.display()
                ),
            )
        })?;
    Ok(archive_path.with_file_name(format!("{stem}_{suffix}.tif")))
}

#[derive(Debug, Clone)]
struct TargetCandidate {
    slot: u32,
    role: &'static str,
    path: std::path::PathBuf,
    create_only: bool,
}

#[derive(Debug)]
struct PhysicalTarget {
    key: String,
    handle: Option<same_file::Handle>,
    exists: bool,
}

fn lexical_absolute(path: &std::path::Path) -> Result<std::path::PathBuf, domain::EngineError> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("resolve current directory for output path: {error}"),
                )
            })?
            .join(path)
    };
    let mut normalized = std::path::PathBuf::new();
    for component in absolute.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    Ok(normalized)
}

/// Produces a conservative physical key without requiring the final role
/// folder to exist yet: lexical `.`/`..` are collapsed, the nearest
/// existing ancestor is canonicalized (resolving existing parent
/// symlinks), and the missing suffix is appended. Lower-casing makes
/// case-only aliases fail closed on both case-insensitive and
/// case-sensitive filesystems.
fn physical_target(path: &std::path::Path) -> Result<PhysicalTarget, domain::EngineError> {
    let normalized = lexical_absolute(path)?;
    let leaf = normalized
        .file_name()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("output target must end in a file name: {}", path.display()),
            )
        })?;
    let _ = leaf;

    let leaf_metadata = match std::fs::symlink_metadata(&normalized) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!(
                        "output target is an existing symlink and is refused: {}",
                        normalized.display()
                    ),
                ));
            }
            if !metadata.is_file() {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!(
                        "output target exists but is not a regular file: {}",
                        normalized.display()
                    ),
                ));
            }
            Some(metadata)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("inspect output target {}: {error}", normalized.display()),
            ))
        }
    };

    let mut ancestor = normalized.clone();
    let mut missing = Vec::<std::ffi::OsString>::new();
    let canonical_ancestor = loop {
        match std::fs::canonicalize(&ancestor) {
            Ok(value) => {
                let metadata = std::fs::metadata(&value).map_err(|error| {
                    domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        format!("inspect output ancestor {}: {error}", value.display()),
                    )
                })?;
                if !missing.is_empty() && !metadata.is_dir() {
                    return Err(domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        format!("output ancestor is not a directory: {}", value.display()),
                    ));
                }
                break value;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let component = ancestor.file_name().ok_or_else(|| {
                    domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        format!(
                            "cannot resolve an existing ancestor for output target {}",
                            normalized.display()
                        ),
                    )
                })?;
                missing.push(component.to_os_string());
                if !ancestor.pop() {
                    return Err(domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        format!(
                            "cannot resolve an existing ancestor for output target {}",
                            normalized.display()
                        ),
                    ));
                }
            }
            Err(error) => {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!(
                        "canonicalize output target ancestor {}: {error}",
                        ancestor.display()
                    ),
                ))
            }
        }
    };
    let mut physical = canonical_ancestor;
    for component in missing.iter().rev() {
        physical.push(component);
    }

    let handle = if leaf_metadata.is_some() {
        Some(same_file::Handle::from_path(&normalized).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "open output target identity oracle {}: {error}",
                    normalized.display()
                ),
            )
        })?)
    } else {
        None
    };
    Ok(PhysicalTarget {
        key: physical.to_string_lossy().to_lowercase(),
        handle,
        exists: leaf_metadata.is_some(),
    })
}

fn validate_target_candidates(candidates: &[TargetCandidate]) -> Result<(), domain::EngineError> {
    let mut resolved: Vec<(&TargetCandidate, PhysicalTarget)> =
        Vec::with_capacity(candidates.len());
    for candidate in candidates {
        let physical = physical_target(&candidate.path)?;
        if candidate.create_only && physical.exists {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::ArchiveCollision,
                format!(
                    "{} output for frame {} already exists at {}; capture outputs are create-only",
                    candidate.role,
                    candidate.slot,
                    candidate.path.display()
                ),
            ));
        }
        for (other, other_physical) in &resolved {
            let same_path = physical.key == other_physical.key;
            let same_file =
                matches!((&physical.handle, &other_physical.handle), (Some(a), Some(b)) if a == b);
            if same_path || same_file {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!(
                        "enabled outputs must resolve to distinct physical files before capture: frame {} {} aliases frame {} {}",
                        candidate.slot, candidate.role, other.slot, other.role
                    ),
                ));
            }
        }
        resolved.push((candidate, physical));
    }
    Ok(())
}

fn frame_target_candidates(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
    include_ir_sidecar: bool,
    include_meter_sidecar: bool,
    include_raw_ir_sidecar: bool,
) -> Result<Vec<TargetCandidate>, domain::EngineError> {
    validate_output_recipe_paths(recipes)?;
    let archive = recipes
        .archive
        .enabled
        .then(|| resolve_archive_output_path(recipes, frame_index));
    let mut candidates = Vec::new();
    if let Some(archive) = archive.as_ref() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "archive RGB",
            path: archive.clone(),
            create_only: true,
        });
    }
    if include_ir_sidecar && archive.is_some() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "archive IR sidecar",
            path: archive_sidecar_path(
                archive
                    .as_ref()
                    .expect("archive sidecar requires retained archive"),
                "IR",
            )?,
            create_only: true,
        });
    }
    if include_meter_sidecar && archive.is_some() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "archive meter sidecar",
            path: archive_sidecar_path(
                archive
                    .as_ref()
                    .expect("archive sidecar requires retained archive"),
                "METER",
            )?,
            create_only: true,
        });
    }
    if recipes.positive.enabled {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "positive",
            path: resolve_output_path(
                &recipes.positive.destination,
                &recipes.positive.filename_template,
                frame_index,
                recipes.positive.file_format,
            ),
            create_only: is_reserved_sequence_template(&recipes.positive.filename_template),
        });
    }
    if recipes.preview.enabled {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "preview",
            path: resolve_output_path(
                &recipes.preview.destination,
                &recipes.preview.filename_template,
                frame_index,
                recipes.preview.file_format,
            ),
            create_only: is_reserved_sequence_template(&recipes.preview.filename_template),
        });
    }
    if recipes.raw_export.enabled {
        let raw = resolve_raw_export_output_path(recipes, frame_index);
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "raw negative",
            path: raw.clone(),
            create_only: true,
        });
        if include_raw_ir_sidecar
            && recipes.raw_export.tiff_infrared == domain::RawTiffInfrared::Sidecar
        {
            candidates.push(TargetCandidate {
                slot: frame_index,
                role: "raw infrared sidecar",
                path: raw_export_ir_sidecar_path(&raw),
                create_only: true,
            });
            candidates.push(TargetCandidate {
                slot: frame_index,
                role: "raw RGB/IR commit marker",
                path: raw_export_pair_commit_marker_path(&raw)?,
                create_only: true,
            });
        }
    }
    Ok(candidates)
}

/// Validates every physical target for the complete requested batch in one
/// pass. Archive RGB, possible IR, and possible meter files participate
/// alongside both derivatives, including across different slots.
#[cfg(test)]
pub fn validate_batch_output_paths(
    frames: &[u32],
    recipe: &domain::CaptureRecipe,
    processing: &domain::ProcessingRecipe,
    recipes: &domain::OutputRecipe,
    overrides: &std::collections::HashMap<u32, domain::FrameOverrides>,
) -> Result<(), domain::EngineError> {
    let base_recipe = recipe.effective_for_process(processing.film_process);
    let mut candidates = Vec::new();
    for frame_index in frames {
        let frame_override = overrides.get(frame_index);
        let frame_recipes = frame_override
            .and_then(|value| value.output.as_ref())
            .unwrap_or(recipes);
        let frame_processing = frame_override
            .and_then(|value| value.processing.as_ref())
            .unwrap_or(processing)
            .effective();
        let frame_recipe = frame_override
            .and_then(|value| value.capture.as_ref())
            .unwrap_or(recipe)
            .effective_for_process(frame_processing.film_process);
        // The real backend currently uses the batch capture recipe even
        // when a legacy per-frame capture override exists. Include IR if
        // either route could create it; over-rejection is safer than
        // omitting a possible archive sidecar.
        let include_ir = base_recipe.channels == domain::Channels::Rgbi
            || frame_recipe.channels == domain::Channels::Rgbi;
        candidates.extend(frame_target_candidates(
            frame_recipes,
            *frame_index,
            include_ir,
            true,
            include_ir,
        )?);
    }
    validate_target_candidates(&candidates)
}

fn targets_match(
    expected: &std::path::Path,
    actual: &std::path::Path,
) -> Result<bool, domain::EngineError> {
    let expected = physical_target(expected)?;
    let actual = physical_target(actual)?;
    if !actual.exists {
        return Ok(false);
    }
    let same_path = expected.key == actual.key;
    let same_file = matches!((&expected.handle, &actual.handle), (Some(a), Some(b)) if a == b);
    Ok(same_path || same_file)
}

/// Checks a real bridge receipt against the same final-name resolver used
/// before dispatch. The receipt path remains the authority after it
/// matches; callers must render, persist, and package from that exact path.
#[cfg(test)]
pub(crate) fn validate_bridge_capture_receipt_paths(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
    channels: domain::Channels,
    rgb_path: &std::path::Path,
    ir_path: Option<&std::path::Path>,
    meter_path: Option<&std::path::Path>,
) -> Result<(), domain::EngineError> {
    validate_output_recipe_paths(recipes)?;
    let expected_rgb = resolve_archive_output_path(recipes, frame_index);
    validate_bridge_capture_receipt_paths_for_expected(
        &expected_rgb,
        frame_index,
        channels,
        rgb_path,
        ir_path,
        meter_path,
    )
}

/// Validates a real bridge receipt against an already-reserved exact
/// capture target. Used both for retained masters and the real backend's
/// private, job-owned working captures; neither path may be inferred from
/// a user-visible recipe after the bridge starts.
pub(crate) fn validate_bridge_capture_receipt_paths_for_expected(
    expected_rgb: &std::path::Path,
    frame_index: u32,
    channels: domain::Channels,
    rgb_path: &std::path::Path,
    ir_path: Option<&std::path::Path>,
    meter_path: Option<&std::path::Path>,
) -> Result<(), domain::EngineError> {
    if !targets_match(&expected_rgb, rgb_path)? {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "bridge RGB receipt path {} does not match the reserved frame {} capture target {}",
                rgb_path.display(),
                frame_index,
                expected_rgb.display()
            ),
        ));
    }

    let expected_ir = archive_sidecar_path(&expected_rgb, "IR")?;
    match (channels, ir_path) {
        (domain::Channels::Rgbi, Some(actual)) if targets_match(&expected_ir, actual)? => {}
        (domain::Channels::Rgbi, Some(actual)) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                "bridge IR receipt path {} does not match the reserved frame {} capture sidecar {}",
                    actual.display(),
                    frame_index,
                    expected_ir.display()
                ),
            ))
        }
        (domain::Channels::Rgbi, None) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("bridge RGBI receipt omitted frame {frame_index}'s IR sidecar"),
            ))
        }
        (domain::Channels::Rgb, Some(actual)) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "bridge RGB-only receipt unexpectedly supplied IR path {} for frame {}",
                    actual.display(),
                    frame_index
                ),
            ))
        }
        (domain::Channels::Rgb, None) => {}
    }

    if let Some(actual) = meter_path {
        let expected_meter = archive_sidecar_path(&expected_rgb, "METER")?;
        if !targets_match(&expected_meter, actual)? {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "bridge meter receipt path {} does not match the reserved frame {} sidecar {}",
                    actual.display(),
                    frame_index,
                    expected_meter.display()
                ),
            ));
        }
    }
    Ok(())
}

pub(crate) fn validate_bridge_raw_export_receipt_path(
    expected: Option<&std::path::Path>,
    actual: Option<&std::path::Path>,
    frame_index: u32,
) -> Result<(), domain::EngineError> {
    match (expected, actual) {
        (Some(expected), Some(actual)) if targets_match(expected, actual)? => Ok(()),
        (Some(expected), Some(actual)) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "bridge raw export receipt path {} does not match the reserved frame {} output {}",
                actual.display(),
                frame_index,
                expected.display()
            ),
        )),
        (Some(expected), None) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "bridge receipt omitted frame {} raw export {}",
                frame_index,
                expected.display()
            ),
        )),
        (None, Some(actual)) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "bridge receipt unexpectedly supplied raw export {} for frame {}",
                actual.display(),
                frame_index
            ),
        )),
        (None, None) => Ok(()),
    }
}

pub fn validate_frame_output_paths(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
) -> Result<
    (
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
    ),
    domain::EngineError,
> {
    validate_frame_output_paths_with_raw_ir(recipes, frame_index, true)
}

fn validate_frame_output_paths_with_raw_ir(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
    raw_ir_available: bool,
) -> Result<
    (
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
    ),
    domain::EngineError,
> {
    let candidates = frame_target_candidates(recipes, frame_index, false, false, raw_ir_available)?;
    validate_target_candidates(&candidates)?;
    let archive = recipes
        .archive
        .enabled
        .then(|| resolve_archive_output_path(recipes, frame_index));
    let positive = recipes.positive.enabled.then(|| {
        resolve_output_path(
            &recipes.positive.destination,
            &recipes.positive.filename_template,
            frame_index,
            recipes.positive.file_format,
        )
    });
    let preview = recipes.preview.enabled.then(|| {
        resolve_output_path(
            &recipes.preview.destination,
            &recipes.preview.filename_template,
            frame_index,
            recipes.preview.file_format,
        )
    });
    let raw_export = recipes
        .raw_export
        .enabled
        .then(|| resolve_raw_export_output_path(recipes, frame_index));
    let raw_export_ir = raw_export.as_ref().and_then(|path| {
        (raw_ir_available && recipes.raw_export.tiff_infrared == domain::RawTiffInfrared::Sidecar)
            .then(|| raw_export_ir_sidecar_path(path))
    });
    Ok((archive, positive, preview, raw_export, raw_export_ir))
}

/// Resolves the roll-level naming tokens before a backend starts work. The
/// remaining `####` run is intentionally left intact for the established
/// simulator and bridge frame-number resolvers. This keeps old templates
/// such as `Archive_####` byte-for-byte compatible.
pub fn materialize_output_filename_tokens(
    recipes: &mut domain::OutputRecipe,
    metadata: &domain::MetadataSet,
) {
    for template in [
        &mut recipes.archive.filename_template,
        &mut recipes.positive.filename_template,
        &mut recipes.preview.filename_template,
        &mut recipes.raw_export.filename_template,
    ] {
        *template = materialize_filename_tokens(template, metadata);
    }
}

pub fn materialize_filename_tokens(template: &str, metadata: &domain::MetadataSet) -> String {
    let (year, month, day) = metadata_date_tokens(metadata.date.as_ref());
    let substitutions = [
        (
            "$FilmStock",
            filename_component(metadata.film_stock.as_deref().unwrap_or("UnknownFilm")),
        ),
        (
            "$Camera",
            filename_component(metadata.camera.as_deref().unwrap_or("UnknownCamera")),
        ),
        (
            "$Lens",
            filename_component(metadata.lens.as_deref().unwrap_or("UnknownLens")),
        ),
        ("$Year", year),
        ("$Month", month),
        ("$Day", day),
        // `$Frame` is translated to the established hash-run convention so
        // both the simulator and the real bridge preserve their proven
        // frame-number substitution behavior.
        // The bridge's resolver intentionally recognizes the legacy
        // four-character run only. Keep that wire contract here: using a
        // shorter run would leave every real slot pointed at the literal
        // same `##` destination before the scanner moves.
        ("$Frame", "####".to_string()),
    ];
    substitutions
        .into_iter()
        .fold(template.to_string(), |value, (token, replacement)| {
            value.replace(token, &replacement)
        })
}

fn filename_component(value: &str) -> String {
    let value = value.replace("f/", "F").replace("F/", "F");
    let mut output = String::with_capacity(value.len());
    let mut previous_separator = false;
    for character in value.chars() {
        let forbidden = matches!(character, '/' | '\\' | ':' | '\0' | '\n' | '\r');
        if character.is_whitespace() {
            continue;
        }
        if forbidden {
            if !previous_separator {
                previous_separator = true;
            }
        } else {
            output.push(character);
            previous_separator = false;
        }
    }
    let output = output.trim_matches(|c| c == '.' || c == '-');
    if output.is_empty() {
        "Unknown".to_string()
    } else {
        output.to_string()
    }
}

fn metadata_date_tokens(date: Option<&domain::PartialDate>) -> (String, String, String) {
    match date {
        Some(domain::PartialDate::Exact { date }) => {
            let parts: Vec<_> = date.split('-').collect();
            if parts.len() == 3
                && parts
                    .iter()
                    .all(|part| part.chars().all(|c| c.is_ascii_digit()))
            {
                (
                    parts[0].to_string(),
                    parts[1].to_string(),
                    parts[2].to_string(),
                )
            } else {
                (
                    "UnknownYear".into(),
                    "UnknownMonth".into(),
                    "UnknownDay".into(),
                )
            }
        }
        Some(domain::PartialDate::MonthOnly { year, month }) => (
            format!("{year:04}"),
            format!("{month:02}"),
            "UnknownDay".into(),
        ),
        Some(domain::PartialDate::YearOnly { year }) => (
            format!("{year:04}"),
            "UnknownMonth".into(),
            "UnknownDay".into(),
        ),
        Some(domain::PartialDate::Unknown) | None => (
            "UnknownYear".into(),
            "UnknownMonth".into(),
            "UnknownDay".into(),
        ),
    }
}

// ---------------------------------------------------------------------
// Positive rendering (nikonlook wiring)
// ---------------------------------------------------------------------

/// C-41 color-negative frames run through the real, parity-tested
/// nikonlook color pipeline (Phase 14). Positive/Kodachrome are already
/// positive and pass through unchanged. B&W negatives use a neutral RGB
/// average followed by inversion, while C-41 alone uses nikonlook because
/// its matrix+curves are dye-specific.
///
/// `width` is the decoded raster's width (`raw.len() / width` is its
/// height) — nikonlook v2's blind gain estimator samples on a 2D grid and
/// needs it; `exposure_10ns` is the frame's hardware exposure in 10ns
/// ticks when the caller has it (real backend only, env-gated — see
/// `real_backend.rs`), `None` otherwise (simulator, or the exposure path
/// opted out), which routes v2 to its blind fallback instead of the
/// hardware-exposure inverse.
///
/// Returns the rendered positive plus, for a C41 frame, the nikonlook
/// provenance (bundle version, which Layer-A path actually ran, the exact
/// gains applied) so a caller can surface it in the frame's receipt — see
/// `domain::NikonlookProvenance`. `None` for every non-C41 process, which
/// never touches nikonlook at all. `exposure_10ns.is_some()` alone is NOT
/// enough to determine which path ran: `estimate_gains` silently falls
/// back to blind on an unusable exposure value (Finding 5), so the actual
/// path is derived here via `nikonlook::exposure_is_usable` — the same
/// predicate `estimate_gains` itself gates on — rather than assumed from
/// the caller's input.
fn render_positive(
    film_process: domain::FilmProcess,
    raw: &[[f64; 3]],
    width: usize,
    exposure_10ns: Option<[f64; 3]>,
) -> Result<(Vec<[f64; 3]>, Option<domain::NikonlookProvenance>), domain::EngineError> {
    match film_process {
        domain::FilmProcess::C41ColorNegative => {
            let bundle = crate::processing::nikonlook::load_bundle().map_err(|err| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("nikonlook bundle failed to load: {err}"),
                )
            })?;
            let k =
                crate::processing::nikonlook::estimate_gains(raw, width, exposure_10ns, &bundle)
                    .map_err(|err| {
                        domain::EngineError::new(
                            protocol::ErrorCode::Internal,
                            format!("nikonlook gain estimation failed: {err}"),
                        )
                    })?;
            let positive = crate::processing::nikonlook::apply(raw, k, &bundle);
            let layer_a_path =
                if exposure_10ns.is_some_and(crate::processing::nikonlook::exposure_is_usable) {
                    domain::NikonlookLayerAPath::HardwareExposure
                } else {
                    domain::NikonlookLayerAPath::Blind
                };
            let provenance = domain::NikonlookProvenance {
                bundle_version: bundle.bundle_version.clone(),
                layer_a_path,
                gains: k,
            };
            Ok((positive, Some(provenance)))
        }
        domain::FilmProcess::BwNegative => Ok((
            raw.iter()
                .map(|pixel| {
                    let inverted = 1.0 - (pixel[0] + pixel[1] + pixel[2]) / 3.0;
                    [inverted, inverted, inverted]
                })
                .collect(),
            None,
        )),
        domain::FilmProcess::Positive | domain::FilmProcess::Kodachrome => Ok((raw.to_vec(), None)),
    }
}

/// Runs the operator-selected local Cool Colors checkout for the experimental
/// Nikon OEM replay. This is deliberately an adapter, not a second guessed
/// color fit: the checkout owns the captured CML4 assets and verifies the
/// three builder LUTs. The source archive and every supplied path stay local.
fn render_nikon_oem_replay(
    archive_rgb_path: &Path,
    private_workspace: &Path,
    inputs: &domain::CoolColorsInputs,
) -> Result<(Vec<[f64; 3]>, u32, u32), domain::EngineError> {
    let required = |value: &Option<String>, label: &str| -> Result<PathBuf, domain::EngineError> {
        let path = value
            .as_ref()
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .ok_or_else(|| {
                domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!("XXX (Testing) Nikon OEM replay needs {label}"),
                )
            })?;
        if !path.exists() {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "XXX (Testing) Nikon OEM replay cannot find {label}: {}",
                    path.display()
                ),
            ));
        }
        Ok(path)
    };
    let checkout = required(&inputs.checkout_path, "a local Cool Colors folder")?;
    let red = required(&inputs.builder_red_path, "the red builder LUT")?;
    let green = required(&inputs.builder_green_path, "the green builder LUT")?;
    let blue = required(&inputs.builder_blue_path, "the blue builder LUT")?;
    let entrypoint = checkout.join("invert_c41.py");
    if !entrypoint.is_file() {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "XXX (Testing) expected Cool Colors' invert_c41.py in {}",
                checkout.display()
            ),
        ));
    }

    let output = private_workspace.join("positive.tif");
    let receipt = private_workspace.join("positive.tif.receipt.json");
    let reserve = |path: &Path| -> Result<std::fs::File, domain::EngineError> {
        let mut options = std::fs::OpenOptions::new();
        options.read(true).write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        options.open(path).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "reserve private Nikon replay leaf {}: {error}",
                    path.display()
                ),
            )
        })
    };
    let output_handle = reserve(&output)?;
    let receipt_handle = match reserve(&receipt) {
        Ok(file) => file,
        Err(error) => {
            let _ = std::fs::remove_file(&output);
            return Err(error);
        }
    };
    let result = (|| {
        let command = Command::new("python3")
            .arg(&entrypoint)
            .arg(archive_rgb_path)
            .arg(&output)
            .arg("--builder")
            .arg(red)
            .arg(green)
            .arg(blue)
            .arg("--nikon-cms")
            .output()
            .map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("XXX (Testing) could not start local Cool Colors: {error}"),
                )
            })?;
        if !command.status.success() {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "XXX (Testing) Nikon OEM replay refused this scan: {}",
                    String::from_utf8_lossy(&command.stderr).trim()
                ),
            ));
        }
        output_handle.sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("sync private Nikon replay output: {error}"),
            )
        })?;
        receipt_handle.sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("sync private Nikon replay receipt: {error}"),
            )
        })?;
        verify_published_file_identity(&output, &output_handle)?;
        verify_published_file_identity(&receipt, &receipt_handle)?;
        let mut output_reader = output_handle.try_clone().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("retain private Nikon replay output: {error}"),
            )
        })?;
        output_reader
            .seek(std::io::SeekFrom::Start(0))
            .map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("rewind private Nikon replay output: {error}"),
                )
            })?;
        let image = image_io::read_rgb16_file(output_reader).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("XXX (Testing) could not read the local Nikon replay: {error}"),
            )
        })?;
        verify_published_file_identity(&output, &output_handle)?;
        let pixels = image
            .pixels
            .into_iter()
            .map(|pixel| {
                [
                    pixel[0] as f64 / 65535.0,
                    pixel[1] as f64 / 65535.0,
                    pixel[2] as f64 / 65535.0,
                ]
            })
            .collect();
        Ok((pixels, image.width, image.height))
    })();
    let _ = std::fs::remove_file(&output);
    let _ = std::fs::remove_file(&receipt);
    result
}

/// Gives the experimental external replay adapter a private snapshot copied
/// from the held bridge-archive descriptor.  Passing the bridge pathname
/// directly would reintroduce an ABA replacement window even though the main
/// decoder uses the held descriptor.
fn render_nikon_oem_replay_from_proof(
    archive: &PublishedFileProof,
    inputs: &domain::CoolColorsInputs,
) -> Result<(Vec<[f64; 3]>, u32, u32), domain::EngineError> {
    let temporary_root = std::fs::canonicalize(std::env::temp_dir()).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("resolve private Nikon replay temp root: {error}"),
        )
    })?;
    let (attempt, _) = create_private_directory(&temporary_root, "nikon-replay-source")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&attempt, std::fs::Permissions::from_mode(0o700)).map_err(
            |error| {
                let _ = std::fs::remove_dir_all(&attempt);
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!(
                        "failed to restrict private Nikon replay source {}: {error}",
                        attempt.display()
                    ),
                )
            },
        )?;
    }
    let snapshot = attempt.join("archive.tif");
    let result = (|| {
        let mut source = archive.try_clone_file()?;
        source.seek(std::io::SeekFrom::Start(0)).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to seek held Nikon replay source: {error}"),
            )
        })?;
        let source_before = source.metadata().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to inspect held Nikon replay source: {error}"),
            )
        })?;
        let mut options = std::fs::OpenOptions::new();
        options.read(true).write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut destination = options.open(&snapshot).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to reserve private Nikon replay snapshot {}: {error}",
                    snapshot.display()
                ),
            )
        })?;
        let copied = std::io::copy(&mut source, &mut destination).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to copy held Nikon replay source: {error}"),
            )
        })?;
        destination.sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to sync private Nikon replay source: {error}"),
            )
        })?;
        let source_after = source.metadata().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to re-inspect held Nikon replay source: {error}"),
            )
        })?;
        if publication_identity(&source, &source_before)
            != publication_identity(&source, &source_after)
            || source_before.len() != source_after.len()
            || copied != source_before.len()
        {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::Internal,
                "bridge archive changed while creating the private Nikon replay snapshot",
            )
            .with_recoverable(true));
        }
        sync_output_directory(&attempt).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to sync private Nikon replay directory: {error}"),
            )
        })?;
        render_nikon_oem_replay(&snapshot, &attempt, inputs)
    })();
    let _ = std::fs::remove_dir_all(&attempt);
    result
}

fn exact_nikon_requested(inputs: &domain::CoolColorsInputs) -> bool {
    [
        &inputs.checkout_path,
        &inputs.builder_red_path,
        &inputs.builder_green_path,
        &inputs.builder_blue_path,
    ]
    .iter()
    .any(|path| path.as_ref().is_some_and(|path| !path.is_empty()))
}

/// Noritsu's recovered output curve is deliberately strong on its own. Lab
/// operators normally temper it with exposure and print adjustments, so this
/// export mode mixes only a restrained portion over the Nikon-positive base.
/// That retains the warmer, denser Noritsu character without crushing the
/// frame into the high-contrast display look.
const NORITSU_LAB_CURVE: [f64; 20] = [
    0.0,
    76.0 / 65535.0,
    203.0 / 65535.0,
    445.0 / 65535.0,
    880.0 / 65535.0,
    1583.0 / 65535.0,
    2633.0 / 65535.0,
    4108.0 / 65535.0,
    6187.0 / 65535.0,
    9214.0 / 65535.0,
    13545.0 / 65535.0,
    19538.0 / 65535.0,
    27390.0 / 65535.0,
    36346.0 / 65535.0,
    45295.0 / 65535.0,
    53128.0 / 65535.0,
    58736.0 / 65535.0,
    61539.0 / 65535.0,
    63657.0 / 65535.0,
    1.0,
];
const NORITSU_LAB_STRENGTH: f64 = 0.30;

fn apply_noritsu_lab_mode(pixels: Vec<[f64; 3]>) -> Vec<[f64; 3]> {
    pixels
        .into_iter()
        .map(|pixel| {
            pixel.map(|value| {
                let clamped = value.clamp(0.0, 1.0);
                let position = clamped * (NORITSU_LAB_CURVE.len() - 1) as f64;
                let left = position.floor() as usize;
                let right = (left + 1).min(NORITSU_LAB_CURVE.len() - 1);
                let mapped = NORITSU_LAB_CURVE[left]
                    + (NORITSU_LAB_CURVE[right] - NORITSU_LAB_CURVE[left])
                        * (position - left as f64);
                value * (1.0 - NORITSU_LAB_STRENGTH) + mapped * NORITSU_LAB_STRENGTH
            })
        })
        .collect()
}

/// Conservative RGB-only, classical-CV cleanup for isolated bright/dark B&W
/// dust impulses. Runs after B&W inversion on derivatives only; archive pixels
/// are never passed here. A low-variance 5×5 outer ring supplies the local
/// background estimate, which fails closed around edges and grain clusters.
pub fn software_dust_remove_bw(raw: &[[f64; 3]], width: u32, height: u32) -> Vec<[f64; 3]> {
    software_dust_remove_bw_owned(raw.to_vec(), width, height)
}

/// Owned-buffer variant used by rendering. It mutates the already-owned
/// positive derivative, avoiding a second full RGB f64 buffer; the only
/// frame-sized auxiliary allocation is the one-byte candidate mask.
pub fn software_dust_remove_bw_owned(
    mut raw: Vec<[f64; 3]>,
    width: u32,
    height: u32,
) -> Vec<[f64; 3]> {
    if width < 5 || height < 5 || raw.len() != (width as usize).saturating_mul(height as usize) {
        return raw;
    }
    // One byte/pixel candidate mask; no per-pixel RGB background cache.
    // At a full 3946×5959 frame this auxiliary buffer is ~23.5 MB.
    let luminance = |pixel: [f64; 3]| (pixel[0] + pixel[1] + pixel[2]) / 3.0;
    // `1` and `-1` retain each candidate's residual polarity. Components
    // and their conservative expansion must never merge a bright impulse
    // into an adjacent dark image detail (or the converse).
    let mut candidates = vec![0i8; raw.len()];
    // A 5x5 local ring gives a compact 1-3 pixel dust component a stable
    // background estimate while an edge's mixed ring fails closed.
    for y in 2..height - 2 {
        for x in 2..width - 2 {
            let index = (y * width + x) as usize;
            let mut count = 0.0;
            let mut min = f64::INFINITY;
            let mut max = f64::NEG_INFINITY;
            let mut sums = [0.0; 3];
            for dy in -2i32..=2 {
                for dx in -2i32..=2 {
                    if dx.abs() <= 1 && dy.abs() <= 1 {
                        continue;
                    }
                    let pixel =
                        raw[((y as i32 + dy) as u32 * width + (x as i32 + dx) as u32) as usize];
                    let value = luminance(pixel);
                    min = min.min(value);
                    max = max.max(value);
                    sums[0] += pixel[0];
                    sums[1] += pixel[1];
                    sums[2] += pixel[2];
                    count += 1.0;
                }
            }
            let background = [sums[0] / count, sums[1] / count, sums[2] / count];
            let residual = luminance(raw[index]) - luminance(background);
            if max - min <= 0.06 && residual.abs() >= 0.22 {
                candidates[index] = if residual.is_sign_positive() { 1 } else { -1 };
            }
        }
    }
    let mut visited = vec![false; raw.len()];
    for start in 0..raw.len() {
        if visited[start] || candidates[start] == 0 {
            continue;
        }
        let candidate_sign = candidates[start];
        let mut stack = vec![start];
        let mut component = Vec::new();
        visited[start] = true;
        while let Some(index) = stack.pop() {
            component.push(index);
            let x = index % width as usize;
            let y = index / width as usize;
            for dy in y.saturating_sub(1)..=(y + 1).min(height as usize - 1) {
                for dx in x.saturating_sub(1)..=(x + 1).min(width as usize - 1) {
                    let neighbor = dy * width as usize + dx;
                    if !visited[neighbor] && candidates[neighbor] == candidate_sign {
                        visited[neighbor] = true;
                        stack.push(neighbor);
                    }
                }
            }
        }
        if component.len() <= 9 {
            let seed = component[0];
            let sx = seed % width as usize;
            let sy = seed / width as usize;
            let mut sums = [0.0; 3];
            let mut count = 0.0;
            for dy in sy - 2..=sy + 2 {
                for dx in sx - 2..=sx + 2 {
                    if (dx as isize - sx as isize).abs() <= 1
                        && (dy as isize - sy as isize).abs() <= 1
                    {
                        continue;
                    }
                    let pixel = raw[dy * width as usize + dx];
                    sums[0] += pixel[0];
                    sums[1] += pixel[1];
                    sums[2] += pixel[2];
                    count += 1.0;
                }
            }
            let replacement = [sums[0] / count, sums[1] / count, sums[2] / count];
            let seed_residual = luminance(raw[seed]) - luminance(replacement);
            // Expand a conservative accepted seed across an adjacent compact
            // same-polarity blob. This catches 3x3 dust whose corner ring is
            // contaminated by its own component, without treating a mixed
            // edge as dust (mixed edges never produced the seed).
            let mut cursor = 0;
            while cursor < component.len() && component.len() < 9 {
                let index = component[cursor];
                let x = index % width as usize;
                let y = index / width as usize;
                for dy in y.saturating_sub(1)..=(y + 1).min(height as usize - 1) {
                    for dx in x.saturating_sub(1)..=(x + 1).min(width as usize - 1) {
                        let neighbor = dy * width as usize + dx;
                        let residual = luminance(raw[neighbor]) - luminance(replacement);
                        if !component.contains(&neighbor)
                            && residual.abs() >= 0.22
                            && residual.signum() == seed_residual.signum()
                        {
                            component.push(neighbor);
                            if component.len() == 9 {
                                break;
                            }
                        }
                    }
                    if component.len() == 9 {
                        break;
                    }
                }
                cursor += 1;
            }
            for index in component {
                raw[index] = replacement;
            }
        }
    }
    raw
}

// ---------------------------------------------------------------------
// Real-archive derivative rendering
// ---------------------------------------------------------------------

/// The live ScanStudio/CoolscanPy storage transform whose stored RGB raster
/// is already in Nikon-render-parity orientation.
pub const STORAGE_TRANSFORM_SWAPAXES01: &str =
    "swapaxes01-scanner-native-to-nikon-render-parity-v2";

fn validate_real_derivative_output_paths(
    archive_rgb_path: &std::path::Path,
    frame_index: u32,
    recipes: &domain::OutputRecipe,
) -> Result<(Option<std::path::PathBuf>, Option<std::path::PathBuf>), domain::EngineError> {
    validate_output_recipe_paths(recipes)?;
    let mut candidates = vec![
        TargetCandidate {
            slot: frame_index,
            role: "actual archive RGB source",
            path: archive_rgb_path.to_path_buf(),
            create_only: false,
        },
        TargetCandidate {
            slot: frame_index,
            role: "actual archive IR sidecar",
            path: archive_sidecar_path(archive_rgb_path, "IR")?,
            create_only: false,
        },
        TargetCandidate {
            slot: frame_index,
            role: "actual archive meter sidecar",
            path: archive_sidecar_path(archive_rgb_path, "METER")?,
            create_only: false,
        },
    ];
    let positive = recipes.positive.enabled.then(|| {
        resolve_output_path(
            &recipes.positive.destination,
            &recipes.positive.filename_template,
            frame_index,
            recipes.positive.file_format,
        )
    });
    let preview = recipes.preview.enabled.then(|| {
        resolve_output_path(
            &recipes.preview.destination,
            &recipes.preview.filename_template,
            frame_index,
            recipes.preview.file_format,
        )
    });
    if let Some(path) = positive.as_ref() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "positive",
            path: path.clone(),
            create_only: false,
        });
    }
    if let Some(path) = preview.as_ref() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "preview",
            path: path.clone(),
            create_only: false,
        });
    }
    validate_target_candidates(&candidates)?;
    Ok((positive, preview))
}

/// Renders requested derivatives from an existing real-hardware RGB archive.
///
/// The archive is opened read-only and never rewritten. Unknown orientation,
/// unsupported color-profile requests, and approved crops without a detected
/// boundary are refused rather than guessed or silently ignored.
pub fn render_derivative_from_archive(
    archive_rgb_path: &std::path::Path,
    frame_index: u32,
    film_process: domain::FilmProcess,
    recipes: &domain::OutputRecipe,
    storage_transform: Option<&str>,
    storage_transform_override: Option<&str>,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
    resolution_dpi: u32,
) -> Result<WrittenPaths, domain::EngineError> {
    let processing = domain::ProcessingRecipe {
        film_process,
        ..domain::ProcessingRecipe::default()
    };
    render_derivative_from_archive_with_processing(
        archive_rgb_path,
        frame_index,
        &processing,
        recipes,
        storage_transform,
        storage_transform_override,
        detected_boundary,
        alignment,
        // This convenience wrapper has no hardware-exposure metadata to
        // pass through — callers that have it use the _with_processing
        // form directly (see real_backend.rs).
        None,
        resolution_dpi,
    )
}

/// Processing-aware real derivative path. The RGB archive is only read and
/// never rewritten; optional B&W dust cleanup is applied after inversion to
/// the regenerable positive/preview buffers. `exposure_10ns` is the frame's
/// hardware exposure (10ns ticks, RGB order) when the caller has it and has
/// opted into the exposure path — see `render_positive` and
/// `real_backend.rs`.
///
/// `resolution_dpi` is the capture recipe's DPI (`CaptureRecipe.resolution_dpi`)
/// and is embedded into TIFF derivatives as their XResolution/YResolution so
/// the output carries the same scale as the capture that produced it.
pub fn render_derivative_from_archive_with_processing(
    archive_rgb_path: &std::path::Path,
    frame_index: u32,
    processing: &domain::ProcessingRecipe,
    recipes: &domain::OutputRecipe,
    storage_transform: Option<&str>,
    storage_transform_override: Option<&str>,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
    exposure_10ns: Option<[f64; 3]>,
    resolution_dpi: u32,
) -> Result<WrittenPaths, domain::EngineError> {
    let fallback_recipe = domain::CaptureRecipe {
        channels: domain::Channels::Rgbi,
        ..domain::CaptureRecipe::default()
    };
    let mut fallback_output = recipes.clone();
    if fallback_output.archive.enabled {
        let parent = archive_rgb_path.parent().ok_or_else(|| {
            output_authority_error("real archive source has no parent destination")
        })?;
        let leaf = archive_rgb_path
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| output_authority_error("real archive source has no UTF-8 leaf name"))?;
        fallback_output.archive.destination = parent.display().to_string();
        fallback_output.archive.filename_template = leaf.to_string();
    }
    let mut fallback_authorities = acquire_job_output_authorities(
        None,
        &[frame_index],
        &fallback_recipe,
        &fallback_output,
        &std::collections::HashMap::new(),
    )?;
    if recipes.archive.enabled {
        let archive =
            authorize_independent_leaf(archive_rgb_path.to_path_buf(), "existing archive RGB")?;
        let frame = fallback_authorities
            .frames
            .get_mut(&frame_index)
            .expect("fallback acquisition inserted requested frame");
        frame.archive = Some(archive);
        frame.archive_ir = None;
        frame.archive_meter = None;
    }
    render_derivative_from_archive_with_processing_authorized(
        archive_rgb_path,
        None,
        None,
        frame_index,
        processing,
        recipes,
        storage_transform,
        storage_transform_override,
        detected_boundary,
        alignment,
        exposure_10ns,
        resolution_dpi,
        fallback_authorities.frame(frame_index)?,
    )
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn render_derivative_from_archive_with_processing_authorized(
    archive_rgb_path: &std::path::Path,
    archive_ir_path: Option<&std::path::Path>,
    archive_meter_path: Option<&std::path::Path>,
    frame_index: u32,
    processing: &domain::ProcessingRecipe,
    recipes: &domain::OutputRecipe,
    storage_transform: Option<&str>,
    storage_transform_override: Option<&str>,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
    exposure_10ns: Option<[f64; 3]>,
    resolution_dpi: u32,
    authorities: &FrameOutputAuthorities,
) -> Result<WrittenPaths, domain::EngineError> {
    let derivative_transform = alignment
        .map(|value| value.derivative_transform)
        .unwrap_or_default();
    validate_derivative_transform(derivative_transform)?;

    if !recipes.archive.enabled && !recipes.positive.enabled && !recipes.preview.enabled {
        return Ok(WrittenPaths {
            archive_path: None,
            positive_path: None,
            preview_path: None,
            raw_negative_path: None,
            raw_negative_ir_path: None,
            metadata_publications: MetadataPublicationProofs::default(),
            nikonlook: None,
            auto_crop: None,
            derivative_transform,
        });
    }

    // The bridge capture is always retained by an already-open no-follow
    // descriptor before any copy or decode. Real jobs route it through a
    // private workspace, then publish byte-exact retained masters through
    // the project-root-held authority. Low-level callers whose source is
    // already the authorized final leaf retain that exact proof in place.
    let archive_source_proof = open_existing_file_proof(archive_rgb_path)?;
    let mut archive_existing_proof = None;
    let archive_staged = if let Some(output) = authorities.archive.as_ref() {
        if source_matches_authorized_final(archive_rgb_path, output)? {
            archive_existing_proof = Some(PublishedFileProof {
                final_path: output.final_path.clone(),
                file: archive_source_proof.try_clone_file()?,
            });
            None
        } else {
            Some(stage_authorized_source(
                output,
                &archive_source_proof,
                "archive-rgb-copy",
            )?)
        }
    } else {
        None
    };
    let mut archive_ir_existing_proof = None;
    let archive_ir_staged = if let (Some(source_path), Some(output)) =
        (archive_ir_path, authorities.archive_ir.as_ref())
    {
        let source = open_existing_file_proof(source_path)?;
        if source_matches_authorized_final(source_path, output)? {
            archive_ir_existing_proof = Some(PublishedFileProof {
                final_path: output.final_path.clone(),
                file: source.try_clone_file()?,
            });
            None
        } else {
            Some(stage_authorized_source(output, &source, "archive-ir-copy")?)
        }
    } else {
        None
    };
    let mut archive_meter_existing_proof = None;
    let archive_meter_staged = if let (Some(source_path), Some(output)) =
        (archive_meter_path, authorities.archive_meter.as_ref())
    {
        let source = open_existing_file_proof(source_path)?;
        if source_matches_authorized_final(source_path, output)? {
            archive_meter_existing_proof = Some(PublishedFileProof {
                final_path: output.final_path.clone(),
                file: source.try_clone_file()?,
            });
            None
        } else {
            Some(stage_authorized_source(
                output,
                &source,
                "archive-meter-copy",
            )?)
        }
    } else {
        None
    };
    let [archive_published, archive_ir_published, archive_meter_published] =
        publish_retained_archive_set([&archive_staged, &archive_ir_staged, &archive_meter_staged])?;
    let archive_proof = archive_existing_proof.or(archive_published);
    let archive_ir_proof = archive_ir_existing_proof.or(archive_ir_published);
    let archive_meter_proof = archive_meter_existing_proof.or(archive_meter_published);
    if !recipes.positive.enabled && !recipes.preview.enabled {
        return Ok(WrittenPaths {
            archive_path: authorities
                .archive
                .as_ref()
                .map(|output| output.final_path.clone()),
            positive_path: None,
            preview_path: None,
            raw_negative_path: None,
            raw_negative_ir_path: None,
            metadata_publications: MetadataPublicationProofs {
                archive: archive_proof,
                archive_ir: archive_ir_proof,
                archive_meter: archive_meter_proof,
                ..MetadataPublicationProofs::default()
            },
            nikonlook: None,
            auto_crop: None,
            derivative_transform,
        });
    }

    // Validate against the bridge receipt's actual archive authority before
    // opening that source or creating any derivative. A recipe-predicted
    // archive path is not evidence of where hardware really wrote.
    let (preflight_positive_path, preflight_preview_path) =
        validate_real_derivative_output_paths(archive_rgb_path, frame_index, recipes)?;
    if recipes.positive.color_profile != domain::OutputColorProfile::AdobeRgb1998 {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "positive color setting {:?} is unsupported: nikonlook writes values in the Adobe RGB (1998) color space and no alternate profile-conversion path exists",
                recipes.positive.color_profile
            ),
        ));
    }

    match storage_transform_override.or(storage_transform) {
        Some(STORAGE_TRANSFORM_SWAPAXES01) => {}
        Some(other) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "unsupported storageTransform {other:?}: expected {STORAGE_TRANSFORM_SWAPAXES01:?}; refusing to guess an orientation"
                ),
            ));
        }
        None => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                "missing storageTransform: cannot determine archive raster orientation; refusing to guess"
                    .to_string(),
            ));
        }
    }

    if alignment.is_some_and(|value| value.approved) && detected_boundary.is_none() {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            "approved frame alignment has no detected boundary on this real archive; refusing to silently drop the crop"
                .to_string(),
        ));
    }

    let raw_image =
        image_io::read_rgb16_file(archive_source_proof.try_clone_file()?).map_err(|err| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to read RGB archive at {}: {err}",
                    archive_rgb_path.display()
                ),
            )
        })?;
    let width = raw_image.width;
    let height = raw_image.height;
    let raw_linear: Vec<[f64; 3]> = raw_image
        .pixels
        .iter()
        .map(|pixel| {
            [
                pixel[0] as f64 / 65535.0,
                pixel[1] as f64 / 65535.0,
                pixel[2] as f64 / 65535.0,
            ]
        })
        .collect();
    drop(raw_image);

    // Detection reads the raw archive domain. An approved manual alignment
    // owns the crop, so detection is skipped rather than merely ignored.
    let alignment_owns_crop = alignment.is_some_and(|value| value.approved);
    let auto_crop_outcome = if recipes.auto_crop {
        if alignment_owns_crop {
            Some(auto_crop_deferred_to_alignment(width, height))
        } else {
            Some(detect_auto_crop(&raw_linear, width, height))
        }
    } else {
        None
    };

    let (positive_full, nikonlook) = match recipes.c41_render.target {
        domain::C41RenderTarget::NikonOemReplay => {
            if processing.film_process != domain::FilmProcess::C41ColorNegative {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    "XXX (Testing) Nikon OEM replay only supports C-41 color-negative scans"
                        .to_string(),
                ));
            }
            let (positive, replay_width, replay_height) = render_nikon_oem_replay_from_proof(
                &archive_source_proof,
                &recipes.c41_render.cool_colors,
            )?;
            if replay_width != width || replay_height != height {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!(
                        "XXX (Testing) Nikon OEM replay changed the frame dimensions from {width}x{height} to {replay_width}x{replay_height}"
                    ),
                ));
            }
            (positive, None)
        }
        domain::C41RenderTarget::Nikonlook => {
            let cool_colors = &recipes.c41_render.cool_colors;
            if exact_nikon_requested(cool_colors) {
                if processing.film_process != domain::FilmProcess::C41ColorNegative {
                    return Err(domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        "exact Nikon replay only supports C-41 color-negative scans".to_string(),
                    ));
                }
                let (positive, replay_width, replay_height) =
                    render_nikon_oem_replay_from_proof(&archive_source_proof, cool_colors)?;
                if replay_width != width || replay_height != height {
                    return Err(domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        format!(
                            "exact Nikon replay changed the frame dimensions from {width}x{height} to {replay_width}x{replay_height}"
                        ),
                    ));
                }
                (positive, None)
            } else {
                render_positive(
                    processing.film_process,
                    &raw_linear,
                    width as usize,
                    exposure_10ns,
                )?
            }
        }
        domain::C41RenderTarget::NoritsuLs600 => {
            let cool_colors = &recipes.c41_render.cool_colors;
            let (nikon, provenance) = if exact_nikon_requested(cool_colors) {
                if processing.film_process != domain::FilmProcess::C41ColorNegative {
                    return Err(domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        "Noritsu Lab Mode only supports C-41 color-negative scans".to_string(),
                    ));
                }
                let (positive, replay_width, replay_height) =
                    render_nikon_oem_replay_from_proof(&archive_source_proof, cool_colors)?;
                if replay_width != width || replay_height != height {
                    return Err(domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        "exact Nikon replay changed the frame dimensions before Noritsu Lab Mode"
                            .to_string(),
                    ));
                }
                (positive, None)
            } else {
                render_positive(
                    processing.film_process,
                    &raw_linear,
                    width as usize,
                    exposure_10ns,
                )?
            };
            (apply_noritsu_lab_mode(nikon), provenance)
        }
        target => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("XXX (Testing) {target:?} export is not wired yet; choose Noritsu Lab Mode or ScanStudio NikonLook"),
            ));
        }
    };
    drop(raw_linear);
    let positive_full = if processing.film_process == domain::FilmProcess::BwNegative
        && processing.software_dust_removal_bw
    {
        software_dust_remove_bw_owned(positive_full, width, height)
    } else {
        positive_full
    };

    let (mut positive_raw, mut positive_width, mut positive_height) = match alignment {
        Some(value) if value.approved => apply_alignment_crop(
            &positive_full,
            width,
            height,
            detected_boundary,
            Some(value),
        ),
        _ => match &auto_crop_outcome {
            Some(outcome) if outcome.applied => {
                let roi = outcome
                    .roi
                    .as_ref()
                    .expect("applied auto-crop outcome carries its ROI");
                crop_to_roi(&positive_full, width, roi)
            }
            _ => (positive_full, width, height),
        },
    };
    (positive_width, positive_height) = apply_derivative_transform_in_place(
        &mut positive_raw,
        positive_width,
        positive_height,
        derivative_transform,
    )?;

    let archive_path = authorities
        .archive
        .as_ref()
        .map(|output| output.final_path.clone());
    let mut positive_path = None;
    let mut preview_path = None;
    let mut positive_proof = None;
    let mut preview_proof = None;

    // The color-profile contract (ICC) and physical scale (DPI) differ per
    // output: the full-resolution positive is at `resolution_dpi`; the
    // downsampled preview must not claim that DPI. ICC attaches only for C41.
    let positive_metadata = DerivativeMetadata::positive(processing.film_process, resolution_dpi);
    let preview_metadata = DerivativeMetadata::preview(processing.film_process);

    if recipes.positive.enabled {
        let output = authorities.positive.as_ref().ok_or_else(|| {
            output_authority_error("enabled positive has no held destination authority")
        })?;
        let _ = preflight_positive_path.as_ref();
        positive_proof = Some(write_derivative_authorized(
            output,
            &positive_raw,
            positive_width,
            positive_height,
            recipes.positive.file_format,
            &positive_metadata,
        )?);
        positive_path = Some(output.final_path.clone());
    }

    if recipes.preview.enabled {
        let (preview_width, preview_height) = downsample_dimensions(
            positive_width,
            positive_height,
            recipes.preview.max_long_edge_px,
        );
        let preview_raw = downsample_nearest(
            &positive_raw,
            positive_width,
            positive_height,
            preview_width,
            preview_height,
        );
        let output = authorities.preview.as_ref().ok_or_else(|| {
            output_authority_error("enabled preview has no held destination authority")
        })?;
        let _ = preflight_preview_path.as_ref();
        preview_proof = Some(write_derivative_authorized(
            output,
            &preview_raw,
            preview_width,
            preview_height,
            recipes.preview.file_format,
            &preview_metadata,
        )?);
        preview_path = Some(output.final_path.clone());
    }

    // The bridge archive identity held before decode must still own the final
    // no-follow leaf after every derivative publication.  A replacement is a
    // typed render failure and can never be ratified into a receipt.
    verify_published_file_identity(archive_rgb_path, &archive_source_proof.file)?;
    Ok(WrittenPaths {
        archive_path,
        positive_path,
        preview_path,
        raw_negative_path: None,
        raw_negative_ir_path: None,
        metadata_publications: MetadataPublicationProofs {
            archive: archive_proof,
            archive_ir: archive_ir_proof,
            archive_meter: archive_meter_proof,
            positive: positive_proof,
            preview: preview_proof,
        },
        nikonlook,
        auto_crop: auto_crop_outcome,
        derivative_transform,
    })
}

fn validate_derivative_transform(
    transform: domain::DerivativeTransform,
) -> Result<(), domain::EngineError> {
    if transform.is_supported() {
        Ok(())
    } else {
        Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "unsupported derivative rotation {}: expected 0, 90, 180, or 270 degrees",
                transform.rotation_degrees
            ),
        ))
    }
}

/// Applies mirror(s) in the source axes followed by a clockwise quarter-turn.
/// The permutation is performed in place with one bit per pixel of cycle
/// bookkeeping, avoiding a second full-size floating-point frame buffer.
fn apply_derivative_transform_in_place(
    raw: &mut [[f64; 3]],
    width: u32,
    height: u32,
    transform: domain::DerivativeTransform,
) -> Result<(u32, u32), domain::EngineError> {
    validate_derivative_transform(transform)?;
    let expected_len = width as usize * height as usize;
    if raw.len() != expected_len {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            "derivative transform pixel buffer size does not match width*height".to_string(),
        ));
    }
    if expected_len <= 1 || transform == domain::DerivativeTransform::default() {
        return Ok((width, height));
    }

    let destination_index = |source_index: usize| -> usize {
        let x = source_index as u32 % width;
        let y = source_index as u32 / width;
        let mirrored_x = if transform.horizontal_mirror {
            width - 1 - x
        } else {
            x
        };
        let mirrored_y = if transform.vertical_mirror {
            height - 1 - y
        } else {
            y
        };
        let (destination_x, destination_y, destination_width) = match transform.rotation_degrees {
            0 => (mirrored_x, mirrored_y, width),
            90 => (height - 1 - mirrored_y, mirrored_x, height),
            180 => (width - 1 - mirrored_x, height - 1 - mirrored_y, width),
            270 => (mirrored_y, width - 1 - mirrored_x, height),
            _ => unreachable!("validated quarter-turn"),
        };
        (destination_y * destination_width + destination_x) as usize
    };

    let mut visited = vec![false; expected_len];
    for start in 0..expected_len {
        if visited[start] {
            continue;
        }
        let mut source = start;
        let mut carried = raw[source];
        loop {
            visited[source] = true;
            let destination = destination_index(source);
            std::mem::swap(&mut carried, &mut raw[destination]);
            source = destination;
            if source == start {
                break;
            }
        }
    }

    Ok(match transform.rotation_degrees {
        90 | 270 => (height, width),
        _ => (width, height),
    })
}

// ---------------------------------------------------------------------
// Preview downsampling
// ---------------------------------------------------------------------

fn downsample_dimensions(width: u32, height: u32, max_long_edge_px: u32) -> (u32, u32) {
    let long_edge = width.max(height);
    if long_edge <= max_long_edge_px || max_long_edge_px == 0 {
        return (width, height);
    }
    let scale = max_long_edge_px as f64 / long_edge as f64;
    (
        (width as f64 * scale).round().max(1.0) as u32,
        (height as f64 * scale).round().max(1.0) as u32,
    )
}

/// Nearest-neighbor resample using integer ratio math to avoid drift.
fn downsample_nearest(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    new_width: u32,
    new_height: u32,
) -> Vec<[f64; 3]> {
    let mut out = Vec::with_capacity(new_width as usize * new_height as usize);
    for ny in 0..new_height {
        let sy = ((ny as u64 * height as u64) / new_height.max(1) as u64) as u32;
        let sy = sy.min(height.saturating_sub(1));
        for nx in 0..new_width {
            let sx = ((nx as u64 * width as u64) / new_width.max(1) as u64) as u32;
            let sx = sx.min(width.saturating_sub(1));
            out.push(raw[(sy * width + sx) as usize]);
        }
    }
    out
}

// ---------------------------------------------------------------------
// Quantization
// ---------------------------------------------------------------------

/// Round-half-up quantization from a `[0,1]` float to a full-scale `u16`
/// sample -- mirrors `parity::candidates::quantize_u16`'s formula exactly.
fn quantize_u16(value: f64) -> u16 {
    (value * 65535.0 + 0.5).clamp(0.0, 65535.0) as u16
}

/// Same convention as `quantize_u16`, scaled for 8-bit output.
fn quantize_u8(value: f64) -> u8 {
    (value * 255.0 + 0.5).clamp(0.0, 255.0) as u8
}

fn to_u16_samples(raw: &[[f64; 3]]) -> Vec<u16> {
    raw.iter()
        .flat_map(|px| px.iter().copied().map(quantize_u16))
        .collect()
}

fn to_u8_samples(raw: &[[f64; 3]]) -> Vec<u8> {
    raw.iter()
        .flat_map(|px| px.iter().copied().map(quantize_u8))
        .collect()
}

// ---------------------------------------------------------------------
// File writers
// ---------------------------------------------------------------------

/// Builds the in-memory `image::DynamicImage` for a raw `[0,1]`-float pixel
/// buffer at the given bit depth: `bit_depth == 8` selects the 8-bit/`Rgb8`
/// branch, anything else (in practice only `16`) selects the 16-bit/`Rgb16`
/// branch. Shared by both `write_tiff_create_only` (archive, driven by the
/// capture's own `bit_depth`) and `write_derivative` (derivatives, which
/// always force `16` for Tiff or `8` for Jpeg -- see its own doc comment).
fn build_dynamic_image(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    bit_depth: u32,
) -> Result<image::DynamicImage, domain::EngineError> {
    if bit_depth == 8 {
        let buffer =
            image::ImageBuffer::<image::Rgb<u8>, _>::from_raw(width, height, to_u8_samples(raw))
                .ok_or_else(|| {
                    domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        "8-bit pixel buffer size does not match width*height*3".to_string(),
                    )
                })?;
        Ok(image::DynamicImage::ImageRgb8(buffer))
    } else {
        let buffer =
            image::ImageBuffer::<image::Rgb<u16>, _>::from_raw(width, height, to_u16_samples(raw))
                .ok_or_else(|| {
                    domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        "16-bit pixel buffer size does not match width*height*3".to_string(),
                    )
                })?;
        Ok(image::DynamicImage::ImageRgb16(buffer))
    }
}

const PRIVATE_FILE_ATTEMPTS: usize = 32;

fn random_file_token() -> Result<String, domain::EngineError> {
    let mut random = [0_u8; 16];
    getrandom::fill(&mut random).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("failed to obtain randomness for private output staging: {error}"),
        )
    })?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(test)]
fn create_private_file(
    parent: &Path,
    purpose: &str,
) -> Result<(PathBuf, std::fs::File), domain::EngineError> {
    for _ in 0..PRIVATE_FILE_ATTEMPTS {
        let token = random_file_token()?;
        let temporary = parent.join(format!(".scanstudio-{purpose}-{token}.tmp"));
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => return Ok((temporary, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!(
                        "failed to reserve private {purpose} sibling in {}: {error}",
                        parent.display()
                    ),
                ))
            }
        }
    }
    Err(domain::EngineError::new(
        protocol::ErrorCode::Internal,
        format!(
            "failed to reserve a unique private {purpose} sibling in {}",
            parent.display()
        ),
    ))
}

fn create_private_directory(
    parent: &Path,
    purpose: &str,
) -> Result<(PathBuf, String), domain::EngineError> {
    for _ in 0..PRIVATE_FILE_ATTEMPTS {
        let token = random_file_token()?;
        let temporary = parent.join(format!(".scanstudio-{purpose}-{token}.attempt"));
        #[allow(unused_mut)]
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt as _;
            builder.mode(0o700);
        }
        match builder.create(&temporary) {
            Ok(()) => return Ok((temporary, token)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!(
                        "failed to reserve private {purpose} attempt directory in {}: {error}",
                        parent.display()
                    ),
                ))
            }
        }
    }
    Err(domain::EngineError::new(
        protocol::ErrorCode::Internal,
        format!(
            "failed to reserve a unique private {purpose} attempt directory in {}",
            parent.display()
        ),
    ))
}

#[cfg(unix)]
fn sync_output_directory(directory: &Path) -> std::io::Result<()> {
    std::fs::File::open(directory)?.sync_all()
}

#[cfg(windows)]
fn sync_output_directory(directory: &Path) -> std::io::Result<()> {
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(directory)?
        .sync_all()
}

#[cfg(not(any(unix, windows)))]
fn sync_output_directory(directory: &Path) -> std::io::Result<()> {
    std::fs::File::open(directory)?.sync_all()
}

#[cfg(test)]
fn publish_no_replace(
    temporary: &Path,
    final_path: &Path,
    role: &str,
) -> Result<(), domain::EngineError> {
    std::fs::hard_link(temporary, final_path).map_err(|error| {
        let code = if error.kind() == std::io::ErrorKind::AlreadyExists {
            protocol::ErrorCode::ArchiveCollision
        } else {
            protocol::ErrorCode::Internal
        };
        domain::EngineError::new(
            code,
            format!(
                "failed to publish create-only {role} at {}: {error}",
                final_path.display()
            ),
        )
    })
}

#[cfg(test)]
fn validate_archive_tiff(
    path: &Path,
    width: u32,
    height: u32,
    bit_depth: u32,
) -> Result<(), domain::EngineError> {
    let decoded = image::ImageReader::open(path)
        .and_then(|reader| reader.with_guessed_format())
        .map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to reopen staged archive TIFF {}: {error}",
                    path.display()
                ),
            )
        })?
        .decode()
        .map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "staged archive TIFF {} failed decode validation: {error}",
                    path.display()
                ),
            )
        })?;
    let expected_color = if bit_depth == 8 {
        image::ColorType::Rgb8
    } else {
        image::ColorType::Rgb16
    };
    if decoded.width() != width || decoded.height() != height || decoded.color() != expected_color {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "staged archive TIFF validation mismatch: expected {width}x{height} {expected_color:?}, decoded {}x{} {:?}",
                decoded.width(),
                decoded.height(),
                decoded.color()
            ),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ArchiveCommitStep {
    TemporaryReserved,
    Encoded,
    FileSynced,
    Validated,
    FinalPublished,
    ParentSynced,
}

#[cfg(test)]
fn write_tiff_create_only_with_hook<Hook>(
    path: &Path,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    bit_depth: u32,
    mut after_step: Hook,
) -> Result<PublishedFileProof, domain::EngineError>
where
    Hook: FnMut(ArchiveCommitStep, &Path) -> Result<(), domain::EngineError>,
{
    let parent = path.parent().ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("archive path has no parent directory: {}", path.display()),
        )
    })?;
    std::fs::create_dir_all(parent).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to create archive directory {}: {error}",
                parent.display()
            ),
        )
    })?;

    let (temporary, file) = create_private_file(parent, "archive")?;
    let mut final_published = false;
    let result = (|| {
        after_step(ArchiveCommitStep::TemporaryReserved, &temporary)?;
        let mut writer = std::io::BufWriter::new(file);
        let image = build_dynamic_image(raw, width, height, bit_depth)?;
        image
            .write_to(&mut writer, image::ImageFormat::Tiff)
            .map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!(
                        "failed to encode staged archive TIFF beside {}: {error}",
                        path.display()
                    ),
                )
            })?;
        drop(image);
        after_step(ArchiveCommitStep::Encoded, &temporary)?;
        writer.flush().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to flush staged archive TIFF beside {}: {error}",
                    path.display()
                ),
            )
        })?;
        writer.get_ref().sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to sync staged archive TIFF beside {}: {error}",
                    path.display()
                ),
            )
        })?;
        let published_file = writer.get_ref().try_clone().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to retain the staged archive identity beside {}: {error}",
                    path.display()
                ),
            )
        })?;
        drop(writer);
        after_step(ArchiveCommitStep::FileSynced, &temporary)?;
        validate_archive_tiff(&temporary, width, height, bit_depth)?;
        after_step(ArchiveCommitStep::Validated, &temporary)?;
        publish_no_replace(&temporary, path, "archive TIFF")?;
        final_published = true;
        after_step(ArchiveCommitStep::FinalPublished, &temporary)?;
        sync_output_directory(parent).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to sync archive directory {} after publication: {error}",
                    parent.display()
                ),
            )
        })?;
        after_step(ArchiveCommitStep::ParentSynced, &temporary)?;
        Ok(published_file)
    })();

    if !final_published {
        let _ = std::fs::remove_file(&temporary);
    } else if std::fs::remove_file(&temporary).is_ok() {
        let _ = sync_output_directory(parent);
    }
    result.and_then(|file| published_file_proof(path, file))
}

/// Encodes the retained master to a private, unpredictable sibling and only
/// publishes its final create-only name after a successful sync and decode
/// validation. The final leaf is therefore never a partial TIFF.
#[cfg(test)]
fn write_tiff_create_only(
    path: &Path,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    bit_depth: u32,
) -> Result<PublishedFileProof, domain::EngineError> {
    write_tiff_create_only_with_hook(path, raw, width, height, bit_depth, |_, _| Ok(()))
}

#[cfg(any(unix, windows))]
fn cleanup_authorized_temporary(
    output: &AuthorizedOutputLeaf,
    temporary: &std::ffi::OsStr,
    file: &std::fs::File,
) {
    let _ = destination_sys::unlink_leaf(&output.destination.inner, temporary, file);
}

#[cfg(not(any(unix, windows)))]
fn cleanup_authorized_temporary(
    _output: &AuthorizedOutputLeaf,
    _temporary: &std::ffi::OsStr,
    _file: &std::fs::File,
) {
}

#[cfg(any(unix, windows))]
fn authorized_published_file_proof(
    output: &AuthorizedOutputLeaf,
    file: std::fs::File,
) -> Result<PublishedFileProof, domain::EngineError> {
    destination_sys::verify_leaf_identity(&output.destination.inner, &output.final_name, &file)?;
    Ok(PublishedFileProof {
        final_path: output.final_path.clone(),
        file,
    })
}

#[cfg(not(any(unix, windows)))]
fn authorized_published_file_proof(
    output: &AuthorizedOutputLeaf,
    _file: std::fs::File,
) -> Result<PublishedFileProof, domain::EngineError> {
    Err(output_authority_error(format!(
        "{} publication at {} is unavailable without handle-relative reparse-safe filesystem operations",
        output.role,
        output.final_path.display()
    )))
}

fn validate_archive_tiff_file(
    file: &std::fs::File,
    display_path: &Path,
    width: u32,
    height: u32,
    bit_depth: u32,
) -> Result<(), domain::EngineError> {
    let mut cloned = file.try_clone().map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("retain staged archive for decode validation: {error}"),
        )
    })?;
    cloned.seek(std::io::SeekFrom::Start(0)).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("rewind staged archive {}: {error}", display_path.display()),
        )
    })?;
    let decoded = image::ImageReader::new(std::io::BufReader::new(cloned))
        .with_guessed_format()
        .map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to identify staged archive TIFF {}: {error}",
                    display_path.display()
                ),
            )
        })?
        .decode()
        .map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "staged archive TIFF {} failed decode validation: {error}",
                    display_path.display()
                ),
            )
        })?;
    let expected_color = if bit_depth == 8 {
        image::ColorType::Rgb8
    } else {
        image::ColorType::Rgb16
    };
    if decoded.width() != width || decoded.height() != height || decoded.color() != expected_color {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "staged archive TIFF validation mismatch: expected {width}x{height} {expected_color:?}, decoded {}x{} {:?}",
                decoded.width(),
                decoded.height(),
                decoded.color()
            ),
        ));
    }
    Ok(())
}

#[cfg(any(unix, windows))]
fn write_tiff_create_only_authorized_with_hook<Hook>(
    output: &AuthorizedOutputLeaf,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    bit_depth: u32,
    mut after_step: Hook,
) -> Result<PublishedFileProof, domain::EngineError>
where
    Hook: FnMut(ArchiveCommitStep) -> Result<(), domain::EngineError>,
{
    if !output.create_only {
        return Err(output_authority_error(
            "archive authority unexpectedly permits replacement",
        ));
    }
    let (temporary, file) = destination_sys::reserve_private_sibling(
        &output.destination.inner,
        &output.final_name,
        "archive",
    )?;
    let cleanup_file = match file.try_clone() {
        Ok(file) => file,
        Err(error) => {
            cleanup_authorized_temporary(output, &temporary, &file);
            return Err(domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("retain staged archive cleanup identity: {error}"),
            ));
        }
    };
    let result = (|| {
        after_step(ArchiveCommitStep::TemporaryReserved)?;
        let mut writer = std::io::BufWriter::new(file);
        let image = build_dynamic_image(raw, width, height, bit_depth)?;
        image
            .write_to(&mut writer, image::ImageFormat::Tiff)
            .map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!(
                        "failed to encode staged archive TIFF for {}: {error}",
                        output.final_path.display()
                    ),
                )
            })?;
        drop(image);
        after_step(ArchiveCommitStep::Encoded)?;
        writer.flush().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("flush staged archive TIFF: {error}"),
            )
        })?;
        writer.get_ref().sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("sync staged archive TIFF: {error}"),
            )
        })?;
        let published_file = writer.get_ref().try_clone().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("retain staged archive identity: {error}"),
            )
        })?;
        drop(writer);
        after_step(ArchiveCommitStep::FileSynced)?;
        validate_archive_tiff_file(
            &published_file,
            &output.final_path,
            width,
            height,
            bit_depth,
        )?;
        after_step(ArchiveCommitStep::Validated)?;
        destination_sys::publish(
            &output.destination.inner,
            &temporary,
            &output.final_name,
            &published_file,
            true,
            output.role,
        )?;
        after_step(ArchiveCommitStep::FinalPublished)?;
        after_step(ArchiveCommitStep::ParentSynced)?;
        authorized_published_file_proof(output, published_file)
    })();
    if result.is_err() {
        cleanup_authorized_temporary(output, &temporary, &cleanup_file);
    }
    result
}

#[cfg(not(any(unix, windows)))]
fn write_tiff_create_only_authorized_with_hook<Hook>(
    output: &AuthorizedOutputLeaf,
    _raw: &[[f64; 3]],
    _width: u32,
    _height: u32,
    _bit_depth: u32,
    _after_step: Hook,
) -> Result<PublishedFileProof, domain::EngineError>
where
    Hook: FnMut(ArchiveCommitStep) -> Result<(), domain::EngineError>,
{
    Err(output_authority_error(format!(
        "archive publication at {} is unavailable without reparse-safe handle-relative operations",
        output.final_path.display()
    )))
}

fn write_tiff_create_only_authorized(
    output: &AuthorizedOutputLeaf,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    bit_depth: u32,
) -> Result<PublishedFileProof, domain::EngineError> {
    write_tiff_create_only_authorized_with_hook(output, raw, width, height, bit_depth, |_| Ok(()))
}

const RAW_IR_TAG: u16 = 65_001;
const RAW_IR_MARKER: &[u8] = b"scanstudio.infrared.linear.uint16.v1\0";

#[derive(Debug, Clone)]
struct RawTiffEntry {
    tag: u16,
    field_type: u16,
    count: u32,
    value: Vec<u8>,
}

impl RawTiffEntry {
    fn byte(tag: u16, values: &[u8]) -> Self {
        Self {
            tag,
            field_type: 1,
            count: values.len() as u32,
            value: values.to_vec(),
        }
    }

    fn ascii(tag: u16, value: &str) -> Self {
        let mut bytes = value.as_bytes().to_vec();
        if !bytes.ends_with(&[0]) {
            bytes.push(0);
        }
        Self {
            tag,
            field_type: 2,
            count: bytes.len() as u32,
            value: bytes,
        }
    }

    fn short(tag: u16, values: &[u16]) -> Self {
        Self {
            tag,
            field_type: 3,
            count: values.len() as u32,
            value: values
                .iter()
                .flat_map(|value| value.to_le_bytes())
                .collect(),
        }
    }

    fn long(tag: u16, values: &[u32]) -> Self {
        Self {
            tag,
            field_type: 4,
            count: values.len() as u32,
            value: values
                .iter()
                .flat_map(|value| value.to_le_bytes())
                .collect(),
        }
    }

    fn rational(tag: u16, values: &[(u32, u32)]) -> Self {
        let value = values
            .iter()
            .flat_map(|(numerator, denominator)| {
                numerator
                    .to_le_bytes()
                    .into_iter()
                    .chain(denominator.to_le_bytes())
            })
            .collect();
        Self {
            tag,
            field_type: 5,
            count: values.len() as u32,
            value,
        }
    }

    fn signed_rational(tag: u16, values: &[(i32, i32)]) -> Self {
        let value = values
            .iter()
            .flat_map(|(numerator, denominator)| {
                numerator
                    .to_le_bytes()
                    .into_iter()
                    .chain(denominator.to_le_bytes())
            })
            .collect();
        Self {
            tag,
            field_type: 10,
            count: values.len() as u32,
            value,
        }
    }
}

fn align_four(value: usize) -> usize {
    (value + 3) & !3
}

fn raw_ifd_storage_len(entries: &[RawTiffEntry], ifd_offset: usize) -> usize {
    let fixed_len = 2 + entries.len() * 12 + 4;
    let mut cursor = ifd_offset + fixed_len;
    for entry in entries {
        if entry.value.len() > 4 {
            cursor = align_four(cursor);
            cursor += entry.value.len();
        }
    }
    cursor - ifd_offset
}

fn serialize_raw_ifd(entries: &[RawTiffEntry], ifd_offset: usize) -> Vec<u8> {
    let mut entries = entries.to_vec();
    entries.sort_by_key(|entry| entry.tag);
    let fixed_len = 2 + entries.len() * 12 + 4;
    let mut bytes = vec![0_u8; fixed_len];
    bytes[0..2].copy_from_slice(&(entries.len() as u16).to_le_bytes());

    for (index, entry) in entries.iter().enumerate() {
        let base = 2 + index * 12;
        bytes[base..base + 2].copy_from_slice(&entry.tag.to_le_bytes());
        bytes[base + 2..base + 4].copy_from_slice(&entry.field_type.to_le_bytes());
        bytes[base + 4..base + 8].copy_from_slice(&entry.count.to_le_bytes());
        if entry.value.len() <= 4 {
            bytes[base + 8..base + 8 + entry.value.len()].copy_from_slice(&entry.value);
        } else {
            let aligned = align_four(ifd_offset + bytes.len());
            bytes.resize(aligned - ifd_offset, 0);
            bytes[base + 8..base + 12].copy_from_slice(&(aligned as u32).to_le_bytes());
            bytes.extend_from_slice(&entry.value);
        }
    }
    bytes
}

fn raw_baseline_entries(
    width: u32,
    height: u32,
    dpi: u32,
    samples_per_pixel: u16,
    photometric: u16,
    strip_offset: u32,
    strip_byte_count: u32,
) -> Vec<RawTiffEntry> {
    vec![
        RawTiffEntry::long(254, &[0]),
        RawTiffEntry::long(256, &[width]),
        RawTiffEntry::long(257, &[height]),
        RawTiffEntry::short(258, &vec![16; samples_per_pixel as usize]),
        RawTiffEntry::short(259, &[1]),
        RawTiffEntry::short(262, &[photometric]),
        RawTiffEntry::long(273, &[strip_offset]),
        RawTiffEntry::short(274, &[1]),
        RawTiffEntry::short(277, &[samples_per_pixel]),
        RawTiffEntry::long(278, &[height]),
        RawTiffEntry::long(279, &[strip_byte_count]),
        RawTiffEntry::rational(282, &[(dpi, 1)]),
        RawTiffEntry::rational(283, &[(dpi, 1)]),
        RawTiffEntry::short(284, &[1]),
        RawTiffEntry::short(296, &[2]),
        RawTiffEntry::ascii(305, "ScanStudio"),
    ]
}

fn dng_main_entries(
    width: u32,
    height: u32,
    dpi: u32,
    strip_offset: u32,
    strip_byte_count: u32,
    infrared_ifd_offset: Option<u32>,
) -> Vec<RawTiffEntry> {
    let mut entries = raw_baseline_entries(
        width,
        height,
        dpi,
        3,
        34_892,
        strip_offset,
        strip_byte_count,
    );
    entries.extend([
        RawTiffEntry::ascii(271, "Nikon"),
        RawTiffEntry::ascii(272, "Nikon Coolscan Simulator"),
    ]);
    if let Some(infrared_ifd_offset) = infrared_ifd_offset {
        entries.push(RawTiffEntry::long(330, &[infrared_ifd_offset]));
    }
    entries.extend([
        RawTiffEntry::byte(50_706, &[1, 4, 0, 0]),
        RawTiffEntry::byte(50_707, &[1, 1, 0, 0]),
        RawTiffEntry::ascii(50_708, "Nikon Coolscan Simulator"),
        RawTiffEntry::rational(50_714, &[(0, 1), (0, 1), (0, 1)]),
        RawTiffEntry::long(50_717, &[65_535, 65_535, 65_535]),
        RawTiffEntry::rational(50_718, &[(1, 1), (1, 1)]),
        RawTiffEntry::long(50_719, &[0, 0]),
        RawTiffEntry::long(50_720, &[width, height]),
        RawTiffEntry::signed_rational(
            50_721,
            &[
                (1, 1),
                (0, 1),
                (0, 1),
                (0, 1),
                (1, 1),
                (0, 1),
                (0, 1),
                (0, 1),
                (1, 1),
            ],
        ),
        RawTiffEntry::rational(50_728, &[(1, 1), (1, 1), (1, 1)]),
        RawTiffEntry::short(50_778, &[0]),
        RawTiffEntry::long(50_829, &[0, 0, height, width]),
    ]);
    entries
}

fn dng_infrared_entries(
    width: u32,
    height: u32,
    dpi: u32,
    strip_offset: u32,
    strip_byte_count: u32,
) -> Vec<RawTiffEntry> {
    let mut entries =
        raw_baseline_entries(width, height, dpi, 1, 1, strip_offset, strip_byte_count);
    entries.extend([
        RawTiffEntry::ascii(270, "Untouched Nikon Coolscan infrared plane"),
        RawTiffEntry::ascii(
            RAW_IR_TAG,
            std::str::from_utf8(RAW_IR_MARKER).expect("marker is ASCII"),
        ),
    ]);
    entries
}

fn encoded_simulated_raw(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    dpi: u32,
    recipe: &domain::RawExportRecipe,
    ir_available: bool,
) -> Result<Vec<u8>, domain::EngineError> {
    let pixel_count = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                "raw export dimensions overflow",
            )
        })?;
    if raw.len() != pixel_count {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            "raw export pixel buffer does not match its dimensions",
        ));
    }
    let rgb_byte_count = u32::try_from(pixel_count.checked_mul(6).ok_or_else(|| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw RGB byte count overflow")
    })?)
    .map_err(|_| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            "raw RGB exceeds classic TIFF",
        )
    })?;
    let ir_byte_count = u32::try_from(pixel_count.checked_mul(2).ok_or_else(|| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw IR byte count overflow")
    })?)
    .map_err(|_| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw IR exceeds classic TIFF")
    })?;

    let mut bytes = b"II*\0\x08\0\0\0".to_vec();
    match recipe.file_format {
        domain::RawExportFormat::LinearDng => {
            let embed_infrared =
                ir_available && recipe.tiff_infrared != domain::RawTiffInfrared::Sidecar;
            let main_dummy = dng_main_entries(
                width,
                height,
                dpi,
                0,
                rgb_byte_count,
                embed_infrared.then_some(0),
            );
            let main_end = align_four(8 + raw_ifd_storage_len(&main_dummy, 8));
            let (infrared_ifd_offset, rgb_offset, infrared_offset) = if embed_infrared {
                let infrared_ifd_offset = main_end;
                let infrared_dummy = dng_infrared_entries(width, height, dpi, 0, ir_byte_count);
                let rgb_offset = align_four(
                    infrared_ifd_offset + raw_ifd_storage_len(&infrared_dummy, infrared_ifd_offset),
                );
                let infrared_offset =
                    rgb_offset
                        .checked_add(rgb_byte_count as usize)
                        .ok_or_else(|| {
                            domain::EngineError::new(
                                protocol::ErrorCode::Internal,
                                "DNG offset overflow",
                            )
                        })?;
                (Some(infrared_ifd_offset), rgb_offset, Some(infrared_offset))
            } else {
                (None, main_end, None)
            };
            let main = dng_main_entries(
                width,
                height,
                dpi,
                rgb_offset as u32,
                rgb_byte_count,
                infrared_ifd_offset.map(|value| value as u32),
            );
            bytes.extend_from_slice(&serialize_raw_ifd(&main, 8));
            if let (Some(infrared_ifd_offset), Some(infrared_offset)) =
                (infrared_ifd_offset, infrared_offset)
            {
                bytes.resize(infrared_ifd_offset, 0);
                let infrared =
                    dng_infrared_entries(width, height, dpi, infrared_offset as u32, ir_byte_count);
                bytes.extend_from_slice(&serialize_raw_ifd(&infrared, infrared_ifd_offset));
            }
            bytes.resize(rgb_offset, 0);
            for pixel in raw {
                for sample in pixel {
                    bytes.extend_from_slice(&quantize_u16(*sample).to_le_bytes());
                }
            }
            if embed_infrared {
                for pixel in raw {
                    let infrared = quantize_u16((pixel[0] + pixel[1] + pixel[2]) / 3.0);
                    bytes.extend_from_slice(&infrared.to_le_bytes());
                }
            }
        }
        domain::RawExportFormat::LinearTiff => {
            if !ir_available && recipe.tiff_infrared == domain::RawTiffInfrared::FourthChannel {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    "fourth-channel linear TIFF requires an infrared capture plane",
                ));
            }
            let include_infrared = recipe.tiff_infrared == domain::RawTiffInfrared::FourthChannel;
            let samples_per_pixel = if include_infrared { 4 } else { 3 };
            let strip_byte_count = if include_infrared {
                rgb_byte_count.checked_add(ir_byte_count).ok_or_else(|| {
                    domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        "raw TIFF byte count overflow",
                    )
                })?
            } else {
                rgb_byte_count
            };
            let mut dummy = raw_baseline_entries(
                width,
                height,
                dpi,
                samples_per_pixel,
                2,
                0,
                strip_byte_count,
            );
            if include_infrared {
                dummy.push(RawTiffEntry::short(338, &[0]));
                dummy.push(RawTiffEntry::ascii(
                    RAW_IR_TAG,
                    std::str::from_utf8(RAW_IR_MARKER).expect("marker is ASCII"),
                ));
            }
            let strip_offset = align_four(8 + raw_ifd_storage_len(&dummy, 8));
            let mut entries = raw_baseline_entries(
                width,
                height,
                dpi,
                samples_per_pixel,
                2,
                strip_offset as u32,
                strip_byte_count,
            );
            if include_infrared {
                entries.push(RawTiffEntry::short(338, &[0]));
                entries.push(RawTiffEntry::ascii(
                    RAW_IR_TAG,
                    std::str::from_utf8(RAW_IR_MARKER).expect("marker is ASCII"),
                ));
            }
            bytes.extend_from_slice(&serialize_raw_ifd(&entries, 8));
            bytes.resize(strip_offset, 0);
            for pixel in raw {
                for sample in pixel {
                    bytes.extend_from_slice(&quantize_u16(*sample).to_le_bytes());
                }
                if include_infrared {
                    let infrared = quantize_u16((pixel[0] + pixel[1] + pixel[2]) / 3.0);
                    bytes.extend_from_slice(&infrared.to_le_bytes());
                }
            }
        }
    }
    Ok(bytes)
}

fn encoded_simulated_raw_ir(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    dpi: u32,
) -> Result<Vec<u8>, domain::EngineError> {
    let pixel_count = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| {
            domain::EngineError::new(protocol::ErrorCode::Internal, "raw IR dimensions overflow")
        })?;
    let strip_byte_count = u32::try_from(pixel_count.checked_mul(2).ok_or_else(|| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw IR byte count overflow")
    })?)
    .map_err(|_| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw IR exceeds classic TIFF")
    })?;
    let dummy = dng_infrared_entries(width, height, dpi, 0, strip_byte_count);
    let strip_offset = align_four(8 + raw_ifd_storage_len(&dummy, 8));
    let entries = dng_infrared_entries(width, height, dpi, strip_offset as u32, strip_byte_count);
    let mut bytes = b"II*\0\x08\0\0\0".to_vec();
    bytes.extend_from_slice(&serialize_raw_ifd(&entries, 8));
    bytes.resize(strip_offset, 0);
    for pixel in raw {
        let infrared = quantize_u16((pixel[0] + pixel[1] + pixel[2]) / 3.0);
        bytes.extend_from_slice(&infrared.to_le_bytes());
    }
    Ok(bytes)
}

const RAW_PAIR_MARKER_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawPairCommittedFile {
    file_name: String,
    byte_length: u64,
    sha256: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawPairCommitMarker {
    schema_version: u32,
    transaction_id: String,
    rgb: RawPairCommittedFile,
    infrared: RawPairCommittedFile,
}

struct AuthorizedStagedFile {
    output: AuthorizedOutputLeaf,
    temporary: std::ffi::OsString,
    file: std::fs::File,
    byte_length: u64,
    sha256: String,
}

fn stage_authorized_bytes(
    output: &AuthorizedOutputLeaf,
    bytes: &[u8],
    purpose: &str,
) -> Result<AuthorizedStagedFile, domain::EngineError> {
    use sha2::{Digest as _, Sha256};

    let (temporary, file) = destination_sys::reserve_private_sibling(
        &output.destination.inner,
        &output.final_name,
        purpose,
    )?;
    let cleanup_file = match file.try_clone() {
        Ok(file) => file,
        Err(error) => {
            cleanup_authorized_temporary(output, &temporary, &file);
            return Err(domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("retain staged {} cleanup identity: {error}", output.role),
            ));
        }
    };
    let result = (|| {
        let mut writer = std::io::BufWriter::new(file);
        writer.write_all(bytes).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("write staged {}: {error}", output.role),
            )
        })?;
        writer.flush().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("flush staged {}: {error}", output.role),
            )
        })?;
        writer.get_ref().sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("sync staged {}: {error}", output.role),
            )
        })?;
        let file = writer.get_ref().try_clone().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("retain staged {} identity: {error}", output.role),
            )
        })?;
        drop(writer);
        Ok(AuthorizedStagedFile {
            output: output.clone(),
            temporary: temporary.clone(),
            file,
            byte_length: bytes.len() as u64,
            sha256: Sha256::digest(bytes)
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
        })
    })();
    if result.is_err() {
        cleanup_authorized_temporary(output, &temporary, &cleanup_file);
    }
    result
}

fn stage_authorized_source(
    output: &AuthorizedOutputLeaf,
    source: &PublishedFileProof,
    purpose: &str,
) -> Result<AuthorizedStagedFile, domain::EngineError> {
    use sha2::{Digest as _, Sha256};

    let (temporary, file) = destination_sys::reserve_private_sibling(
        &output.destination.inner,
        &output.final_name,
        purpose,
    )?;
    let cleanup_file = match file.try_clone() {
        Ok(file) => file,
        Err(error) => {
            cleanup_authorized_temporary(output, &temporary, &file);
            return Err(domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("retain staged {} cleanup identity: {error}", output.role),
            ));
        }
    };
    let result = (|| {
        let mut source_file = source.try_clone_file()?;
        source_file
            .seek(std::io::SeekFrom::Start(0))
            .map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("rewind held {} source: {error}", output.role),
                )
            })?;
        let expected_length = source_file
            .metadata()
            .map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("inspect held {} source: {error}", output.role),
                )
            })?
            .len();
        let mut reader = std::io::BufReader::new(source_file);
        let mut writer = std::io::BufWriter::new(file);
        let mut digest = Sha256::new();
        let mut buffer = [0_u8; 64 * 1024];
        let mut copied = 0_u64;
        loop {
            let read = reader.read(&mut buffer).map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("read held {} source: {error}", output.role),
                )
            })?;
            if read == 0 {
                break;
            }
            writer.write_all(&buffer[..read]).map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("write staged {} source copy: {error}", output.role),
                )
            })?;
            digest.update(&buffer[..read]);
            copied = copied.checked_add(read as u64).ok_or_else(|| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("{} source length overflow", output.role),
                )
            })?;
        }
        if copied != expected_length {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "held {} source length changed during copy: expected {expected_length}, copied {copied}",
                    output.role
                ),
            ));
        }
        writer.flush().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("flush staged {} source copy: {error}", output.role),
            )
        })?;
        writer.get_ref().sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("sync staged {} source copy: {error}", output.role),
            )
        })?;
        let file = writer.get_ref().try_clone().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "retain staged {} source-copy identity: {error}",
                    output.role
                ),
            )
        })?;
        drop(writer);
        verify_published_file_identity(source.final_path(), &source.file)?;
        Ok(AuthorizedStagedFile {
            output: output.clone(),
            temporary: temporary.clone(),
            file,
            byte_length: copied,
            sha256: digest
                .finalize()
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
        })
    })();
    if result.is_err() {
        cleanup_authorized_temporary(output, &temporary, &cleanup_file);
    }
    result
}

impl AuthorizedStagedFile {
    fn committed_description(&self) -> Result<RawPairCommittedFile, domain::EngineError> {
        let file_name = self
            .output
            .final_path
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| {
                output_authority_error(format!("{} has no UTF-8 leaf", self.output.role))
            })?;
        Ok(RawPairCommittedFile {
            file_name: file_name.to_string(),
            byte_length: self.byte_length,
            sha256: self.sha256.clone(),
        })
    }

    fn publish(&self) -> Result<PublishedFileProof, domain::EngineError> {
        destination_sys::publish(
            &self.output.destination.inner,
            &self.temporary,
            &self.output.final_name,
            &self.file,
            true,
            self.output.role,
        )?;
        let file = self.file.try_clone().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("retain published {} identity: {error}", self.output.role),
            )
        })?;
        match authorized_published_file_proof(&self.output, file) {
            Ok(proof) => Ok(proof),
            Err(error) => {
                // Publication itself succeeded, so proof construction must
                // either return the bound identity or retire that exact
                // identity. Never leave an unproved create-only final behind.
                let _ = destination_sys::remove_published_leaf(
                    &self.output.destination.inner,
                    &self.output.final_name,
                    &self.file,
                );
                Err(error)
            }
        }
    }

    fn cleanup_temporary(&self) {
        cleanup_authorized_temporary(&self.output, &self.temporary, &self.file);
    }
}

impl Drop for AuthorizedStagedFile {
    fn drop(&mut self) {
        cleanup_authorized_temporary(&self.output, &self.temporary, &self.file);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RetainedArchiveCommitStep {
    AllStaged,
    RgbPublished,
    InfraredPublished,
    MeterPublished,
}

fn publish_retained_archive_set_with_hook<Hook>(
    staged: [&Option<AuthorizedStagedFile>; 3],
    mut after_step: Hook,
) -> Result<[Option<PublishedFileProof>; 3], domain::EngineError>
where
    Hook: FnMut(RetainedArchiveCommitStep) -> Result<(), domain::EngineError>,
{
    let mut proofs: [Option<PublishedFileProof>; 3] = [None, None, None];
    let steps = [
        RetainedArchiveCommitStep::RgbPublished,
        RetainedArchiveCommitStep::InfraredPublished,
        RetainedArchiveCommitStep::MeterPublished,
    ];
    let result = (|| {
        after_step(RetainedArchiveCommitStep::AllStaged)?;
        for (index, file) in staged.iter().enumerate() {
            if let Some(file) = file {
                proofs[index] = Some(file.publish()?);
                after_step(steps[index])?;
            }
        }
        Ok(())
    })();
    if result.is_err() {
        for index in (0..staged.len()).rev() {
            if let Some(file) = staged[index] {
                rollback_authorized_publication(&file.output, proofs[index].as_ref());
            }
        }
    }
    for file in staged.into_iter().flatten() {
        file.cleanup_temporary();
    }
    result.map(|()| proofs)
}

fn publish_retained_archive_set(
    staged: [&Option<AuthorizedStagedFile>; 3],
) -> Result<[Option<PublishedFileProof>; 3], domain::EngineError> {
    publish_retained_archive_set_with_hook(staged, |_| Ok(()))
}

fn rollback_authorized_publication(
    output: &AuthorizedOutputLeaf,
    proof: Option<&PublishedFileProof>,
) {
    if let Some(proof) = proof {
        let _ = destination_sys::remove_published_leaf(
            &output.destination.inner,
            &output.final_name,
            &proof.file,
        );
    }
}

fn raw_export_pair_commit_marker_path(path: &Path) -> Result<PathBuf, domain::EngineError> {
    use sha2::{Digest as _, Sha256};

    let parent = path.parent().ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("raw export has no parent directory: {}", path.display()),
        )
    })?;
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("raw export has no UTF-8 file name: {}", path.display()),
            )
        })?;
    let digest = Sha256::digest(file_name.as_bytes());
    let key = digest[..16]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    Ok(parent.join(format!(".scanstudio-raw-pair-{key}.json")))
}

#[cfg(test)]
fn path_entry_exists(path: &Path) -> Result<bool, domain::EngineError> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("failed to inspect output path {}: {error}", path.display()),
        )),
    }
}

#[cfg(test)]
fn bytes_sha256(encoded: &[u8]) -> String {
    use sha2::{Digest as _, Sha256};

    Sha256::digest(encoded)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
fn file_sha256(path: &Path) -> Result<(u64, String), domain::EngineError> {
    use sha2::{Digest as _, Sha256};

    let metadata = std::fs::symlink_metadata(path).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to inspect committed raw export {}: {error}",
                path.display()
            ),
        )
    })?;
    if !metadata.file_type().is_file() {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "committed raw export is not a regular file: {}",
                path.display()
            ),
        ));
    }
    let mut file = std::fs::File::open(path).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to open committed raw export {}: {error}",
                path.display()
            ),
        )
    })?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to hash committed raw export {}: {error}",
                    path.display()
                ),
            )
        })?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    let hash = digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    Ok((metadata.len(), hash))
}

#[cfg(test)]
fn committed_file_description(
    path: &Path,
    encoded: &[u8],
) -> Result<RawPairCommittedFile, domain::EngineError> {
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("raw export has no UTF-8 file name: {}", path.display()),
            )
        })?;
    Ok(RawPairCommittedFile {
        file_name: file_name.to_string(),
        byte_length: encoded.len() as u64,
        sha256: bytes_sha256(encoded),
    })
}

/// A two-plane raw export is readable only when its atomic commit marker
/// names both final leaves and their durable bytes match the marker exactly.
/// Orphan files left by a host crash before the marker commit point are never
/// treated as a pair.
#[cfg(test)]
pub(crate) fn validate_raw_export_pair_commit(
    main_path: &Path,
    sidecar_path: &Path,
) -> Result<(), domain::EngineError> {
    if main_path.parent() != sidecar_path.parent() {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            "raw RGB and infrared pair must share one parent directory",
        ));
    }
    let marker_path = raw_export_pair_commit_marker_path(main_path)?;
    let marker_metadata = std::fs::symlink_metadata(&marker_path).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "raw export pair has no trusted commit marker at {}: {error}",
                marker_path.display()
            ),
        )
    })?;
    if !marker_metadata.file_type().is_file() {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "raw export pair commit marker is not a regular file: {}",
                marker_path.display()
            ),
        ));
    }
    if marker_metadata.len() > 16 * 1024 {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "raw export pair commit marker is unreasonably large: {}",
                marker_path.display()
            ),
        ));
    }
    let marker_bytes = std::fs::read(&marker_path).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to read raw export pair commit marker {}: {error}",
                marker_path.display()
            ),
        )
    })?;
    let marker: RawPairCommitMarker = serde_json::from_slice(&marker_bytes).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "invalid raw export pair commit marker {}: {error}",
                marker_path.display()
            ),
        )
    })?;
    if marker.schema_version != RAW_PAIR_MARKER_SCHEMA_VERSION
        || marker.transaction_id.len() != 32
        || !marker
            .transaction_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "unsupported or malformed raw export pair commit marker {}",
                marker_path.display()
            ),
        ));
    }
    let expected_main_name = main_path.file_name().and_then(|value| value.to_str());
    let expected_sidecar_name = sidecar_path.file_name().and_then(|value| value.to_str());
    if expected_main_name != Some(marker.rgb.file_name.as_str())
        || expected_sidecar_name != Some(marker.infrared.file_name.as_str())
    {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "raw export pair commit marker {} names different output files",
                marker_path.display()
            ),
        ));
    }
    let (main_length, main_hash) = file_sha256(main_path)?;
    let (sidecar_length, sidecar_hash) = file_sha256(sidecar_path)?;
    if main_length != marker.rgb.byte_length
        || main_hash != marker.rgb.sha256
        || sidecar_length != marker.infrared.byte_length
        || sidecar_hash != marker.infrared.sha256
    {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "raw export pair bytes do not match commit marker {}",
                marker_path.display()
            ),
        ));
    }
    Ok(())
}

#[cfg(test)]
fn write_synced_create_new(path: &Path, encoded: &[u8]) -> Result<(), domain::EngineError> {
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to create staged raw export {}: {error}",
                    path.display()
                ),
            )
        })?;
    let mut writer = std::io::BufWriter::new(file);
    writer.write_all(encoded).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to write staged raw export {}: {error}",
                path.display()
            ),
        )
    })?;
    writer.flush().map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to flush staged raw export {}: {error}",
                path.display()
            ),
        )
    })?;
    writer.get_ref().sync_all().map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to sync staged raw export {}: {error}",
                path.display()
            ),
        )
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RawPairCommitStep {
    MainSynced,
    InfraredSynced,
    AttemptDirectorySynced,
    MainPublished,
    InfraredPublished,
    FinalFilesDirectorySynced,
    MarkerPublished,
    CommitDirectorySynced,
}

fn publish_authorized_raw_pair_with_hook<Hook>(
    main: AuthorizedStagedFile,
    sidecar: AuthorizedStagedFile,
    marker_output: &AuthorizedOutputLeaf,
    mut after_step: Hook,
) -> Result<Option<PathBuf>, domain::EngineError>
where
    Hook: FnMut(RawPairCommitStep) -> Result<(), domain::EngineError>,
{
    let marker_staged = match (|| {
        after_step(RawPairCommitStep::MainSynced)?;
        after_step(RawPairCommitStep::InfraredSynced)?;
        let transaction_id = publication_token()?;
        let marker = RawPairCommitMarker {
            schema_version: RAW_PAIR_MARKER_SCHEMA_VERSION,
            transaction_id,
            rgb: main.committed_description()?,
            infrared: sidecar.committed_description()?,
        };
        let marker_bytes = serde_json::to_vec_pretty(&marker).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("serialize raw pair commit marker: {error}"),
            )
        })?;
        stage_authorized_bytes(marker_output, &marker_bytes, "raw-marker")
    })() {
        Ok(staged) => staged,
        Err(error) => {
            main.cleanup_temporary();
            sidecar.cleanup_temporary();
            return Err(error);
        }
    };
    if let Err(error) = after_step(RawPairCommitStep::AttemptDirectorySynced) {
        main.cleanup_temporary();
        sidecar.cleanup_temporary();
        marker_staged.cleanup_temporary();
        return Err(error);
    }

    let mut main_proof = None;
    let mut sidecar_proof = None;
    let mut marker_proof = None;
    let result = (|| {
        main_proof = Some(main.publish()?);
        after_step(RawPairCommitStep::MainPublished)?;
        sidecar_proof = Some(sidecar.publish()?);
        after_step(RawPairCommitStep::InfraredPublished)?;
        after_step(RawPairCommitStep::FinalFilesDirectorySynced)?;
        marker_proof = Some(marker_staged.publish()?);
        after_step(RawPairCommitStep::MarkerPublished)?;
        after_step(RawPairCommitStep::CommitDirectorySynced)?;
        Ok(Some(sidecar.output.final_path.clone()))
    })();
    if result.is_err() {
        rollback_authorized_publication(marker_output, marker_proof.as_ref());
        rollback_authorized_publication(&sidecar.output, sidecar_proof.as_ref());
        rollback_authorized_publication(&main.output, main_proof.as_ref());
    }
    main.cleanup_temporary();
    sidecar.cleanup_temporary();
    marker_staged.cleanup_temporary();
    result
}

fn write_raw_export_create_only_authorized_with_hook<Hook>(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    dpi: u32,
    recipe: &domain::RawExportRecipe,
    ir_available: bool,
    authorities: &FrameOutputAuthorities,
    after_step: Hook,
) -> Result<Option<PathBuf>, domain::EngineError>
where
    Hook: FnMut(RawPairCommitStep) -> Result<(), domain::EngineError>,
{
    let main_output = authorities.raw.as_ref().ok_or_else(|| {
        output_authority_error("enabled raw export has no held destination authority")
    })?;
    let encoded = encoded_simulated_raw(raw, width, height, dpi, recipe, ir_available)?;
    let main = stage_authorized_bytes(main_output, &encoded, "raw")?;
    if !(ir_available && recipe.tiff_infrared == domain::RawTiffInfrared::Sidecar) {
        let result = main.publish().map(|_| None);
        main.cleanup_temporary();
        return result;
    }
    let sidecar_output = authorities
        .raw_ir
        .as_ref()
        .ok_or_else(|| output_authority_error("raw sidecar mode has no held infrared authority"))?;
    let marker_output = authorities.raw_marker.as_ref().ok_or_else(|| {
        output_authority_error("raw sidecar mode has no held commit-marker authority")
    })?;
    let sidecar_encoded = encoded_simulated_raw_ir(raw, width, height, dpi)?;
    let sidecar = match stage_authorized_bytes(sidecar_output, &sidecar_encoded, "raw-ir") {
        Ok(value) => value,
        Err(error) => {
            main.cleanup_temporary();
            return Err(error);
        }
    };
    publish_authorized_raw_pair_with_hook(main, sidecar, marker_output, after_step)
}

fn write_raw_export_create_only_authorized(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    dpi: u32,
    recipe: &domain::RawExportRecipe,
    ir_available: bool,
    authorities: &FrameOutputAuthorities,
) -> Result<Option<PathBuf>, domain::EngineError> {
    write_raw_export_create_only_authorized_with_hook(
        raw,
        width,
        height,
        dpi,
        recipe,
        ir_available,
        authorities,
        |_| Ok(()),
    )
}

pub(crate) fn publish_real_raw_export_authorized(
    main_source: Option<&Path>,
    sidecar_source: Option<&Path>,
    authorities: &FrameOutputAuthorities,
) -> Result<(Option<PathBuf>, Option<PathBuf>), domain::EngineError> {
    let Some(main_source) = main_source else {
        if authorities.raw.is_some() {
            return Err(output_authority_error(
                "enabled raw export was omitted by the bridge",
            ));
        }
        return Ok((None, None));
    };
    let main_output = authorities.raw.as_ref().ok_or_else(|| {
        output_authority_error("bridge produced raw output without held destination authority")
    })?;
    let main_source = open_existing_file_proof(main_source)?;
    let main = stage_authorized_source(main_output, &main_source, "raw-copy")?;
    let Some(sidecar_source) = sidecar_source else {
        if authorities.raw_ir.is_some() || authorities.raw_marker.is_some() {
            main.cleanup_temporary();
            return Err(output_authority_error(
                "raw sidecar mode was enabled but the bridge omitted its infrared file",
            ));
        }
        let result = main
            .publish()
            .map(|_| (Some(main_output.final_path.clone()), None));
        main.cleanup_temporary();
        return result;
    };
    let sidecar_output = authorities.raw_ir.as_ref().ok_or_else(|| {
        output_authority_error("bridge produced raw infrared without held sidecar authority")
    })?;
    let marker_output = authorities.raw_marker.as_ref().ok_or_else(|| {
        output_authority_error("bridge produced raw infrared without held marker authority")
    })?;
    let sidecar_source = open_existing_file_proof(sidecar_source)?;
    let sidecar = match stage_authorized_source(sidecar_output, &sidecar_source, "raw-ir-copy") {
        Ok(value) => value,
        Err(error) => {
            main.cleanup_temporary();
            return Err(error);
        }
    };
    publish_authorized_raw_pair_with_hook(main, sidecar, marker_output, |_| Ok(()))
        .map(|sidecar| (Some(main_output.final_path.clone()), sidecar))
}

#[derive(Debug, Default)]
#[cfg(test)]
struct RawPairPublicationState {
    main_published: bool,
    sidecar_published: bool,
    marker_published: bool,
}

#[allow(clippy::too_many_arguments)]
#[cfg(test)]
fn execute_raw_pair_transaction<Hook>(
    attempt_directory: &Path,
    transaction_id: &str,
    main_path: &Path,
    main_encoded: &[u8],
    sidecar_path: &Path,
    sidecar_encoded: &[u8],
    marker_path: &Path,
    state: &mut RawPairPublicationState,
    mut after_step: Hook,
) -> Result<(), domain::EngineError>
where
    Hook: FnMut(RawPairCommitStep) -> Result<(), domain::EngineError>,
{
    let parent = main_path.parent().ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            "raw export pair has no parent directory",
        )
    })?;
    if sidecar_path.parent() != Some(parent) || marker_path.parent() != Some(parent) {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            "raw export pair and commit marker must share one parent directory",
        ));
    }

    let staged_main = attempt_directory.join("rgb.raw");
    let staged_sidecar = attempt_directory.join("infrared.tif");
    let staged_marker = attempt_directory.join("commit.json");
    write_synced_create_new(&staged_main, main_encoded)?;
    after_step(RawPairCommitStep::MainSynced)?;
    write_synced_create_new(&staged_sidecar, sidecar_encoded)?;
    after_step(RawPairCommitStep::InfraredSynced)?;

    let marker = RawPairCommitMarker {
        schema_version: RAW_PAIR_MARKER_SCHEMA_VERSION,
        transaction_id: transaction_id.to_string(),
        rgb: committed_file_description(main_path, main_encoded)?,
        infrared: committed_file_description(sidecar_path, sidecar_encoded)?,
    };
    let marker_bytes = serde_json::to_vec_pretty(&marker).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("failed to serialize raw export pair commit marker: {error}"),
        )
    })?;
    write_synced_create_new(&staged_marker, &marker_bytes)?;
    sync_output_directory(attempt_directory).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to sync raw export attempt directory {}: {error}",
                attempt_directory.display()
            ),
        )
    })?;
    after_step(RawPairCommitStep::AttemptDirectorySynced)?;

    publish_no_replace(&staged_main, main_path, "raw RGB file")?;
    state.main_published = true;
    after_step(RawPairCommitStep::MainPublished)?;
    publish_no_replace(&staged_sidecar, sidecar_path, "raw infrared file")?;
    state.sidecar_published = true;
    after_step(RawPairCommitStep::InfraredPublished)?;
    sync_output_directory(parent).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to sync raw export directory {} before pair commit: {error}",
                parent.display()
            ),
        )
    })?;
    after_step(RawPairCommitStep::FinalFilesDirectorySynced)?;

    publish_no_replace(&staged_marker, marker_path, "raw pair commit marker")?;
    state.marker_published = true;
    after_step(RawPairCommitStep::MarkerPublished)?;
    sync_output_directory(parent).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to sync raw export directory {} after pair commit: {error}",
                parent.display()
            ),
        )
    })?;
    after_step(RawPairCommitStep::CommitDirectorySynced)
}

#[cfg(test)]
fn rollback_raw_pair_publication(
    parent: &Path,
    main_path: &Path,
    sidecar_path: &Path,
    marker_path: &Path,
    state: &RawPairPublicationState,
) {
    if state.marker_published {
        let _ = std::fs::remove_file(marker_path);
        let _ = sync_output_directory(parent);
    }
    if state.sidecar_published {
        let _ = std::fs::remove_file(sidecar_path);
    }
    if state.main_published {
        let _ = std::fs::remove_file(main_path);
    }
    if state.main_published || state.sidecar_published {
        let _ = sync_output_directory(parent);
    }
}

#[cfg(test)]
fn write_single_raw_create_only(path: &Path, encoded: &[u8]) -> Result<(), domain::EngineError> {
    let parent = path.parent().ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("raw export has no parent directory: {}", path.display()),
        )
    })?;
    let (temporary, file) = create_private_file(parent, "raw")?;
    let result = (|| {
        let mut writer = std::io::BufWriter::new(file);
        writer.write_all(encoded).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to write staged raw export: {error}"),
            )
        })?;
        writer.flush().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to flush staged raw export: {error}"),
            )
        })?;
        writer.get_ref().sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to sync staged raw export: {error}"),
            )
        })?;
        drop(writer);
        publish_no_replace(&temporary, path, "raw export")?;
        sync_output_directory(parent).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to sync raw export directory {}: {error}",
                    parent.display()
                ),
            )
        })
    })();
    let _ = std::fs::remove_file(&temporary);
    result
}

#[cfg(test)]
fn write_raw_export_create_only(
    path: &Path,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    dpi: u32,
    recipe: &domain::RawExportRecipe,
    ir_available: bool,
) -> Result<Option<PathBuf>, domain::EngineError> {
    let parent = path.parent().ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            "raw export has no parent directory",
        )
    })?;
    std::fs::create_dir_all(parent).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to create raw export directory {}: {error}",
                parent.display()
            ),
        )
    })?;
    let sidecar_path = (ir_available && recipe.tiff_infrared == domain::RawTiffInfrared::Sidecar)
        .then(|| raw_export_ir_sidecar_path(path));
    let marker_path = sidecar_path
        .as_ref()
        .map(|_| raw_export_pair_commit_marker_path(path))
        .transpose()?;
    for candidate in std::iter::once(path)
        .chain(sidecar_path.as_deref())
        .chain(marker_path.as_deref())
    {
        if path_entry_exists(candidate)? {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::ArchiveCollision,
                format!(
                    "raw export target already exists at {}; raw outputs are create-only",
                    candidate.display()
                ),
            ));
        }
    }

    let encoded = encoded_simulated_raw(raw, width, height, dpi, recipe, ir_available)?;
    let Some(sidecar_path) = sidecar_path else {
        write_single_raw_create_only(path, &encoded)?;
        return Ok(None);
    };
    let marker_path = marker_path.expect("sidecar raw export always reserves a marker");
    let sidecar_encoded = encoded_simulated_raw_ir(raw, width, height, dpi)?;
    let (attempt_directory, transaction_id) = create_private_directory(parent, "raw-pair")?;
    let mut state = RawPairPublicationState::default();
    let result = execute_raw_pair_transaction(
        &attempt_directory,
        &transaction_id,
        path,
        &encoded,
        &sidecar_path,
        &sidecar_encoded,
        &marker_path,
        &mut state,
        |_| Ok(()),
    )
    .and_then(|()| validate_raw_export_pair_commit(path, &sidecar_path));
    if result.is_err() {
        rollback_raw_pair_publication(parent, path, &sidecar_path, &marker_path, &state);
    }
    let _ = std::fs::remove_dir_all(&attempt_directory);
    let _ = sync_output_directory(parent);
    result.map(|()| Some(sidecar_path))
}

/// Color/metadata to attach to a rendered derivative. It distinguishes two
/// independent guarantees:
///
/// * the color-profile contract — only a C41 color-negative render actually
///   produces Adobe RGB-family encoded values (see `render_positive`); the
///   positive-film/Kodachrome passthrough and the B&W inversion are not
///   Adobe RGB-encoded and must not be falsely labeled with that profile;
/// * the physical DPI scale — only the full-resolution positive is at the
///   capture recipe's DPI; the downsampled preview is not, so it must never
///   claim the capture DPI as its own.
#[derive(Debug, Clone, Copy)]
struct DerivativeMetadata {
    /// Capture recipe's DPI, written as the Positive TIFF's
    /// XResolution/YResolution in pixels/inch. `None` for the downsampled
    /// preview (and for any JPEG, which has no such resolution tags here).
    resolution_dpi: Option<u32>,
    /// Whether to embed ScanStudio's Adobe RGB (1998)-compatible ICC profile.
    attach_icc: bool,
}

impl DerivativeMetadata {
    /// Only the C41 color-negative path (nikonlook) produces the Adobe
    /// RGB-family encoding the profile labels; all other processes leave the
    /// buffer passthrough or grayscale and must stay unprofiled.
    fn attach_icc(film_process: domain::FilmProcess) -> bool {
        film_process == domain::FilmProcess::C41ColorNegative
    }

    /// Full-resolution positive output at the capture recipe's DPI.
    fn positive(film_process: domain::FilmProcess, resolution_dpi: u32) -> Self {
        Self {
            resolution_dpi: Some(resolution_dpi),
            attach_icc: Self::attach_icc(film_process),
        }
    }

    /// Downsampled preview output: same color contract as the positive, but
    /// never tagged at the capture DPI it was scaled down from.
    fn preview(film_process: domain::FilmProcess) -> Self {
        Self {
            resolution_dpi: None,
            attach_icc: Self::attach_icc(film_process),
        }
    }
}

/// Encodes a TIFF derivative directly with the `tiff` crate so the metadata
/// the `image` crate's higher-level TiffEncoder omits (resolution tags and
/// the ICC profile) can be written in the same pass. `bit_depth` is 8 or 16
/// (derivatives always force 16 for TIFF / 8 for JPEG -- see
/// `write_derivative`). The ICC profile is embedded only when the render is
/// actually Adobe RGB-encoded (C41), and the DPI resolution tags only when
/// the derivative is at the capture's physical scale (the full-resolution
/// positive), never the downsampled preview.
fn write_tiff_with_metadata<W: std::io::Write + std::io::Seek>(
    writer: W,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    bit_depth: u32,
    metadata: &DerivativeMetadata,
) -> Result<(), domain::EngineError> {
    use tiff::encoder::colortype::RGB16;
    use tiff::encoder::colortype::RGB8;
    use tiff::encoder::TiffEncoder;

    if bit_depth == 8 {
        let samples = to_u8_samples(raw);
        let mut encoder = TiffEncoder::new(writer).map_err(metadata_encode_error)?;
        let mut image = encoder
            .new_image::<RGB8>(width, height)
            .map_err(metadata_encode_error)?;
        emit_tiff_metadata(image.encoder(), metadata)?;
        image.write_data(&samples).map_err(metadata_encode_error)
    } else {
        let samples = to_u16_samples(raw);
        let mut encoder = TiffEncoder::new(writer).map_err(metadata_encode_error)?;
        let mut image = encoder
            .new_image::<RGB16>(width, height)
            .map_err(metadata_encode_error)?;
        emit_tiff_metadata(image.encoder(), metadata)?;
        image.write_data(&samples).map_err(metadata_encode_error)
    }
}

/// TIFF/EP requires the ICC profile tag (34675) to use field type UNDEFINED,
/// not BYTE. A bare `&[u8]` implements `TiffValue` as BYTE, which is readable
/// by tolerant software but non-conforming and rejected by strict validators.
struct IccProfileValue<'a>(&'a [u8]);

impl tiff::encoder::TiffValue for IccProfileValue<'_> {
    const BYTE_LEN: u8 = 1;
    const FIELD_TYPE: tiff::tags::Type = tiff::tags::Type::UNDEFINED;

    fn count(&self) -> usize {
        self.0.len()
    }

    fn data(&self) -> std::borrow::Cow<'_, [u8]> {
        std::borrow::Cow::Borrowed(self.0)
    }
}

/// Writes the metadata selected by `metadata` onto a TIFF directory encoder
/// before its pixel data:
///
/// * the ScanStudio RGB compatible ICC profile, iff `metadata.attach_icc` (C41);
/// * `XResolution`/`YResolution`/`ResolutionUnit` = pixels/inch at
///   `metadata.resolution_dpi`, iff it is `Some` (the full-resolution
///   positive only).
///
/// Every metadata write must succeed or the derivative is rejected
/// (fail-closed) rather than silently unlabeled. A zero DPI is untruthful
/// and refused rather than emitting an undefined resolution unit.
fn emit_tiff_metadata<W: std::io::Write + std::io::Seek>(
    ifd: &mut tiff::encoder::DirectoryEncoder<'_, W, tiff::encoder::TiffKindStandard>,
    metadata: &DerivativeMetadata,
) -> Result<(), domain::EngineError> {
    use tiff::encoder::Rational;
    use tiff::tags::ResolutionUnit;
    use tiff::tags::Tag;

    if metadata.attach_icc {
        let profile = crate::icc::scanstudio_rgb_icc_profile()?;
        ifd.write_tag(Tag::IccProfile, IccProfileValue(&profile[..]))
            .map_err(metadata_encode_error)?;
    }
    if let Some(resolution_dpi) = metadata.resolution_dpi {
        if resolution_dpi == 0 {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("cannot embed a truthful DPI metadata tag for a {resolution_dpi} DPI capture recipe"),
            ));
        }
        ifd.write_tag(
            Tag::XResolution,
            Rational {
                n: resolution_dpi,
                d: 1,
            },
        )
        .map_err(metadata_encode_error)?;
        ifd.write_tag(
            Tag::YResolution,
            Rational {
                n: resolution_dpi,
                d: 1,
            },
        )
        .map_err(metadata_encode_error)?;
        ifd.write_tag(Tag::ResolutionUnit, ResolutionUnit::Inch)
            .map_err(metadata_encode_error)?;
    }
    Ok(())
}

fn metadata_encode_error(error: tiff::TiffError) -> domain::EngineError {
    domain::EngineError::new(
        protocol::ErrorCode::Internal,
        format!("failed to encode derivative TIFF metadata: {error}"),
    )
}

/// Encodes a JPEG derivative with the `image`-crate JPEG encoder, embedding
/// the ScanStudio RGB compatible ICC profile when the render is Adobe RGB-encoded
/// (C41). JPEG carries no resolution tags here, so DPI is never written for
/// JPEG even for the full-resolution positive. The default quality equals the
/// historical `DynamicImage::write_to(ImageFormat::Jpeg)` path, preserving
/// the 8-bit sample encoding.
fn write_jpeg_with_metadata<W: std::io::Write>(
    writer: W,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    metadata: &DerivativeMetadata,
) -> Result<(), domain::EngineError> {
    use image::codecs::jpeg::JpegEncoder;
    use image::{ExtendedColorType, ImageEncoder};

    let samples = to_u8_samples(raw);
    let mut encoder = JpegEncoder::new(writer);
    if metadata.attach_icc {
        let profile = crate::icc::scanstudio_rgb_icc_profile()?;
        encoder.set_icc_profile(profile).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to attach derivative JPEG ICC profile: {error}"),
            )
        })?;
    }
    encoder
        .encode(&samples, width, height, ExtendedColorType::Rgb8)
        .map_err(jpeg_encode_error)
}

fn jpeg_encode_error(error: image::ImageError) -> domain::EngineError {
    domain::EngineError::new(
        protocol::ErrorCode::Internal,
        format!("failed to encode derivative JPEG: {error}"),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DerivativeCommitStep {
    TemporaryReserved,
    FileSynced,
    FinalPublished,
}

#[cfg(any(unix, windows))]
fn write_derivative_authorized_with_hook<Hook>(
    output: &AuthorizedOutputLeaf,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    format: domain::OutputFileFormat,
    metadata: &DerivativeMetadata,
    mut after_step: Hook,
) -> Result<PublishedFileProof, domain::EngineError>
where
    Hook: FnMut(DerivativeCommitStep) -> Result<(), domain::EngineError>,
{
    let (temporary, file) = destination_sys::reserve_private_sibling(
        &output.destination.inner,
        &output.final_name,
        "derivative",
    )?;
    let cleanup_file = match file.try_clone() {
        Ok(file) => file,
        Err(error) => {
            cleanup_authorized_temporary(output, &temporary, &file);
            return Err(domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("retain staged {} cleanup identity: {error}", output.role),
            ));
        }
    };
    let result = (|| {
        after_step(DerivativeCommitStep::TemporaryReserved)?;
        let mut writer = std::io::BufWriter::new(file);
        match format {
            domain::OutputFileFormat::Jpeg => {
                write_jpeg_with_metadata(&mut writer, raw, width, height, metadata)
            }
            domain::OutputFileFormat::Tiff => {
                write_tiff_with_metadata(&mut writer, raw, width, height, 16, metadata)
            }
        }?;
        writer.flush().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to flush staged {} derivative: {error}", output.role),
            )
        })?;
        writer.get_ref().sync_all().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to sync staged {} derivative: {error}", output.role),
            )
        })?;
        let published_file = writer.get_ref().try_clone().map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to retain staged {} identity: {error}", output.role),
            )
        })?;
        drop(writer);
        after_step(DerivativeCommitStep::FileSynced)?;
        destination_sys::publish(
            &output.destination.inner,
            &temporary,
            &output.final_name,
            &published_file,
            output.create_only,
            output.role,
        )?;
        after_step(DerivativeCommitStep::FinalPublished)?;
        authorized_published_file_proof(output, published_file)
    })();
    if result.is_err() {
        cleanup_authorized_temporary(output, &temporary, &cleanup_file);
    }
    result
}

#[cfg(not(any(unix, windows)))]
fn write_derivative_authorized_with_hook<Hook>(
    output: &AuthorizedOutputLeaf,
    _raw: &[[f64; 3]],
    _width: u32,
    _height: u32,
    _format: domain::OutputFileFormat,
    _metadata: &DerivativeMetadata,
    _after_step: Hook,
) -> Result<PublishedFileProof, domain::EngineError>
where
    Hook: FnMut(DerivativeCommitStep) -> Result<(), domain::EngineError>,
{
    Err(output_authority_error(format!(
        "{} publication at {} is unavailable without reparse-safe handle-relative operations",
        output.role,
        output.final_path.display()
    )))
}

fn write_derivative_authorized(
    output: &AuthorizedOutputLeaf,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    format: domain::OutputFileFormat,
    metadata: &DerivativeMetadata,
) -> Result<PublishedFileProof, domain::EngineError> {
    write_derivative_authorized_with_hook(output, raw, width, height, format, metadata, |_| Ok(()))
}

/// Publishes a completely encoded and synced private sibling at the final
/// leaf. Auto-sequenced outputs use an atomic same-directory hard link, so
/// publishing is create-only even if another process creates the leaf after
/// preflight. Custom outputs retain their established atomic-replace policy.
/// Neither mode follows or truncates a symlink/hardlink leaf during encoding.
/// TIFF derivatives always encode at 16-bit
/// (derivatives carry no bit-depth choice of their own the way the archive's
/// `CaptureRecipe.bit_depth` does -- 16-bit is the max fidelity a `[0,1]`
/// float sample can be quantized to); JPEG has no 16-bit mode, so it always
/// encodes at 8-bit regardless of the capture's own bit depth.
///
/// `metadata` carries the color-profile contract (ICC only for C41) and the
/// physical DPI scale (only the full-resolution positive), so the right
/// metadata is attached per derivative: TIFF carries ICC and optionally DPI;
/// JPEG carries ICC only (it has no resolution tags in this encoder).
#[cfg(test)]
fn write_derivative(
    path: &std::path::Path,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    format: domain::OutputFileFormat,
    create_only: bool,
    metadata: &DerivativeMetadata,
) -> Result<PublishedFileProof, domain::EngineError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|err| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to create derivative directory {}: {err}",
                    parent.display()
                ),
            )
        })?;
    }

    // TIFF derivatives are written by the direct `tiff`-crate encoder (ICC +
    // optional DPI); JPEG is written by the `image`-crate JPEG encoder with
    // an optional ICC profile. Both preserve the quantized sample values.

    static TEMP_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let parent = path.parent().ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("derivative path has no parent: {}", path.display()),
        )
    })?;
    let final_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("derivative path has no file name: {}", path.display()),
            )
        })?;
    let mut reserved = None;
    for _ in 0..128 {
        let counter = TEMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let candidate = parent.join(format!(
            ".{final_name}.scanstudio-{}-{counter}.tmp",
            std::process::id()
        ));
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => {
                reserved = Some((candidate, file));
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!(
                        "failed to reserve derivative sibling beside {}: {error}",
                        path.display()
                    ),
                ))
            }
        }
    }
    let (temporary_path, file) = reserved.ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to reserve a unique derivative sibling beside {}",
                path.display()
            ),
        )
    })?;
    let mut writer = std::io::BufWriter::new(file);

    // TIFF derivatives carry ICC and optional resolution tags. JPEG carries
    // the same ICC contract when applicable, but no physical-resolution tag.
    let write_result = match format {
        domain::OutputFileFormat::Jpeg => {
            write_jpeg_with_metadata(&mut writer, raw, width, height, metadata)
        }
        domain::OutputFileFormat::Tiff => {
            write_tiff_with_metadata(&mut writer, raw, width, height, 16, metadata)
        }
    }
    .and_then(|_| {
        writer.flush().map_err(|err| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to flush derivative at {}: {err}", path.display()),
            )
        })
    })
    .and_then(|_| {
        writer.get_ref().sync_all().map_err(|err| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to sync derivative at {}: {err}", path.display()),
            )
        })
    });
    if let Err(error) = write_result {
        drop(writer);
        let _ = std::fs::remove_file(&temporary_path);
        return Err(error);
    }
    let published_file = writer.get_ref().try_clone().map_err(|error| {
        let _ = std::fs::remove_file(&temporary_path);
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to retain the staged derivative identity beside {}: {error}",
                path.display()
            ),
        )
    })?;
    drop(writer);
    if create_only {
        match std::fs::hard_link(&temporary_path, path) {
            Ok(()) => {
                std::fs::remove_file(&temporary_path).map_err(|error| {
                    domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        format!(
                            "created auto-sequenced derivative at {} but failed to remove its private sibling {}: {error}",
                            path.display(),
                            temporary_path.display()
                        ),
                    )
                })?;
            }
            Err(error) => {
                let _ = std::fs::remove_file(&temporary_path);
                let code = if error.kind() == std::io::ErrorKind::AlreadyExists {
                    protocol::ErrorCode::ArchiveCollision
                } else {
                    protocol::ErrorCode::Internal
                };
                return Err(domain::EngineError::new(
                    code,
                    format!(
                        "failed to publish create-only auto-sequenced derivative at {}: {error}",
                        path.display()
                    ),
                ));
            }
        }
    } else if let Err(error) = std::fs::rename(&temporary_path, path) {
        let _ = std::fs::remove_file(&temporary_path);
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to atomically replace derivative at {}: {error}",
                path.display()
            ),
        ));
    }
    sync_output_directory(parent).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to sync derivative directory {} after publication: {error}",
                parent.display()
            ),
        )
    })?;
    published_file_proof(path, published_file)
}

// ---------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------

/// Where a completed frame's files actually landed on this call.
#[derive(Debug)]
pub struct WrittenPaths {
    /// Retained user-visible master only. A real backend's private working
    /// capture is intentionally never represented here when master
    /// retention is disabled.
    pub archive_path: Option<std::path::PathBuf>,
    pub positive_path: Option<std::path::PathBuf>,
    pub preview_path: Option<std::path::PathBuf>,
    pub raw_negative_path: Option<std::path::PathBuf>,
    pub raw_negative_ir_path: Option<std::path::PathBuf>,
    /// Opaque held-descriptor proofs for metadata-capable publications.
    /// Receipt construction consumes these only through ExifTool's
    /// proof-aware binder; the display paths above are never reinterpreted as
    /// authority.
    pub(crate) metadata_publications: MetadataPublicationProofs,
    /// See `render_positive`'s own doc comment. `None` whenever no
    /// positive/preview was rendered this call, or the rendered frame
    /// wasn't C41.
    pub nikonlook: Option<domain::NikonlookProvenance>,
    /// Scan-time non-destructive auto-crop decision. `None` when the recipe
    /// did not request auto-crop or no derivative rendered.
    pub auto_crop: Option<domain::AutoCropOutcome>,
    pub derivative_transform: domain::DerivativeTransform,
}

/// Renders one frame's deterministic simulated pixel data and writes the
/// optional retained archive (create-only) plus the positive/preview derivatives
/// (each only if their recipe is `enabled`, overwrite-ok). Refuses to write
/// a derivative whose resolved path aliases the archive's (T-03-04).
///
/// A retained archive receives the full, uncropped capture. An approved
/// `alignment` is applied only to the derived outputs, using
/// `detected_boundary` as the base frame edge. This keeps a retained archive
/// master byte-identical regardless of any crop setting.
pub fn render_and_write_frame(
    device_id: &str,
    frame_index: u32,
    film_process: domain::FilmProcess,
    width: u32,
    height: u32,
    bit_depth: u32,
    recipes: &domain::OutputRecipe,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
) -> Result<WrittenPaths, domain::EngineError> {
    let processing = domain::ProcessingRecipe {
        film_process,
        ..domain::ProcessingRecipe::default()
    };
    render_and_write_frame_with_processing(
        device_id,
        frame_index,
        &processing,
        width,
        height,
        bit_depth,
        domain::CaptureRecipe::default().resolution_dpi,
        true,
        recipes,
        detected_boundary,
        alignment,
    )
}

/// Processing-aware simulated derivative path. `software_dust_removal_bw`
/// is opt-in and affects derivative buffers only.
pub fn render_and_write_frame_with_processing(
    device_id: &str,
    frame_index: u32,
    processing: &domain::ProcessingRecipe,
    width: u32,
    height: u32,
    bit_depth: u32,
    resolution_dpi: u32,
    raw_ir_available: bool,
    recipes: &domain::OutputRecipe,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
) -> Result<WrittenPaths, domain::EngineError> {
    let fallback_recipe = domain::CaptureRecipe {
        channels: if raw_ir_available {
            domain::Channels::Rgbi
        } else {
            domain::Channels::Rgb
        },
        ..domain::CaptureRecipe::default()
    };
    let fallback_authorities = acquire_job_output_authorities(
        None,
        &[frame_index],
        &fallback_recipe,
        recipes,
        &std::collections::HashMap::new(),
    )?;
    render_and_write_frame_with_processing_authorized(
        device_id,
        frame_index,
        processing,
        width,
        height,
        bit_depth,
        resolution_dpi,
        raw_ir_available,
        recipes,
        detected_boundary,
        alignment,
        fallback_authorities.frame(frame_index)?,
    )
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn render_and_write_frame_with_processing_authorized(
    device_id: &str,
    frame_index: u32,
    processing: &domain::ProcessingRecipe,
    width: u32,
    height: u32,
    bit_depth: u32,
    resolution_dpi: u32,
    raw_ir_available: bool,
    recipes: &domain::OutputRecipe,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
    authorities: &FrameOutputAuthorities,
) -> Result<WrittenPaths, domain::EngineError> {
    let derivative_transform = alignment
        .map(|value| value.derivative_transform)
        .unwrap_or_default();
    validate_derivative_transform(derivative_transform)?;
    validate_output_recipe_paths(recipes)?;
    let (
        _archive_path,
        preflight_positive_path,
        preflight_preview_path,
        preflight_raw_path,
        preflight_raw_ir_path,
    ) = validate_frame_output_paths_with_raw_ir(recipes, frame_index, raw_ir_available)?;
    let raw = generate_sim_frame(device_id, frame_index, width, height);
    let archive_proof = authorities
        .archive
        .as_ref()
        .map(|archive| write_tiff_create_only_authorized(archive, &raw, width, height, bit_depth))
        .transpose()?;
    let archive_path = authorities
        .archive
        .as_ref()
        .map(|archive| archive.final_path.clone());
    let (raw_negative_path, raw_negative_ir_path) = if preflight_raw_path.is_some() {
        let written_ir_path = write_raw_export_create_only_authorized(
            &raw,
            width,
            height,
            resolution_dpi,
            &recipes.raw_export,
            raw_ir_available,
            authorities,
        )?;
        let _ = preflight_raw_ir_path.as_ref();
        (
            authorities
                .raw
                .as_ref()
                .map(|output| output.final_path.clone()),
            written_ir_path,
        )
    } else {
        (None, None)
    };

    let mut positive_path: Option<std::path::PathBuf> = None;
    let mut preview_path: Option<std::path::PathBuf> = None;
    let mut positive_proof = None;
    let mut preview_proof = None;
    let mut nikonlook_provenance: Option<domain::NikonlookProvenance> = None;
    let mut auto_crop_outcome: Option<domain::AutoCropOutcome> = None;

    if recipes.positive.enabled || recipes.preview.enabled {
        if recipes.auto_crop {
            auto_crop_outcome = Some(if alignment.is_some_and(|value| value.approved) {
                auto_crop_deferred_to_alignment(width, height)
            } else {
                detect_auto_crop(&raw, width, height)
            });
        }
        // Computed once -- both derivatives share it rather than each
        // calling render_positive (and thus reloading/re-estimating
        // nikonlook) independently. The simulator has no hardware exposure
        // to report, so nikonlook v2 always uses its blind fallback here.
        let (positive_raw_full, provenance) =
            render_positive(processing.film_process, &raw, width as usize, None)?;
        nikonlook_provenance = provenance;
        let positive_raw_full = if processing.film_process == domain::FilmProcess::BwNegative
            && processing.software_dust_removal_bw
        {
            software_dust_remove_bw_owned(positive_raw_full, width, height)
        } else {
            positive_raw_full
        };
        let (mut positive_raw, mut positive_width, mut positive_height) = match &auto_crop_outcome {
            Some(outcome) if outcome.applied => {
                let roi = outcome
                    .roi
                    .as_ref()
                    .expect("applied auto-crop outcome carries its ROI");
                crop_to_roi(&positive_raw_full, width, roi)
            }
            _ => apply_alignment_crop(
                &positive_raw_full,
                width,
                height,
                detected_boundary,
                alignment,
            ),
        };
        (positive_width, positive_height) = apply_derivative_transform_in_place(
            &mut positive_raw,
            positive_width,
            positive_height,
            derivative_transform,
        )?;

        let positive_metadata =
            DerivativeMetadata::positive(processing.film_process, resolution_dpi);
        let preview_metadata = DerivativeMetadata::preview(processing.film_process);

        if recipes.positive.enabled {
            let output = authorities.positive.as_ref().ok_or_else(|| {
                output_authority_error("enabled positive has no held destination authority")
            })?;
            let _ = preflight_positive_path.as_ref();
            positive_proof = Some(write_derivative_authorized(
                output,
                &positive_raw,
                positive_width,
                positive_height,
                recipes.positive.file_format,
                &positive_metadata,
            )?);
            positive_path = Some(output.final_path.clone());
        }

        if recipes.preview.enabled {
            let (preview_width, preview_height) = downsample_dimensions(
                positive_width,
                positive_height,
                recipes.preview.max_long_edge_px,
            );
            let preview_raw = downsample_nearest(
                &positive_raw,
                positive_width,
                positive_height,
                preview_width,
                preview_height,
            );
            let output = authorities.preview.as_ref().ok_or_else(|| {
                output_authority_error("enabled preview has no held destination authority")
            })?;
            let _ = preflight_preview_path.as_ref();
            preview_proof = Some(write_derivative_authorized(
                output,
                &preview_raw,
                preview_width,
                preview_height,
                recipes.preview.file_format,
                &preview_metadata,
            )?);
            preview_path = Some(output.final_path.clone());
        }
    }

    Ok(WrittenPaths {
        archive_path,
        positive_path,
        preview_path,
        raw_negative_path,
        raw_negative_ir_path,
        metadata_publications: MetadataPublicationProofs {
            archive: archive_proof,
            archive_ir: None,
            archive_meter: None,
            positive: positive_proof,
            preview: preview_proof,
        },
        nikonlook: nikonlook_provenance,
        auto_crop: auto_crop_outcome,
        derivative_transform,
    })
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn software_bw_dust_removal_corrects_isolated_bright_and_dark_specks_but_preserves_edges() {
        let mut pixels = vec![[0.5; 3]; 121];
        pixels[24] = [1.0; 3];
        pixels[96] = [0.0; 3];
        // A high-contrast edge has unlike neighbours and must fail closed.
        pixels[110] = [1.0; 3];
        let cleaned = software_dust_remove_bw(&pixels, 11, 11);
        assert_eq!(cleaned[24], [0.5; 3]);
        assert_eq!(cleaned[96], [0.5; 3]);
        assert_eq!(cleaned[110], [1.0; 3]);
        assert_eq!(cleaned, software_dust_remove_bw(&pixels, 11, 11));
    }

    #[test]
    fn software_bw_dust_removal_inpaints_compact_two_by_two_bright_and_dark_blobs() {
        let mut bright = vec![[0.5; 3]; 225];
        for index in [112, 113, 127, 128] {
            bright[index] = [1.0; 3];
        }
        let cleaned_bright = software_dust_remove_bw(&bright, 15, 15);
        for index in [112, 113, 127, 128] {
            assert_eq!(cleaned_bright[index], [0.5; 3]);
        }

        let mut dark = vec![[0.5; 3]; 225];
        for index in [112, 113, 127, 128] {
            dark[index] = [0.0; 3];
        }
        let cleaned_dark = software_dust_remove_bw(&dark, 15, 15);
        for index in [112, 113, 127, 128] {
            assert_eq!(cleaned_dark[index], [0.5; 3]);
        }
    }

    #[test]
    fn software_bw_dust_removal_inpaints_three_by_three_without_touching_interior_edge_detail() {
        let mut dust = vec![[0.5; 3]; 225];
        for y in 6..=8 {
            for x in 6..=8 {
                dust[y * 15 + x] = [1.0; 3];
            }
        }
        let cleaned = software_dust_remove_bw(&dust, 15, 15);
        for y in 6..=8 {
            for x in 6..=8 {
                assert_eq!(cleaned[y * 15 + x], [0.5; 3]);
            }
        }

        let mut edge = vec![[0.1; 3]; 225];
        for y in 2..13 {
            for x in 8..13 {
                edge[y * 15 + x] = [0.9; 3];
            }
        }
        edge[7 * 15 + 7] = [0.9; 3]; // one-pixel legitimate line/detail beside the step
        let preserved = software_dust_remove_bw(&edge, 15, 15);
        assert_eq!(preserved, edge, "interior edge/detail must fail closed");
    }

    #[test]
    fn software_bw_dust_removal_does_not_absorb_an_adjacent_opposite_polarity_detail() {
        let mut pixels = vec![[0.5; 3]; 225];
        // Only the lower-right bright pixel is a clean seed: the other
        // three bright pixels contaminate the dark detail's ring, making
        // that legitimate dark pixel non-candidate. Older absolute-residual
        // expansion nevertheless swallowed it from the bright seed.
        for (x, y) in [(6, 6), (7, 6), (6, 7), (7, 7)] {
            pixels[y * 15 + x] = [1.0; 3];
        }
        let dark_detail = 7 * 15 + 8;
        pixels[dark_detail] = [0.0; 3];

        let cleaned = software_dust_remove_bw(&pixels, 15, 15);
        assert_eq!(
            cleaned[7 * 15 + 7],
            [0.5; 3],
            "the bright dust seed is repaired"
        );
        assert_eq!(
            cleaned[dark_detail], [0.0; 3],
            "opposite-polarity detail is preserved"
        );
    }

    fn unique_test_dir() -> std::path::PathBuf {
        static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "scanstudio-render-test-{}-{n}",
            crate::manifest::generate_project_id(),
        ))
    }

    #[cfg(unix)]
    #[test]
    fn project_root_alias_normalization_keeps_child_links_visible_to_nofollow_acquisition() {
        use std::os::unix::fs::symlink;

        let project = unique_test_dir();
        let alias = project.with_extension("alias");
        let outside = unique_test_dir();
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        symlink(&project, &alias).unwrap();
        symlink(&outside, project.join("linked-child")).unwrap();
        let project_root = acquire_project_output_root_authority(Some(&project))
            .unwrap()
            .unwrap();

        let mut output = domain::OutputRecipe::default();
        output.archive.destination = alias.join("Archive").display().to_string();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        normalize_output_recipe_project_aliases(&project_root, &mut output).unwrap();
        assert_eq!(
            Path::new(&output.archive.destination),
            project_root.canonical_path().join("Archive")
        );

        output.archive.destination = alias
            .join("linked-child")
            .join("Archive")
            .display()
            .to_string();
        normalize_output_recipe_project_aliases(&project_root, &mut output).unwrap();
        let error = acquire_job_output_authorities_with_project_root(
            Some(&project_root),
            &[1],
            &domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .expect_err("a child symlink must remain visible and fail the held no-follow walk");
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(!outside.join("Archive").exists());

        let _ = std::fs::remove_file(project.join("linked-child"));
        let _ = std::fs::remove_file(&alias);
        let _ = std::fs::remove_dir_all(&project);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[cfg(unix)]
    #[test]
    fn held_archive_destination_refuses_existing_directory_swap_before_publication() {
        use std::os::unix::fs::symlink;

        let project = unique_test_dir();
        let destination = project.join("archive");
        let displaced = project.join("archive-held");
        let outside = unique_test_dir();
        std::fs::create_dir_all(&destination).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("sentinel"), b"unchanged").unwrap();

        let mut output = domain::OutputRecipe::default();
        output.archive.destination = destination.display().to_string();
        output.archive.filename_template = "master.tif".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let recipe = domain::CaptureRecipe::default();
        let authorities = acquire_job_output_authorities(
            Some(&project),
            &[1],
            &recipe,
            &output,
            &std::collections::HashMap::new(),
        )
        .unwrap();
        let archive = authorities.frame(1).unwrap().archive.as_ref().unwrap();
        let raw = vec![[0.25, 0.5, 0.75]; 48];
        let mut swapped = false;
        let error = write_tiff_create_only_authorized_with_hook(archive, &raw, 8, 6, 16, |step| {
            if step == ArchiveCommitStep::FileSynced && !swapped {
                std::fs::rename(&destination, &displaced).unwrap();
                symlink(&outside, &destination).unwrap();
                swapped = true;
            }
            Ok(())
        })
        .unwrap_err();
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(error.message.contains("authority") || error.message.contains("without following"));
        assert_eq!(
            std::fs::read(outside.join("sentinel")).unwrap(),
            b"unchanged"
        );
        assert!(!outside.join("master.tif").exists());

        let _ = std::fs::remove_file(&destination);
        let _ = std::fs::remove_dir_all(&project);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[cfg(unix)]
    #[test]
    fn evidence_root_acquisition_never_mutates_a_replacement_destination() {
        let project = unique_test_dir();
        let destination = project.join("archive");
        let displaced = project.join("archive-held");
        std::fs::create_dir_all(&destination).unwrap();

        let mut output = domain::OutputRecipe::default();
        output.archive.destination = destination.display().to_string();
        output.archive.filename_template = "master.tif".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let authorities = acquire_job_output_authorities(
            Some(&project),
            &[1],
            &domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .unwrap();
        let held_archive = &authorities.evidence_destinations[0].destination;

        let error = acquire_held_child_directory_with_hook(
            held_archive,
            std::ffi::OsStr::new("Capture Evidence"),
            "capture evidence root",
            || {
                std::fs::rename(&destination, &displaced).unwrap();
                std::fs::create_dir(&destination).unwrap();
                std::fs::write(destination.join("sentinel"), b"unchanged").unwrap();
                Ok(())
            },
        )
        .expect_err("the replaced archive namespace must be refused");

        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert_eq!(
            std::fs::read(destination.join("sentinel")).unwrap(),
            b"unchanged"
        );
        assert!(
            !destination.join("Capture Evidence").exists(),
            "handle-relative acquisition must not create anything in the replacement"
        );
        assert!(
            displaced.join("Capture Evidence").is_dir(),
            "the relative mutation remains confined to the originally held directory"
        );

        let _ = std::fs::remove_dir_all(&project);
    }

    #[test]
    fn later_evidence_reservation_collision_rolls_back_every_earlier_package() {
        let project = unique_test_dir();
        let archive_a = project.join("archive-a");
        let archive_b = project.join("archive-b");
        std::fs::create_dir_all(&archive_a).unwrap();
        std::fs::create_dir_all(&archive_b).unwrap();

        let mut output = domain::OutputRecipe::default();
        output.archive.destination = archive_a.display().to_string();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let mut frame_two_output = output.clone();
        frame_two_output.archive.destination = archive_b.display().to_string();
        let mut overrides = std::collections::HashMap::new();
        overrides.insert(
            2,
            domain::FrameOverrides {
                output: Some(frame_two_output),
                ..domain::FrameOverrides::default()
            },
        );

        let mut authorities = acquire_job_output_authorities(
            Some(&project),
            &[1, 2],
            &domain::CaptureRecipe::default(),
            &output,
            &overrides,
        )
        .unwrap();
        let job_id = "transactional-reservation-test";
        let raced_package = archive_b
            .join("Capture Evidence")
            .join(format!("{job_id}.scanstudio"));
        let foreign_marker = raced_package.join("foreign.txt");

        let error = authorities
            .reserve_evidence_packages_with_hook(job_id, |index, _| {
                if index == 0 {
                    std::fs::create_dir(&raced_package).unwrap();
                    std::fs::write(&foreign_marker, b"foreign package").unwrap();
                }
                Ok(())
            })
            .expect_err("the second create-only package reservation must collide");

        assert_eq!(error.code, protocol::ErrorCode::ArchiveCollision);
        let earlier_package = archive_a
            .join("Capture Evidence")
            .join(format!("{job_id}.scanstudio"));
        #[cfg(windows)]
        assert!(
            !earlier_package.exists(),
            "Windows must retire the earlier exact empty reservation by handle"
        );
        #[cfg(unix)]
        {
            assert!(
                earlier_package.is_dir(),
                "Unix must preserve the earlier reservation rather than risk name-based deletion"
            );
            assert!(error.message.contains("HOLD"), "{error:?}");
            assert!(!error.recoverable());
        }
        assert_eq!(std::fs::read(&foreign_marker).unwrap(), b"foreign package");
        assert!(authorities.reserved_evidence_packages().is_empty());

        drop(authorities);
        let _ = std::fs::remove_dir_all(&project);
    }

    #[cfg(unix)]
    #[test]
    fn project_root_capability_cannot_rebless_a_replacement_after_preflight_capture() {
        use std::os::unix::fs::symlink;

        let project = unique_test_dir();
        let displaced = project.with_extension("held-project");
        let outside = unique_test_dir();
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("sentinel"), b"unchanged").unwrap();

        // This is the ordering enforced by server.rs: capture the root first,
        // then run pathname preflight/materialization, then acquire leaves
        // from that exact capability. Replacing the project pathname in the
        // middle must never turn the replacement into publication authority.
        let project_root = acquire_project_output_root_authority(Some(&project))
            .unwrap()
            .unwrap();
        std::fs::rename(&project, &displaced).unwrap();
        symlink(&outside, &project).unwrap();

        let mut output = domain::OutputRecipe::default();
        output.archive.destination = project.join("archive").display().to_string();
        output.archive.filename_template = "master.tif".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let error = acquire_job_output_authorities_with_project_root(
            Some(&project_root),
            &[1],
            &domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .expect_err("a replaced project root must be refused before leaf acquisition");
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(error.message.contains("project-root"), "{error}");
        assert_eq!(
            std::fs::read(outside.join("sentinel")).unwrap(),
            b"unchanged"
        );
        assert!(!outside.join("archive/master.tif").exists());
        assert!(
            !displaced.join("archive").exists(),
            "pre-motion refusal must happen before creating output directories"
        );

        let _ = std::fs::remove_file(&project);
        let _ = std::fs::remove_dir_all(&displaced);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[cfg(unix)]
    #[test]
    fn auto_sequence_discovery_refuses_a_replaced_project_root_before_enumeration() {
        use std::os::unix::fs::symlink;

        let project = unique_test_dir();
        let displaced = project.with_extension("held-sequence-project");
        let outside = unique_test_dir();
        std::fs::create_dir_all(project.join("Archive")).unwrap();
        std::fs::create_dir_all(outside.join("Archive")).unwrap();
        std::fs::write(project.join("Archive/ScanStudio7.tif"), b"held").unwrap();
        std::fs::write(outside.join("Archive/ScanStudio99.tif"), b"replacement").unwrap();
        std::fs::write(outside.join("sentinel"), b"unchanged").unwrap();
        let project_root = acquire_project_output_root_authority(Some(&project))
            .unwrap()
            .unwrap();
        std::fs::rename(&project, &displaced).unwrap();
        symlink(&outside, &project).unwrap();

        let mut output = domain::OutputRecipe::default();
        output.archive.destination = project.join("Archive").display().to_string();
        output.archive.filename_template = "ScanStudio#".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let mut overrides = std::collections::HashMap::new();
        let error = reserve_auto_sequence_filenames(
            Some(&project_root),
            &[1],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &output,
            &mut overrides,
        )
        .expect_err("sequence discovery must refuse before reading a replacement root");
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(error.message.contains("project-root"), "{error}");
        assert!(overrides.is_empty());
        assert_eq!(
            std::fs::read(outside.join("sentinel")).unwrap(),
            b"unchanged"
        );

        let _ = std::fs::remove_file(&project);
        let _ = std::fs::remove_dir_all(&displaced);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[cfg(unix)]
    #[test]
    fn held_derivative_destination_refuses_missing_suffix_swap_before_publication() {
        use std::os::unix::fs::symlink;

        let project = unique_test_dir();
        let swapped_ancestor = project.join("new");
        let destination = swapped_ancestor.join("deep/positive");
        let displaced = project.join("new-held");
        let outside = unique_test_dir();
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("sentinel"), b"unchanged").unwrap();

        let mut output = domain::OutputRecipe::default();
        output.archive.enabled = false;
        output.archive.full_capture_package = false;
        output.positive.enabled = true;
        output.positive.destination = destination.display().to_string();
        output.positive.filename_template = "positive.tif".into();
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let recipe = domain::CaptureRecipe::default();
        let authorities = acquire_job_output_authorities(
            Some(&project),
            &[1],
            &recipe,
            &output,
            &std::collections::HashMap::new(),
        )
        .unwrap();
        assert!(
            destination.is_dir(),
            "secure acquisition creates every missing suffix component"
        );
        let positive = authorities.frame(1).unwrap().positive.as_ref().unwrap();
        let raw = vec![[0.1, 0.4, 0.9]; 48];
        let metadata = DerivativeMetadata::positive(domain::FilmProcess::Positive, 4_000);
        let mut swapped = false;
        let error = write_derivative_authorized_with_hook(
            positive,
            &raw,
            8,
            6,
            domain::OutputFileFormat::Tiff,
            &metadata,
            |step| {
                if step == DerivativeCommitStep::FileSynced && !swapped {
                    std::fs::rename(&swapped_ancestor, &displaced).unwrap();
                    symlink(&outside, &swapped_ancestor).unwrap();
                    swapped = true;
                }
                Ok(())
            },
        )
        .unwrap_err();
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert_eq!(
            std::fs::read(outside.join("sentinel")).unwrap(),
            b"unchanged"
        );
        assert!(!outside.join("deep/positive/positive.tif").exists());

        let _ = std::fs::remove_file(&swapped_ancestor);
        let _ = std::fs::remove_dir_all(&project);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[cfg(unix)]
    #[test]
    fn held_raw_pair_destination_refuses_swap_before_commit_marker_publication() {
        use std::os::unix::fs::symlink;

        let project = unique_test_dir();
        let raw_destination = unique_test_dir();
        let displaced = raw_destination.with_extension("held");
        let outside = unique_test_dir();
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&raw_destination).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("sentinel"), b"unchanged").unwrap();

        let mut output = domain::OutputRecipe::default();
        output.archive.enabled = false;
        output.archive.full_capture_package = false;
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = true;
        output.raw_export.destination = raw_destination.display().to_string();
        output.raw_export.filename_template = "negative.dng".into();
        output.raw_export.tiff_infrared = domain::RawTiffInfrared::Sidecar;
        let recipe = domain::CaptureRecipe {
            channels: domain::Channels::Rgbi,
            ..domain::CaptureRecipe::default()
        };
        let authorities = acquire_job_output_authorities(
            Some(&project),
            &[1],
            &recipe,
            &output,
            &std::collections::HashMap::new(),
        )
        .unwrap();
        let raw = vec![[0.2, 0.4, 0.6]; 48];
        let mut swapped = false;
        let error = write_raw_export_create_only_authorized_with_hook(
            &raw,
            8,
            6,
            4_000,
            &output.raw_export,
            true,
            authorities.frame(1).unwrap(),
            |step| {
                if step == RawPairCommitStep::AttemptDirectorySynced && !swapped {
                    std::fs::rename(&raw_destination, &displaced).unwrap();
                    symlink(&outside, &raw_destination).unwrap();
                    swapped = true;
                }
                Ok(())
            },
        )
        .unwrap_err();
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert_eq!(
            std::fs::read(outside.join("sentinel")).unwrap(),
            b"unchanged"
        );
        assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 1);

        let _ = std::fs::remove_file(&raw_destination);
        let _ = std::fs::remove_dir_all(&displaced);
        let _ = std::fs::remove_dir_all(&project);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[cfg(unix)]
    #[test]
    fn held_authority_graph_rejects_two_lexical_destinations_with_one_physical_leaf() {
        use std::os::unix::fs::symlink;

        let root = unique_test_dir();
        let target = root.join("physical");
        let positive_alias = root.join("positive-alias");
        let preview_alias = root.join("preview-alias");
        std::fs::create_dir_all(&target).unwrap();
        symlink(&target, &positive_alias).unwrap();
        symlink(&target, &preview_alias).unwrap();

        let mut output = domain::OutputRecipe::default();
        output.archive.enabled = false;
        output.archive.full_capture_package = false;
        output.raw_export.enabled = false;
        output.positive.destination = positive_alias.display().to_string();
        output.positive.filename_template = "same.tif".into();
        output.positive.file_format = domain::OutputFileFormat::Tiff;
        output.preview.destination = preview_alias.display().to_string();
        output.preview.filename_template = "same.tif".into();
        output.preview.file_format = domain::OutputFileFormat::Tiff;

        let error = acquire_job_output_authorities(
            None,
            &[1],
            &domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .expect_err("physical alias must be rejected before rendering");
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(error.message.contains("physical output collision"));
        assert!(!target.join("same.tif").exists());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn held_create_only_vacancy_rejects_collision_before_rendering() {
        let project = unique_test_dir();
        let archive_directory = project.join("archive");
        std::fs::create_dir_all(&archive_directory).unwrap();
        let project_root = acquire_project_output_root_authority(Some(&project))
            .unwrap()
            .unwrap();
        let mut output = domain::OutputRecipe::default();
        output.archive.destination = archive_directory.display().to_string();
        output.archive.filename_template = "master.tif".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let existing = resolve_archive_output_path(&output, 1);
        std::fs::write(&existing, b"existing master").unwrap();

        let error = acquire_job_output_authorities_with_project_root(
            Some(&project_root),
            &[1],
            &domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .expect_err("held create-only collision must be refused before rendering");
        assert_eq!(error.code, protocol::ErrorCode::ArchiveCollision);
        assert!(error.message.contains("refusing before capture"));
        assert_eq!(std::fs::read(existing).unwrap(), b"existing master");

        let _ = std::fs::remove_dir_all(&project);
    }

    #[cfg(unix)]
    #[test]
    fn raw_beneath_project_uses_held_root_and_never_follows_later_replacement() {
        use std::os::unix::fs::symlink;

        let project = unique_test_dir();
        let displaced = project.with_extension("held-raw-project");
        let outside = unique_test_dir();
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("sentinel"), b"unchanged").unwrap();
        let project_root = acquire_project_output_root_authority(Some(&project))
            .unwrap()
            .unwrap();
        let mut output = domain::OutputRecipe::default();
        output.archive.enabled = false;
        output.archive.full_capture_package = false;
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = true;
        output.raw_export.destination = project.join("raw").display().to_string();
        output.raw_export.filename_template = "negative.dng".into();
        let authorities = acquire_job_output_authorities_with_project_root(
            Some(&project_root),
            &[1],
            &domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .unwrap();
        std::fs::rename(&project, &displaced).unwrap();
        symlink(&outside, &project).unwrap();

        let error = write_raw_export_create_only_authorized_with_hook(
            &vec![[0.2, 0.4, 0.6]; 48],
            8,
            6,
            4_000,
            &output.raw_export,
            false,
            authorities.frame(1).unwrap(),
            |_| Ok(()),
        )
        .expect_err("held project raw authority must refuse a later root replacement");
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert_eq!(
            std::fs::read(outside.join("sentinel")).unwrap(),
            b"unchanged"
        );
        assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 1);

        let _ = std::fs::remove_file(&project);
        let _ = std::fs::remove_dir_all(&displaced);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[test]
    fn retained_archive_set_rolls_back_earlier_publication_on_sidecar_collision() {
        let project = unique_test_dir();
        std::fs::create_dir_all(&project).unwrap();
        let mut output = domain::OutputRecipe::default();
        output.archive.destination = project.join("archive").display().to_string();
        output.archive.filename_template = "master.tif".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let recipe = domain::CaptureRecipe {
            channels: domain::Channels::Rgbi,
            ..domain::CaptureRecipe::default()
        };
        let authorities = acquire_job_output_authorities(
            Some(&project),
            &[1],
            &recipe,
            &output,
            &std::collections::HashMap::new(),
        )
        .unwrap();
        let frame = authorities.frame(1).unwrap();
        let rgb =
            stage_authorized_bytes(frame.archive.as_ref().unwrap(), b"rgb", "set-rgb").unwrap();
        let ir =
            stage_authorized_bytes(frame.archive_ir.as_ref().unwrap(), b"ir", "set-ir").unwrap();
        let meter =
            stage_authorized_bytes(frame.archive_meter.as_ref().unwrap(), b"meter", "set-meter")
                .unwrap();
        let rgb_path = frame.archive.as_ref().unwrap().final_path.clone();
        let ir_path = frame.archive_ir.as_ref().unwrap().final_path.clone();
        let meter_path = frame.archive_meter.as_ref().unwrap().final_path.clone();
        let mut injected = false;
        let error =
            publish_retained_archive_set_with_hook([&Some(rgb), &Some(ir), &Some(meter)], |step| {
                if step == RetainedArchiveCommitStep::RgbPublished && !injected {
                    std::fs::write(&ir_path, b"foreign sidecar").unwrap();
                    injected = true;
                }
                Ok(())
            })
            .expect_err("IR collision must fail the retained set");
        assert_eq!(error.code, protocol::ErrorCode::ArchiveCollision);
        assert!(
            !rgb_path.exists(),
            "the earlier RGB publication is rolled back"
        );
        assert_eq!(std::fs::read(&ir_path).unwrap(), b"foreign sidecar");
        assert!(!meter_path.exists());

        let _ = std::fs::remove_dir_all(&project);
    }

    #[test]
    fn windows_leaf_policy_rejects_ads_devices_and_win32_normalization() {
        for unsafe_name in [
            "image.tif:payload",
            "CON.tif",
            "prn",
            "COM1.jpg",
            "lpt9.tif",
            "trailing.",
            "trailing ",
            "question?.tif",
        ] {
            assert!(
                invalid_windows_output_leaf_reason(unsafe_name).is_some(),
                "{unsafe_name:?} must be refused"
            );
        }
        for safe_name in ["contact.tif", "company.jpg", "lpt10.tif", "ABé.tif"] {
            assert_eq!(invalid_windows_output_leaf_reason(safe_name), None);
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn held_preflight_uses_apfs_oracle_for_nfc_nfd_aliases() {
        let project = unique_test_dir();
        let destination = project.join("outputs");
        std::fs::create_dir_all(&destination).unwrap();
        let mut output = domain::OutputRecipe::default();
        output.archive.destination = destination.display().to_string();
        output.archive.filename_template = "caf\u{e9}_####".into();
        output.positive.destination = destination.display().to_string();
        output.positive.filename_template = "cafe\u{301}_####".into();
        output.preview.enabled = false;
        output.raw_export.enabled = false;

        let error = acquire_job_output_authorities(
            Some(&project),
            &[1],
            &domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .expect_err("APFS-equivalent Unicode spellings must collide before capture");

        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(error.message.contains("filename collation"), "{error}");
        assert!(std::fs::read_dir(&destination).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".scanstudio-output-alias-probe-")));
        let _ = std::fs::remove_dir_all(&project);
    }

    #[cfg(windows)]
    #[test]
    fn held_preflight_uses_ntfs_oracle_for_nontrivial_case_aliases() {
        let project = unique_test_dir();
        let destination = project.join("outputs");
        std::fs::create_dir_all(&destination).unwrap();
        let mut output = domain::OutputRecipe::default();
        output.archive.destination = destination.display().to_string();
        output.archive.filename_template = "\u{3a3}_####".into();
        output.positive.destination = destination.display().to_string();
        output.positive.filename_template = "\u{3c2}_####".into();
        output.preview.enabled = false;
        output.raw_export.enabled = false;

        let error = acquire_job_output_authorities(
            Some(&project),
            &[1],
            &domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .expect_err("NTFS-upcase aliases must collide before capture");

        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(error.message.contains("filename collation"), "{error}");
        let _ = std::fs::remove_dir_all(&project);
    }

    #[cfg(windows)]
    #[test]
    fn windows_held_destination_creates_and_publishes_without_reparse_fallback() {
        let project = unique_test_dir();
        std::fs::create_dir_all(&project).unwrap();
        let mut output = domain::OutputRecipe::default();
        output.archive.destination = project.join("archive/deep").display().to_string();
        output.archive.filename_template = "master.tif".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let recipe = domain::CaptureRecipe::default();
        let authorities = acquire_job_output_authorities(
            Some(&project),
            &[1],
            &recipe,
            &output,
            &std::collections::HashMap::new(),
        )
        .unwrap();
        let archive = authorities.frame(1).unwrap().archive.as_ref().unwrap();
        let proof =
            write_tiff_create_only_authorized(archive, &vec![[0.25, 0.5, 0.75]; 48], 8, 6, 16)
                .unwrap();
        destination_sys::verify_leaf_identity(
            &archive.destination.inner,
            &archive.final_name,
            &proof.file,
        )
        .unwrap();
        assert!(archive.final_path().is_file());
        let _ = std::fs::remove_dir_all(&project);
    }

    #[cfg(windows)]
    #[test]
    fn windows_project_root_write_handle_allows_compatible_anchored_reopens() {
        let project = unique_test_dir();
        std::fs::create_dir_all(&project).unwrap();
        let authority = acquire_project_output_root_authority(Some(&project))
            .unwrap()
            .unwrap();
        let manifest_reopen =
            crate::exiftool::metadata_publish_sys::open_directory(authority.canonical_path())
                .expect("held root sharing must allow the anchored manifest writer");
        manifest_reopen
            .sync_all()
            .expect("writable anchored directory handle must sync");
        authority
            .verify_namespace()
            .expect("read-only authority verifier must coexist with held write access");

        drop(manifest_reopen);
        drop(authority);
        let _ = std::fs::remove_dir_all(&project);
    }

    #[cfg(windows)]
    #[test]
    fn windows_archive_collision_retires_private_staged_file_by_handle() {
        let project = unique_test_dir();
        std::fs::create_dir_all(&project).unwrap();
        let mut output = domain::OutputRecipe::default();
        output.archive.destination = project.join("archive").display().to_string();
        output.archive.filename_template = "master.tif".into();
        output.positive.enabled = false;
        output.preview.enabled = false;
        output.raw_export.enabled = false;
        let authorities = acquire_job_output_authorities(
            Some(&project),
            &[1],
            &domain::CaptureRecipe::default(),
            &output,
            &std::collections::HashMap::new(),
        )
        .unwrap();
        let archive = authorities.frame(1).unwrap().archive.as_ref().unwrap();
        std::fs::write(archive.final_path(), b"foreign collision").unwrap();
        let error =
            write_tiff_create_only_authorized(archive, &vec![[0.25, 0.5, 0.75]; 48], 8, 6, 16)
                .expect_err("create-only collision must fail");
        assert_eq!(error.code, protocol::ErrorCode::ArchiveCollision);
        let leftovers: Vec<_> = std::fs::read_dir(project.join("archive"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .filter(|name| name.to_string_lossy().contains(".scanstudio-"))
            .collect();
        assert!(
            leftovers.is_empty(),
            "private staged bytes leaked: {leftovers:?}"
        );

        let _ = std::fs::remove_dir_all(&project);
    }

    fn write_small_rgb16_tiff(path: &std::path::Path, width: u32, height: u32) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("create fixture directory");
        }
        let pixels = (0..width * height)
            .map(|index| {
                [
                    ((index * 701) % 65536) as u16,
                    ((index * 1301) % 65536) as u16,
                    ((index * 2903) % 65536) as u16,
                ]
            })
            .collect();
        image_io::write_rgb16(
            path,
            &image_io::Rgb16Image {
                width,
                height,
                pixels,
            },
        )
        .expect("write RGB16 TIFF fixture");
    }

    fn classic_tiff_field_type(bytes: &[u8], wanted_tag: u16) -> Option<u16> {
        let little_endian = match bytes.get(0..2)? {
            b"II" => true,
            b"MM" => false,
            _ => return None,
        };
        let read_u16 = |slice: &[u8]| -> Option<u16> {
            let value: [u8; 2] = slice.try_into().ok()?;
            Some(if little_endian {
                u16::from_le_bytes(value)
            } else {
                u16::from_be_bytes(value)
            })
        };
        let read_u32 = |slice: &[u8]| -> Option<u32> {
            let value: [u8; 4] = slice.try_into().ok()?;
            Some(if little_endian {
                u32::from_le_bytes(value)
            } else {
                u32::from_be_bytes(value)
            })
        };
        if read_u16(bytes.get(2..4)?)? != 42 {
            return None;
        }
        let ifd_offset = read_u32(bytes.get(4..8)?)? as usize;
        let entry_count = read_u16(bytes.get(ifd_offset..ifd_offset.checked_add(2)?)?)? as usize;
        for index in 0..entry_count {
            let start = ifd_offset
                .checked_add(2)?
                .checked_add(index.checked_mul(12)?)?;
            let entry = bytes.get(start..start.checked_add(12)?)?;
            if read_u16(&entry[0..2])? == wanted_tag {
                return read_u16(&entry[2..4]);
            }
        }
        None
    }

    fn classic_tiff_entry(
        bytes: &[u8],
        ifd_offset: usize,
        wanted_tag: u16,
    ) -> Option<(u16, u32, [u8; 4])> {
        let entry_count =
            u16::from_le_bytes(bytes.get(ifd_offset..ifd_offset + 2)?.try_into().ok()?) as usize;
        for index in 0..entry_count {
            let start = ifd_offset + 2 + index * 12;
            if u16::from_le_bytes(bytes.get(start..start + 2)?.try_into().ok()?) == wanted_tag {
                return Some((
                    u16::from_le_bytes(bytes.get(start + 2..start + 4)?.try_into().ok()?),
                    u32::from_le_bytes(bytes.get(start + 4..start + 8)?.try_into().ok()?),
                    bytes.get(start + 8..start + 12)?.try_into().ok()?,
                ));
            }
        }
        None
    }

    fn classic_tiff_value(bytes: &[u8], ifd_offset: usize, tag: u16) -> Option<Vec<u8>> {
        let (field_type, count, inline) = classic_tiff_entry(bytes, ifd_offset, tag)?;
        let unit = match field_type {
            1 | 2 => 1,
            3 => 2,
            4 => 4,
            5 | 10 => 8,
            _ => return None,
        };
        let len = usize::try_from(count).ok()?.checked_mul(unit)?;
        if len <= 4 {
            Some(inline[..len].to_vec())
        } else {
            let offset = u32::from_le_bytes(inline) as usize;
            Some(bytes.get(offset..offset.checked_add(len)?)?.to_vec())
        }
    }

    fn classic_tiff_short(bytes: &[u8], ifd_offset: usize, tag: u16) -> Option<u16> {
        Some(u16::from_le_bytes(
            classic_tiff_value(bytes, ifd_offset, tag)?
                .get(0..2)?
                .try_into()
                .ok()?,
        ))
    }

    fn classic_tiff_long(bytes: &[u8], ifd_offset: usize, tag: u16) -> Option<u32> {
        Some(u32::from_le_bytes(
            classic_tiff_value(bytes, ifd_offset, tag)?
                .get(0..4)?
                .try_into()
                .ok()?,
        ))
    }

    fn u16_samples(bytes: &[u8]) -> Vec<u16> {
        bytes
            .chunks_exact(2)
            .map(|sample| u16::from_le_bytes(sample.try_into().unwrap()))
            .collect()
    }

    #[test]
    fn simulated_linear_dng_has_rgb_linear_raw_main_ifd_and_exact_ir_sub_ifd() {
        let raw = vec![[0.0, 0.5, 1.0], [0.25, 0.75, 0.125]];
        let recipe = domain::RawExportRecipe::default();
        let bytes = encoded_simulated_raw(&raw, 2, 1, 4_000, &recipe, true).unwrap();
        let main_ifd = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;

        assert_eq!(classic_tiff_short(&bytes, main_ifd, 262), Some(34_892));
        assert_eq!(classic_tiff_short(&bytes, main_ifd, 277), Some(3));
        assert!(classic_tiff_entry(&bytes, main_ifd, 338).is_none());
        assert_eq!(
            classic_tiff_value(&bytes, main_ifd, 50_706).unwrap(),
            [1, 4, 0, 0]
        );
        assert_eq!(
            classic_tiff_value(&bytes, main_ifd, 282).unwrap(),
            4_000_u32
                .to_le_bytes()
                .into_iter()
                .chain(1_u32.to_le_bytes())
                .collect::<Vec<_>>()
        );
        assert_eq!(classic_tiff_short(&bytes, main_ifd, 296), Some(2));
        let infrared_ifd = classic_tiff_long(&bytes, main_ifd, 330).unwrap() as usize;
        assert_eq!(classic_tiff_short(&bytes, infrared_ifd, 262), Some(1));
        assert_eq!(classic_tiff_short(&bytes, infrared_ifd, 277), Some(1));
        assert_eq!(
            classic_tiff_value(&bytes, infrared_ifd, RAW_IR_TAG).unwrap(),
            RAW_IR_MARKER
        );

        let rgb_offset = classic_tiff_long(&bytes, main_ifd, 273).unwrap() as usize;
        let rgb_len = classic_tiff_long(&bytes, main_ifd, 279).unwrap() as usize;
        assert_eq!(
            u16_samples(&bytes[rgb_offset..rgb_offset + rgb_len]),
            [0, 32_768, 65_535, 16_384, 49_151, 8_192]
        );
        let ir_offset = classic_tiff_long(&bytes, infrared_ifd, 273).unwrap() as usize;
        let ir_len = classic_tiff_long(&bytes, infrared_ifd, 279).unwrap() as usize;
        assert_eq!(
            u16_samples(&bytes[ir_offset..ir_offset + ir_len]),
            [32_768, 24_576]
        );
    }

    #[test]
    fn simulated_linear_tiff_fourth_channel_and_omitted_modes_are_unambiguous() {
        let raw = vec![[0.0, 0.5, 1.0], [0.25, 0.75, 0.125]];
        for (infrared, expected_spp, expected_samples) in [
            (
                domain::RawTiffInfrared::FourthChannel,
                4,
                vec![0, 32_768, 65_535, 32_768, 16_384, 49_151, 8_192, 24_576],
            ),
            (
                domain::RawTiffInfrared::Omitted,
                3,
                vec![0, 32_768, 65_535, 16_384, 49_151, 8_192],
            ),
        ] {
            let recipe = domain::RawExportRecipe {
                enabled: true,
                file_format: domain::RawExportFormat::LinearTiff,
                tiff_infrared: infrared,
                ..domain::RawExportRecipe::default()
            };
            let bytes = encoded_simulated_raw(&raw, 2, 1, 4_000, &recipe, true).unwrap();
            let ifd = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
            assert_eq!(classic_tiff_short(&bytes, ifd, 262), Some(2));
            assert_eq!(classic_tiff_short(&bytes, ifd, 277), Some(expected_spp));
            assert_eq!(
                classic_tiff_entry(&bytes, ifd, 338).is_some(),
                expected_spp == 4
            );
            assert_eq!(
                classic_tiff_entry(&bytes, ifd, RAW_IR_TAG).is_some(),
                expected_spp == 4
            );
            let offset = classic_tiff_long(&bytes, ifd, 273).unwrap() as usize;
            let len = classic_tiff_long(&bytes, ifd, 279).unwrap() as usize;
            assert_eq!(u16_samples(&bytes[offset..offset + len]), expected_samples);
        }
    }

    #[test]
    fn simulated_sidecar_modes_keep_rgb_main_and_round_trip_grayscale_ir_tags() {
        let raw = vec![[0.0, 0.5, 1.0], [0.25, 0.75, 0.125]];
        for format in [
            domain::RawExportFormat::LinearDng,
            domain::RawExportFormat::LinearTiff,
        ] {
            let recipe = domain::RawExportRecipe {
                enabled: true,
                file_format: format,
                tiff_infrared: domain::RawTiffInfrared::Sidecar,
                ..domain::RawExportRecipe::default()
            };
            let main = encoded_simulated_raw(&raw, 2, 1, 4_000, &recipe, true).unwrap();
            let main_ifd = u32::from_le_bytes(main[4..8].try_into().unwrap()) as usize;
            assert_eq!(classic_tiff_short(&main, main_ifd, 277), Some(3));
            assert!(classic_tiff_entry(&main, main_ifd, 330).is_none());
            assert!(classic_tiff_entry(&main, main_ifd, RAW_IR_TAG).is_none());
            let main_offset = classic_tiff_long(&main, main_ifd, 273).unwrap() as usize;
            let main_len = classic_tiff_long(&main, main_ifd, 279).unwrap() as usize;
            assert_eq!(
                u16_samples(&main[main_offset..main_offset + main_len]),
                [0, 32_768, 65_535, 16_384, 49_151, 8_192]
            );

            let sidecar = encoded_simulated_raw_ir(&raw, 2, 1, 4_000).unwrap();
            let sidecar_ifd = u32::from_le_bytes(sidecar[4..8].try_into().unwrap()) as usize;
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 258), Some(16));
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 262), Some(1));
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 277), Some(1));
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 274), Some(1));
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 296), Some(2));
            assert_eq!(
                classic_tiff_value(&sidecar, sidecar_ifd, 282).unwrap(),
                4_000_u32
                    .to_le_bytes()
                    .into_iter()
                    .chain(1_u32.to_le_bytes())
                    .collect::<Vec<_>>()
            );
            assert_eq!(
                classic_tiff_value(&sidecar, sidecar_ifd, RAW_IR_TAG).unwrap(),
                RAW_IR_MARKER
            );
            let ir_offset = classic_tiff_long(&sidecar, sidecar_ifd, 273).unwrap() as usize;
            let ir_len = classic_tiff_long(&sidecar, sidecar_ifd, 279).unwrap() as usize;
            assert_eq!(
                u16_samples(&sidecar[ir_offset..ir_offset + ir_len]),
                [32_768, 24_576]
            );
        }
    }

    #[test]
    fn simulated_sidecar_without_ir_matches_single_rgb_sibling() {
        let raw = vec![[0.0, 0.5, 1.0], [0.25, 0.75, 0.125]];
        for format in [
            domain::RawExportFormat::LinearDng,
            domain::RawExportFormat::LinearTiff,
        ] {
            let recipe = domain::RawExportRecipe {
                file_format: format,
                tiff_infrared: domain::RawTiffInfrared::Sidecar,
                ..domain::RawExportRecipe::default()
            };
            let main = encoded_simulated_raw(&raw, 2, 1, 4_000, &recipe, false).unwrap();
            let ifd = u32::from_le_bytes(main[4..8].try_into().unwrap()) as usize;
            assert_eq!(classic_tiff_short(&main, ifd, 277), Some(3));
            assert!(classic_tiff_entry(&main, ifd, 330).is_none());
            assert!(classic_tiff_entry(&main, ifd, RAW_IR_TAG).is_none());
        }
    }

    #[test]
    fn raw_pair_crash_steps_have_no_trusted_commit_until_marker_publication() {
        let interruption_steps = [
            RawPairCommitStep::MainSynced,
            RawPairCommitStep::InfraredSynced,
            RawPairCommitStep::AttemptDirectorySynced,
            RawPairCommitStep::MainPublished,
            RawPairCommitStep::InfraredPublished,
            RawPairCommitStep::FinalFilesDirectorySynced,
            RawPairCommitStep::MarkerPublished,
        ];

        for interruption_step in interruption_steps {
            let dir = unique_test_dir();
            std::fs::create_dir_all(&dir).unwrap();
            let main = dir.join("negative.dng");
            let sidecar = dir.join("negative-ir.tif");
            let marker = raw_export_pair_commit_marker_path(&main).unwrap();
            let (attempt, transaction_id) =
                create_private_directory(&dir, "raw-pair-test").unwrap();
            let mut state = RawPairPublicationState::default();
            let error = execute_raw_pair_transaction(
                &attempt,
                &transaction_id,
                &main,
                b"complete main",
                &sidecar,
                b"complete sidecar",
                &marker,
                &mut state,
                |step| {
                    if step == interruption_step {
                        let committed = validate_raw_export_pair_commit(&main, &sidecar).is_ok();
                        assert_eq!(
                            committed,
                            step == RawPairCommitStep::MarkerPublished,
                            "{step:?} must expose a trusted pair iff the atomic marker has published"
                        );
                        return Err(domain::EngineError::new(
                            protocol::ErrorCode::Internal,
                            format!("simulated crash after {step:?}"),
                        ));
                    }
                    Ok(())
                },
            )
            .unwrap_err();

            assert!(error.message.contains("simulated crash"));
            let committed = validate_raw_export_pair_commit(&main, &sidecar).is_ok();
            assert_eq!(
                committed,
                interruption_step == RawPairCommitStep::MarkerPublished
            );
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    #[test]
    fn raw_pair_reader_rejects_orphans_and_bytes_changed_after_commit() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let main = dir.join("negative.dng");
        let sidecar = dir.join("negative-ir.tif");
        std::fs::write(&main, b"orphan main").unwrap();
        std::fs::write(&sidecar, b"orphan sidecar").unwrap();
        assert!(validate_raw_export_pair_commit(&main, &sidecar).is_err());
        std::fs::remove_file(&main).unwrap();
        std::fs::remove_file(&sidecar).unwrap();

        let marker = raw_export_pair_commit_marker_path(&main).unwrap();
        let (attempt, transaction_id) = create_private_directory(&dir, "raw-pair-test").unwrap();
        let mut state = RawPairPublicationState::default();
        execute_raw_pair_transaction(
            &attempt,
            &transaction_id,
            &main,
            b"complete main",
            &sidecar,
            b"complete sidecar",
            &marker,
            &mut state,
            |_| Ok(()),
        )
        .unwrap();
        validate_raw_export_pair_commit(&main, &sidecar).unwrap();

        std::fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(&sidecar)
            .unwrap()
            .write_all(b"changed")
            .unwrap();
        assert!(validate_raw_export_pair_commit(&main, &sidecar).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn ordinary_raw_pair_error_rolls_back_own_uncommitted_final() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let main = dir.join("negative.dng");
        let sidecar = dir.join("negative-ir.tif");
        let marker = raw_export_pair_commit_marker_path(&main).unwrap();
        let (attempt, transaction_id) = create_private_directory(&dir, "raw-pair-test").unwrap();
        let mut state = RawPairPublicationState::default();
        let error = execute_raw_pair_transaction(
            &attempt,
            &transaction_id,
            &main,
            b"complete main",
            &sidecar,
            b"complete sidecar",
            &marker,
            &mut state,
            |step| {
                if step == RawPairCommitStep::MainPublished {
                    return Err(domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        "simulated ordinary publication failure",
                    ));
                }
                Ok(())
            },
        )
        .unwrap_err();
        rollback_raw_pair_publication(&dir, &main, &sidecar, &marker, &state);

        assert!(error
            .message
            .contains("simulated ordinary publication failure"));
        assert!(!main.exists());
        assert!(!sidecar.exists());
        assert!(!marker.exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn raw_pair_writer_returns_only_a_validated_create_only_commit() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let main = dir.join("negative.dng");
        let sidecar = raw_export_ir_sidecar_path(&main);
        let marker = raw_export_pair_commit_marker_path(&main).unwrap();
        let raw = vec![[0.0, 0.5, 1.0], [0.25, 0.75, 0.125]];
        let recipe = domain::RawExportRecipe {
            enabled: true,
            file_format: domain::RawExportFormat::LinearDng,
            tiff_infrared: domain::RawTiffInfrared::Sidecar,
            ..domain::RawExportRecipe::default()
        };

        assert_eq!(
            write_raw_export_create_only(&main, &raw, 2, 1, 4_000, &recipe, true).unwrap(),
            Some(sidecar.clone())
        );
        validate_raw_export_pair_commit(&main, &sidecar).unwrap();
        assert!(marker.is_file());
        let main_before = std::fs::read(&main).unwrap();
        let sidecar_before = std::fs::read(&sidecar).unwrap();

        let error =
            write_raw_export_create_only(&main, &raw, 2, 1, 4_000, &recipe, true).unwrap_err();
        assert_eq!(error.code, protocol::ErrorCode::ArchiveCollision);
        assert_eq!(std::fs::read(&main).unwrap(), main_before);
        assert_eq!(std::fs::read(&sidecar).unwrap(), sidecar_before);
        validate_raw_export_pair_commit(&main, &sidecar).unwrap();
        assert!(
            std::fs::read_dir(&dir).unwrap().all(|entry| !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".attempt")),
            "successful publication must clean its private attempt directory"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn frame_dimensions_matches_scan_size_estimator_constants() {
        assert_eq!(
            frame_dimensions(domain::MediaCarrier::Roll36, 4000),
            (3946, 5959)
        );
        assert_eq!(
            frame_dimensions(domain::MediaCarrier::Mounted, 4000),
            (3946, 5782)
        );
        assert_eq!(
            frame_dimensions(domain::MediaCarrier::Roll36, 2000),
            (1973, 2980)
        );
    }

    #[test]
    fn generate_sim_frame_is_deterministic_and_bounded() {
        let a = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        let b = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        assert_eq!(a, b, "same arguments must reproduce byte-identical pixels");
        assert_eq!(a.len(), 8 * 6, "one triple per pixel, row-major");
        for px in &a {
            for &v in px {
                assert!((0.0..=1.0).contains(&v), "channel value {v} out of bounds");
            }
        }
    }

    #[test]
    fn resolve_filename_zero_pads_to_the_hash_run_length() {
        assert_eq!(resolve_filename("Roll_001_####", 5), "Roll_001_0005");
    }

    #[test]
    fn resolve_filename_uses_a_four_digit_suffix_when_no_hash_present() {
        assert_eq!(resolve_filename("Roll_001", 5), "Roll_001_0005");
        assert_eq!(resolve_filename("Roll.v1.tif", 5), "Roll.v1_0005.tif");
        assert_eq!(resolve_filename("Roll.v1.TiFf", 5), "Roll.v1_0005.TiFf");
    }

    #[test]
    fn single_hash_reserves_the_next_available_number_across_enabled_outputs() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("ScanStudio1.jpg"), b"existing").unwrap();
        std::fs::write(dir.join("ScanStudio2.tif"), b"existing").unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "ScanStudio#".into();
        recipes.raw_export.enabled = true;
        recipes.raw_export.destination = dir.display().to_string();
        recipes.raw_export.filename_template = "ScanStudio#".into();
        recipes.positive.destination = dir.display().to_string();
        recipes.positive.filename_template = "ScanStudio#".into();
        recipes.preview.destination = dir.display().to_string();
        recipes.preview.filename_template = "ScanStudio#".into();
        let mut overrides = std::collections::HashMap::new();

        reserve_auto_sequence_filenames(
            None,
            &[1],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &recipes,
            &mut overrides,
        )
        .expect("the next unused sequence number should be reserved");

        let output = &overrides.get(&1).unwrap().output.as_ref().unwrap();
        assert_eq!(
            resolve_archive_output_path(output, 1),
            dir.join("ScanStudio3.tif")
        );
        assert_eq!(
            resolve_output_path(
                &output.positive.destination,
                &output.positive.filename_template,
                1,
                output.positive.file_format,
            ),
            dir.join("ScanStudio3.tif")
        );
        assert_eq!(
            resolve_output_path(
                &output.preview.destination,
                &output.preview.filename_template,
                1,
                output.preview.file_format,
            ),
            dir.join("ScanStudio3.jpg")
        );
        assert_eq!(
            resolve_raw_export_output_path(output, 1),
            dir.join("ScanStudio3.dng")
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn receipt_recipe_restores_job_local_sequence_markers_to_the_user_template() {
        let mut output = domain::OutputRecipe::default();
        output.archive.filename_template = "Master$ScanStudioSequence(12)".into();
        output.raw_export.filename_template = "Raw$ScanStudioSequence(12).dng".into();
        output.positive.filename_template = "Positive$ScanStudioSequence(12).tif".into();
        output.preview.filename_template = "Preview$ScanStudioSequence(12).jpg".into();

        let receipt_output = receipt_output_recipe(&output);

        assert_eq!(receipt_output.archive.filename_template, "Master#");
        assert_eq!(receipt_output.raw_export.filename_template, "Raw#.dng");
        assert_eq!(receipt_output.positive.filename_template, "Positive#.tif");
        assert_eq!(receipt_output.preview.filename_template, "Preview#.jpg");
        assert!(
            !serde_json::to_string(&receipt_output)
                .expect("output recipe must serialize")
                .contains("ScanStudioSequence"),
            "receipt recipes must never persist the private sequence marker"
        );
    }

    #[test]
    fn user_output_recipes_reject_the_engine_reserved_sequence_marker() {
        let mut output = domain::OutputRecipe::default();
        output.archive.filename_template = "ScanStudio$ScanStudioSequence(7)".into();

        let error = validate_user_output_recipe_paths(&output).unwrap_err();

        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(error.message.contains("reserved"));

        let mut metadata_injected = domain::OutputRecipe::default();
        metadata_injected.archive.filename_template = "$FilmStock-#".into();
        materialize_output_filename_tokens(
            &mut metadata_injected,
            &domain::MetadataSet {
                film_stock: Some("$ScanStudioSequence(88)".into()),
                ..Default::default()
            },
        );
        assert_eq!(
            validate_user_output_recipe_paths(&metadata_injected)
                .unwrap_err()
                .code,
            protocol::ErrorCode::InvalidParams,
            "metadata expansion cannot smuggle an engine-only marker"
        );
    }

    #[test]
    fn single_hash_allocates_consecutive_numbers_for_arbitrary_frame_slots_and_sidecars() {
        let dir = unique_test_dir();
        let archive_dir = dir.join("archive");
        let positive_dir = dir.join("positive");
        let preview_dir = dir.join("preview");
        for directory in [&archive_dir, &positive_dir, &preview_dir] {
            std::fs::create_dir_all(directory).unwrap();
        }
        std::fs::write(positive_dir.join("ScanStudio1.jpeg"), b"existing").unwrap();
        std::fs::write(archive_dir.join("ScanStudio2.tiff"), b"existing").unwrap();
        std::fs::write(archive_dir.join("ScanStudio3_IR.tif"), b"existing").unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = archive_dir.display().to_string();
        recipes.archive.filename_template = "ScanStudio#".into();
        recipes.positive.destination = positive_dir.display().to_string();
        recipes.positive.filename_template = "ScanStudio#".into();
        recipes.preview.destination = preview_dir.display().to_string();
        recipes.preview.filename_template = "ScanStudio#".into();
        let mut overrides = std::collections::HashMap::new();
        let mut capture = domain::CaptureRecipe::default();
        capture.channels = domain::Channels::Rgbi;

        reserve_auto_sequence_filenames(
            None,
            &[7, 39],
            &capture,
            &domain::ProcessingRecipe::default(),
            &recipes,
            &mut overrides,
        )
        .expect("sidecar and all output folders must participate in allocation");

        for (frame, expected) in [(7, "ScanStudio4.tif"), (39, "ScanStudio5.tif")] {
            let output = &overrides.get(&frame).unwrap().output.as_ref().unwrap();
            assert_eq!(
                resolve_archive_output_path(output, frame),
                archive_dir.join(expected)
            );
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn sequence_discovery_is_case_insensitive_and_starts_after_the_highest_matching_stem() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("roll-2-final.tiff"), b"gap below maximum").unwrap();
        std::fs::write(dir.join("rOlL-42-fInAl.TIF"), b"highest mixed-case match").unwrap();
        std::fs::write(dir.join("roll-99-other.tif"), b"wrong suffix").unwrap();
        std::fs::write(dir.join("other-100-final.tif"), b"wrong prefix").unwrap();

        assert_eq!(
            highest_existing_sequence_number(
                &dir.display().to_string(),
                "Roll-#-Final.TIFF",
                domain::OutputFileFormat::Tiff,
            )
            .unwrap(),
            42,
            "case-only prefix/suffix/extension differences count and gaps are never filled"
        );

        let default_dir = dir.join("default");
        std::fs::create_dir_all(&default_dir).unwrap();
        std::fs::write(default_dir.join("scanstudio42.TIF"), b"existing").unwrap();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = default_dir.display().to_string();
        recipes.positive.enabled = false;
        recipes.preview.enabled = false;
        let mut overrides = std::collections::HashMap::new();
        reserve_auto_sequence_filenames(
            None,
            &[39],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &recipes,
            &mut overrides,
        )
        .unwrap();
        let reserved = &overrides.get(&39).unwrap().output.as_ref().unwrap().archive;
        assert_eq!(
            resolve_output_path(
                &reserved.destination,
                &reserved.filename_template,
                39,
                domain::OutputFileFormat::Tiff,
            ),
            default_dir.join("ScanStudio43.tif")
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn archive_off_sequence_uses_only_retained_output_destinations_and_starts_after_highest() {
        let dir = unique_test_dir();
        let archive_dir = dir.join("disabled-archive");
        let positive_dir = dir.join("positive");
        let preview_dir = dir.join("preview");
        for directory in [&archive_dir, &positive_dir, &preview_dir] {
            std::fs::create_dir_all(directory).unwrap();
        }
        std::fs::write(archive_dir.join("ScanStudio99.tif"), b"must be ignored").unwrap();
        std::fs::write(positive_dir.join("ScanStudio1.tif"), b"existing").unwrap();
        std::fs::write(positive_dir.join("ScanStudio3.jpg"), b"existing").unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.enabled = false;
        recipes.archive.destination = archive_dir.display().to_string();
        recipes.archive.filename_template = "ScanStudio#".into();
        recipes.positive.destination = positive_dir.display().to_string();
        recipes.positive.filename_template = "ScanStudio#".into();
        recipes.preview.destination = preview_dir.display().to_string();
        recipes.preview.filename_template = "ScanStudio#".into();
        let mut overrides = std::collections::HashMap::new();

        reserve_auto_sequence_filenames(
            None,
            &[17, 18],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &recipes,
            &mut overrides,
        )
        .expect("retained outputs reserve sequence names");

        for (slot, expected) in [(17, "ScanStudio4.tif"), (18, "ScanStudio5.tif")] {
            let output = overrides[&slot].output.as_ref().unwrap();
            assert_eq!(
                resolve_output_path(
                    &output.positive.destination,
                    &output.positive.filename_template,
                    slot,
                    output.positive.file_format,
                ),
                positive_dir.join(expected),
            );
            assert!(
                is_auto_sequence_template(&output.archive.filename_template),
                "disabled archive must remain out of the job-local reservation plan"
            );
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn materialize_filename_tokens_sanitizes_metadata_and_keeps_legacy_hash_runs() {
        let metadata = domain::MetadataSet {
            camera: Some("Canon 7E".into()),
            lens: Some("EF 50mm f/1.8".into()),
            film_stock: Some("Kodak Gold 200".into()),
            date: Some(domain::PartialDate::Exact {
                date: "2026-07-27".into(),
            }),
            ..Default::default()
        };
        assert_eq!(
            materialize_filename_tokens(
                "$FilmStock-$Camera-$Lens-$Month-$Day-$Year-$Frame",
                &metadata
            ),
            "KodakGold200-Canon7E-EF50mmF1.8-07-27-2026-####"
        );
        assert_eq!(
            materialize_filename_tokens("Archive_####", &metadata),
            "Archive_####"
        );
    }

    #[test]
    fn output_templates_reject_absolute_and_traversal_paths_before_any_write() {
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.filename_template = "../../outside".into();
        assert!(validate_output_recipe_paths(&recipes).is_err());
        recipes.archive.filename_template = "/tmp/outside".into();
        assert!(validate_output_recipe_paths(&recipes).is_err());
        recipes.archive.filename_template = "safe-name".into();
        assert!(validate_output_recipe_paths(&recipes).is_ok());
    }

    #[test]
    fn pairwise_alias_preflight_leaves_no_archive_on_repeat_attempts() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.positive.destination = dir.display().to_string();
        recipes.archive.filename_template = "same_####".into();
        recipes.positive.filename_template = "same_####".into();
        recipes.positive.enabled = true;
        recipes.preview.enabled = false;
        for _ in 0..2 {
            let error = render_and_write_frame(
                "sim",
                1,
                domain::FilmProcess::C41ColorNegative,
                2,
                2,
                16,
                &recipes,
                None,
                None,
            )
            .unwrap_err();
            assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
            assert!(!dir.join("same_0001.tif").exists());
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn no_hash_batch_preflight_and_simulator_write_distinct_four_digit_archives() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "Roll.v1.tiff".into();
        recipes.positive.enabled = false;
        recipes.preview.enabled = false;

        validate_batch_output_paths(
            &[1, 2],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &recipes,
            &std::collections::HashMap::new(),
        )
        .expect("no-marker frames must preflight as distinct physical targets");

        let first = render_and_write_frame(
            "sim",
            1,
            domain::FilmProcess::C41ColorNegative,
            2,
            2,
            16,
            &recipes,
            None,
            None,
        )
        .expect("write first simulator archive");
        let second = render_and_write_frame(
            "sim",
            2,
            domain::FilmProcess::C41ColorNegative,
            2,
            2,
            16,
            &recipes,
            None,
            None,
        )
        .expect("write second simulator archive");
        let canonical_dir = std::fs::canonicalize(&dir).unwrap();
        assert_eq!(
            first.archive_path,
            Some(canonical_dir.join("Roll.v1_0001.tiff"))
        );
        assert_eq!(
            second.archive_path,
            Some(canonical_dir.join("Roll.v1_0002.tiff"))
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn final_name_resolver_preserves_only_extensions_owned_by_the_format() {
        for (template, expected) in [
            ("Archive_####", "Archive_####.tif"),
            ("Archive_####.tif", "Archive_####.tif"),
            ("Archive_####.tiff", "Archive_####.tiff"),
            ("Archive_####.TiF", "Archive_####.TiF"),
            (
                "KodakGold200-EF50mmF1.8STM-####",
                "KodakGold200-EF50mmF1.8STM-####.tif",
            ),
            ("wrong.jpg", "wrong.jpg.tif"),
        ] {
            assert_eq!(
                normalize_output_filename_template(template, domain::OutputFileFormat::Tiff),
                expected
            );
        }
        for (template, expected) in [
            ("Preview_####", "Preview_####.jpg"),
            ("Preview_####.jpg", "Preview_####.jpg"),
            ("Preview_####.jpeg", "Preview_####.jpeg"),
            ("Preview_####.JpEg", "Preview_####.JpEg"),
            ("wrong.tif", "wrong.tif.jpg"),
        ] {
            assert_eq!(
                normalize_output_filename_template(template, domain::OutputFileFormat::Jpeg),
                expected
            );
        }
    }

    #[test]
    fn batch_preflight_rejects_cross_frame_template_collisions() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let mut output = domain::OutputRecipe::default();
        output.archive.destination = dir.display().to_string();
        output.positive.enabled = false;
        output.preview.enabled = false;
        let mut first = output.clone();
        first.archive.filename_template = "x_#_2".into();
        let mut second = output.clone();
        second.archive.filename_template = "x_1_#".into();
        let overrides = std::collections::HashMap::from([
            (
                1,
                domain::FrameOverrides {
                    output: Some(first),
                    ..Default::default()
                },
            ),
            (
                2,
                domain::FrameOverrides {
                    output: Some(second),
                    ..Default::default()
                },
            ),
        ]);
        let error = validate_batch_output_paths(
            &[1, 2],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &output,
            &overrides,
        )
        .unwrap_err();
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(!dir.join("x_1_2.tif").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn physical_preflight_rejects_lexical_case_and_sidecar_aliases() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(dir.join("a")).unwrap();
        let mut lexical = domain::OutputRecipe::default();
        lexical.archive.destination = dir.join("a/..").display().to_string();
        lexical.archive.filename_template = "same_####".into();
        lexical.positive.destination = dir.display().to_string();
        lexical.positive.filename_template = "same_####".into();
        lexical.preview.enabled = false;
        assert_eq!(
            validate_frame_output_paths(&lexical, 1).unwrap_err().code,
            protocol::ErrorCode::InvalidParams
        );

        let mut case_only = lexical.clone();
        case_only.archive.destination = dir.display().to_string();
        case_only.archive.filename_template = "Output_####".into();
        case_only.positive.filename_template = "output_####".into();
        assert_eq!(
            validate_frame_output_paths(&case_only, 1).unwrap_err().code,
            protocol::ErrorCode::InvalidParams
        );

        let mut sidecar = domain::OutputRecipe::default();
        sidecar.archive.destination = dir.display().to_string();
        sidecar.archive.filename_template = "Frame_####".into();
        sidecar.positive.destination = dir.display().to_string();
        sidecar.positive.filename_template = "Frame_####_IR".into();
        sidecar.positive.file_format = domain::OutputFileFormat::Tiff;
        sidecar.preview.enabled = false;
        assert_eq!(
            validate_batch_output_paths(
                &[1],
                &domain::CaptureRecipe::default(),
                &domain::ProcessingRecipe::default(),
                &sidecar,
                &std::collections::HashMap::new(),
            )
            .unwrap_err()
            .code,
            protocol::ErrorCode::InvalidParams
        );

        let mut raw_alias = domain::OutputRecipe::default();
        raw_alias.archive.destination = dir.display().to_string();
        raw_alias.archive.filename_template = "Raw_####.tif".into();
        raw_alias.raw_export.enabled = true;
        raw_alias.raw_export.file_format = domain::RawExportFormat::LinearTiff;
        raw_alias.raw_export.destination = dir.display().to_string();
        raw_alias.raw_export.filename_template = "Raw_####.tif".into();
        raw_alias.positive.enabled = false;
        raw_alias.preview.enabled = false;
        assert_eq!(
            validate_frame_output_paths(&raw_alias, 1).unwrap_err().code,
            protocol::ErrorCode::InvalidParams
        );

        let mut raw_sidecar_alias = domain::OutputRecipe::default();
        raw_sidecar_alias.archive.enabled = false;
        raw_sidecar_alias.raw_export.enabled = true;
        raw_sidecar_alias.raw_export.file_format = domain::RawExportFormat::LinearDng;
        raw_sidecar_alias.raw_export.tiff_infrared = domain::RawTiffInfrared::Sidecar;
        raw_sidecar_alias.raw_export.destination = dir.display().to_string();
        raw_sidecar_alias.raw_export.filename_template = "Negative_####.dng".into();
        raw_sidecar_alias.positive.destination = dir.display().to_string();
        raw_sidecar_alias.positive.filename_template = "Negative_####-ir.tif".into();
        raw_sidecar_alias.preview.enabled = false;
        assert_eq!(
            validate_frame_output_paths(&raw_sidecar_alias, 1)
                .unwrap_err()
                .code,
            protocol::ErrorCode::InvalidParams
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn physical_identity_oracle_rejects_hard_link_aliases_before_motion() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let primary = dir.join("primary.tif");
        let alias = dir.join("alias.tif");
        std::fs::write(&primary, b"shared artifact").unwrap();
        std::fs::hard_link(&primary, &alias).unwrap();

        assert!(
            targets_match(&primary, &alias).unwrap(),
            "receipt matching must recognize a hard-linked alias on every supported host"
        );
        let error = validate_target_candidates(&[
            TargetCandidate {
                slot: 1,
                role: "archive",
                path: primary.clone(),
                create_only: false,
            },
            TargetCandidate {
                slot: 1,
                role: "positive",
                path: alias.clone(),
                create_only: false,
            },
        ])
        .expect_err("physical aliases must be rejected before output motion");
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(error.message.contains("aliases"));
        assert_eq!(std::fs::read(&primary).unwrap(), b"shared artifact");
        assert_eq!(std::fs::read(&alias).unwrap(), b"shared artifact");

        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn physical_preflight_resolves_parent_symlinks_and_rejects_leaf_symlinks() {
        use std::os::unix::fs::symlink;
        let dir = unique_test_dir();
        let real = dir.join("real");
        let alias = dir.join("alias");
        std::fs::create_dir_all(&real).unwrap();
        symlink(&real, &alias).unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = real.display().to_string();
        recipes.archive.filename_template = "same_####".into();
        recipes.positive.destination = alias.display().to_string();
        recipes.positive.filename_template = "same_####".into();
        recipes.preview.enabled = false;
        assert_eq!(
            validate_frame_output_paths(&recipes, 1).unwrap_err().code,
            protocol::ErrorCode::InvalidParams
        );

        recipes.positive.enabled = false;
        let victim = dir.join("victim.tif");
        std::fs::write(&victim, b"victim").unwrap();
        let archive_leaf = real.join("same_0001.tif");
        symlink(&victim, &archive_leaf).unwrap();
        assert_eq!(
            validate_frame_output_paths(&recipes, 1).unwrap_err().code,
            protocol::ErrorCode::InvalidParams
        );
        assert_eq!(std::fs::read(&victim).unwrap(), b"victim");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn bridge_receipt_paths_must_match_the_reserved_archive_and_sidecars() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "frame-####".into();
        let rgb = dir.join("frame-0001.tif");
        let ir = dir.join("frame-0001_IR.tif");
        let meter = dir.join("frame-0001_METER.tif");
        for path in [&rgb, &ir, &meter] {
            std::fs::write(path, b"fixture").unwrap();
        }
        validate_bridge_capture_receipt_paths(
            &recipes,
            1,
            domain::Channels::Rgbi,
            &rgb,
            Some(&ir),
            Some(&meter),
        )
        .unwrap();
        let wrong = dir.join("wrong.tif");
        std::fs::write(&wrong, b"fixture").unwrap();
        assert_eq!(
            validate_bridge_capture_receipt_paths(
                &recipes,
                1,
                domain::Channels::Rgbi,
                &wrong,
                Some(&ir),
                Some(&meter),
            )
            .unwrap_err()
            .code,
            protocol::ErrorCode::InvalidParams
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn bridge_raw_receipt_path_must_match_the_reserved_output() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let expected = dir.join("frame-0001.dng");
        let wrong = dir.join("other.dng");
        std::fs::write(&expected, b"fixture").unwrap();
        std::fs::write(&wrong, b"fixture").unwrap();
        validate_bridge_raw_export_receipt_path(Some(&expected), Some(&expected), 1).unwrap();
        assert_eq!(
            validate_bridge_raw_export_receipt_path(Some(&expected), Some(&wrong), 1)
                .unwrap_err()
                .code,
            protocol::ErrorCode::InvalidParams
        );
        assert!(validate_bridge_raw_export_receipt_path(Some(&expected), None, 1).is_err());
        assert!(validate_bridge_raw_export_receipt_path(None, Some(&wrong), 1).is_err());
        validate_bridge_raw_export_receipt_path(None, None, 1).unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn atomic_derivative_write_replaces_a_raced_symlink_without_touching_target() {
        use std::os::unix::fs::symlink;
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let protected = dir.join("protected.bin");
        let derivative = dir.join("positive.tif");
        std::fs::write(&protected, b"do-not-touch").unwrap();
        symlink(&protected, &derivative).unwrap();
        let raw = generate_sim_frame("sim", 1, 4, 3);
        write_derivative(
            &derivative,
            &raw,
            4,
            3,
            domain::OutputFileFormat::Tiff,
            false,
            &DerivativeMetadata::positive(domain::FilmProcess::C41ColorNegative, 4000),
        )
        .unwrap();
        assert_eq!(std::fs::read(&protected).unwrap(), b"do-not-touch");
        assert!(!std::fs::symlink_metadata(&derivative)
            .unwrap()
            .file_type()
            .is_symlink());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn auto_sequence_tiff_derivative_is_create_only_if_final_appears_after_preflight() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let derivative = dir.join("ScanStudio9.tif");
        std::fs::write(&derivative, b"raced-final").unwrap();
        let raw = generate_sim_frame("sim", 1, 4, 3);

        let error = write_derivative(
            &derivative,
            &raw,
            4,
            3,
            domain::OutputFileFormat::Tiff,
            true,
            &DerivativeMetadata::positive(domain::FilmProcess::C41ColorNegative, 4000),
        )
        .unwrap_err();

        assert_eq!(error.code, protocol::ErrorCode::ArchiveCollision);
        assert_eq!(std::fs::read(&derivative).unwrap(), b"raced-final");
        assert_eq!(
            std::fs::read_dir(&dir).unwrap().count(),
            1,
            "temporary sibling must be cleaned"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn auto_sequence_jpeg_derivative_is_create_only_if_final_appears_after_preflight() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let derivative = dir.join("ScanStudio10.jpg");
        std::fs::write(&derivative, b"raced-jpeg-final").unwrap();
        let raw = generate_sim_frame("sim", 1, 4, 3);

        let error = write_derivative(
            &derivative,
            &raw,
            4,
            3,
            domain::OutputFileFormat::Jpeg,
            true,
            &DerivativeMetadata::positive(domain::FilmProcess::C41ColorNegative, 4000),
        )
        .unwrap_err();

        assert_eq!(error.code, protocol::ErrorCode::ArchiveCollision);
        assert_eq!(std::fs::read(&derivative).unwrap(), b"raced-jpeg-final");
        assert_eq!(
            std::fs::read_dir(&dir).unwrap().count(),
            1,
            "temporary sibling must be cleaned"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn render_positive_actually_transforms_c41_color_negative() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        let (out, provenance) =
            render_positive(domain::FilmProcess::C41ColorNegative, &raw, 8, None)
                .expect("nikonlook bundle must load and apply");
        assert_ne!(out, raw, "nikonlook must actually transform the data");

        // Finding 2: a C41 render must surface its nikonlook provenance --
        // no exposure metadata supplied, so the blind path must have run.
        let provenance = provenance.expect("a C41 render must report nikonlook provenance");
        assert_eq!(provenance.bundle_version, "nikonlook-v2");
        assert_eq!(provenance.layer_a_path, domain::NikonlookLayerAPath::Blind);
        assert!(
            provenance.gains.iter().all(|value| value.is_finite() && *value > 0.0),
            "reported gains must be the real, finite, positive values estimate_gains returned: {:?}",
            provenance.gains
        );

        // The reported gains must be exactly what produced `out`, not a
        // separately-computed or stale value: re-applying them from scratch
        // against a freshly loaded bundle must reproduce the actual render.
        let bundle = crate::processing::nikonlook::load_bundle().expect("real v2 bundle must load");
        let reapplied = crate::processing::nikonlook::apply(&raw, provenance.gains, &bundle);
        assert_eq!(
            reapplied, out,
            "apply()'d output using the reported gains must equal the actual render"
        );
    }

    /// Same literal as `processing::nikonlook`'s own Group J/N tests and
    /// `tests/nikonlook_v2_fixture.rs`'s `EXPOSURE_10NS_FRAME5` -- a real,
    /// usable exposure triple.
    const USABLE_EXPOSURE_10NS: [f64; 3] = [127992.0, 312892.0, 259345.0];

    #[test]
    fn render_positive_c41_with_usable_exposure_labels_hardware_exposure() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        let (out, provenance) = render_positive(
            domain::FilmProcess::C41ColorNegative,
            &raw,
            8,
            Some(USABLE_EXPOSURE_10NS),
        )
        .expect("nikonlook bundle must load and apply");

        let provenance = provenance.expect("a C41 render must report nikonlook provenance");
        assert_eq!(provenance.bundle_version, "nikonlook-v2");
        assert_eq!(
            provenance.layer_a_path,
            domain::NikonlookLayerAPath::HardwareExposure,
            "a usable exposure_10ns must route to the hardware-exposure path, not fall back to blind"
        );

        let bundle = crate::processing::nikonlook::load_bundle().expect("real v2 bundle must load");
        let expected_gains = crate::processing::nikonlook::estimate_gains(
            &raw,
            8,
            Some(USABLE_EXPOSURE_10NS),
            &bundle,
        )
        .expect("exposure path never fails");
        assert_eq!(
            provenance.gains, expected_gains,
            "reported gains must equal estimate_gains' own output for this exposure"
        );
        let reapplied = crate::processing::nikonlook::apply(&raw, provenance.gains, &bundle);
        assert_eq!(
            reapplied, out,
            "apply()'d output using the reported gains must equal the actual render"
        );
    }

    #[test]
    fn render_positive_c41_with_malformed_exposure_falls_back_to_blind() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        // Non-finite, zero, and negative components are all "unusable" --
        // see processing::nikonlook::exposure_is_usable. One representative
        // case here; that predicate's own exhaustive cases are covered by
        // Group P in processing/nikonlook.rs.
        let malformed = [f64::NAN, 312892.0, 259345.0];

        let (_, provenance) = render_positive(
            domain::FilmProcess::C41ColorNegative,
            &raw,
            8,
            Some(malformed),
        )
        .expect("a malformed exposure must fall back to blind, never fail");

        let provenance = provenance.expect("a C41 render must report nikonlook provenance");
        assert_eq!(
            provenance.layer_a_path,
            domain::NikonlookLayerAPath::Blind,
            "a malformed exposure_10ns must be treated like None, not silently divided into a gain"
        );
    }

    #[test]
    fn render_positive_passthroughs_positive_kodachrome_and_neutral_inverts_bw_negative() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        for process in [
            domain::FilmProcess::Positive,
            domain::FilmProcess::Kodachrome,
        ] {
            let (out, provenance) =
                render_positive(process, &raw, 8, None).expect("passthrough never fails");
            assert_eq!(out, raw, "{process:?} must be an exact passthrough");
            assert!(
                provenance.is_none(),
                "{process:?} never runs nikonlook, so provenance must be None"
            );
        }
        let (bw, bw_provenance) =
            render_positive(domain::FilmProcess::BwNegative, &raw, 8, None).unwrap();
        assert!(
            bw_provenance.is_none(),
            "BwNegative never runs nikonlook, so provenance must be None"
        );
        for (source, rendered) in raw.iter().zip(bw) {
            let expected = 1.0 - (source[0] + source[1] + source[2]) / 3.0;
            assert_eq!(rendered, [expected; 3]);
        }
    }

    #[test]
    fn archive_write_is_create_only_and_never_overwrites() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).expect("create test dir");
        let path = dir.join("archive.tiff");
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);

        write_tiff_create_only(&path, &raw, 8, 6, 16).expect("first write succeeds");
        let original_bytes = std::fs::read(&path).expect("read back first write");

        let raw2 = generate_sim_frame("sim-ls5000-0", 2, 8, 6);
        let err = write_tiff_create_only(&path, &raw2, 8, 6, 16).unwrap_err();
        assert_eq!(err.code, protocol::ErrorCode::ArchiveCollision);

        let bytes_after = std::fs::read(&path).expect("read back after failed second write");
        assert_eq!(
            original_bytes, bytes_after,
            "archive bytes must be unchanged after a failed second write"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn archive_interruptions_before_publish_never_expose_final_leaf() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        for interruption_step in [
            ArchiveCommitStep::TemporaryReserved,
            ArchiveCommitStep::Encoded,
            ArchiveCommitStep::FileSynced,
            ArchiveCommitStep::Validated,
        ] {
            let dir = unique_test_dir();
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("archive.tiff");
            let error =
                write_tiff_create_only_with_hook(&path, &raw, 8, 6, 16, |step, temporary| {
                    assert!(temporary.exists(), "the private sibling exists at {step:?}");
                    assert!(
                        !path.exists(),
                        "the final archive leaf must remain absent at {step:?}"
                    );
                    if step == interruption_step {
                        return Err(domain::EngineError::new(
                            protocol::ErrorCode::Internal,
                            format!("simulated interruption after {step:?}"),
                        ));
                    }
                    Ok(())
                })
                .unwrap_err();
            assert!(error.message.contains("simulated interruption"));
            assert!(!path.exists());
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    #[test]
    fn archive_partial_encode_bytes_remain_private_at_multiple_cut_points() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        for byte_count in [1_usize, 8, 257] {
            let dir = unique_test_dir();
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("archive.tiff");
            let error =
                write_tiff_create_only_with_hook(&path, &raw, 8, 6, 16, |step, temporary| {
                    if step != ArchiveCommitStep::TemporaryReserved {
                        return Ok(());
                    }
                    let mut partial = std::fs::OpenOptions::new()
                        .write(true)
                        .truncate(true)
                        .open(temporary)
                        .unwrap();
                    partial.write_all(&vec![0xA5; byte_count]).unwrap();
                    partial.sync_all().unwrap();
                    assert_eq!(
                        std::fs::metadata(temporary).unwrap().len(),
                        byte_count as u64
                    );
                    assert!(!path.exists(), "partial bytes must stay off the final leaf");
                    Err(domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        format!("simulated process death after {byte_count} encoded bytes"),
                    ))
                })
                .unwrap_err();
            assert!(error.message.contains("simulated process death"));
            assert!(!path.exists());
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    #[test]
    fn archive_final_becomes_visible_only_as_a_valid_synced_tiff() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("archive.tiff");
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        write_tiff_create_only_with_hook(&path, &raw, 8, 6, 16, |step, _| {
            if matches!(
                step,
                ArchiveCommitStep::FinalPublished | ArchiveCommitStep::ParentSynced
            ) {
                validate_archive_tiff(&path, 8, 6, 16)?;
            } else {
                assert!(!path.exists(), "final leaf appeared too early at {step:?}");
            }
            Ok(())
        })
        .unwrap();
        validate_archive_tiff(&path, 8, 6, 16).unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn simulated_derivative_binding_uses_held_publication_not_reopened_replacement() {
        let root = unique_test_dir();
        std::fs::create_dir_all(&root).unwrap();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.enabled = false;
        recipes.raw_export.enabled = false;
        recipes.preview.enabled = false;
        recipes.positive.enabled = true;
        recipes.positive.destination = root.join("Positive").display().to_string();
        recipes.positive.filename_template = "positive.tif".to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;

        let written = render_and_write_frame_with_processing(
            "sim-ls5000-0",
            1,
            &domain::ProcessingRecipe {
                film_process: domain::FilmProcess::Positive,
                ..domain::ProcessingRecipe::default()
            },
            8,
            6,
            16,
            4000,
            false,
            &recipes,
            None,
            None,
        )
        .unwrap();
        let initial = crate::exiftool::bind_metadata_output_publications(
            &root,
            &written.metadata_publications,
        )
        .expect("the exact held derivative publication should bind");
        assert!(initial.positive.is_some());

        let positive = written.positive_path.as_ref().unwrap();
        let displaced = root.join("engine-authored-positive.tif");
        std::fs::rename(positive, &displaced).unwrap();
        std::fs::write(positive, b"attacker replacement").unwrap();

        let error = crate::exiftool::bind_metadata_output_publications(
            &root,
            &written.metadata_publications,
        )
        .unwrap_err();
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(
            error.message.contains("replaced") || error.message.contains("changed"),
            "unexpected refusal: {}",
            error.message
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn bridge_archive_binding_uses_held_nofollow_identity_not_reopened_replacement() {
        let root = unique_test_dir();
        let archive = root.join("Archive").join("bridge-rgb.tif");
        write_small_rgb16_tiff(&archive, 8, 6);
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.enabled = true;
        recipes.positive.enabled = false;
        recipes.preview.enabled = false;
        recipes.raw_export.enabled = false;

        let written = render_derivative_from_archive(
            &archive,
            1,
            domain::FilmProcess::Positive,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            4000,
        )
        .unwrap();
        let initial = crate::exiftool::bind_metadata_output_publications(
            &root,
            &written.metadata_publications,
        )
        .expect("the held bridge archive identity should bind");
        assert!(initial.archive.is_some());

        let displaced = root.join("bridge-rgb-original.tif");
        std::fs::rename(&archive, &displaced).unwrap();
        write_small_rgb16_tiff(&archive, 8, 6);

        let error = crate::exiftool::bind_metadata_output_publications(
            &root,
            &written.metadata_publications,
        )
        .unwrap_err();
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(
            error.message.contains("replaced") || error.message.contains("changed"),
            "unexpected refusal: {}",
            error.message
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn real_archive_derivatives_write_requested_files_without_mutating_archive() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        write_small_rgb16_tiff(&archive_path, 8, 6);
        let archive_before = std::fs::read(&archive_path).expect("read archive before");

        let mut recipes = domain::OutputRecipe::default();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.destination = dir.join("Preview").display().to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Jpeg;
        recipes.preview.max_long_edge_px = 4;

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            3200,
        )
        .expect("render real derivatives");

        assert_eq!(std::fs::read(&archive_path).unwrap(), archive_before);
        let canonical_archive_path = std::fs::canonicalize(&archive_path).unwrap();
        assert_eq!(
            written.archive_path.as_deref(),
            Some(canonical_archive_path.as_path())
        );
        assert!(written
            .positive_path
            .as_ref()
            .is_some_and(|path| path.is_file()));
        assert!(written
            .preview_path
            .as_ref()
            .is_some_and(|path| path.is_file()));
        let positive = image_io::read_rgb16(written.positive_path.as_ref().unwrap())
            .expect("positive is a readable RGB16 TIFF");
        assert_eq!((positive.width, positive.height), (8, 6));

        assert_eq!(
            <IccProfileValue<'static> as tiff::encoder::TiffValue>::FIELD_TYPE,
            tiff::tags::Type::UNDEFINED
        );
        let positive_bytes = std::fs::read(written.positive_path.as_ref().unwrap()).unwrap();
        assert_eq!(
            classic_tiff_field_type(&positive_bytes, 34675),
            Some(7),
            "TIFF ICC_Profile must use field type UNDEFINED (7), not BYTE (1)"
        );

        let positive_file = std::fs::File::open(written.positive_path.as_ref().unwrap()).unwrap();
        let mut positive_decoder = tiff::decoder::Decoder::new(positive_file).unwrap();
        assert!(matches!(
            positive_decoder
                .get_tag(tiff::tags::Tag::XResolution)
                .unwrap(),
            tiff::decoder::ifd::Value::Rational(3200, 1)
        ));
        assert!(matches!(
            positive_decoder
                .get_tag(tiff::tags::Tag::YResolution)
                .unwrap(),
            tiff::decoder::ifd::Value::Rational(3200, 1)
        ));
        assert_eq!(
            positive_decoder
                .get_tag_u32(tiff::tags::Tag::ResolutionUnit)
                .unwrap(),
            2
        );
        let positive_icc = positive_decoder
            .get_tag_u8_vec(tiff::tags::Tag::IccProfile)
            .expect("C41 Positive TIFF carries ICC");
        moxcms::ColorProfile::new_from_slice(&positive_icc).expect("Positive TIFF ICC parses");

        use image::ImageDecoder as _;
        let preview_file = std::fs::File::open(written.preview_path.as_ref().unwrap()).unwrap();
        let mut preview_decoder =
            image::codecs::jpeg::JpegDecoder::new(std::io::BufReader::new(preview_file)).unwrap();
        let preview_icc = preview_decoder
            .icc_profile()
            .unwrap()
            .expect("C41 Preview JPEG carries ICC");
        assert_eq!(
            preview_icc, positive_icc,
            "C41 color contract is format-independent"
        );

        // This is the exact function real_backend.rs's `run_real_scan_job_inner`
        // calls (`render_derivative_from_archive` is a thin exposure_10ns=None
        // wrapper around `render_derivative_from_archive_with_processing`) --
        // its `WrittenPaths.nikonlook` is copied verbatim into
        // `ScanReceipt.nikonlook` there (`receipt.nikonlook = written.nikonlook;`).
        // Proving it here, written for a real archive file on disk, is the
        // closest feasible proof of that patch-in short of standing up a
        // fake bridge subprocess to drive `run_real_scan_job_inner` itself.
        let provenance = written
            .nikonlook
            .expect("a C41 archive render must report nikonlook provenance");
        assert_eq!(provenance.bundle_version, "nikonlook-v2");
        assert_eq!(
            provenance.layer_a_path,
            domain::NikonlookLayerAPath::Blind,
            "render_derivative_from_archive supplies no exposure_10ns, so blind must have run"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_archive_derivative_transform_rotates_and_flips_both_outputs_without_mutating_master() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        std::fs::create_dir_all(archive_path.parent().unwrap()).unwrap();
        let source_pixels = vec![
            [1_000, 1_000, 1_000],
            [2_000, 2_000, 2_000],
            [3_000, 3_000, 3_000],
            [4_000, 4_000, 4_000],
            [5_000, 5_000, 5_000],
            [6_000, 6_000, 6_000],
        ];
        image_io::write_rgb16(
            &archive_path,
            &image_io::Rgb16Image {
                width: 3,
                height: 2,
                pixels: source_pixels,
            },
        )
        .unwrap();
        let archive_before = std::fs::read(&archive_path).unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.destination = dir.join("Preview").display().to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.max_long_edge_px = 100;
        let alignment = domain::FrameAlignment {
            offset_rows: 0,
            approved: false,
            derivative_transform: domain::DerivativeTransform {
                rotation_degrees: 90,
                horizontal_mirror: true,
                vertical_mirror: false,
            },
        };

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::Positive,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            Some(&alignment),
            4000,
        )
        .expect("render transformed derivatives");

        assert_eq!(std::fs::read(&archive_path).unwrap(), archive_before);
        assert_eq!(
            written.derivative_transform,
            domain::DerivativeTransform {
                rotation_degrees: 90,
                horizontal_mirror: true,
                vertical_mirror: false,
            }
        );
        let positive_path = written.positive_path.clone().unwrap();
        for path in [&written.positive_path, &written.preview_path] {
            let image = image_io::read_rgb16(path.as_ref().unwrap()).unwrap();
            assert_eq!((image.width, image.height), (2, 3));
            assert_eq!(
                image.pixels,
                vec![
                    [6_000, 6_000, 6_000],
                    [3_000, 3_000, 3_000],
                    [5_000, 5_000, 5_000],
                    [2_000, 2_000, 2_000],
                    [4_000, 4_000, 4_000],
                    [1_000, 1_000, 1_000],
                ]
            );
        }

        let mut decoder =
            tiff::decoder::Decoder::new(std::fs::File::open(positive_path).unwrap()).unwrap();
        assert!(
            decoder.get_tag(tiff::tags::Tag::IccProfile).is_err(),
            "positive-film passthrough must not be falsely labeled as ScanStudio RGB"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn derivative_transform_permutation_is_exact_for_every_rotation_and_mirror_combination() {
        let cases: &[(u16, bool, bool, (u32, u32), &[u16])] = &[
            (0, false, false, (3, 2), &[1, 2, 3, 4, 5, 6]),
            (0, true, false, (3, 2), &[3, 2, 1, 6, 5, 4]),
            (0, false, true, (3, 2), &[4, 5, 6, 1, 2, 3]),
            (0, true, true, (3, 2), &[6, 5, 4, 3, 2, 1]),
            (90, false, false, (2, 3), &[4, 1, 5, 2, 6, 3]),
            (90, true, false, (2, 3), &[6, 3, 5, 2, 4, 1]),
            (90, false, true, (2, 3), &[1, 4, 2, 5, 3, 6]),
            (90, true, true, (2, 3), &[3, 6, 2, 5, 1, 4]),
            (180, false, false, (3, 2), &[6, 5, 4, 3, 2, 1]),
            (180, true, false, (3, 2), &[4, 5, 6, 1, 2, 3]),
            (180, false, true, (3, 2), &[3, 2, 1, 6, 5, 4]),
            (180, true, true, (3, 2), &[1, 2, 3, 4, 5, 6]),
            (270, false, false, (2, 3), &[3, 6, 2, 5, 1, 4]),
            (270, true, false, (2, 3), &[1, 4, 2, 5, 3, 6]),
            (270, false, true, (2, 3), &[6, 3, 5, 2, 4, 1]),
            (270, true, true, (2, 3), &[4, 1, 5, 2, 6, 3]),
        ];

        for &(rotation_degrees, horizontal_mirror, vertical_mirror, dimensions, expected) in cases {
            let mut raw: Vec<[f64; 3]> = (1..=6).map(|value| [value as f64; 3]).collect();
            let actual_dimensions = apply_derivative_transform_in_place(
                &mut raw,
                3,
                2,
                domain::DerivativeTransform {
                    rotation_degrees,
                    horizontal_mirror,
                    vertical_mirror,
                },
            )
            .unwrap();
            assert_eq!(actual_dimensions, dimensions);
            assert_eq!(
                raw.iter().map(|pixel| pixel[0] as u16).collect::<Vec<_>>(),
                expected,
                "rotation={rotation_degrees}, horizontalMirror={horizontal_mirror}, verticalMirror={vertical_mirror}"
            );
        }
    }

    #[test]
    fn real_archive_derivative_nikonlook_provenance_tracks_exposure_usability() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        write_small_rgb16_tiff(&archive_path, 8, 6);

        let mut recipes = domain::OutputRecipe::default();
        recipes.preview.enabled = false;
        let processing = domain::ProcessingRecipe {
            film_process: domain::FilmProcess::C41ColorNegative,
            ..domain::ProcessingRecipe::default()
        };

        // A usable exposure -- the real_backend.rs path opted into it and
        // the bridge supplied a finite, positive triple.
        recipes.positive.destination = dir.join("Hardware").display().to_string();
        let written_hardware = render_derivative_from_archive_with_processing(
            &archive_path,
            1,
            &processing,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            Some(USABLE_EXPOSURE_10NS),
            4000,
        )
        .expect("render real derivatives");
        let hardware_provenance = written_hardware
            .nikonlook
            .expect("a C41 archive render must report nikonlook provenance");
        assert_eq!(
            hardware_provenance.layer_a_path,
            domain::NikonlookLayerAPath::HardwareExposure
        );

        // A malformed exposure -- must fall back to blind, never fail or
        // silently divide a meaningless ratio into the gain.
        recipes.positive.destination = dir.join("Malformed").display().to_string();
        let written_malformed = render_derivative_from_archive_with_processing(
            &archive_path,
            1,
            &processing,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            Some([f64::NAN, 312892.0, 259345.0]),
            4000,
        )
        .expect("a malformed exposure must fall back to blind, never fail");
        let malformed_provenance = written_malformed
            .nikonlook
            .expect("a C41 archive render must report nikonlook provenance");
        assert_eq!(
            malformed_provenance.layer_a_path,
            domain::NikonlookLayerAPath::Blind
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    fn write_autocrop_pattern_archive(path: &std::path::Path) -> (u32, u32) {
        let width = 480u32;
        let height = 320u32;
        let mut raw = vec![[0.95f64; 3]; (width * height) as usize];
        for y in 40..280u32 {
            for x in 40..440u32 {
                raw[(y * width + x) as usize] = [0.55; 3];
            }
        }
        for y in 58..262u32 {
            for x in 58..422u32 {
                let base = 0.15
                    + 0.20 * ((x - 58) as f64 / (422 - 58) as f64)
                    + 0.025 * ((y as f64) * 0.3).sin()
                    + 0.05;
                raw[(y * width + x) as usize] = [base * 0.8, base * 0.9, base];
            }
        }
        write_tiff_create_only(path, &raw, width, height, 16).expect("write autocrop archive");
        (width, height)
    }

    #[test]
    fn real_auto_crop_crops_derivatives_reports_roi_and_preserves_archive() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        let (width, height) = write_autocrop_pattern_archive(&archive_path);
        let archive_before = std::fs::read(&archive_path).unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.auto_crop = true;
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.destination = dir.join("Preview").display().to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.max_long_edge_px = 100;

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::Positive,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            4000,
        )
        .expect("auto-cropped derivatives render");

        assert_eq!(std::fs::read(&archive_path).unwrap(), archive_before);
        let outcome = written.auto_crop.expect("auto-crop outcome");
        assert!(outcome.applied);
        assert_eq!(
            (outcome.source_width, outcome.source_height),
            (width, height)
        );
        let roi = outcome.roi.expect("applied outcome carries ROI");
        assert!(roi.y1 > 0 && roi.x1 > 0 && roi.y2 < height && roi.x2 < width);

        let positive = image_io::read_rgb16(written.positive_path.as_ref().unwrap()).unwrap();
        assert_eq!(
            (positive.width, positive.height),
            (roi.x2 - roi.x1, roi.y2 - roi.y1)
        );
        let preview = image_io::read_rgb16(written.preview_path.as_ref().unwrap()).unwrap();
        assert_eq!(
            (preview.width, preview.height),
            downsample_dimensions(roi.x2 - roi.x1, roi.y2 - roi.y1, 100)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_auto_crop_off_keeps_full_frame_and_reports_nothing() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        let (width, height) = write_autocrop_pattern_archive(&archive_path);
        let mut recipes = domain::OutputRecipe::default();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::Positive,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            4000,
        )
        .unwrap();
        assert!(written.auto_crop.is_none());
        let positive = image_io::read_rgb16(written.positive_path.as_ref().unwrap()).unwrap();
        assert_eq!((positive.width, positive.height), (width, height));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_auto_crop_defers_to_approved_alignment() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        let (width, _) = write_autocrop_pattern_archive(&archive_path);
        let mut recipes = domain::OutputRecipe::default();
        recipes.auto_crop = true;
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;
        let alignment = domain::FrameAlignment {
            offset_rows: 0,
            approved: true,
            derivative_transform: domain::DerivativeTransform::default(),
        };

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::Positive,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            Some((40, 280)),
            Some(&alignment),
            4000,
        )
        .unwrap();
        let outcome = written.auto_crop.expect("deferred outcome");
        assert!(!outcome.applied);
        assert!(outcome
            .reason
            .as_deref()
            .is_some_and(|reason| reason.contains("alignment")));
        let positive = image_io::read_rgb16(written.positive_path.as_ref().unwrap()).unwrap();
        assert_eq!((positive.width, positive.height), (width, 241));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn output_recipe_auto_crop_defaults_false_and_round_trips_camel_case() {
        let parsed: domain::OutputRecipe = serde_json::from_str("{}").unwrap();
        assert!(!parsed.auto_crop);
        let mut recipes = domain::OutputRecipe::default();
        recipes.auto_crop = true;
        let json = serde_json::to_string(&recipes).unwrap();
        assert!(json.contains("\"autoCrop\":true"));
        assert!(
            serde_json::from_str::<domain::OutputRecipe>(&json)
                .unwrap()
                .auto_crop
        );
    }

    #[test]
    fn real_bw_dust_option_changes_only_derivatives_and_default_off_matches_explicit_false() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        let mut raw = vec![[0.5; 3]; 225];
        for index in [112, 113, 127, 128] {
            raw[index] = [0.0; 3];
        }
        write_tiff_create_only(&archive_path, &raw, 15, 15, 16).unwrap();
        let archive_before = std::fs::read(&archive_path).unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.preview.enabled = false;
        recipes.positive.destination = dir.join("Off").display().to_string();
        let default_off = domain::ProcessingRecipe {
            film_process: domain::FilmProcess::BwNegative,
            ..domain::ProcessingRecipe::default()
        };
        let written_off = render_derivative_from_archive_with_processing(
            &archive_path,
            1,
            &default_off,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            None,
            4000,
        )
        .unwrap();
        let off_bytes = std::fs::read(written_off.positive_path.unwrap()).unwrap();

        recipes.positive.destination = dir.join("ExplicitFalse").display().to_string();
        let explicit_false = domain::ProcessingRecipe {
            film_process: domain::FilmProcess::BwNegative,
            software_dust_removal_bw: false,
            ..domain::ProcessingRecipe::default()
        };
        let written_false = render_derivative_from_archive_with_processing(
            &archive_path,
            1,
            &explicit_false,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            None,
            4000,
        )
        .unwrap();
        assert_eq!(
            off_bytes,
            std::fs::read(written_false.positive_path.unwrap()).unwrap()
        );

        recipes.positive.destination = dir.join("On").display().to_string();
        let enabled = domain::ProcessingRecipe {
            film_process: domain::FilmProcess::BwNegative,
            software_dust_removal_bw: true,
            ..domain::ProcessingRecipe::default()
        };
        let written_on = render_derivative_from_archive_with_processing(
            &archive_path,
            1,
            &enabled,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            None,
            4000,
        )
        .unwrap();
        assert_ne!(
            off_bytes,
            std::fs::read(written_on.positive_path.unwrap()).unwrap()
        );
        assert_eq!(std::fs::read(&archive_path).unwrap(), archive_before);

        let c41 = domain::ProcessingRecipe {
            film_process: domain::FilmProcess::C41ColorNegative,
            software_dust_removal_bw: true,
            ..domain::ProcessingRecipe::default()
        }
        .effective();
        assert!(!c41.software_dust_removal_bw);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_archive_with_all_outputs_disabled_needs_no_file_or_transform() {
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.enabled = false;
        recipes.positive.enabled = false;
        recipes.preview.enabled = false;

        let missing = unique_test_dir().join("missing.tif");
        let written = render_derivative_from_archive(
            &missing,
            7,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            None,
            None,
            None,
            None,
            4000,
        )
        .expect("disabled derivatives are a no-op");
        assert!(written.archive_path.is_none());
        assert!(written.positive_path.is_none());
        assert!(written.preview_path.is_none());
    }

    #[test]
    fn real_archive_derivatives_refuse_unknown_orientation_profile_and_crop() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive_0001.tif");
        write_small_rgb16_tiff(&archive_path, 8, 6);
        let mut recipes = domain::OutputRecipe::default();
        recipes.preview.enabled = false;

        let missing_transform = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            None,
            None,
            None,
            None,
            4000,
        )
        .unwrap_err();
        assert_eq!(missing_transform.code, protocol::ErrorCode::InvalidParams);

        let wrong_transform = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            Some("rot90k1-scanner-native-to-storage-v1"),
            None,
            None,
            None,
            4000,
        )
        .unwrap_err();
        assert_eq!(wrong_transform.code, protocol::ErrorCode::InvalidParams);

        recipes.positive.color_profile = domain::OutputColorProfile::SRgb;
        let unsupported_profile = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            4000,
        )
        .unwrap_err();
        assert_eq!(unsupported_profile.code, protocol::ErrorCode::InvalidParams);

        recipes.positive.color_profile = domain::OutputColorProfile::AdobeRgb1998;
        let missing_boundary = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            Some(&domain::FrameAlignment::approved(0)),
            4000,
        )
        .unwrap_err();
        assert_eq!(missing_boundary.code, protocol::ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn render_and_write_frame_refuses_a_positive_path_aliasing_the_archive() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "Frame_####".to_string();
        recipes.positive.destination = dir.display().to_string();
        recipes.positive.filename_template = "Frame_####".to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;

        let err = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes,
            None,
            None,
        )
        .unwrap_err();
        assert_eq!(err.code, protocol::ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn render_and_write_frame_refuses_a_preview_path_aliasing_the_archive() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "Frame_####".to_string();
        recipes.positive.enabled = false;
        recipes.preview.destination = dir.display().to_string();
        recipes.preview.filename_template = "Frame_####".to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Tiff;

        let err = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes,
            None,
            None,
        )
        .unwrap_err();
        assert_eq!(err.code, protocol::ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn render_and_write_frame_writes_all_three_real_files_when_enabled() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.join("Archive").display().to_string();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.destination = dir.join("Preview").display().to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Jpeg;
        recipes.preview.max_long_edge_px = 4;

        let written = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::C41ColorNegative,
            8,
            6,
            16,
            &recipes,
            None,
            None,
        )
        .expect("all three outputs must write successfully");

        assert!(
            written
                .archive_path
                .as_ref()
                .is_some_and(|path| path.is_file()),
            "archive file must exist on disk"
        );
        let positive_path = written.positive_path.expect("positive enabled by default");
        assert!(positive_path.is_file(), "positive file must exist on disk");
        let preview_path = written.preview_path.expect("preview enabled by default");
        assert!(preview_path.is_file(), "preview file must exist on disk");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn simulator_derivative_only_outputs_create_no_archive_file_or_directory() {
        let dir = unique_test_dir();
        let archive = dir.join("master-must-not-exist");
        let positive = dir.join("positive");
        let preview = dir.join("preview");
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.enabled = false;
        recipes.archive.destination = archive.display().to_string();
        recipes.positive.enabled = true;
        recipes.positive.destination = positive.display().to_string();
        recipes.preview.enabled = true;
        recipes.preview.destination = preview.display().to_string();

        let written = render_and_write_frame_with_processing(
            "sim-ls5000-0",
            1,
            &domain::ProcessingRecipe::default(),
            16,
            12,
            16,
            4000,
            true,
            &recipes,
            None,
            None,
        )
        .expect("derivative-only simulator scan succeeds");

        assert_eq!(written.archive_path, None);
        assert!(
            !archive.exists(),
            "disabled master must not create even its folder"
        );
        assert!(written
            .positive_path
            .as_ref()
            .is_some_and(|path| path.is_file()));
        assert!(written
            .preview_path
            .as_ref()
            .is_some_and(|path| path.is_file()));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn archive_bytes_are_identical_with_and_without_an_approved_crop() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.join("Archive").display().to_string();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;

        let boundary = (1, 4);
        let alignment = domain::FrameAlignment::approved(1);

        let written_no_crop = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes,
            Some(boundary),
            None,
        )
        .expect("no-crop render must succeed");
        let archive_bytes_no_crop = std::fs::read(
            written_no_crop
                .archive_path
                .as_ref()
                .expect("archive retained"),
        )
        .expect("read archive without crop");

        // Use a fresh destination so the create-only archive write does not
        // collide; we are testing that the archive bytes stay identical, not
        // that a collision occurs.
        let mut recipes_cropped = recipes.clone();
        recipes_cropped.archive.destination = dir.join("ArchiveCropped").display().to_string();
        recipes_cropped.positive.destination = dir.join("PositiveCropped").display().to_string();
        let written_cropped = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes_cropped,
            Some(boundary),
            Some(&alignment),
        )
        .expect("cropped render must succeed");
        let archive_bytes_cropped = std::fs::read(
            written_cropped
                .archive_path
                .as_ref()
                .expect("archive retained"),
        )
        .expect("read archive with crop");

        assert_eq!(
            archive_bytes_no_crop, archive_bytes_cropped,
            "archive master must be byte-identical whether or not a crop is set"
        );

        // Sanity: the derived positive did actually get cropped.
        let positive_no_crop_len = std::fs::metadata(&written_no_crop.positive_path.unwrap())
            .map(|m| m.len())
            .unwrap_or(0);
        let positive_cropped_len = std::fs::metadata(&written_cropped.positive_path.unwrap())
            .map(|m| m.len())
            .unwrap_or(0);
        assert_ne!(
            positive_no_crop_len, positive_cropped_len,
            "cropped derivative must differ from uncropped derivative"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn derived_output_changes_when_crop_changes_without_rescan() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.join("Archive").display().to_string();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;

        let boundary = (1, 4);

        let mut recipes_a = recipes.clone();
        recipes_a.positive.destination = dir.join("PositiveA").display().to_string();
        let written_a = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes_a,
            Some(boundary),
            Some(&domain::FrameAlignment::approved(0)),
        )
        .expect("crop A");

        let mut recipes_b = recipes.clone();
        recipes_b.archive.destination = dir.join("ArchiveB").display().to_string();
        recipes_b.positive.destination = dir.join("PositiveB").display().to_string();
        let written_b = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes_b,
            Some(boundary),
            Some(&domain::FrameAlignment::approved(1)),
        )
        .expect("crop B");

        let bytes_a = std::fs::read(&written_a.positive_path.unwrap()).expect("read positive A");
        let bytes_b = std::fs::read(&written_b.positive_path.unwrap()).expect("read positive B");
        assert_ne!(
            bytes_a, bytes_b,
            "a different relative offset must produce different derived output"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn relative_offset_survives_a_different_absolute_detected_row() {
        // The core relative-intent property: the stored offset is relative to
        // the detected boundary, so when detection finds a different absolute
        // row, the same offset shifts the new boundary by the same amount.
        let offset_rows: i64 = 2;
        let boundary_a = (10, 20);
        let boundary_b = (15, 25);
        let (_, _, height_a) = resolve_aligned_crop(boundary_a.0, boundary_a.1, offset_rows, 30);
        let (top_b, _, height_b) =
            resolve_aligned_crop(boundary_b.0, boundary_b.1, offset_rows, 30);

        assert_eq!(top_b, boundary_b.0 + offset_rows as u32);
        assert_eq!(
            height_a, height_b,
            "same relative offset must preserve crop height"
        );
    }

    #[test]
    fn unapproved_alignment_is_inert_for_derivatives() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        let (out, w, h) = apply_alignment_crop(
            &raw,
            8,
            6,
            Some((1, 4)),
            Some(&domain::FrameAlignment::draft(2)),
        );
        assert_eq!(out, raw);
        assert_eq!(w, 8);
        assert_eq!(h, 6);
    }

    #[test]
    fn generate_synthetic_defects_is_deterministic_for_identical_arguments() {
        let capture = domain::CaptureRecipe::default();
        let processing = domain::ProcessingRecipe::default();
        let a = generate_synthetic_defects(5, &capture, &processing);
        let b = generate_synthetic_defects(5, &capture, &processing);
        assert_eq!(
            a, b,
            "identical arguments must reproduce a byte-identical Vec"
        );
        assert!(
            !a.is_empty(),
            "digital ICE is enabled by default; the generator must actually produce instances"
        );
    }

    #[test]
    fn generate_synthetic_defects_varies_with_frame_index() {
        let capture = domain::CaptureRecipe::default();
        let processing = domain::ProcessingRecipe::default();
        let one = generate_synthetic_defects(1, &capture, &processing);
        let two = generate_synthetic_defects(2, &capture, &processing);
        assert_ne!(
            one, two,
            "different frame indices must vary the generated defects"
        );
    }

    #[test]
    fn generate_synthetic_defects_is_empty_when_digital_ice_disabled() {
        let capture = domain::CaptureRecipe::default();
        let processing = domain::ProcessingRecipe {
            digital_ice_enabled: false,
            ..domain::ProcessingRecipe::default()
        };
        for frame_index in 1..=5 {
            let defects = generate_synthetic_defects(frame_index, &capture, &processing);
            assert!(
                defects.is_empty(),
                "frame {frame_index}: digital ICE off must never fabricate detections"
            );
        }
    }

    #[test]
    fn generate_synthetic_defects_stays_within_documented_bounds_across_many_frames() {
        let capture = domain::CaptureRecipe::default();
        let processing = domain::ProcessingRecipe::default();
        for frame_index in 1..=36 {
            let defects = generate_synthetic_defects(frame_index, &capture, &processing);
            let count = defects.len() as u32;
            assert!(
                (MIN_DEFECT_COUNT..=MAX_DEFECT_COUNT).contains(&count),
                "frame {frame_index}: defect count {count} out of [{MIN_DEFECT_COUNT}, {MAX_DEFECT_COUNT}]"
            );
            for instance in &defects {
                assert!(
                    (DEFECT_SEVERITY_FLOOR..=1.0).contains(&instance.severity),
                    "frame {frame_index}: severity {} out of bounds",
                    instance.severity
                );
                assert!(
                    (0.0..=1.0).contains(&instance.center_x)
                        && (0.0..=1.0).contains(&instance.center_y),
                    "frame {frame_index}: center ({}, {}) outside the unit square",
                    instance.center_x,
                    instance.center_y
                );
                assert_eq!(
                    instance.classification,
                    classify_defect_severity(instance.severity),
                    "frame {frame_index}: classification must agree with classify_defect_severity(severity)"
                );
                match &instance.kind {
                    domain::DefectKind::Scratch => {
                        let end_x = instance
                            .end_x
                            .expect("scratch instance must populate end_x");
                        let end_y = instance
                            .end_y
                            .expect("scratch instance must populate end_y");
                        assert!(
                            (0.0..=1.0).contains(&end_x),
                            "frame {frame_index}: end_x {end_x} out of bounds"
                        );
                        assert!(
                            (0.0..=1.0).contains(&end_y),
                            "frame {frame_index}: end_y {end_y} out of bounds"
                        );
                    }
                    domain::DefectKind::Dust => {
                        assert!(
                            instance.end_x.is_none(),
                            "frame {frame_index}: dust must omit end_x"
                        );
                        assert!(
                            instance.end_y.is_none(),
                            "frame {frame_index}: dust must omit end_y"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn classify_defect_severity_respects_threshold_boundary() {
        assert_eq!(
            classify_defect_severity(DEFECT_CLASSIFICATION_THRESHOLD - 0.01),
            domain::DefectClassification::WillCorrect
        );
        assert_eq!(
            classify_defect_severity(DEFECT_CLASSIFICATION_THRESHOLD),
            domain::DefectClassification::Uncertain
        );
        assert_eq!(
            classify_defect_severity(1.0),
            domain::DefectClassification::Uncertain
        );
        assert_eq!(
            classify_defect_severity(DEFECT_SEVERITY_FLOOR),
            domain::DefectClassification::WillCorrect
        );
    }

    // -----------------------------------------------------------------
    // Real defect-map clustering tests
    // -----------------------------------------------------------------

    fn map_from_grid(
        width: u32,
        height: u32,
        on_pixels: &[(u32, u32)],
        score: f32,
    ) -> ice::DefectMap {
        let mut scores = vec![0.0_f32; width as usize * height as usize];
        for &(x, y) in on_pixels {
            scores[y as usize * width as usize + x as usize] = score;
        }
        ice::DefectMap {
            width,
            height,
            score: scores,
        }
    }

    #[test]
    fn cluster_defect_map_all_zero_returns_empty() {
        let map = map_from_grid(30, 30, &[], 0.5);
        assert!(
            cluster_defect_map(&map).is_empty(),
            "all-zero map must yield no instances"
        );

        let empty = ice::DefectMap {
            width: 0,
            height: 0,
            score: Vec::new(),
        };
        assert!(
            cluster_defect_map(&empty).is_empty(),
            "0x0 map must yield no instances"
        );
    }

    #[test]
    fn cluster_defect_map_single_compact_block_returns_one_dust() {
        let mut pixels = Vec::new();
        for y in 10..13 {
            for x in 10..13 {
                pixels.push((x, y));
            }
        }
        let map = map_from_grid(30, 30, &pixels, 0.6);
        let instances = cluster_defect_map(&map);
        assert_eq!(
            instances.len(),
            1,
            "compact block must cluster into one instance"
        );

        let instance = &instances[0];
        assert_eq!(instance.id, 0);
        assert_eq!(instance.kind, domain::DefectKind::Dust);
        assert_eq!(
            instance.classification,
            domain::DefectClassification::WillCorrect
        );
        assert!(instance.end_x.is_none(), "dust must omit end_x");
        assert!(instance.end_y.is_none(), "dust must omit end_y");
        assert!(instance.center_x >= 10.0 / 30.0 && instance.center_x <= 12.0 / 30.0);
        assert!(instance.center_y >= 10.0 / 30.0 && instance.center_y <= 12.0 / 30.0);
        assert!(instance.radius > 0.0, "dust radius must be positive");
    }

    #[test]
    fn cluster_defect_map_single_diagonal_run_returns_one_scratch() {
        // A steep 1-pixel-wide diagonal run: ~15 pixels tall, ~5 pixels wide,
        // giving a bounding-box aspect ratio >= 3 so it classifies as Scratch.
        let mut pixels = Vec::new();
        for y in 0..15 {
            let x = y / 3;
            pixels.push((x, y));
        }
        let map = map_from_grid(30, 30, &pixels, 0.85);
        let instances = cluster_defect_map(&map);
        assert_eq!(
            instances.len(),
            1,
            "elongated run must cluster into one instance"
        );

        let instance = &instances[0];
        assert_eq!(instance.id, 0);
        assert_eq!(instance.kind, domain::DefectKind::Scratch);
        assert_eq!(
            instance.classification,
            domain::DefectClassification::Uncertain
        );
        assert!(instance.end_x.is_some(), "scratch must populate end_x");
        assert!(instance.end_y.is_some(), "scratch must populate end_y");
        assert!((0.0..=1.0).contains(&instance.center_x));
        assert!((0.0..=1.0).contains(&instance.center_y));
        assert!(instance.radius > 0.0, "scratch radius must be positive");
    }

    #[test]
    fn cluster_defect_map_two_disjoint_components_return_two_instances() {
        let mut dust_pixels = Vec::new();
        for y in 5..8 {
            for x in 5..8 {
                dust_pixels.push((x, y));
            }
        }
        let mut scratch_pixels = Vec::new();
        for x in 20..35 {
            scratch_pixels.push((x, 25));
        }

        let mut all_pixels = dust_pixels.clone();
        all_pixels.extend(&scratch_pixels);
        let map = map_from_grid(40, 40, &all_pixels, 0.7);
        let instances = cluster_defect_map(&map);
        assert_eq!(
            instances.len(),
            2,
            "disjoint components must stay separated"
        );
        assert_eq!(instances[0].id, 0);
        assert_eq!(instances[1].id, 1);

        let dust = instances
            .iter()
            .find(|i| i.kind == domain::DefectKind::Dust)
            .expect("dust component must be present");
        let scratch = instances
            .iter()
            .find(|i| i.kind == domain::DefectKind::Scratch)
            .expect("scratch component must be present");
        assert!(dust.end_x.is_none() && dust.end_y.is_none());
        assert!(scratch.end_x.is_some() && scratch.end_y.is_some());
    }

    #[test]
    fn cluster_defect_map_edge_component_is_clamped_to_unit_square() {
        let mut pixels = Vec::new();
        for y in 0..3 {
            for x in 0..3 {
                pixels.push((x, y));
            }
        }
        let map = map_from_grid(10, 10, &pixels, 0.5);
        let instances = cluster_defect_map(&map);
        assert_eq!(instances.len(), 1);
        let instance = &instances[0];
        assert!(
            (0.0..=1.0).contains(&instance.center_x),
            "center_x must be clamped"
        );
        assert!(
            (0.0..=1.0).contains(&instance.center_y),
            "center_y must be clamped"
        );
        assert!(
            instance.radius >= DEFECT_INSTANCE_RADIUS_MIN
                && instance.radius <= DEFECT_INSTANCE_RADIUS_MAX
        );
    }

    #[test]
    fn cluster_defect_map_is_deterministic_for_identical_inputs() {
        let mut pixels = Vec::new();
        for y in 5..8 {
            for x in 5..8 {
                pixels.push((x, y));
            }
        }
        let map = map_from_grid(20, 20, &pixels, 0.55);
        let a = cluster_defect_map(&map);
        let b = cluster_defect_map(&map);
        assert_eq!(a, b, "identical inputs must produce byte-identical output");
    }

    #[test]
    fn real_frame_defects_short_circuits_on_digital_ice_disabled_without_touching_disk() {
        let processing = domain::ProcessingRecipe {
            digital_ice_enabled: false,
            ..domain::ProcessingRecipe::default()
        };
        let result = real_frame_defects(
            std::path::Path::new("/nonexistent/does-not-exist-rgb.tif"),
            std::path::Path::new("/nonexistent/does-not-exist-ir.tif"),
            &processing,
        );
        assert_eq!(
            result,
            Ok(Vec::new()),
            "ICE off must short-circuit before disk I/O"
        );
    }
}
