//! Project manifest persistence (PROJ-01/PROJ-02, PERSIST-01).
//!
//! `domain.rs` owns the manifest *shape* (`ScanProject`/`ProjectFrame`/
//! `ProjectSummary`); this module owns *how* that shape gets to and from
//! disk: atomic writes (temp file + rename, so a crash mid-write can never
//! leave a corrupt `manifest.json`), strict schema-version validation on
//! read, project create/open/list over the local filesystem, and -- since
//! the scan worker thread and the server's request-dispatch thread can
//! both want to mutate the same project's manifest at once (PERSIST-02) --
//! a single process-wide lock plus a receipt-preserving merge every
//! multi-field write routes through, with a fail-closed guard on the
//! underlying write itself as a structural backstop.
//!
//! No new crates: `SystemTime`/`std::env` for ids and default paths
//! (matching `sim.rs`'s dependency-free approach), and plain
//! `std::fs`/`std::path` for everything else.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::domain::{
    ArchiveRecipe, EngineError, FilmProcess, MediaCarrier, MetadataSet, OutputRecipe,
    PositiveRecipe, PreviewRecipe, ProjectFrame, ProjectSummary, ScanProject,
};
use crate::protocol::ErrorCode;

/// The schema version this build of the engine writes for every new or
/// resaved manifest. `read_manifest` accepts any version in
/// `MIN_SUPPORTED_SCHEMA_VERSION..=CURRENT_SCHEMA_VERSION`: an older
/// manifest decodes via `#[serde(default)]` on every field added since its
/// version (e.g. v1 has no `recipes`/`outputOverride` keys — they fill in
/// with `OutputRecipe::default()`/`None`), and the next atomic write
/// naturally upgrades the file back to `CURRENT_SCHEMA_VERSION` — there is
/// no separate "migrate and rewrite" step.
pub const CURRENT_SCHEMA_VERSION: u32 = 4;
/// The oldest `schemaVersion` `read_manifest` still opens. Anything older,
/// or newer than `CURRENT_SCHEMA_VERSION`, is `ManifestInvalid`.
pub const MIN_SUPPORTED_SCHEMA_VERSION: u32 = 1;

const MANIFEST_FILE_NAME: &str = "manifest.json";
const MANIFEST_TMP_FILE_NAME: &str = ".manifest.json.tmp";

// ---------------------------------------------------------------------
// Paths, ids, slugs
// ---------------------------------------------------------------------

/// `$HOME/ScanStudio Projects`. Falls back to the current working
/// directory (then `.`) if `HOME` is unset — an unusual sandboxed-shell
/// case, not the expected path.
pub fn default_projects_root() -> PathBuf {
    let base = match std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")) {
        Ok(home) => PathBuf::from(home),
        Err(_) => std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
    };
    base.join("ScanStudio Projects")
}

/// Lowercases `name`, collapses every run of non-ASCII-alphanumeric
/// characters to a single hyphen, and trims leading/trailing hyphens. A
/// name with no alphanumeric content at all (empty string, pure
/// punctuation) falls back to `"project"` rather than an empty slug.
pub fn slugify(name: &str) -> String {
    let mut slug = String::with_capacity(name.len());
    let mut last_was_hyphen = false;
    for ch in name.to_lowercase().chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch);
            last_was_hyphen = false;
        } else if !last_was_hyphen {
            slug.push('-');
            last_was_hyphen = true;
        }
    }
    let trimmed = slug.trim_matches('-');
    if trimmed.is_empty() {
        "project".to_string()
    } else {
        trimmed.to_string()
    }
}

/// `proj-{hex nanos since epoch}`. Computes the timestamp exactly once —
/// callers that also need a directory-name suffix reuse this same id
/// verbatim rather than taking a second timestamp.
pub fn generate_project_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("proj-{nanos:x}")
}

// ---------------------------------------------------------------------
// Atomic read/write
// ---------------------------------------------------------------------

fn io_err_to_internal(err: io::Error) -> EngineError {
    EngineError::new(ErrorCode::Internal, format!("manifest I/O error: {err}"))
}

/// The one process-wide gate a manifest read-modify-write cycle must hold
/// for its *full* extent, not just its final write. `write_manifest_
/// atomically`'s rename is atomic per call, but "read the current file,
/// decide what the new one should say" is not a single atomic operation —
/// the window between one thread's read and its write is exactly where
/// another thread's own write can land and then be silently discarded the
/// moment the first thread's write lands on top of it (PERSIST-02: this is
/// how a scan's completed-frame receipt used to get destroyed by the very
/// next scan's own best-effort recipe save). Exactly two threads ever write
/// a given project's manifest in this process — the server's single
/// request-dispatch thread and a scan job's worker thread (via
/// `persist_frame_receipt`) — so a plain `Mutex` scoped to this process is
/// sufficient; there is no other process ever writing this file.
/// `persist_project_update` and `persist_frame_receipt` are the only two
/// functions that acquire it; `write_manifest_atomically` deliberately does
/// not, so those two can call it while already holding the lock without
/// deadlocking on themselves.
static MANIFEST_LOCK: Mutex<()> = Mutex::new(());

/// Acquires `MANIFEST_LOCK`, recovering from poisoning rather than
/// propagating it. A panic while some *other* caller held the lock is not
/// evidence that the manifest on disk is corrupt, and refusing every future
/// read/write for the rest of the process over one past panic would be a
/// self-inflicted, permanent denial of service — `write_manifest_
/// atomically`'s own guard is what actually protects the data; this lock
/// only orders access to it.
fn manifest_lock() -> std::sync::MutexGuard<'static, ()> {
    MANIFEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Writes `project` to `directory/manifest.json`, atomically: serialize to
/// a sibling temp file inside the same directory, then `fs::rename` it
/// into place. `fs::rename` within a single filesystem is atomic, so a
/// crash or kill mid-write can never leave a partially-written
/// `manifest.json` — readers see either the old file or the fully-written
/// new one, never a torn write.
///
/// Fail-closed provenance guard (PERSIST-02): before writing anything,
/// every frame currently on disk has its receipts compared against
/// `project`'s own — if disk holds so much as one receipt `project` does
/// not, this write would destroy a durable scan record and is refused
/// outright instead of performed. `persist_project_update` and
/// `persist_frame_receipt` read-merge-write under `MANIFEST_LOCK`, so by
/// construction their own writes are always supersets of whatever they just
/// read and this guard should never fire against them in normal operation;
/// it exists as the structural backstop for a write that reaches here some
/// other way — a future caller that skips the lock, or a lock-holder racing
/// one of the two callers that don't take it (`create_project`, whose fresh
/// directory has nothing to race; `open_project`'s destination-migration
/// write, which touches `recipes` only and carries forward whatever
/// receipts it just read) — in which case refusing the write outright is
/// still strictly safer than the silent overwrite this guard exists to
/// make impossible. A missing manifest has nothing to compare against and
/// is always allowed (a brand new project's first save); an existing
/// manifest that cannot be read or parsed is refused rather than trusted or
/// blindly overwritten — that corruption needs a human, not this function,
/// to resolve.
pub fn write_manifest_atomically(
    directory: &Path,
    project: &ScanProject,
) -> Result<(), EngineError> {
    match read_manifest(directory) {
        Ok(on_disk) => {
            for on_disk_frame in &on_disk.frames {
                let incoming_receipts = project
                    .frames
                    .iter()
                    .find(|frame| frame.index == on_disk_frame.index)
                    .map(|frame| frame.receipts.as_slice())
                    .unwrap_or(&[]);
                if let Some(lost) = on_disk_frame
                    .receipts
                    .iter()
                    .find(|receipt| !incoming_receipts.contains(receipt))
                {
                    return Err(EngineError::new(
                        ErrorCode::ManifestInvalid,
                        format!(
                            "refusing to write manifest at {}: frame {} would lose its on-disk receipt from job {} (started {}) — this write was not derived from the manifest currently on disk; read, merge, and retry through persist_project_update instead of overwriting",
                            directory.display(),
                            on_disk_frame.index,
                            lost.job_id,
                            lost.started_at,
                        ),
                    ));
                }
            }
        }
        Err(err) if err.code == ErrorCode::ProjectNotFound => {}
        Err(err) => {
            return Err(EngineError::new(
                ErrorCode::ManifestInvalid,
                format!(
                    "refusing to write manifest at {}: the existing manifest cannot be read ({err}) — manual recovery is needed before this project can be written to again",
                    directory.display(),
                ),
            ));
        }
    }
    write_manifest_bytes(directory, project)
}

