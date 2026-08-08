//! Domain vocabulary for the Scan Studio engine.
//!
//! Every wire-facing type here mirrors `protocol/PROTOCOL.md`'s "Types"
//! section byte-for-byte (camelCase on the wire, snake_case in Rust). Types
//! not yet consumed by the M1 server (MetadataSet, PartialDate)
//! are still part of the vocabulary later phases build on and are
//! round-trip tested below per D-06. `ScanProject` and friends are the
//! Phase 2 manifest schema; persistence lives in `manifest.rs`.

use serde::{Deserialize, Serialize};

use crate::protocol::{ConnectOptions, ConnectResult, ErrorCode, ScannerStatus, StopMode};

// ---------------------------------------------------------------------
// Device
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub device_id: String,
    pub model: String,
    pub kind: String,
    pub firmware: String,
    pub connection: String,
    /// False for a recognized-but-unsupported Nikon model (Lane D): it is
    /// listed by name in ``scanner.list`` but is never connectable.
    pub supported: bool,
}

// ---------------------------------------------------------------------
// ScannerBackend: the seam a real-hardware backend would implement later.
// Not built in M1 (D-20 forbids any USB/SCSI/hardware I/O) — SimulatedLs5000
// (src/sim.rs) is the only implementation that exists today.
// ---------------------------------------------------------------------

/// Synchronous connect/disconnect/status/load-media/eject, plus a way for
/// the long-running, worker-thread-driven operations (thumbnail acquisition
/// and scan jobs) to report progress asynchronously via a sender of
/// pre-serialized NDJSON event lines.
///
/// The three worker-thread operations are associated functions taking
/// `backend: &Arc<Self>` (rather than `&self`) specifically so an
/// implementation can clone the `Arc` into a spawned thread without relying
/// on `self: Arc<Self>` receiver syntax.
pub trait ScannerBackend: Send + Sync + Sized {
    fn connect(
        &self,
        device_id: &str,
        options: &ConnectOptions,
    ) -> Result<ConnectResult, EngineError>;

    fn disconnect(&self) -> Result<crate::protocol::ScannerStatus, EngineError>;

    fn status(&self) -> Result<ScannerStatus, EngineError>;

    fn load_media(&self, carrier: MediaCarrier) -> Result<ScannerStatus, EngineError>;

    fn eject(&self) -> Result<ScannerStatus, EngineError>;

    /// Kicks off thumbnail acquisition on a worker thread. `event_tx`
    /// receives fully-serialized NDJSON event lines (`scanner.thumbnail` per
    /// frame, then `scanner.thumbnailsComplete`). Returns the accepted frame
    /// list synchronously, mirroring `AcquireThumbnailsAck.frames`.
    ///
    /// `film_process` threads the active project's film process through so
    /// a real backend can pick the correct BRIDGE.md `material` value
    /// (`roll.preview`'s `"colorNegative"`/`"blackAndWhiteNegative"`); the
    /// simulator ignores it.
    fn acquire_thumbnails(
        backend: &std::sync::Arc<Self>,
        frames: Option<Vec<u32>>,
        film_process: FilmProcess,
        operation_id: Option<String>,
        event_tx: std::sync::mpsc::Sender<String>,
    ) -> Result<Vec<u32>, EngineError>;

    /// Kicks off a scan job on a worker thread. `event_tx` receives every
    /// `scan.*` event for the job's lifetime. Returns the new job id
    /// synchronously, mirroring `ScanStartResult.jobId`.
    ///
    /// `overrides` is resolved by the caller (`server.rs`'s `scan.start`
    /// handler) from the active project's manifest before the job starts.
    /// A frame absent from the map (or a `None` field within an entry)
    /// uses this call's roll-wide `recipe`/`processing`/`output` for that
    /// one dimension instead.
    ///
    /// `project_directory`, when present, is the active project's manifest
    /// directory at the moment this job started, captured once and threaded
    /// straight into the worker thread — used to persist each completed
    /// frame's receipt independently of `server.rs`'s in-memory project state
    /// (see `manifest::persist_frame_receipt`).
    fn scan_start(
        backend: &std::sync::Arc<Self>,
        frames: Vec<u32>,
        recipe: CaptureRecipe,
        processing: ProcessingRecipe,
        output: OutputRecipe,
        overrides: std::collections::HashMap<u32, FrameOverrides>,
        project_directory: Option<std::path::PathBuf>,
        event_tx: std::sync::mpsc::Sender<String>,
    ) -> Result<String, EngineError>;

    fn scan_stop(
        &self,
        job_id: &str,
        mode: StopMode,
        event_tx: std::sync::mpsc::Sender<String>,
    ) -> Result<(bool, StopMode), EngineError>;

    /// Cancels background simulator work. This is deliberately best-effort:
    /// shutdown must never wait for a worker holding an output sender.
    fn shutdown(&self);
}