/// The actual bytes-to-disk half of `write_manifest_atomically`, split out
/// so the guard above it has a single unconditional place to delegate to
/// once it has decided the write is safe. Never call this directly outside
/// that guard — it is the one thing `write_manifest_atomically` exists to
/// wrap.
fn write_manifest_bytes(directory: &Path, project: &ScanProject) -> Result<(), EngineError> {
    fs::create_dir_all(directory).map_err(io_err_to_internal)?;

    let json = serde_json::to_string_pretty(project).map_err(|err| {
        EngineError::new(
            ErrorCode::Internal,
            format!("failed to serialize manifest: {err}"),
        )
    })?;

    let tmp_path = directory.join(MANIFEST_TMP_FILE_NAME);
    fs::write(&tmp_path, json).map_err(io_err_to_internal)?;

    let final_path = directory.join(MANIFEST_FILE_NAME);
    fs::rename(&tmp_path, &final_path).map_err(io_err_to_internal)?;

    Ok(())
}

/// Reads and validates `directory/manifest.json`. A missing directory or a
/// directory with no `manifest.json` inside it is `ProjectNotFound` — that
/// is the expected shape of "there is no project here", not an anomaly.
/// Anything else that goes wrong (unreadable file, invalid JSON, or a
/// `schemaVersion` this build doesn't recognize) is `ManifestInvalid`: the
/// manifest exists but cannot be trusted, and is never partially trusted
/// or silently coerced.
pub fn read_manifest(directory: &Path) -> Result<ScanProject, EngineError> {
    let path = directory.join(MANIFEST_FILE_NAME);
    let contents = fs::read_to_string(&path).map_err(|err| {
        if err.kind() == io::ErrorKind::NotFound {
            EngineError::new(
                ErrorCode::ProjectNotFound,
                format!("no project found at {}", directory.display()),
            )
        } else {
            EngineError::new(
                ErrorCode::ManifestInvalid,
                format!("failed to read manifest at {}: {err}", directory.display()),
            )
        }
    })?;

    let project: ScanProject = serde_json::from_str(&contents).map_err(|err| {
        EngineError::new(
            ErrorCode::ManifestInvalid,
            format!("failed to parse manifest at {}: {err}", directory.display()),
        )
    })?;

    if project.schema_version < MIN_SUPPORTED_SCHEMA_VERSION
        || project.schema_version > CURRENT_SCHEMA_VERSION
    {
        return Err(EngineError::new(
            ErrorCode::ManifestInvalid,
            format!(
                "unsupported manifest schemaVersion {} at {} (supported range {MIN_SUPPORTED_SCHEMA_VERSION}..={CURRENT_SCHEMA_VERSION})",
                project.schema_version,
                directory.display()
            ),
        ));
    }

    Ok(project)
}

// ---------------------------------------------------------------------
// Project create / open / list
// ---------------------------------------------------------------------

/// `Roll36` is the legacy wire token for SA-30 roll film and accepts its
/// preview-established 1-40 frame count; `Mounted` must be exactly 1;
/// `Strip6` is 1-6 as chosen at creation time. Any other count for that carrier is
/// rejected before any allocation or I/O happens.
fn validate_frame_count(carrier: MediaCarrier, frame_count: u32) -> Result<(), EngineError> {
    let valid = match carrier {
        MediaCarrier::Roll36 => (1..=40).contains(&frame_count),
        MediaCarrier::Mounted => frame_count == 1,
        MediaCarrier::Strip6 => (1..=6).contains(&frame_count),
    };
    if valid {
        Ok(())
    } else {
        Err(EngineError::new(
            ErrorCode::InvalidParams,
            format!("invalid frameCount {frame_count} for carrier {carrier:?}"),
        ))
    }
}

/// Creates a new project: validates `frame_count` against `carrier`,
/// builds a fresh `ScanProject` (all frames unexcluded, no receipts yet),
/// and writes its manifest atomically. `directory_override` picks the
/// target directory verbatim (tests and any future "choose a location"
/// UI flow use this); when `None`, the project lands under
/// `default_projects_root()` in a `<slug>-<id>` subdirectory.
pub fn create_project(
    name: &str,
    carrier: MediaCarrier,
    frame_count: u32,
    film_process: FilmProcess,
    directory_override: Option<&Path>,
) -> Result<(ScanProject, PathBuf), EngineError> {
    validate_frame_count(carrier, frame_count)?;

    // One id, reused verbatim (including its "proj-" prefix) as the
    // directory-name suffix — never a second `SystemTime::now()` call.
    let id = generate_project_id();
    let directory = match directory_override {
        Some(dir) => dir.to_path_buf(),
        None => default_projects_root().join(format!("{}-{id}", slugify(name))),
    };

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let created_at = crate::sim::format_iso8601(now_secs);

    let frames = (1..=frame_count)
        .map(|index| ProjectFrame {
            index,
            excluded: false,
            capture_override: None,
            processing_override: None,
            output_override: None,
            alignment: None,
            metadata_override: None,
            receipts: vec![],
        })
        .collect();

    // Defect 8 (2026-07-25): `OutputRecipe::default()` alone is
    // project-directory-unaware — its per-recipe defaults fall back to a
    // generic `~/ScanStudio Projects/_Unfiled/<subfolder>` (see
    // `domain::fallback_unfiled_root`), and previously fell back to the OS
    // temp directory. Every brand-new project must instead default its
    // four output destinations under *this* project's own `directory`,
    // computed just above — never a shared, project-unaware location.
    let recipes = OutputRecipe {
        auto_crop: false,
        c41_render: crate::domain::C41RenderRecipe::default(),
        archive: ArchiveRecipe {
            destination: directory.join("Archive").display().to_string(),
            ..ArchiveRecipe::default()
        },
        raw_export: crate::domain::RawExportRecipe {
            destination: directory.join("Raw Negative").display().to_string(),
            ..crate::domain::RawExportRecipe::default()
        },
        positive: PositiveRecipe {
            destination: directory.join("Positive").display().to_string(),
            ..PositiveRecipe::default()
        },
        preview: PreviewRecipe {
            destination: directory.join("Preview").display().to_string(),
            ..PreviewRecipe::default()
        },
    };

    let project = ScanProject {
        schema_version: CURRENT_SCHEMA_VERSION,
        id,
        name: name.to_string(),
        carrier,
        frame_count,
        film_process,
        recipes,
        roll_metadata: MetadataSet::default(),
        created_at,
        frames,
    };

    write_manifest_atomically(&directory, &project)?;

    Ok((project, directory))
}