// ---------------------------------------------------------------------
// Media / process vocabulary — separate types by construction, never
// conflated.
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum MediaCarrier {
    Roll36,
    Strip6,
    Mounted,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum FilmProcess {
    Positive,
    #[default]
    C41ColorNegative,
    BwNegative,
    Kodachrome,
}

// ---------------------------------------------------------------------
// Capture recipe
// ---------------------------------------------------------------------

fn default_resolution_dpi() -> u32 {
    4000
}

fn default_bit_depth() -> u32 {
    16
}

fn default_multisample_passes() -> u32 {
    1
}

fn default_channels() -> Channels {
    Channels::Rgbi
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Channels {
    Rgb,
    Rgbi,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CaptureRecipe {
    #[serde(default = "default_resolution_dpi")]
    pub resolution_dpi: u32,
    #[serde(default = "default_bit_depth")]
    pub bit_depth: u32,
    #[serde(default = "default_multisample_passes")]
    pub multisample_passes: u32,
    #[serde(default = "default_channels")]
    pub channels: Channels,
}

impl Default for CaptureRecipe {
    fn default() -> Self {
        CaptureRecipe {
            resolution_dpi: default_resolution_dpi(),
            bit_depth: default_bit_depth(),
            multisample_passes: default_multisample_passes(),
            channels: default_channels(),
        }
    }
}

impl CaptureRecipe {
    /// B&W's effective processing has no infrared correction; avoid reading
    /// an IR channel that cannot be used or honestly reported.
    pub fn effective_for_process(&self, process: FilmProcess) -> Self {
        let mut effective = self.clone();
        if process == FilmProcess::BwNegative {
            effective.channels = Channels::Rgb;
        }
        effective
    }
}

// ---------------------------------------------------------------------
// Processing and output vocabulary. These recipes are recorded with every
// completed simulated frame; later phases will use them to render and write files.
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum DigitalIceMode {
    #[default]
    Legacy,
    Hybrid,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProcessingRecipe {
    #[serde(default)]
    pub film_process: FilmProcess,
    #[serde(default = "default_true")]
    pub autofocus_each_frame: bool,
    #[serde(default = "default_true")]
    pub auto_exposure_each_frame: bool,
    #[serde(default = "default_true")]
    pub digital_ice_enabled: bool,
    #[serde(default)]
    pub digital_ice_mode: DigitalIceMode,
    /// Opt-in RGB-only, classical-CV cleanup for traditional B&W negatives.
    /// It is deliberately separate from infrared Digital ICE.
    #[serde(default)]
    pub software_dust_removal_bw: bool,
}

impl Default for ProcessingRecipe {
    fn default() -> Self {
        Self {
            film_process: FilmProcess::default(),
            autofocus_each_frame: true,
            auto_exposure_each_frame: true,
            digital_ice_enabled: true,
            digital_ice_mode: DigitalIceMode::default(),
            software_dust_removal_bw: false,
        }
    }
}

impl ProcessingRecipe {
    /// Traditional silver B&W film blocks infrared, so an enabled Digital
    /// ICE flag can never describe an honest result for this process.
    pub fn effective(&self) -> Self {
        let mut effective = self.clone();
        if effective.film_process == FilmProcess::BwNegative {
            effective.digital_ice_enabled = false;
        } else {
            effective.software_dust_removal_bw = false;
        }
        effective
    }
}

fn default_true() -> bool {
    true
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum OutputFileFormat {
    #[default]
    Tiff,
    Jpeg,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum OutputColorProfile {
    #[default]
    AdobeRgb1998,
    SRgb,
    ProPhotoRgb,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum RawExportFormat {
    #[default]
    LinearDng,
    LinearTiff,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum RawTiffInfrared {
    #[default]
    FourthChannel,
    Omitted,
    Sidecar,
}

/// The C-41 renderer used for regenerable positive and preview derivatives.
/// The archive always retains the untouched scanner RGB master.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum C41RenderTarget {
    #[default]
    Nikonlook,
    /// Local-only Nikon Scan CML4 replay. It requires a user-selected
    /// Cool Colors checkout and the three builder LUTs produced for this
    /// exact acquisition; no LUT or profile bytes are embedded here.
    NikonOemReplay,
    NoritsuLs600,
    FlexcolorCleanroom,
}

/// Operator-owned inputs for the experimental Nikon Scan replay. The
/// checkout is deliberately external: ScanStudio does not redistribute its
/// captured CML assets, and all three LUTs are tied to one raw scan.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct CoolColorsInputs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkout_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub builder_red_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub builder_green_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub builder_blue_path: Option<String>,
}

/// Optional paths to user-owned FlexColor calibration inputs.  These are
/// deliberately paths, never embedded profile/LUT/ICC bytes.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct FlexcolorInputs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_setting_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lut_table_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_icc_path: Option<String>,
}

/// Selects the C-41 derivative renderer and, for the clean-room FlexColor
/// path, identifies the operator-owned inputs it may read.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct C41RenderRecipe {
    #[serde(default)]
    pub target: C41RenderTarget,
    #[serde(default)]
    pub flexcolor: FlexcolorInputs,
    #[serde(default)]
    pub cool_colors: CoolColorsInputs,
}

impl Default for C41RenderRecipe {
    fn default() -> Self {
        Self {
            target: C41RenderTarget::Nikonlook,
            flexcolor: FlexcolorInputs::default(),
            cool_colors: CoolColorsInputs::default(),
        }
    }
}

fn default_archive_filename_template() -> String {
    "ScanStudio#".to_string()
}

/// `$HOME/ScanStudio Projects/_Unfiled` — mirrors both
/// `manifest::default_projects_root()` (identical `$HOME` lookup, same
/// current-dir-then-`.` fallback when `HOME` is unset) and Swift's
/// `SessionModel.defaultOutputDestination`, which independently uses the
/// same `~/ScanStudio Projects/_Unfiled/<subfolder>` shape for its own "no
/// project open yet" fallback. Duplicated here rather than depending on
/// `crate::manifest`: `domain.rs` is the lower layer (manifest.rs depends
/// on domain's types, never the reverse).
///
/// This is only ever a *generic, project-directory-unaware* fallback: the
/// `#[serde(default = ...)]` path for a manifest missing this key entirely
/// (old schema versions predating recipes — see manifest.rs's migration
/// tests) and the output sub-recipes' `Default` implementations for any
/// construction site with no project directory in scope
/// (e.g. `OutputRecipe::default()` in tests). `manifest::create_project`
/// never actually ships this value for a real project — it overwrites all
/// four destinations with paths rooted under the new project's own
/// directory immediately after constructing them.
///
/// Defect 8 (2026-07-25): this function and its two siblings previously
/// returned `std::env::temp_dir().join("ScanStudio").join(<subfolder>)` —
/// a real, shared, OS-purged scratch directory. Because `create_project`
/// built every new project's recipes via `OutputRecipe::default()`
/// (manifest.rs), every brand-new project silently defaulted its three
/// output destinations there; a live 2-frame/361MB batch landed in the
/// system temporary directory before this fix.
fn fallback_unfiled_root() -> std::path::PathBuf {
    let base = match std::env::var("HOME") {
        Ok(home) => std::path::PathBuf::from(home),
        Err(_) => std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from(".")),
    };
    base.join("ScanStudio Projects").join("_Unfiled")
}

fn default_archive_destination() -> String {
    fallback_unfiled_root()
        .join("Archive")
        .display()
        .to_string()
}

fn default_raw_export_filename_template() -> String {
    "ScanStudio#".to_string()
}

fn default_raw_export_destination() -> String {
    fallback_unfiled_root()
        .join("Raw Negative")
        .display()
        .to_string()
}

/// Optional untouched-negative output. It is disabled by default for wire
/// and manifest compatibility. `Sidecar` writes available IR to a paired
/// grayscale TIFF for either format; legacy DNG values retain embedded IR.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RawExportRecipe {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub file_format: RawExportFormat,
    #[serde(default)]
    pub tiff_infrared: RawTiffInfrared,
    #[serde(default = "default_raw_export_filename_template")]
    pub filename_template: String,
    #[serde(default = "default_raw_export_destination")]
    pub destination: String,
}

impl Default for RawExportRecipe {
    fn default() -> Self {
        Self {
            enabled: false,
            file_format: RawExportFormat::default(),
            tiff_infrared: RawTiffInfrared::default(),
            filename_template: default_raw_export_filename_template(),
            destination: default_raw_export_destination(),
        }
    }
}

/// An optional, never-touched capture master ("archive-grade capture
/// preservation with regenerable derivatives"). When retained it has no
/// `file_format`/`color_profile` field — it is always full-fidelity,
/// uncompressed, at the capture's own bit depth, enforced by these fields
/// not existing on this type at all, not by a runtime check. `enabled`
/// defaults to true so older manifests and clients preserve their historic
/// master-retention behavior.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ArchiveRecipe {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_archive_filename_template")]
    pub filename_template: String,
    #[serde(default = "default_archive_destination")]
    pub destination: String,
    #[serde(default = "default_true")]
    pub full_capture_package: bool,
}

impl Default for ArchiveRecipe {
    fn default() -> Self {
        Self {
            enabled: true,
            filename_template: default_archive_filename_template(),
            destination: default_archive_destination(),
            full_capture_package: true,
        }
    }
}

fn default_positive_filename_template() -> String {
    "ScanStudio#".to_string()
}

fn default_positive_destination() -> String {
    fallback_unfiled_root()
        .join("Positive")
        .display()
        .to_string()
}

/// A regenerable derivative: format/profile choices here never touch
/// `ArchiveRecipe` — different Rust types, not just different UI labels.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PositiveRecipe {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub file_format: OutputFileFormat,
    #[serde(default)]
    pub color_profile: OutputColorProfile,
    #[serde(default = "default_positive_filename_template")]
    pub filename_template: String,
    #[serde(default = "default_positive_destination")]
    pub destination: String,
}

impl Default for PositiveRecipe {
    fn default() -> Self {
        Self {
            enabled: true,
            file_format: OutputFileFormat::default(),
            color_profile: OutputColorProfile::default(),
            filename_template: default_positive_filename_template(),
            destination: default_positive_destination(),
        }
    }
}

fn default_preview_file_format() -> OutputFileFormat {
    OutputFileFormat::Jpeg
}

fn default_preview_max_long_edge_px() -> u32 {
    2048
}

fn default_preview_filename_template() -> String {
    "ScanStudio#".to_string()
}

fn default_preview_destination() -> String {
    fallback_unfiled_root()
        .join("Preview")
        .display()
        .to_string()
}