/// True when `path` sits under `<OS temp dir>/ScanStudio` — the exact
/// shape the pre-fix `default_archive_destination`/`default_positive_destination`/
/// `default_preview_destination` (domain.rs) used to produce
/// (`std::env::temp_dir().join("ScanStudio").join(<subfolder>)`), which
/// `create_project` shipped verbatim for every brand-new project before
/// defect 8's fix.
///
/// Deliberately narrower than "anywhere under the OS temp dir": this
/// module's own tests root their *entire* fake project directory under
/// `std::env::temp_dir()` for isolation (see `temp_project_dir`), so a
/// correctly-project-rooted destination like `<temp>/scanstudio-test-.../Archive`
/// also happens to sit under the OS temp dir without being defect 8 at
/// all. Matching only the literal `.../ScanStudio/<subfolder>` shape the
/// old shared default actually wrote avoids that false positive while
/// still catching every real occurrence of the defect (a genuine
/// production project directory is never `~/ScanStudio Projects/...`
/// nested inside the OS temp dir).
fn is_under_os_temp_dir(path: &str) -> bool {
    if path.is_empty() {
        return false;
    }
    Path::new(path).starts_with(std::env::temp_dir().join("ScanStudio"))
}

/// Load-time migration, the value-level counterpart to the key-presence
/// migration `read_manifest` already performs via `#[serde(default)]` for
/// older schema versions (see `CURRENT_SCHEMA_VERSION`'s doc comment).
/// That mechanism only fires for a *missing* key; defect 8's bad
/// destinations are present-but-wrong string values a schema-version-range
/// check can never catch, so this walks the three recipes explicitly and
/// rewrites any destination still rooted under the OS temp dir to live
/// under `directory` instead — mirroring exactly what a fixed
/// `create_project` would have written for this project in the first
/// place. Returns whether anything changed, so callers only pay for a
/// re-write when one is actually needed.
fn migrate_temp_destinations(
    project: &mut ScanProject,
    directory: &Path,
    missing_raw_export: bool,
    frame_overrides_missing_raw_export: &std::collections::HashSet<u32>,
) -> bool {
    let mut changed = false;
    if is_under_os_temp_dir(&project.recipes.archive.destination) {
        project.recipes.archive.destination = directory.join("Archive").display().to_string();
        changed = true;
    }
    if is_under_os_temp_dir(&project.recipes.positive.destination) {
        project.recipes.positive.destination = directory.join("Positive").display().to_string();
        changed = true;
    }
    if is_under_os_temp_dir(&project.recipes.preview.destination) {
        project.recipes.preview.destination = directory.join("Preview").display().to_string();
        changed = true;
    }
    if missing_raw_export {
        project.recipes.raw_export.destination = directory.join("Raw Negative").display().to_string();
        changed = true;
    }
    for frame in &mut project.frames {
        if frame_overrides_missing_raw_export.contains(&frame.index) {
            if let Some(output) = frame.output_override.as_mut() {
                output.raw_export.destination = directory.join("Raw Negative").display().to_string();
                changed = true;
            }
        }
    }
    changed
}

fn legacy_raw_export_presence(
    directory: &Path,
) -> Result<(bool, std::collections::HashSet<u32>), EngineError> {
    let path = directory.join(MANIFEST_FILE_NAME);
    let contents = fs::read_to_string(&path).map_err(|error| {
        EngineError::new(
            ErrorCode::ManifestInvalid,
            format!("failed to read manifest at {}: {error}", directory.display()),
        )
    })?;
    let value: serde_json::Value = serde_json::from_str(&contents).map_err(|error| {
        EngineError::new(
            ErrorCode::ManifestInvalid,
            format!("failed to parse manifest at {}: {error}", directory.display()),
        )
    })?;
    let missing_project_raw = value
        .get("recipes")
        .and_then(serde_json::Value::as_object)
        .is_some_and(|recipes| !recipes.contains_key("rawExport"));
    let missing_frame_raw = value
        .get("frames")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|frame| {
            let output = frame.get("outputOverride")?.as_object()?;
            (!output.contains_key("rawExport"))
                .then(|| frame.get("index")?.as_u64().and_then(|index| u32::try_from(index).ok()))
                .flatten()
        })
        .collect();
    Ok((missing_project_raw, missing_frame_raw))
}

/// Thin wrapper over `read_manifest` — the seam name that mirrors the
/// `project.open` wire method. Also applies `migrate_temp_destinations`
/// and, only when that migration actually changes something, immediately
/// persists the correction — unlike a schema-version upgrade (which rides
/// along on whatever atomic write happens next), a temp-dir destination is
/// a live data-loss risk (defect 8) that must not wait for some future
/// mutation to happen to get fixed.
pub fn open_project(directory: &Path) -> Result<ScanProject, EngineError> {
    let mut project = read_manifest(directory)?;
    let (missing_raw_export, frame_overrides_missing_raw_export) =
        legacy_raw_export_presence(directory)?;
    if migrate_temp_destinations(
        &mut project,
        directory,
        missing_raw_export,
        &frame_overrides_missing_raw_export,
    ) {
        write_manifest_atomically(directory, &project)?;
    }
    Ok(project)
}

/// Best-effort scan of `root`'s immediate subdirectories: an unreadable or
/// missing `root` yields an empty list (there being no projects yet is not
/// an anomaly), and any subdirectory whose manifest fails to read/parse/
/// validate is silently skipped rather than surfaced as an error. Results
/// are sorted newest-`createdAt`-first; plain string comparison is valid
/// because `format_iso8601`'s output is fixed-width.
pub fn list_projects(root: &Path) -> Vec<ProjectSummary> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(_) => return Vec::new(),
    };

    let mut summaries: Vec<ProjectSummary> = entries
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| {
            let directory = entry.path();
            let project = read_manifest(&directory).ok()?;
            Some(ProjectSummary {
                id: project.id,
                name: project.name,
                carrier: project.carrier,
                frame_count: project.frame_count,
                film_process: project.film_process,
                created_at: project.created_at,
                directory: directory.display().to_string(),
            })
        })
        .collect();

    summaries.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    summaries
}

// ---------------------------------------------------------------------
// Per-frame mutation (SHEET-02/SHEET-03) — the one shared helper every
// `project.setFrame*` wire method in server.rs routes through.
// ---------------------------------------------------------------------

/// Finds the frame in `project` whose `index` matches `frame_index` and
/// applies `mutate` to it in place. Returns `InvalidParams` if no frame
/// with that index exists in this project — before any mutation happens
/// (T-04-01). Never persists anything itself: mirrors `create_project`'s
/// own build-then-write separation, so callers (`server.rs`'s
/// `apply_frame_mutation`) write the manifest afterward.
pub fn mutate_frame<F>(
    project: &mut ScanProject,
    frame_index: u32,
    mutate: F,
) -> Result<(), EngineError>
where
    F: FnOnce(&mut ProjectFrame),
{
    let frame = project
        .frames
        .iter_mut()
        .find(|f| f.index == frame_index)
        .ok_or_else(|| {
            EngineError::new(
                ErrorCode::InvalidParams,
                format!("frame index {frame_index} does not exist in this project"),
            )
        })?;
    mutate(frame);
    Ok(())
}