/// A regenerable derivative like `PositiveRecipe`, but defaults to the
/// small/fast format (`jpeg`) rather than positive's `tiff` default.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PreviewRecipe {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_preview_file_format")]
    pub file_format: OutputFileFormat,
    #[serde(default = "default_preview_max_long_edge_px")]
    pub max_long_edge_px: u32,
    #[serde(default = "default_preview_filename_template")]
    pub filename_template: String,
    #[serde(default = "default_preview_destination")]
    pub destination: String,
}

impl Default for PreviewRecipe {
    fn default() -> Self {
        Self {
            enabled: true,
            file_format: default_preview_file_format(),
            max_long_edge_px: default_preview_max_long_edge_px(),
            filename_template: default_preview_filename_template(),
            destination: default_preview_destination(),
        }
    }
}

/// Container holding the four independent recipes. Kept named
/// `OutputRecipe` (not renamed) so `ScannerBackend::scan_start`'s
/// signature stays textually unchanged — only the internal shape nests.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OutputRecipe {
    #[serde(default)]
    pub archive: ArchiveRecipe,
    #[serde(default)]
    pub positive: PositiveRecipe,
    #[serde(default)]
    pub preview: PreviewRecipe,
    /// Optional, full-resolution untouched scanner-negative export.
    #[serde(default)]
    pub raw_export: RawExportRecipe,
    /// Non-destructive scan-time auto-crop. When true, each frame's derived
    /// outputs (positive/preview) are cropped to that frame's own detected
    /// film ROI via the parity-proven NegPy AUTO_FRAME_EDGE port. The
    /// retained archive master and raw negative are never cropped; the
    /// decision and ROI are recorded per frame in `ScanReceipt.auto_crop`.
    /// An approved manual frame alignment takes precedence, and a detection failure falls back
    /// to the uncropped derivative with the outcome recorded. Missing key
    /// keeps older projects and clients uncropped.
    #[serde(default)]
    pub auto_crop: bool,
    /// C-41 target for regenerable positive/preview exports. Missing keys
    /// preserve the historic nikonlook output of existing projects.
    #[serde(default)]
    pub c41_render: C41RenderRecipe,
}

impl Default for OutputRecipe {
    fn default() -> Self {
        Self {
            archive: ArchiveRecipe::default(),
            positive: PositiveRecipe::default(),
            preview: PreviewRecipe::default(),
            raw_export: RawExportRecipe::default(),
            auto_crop: false,
            c41_render: C41RenderRecipe::default(),
        }
    }
}

impl OutputRecipe {
    pub const RESERVED_FILENAME_MARKER_PREFIX: &'static str = "$ScanStudioSequence(";

    /// Engine-created exact sequence reservations are job-local capability
    /// markers, never valid user/project recipe text.
    pub fn contains_reserved_filename_marker(&self) -> bool {
        [
            self.archive.filename_template.as_str(),
            self.positive.filename_template.as_str(),
            self.preview.filename_template.as_str(),
            self.raw_export.filename_template.as_str(),
        ]
        .into_iter()
        .any(|template| template.contains(Self::RESERVED_FILENAME_MARKER_PREFIX))
    }

    /// A scan must retain something the operator can recover without the
    /// engine's private capture workspace. The archive is optional, but an
    /// all-off recipe is never safe to dispatch.
    pub fn has_retained_output(&self) -> bool {
        self.archive.enabled
            || self.positive.enabled
            || self.preview.enabled
            || self.raw_export.enabled
    }

    /// Full capture packages copy a retained master and its sidecars; they
    /// have no honest meaning when the master itself is disabled.
    pub fn retention_is_valid(&self) -> bool {
        self.has_retained_output() && (!self.archive.full_capture_package || self.archive.enabled)
    }
}

/// A reproducible, non-destructive presentation transform applied only to
/// finished positive/preview derivatives. Quarter-turn rotation is clockwise,
/// and mirrors are evaluated in the unrotated source axes before rotation --
/// the same ordering SwiftUI uses for ScanStudio's preview tiles. Capture
/// masters, raw negatives, and their IR/meter sidecars never consume this value.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct DerivativeTransform {
    #[serde(default)]
    pub rotation_degrees: u16,
    #[serde(default)]
    pub horizontal_mirror: bool,
    #[serde(default)]
    pub vertical_mirror: bool,
}

impl DerivativeTransform {
    pub fn is_supported(self) -> bool {
        matches!(self.rotation_degrees, 0 | 90 | 180 | 270)
    }
}

/// Per-frame alignment intent for frame-alignment review (SPEC-FRAME-
/// ALIGNMENT-REVIEW.md Rule 2). The adjustment is stored as a row offset
/// relative to the frame boundary that detection found, plus an explicit
/// approval token — never as absolute row numbers. A retained archive master
/// is never cropped; this setting is applied only when producing derived
/// output, and carried into `scan.start` so an approved relative offset
/// reaches the backend.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FrameAlignment {
    /// User adjustment in rows, relative to the detected frame boundary.
    /// Positive values shift the crop downward; negative values shift it
    /// upward. The render path clamps the resulting region to the archive.
    pub offset_rows: i64,
    /// True only after the user has explicitly approved this offset. An
    /// unapproved offset is persisted (so the UI can preserve a draft
    /// nudge) but is inert for both derived-output rendering and the
    /// backend scan wire.
    pub approved: bool,
    /// Display geometry selected in the contact sheet/detail editor. Unlike
    /// the crop nudge, it does not require approval: it is explicit user
    /// intent and applies only to regenerable derivatives.
    #[serde(default)]
    pub derivative_transform: DerivativeTransform,
}

impl FrameAlignment {
    /// Convenience builder for an approved offset — the common case once
    /// review is complete.
    pub fn approved(offset_rows: i64) -> Self {
        Self {
            offset_rows,
            approved: true,
            derivative_transform: DerivativeTransform::default(),
        }
    }

    /// Convenience builder for a draft/unapproved offset.
    pub fn draft(offset_rows: i64) -> Self {
        Self {
            offset_rows,
            approved: false,
            derivative_transform: DerivativeTransform::default(),
        }
    }
}

/// Per-frame recipe overrides and alignment resolved by `server.rs`'s
/// `scan.start` handler from the active project's manifest before a job
/// starts. A frame absent from the map (or a `None` field within an entry)
/// uses the job's roll-wide recipe/processing/output/alignment for that
/// one dimension.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FrameOverrides {
    pub capture: Option<CaptureRecipe>,
    pub processing: Option<ProcessingRecipe>,
    pub output: Option<OutputRecipe>,
    pub alignment: Option<FrameAlignment>,
}

/// Where a completed frame's files actually landed. Populated by Plan
/// 03-02's real file-writing logic; every field is a path this engine
/// build actually wrote, never a template or a destination directory.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WrittenOutputs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archive_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub positive_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_negative_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_negative_ir_path: Option<String>,
    /// Exact presentation transform used for the finished derivatives.
    /// Identity on legacy receipts whose `outputs` object predates this key.
    #[serde(default)]
    pub derivative_transform: DerivativeTransform,
}

/// Which of nikonlook v2's Layer-A gain-estimation paths a rendered C41
/// frame actually used. `Blind` covers both v1's only method
/// (`percentile-stopgap-v1`, which never accepts exposure metadata at all)
/// and v2's scored raw-feature fallback (`log-ridge-raw-features-v1`) --
/// telling those two apart requires reading `NikonlookProvenance.bundle_version`
/// alongside this field. `HardwareExposure` is only reachable on a v2
/// bundle whose caller supplied a usable `exposure_10ns` (see
/// `processing::nikonlook::estimate_gains`'s doc comment for exactly what
/// "usable" means and why an unusable value is treated as absent rather
/// than erroring or clamping a meaningless ratio).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum NikonlookLayerAPath {
    Blind,
    HardwareExposure,
}

/// Per-frame nikonlook provenance for a rendered C41 positive: the bundle
/// version, which Layer-A path ran, and the exact per-channel gains
/// `processing::nikonlook::apply` actually used. These materially change
/// the rendered output (see PARITY.md and
/// `resources/nikonlook-v2/PROVENANCE.md`) but were previously
/// unrecoverable from a receipt alone. `None` on every non-C41 frame
/// (Positive/Kodachrome pass the raw pixels through unchanged; BwNegative
/// inverts a neutral RGB average) -- nikonlook never runs for those.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NikonlookProvenance {
    pub bundle_version: String,
    pub layer_a_path: NikonlookLayerAPath,
    /// R, G, B order -- the exact `k` `estimate_gains` returned and `apply`
    /// multiplied into the raw pixels before the shared matrix+curves model.
    pub gains: [f64; 3],
}

// ---------------------------------------------------------------------
// Metadata (META-01)
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PartialDate {
    Exact { date: String },
    MonthOnly { year: i32, month: u32 },
    YearOnly { year: i32 },
    Unknown,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct MetadataSet {
    pub camera: Option<String>,
    pub lens: Option<String>,
    pub film_stock: Option<String>,
    pub process: Option<FilmProcess>,
    pub iso: Option<u32>,
    pub date: Option<PartialDate>,
    pub location: Option<String>,
    pub photographer: Option<String>,
    pub copyright: Option<String>,
    pub roll_id: Option<String>,
    pub frame_number: Option<u32>,
    pub notes: Option<String>,
    #[serde(default)]
    pub keywords: Vec<String>,
}

// ---------------------------------------------------------------------
// Project manifest schema (PROJ-01/PROJ-02, PERSIST-01). Persistence
// (atomic read/write, create/open/list) lives in `manifest.rs`; this is
// just the wire/on-disk shape, mirroring `protocol/PROTOCOL.md`'s "Types"
// section byte-for-byte like everything else in this file.
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanProject {
    pub schema_version: u32,
    pub id: String,
    pub name: String,
    pub carrier: MediaCarrier,
    pub frame_count: u32,
    pub film_process: FilmProcess,
    #[serde(default)]
    pub recipes: OutputRecipe,
    /// Roll-wide default metadata. Read/written by `project.setRollMetadata`;
    /// every frame without its own `metadataOverride` inherits this set.
    #[serde(default)]
    pub roll_metadata: MetadataSet,
    pub created_at: String,
    pub frames: Vec<ProjectFrame>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectFrame {
    pub index: u32,
    pub excluded: bool,
    /// Per-frame capture override slot. Read/written by
    /// `project.setFrameCaptureOverride`; resolved into actual scan
    /// execution by Plan 04-02.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capture_override: Option<CaptureRecipe>,
    /// Per-frame processing override slot. Read/written by
    /// `project.setFrameProcessingOverride`; resolved into actual scan
    /// execution by Plan 04-02.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub processing_override: Option<ProcessingRecipe>,
    /// Per-frame output override slot. Read/written by
    /// `project.setFrameOutputOverride`; resolved into actual scan
    /// execution by Plan 04-02.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_override: Option<OutputRecipe>,
    /// Per-frame alignment setting. Read/written by
    /// `project.setFrameAlignment`; applied only to derived output, never
    /// to a retained archive master, and carried into `scan.start` when approved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alignment: Option<FrameAlignment>,
    /// Per-frame metadata override slot. Read/written by
    /// `project.setFrameMetadataOverride`; when `Some` it entirely replaces
    /// the roll-wide `rollMetadata` for this frame, with no per-field merge.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata_override: Option<MetadataSet>,
    pub receipts: Vec<ScanReceipt>,
}

/// Lightweight listing shape for `project.list` — everything in
/// `ScanProject` except `frames`, plus the resolved `directory` it was
/// read from (which isn't part of the manifest file itself).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectSummary {
    pub id: String,
    pub name: String,
    pub carrier: MediaCarrier,
    pub frame_count: u32,
    pub film_process: FilmProcess,
    pub created_at: String,
    pub directory: String,
}

// ---------------------------------------------------------------------
// Defect instances (DEF-02). `severity`/`classification` mirror
// `processing::ice::DefectMap`'s own documented convention so Phase 17 can
// swap this Vec's data source without a wire-protocol change -- see
// render.rs::generate_synthetic_defects and render.rs::classify_defect_severity.
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum DefectKind {
    Dust,
    Scratch,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum DefectClassification {
    WillCorrect,
    Uncertain,
}

/// One discrete, navigable/filterable/countable synthetic defect instance
/// for DEF-01/DEF-02's Defect Map viewing mode. `severity` mirrors
/// `processing::ice::DefectMap.score`'s own documented convention exactly
/// (normalized [0.0,1.0]: 0.0=clean, 1.0=most severe/least certain) so
/// Phase 17 can populate this same Vec shape from real per-pixel
/// ice::DefectMap data (via connected-component clustering of thresholded
/// pixels into instances) without any wire-protocol change -- only the
/// SOURCE of this Vec changes. `classification` is this severity's
/// pre-resolved red("will correct")/amber("uncertain") band (see
/// render.rs::classify_defect_severity) so clients never need their own
/// threshold logic. `end_x`/`end_y` mirror Thumbnail's own documented
/// "exactly one of ..." convention: populated only when `kind == Scratch`
/// (the trace's second endpoint), `None` when `kind == Dust`. `radius` is
/// the dust marker's circle radius for `Dust`, and the trace's half-width
/// for `Scratch` -- both normalized to the frame's own [0,1] unit square,
/// same convention as `center_x`/`center_y`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DefectInstance {
    pub id: u32,
    pub kind: DefectKind,
    pub severity: f32,
    pub classification: DefectClassification,
    pub center_x: f32,
    pub center_y: f32,
    pub radius: f32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_x: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_y: Option<f32>,
}

// ---------------------------------------------------------------------
// Scan job + state machines (D-08)
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanJob {
    pub job_id: String,
    pub frames: Vec<u32>,
    pub recipe: CaptureRecipe,
    pub state: JobState,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum JobState {
    Queued,
    Scanning,
    Completed,
    Failed,
    StoppingAfterCurrentFrame,
    StoppingImmediately,
    Stopped,
}

/// Explicit transition table over PROTOCOL.md's "State machines" section.
/// Every legal edge is enumerated; everything else — including every
/// self-transition and every transition out of a terminal state
/// (`Completed`/`Stopped`/`Failed`) — is illegal.
pub fn job_state_can_transition(from: JobState, to: JobState) -> bool {
    use JobState::*;
    matches!(
        (from, to),
        (Queued, Scanning)
            | (Queued, Stopped)
            | (Scanning, Completed)
            | (Scanning, Failed)
            | (Scanning, StoppingAfterCurrentFrame)
            | (Scanning, StoppingImmediately)
            | (StoppingAfterCurrentFrame, Stopped)
            | (StoppingAfterCurrentFrame, Completed)
            | (StoppingImmediately, Stopped)
    )
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum FrameState {
    Waiting,
    Active,
    Completed,
    Failed,
    Skipped,
}

/// No "excluded" variant — excluded frames never enter a job at all
/// (PROTOCOL.md is explicit about this).
pub fn frame_state_can_transition(from: FrameState, to: FrameState) -> bool {
    use FrameState::*;
    matches!(
        (from, to),
        (Waiting, Active)
            | (Active, Completed)
            | (Active, Failed)
            | (Active, Skipped)
            | (Failed, Active)
    )
}

// ---------------------------------------------------------------------
// Scan receipt
// ---------------------------------------------------------------------

/// Mirrors `bridge_protocol::BridgeExposureVector` field-for-field — a
/// PROTOCOL.md-owned copy, not a re-export, per BRIDGE.md's own stated
/// independence from PROTOCOL.md.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ExposureVector {
    pub focus_position: i64,
    pub exposure_multiplier: f64,
    pub red_exposure_us: f64,
    pub green_exposure_us: f64,
    pub blue_exposure_us: f64,
}

/// Mirrors `bridge_protocol::BridgeClippingTelemetry` field-for-field.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClippingTelemetry {
    pub fractions: (f64, f64, f64),
    pub clip_level: f64,
    pub warning_fraction: f64,
    pub warning: bool,
}

/// Mirrors `bridge_protocol::BridgeFocusDetailTelemetry` field-for-field.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FocusDetailTelemetry {
    pub method: String,
    pub verdict: String,
    pub score: Option<f64>,
    pub texture_span: f64,
}