/// Single choke point for every manifest mutation that isn't a bare receipt
/// append (`persist_frame_receipt`, below, is the other one — they share
/// `MANIFEST_LOCK`). Reads whatever is on disk right now and folds its
/// receipts into `incoming` frame by frame: any on-disk receipt `incoming`
/// doesn't already have (by value equality — a `ScanReceipt` carries no id,
/// so "the same receipt" means every field matches) is retained ahead of
/// `incoming`'s own, producing disk-first chronological order per frame.
/// Every other field — recipes, roll metadata, per-frame overrides,
/// exclusion — comes from `incoming` untouched: those are this call's
/// actual payload, and `incoming` is authoritative for them. Receipts are
/// the one field a concurrent scan-worker-thread `persist_frame_receipt`
/// call can also be changing at this exact moment, which is the entire
/// reason this function re-reads disk instead of trusting `incoming` for
/// that field too. The merged project is what actually gets written, and
/// is returned so a caller that stores it back into its own in-memory state
/// (`server.rs`'s `project_state.active`) converges toward disk truth on
/// every call instead of drifting further from it.
///
/// Held under `MANIFEST_LOCK` for the full read-merge-write extent, not
/// just the final write — see `write_manifest_atomically`'s own guard for
/// the backstop that catches a write that reaches disk some other way. A
/// missing manifest has nothing to merge against, so `incoming` is written
/// as-is (mirrors a brand new project's first save); an existing manifest
/// that fails to read is propagated rather than silently paved over with
/// `incoming`.
pub fn persist_project_update(
    directory: &Path,
    incoming: &ScanProject,
) -> Result<ScanProject, EngineError> {
    let _guard = manifest_lock();
    let merged = match read_manifest(directory) {
        Ok(on_disk) => merge_receipts(on_disk, incoming.clone()),
        Err(err) if err.code == ErrorCode::ProjectNotFound => incoming.clone(),
        Err(err) => return Err(err),
    };
    write_manifest_atomically(directory, &merged)?;
    Ok(merged)
}

/// Per frame, `on_disk`'s receipts survive ahead of `into`'s own: any of
/// `into`'s receipts not already present (by equality) are appended after,
/// so the result is their union in disk-first chronological order. Every
/// other field of `into` — recipes, roll metadata, per-frame overrides,
/// exclusion, alignment — passes through unchanged; `on_disk` contributes
/// receipts only. A frame present on disk but absent from `into` (frame
/// counts are fixed at project creation, so this should never happen in
/// practice) has nothing to merge into and is skipped here — the caller's
/// own `write_manifest_atomically` guard still catches that case and
/// refuses the write, rather than this function silently dropping it.
fn merge_receipts(on_disk: ScanProject, mut into: ScanProject) -> ScanProject {
    for on_disk_frame in on_disk.frames {
        let Some(target) = into
            .frames
            .iter_mut()
            .find(|frame| frame.index == on_disk_frame.index)
        else {
            continue;
        };
        let mut merged_receipts = on_disk_frame.receipts;
        for receipt in target.receipts.drain(..) {
            if !merged_receipts.contains(&receipt) {
                merged_receipts.push(receipt);
            }
        }
        target.receipts = merged_receipts;
    }
    into
}

/// Reads the manifest, pushes `receipt` onto `frame_index`'s `receipts`
/// list, and writes the manifest back atomically — all under
/// `MANIFEST_LOCK`, so this read-modify-write cycle can never interleave
/// with a concurrent `persist_project_update` call from the server thread
/// (or with another concurrent call to this same function). Used by the
/// scan worker thread to durably attach each completed frame's receipt to
/// the project file independent of `server.rs`'s in-memory project state.
/// Unlike `persist_project_update`, this function's caller never has an
/// in-memory `ScanProject` of its own to merge against — only a directory
/// and one new receipt — so it must read fresh, mutate, and write back
/// before releasing the lock, not just wrap the final write.
pub fn persist_frame_receipt(
    directory: &Path,
    frame_index: u32,
    receipt: &crate::domain::ScanReceipt,
) -> Result<(), EngineError> {
    let _guard = manifest_lock();
    let mut project = read_manifest(directory)?;
    mutate_frame(&mut project, frame_index, |f| {
        f.receipts.push(receipt.clone())
    })?;
    write_manifest_atomically(directory, &project)?;
    Ok(())
}