/// Mirrors `bridge_protocol::BridgeTransportSmearAssessment` field-for-field.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TransportSmearAssessment {
    pub verdict: String,
    pub start_row: Option<u32>,
    pub suffix_rows: u32,
    pub minimum_matches: u32,
    pub tail_median_rms: Option<f64>,
    pub tail_min_corr: Option<f64>,
    pub pre_tail_median_rms: Option<f64>,
    pub texture_span: Option<f64>,
    pub reason: String,
}

/// A completed real-backend frame's per-frame hardware telemetry —
/// exposure, clipping, focus, and transport-smear assessment, forwarded
/// from BRIDGE.md's `ScanReceipt` fields of the same shape. `None` on
/// every simulated receipt (the simulator has no bridge to source this
/// from).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HardwareTelemetry {
    pub exposure: ExposureVector,
    pub clipping: ClippingTelemetry,
    pub focus_detail: FocusDetailTelemetry,
    pub transport_smear: TransportSmearAssessment,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanReceipt {
    pub job_id: String,
    pub frame_index: u32,
    pub started_at: String,
    pub duration_ms: u64,
    pub passes: u32,
    pub resolution_dpi: u32,
    pub bit_depth: u32,
    pub channels: String,
    pub engine_version: String,
    pub device_id: String,
    pub simulated: bool,
    pub settings_fingerprint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub processing: Option<ProcessingRecipe>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<OutputRecipe>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outputs: Option<WrittenOutputs>,
    /// Bridge-written capture-file locations (hardware side) — deliberately
    /// distinct from `outputs` (engine-rendered derivatives, Plan 03-02's
    /// domain); do not merge the two concepts. `None` on every simulated
    /// receipt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rgb_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ir_path: Option<String>,
    /// CoolscanPy's versioned storage-orientation transform for `rgb_path`
    /// and `ir_path`, forwarded verbatim from the bridge. `None` for
    /// simulated receipts and legacy real receipts that predate the field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub storage_transform: Option<String>,
    /// CoolscanPy's `Frame.meter_rgbi` auto-exposure prepass file, when the
    /// bridge supplies one. `None` on every simulated receipt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meter_rgbi_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hardware_telemetry: Option<HardwareTelemetry>,
    /// `None` for every non-C41 frame and for any C41 frame rendered before
    /// this field existed (legacy receipts predate it) -- never a
    /// fabricated value. See `NikonlookProvenance`'s own doc comment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nikonlook: Option<NikonlookProvenance>,
    /// Scan-time non-destructive auto-crop decision for this frame's
    /// derived outputs. `None` whenever the recipe did not request
    /// auto-crop or no derivative rendered.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_crop: Option<AutoCropOutcome>,
    /// Which RGB source commanded this frame's hardware exposure and what
    /// the active auto-exposure controller accepted. Forwarded verbatim
    /// from CoolscanPy's per-frame journal by the bridge. `None` for
    /// simulated and legacy receipts, or when the journal read failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exposure_authority: Option<ExposureAuthority>,
}

/// Result of the non-destructive auto-crop decision for one frame's
/// derived outputs. The retained archive master is never affected.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AutoCropOutcome {
    pub mode: String,
    pub applied: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub roi: Option<AutoCropRoi>,
    pub source_width: u32,
    pub source_height: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Half-open pixel ROI (`y1 <= row < y2`, `x1 <= col < x2`) in the archive
/// raster's stored orientation.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AutoCropRoi {
    pub y1: u32,
    pub y2: u32,
    pub x1: u32,
    pub x2: u32,
}

/// Hardware exposure authority for one fine scan. Channel maps retain the
/// raw journal keys (`R`, `G`, `B`, and `IR`); the device-clamped map is
/// sparse by construction.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ExposureAuthority {
    pub rgb_source: String,
    pub ir_source: String,
    pub commanded_channels_raw_10ns: std::collections::BTreeMap<String, u32>,
    pub active_controller_channels_raw_10ns: std::collections::BTreeMap<String, u32>,
    pub device_bound_clamped_channels_raw_10ns: std::collections::BTreeMap<String, u32>,
    /// `[min, max]` raw 10ns-tick bounds enforced by the device.
    pub device_exposure_bounds_raw_10ns: [u32; 2],
}

// ---------------------------------------------------------------------
// Engine error — internal Rust-side error; server.rs converts this into
// the wire `ErrorPayload` shape (protocol::ErrorPayload).
// ---------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct EngineError {
    pub code: ErrorCode,
    pub message: String,
    recoverable_override: Option<bool>,
}

impl EngineError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        EngineError {
            code,
            message: message.into(),
            recoverable_override: None,
        }
    }

    /// Explicitly sets the recoverable bit for this error, overriding the
    /// code-based default. Used by the Real backend so BRIDGE.md's own
    /// code-to-recoverable policy survives being folded into
    /// `ErrorCode::Internal`.
    pub fn with_recoverable(mut self, recoverable: bool) -> Self {
        self.recoverable_override = Some(recoverable);
        self
    }

    /// `true` only for `FeedJam` when no explicit override is set — the only
    /// fault where retrying the same operation can succeed. An explicit
    /// override (set via `with_recoverable`) wins so bridge-sourced failures
    /// can report BRIDGE.md's own recoverability honestly.
    pub fn recoverable(&self) -> bool {
        self.recoverable_override
            .unwrap_or_else(|| matches!(self.code, ErrorCode::FeedJam))
    }
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)
    }
}

impl std::error::Error for EngineError {}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bw_processing_forces_infrared_ice_off_without_changing_color_negative() {
        let bw = ProcessingRecipe {
            film_process: FilmProcess::BwNegative,
            digital_ice_enabled: true,
            ..ProcessingRecipe::default()
        };
        assert!(!bw.effective().digital_ice_enabled);
        assert_eq!(
            CaptureRecipe::default()
                .effective_for_process(FilmProcess::BwNegative)
                .channels,
            Channels::Rgb
        );

        let c41 = ProcessingRecipe {
            film_process: FilmProcess::C41ColorNegative,
            digital_ice_enabled: true,
            ..ProcessingRecipe::default()
        };
        assert!(c41.effective().digital_ice_enabled);
        let c41_dust = ProcessingRecipe {
            film_process: FilmProcess::C41ColorNegative,
            software_dust_removal_bw: true,
            ..ProcessingRecipe::default()
        };
        assert!(!c41_dust.effective().software_dust_removal_bw);
    }
    use serde_json::json;

    fn round_trip<T>(value: &T)
    where
        T: Serialize + for<'de> Deserialize<'de> + PartialEq + std::fmt::Debug,
    {
        let encoded = serde_json::to_value(value).expect("serialize");
        let decoded: T = serde_json::from_value(encoded.clone()).expect("deserialize");
        assert_eq!(&decoded, value, "round trip mismatch via {encoded}");
    }

    #[test]
    fn device_info_round_trips_camel_case() {
        let device = DeviceInfo {
            device_id: "sim-ls5000-0".into(),
            model: "SUPER COOLSCAN 5000 ED".into(),
            kind: "simulated".into(),
            firmware: "1.03-sim".into(),
            connection: "USB (simulated)".into(),
            supported: true,
        };
        let value = serde_json::to_value(&device).unwrap();
        assert_eq!(value["deviceId"], json!("sim-ls5000-0"));
        assert_eq!(value["supported"], json!(true));
        round_trip(&device);
    }

    #[test]
    fn film_process_c41_color_negative_is_trickiest_camel_case_variant() {
        let value = serde_json::to_value(FilmProcess::C41ColorNegative).unwrap();
        assert_eq!(value, json!("c41ColorNegative"));
        let decoded: FilmProcess = serde_json::from_value(json!("c41ColorNegative")).unwrap();
        assert_eq!(decoded, FilmProcess::C41ColorNegative);
    }

    #[test]
    fn job_state_stopping_after_current_frame_is_trickiest_camel_case_variant() {
        let value = serde_json::to_value(JobState::StoppingAfterCurrentFrame).unwrap();
        assert_eq!(value, json!("stoppingAfterCurrentFrame"));
        let decoded: JobState = serde_json::from_value(json!("stoppingAfterCurrentFrame")).unwrap();
        assert_eq!(decoded, JobState::StoppingAfterCurrentFrame);
    }

    #[test]
    fn media_carrier_round_trips() {
        for (variant, wire) in [
            (MediaCarrier::Roll36, "roll36"),
            (MediaCarrier::Strip6, "strip6"),
            (MediaCarrier::Mounted, "mounted"),
        ] {
            assert_eq!(serde_json::to_value(variant).unwrap(), json!(wire));
        }
    }

    #[test]
    fn film_process_round_trips_all_variants() {
        for (variant, wire) in [
            (FilmProcess::Positive, "positive"),
            (FilmProcess::C41ColorNegative, "c41ColorNegative"),
            (FilmProcess::BwNegative, "bwNegative"),
            (FilmProcess::Kodachrome, "kodachrome"),
        ] {
            assert_eq!(serde_json::to_value(variant).unwrap(), json!(wire));
            round_trip(&variant);
        }
    }

    #[test]
    fn capture_recipe_defaults_match_protocol() {
        let recipe: CaptureRecipe = serde_json::from_value(json!({})).unwrap();
        assert_eq!(recipe, CaptureRecipe::default());
        assert_eq!(recipe.resolution_dpi, 4000);
        assert_eq!(recipe.bit_depth, 16);
        assert_eq!(recipe.multisample_passes, 1);
        assert_eq!(recipe.channels, Channels::Rgbi);
    }

    #[test]
    fn capture_recipe_round_trips_fully_populated() {
        let recipe = CaptureRecipe {
            resolution_dpi: 4000,
            bit_depth: 16,
            multisample_passes: 2,
            channels: Channels::Rgbi,
        };
        round_trip(&recipe);
    }

    #[test]
    fn processing_recipe_round_trips() {
        round_trip(&ProcessingRecipe {
            film_process: FilmProcess::BwNegative,
            autofocus_each_frame: false,
            auto_exposure_each_frame: true,
            digital_ice_enabled: true,
            digital_ice_mode: DigitalIceMode::Hybrid,
            software_dust_removal_bw: false,
        });
        round_trip(&ProcessingRecipe::default());
    }

    #[test]
    fn output_recipe_round_trips() {
        round_trip(&OutputRecipe {
            auto_crop: false,
            c41_render: C41RenderRecipe::default(),
            archive: ArchiveRecipe {
                enabled: true,
                filename_template: "Archive_####".into(),
                destination: "/Scans/Archive".into(),
                full_capture_package: true,
            },
            raw_export: RawExportRecipe {
                enabled: true,
                file_format: RawExportFormat::LinearTiff,
                tiff_infrared: RawTiffInfrared::Sidecar,
                filename_template: "Negative_####.tif".into(),
                destination: "/Scans/Raw".into(),
            },
            positive: PositiveRecipe {
                enabled: false,
                file_format: OutputFileFormat::Jpeg,
                color_profile: OutputColorProfile::ProPhotoRgb,
                filename_template: "Positive_####".into(),
                destination: "/Scans/Positive".into(),
            },
            preview: PreviewRecipe {
                enabled: false,
                file_format: OutputFileFormat::Tiff,
                max_long_edge_px: 1024,
                filename_template: "Preview_####".into(),
                destination: "/Scans/Preview".into(),
            },
        });
        round_trip(&OutputRecipe::default());
    }

    #[test]
    fn output_recipe_missing_raw_export_defaults_to_disabled_for_legacy_projects() {
        let mut value = serde_json::to_value(OutputRecipe::default()).unwrap();
        value.as_object_mut().unwrap().remove("rawExport");
        let output: OutputRecipe = serde_json::from_value(value).unwrap();
        assert_eq!(output.raw_export, RawExportRecipe::default());
        assert!(!output.raw_export.enabled);
    }

    #[test]
    fn output_recipe_detects_reserved_engine_filename_markers_even_when_the_role_is_disabled() {
        let mut output = OutputRecipe::default();
        output.preview.enabled = false;
        output.preview.filename_template = "Hidden$ScanStudioSequence(8)".into();
        assert!(output.contains_reserved_filename_marker());
        output.preview.filename_template = "Preview_####".into();
        output.raw_export.filename_template = "Hidden$ScanStudioSequence(9)".into();
        assert!(output.contains_reserved_filename_marker());
        assert!(!OutputRecipe::default().contains_reserved_filename_marker());
    }

    #[test]
    fn archive_recipe_round_trips() {
        round_trip(&ArchiveRecipe {
            enabled: true,
            filename_template: "Archive_####".into(),
            destination: "/Scans/Archive".into(),
            full_capture_package: true,
        });
    }

    #[test]
    fn archive_recipe_missing_enabled_defaults_to_retained_for_legacy_projects() {
        let archive: ArchiveRecipe = serde_json::from_value(json!({
            "filenameTemplate": "Archive_####",
            "destination": "/Scans/Archive"
        }))
        .expect("legacy archive recipe decodes");
        assert!(archive.enabled);
        assert!(archive.full_capture_package);
    }

    #[test]
    fn positive_recipe_round_trips() {
        round_trip(&PositiveRecipe {
            enabled: false,
            file_format: OutputFileFormat::Jpeg,
            color_profile: OutputColorProfile::ProPhotoRgb,
            filename_template: "Positive_####".into(),
            destination: "/Scans/Positive".into(),
        });
    }

    #[test]
    fn preview_recipe_round_trips() {
        round_trip(&PreviewRecipe {
            enabled: false,
            file_format: OutputFileFormat::Tiff,
            max_long_edge_px: 1024,
            filename_template: "Preview_####".into(),
            destination: "/Scans/Preview".into(),
        });
    }

    /// Defect 8 (2026-07-25): a shared, project-unaware default recipe
    /// must never point into the OS temp directory (real, silently
    /// OS-purged) — only under `~/ScanStudio Projects` like every other
    /// on-this-Mac ScanStudio path. `manifest::create_project` overrides
    /// these per-project anyway (see its own tests), but the generic
    /// fallback itself must be safe for the construction sites that don't
    /// override it (e.g. `OutputRecipe::default()` in tests elsewhere).
    #[test]
    fn default_recipe_destinations_never_point_into_the_os_temp_dir() {
        let temp_dir = std::env::temp_dir();
        let defaults = OutputRecipe::default();
        for destination in [
            &defaults.archive.destination,
            &defaults.positive.destination,
            &defaults.preview.destination,
        ] {
            assert!(
                !std::path::Path::new(destination).starts_with(&temp_dir),
                "default destination {destination:?} must not be under the OS temp dir {temp_dir:?}"
            );
            assert!(
                destination.contains("ScanStudio Projects"),
                "default destination {destination:?} must live under ~/ScanStudio Projects"
            );
        }
    }

    #[test]
    fn scan_project_round_trips() {
        round_trip(&ScanProject {
            schema_version: 1,
            id: "proj-1".into(),
            name: "Test Roll".into(),
            carrier: MediaCarrier::Roll36,
            frame_count: 3,
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
                    receipts: vec![],
                },
                ProjectFrame {
                    index: 2,
                    excluded: true,
                    capture_override: None,
                    processing_override: None,
                    output_override: None,
                    alignment: None,
                    metadata_override: None,
                    receipts: vec![],
                },
                ProjectFrame {
                    index: 3,
                    excluded: false,
                    capture_override: None,
                    processing_override: None,
                    output_override: None,
                    alignment: None,
                    metadata_override: None,
                    receipts: vec![],
                },
            ],
        });
    }

    #[test]
    fn scan_project_round_trips_with_roll_metadata_populated() {
        round_trip(&ScanProject {
            schema_version: 4,
            id: "proj-1".into(),
            name: "Test Roll".into(),
            carrier: MediaCarrier::Roll36,
            frame_count: 1,
            film_process: FilmProcess::C41ColorNegative,
            recipes: OutputRecipe::default(),
            roll_metadata: MetadataSet {
                camera: Some("Nikon F100".into()),
                date: Some(PartialDate::YearOnly { year: 2026 }),
                ..MetadataSet::default()
            },
            created_at: "2026-07-22T09:00:00Z".into(),
            frames: vec![ProjectFrame {
                index: 1,
                excluded: false,
                capture_override: None,
                processing_override: None,
                output_override: None,
                alignment: None,
                metadata_override: None,
                receipts: vec![],
            }],
        });
    }

    #[test]
    fn frame_alignment_round_trips_and_serializes_camel_case() {
        let alignment = FrameAlignment::approved(-12);
        let value = serde_json::to_value(&alignment).unwrap();
        assert_eq!(value["offsetRows"], json!(-12));
        assert_eq!(value["approved"], json!(true));
        round_trip(&alignment);
        round_trip(&FrameAlignment::draft(7));
    }

    #[test]
    fn project_frame_round_trips() {
        round_trip(&ProjectFrame {
            index: 1,
            excluded: false,
            capture_override: None,
            processing_override: None,
            output_override: None,
            alignment: None,
            metadata_override: None,
            receipts: vec![],
        });

        // Same receipt literal as `scan_receipt_matches_golden_fixture_shape`
        // below, attached to a frame — a frame with recorded receipts must
        // round trip exactly, including the nested receipt.
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
        round_trip(&ProjectFrame {
            index: 1,
            excluded: false,
            capture_override: None,
            processing_override: None,
            output_override: None,
            alignment: None,
            metadata_override: None,
            receipts: vec![receipt],
        });
    }

    #[test]
    fn project_frame_round_trips_with_all_three_overrides_populated() {
        round_trip(&ProjectFrame {
            index: 1,
            excluded: false,
            capture_override: Some(CaptureRecipe {
                resolution_dpi: 2000,
                ..CaptureRecipe::default()
            }),
            processing_override: Some(ProcessingRecipe {
                film_process: FilmProcess::BwNegative,
                ..ProcessingRecipe::default()
            }),
            output_override: Some(OutputRecipe::default()),
            alignment: Some(FrameAlignment::approved(5)),
            metadata_override: None,
            receipts: vec![],
        });
    }

    #[test]
    fn project_frame_omits_override_keys_when_none() {
        let frame = ProjectFrame {
            index: 1,
            excluded: false,
            capture_override: None,
            processing_override: None,
            output_override: None,
            alignment: None,
            metadata_override: None,
            receipts: vec![],
        };
        let value = serde_json::to_value(&frame).unwrap();
        assert!(value.get("captureOverride").is_none());
        assert!(value.get("processingOverride").is_none());
        assert!(value.get("outputOverride").is_none());
        assert!(value.get("alignment").is_none());
        assert!(value.get("metadataOverride").is_none());
    }

    #[test]
    fn project_frame_round_trips_with_metadata_override_populated() {
        round_trip(&ProjectFrame {
            index: 1,
            excluded: false,
            capture_override: None,
            processing_override: None,
            output_override: None,
            alignment: None,
            metadata_override: Some(MetadataSet {
                location: Some("Home".into()),
                ..MetadataSet::default()
            }),
            receipts: vec![],
        });

        let frame = ProjectFrame {
            index: 1,
            excluded: false,
            capture_override: None,
            processing_override: None,
            output_override: None,
            alignment: None,
            metadata_override: None,
            receipts: vec![],
        };
        let value = serde_json::to_value(&frame).unwrap();
        assert!(value.get("metadataOverride").is_none());
    }

    #[test]
    fn project_summary_round_trips() {
        round_trip(&ProjectSummary {
            id: "proj-1".into(),
            name: "Test Roll".into(),
            carrier: MediaCarrier::Roll36,
            frame_count: 36,
            film_process: FilmProcess::C41ColorNegative,
            created_at: "2026-07-22T09:00:00Z".into(),
            directory: "/tmp/scanstudio-test/proj-1".into(),
        });
    }

    #[test]
    fn defect_instance_round_trips_with_scratch_endpoints_populated() {
        let instance = DefectInstance {
            id: 3,
            kind: DefectKind::Scratch,
            severity: 0.42,
            classification: DefectClassification::WillCorrect,
            center_x: 0.5,
            center_y: 0.5,
            radius: 0.003,
            end_x: Some(0.62),
            end_y: Some(0.58),
        };
        let value = serde_json::to_value(&instance).unwrap();
        assert_eq!(value["kind"], json!("scratch"));
        assert_eq!(value["classification"], json!("willCorrect"));
        assert!(value.get("endX").is_some(), "scratch must populate endX");
        assert!(value.get("endY").is_some(), "scratch must populate endY");
        round_trip(&instance);
    }

    #[test]
    fn defect_instance_omits_end_x_end_y_when_kind_is_dust() {
        let instance = DefectInstance {
            id: 7,
            kind: DefectKind::Dust,
            severity: 0.81,
            classification: DefectClassification::Uncertain,
            center_x: 0.2,
            center_y: 0.75,
            radius: 0.01,
            end_x: None,
            end_y: None,
        };
        let value = serde_json::to_value(&instance).unwrap();
        assert_eq!(value["kind"], json!("dust"));
        assert!(
            value.get("endX").is_none(),
            "endX must be omitted entirely, not serialized as null: {value}"
        );
        assert!(
            value.get("endY").is_none(),
            "endY must be omitted entirely, not serialized as null: {value}"
        );
        round_trip(&instance);
    }

    #[test]
    fn partial_date_round_trips_all_variants() {
        round_trip(&PartialDate::Exact {
            date: "2026-07-22".into(),
        });
        round_trip(&PartialDate::MonthOnly {
            year: 2026,
            month: 7,
        });
        round_trip(&PartialDate::YearOnly { year: 2026 });
        round_trip(&PartialDate::Unknown);

        let value = serde_json::to_value(PartialDate::MonthOnly {
            year: 2026,
            month: 7,
        })
        .unwrap();
        assert_eq!(value["kind"], json!("monthOnly"));
    }

    #[test]
    fn metadata_set_round_trips() {
        round_trip(&MetadataSet {
            camera: Some("Nikon F100".into()),
            lens: Some("50mm f/1.4".into()),
            film_stock: Some("Kodak Portra 400".into()),
            process: Some(FilmProcess::C41ColorNegative),
            iso: Some(400),
            date: Some(PartialDate::YearOnly { year: 2026 }),
            location: Some("Home".into()),
            photographer: Some("Rohan".into()),
            copyright: Some("(c) 2026".into()),
            roll_id: Some("roll-1".into()),
            frame_number: Some(1),
            notes: Some("test".into()),
            keywords: vec!["family".into()],
        });

        // All-None variant must also round trip.
        round_trip(&MetadataSet {
            camera: None,
            lens: None,
            film_stock: None,
            process: None,
            iso: None,
            date: None,
            location: None,
            photographer: None,
            copyright: None,
            roll_id: None,
            frame_number: None,
            notes: None,
            keywords: vec![],
        });
    }

    #[test]
    fn scan_job_round_trips() {
        round_trip(&ScanJob {
            job_id: "job-1".into(),
            frames: vec![1, 2, 3],
            recipe: CaptureRecipe::default(),
            state: JobState::Queued,
        });
    }

    #[test]
    fn scan_receipt_matches_golden_fixture_shape() {
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
        round_trip(&receipt);
    }

    #[test]
    fn scan_receipt_with_nikonlook_provenance_matches_documented_camelcase_shape() {
        // Same base receipt literal as `scan_receipt_matches_golden_fixture_shape`
        // above, but with `nikonlook: Some(...)` -- the one field neither
        // existing ScanReceipt round-trip test exercises (both use `None`),
        // so nothing previously proved this field's `Some` side reaches the
        // wire in its documented camelCase shape (PROTOCOL.md) rather than
        // being silently dropped by `skip_serializing_if`.
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
            nikonlook: Some(NikonlookProvenance {
                bundle_version: "nikonlook-v2".into(),
                layer_a_path: NikonlookLayerAPath::HardwareExposure,
                gains: [0.5764822683598294, 0.22818411954519974, 0.2620541212542383],
            }),
        };
        let value = serde_json::to_value(&receipt).unwrap();
        assert_eq!(
            value["nikonlook"],
            json!({
                "bundleVersion": "nikonlook-v2",
                "layerAPath": "hardwareExposure",
                "gains": [0.5764822683598294, 0.22818411954519974, 0.2620541212542383],
            })
        );
        round_trip(&receipt);

        // The fallback path's own wire value -- what a malformed or absent
        // exposure_10ns labels (see processing::nikonlook::exposure_is_usable
        // and render::render_positive).
        assert_eq!(
            serde_json::to_value(NikonlookLayerAPath::Blind).unwrap(),
            json!("blind")
        );

        let mut with_exposure_authority = receipt.clone();
        with_exposure_authority.exposure_authority = Some(ExposureAuthority {
            rgb_source: "nikon-parity-guarded-v2".into(),
            ir_source: "active-controller".into(),
            commanded_channels_raw_10ns: std::collections::BTreeMap::from([
                ("R".into(), 107262),
                ("G".into(), 276334),
                ("B".into(), 336777),
                ("IR".into(), 311725),
            ]),
            active_controller_channels_raw_10ns: std::collections::BTreeMap::from([
                ("R".into(), 121500),
                ("G".into(), 276334),
                ("B".into(), 340200),
                ("IR".into(), 311725),
            ]),
            device_bound_clamped_channels_raw_10ns: std::collections::BTreeMap::from([(
                "B".into(),
                340200,
            )]),
            device_exposure_bounds_raw_10ns: [50_000, 400_000],
        });
        let authority_value = serde_json::to_value(&with_exposure_authority).unwrap();
        assert_eq!(
            authority_value["exposureAuthority"]["rgbSource"],
            json!("nikon-parity-guarded-v2")
        );
        assert_eq!(
            authority_value["exposureAuthority"]["deviceBoundClampedChannelsRaw10ns"],
            json!({"B": 340200})
        );
        round_trip(&with_exposure_authority);
    }

    #[test]
    fn job_state_legal_transitions_all_return_true() {
        use JobState::*;
        let legal = [
            (Queued, Scanning),
            (Queued, Stopped),
            (Scanning, Completed),
            (Scanning, Failed),
            (Scanning, StoppingAfterCurrentFrame),
            (Scanning, StoppingImmediately),
            (StoppingAfterCurrentFrame, Stopped),
            (StoppingAfterCurrentFrame, Completed),
            (StoppingImmediately, Stopped),
        ];
        for (from, to) in legal {
            assert!(
                job_state_can_transition(from, to),
                "expected {from:?} -> {to:?} to be legal"
            );
        }
    }

    #[test]
    fn job_state_illegal_transitions_all_return_false() {
        use JobState::*;
        let illegal = [
            // Self-transitions.
            (Queued, Queued),
            (Scanning, Scanning),
            (Completed, Completed),
            (Stopped, Stopped),
            (Failed, Failed),
            (StoppingAfterCurrentFrame, StoppingAfterCurrentFrame),
            (StoppingImmediately, StoppingImmediately),
            // Out of terminal states.
            (Completed, Queued),
            (Completed, Scanning),
            (Stopped, Scanning),
            (Failed, Scanning),
            (Failed, Queued),
            // Other illegal edges.
            (Queued, Completed),
            (Queued, Failed),
            (Scanning, Queued),
            (StoppingImmediately, Completed),
            (StoppingAfterCurrentFrame, Failed),
        ];
        for (from, to) in illegal {
            assert!(
                !job_state_can_transition(from, to),
                "expected {from:?} -> {to:?} to be illegal"
            );
        }
    }

    #[test]
    fn frame_state_legal_transitions_all_return_true() {
        use FrameState::*;
        let legal = [
            (Waiting, Active),
            (Active, Completed),
            (Active, Failed),
            (Active, Skipped),
            (Failed, Active),
        ];
        for (from, to) in legal {
            assert!(
                frame_state_can_transition(from, to),
                "expected {from:?} -> {to:?} to be legal"
            );
        }
    }

    #[test]
    fn frame_state_illegal_transitions_all_return_false() {
        use FrameState::*;
        let illegal = [
            // Self-transitions.
            (Waiting, Waiting),
            (Active, Active),
            (Completed, Completed),
            (Failed, Failed),
            (Skipped, Skipped),
            // Out of terminal-ish states.
            (Completed, Active),
            (Skipped, Active),
            (Failed, Completed),
            (Waiting, Completed),
            (Waiting, Failed),
        ];
        for (from, to) in illegal {
            assert!(
                !frame_state_can_transition(from, to),
                "expected {from:?} -> {to:?} to be illegal"
            );
        }
    }

    #[test]
    fn engine_error_recoverable_true_only_for_feed_jam() {
        let jam = EngineError::new(ErrorCode::FeedJam, "jam");
        assert!(jam.recoverable());

        for code in [
            ErrorCode::UnknownMethod,
            ErrorCode::InvalidParams,
            ErrorCode::UnknownDevice,
            ErrorCode::NotConnected,
            ErrorCode::AlreadyConnected,
            ErrorCode::NoMedia,
            ErrorCode::ScannerBusy,
            ErrorCode::UnknownJob,
            ErrorCode::Internal,
        ] {
            let err = EngineError::new(code, "not a jam");
            assert!(!err.recoverable(), "{code:?} should not be recoverable");
        }
    }

    #[test]
    fn engine_error_recoverable_override_is_backward_compatible() {
        let err = EngineError::new(ErrorCode::Internal, "x");
        assert!(
            !err.recoverable(),
            "default Internal must not be recoverable"
        );

        let overridden = EngineError::new(ErrorCode::Internal, "x").with_recoverable(true);
        assert!(overridden.recoverable(), "explicit override true must win");

        let overridden_false = EngineError::new(ErrorCode::FeedJam, "x").with_recoverable(false);
        assert!(
            !overridden_false.recoverable(),
            "explicit override false must win over FeedJam default"
        );

        let feed_jam = EngineError::new(ErrorCode::FeedJam, "x");
        assert!(
            feed_jam.recoverable(),
            "FeedJam default must still be recoverable"
        );
    }
}