/// Pure, disk-free derivation of the resume set: every frame that is not
/// excluded and has no receipts yet, in ascending index order. A frame
/// with no receipt is pending whether it was never attempted, was skipped,
/// or failed — all three cases correctly want to be re-offered on resume.
pub fn pending_frames(project: &crate::domain::ScanProject) -> Vec<u32> {
    project
        .frames
        .iter()
        .filter(|f| !f.excluded && f.receipts.is_empty())
        .map(|f| f.index)
        .collect()
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::ScanReceipt;

    /// Isolated per-test directory under the OS temp dir — never the real
    /// `default_projects_root()`. Not created on disk by this helper;
    /// callers that need it to already exist call `fs::create_dir_all`
    /// themselves. `generate_project_id()` alone is clock-derived at
    /// microsecond granularity, which macOS advances coarsely enough that
    /// two parallel tests in this binary can draw the identical id — one
    /// test's `cleanup` then deletes the directory out from under the
    /// other mid-write (observed as a rare ENOENT flake). The process-local
    /// counter makes every call site unique regardless of clock behavior.
    fn temp_project_dir() -> PathBuf {
        static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        std::env::temp_dir().join(format!("scanstudio-test-{}-{n}", generate_project_id()))
    }

    fn cleanup(dir: &Path) {
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn create_project_roll36_accepts_a_preview_established_frame_count_and_writes_a_manifest() {
        let dir = temp_project_dir();
        let (project, returned_dir) = create_project(
            "Roll A",
            MediaCarrier::Roll36,
            36,
            FilmProcess::C41ColorNegative,
            Some(&dir),
        )
        .expect("create_project should succeed");

        assert_eq!(project.frames.len(), 36);
        assert_eq!(project.schema_version, CURRENT_SCHEMA_VERSION);
        assert_eq!(returned_dir, dir);
        assert!(dir.join(MANIFEST_FILE_NAME).is_file());

        cleanup(&dir);
    }

    #[test]
    fn create_project_strip6_honors_the_chosen_frame_count() {
        let dir = temp_project_dir();
        let (project, _dir) = create_project(
            "Strip A",
            MediaCarrier::Strip6,
            4,
            FilmProcess::Positive,
            Some(&dir),
        )
        .expect("create_project should succeed");

        assert_eq!(project.frames.len(), 4);

        cleanup(&dir);
    }

    #[test]
    fn create_project_roll36_accepts_one_through_forty_and_rejects_outside_that_range() {
        for frame_count in [1, 36, 39, 40] {
            let dir = temp_project_dir();
            let (project, _) = create_project(
                "SA-30 Roll",
                MediaCarrier::Roll36,
                frame_count,
                FilmProcess::Positive,
                Some(&dir),
            )
            .expect("a preview-established SA-30 count in range should be accepted");
            assert_eq!(project.frames.len(), frame_count as usize);
            cleanup(&dir);
        }

        for frame_count in [0, 41] {
            let dir = temp_project_dir();
            let err = create_project(
                "Bad SA-30 Roll",
                MediaCarrier::Roll36,
                frame_count,
                FilmProcess::Positive,
                Some(&dir),
            )
            .unwrap_err();
            assert_eq!(err.code, ErrorCode::InvalidParams);
            // Rejected before any I/O — nothing should have been written.
            assert!(!dir.exists());
        }
    }

    #[test]
    fn create_project_rejects_wrong_frame_count_for_mounted_and_strip6() {
        let dir_mounted = temp_project_dir();
        let err = create_project(
            "Bad Mount",
            MediaCarrier::Mounted,
            2,
            FilmProcess::Positive,
            Some(&dir_mounted),
        )
        .unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);

        let dir_strip = temp_project_dir();
        let err = create_project(
            "Bad Strip",
            MediaCarrier::Strip6,
            7,
            FilmProcess::Positive,
            Some(&dir_strip),
        )
        .unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);
    }

    /// Defect 8 (2026-07-25): a live 2-frame/361MB batch landed in the
    /// OS temporary directory
    /// because `create_project` used to build recipes via a
    /// project-directory-unaware `OutputRecipe::default()`. Every new
    /// project's four destinations must instead resolve under its own
    /// directory, never the OS temp dir and never the generic
    /// `_Unfiled` fallback either (that fallback is for construction
    /// sites with no project directory in scope at all).
    #[test]
    fn create_project_roots_recipe_destinations_under_the_project_directory() {
        let dir = temp_project_dir();
        let (project, returned_dir) = create_project(
            "Roll 2026-07-25",
            MediaCarrier::Roll36,
            36,
            FilmProcess::C41ColorNegative,
            Some(&dir),
        )
        .expect("create_project should succeed");

        assert_eq!(
            project.recipes.archive.destination,
            returned_dir.join("Archive").display().to_string()
        );
        assert_eq!(
            project.recipes.positive.destination,
            returned_dir.join("Positive").display().to_string()
        );
        assert_eq!(
            project.recipes.raw_export.destination,
            returned_dir.join("Raw Negative").display().to_string()
        );
        assert_eq!(
            project.recipes.preview.destination,
            returned_dir.join("Preview").display().to_string()
        );

        for destination in [
            &project.recipes.archive.destination,
            &project.recipes.raw_export.destination,
            &project.recipes.positive.destination,
            &project.recipes.preview.destination,
        ] {
            assert!(
                !is_under_os_temp_dir(destination),
                "newly created project destination {destination:?} must never match the stale <temp>/ScanStudio/<subfolder> shape"
            );
        }

        cleanup(&dir);
    }

    #[test]
    fn write_then_read_manifest_round_trips_a_frame_with_a_receipt_attached() {
        let dir = temp_project_dir();
        let receipt = ScanReceipt {
            exposure_authority: None,
            auto_crop: None,
            job_id: "job-1".into(),
            frame_index: 1,
            started_at: "2026-07-22T09:00:00Z".into(),
            duration_ms: 1900,
            passes: 2,
            resolution_dpi: 4000,
            bit_depth: 16,
            channels: "rgbi".into(),
            engine_version: "0.1.0".into(),
            device_id: "sim-ls5000-0".into(),
            simulated: true,
            settings_fingerprint: "1a3d265e0b54bbd2".into(),
            processing: None,
            output: None,
            outputs: None,
            rgb_path: None,
            ir_path: None,
            storage_transform: None,
            meter_rgbi_path: None,
            hardware_telemetry: None,
            nikonlook: None,
        };
        let project = ScanProject {
            schema_version: CURRENT_SCHEMA_VERSION,
            id: generate_project_id(),
            name: "Roll With Receipt".into(),
            carrier: MediaCarrier::Roll36,
            frame_count: 2,
            film_process: FilmProcess::C41ColorNegative,
            recipes: OutputRecipe::default(),
            roll_metadata: MetadataSet::default(),
            created_at: "2026-07-22T09:00:00Z".into(),
            frames: vec![
                ProjectFrame {
                    index: 1,
                    excluded: false,
                    capture_override: None,
                    processing_override: None,
                    output_override: None,
                    alignment: None,
                    metadata_override: None,
                    receipts: vec![receipt],
                },
                ProjectFrame {
                    index: 2,
                    excluded: false,
                    capture_override: None,
                    processing_override: None,
                    output_override: None,
                    alignment: None,
                    metadata_override: None,
                    receipts: vec![],
                },
            ],
        };

        write_manifest_atomically(&dir, &project).expect("write");
        let read_back = read_manifest(&dir).expect("read");

        assert_eq!(read_back, project);
        assert!(!read_back.frames[0].receipts.is_empty());

        cleanup(&dir);
    }

    #[test]
    fn read_manifest_missing_directory_is_project_not_found() {
        let dir = temp_project_dir(); // never created
        let err = read_manifest(&dir).unwrap_err();
        assert_eq!(err.code, ErrorCode::ProjectNotFound);
    }

    #[test]
    fn read_manifest_directory_without_manifest_file_is_project_not_found() {
        let dir = temp_project_dir();
        fs::create_dir_all(&dir).expect("create dir");

        let err = read_manifest(&dir).unwrap_err();
        assert_eq!(err.code, ErrorCode::ProjectNotFound);

        cleanup(&dir);
    }

    #[test]
    fn read_manifest_unsupported_schema_version_is_manifest_invalid() {
        let dir = temp_project_dir();
        fs::create_dir_all(&dir).expect("create dir");
        let bad_manifest = serde_json::json!({
            "schemaVersion": 999,
            "id": "proj-1",
            "name": "Bad",
            "carrier": "roll36",
            "frameCount": 36,
            "filmProcess": "positive",
            "createdAt": "2026-07-22T09:00:00Z",
            "frames": []
        });
        fs::write(
            dir.join(MANIFEST_FILE_NAME),
            serde_json::to_string(&bad_manifest).unwrap(),
        )
        .expect("write manifest");

        let err = read_manifest(&dir).unwrap_err();
        assert_eq!(err.code, ErrorCode::ManifestInvalid);

        cleanup(&dir);
    }

    #[test]
    fn read_manifest_rejects_a_schema_version_newer_than_current() {
        let dir = temp_project_dir();
        fs::create_dir_all(&dir).expect("create dir");
        let future_manifest = serde_json::json!({
            "schemaVersion": 5,
            "id": "proj-1",
            "name": "Future",
            "carrier": "roll36",
            "frameCount": 36,
            "filmProcess": "positive",
            "createdAt": "2026-07-22T09:00:00Z",
            "frames": []
        });
        fs::write(
            dir.join(MANIFEST_FILE_NAME),
            serde_json::to_string(&future_manifest).unwrap(),
        )
        .expect("write manifest");

        let err = read_manifest(&dir).unwrap_err();
        assert_eq!(err.code, ErrorCode::ManifestInvalid);

        cleanup(&dir);
    }

    #[test]
    fn read_manifest_migrates_a_schema_v1_manifest_with_no_recipes_key() {
        let dir = temp_project_dir();
        fs::create_dir_all(&dir).expect("create dir");
        let v1_manifest = serde_json::json!({
            "schemaVersion": 1,
            "id": "proj-1",
            "name": "Old Roll",
            "carrier": "roll36",
            "frameCount": 2,
            "filmProcess": "positive",
            "createdAt": "2026-07-22T09:00:00Z",
            "frames": [
                {"index": 1, "excluded": false, "receipts": []},
                {"index": 2, "excluded": false, "receipts": []}
            ]
        });
        fs::write(
            dir.join(MANIFEST_FILE_NAME),
            serde_json::to_string(&v1_manifest).unwrap(),
        )
        .expect("write manifest");

        let project =
            read_manifest(&dir).expect("a schema v1 manifest with no recipes key must still open");
        assert_eq!(project.recipes, OutputRecipe::default());
        assert!(project.frames[0].output_override.is_none());

        cleanup(&dir);
    }

    #[test]
    fn read_manifest_migrates_a_schema_v2_manifest_with_no_capture_or_processing_override_keys() {
        let dir = temp_project_dir();
        fs::create_dir_all(&dir).expect("create dir");
        let v2_manifest = serde_json::json!({
            "schemaVersion": 2,
            "id": "proj-1",
            "name": "Recipe Roll",
            "carrier": "roll36",
            "frameCount": 2,
            "filmProcess": "positive",
            "recipes": {},
            "createdAt": "2026-07-22T09:00:00Z",
            "frames": [
                {"index": 1, "excluded": false, "receipts": []},
                {"index": 2, "excluded": false, "receipts": []}
            ]
        });
        fs::write(
            dir.join(MANIFEST_FILE_NAME),
            serde_json::to_string(&v2_manifest).unwrap(),
        )
        .expect("write manifest");

        let project = read_manifest(&dir).expect(
            "a schema v2 manifest with no captureOverride/processingOverride keys must still open",
        );
        assert!(project.frames[0].capture_override.is_none());
        assert!(project.frames[0].processing_override.is_none());
        assert!(project.frames[0].output_override.is_none());

        cleanup(&dir);
    }

    #[test]
    fn read_manifest_migrates_a_schema_v3_manifest_with_no_metadata_keys() {
        let dir = temp_project_dir();
        fs::create_dir_all(&dir).expect("create dir");
        let v3_manifest = serde_json::json!({
            "schemaVersion": 3,
            "id": "proj-1",
            "name": "Metadata Roll",
            "carrier": "roll36",
            "frameCount": 2,
            "filmProcess": "positive",
            "recipes": {},
            "createdAt": "2026-07-22T09:00:00Z",
            "frames": [
                {"index": 1, "excluded": false, "receipts": []},
                {"index": 2, "excluded": false, "receipts": []}
            ]
        });
        fs::write(
            dir.join(MANIFEST_FILE_NAME),
            serde_json::to_string(&v3_manifest).unwrap(),
        )
        .expect("write manifest");

        let project = read_manifest(&dir).expect(
            "a schema v3 manifest with no rollMetadata/metadataOverride keys must still open",
        );
        assert_eq!(project.roll_metadata, MetadataSet::default());
        assert!(project.frames[0].metadata_override.is_none());

        cleanup(&dir);
    }

    #[test]
    fn read_manifest_invalid_json_is_manifest_invalid() {
        let dir = temp_project_dir();
        fs::create_dir_all(&dir).expect("create dir");
        fs::write(dir.join(MANIFEST_FILE_NAME), "not valid json{{{").expect("write manifest");

        let err = read_manifest(&dir).unwrap_err();
        assert_eq!(err.code, ErrorCode::ManifestInvalid);

        cleanup(&dir);
    }

    #[test]
    fn list_projects_skips_corrupt_entries_and_sorts_newest_first() {
        let root = temp_project_dir();
        fs::create_dir_all(&root).expect("create root");

        let older_dir = root.join("older");
        let newer_dir = root.join("newer");
        let corrupt_dir = root.join("corrupt");

        let older = ScanProject {
            schema_version: CURRENT_SCHEMA_VERSION,
            id: "proj-older".into(),
            name: "Older".into(),
            carrier: MediaCarrier::Roll36,
            frame_count: 36,
            film_process: FilmProcess::Positive,
            recipes: OutputRecipe::default(),
            roll_metadata: MetadataSet::default(),
            created_at: "2026-01-01T00:00:00Z".into(),
            frames: vec![],
        };
        write_manifest_atomically(&older_dir, &older).expect("write older");

        let newer = ScanProject {
            schema_version: CURRENT_SCHEMA_VERSION,
            id: "proj-newer".into(),
            name: "Newer".into(),
            carrier: MediaCarrier::Strip6,
            frame_count: 3,
            film_process: FilmProcess::BwNegative,
            recipes: OutputRecipe::default(),
            roll_metadata: MetadataSet::default(),
            created_at: "2026-06-01T00:00:00Z".into(),
            frames: vec![],
        };
        write_manifest_atomically(&newer_dir, &newer).expect("write newer");

        fs::create_dir_all(&corrupt_dir).expect("create corrupt dir");
        fs::write(corrupt_dir.join(MANIFEST_FILE_NAME), "not json").expect("write corrupt");

        let summaries = list_projects(&root);

        assert_eq!(summaries.len(), 2);
        assert_eq!(summaries[0].id, "proj-newer");
        assert_eq!(summaries[1].id, "proj-older");

        cleanup(&root);
    }

    #[test]
    fn list_projects_on_a_missing_root_returns_an_empty_list_not_an_error() {
        let root = temp_project_dir(); // never created
        assert!(list_projects(&root).is_empty());
    }

    #[test]
    fn open_project_reads_back_what_create_project_just_wrote() {
        let dir = temp_project_dir();
        let (created, _dir) = create_project(
            "Roundtrip",
            MediaCarrier::Mounted,
            1,
            FilmProcess::Kodachrome,
            Some(&dir),
        )
        .expect("create");

        let opened = open_project(&dir).expect("open");
        assert_eq!(opened, created);

        cleanup(&dir);
    }

    /// Defect 8 (2026-07-25) load-time migration: a manifest already
    /// carrying OS-temp-dir destinations (written by a pre-fix engine
    /// build — these are present, valid-shaped string values, never a
    /// missing key `#[serde(default)]` could catch) must be corrected the
    /// moment it's opened, and the correction must be durably persisted
    /// immediately rather than waiting for some future mutation's atomic
    /// write — this is a live data-loss risk, not a cosmetic schema
    /// upgrade.
    #[test]
    fn open_project_migrates_temp_dir_destinations_and_persists_the_fix() {
        let dir = temp_project_dir();
        fs::create_dir_all(&dir).expect("create dir");
        let stale_temp_root = std::env::temp_dir().join("ScanStudio");
        let manifest_with_temp_destinations = serde_json::json!({
            "schemaVersion": 4,
            "id": "proj-18c593634748cb20",
            "name": "Roll 2026-07-25",
            "carrier": "roll36",
            "frameCount": 2,
            "filmProcess": "c41ColorNegative",
            "recipes": {
                "archive": {
                    "filenameTemplate": "Archive_####",
                    "destination": stale_temp_root.join("Archive").display().to_string(),
                },
                "positive": {
                    "enabled": true,
                    "fileFormat": "tiff",
                    "colorProfile": "adobeRgb1998",
                    "filenameTemplate": "Positive_####",
                    "destination": stale_temp_root.join("Positive").display().to_string(),
                },
                "preview": {
                    "enabled": true,
                    "fileFormat": "jpeg",
                    "maxLongEdgePx": 2048,
                    "filenameTemplate": "Preview_####",
                    "destination": stale_temp_root.join("Preview").display().to_string(),
                },
            },
            "createdAt": "2026-07-25T15:54:41Z",
            "frames": [
                {"index": 1, "excluded": false, "receipts": []},
                {"index": 2, "excluded": false, "receipts": []}
            ]
        });
        fs::write(
            dir.join(MANIFEST_FILE_NAME),
            serde_json::to_string(&manifest_with_temp_destinations).unwrap(),
        )
        .expect("write manifest");

        let opened =
            open_project(&dir).expect("a manifest with temp-dir destinations must still open");

        assert_eq!(
            opened.recipes.archive.destination,
            dir.join("Archive").display().to_string()
        );
        assert_eq!(
            opened.recipes.positive.destination,
            dir.join("Positive").display().to_string()
        );
        assert_eq!(
            opened.recipes.raw_export.destination,
            dir.join("Raw Negative").display().to_string(),
            "a legacy manifest's new disabled recipe must still get a project-local future destination"
        );
        assert_eq!(
            opened.recipes.preview.destination,
            dir.join("Preview").display().to_string()
        );

        // The fix must be durable: re-reading the manifest straight off
        // disk (bypassing `open_project`'s own migration) must already
        // show the corrected destinations, proving the migration
        // persisted rather than only patching the in-memory value.
        let reread = read_manifest(&dir).expect("re-read migrated manifest");
        assert_eq!(
            reread.recipes.archive.destination,
            opened.recipes.archive.destination
        );
        assert_eq!(
            reread.recipes.raw_export.destination,
            opened.recipes.raw_export.destination
        );
        assert!(
            !is_under_os_temp_dir(&reread.recipes.archive.destination),
            "the persisted destination must no longer match the stale <temp>/ScanStudio/Archive shape"
        );

        cleanup(&dir);
    }

    /// A manifest whose destinations are already correct must never be
    /// rewritten on open — `migrate_temp_destinations` only pays the
    /// atomic-write cost when it actually changed something.
    #[test]
    fn open_project_does_not_rewrite_a_manifest_with_no_temp_dir_destinations() {
        let dir = temp_project_dir();
        let (_created, _dir) = create_project(
            "Already Fine",
            MediaCarrier::Mounted,
            1,
            FilmProcess::Positive,
            Some(&dir),
        )
        .expect("create");

        let manifest_path = dir.join(MANIFEST_FILE_NAME);
        let mtime_before = fs::metadata(&manifest_path).unwrap().modified().unwrap();

        // Give the filesystem's mtime resolution room to actually show a
        // difference if a spurious rewrite happens.
        std::thread::sleep(std::time::Duration::from_millis(20));
        let _ = open_project(&dir).expect("open");

        let mtime_after = fs::metadata(&manifest_path).unwrap().modified().unwrap();
        assert_eq!(
            mtime_before, mtime_after,
            "opening an already-correct project must not rewrite its manifest"
        );

        cleanup(&dir);
    }

    #[test]
    fn slugify_lowercases_and_collapses_punctuation_to_single_hyphens() {
        assert_eq!(slugify("Test Roll #1!"), "test-roll-1");
    }

    #[test]
    fn slugify_falls_back_to_project_for_empty_or_punctuation_only_input() {
        assert_eq!(slugify(""), "project");
        assert_eq!(slugify("###"), "project");
    }

    /// Builds an `n`-frame project with every frame unexcluded and no
    /// overrides, purely in memory (never written to disk) — `mutate_frame`
    /// itself never touches the filesystem, so its tests don't need to
    /// either.
    fn n_frame_project_for_mutate_frame_tests(n: u32) -> ScanProject {
        ScanProject {
            schema_version: CURRENT_SCHEMA_VERSION,
            id: generate_project_id(),
            name: "Mutate Frame Test".into(),
            carrier: MediaCarrier::Strip6,
            frame_count: n,
            film_process: FilmProcess::Positive,
            recipes: OutputRecipe::default(),
            roll_metadata: MetadataSet::default(),
            created_at: "2026-07-23T00:00:00Z".into(),
            frames: (1..=n)
                .map(|index| ProjectFrame {
                    index,
                    excluded: false,
                    capture_override: None,
                    processing_override: None,
                    output_override: None,
                    alignment: None,
                    metadata_override: None,
                    receipts: vec![],
                })
                .collect(),
        }
    }

    #[test]
    fn mutate_frame_rejects_an_out_of_range_frame_index() {
        let mut project = n_frame_project_for_mutate_frame_tests(2);

        let err = mutate_frame(&mut project, 99, |frame| frame.excluded = true).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);
        // Rejected before any mutation — neither frame should have changed.
        assert!(!project.frames[0].excluded);
        assert!(!project.frames[1].excluded);
    }

    #[test]
    fn mutate_frame_applies_the_closure_to_the_matching_frame_only() {
        let mut project = n_frame_project_for_mutate_frame_tests(3);

        mutate_frame(&mut project, 2, |frame| frame.excluded = true)
            .expect("frame index 2 exists in this 3-frame project");

        assert!(!project.frames[0].excluded, "frame 1 must be untouched");
        assert!(project.frames[1].excluded, "frame 2 must be mutated");
        assert!(!project.frames[2].excluded, "frame 3 must be untouched");
    }

    fn sample_receipt(job_id: &str, frame_index: u32) -> ScanReceipt {
        ScanReceipt {
            exposure_authority: None,
            auto_crop: None,
            job_id: job_id.into(),
            frame_index,
            started_at: "2026-07-22T09:00:00Z".into(),
            duration_ms: 1000,
            passes: 1,
            resolution_dpi: 4000,
            bit_depth: 16,
            channels: "rgbi".into(),
            engine_version: "0.1.0".into(),
            device_id: "sim-ls5000-0".into(),
            simulated: true,
            settings_fingerprint: "1a3d265e0b54bbd2".into(),
            processing: None,
            output: None,
            outputs: None,
            rgb_path: None,
            ir_path: None,
            storage_transform: None,
            meter_rgbi_path: None,
            hardware_telemetry: None,
            nikonlook: None,
        }
    }

    #[test]
    fn persist_frame_receipt_round_trips_through_read_manifest() {
        let dir = temp_project_dir();
        let (project, _dir) = create_project(
            "Receipt Persistence",
            MediaCarrier::Strip6,
            2,
            FilmProcess::Positive,
            Some(&dir),
        )
        .expect("create_project should succeed");

        let receipt = sample_receipt(&project.id, 1);
        persist_frame_receipt(&dir, 1, &receipt).expect("persist frame 1 receipt");

        let read_back = read_manifest(&dir).expect("read back manifest");
        assert_eq!(read_back.frames[0].receipts.len(), 1);
        assert_eq!(read_back.frames[0].receipts[0], receipt);
        assert!(read_back.frames[1].receipts.is_empty());

        cleanup(&dir);
    }

    #[test]
    fn persist_frame_receipt_round_trips_nikonlook_provenance_through_disk() {
        // Backend-level proof that a written receipt actually carries the
        // nikonlook field: `sample_receipt` (used by most tests in this
        // module) always sets `nikonlook: None`, so nothing else exercises
        // this field through the real write-to-JSON-then-read-back path
        // both the sim and real backends funnel through via
        // `persist_frame_receipt`.
        let dir = temp_project_dir();
        let (project, _dir) = create_project(
            "Nikonlook Receipt Persistence",
            MediaCarrier::Strip6,
            2,
            FilmProcess::C41ColorNegative,
            Some(&dir),
        )
        .expect("create_project should succeed");

        let receipt = ScanReceipt {
            nikonlook: Some(crate::domain::NikonlookProvenance {
                bundle_version: "nikonlook-v2".to_string(),
                layer_a_path: crate::domain::NikonlookLayerAPath::HardwareExposure,
                gains: [0.5764822683598294, 0.22818411954519974, 0.2620541212542383],
            }),
            ..sample_receipt(&project.id, 1)
        };
        persist_frame_receipt(&dir, 1, &receipt).expect("persist frame 1 receipt");

        let read_back = read_manifest(&dir).expect("read back manifest");
        assert_eq!(read_back.frames[0].receipts.len(), 1);
        assert_eq!(
            read_back.frames[0].receipts[0].nikonlook, receipt.nikonlook,
            "nikonlook provenance must survive a real write-to-disk/read-back round trip"
        );
        assert_eq!(read_back.frames[0].receipts[0], receipt);

        cleanup(&dir);
    }

    #[test]
    fn persist_frame_receipt_returns_error_for_missing_frame_index() {
        let dir = temp_project_dir();
        create_project(
            "Receipt Persistence Bad Index",
            MediaCarrier::Strip6,
            2,
            FilmProcess::Positive,
            Some(&dir),
        )
        .expect("create_project should succeed");

        let receipt = sample_receipt("job-bad", 99);
        let err = persist_frame_receipt(&dir, 99, &receipt).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);

        cleanup(&dir);
    }

    /// PERSIST-02 core fix: a caller's stale in-memory `incoming` (no
    /// receipts, exactly like `project_state.active` right after
    /// `project.create`) must never blow away a receipt `persist_frame_
    /// receipt` already attached straight to disk. Before this function
    /// existed, `server.rs` wrote `project_state.active` over the manifest
    /// directly and destroyed it every time.
    #[test]
    fn persist_project_update_retains_a_disk_receipt_incoming_does_not_know_about() {
        let dir = temp_project_dir();
        let (project, _dir) = create_project(
            "Merge Retains Disk Receipt",
            MediaCarrier::Strip6,
            2,
            FilmProcess::Positive,
            Some(&dir),
        )
        .expect("create_project should succeed");

        let receipt = sample_receipt("job-1", 1);
        persist_frame_receipt(&dir, 1, &receipt).expect("persist frame 1 receipt");

        // `incoming` reflects a project_state.active that has never heard
        // about that receipt — only a recipe edit unrelated to frame 1.
        let mut incoming = project.clone();
        incoming.recipes.archive.filename_template = "Renamed_####".into();

        let merged = persist_project_update(&dir, &incoming).expect("persist_project_update");
        assert_eq!(merged.frames[0].receipts, vec![receipt.clone()]);
        assert_eq!(merged.recipes.archive.filename_template, "Renamed_####");

        let on_disk = read_manifest(&dir).expect("read back manifest");
        assert_eq!(
            on_disk.frames[0].receipts,
            vec![receipt],
            "the merged write must durably retain the disk-only receipt"
        );
        assert_eq!(on_disk.recipes.archive.filename_template, "Renamed_####");

        cleanup(&dir);
    }

    /// Every field besides receipts is `incoming`'s to decide — merging
    /// must never resurrect a stale roll_metadata or recipe from disk over
    /// a caller's deliberate edit.
    #[test]
    fn persist_project_update_prefers_incoming_for_every_non_receipt_field() {
        let dir = temp_project_dir();
        let (project, _dir) = create_project(
            "Merge Prefers Incoming",
            MediaCarrier::Strip6,
            1,
            FilmProcess::Positive,
            Some(&dir),
        )
        .expect("create_project should succeed");

        let mut incoming = project;
        incoming.roll_metadata.camera = Some("Nikon F3".into());

        let merged = persist_project_update(&dir, &incoming).expect("persist_project_update");
        assert_eq!(merged.roll_metadata.camera, Some("Nikon F3".into()));

        cleanup(&dir);
    }

    /// A missing manifest has nothing to merge against — `persist_project_
    /// update` must still succeed and simply write `incoming` as-is (the
    /// same shape a brand new project's first save already produces).
    #[test]
    fn persist_project_update_writes_incoming_as_is_when_no_manifest_exists_yet() {
        let dir = temp_project_dir(); // never created
        let project = n_frame_project_for_mutate_frame_tests(2);

        let merged = persist_project_update(&dir, &project).expect("persist_project_update");
        assert_eq!(merged, project);
        assert_eq!(read_manifest(&dir).expect("read back manifest"), project);

        cleanup(&dir);
    }

    /// The structural backstop: `write_manifest_atomically` must refuse —
    /// not silently accept — any write whose incoming frame receipts are
    /// not a superset of what is already durably on disk. This is what
    /// `persist_project_update`/`persist_frame_receipt` are relied on to
    /// never trip; this test proves the backstop itself actually holds.
    #[test]
    fn write_manifest_atomically_refuses_a_write_that_would_drop_an_on_disk_receipt() {
        let dir = temp_project_dir();
        let (project, _dir) = create_project(
            "Guard Refuses Receipt Loss",
            MediaCarrier::Strip6,
            2,
            FilmProcess::Positive,
            Some(&dir),
        )
        .expect("create_project should succeed");

        let receipt = sample_receipt("job-1", 1);
        persist_frame_receipt(&dir, 1, &receipt).expect("persist frame 1 receipt");

        // A stale copy of the project, taken before the receipt existed —
        // exactly the shape of the pre-fix defect's stale project_state.active.
        let stale = project;
        let err = write_manifest_atomically(&dir, &stale).unwrap_err();
        assert_eq!(err.code, ErrorCode::ManifestInvalid);
        assert!(err.message.contains("frame 1"));

        // The refusal must be enforced before any write — the receipt is
        // still exactly there, not clobbered by a half-applied attempt.
        let on_disk = read_manifest(&dir).expect("read back manifest");
        assert_eq!(on_disk.frames[0].receipts, vec![receipt]);

        cleanup(&dir);
    }

    /// A manifest that exists but cannot be parsed must refuse the write
    /// rather than pave over the corruption with whatever the caller
    /// happened to be holding.
    #[test]
    fn write_manifest_atomically_refuses_when_the_existing_manifest_is_corrupt() {
        let dir = temp_project_dir();
        fs::create_dir_all(&dir).expect("create dir");
        fs::write(dir.join(MANIFEST_FILE_NAME), "not valid json{{{")
            .expect("write corrupt manifest");

        let project = n_frame_project_for_mutate_frame_tests(1);
        let err = write_manifest_atomically(&dir, &project).unwrap_err();
        assert_eq!(err.code, ErrorCode::ManifestInvalid);
        assert!(err.message.contains("manual recovery"));

        cleanup(&dir);
    }

    /// No manifest at all (a brand new project directory) has nothing to
    /// compare against, so the guard must allow the write through exactly
    /// as it always has.
    #[test]
    fn write_manifest_atomically_allows_the_first_write_to_a_fresh_directory() {
        let dir = temp_project_dir(); // never created
        let project = n_frame_project_for_mutate_frame_tests(1);
        write_manifest_atomically(&dir, &project).expect("first write to a fresh directory");
        assert_eq!(read_manifest(&dir).expect("read back manifest"), project);
        cleanup(&dir);
    }

    #[test]
    fn pending_frames_returns_only_non_excluded_receiptless_frames() {
        let mut project = n_frame_project_for_mutate_frame_tests(3);
        project.frames[0].receipts.push(sample_receipt("job-1", 1));
        project.frames[1].excluded = true;

        assert_eq!(pending_frames(&project), vec![3]);
    }

    #[test]
    fn pending_frames_returns_every_frame_for_all_fresh_project() {
        let project = n_frame_project_for_mutate_frame_tests(3);
        assert_eq!(pending_frames(&project), vec![1, 2, 3]);
    }

    #[test]
    fn pending_frames_returns_empty_for_fully_completed_project() {
        let mut project = n_frame_project_for_mutate_frame_tests(3);
        for frame in &mut project.frames {
            frame.receipts.push(sample_receipt("job-1", frame.index));
        }
        assert!(pending_frames(&project).is_empty());
    }

    #[test]
    fn default_projects_root_uses_userprofile_when_home_is_absent() {
        let original_home = std::env::var("HOME").ok();
        let original_userprofile = std::env::var("USERPROFILE").ok();

        std::env::remove_var("HOME");
        let test_home = "/tmp/scanstudio-userprofile-test";
        std::env::set_var("USERPROFILE", test_home);

        let root = default_projects_root();

        match original_home {
            Some(value) => std::env::set_var("HOME", value),
            None => std::env::remove_var("HOME"),
        }
        match original_userprofile {
            Some(value) => std::env::set_var("USERPROFILE", value),
            None => std::env::remove_var("USERPROFILE"),
        }

        assert!(
            root.starts_with(test_home),
            "default_projects_root must resolve from USERPROFILE when HOME is absent, got {root:?}"
        );
    }
}
