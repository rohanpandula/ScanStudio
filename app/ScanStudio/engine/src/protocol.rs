//! Wire envelope, method payloads, and event payloads for the Scan Studio
//! engine protocol (`protocol/PROTOCOL.md`, v1). JSON field names are
//! camelCase on the wire (see PROTOCOL.md "Transport").

use serde::{Deserialize, Serialize};

use crate::domain;

// ---------------------------------------------------------------------
// Wire envelope — three independent shapes, no shared enum (they don't
// share a discriminant field).
// ---------------------------------------------------------------------

/// Inbound shape (app -> engine). `params` may be omitted on the wire;
/// re-deserialized per-method via `serde_json::from_value`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Request {
    pub id: u64,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

/// Outbound success shape (engine -> app): `{"id": .., "result": ..}`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Response<T> {
    pub id: u64,
    pub result: T,
}

impl<T> Response<T> {
    pub fn new(id: u64, result: T) -> Self {
        Response { id, result }
    }
}

/// Outbound error shape (engine -> app): `{"id": .., "error": {..}}`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct ErrorResponse {
    pub id: u64,
    pub error: ErrorPayload,
}

impl ErrorResponse {
    pub fn new(id: u64, error: ErrorPayload) -> Self {
        ErrorResponse { id, error }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ErrorPayload {
    pub code: ErrorCode,
    pub message: String,
    pub recoverable: bool,
}

impl From<&domain::EngineError> for ErrorPayload {
    fn from(err: &domain::EngineError) -> Self {
        ErrorPayload {
            code: err.code,
            message: err.message.clone(),
            recoverable: err.recoverable(),
        }
    }
}

/// Outbound event shape (engine -> app, unsolicited):
/// `{"event": .., "payload": ..}`. Events may interleave with responses.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Event<T> {
    pub event: String,
    pub payload: T,
}

impl<T> Event<T> {
    pub fn new(event: impl Into<String>, payload: T) -> Self {
        Event {
            event: event.into(),
            payload,
        }
    }
}

// ---------------------------------------------------------------------
// Error codes
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    UnknownMethod,
    InvalidParams,
    UnknownDevice,
    NotConnected,
    AlreadyConnected,
    NoMedia,
    ScannerBusy,
    UnknownJob,
    FeedJam,
    /// The scanner stopped reporting film while positioning a batch frame.
    /// Completed frames remain durable; the operator must refeed, acquire a
    /// fresh preview, and resume only the unfinished frames.
    FilmFeedInterrupted,
    Internal,
    ProjectNotFound,
    ManifestInvalid,
    ArchiveCollision,
    /// A real preview marked this frame as requiring an explicit human
    /// acknowledgement before the bridge will move it for capture.
    ManualReviewRequired,
    /// The real bridge's live SAFE-02 re-check refused a motion-capable
    /// request. This reports readiness only; it never grants permission or
    /// changes the bridge latch.
    HwMotionNotArmed,
    /// A recognized-but-unsupported Nikon model (Lane D, #14): discovery
    /// lists it by name, but connect is refused. Fail-closed.
    NotSupported,
    /// The bridge's eject could not run or could not confirm the film
    /// left the transport. Previously flattened to `Internal`, which made
    /// the #16/#68/#76 eject failures undiagnosable client-side.
    EjectFailed,
    /// The driver's typed accepted-without-progress eject outcome
    /// (INCIDENT-20260719-eject-from-park): the transport never actuated
    /// and a power cycle is the only demonstrated recovery.
    FeederParked,
}

// ---------------------------------------------------------------------
// engine.hello / engine.shutdown
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HelloParams {
    pub client_name: String,
    pub protocol_version: u32,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HelloResult {
    pub engine_name: String,
    pub engine_version: String,
    pub protocol_version: u32,
    pub capabilities: Vec<String>,
}

// ---------------------------------------------------------------------
// scanner.list
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScannerListResult {
    pub devices: Vec<domain::DeviceInfo>,
}

// ---------------------------------------------------------------------
// scanner.connect
// ---------------------------------------------------------------------

fn default_time_scale() -> f64 {
    1.0
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub enum FaultInjection {
    #[default]
    #[serde(rename = "none")]
    NoFault,
    #[serde(rename = "demo")]
    Demo,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectOptions {
    #[serde(default = "default_time_scale")]
    pub time_scale: f64,
    #[serde(default)]
    pub fault_injection: FaultInjection,
}

impl Default for ConnectOptions {
    fn default() -> Self {
        ConnectOptions {
            time_scale: default_time_scale(),
            fault_injection: FaultInjection::default(),
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectParams {
    pub device_id: String,
    #[serde(default)]
    pub options: Option<ConnectOptions>,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Lamp {
    Off,
    Warming,
    Stable,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Transport {
    Idle,
    Busy,
    Locked,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScannerStatus {
    pub connected: bool,
    pub adapter: Option<String>,
    pub media_loaded: bool,
    pub carrier: Option<domain::MediaCarrier>,
    pub frame_count: Option<u32>,
    pub lamp: Lamp,
    pub transport: Transport,
    pub active_job_id: Option<String>,
    /// Read-only result of the bridge's live SAFE-02 readiness re-check.
    /// Real backends forward `Some(true|false)` from `DeviceStatus`; the
    /// simulator has no bridge-side latch and therefore omits this field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion_armed: Option<bool>,
    /// Live, no-motion film-presence read (BRIDGE.md
    /// `DeviceStatus.filmPresent`, forwarded verbatim by a real backend) —
    /// `None` means no trustworthy verdict was available, never absence.
    /// The simulator always reports `None` (it has no bridge to source
    /// this from).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub film_present: Option<bool>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectResult {
    pub device: domain::DeviceInfo,
    pub status: ScannerStatus,
}

// ---------------------------------------------------------------------
// sim.loadMedia
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LoadMediaParams {
    pub carrier: domain::MediaCarrier,
}

// ---------------------------------------------------------------------
// scanner.acquireThumbnails
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct AcquireThumbnailsParams {
    #[serde(default)]
    pub frames: Option<Vec<u32>>,
    /// Optional so pre-existing clients keep the historical active-project
    /// (or C-41 fallback) behavior. New clients provide the process chosen
    /// before a project exists, so real `roll.preview` receives the right
    /// bridge material.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub film_process: Option<domain::FilmProcess>,
    /// Additive request/event correlation token. New ScanStudio clients
    /// always provide this; omission remains accepted for older clients.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AcquireThumbnailsAck {
    pub accepted: bool,
    pub frames: Vec<u32>,
}

// ---------------------------------------------------------------------
// roll.approve
// ---------------------------------------------------------------------

/// Explicitly acknowledges the review warning on one frame from the active
/// real-device preview. The project-facing protocol consistently calls this
/// identifier `frameIndex`; the real backend maps it one-to-one to BRIDGE.md's
/// scanner-addressable `slot` at the hardware boundary.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RollApproveParams {
    pub frame_index: u32,
    /// Required correlation token from the exact completed preview whose
    /// review warning the user is acknowledging. Unlike preview's optional
    /// token, approval has no safe legacy fallback.
    pub operation_id: String,
    /// Attended binding (feed-detector round; ScanStudio #24/#16/#42).
    /// `false` (the default, and every pre-existing client) is unchanged
    /// behavior: only a frame the completed preview flagged
    /// `needsApproval` may be approved. `true` means the operator is
    /// accepting a frame of a roll whose lattice confidence is too low to
    /// bind unattended, so the frame need not be individually flagged --
    /// but every frame of the batch must then be approved this way, and
    /// the driver still refuses any roll shape other than an automatically
    /// detected medium-confidence one.
    ///
    /// Omitted from the wire entirely when false (`skip_serializing_if`),
    /// so a client that predates this field, and every request that does
    /// not opt in, produces byte-identical params to before it existed.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub attended: bool,
}

/// `roll.approve` intentionally returns no payload. Approval is a
/// non-motion, session-scoped bridge state change, not a new preview or scan
/// job.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub struct RollApproveResult {}

/// Updates one frame's alignment inside the exact completed preview session
/// named by `operationId`. The public app calls scanner slots frame indices;
/// the real backend performs that one-to-one vocabulary translation.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RollSetSpacingOffsetParams {
    /// One-based scanner slot from the completed preview.
    pub frame_index: u32,
    /// Frame 1 accepts `0..=144`; every later frame accepts `-144..=144`.
    pub offset_rows: i64,
    /// Correlation token for the exact completed preview being adjusted.
    pub operation_id: String,
}

/// The bridge regenerates and returns the affected preview tile so callers
/// can render the adjustment immediately without starting another preview.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RollSetSpacingOffsetResult {
    pub thumbnail: Thumbnail,
}

/// Wire contract: exactly one of `imagePath` or the `{brightness, tint}`
/// pair is populated per instance — never both, never neither (T-10-07).
/// The simulator populates `brightness`/`tint` and omits `imagePath`; a
/// real backend populates `imagePath` (BRIDGE.md's bridge-written
/// preview-tile file, forwarded verbatim) and omits `brightness`/`tint`
/// rather than fabricating them. `needsApproval` and `warnings` preserve the
/// bridge preview's transport-bound review evidence so clients can obtain
/// explicit approval before the first scan starts.
fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Thumbnail {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub brightness: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tint: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_path: Option<String>,
    /// Real-preview frame boundary in the bridge's preview row coordinate
    /// space. Omitted by the simulator and older real backends.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub boundary_rows: Option<(u32, u32)>,
    /// Current driver-session transport alignment for this preview slot.
    /// Omitted by the simulator and older real backends.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spacing_offset: Option<i64>,
    /// Lane C, additive: `true` only on a frame whose crop overlaps the
    /// preview with >=90% of its height inside but not all of it. Forwarded
    /// verbatim from the bridge; omitted whenever the bridge omits it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partial: Option<bool>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub needs_approval: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
}

// ---------------------------------------------------------------------
// roll.manualFrames / roll.previewStrip (additive, 2026-08-07 -- Rung 4 of
// the feeding UX ladder). Both are non-motion-capable and synchronous (no
// events): `roll.previewStrip` renders the last completed preview attempt's
// whole captured raster to one image for a manual-placement editor;
// `roll.manualFrames` re-slices that raster at operator-picked boundary
// rows in place of automatic detection. Usable any time a preview attempt
// exists on disk -- including one that ended in `scanner.thumbnailsFailed`
// (REFEED_REQUIRED) -- see BRIDGE.md's own "roll.manualFrames" section.
// Unlike `roll.approve`/`roll.setSpacingOffset`, neither method takes an
// `operationId` param: BRIDGE.md's bridge-level contract has none (no
// "exact completed preview" binding is required to call them), so
// `RollManualFramesResult.operationId` is engine-minted, not
// client-supplied -- it arms the SAME approval binding a successful
// `roll.preview` would have, so the existing `roll.approve`/
// `roll.setSpacingOffset`/manual-review-sheet flow keeps working unchanged
// on the resulting frames (see `RealLs5000::roll_manual_frames`).
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RollManualFramesParams {
    /// At least 2 strictly increasing preview rows (N rows define N-1
    /// frames), in the same `0..PreviewStripResult.rowCount-1` coordinate
    /// space `PreviewStripResult` reports.
    pub rows: Vec<u32>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RollManualFramesResult {
    pub count: u32,
    pub fingerprint: String,
    /// Fresh operation id the engine minted for this placement, binding the
    /// resulting slots the same way a normal preview's operationId does --
    /// pass it to `roll.approve`/`roll.setSpacingOffset` for these frames.
    pub operation_id: String,
    pub thumbnails: Vec<ManualFrameThumbnail>,
    pub snaps: Vec<BoundarySnap>,
}

/// One resulting slot from `roll.manualFrames`, paired with its frame
/// index -- BRIDGE.md's wire `Thumbnail.slot` maps one-to-one onto the
/// public engine protocol's `frameIndex` vocabulary, the same translation
/// `ThumbnailPayload` already performs for the ordinary preview-event path.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ManualFrameThumbnail {
    pub frame_index: u32,
    pub thumbnail: Thumbnail,
}

/// One snap-assist adjustment `roll.manualFrames` applied to a picked
/// boundary row (BRIDGE.md "Types" -> `BoundarySnap`).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BoundarySnap {
    pub boundary_index: u32,
    pub requested_row: u32,
    pub snapped_row: u32,
    pub evidence_run: (u32, u32),
}

/// `roll.previewStrip`'s result (BRIDGE.md "Types" -> `PreviewStrip`). No
/// params type: the request carries `{}` on the wire, matching
/// `scanner.status`'s existing no-params dispatch.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PreviewStripResult {
    pub image_path: String,
    pub row_count: u32,
    pub pixels_per_row: u32,
}

// ---------------------------------------------------------------------
// scan.start / scan.stop / scan.skipCurrentFrame
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanStartParams {
    pub frames: Vec<u32>,
    pub recipe: domain::CaptureRecipe,
    #[serde(default)]
    pub processing: domain::ProcessingRecipe,
    #[serde(default)]
    pub output: domain::OutputRecipe,
    /// Per-frame alignments carried into the scan job. Additive and backward
    /// compatible: omitted (or empty) means today’s behavior exactly. Only
    /// approved offsets are meaningful for backend addressing; the backend
    /// ignores unknown fields per PROTOCOL.md forward compatibility.
    #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
    pub frame_alignments: std::collections::HashMap<u32, domain::FrameAlignment>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanStartResult {
    pub job_id: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum StopMode {
    AfterCurrentFrame,
    Immediate,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanStopParams {
    pub job_id: String,
    pub mode: StopMode,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanStopResult {
    pub acknowledged: bool,
    pub mode: StopMode,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanSkipCurrentFrameParams {
    pub job_id: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanSkipCurrentFrameResult {
    pub acknowledged: bool,
}

// ---------------------------------------------------------------------
// project.create / project.open / project.list
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCreateParams {
    pub name: String,
    pub carrier: domain::MediaCarrier,
    pub frame_count: u32,
    pub film_process: domain::FilmProcess,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCreateResult {
    pub project: domain::ScanProject,
    pub directory: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectOpenParams {
    pub directory: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectOpenResult {
    pub project: domain::ScanProject,
    pub directory: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProjectListParams {
    #[serde(default)]
    pub directory: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectListResult {
    pub projects: Vec<domain::ProjectSummary>,
}

// ---------------------------------------------------------------------
// project.setFrameExcluded / setFrameCaptureOverride /
// setFrameProcessingOverride / setFrameOutputOverride (SHEET-02/SHEET-03).
// Each `Option<T>` param field is deliberately plain (no `#[serde(default)]`):
// every one of these methods has exactly one purpose per call — `null` in
// = clear/revert to roll-wide inheritance, a populated value in = set —
// never a third "leave unchanged" state, so there is no ambiguity to
// resolve with a default.
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetFrameExcludedParams {
    pub frame_index: u32,
    pub excluded: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetFrameCaptureOverrideParams {
    pub frame_index: u32,
    pub capture: Option<domain::CaptureRecipe>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetFrameProcessingOverrideParams {
    pub frame_index: u32,
    pub processing: Option<domain::ProcessingRecipe>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetFrameOutputOverrideParams {
    pub frame_index: u32,
    pub output: Option<domain::OutputRecipe>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetFrameAlignmentParams {
    pub frame_index: u32,
    pub alignment: Option<domain::FrameAlignment>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetRollMetadataParams {
    pub metadata: domain::MetadataSet,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetFrameMetadataOverrideParams {
    pub frame_index: u32,
    pub metadata: Option<domain::MetadataSet>,
}

/// Shared result shape for all `project.setFrame*` methods — each
/// mutates-and-returns-the-whole-project identically, so five near-identical
/// result types would be pure duplication.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SetFrameResult {
    pub project: domain::ScanProject,
}

/// Result for `project.pendingFrames`: the exact set of frame indices that
/// are neither excluded nor already carrying a receipt, plus summary counts
/// so the client can display progress without re-deriving them.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PendingFramesResult {
    pub frames: Vec<u32>,
    pub total_frames: u32,
    pub completed_count: u32,
    pub excluded_count: u32,
}

// ---------------------------------------------------------------------
// project.analyzeFrameDefects (DEF-02). Read-only: unlike the
// `project.setFrame*` quartet above, this method never mutates or persists
// the manifest.
// ---------------------------------------------------------------------

/// Only frame identity is accepted from the client. Effective recipes are
/// derived from the active project, frame overrides, and latest receipt in
/// the server so a renderer cannot analyze settings unrelated to the frame.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AnalyzeFrameDefectsParams {
    pub frame_index: u32,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AnalyzeFrameDefectsResult {
    pub frame_index: u32,
    pub capture: domain::CaptureRecipe,
    pub processing: domain::ProcessingRecipe,
    pub defects: Vec<domain::DefectInstance>,
    pub simulated: bool,
    /// Echoes the resolved `processing.digitalIceEnabled` so an empty
    /// `defects` array is never ambiguous between "ICE is off" and "real
    /// analysis ran and found nothing". Orthogonal to `simulated`, which
    /// reports provenance (was a real on-disk capture pair resolved?), not
    /// whether analysis was enabled this call.
    pub digital_ice_enabled: bool,
    /// True when the frame's single most recent receipt carries a
    /// transport-smear verdict other than `"clean"` (`"smear"` or
    /// `"indeterminate"`). Independent of which receipt supplied the real
    /// capture, if any.
    pub transport_smear_flagged: bool,
    /// The human-readable reason from the smear assessment, present only
    /// when `transport_smear_flagged` is true.
    pub transport_smear_reason: Option<String>,
}

// ---------------------------------------------------------------------
// exiftool.detect / project.previewMetadataCommand / project.applyMetadata
// (META-02/META-03). `exiftool.detect` reuses `crate::exiftool
// ::ExifToolDetection` directly as its result type (a pure capability
// query, not project-scoped, so it has no dedicated params type here).
// ExifTool never targets the archive path — see
// `crate::exiftool::assert_no_archive_target`.
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PreviewMetadataCommandParams {
    pub frame_index: u32,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PreviewMetadataCommandResult {
    pub available: bool,
    pub exiftool_path: Option<String>,
    pub targets: Vec<String>,
    pub arguments: Vec<String>,
    pub fingerprint: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ApplyMetadataParams {
    pub frame_index: u32,
    pub preview_fingerprint: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ApplyMetadataResult {
    pub success: bool,
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub targets: Vec<String>,
    pub arguments: Vec<String>,
    pub fingerprint: String,
}

// ---------------------------------------------------------------------
// Event payloads (PROTOCOL.md "Events"). Needed by golden_fixtures.rs
// (fixtures 05/06/08/09/11) and by sim.rs/server.rs to emit real events.
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScannerStatusPayload {
    pub status: ScannerStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThumbnailPayload {
    pub frame_index: u32,
    pub thumbnail: Thumbnail,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThumbnailsCompletePayload {
    pub count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
}

/// Emitted before `scanner.thumbnailsComplete` when a real-backend preview
/// fails (bridge-reported detection error or a stalled event stream), so a
/// zero-count completion is never mistaken for an empty-but-successful read.
/// Additive event: clients that predate it ignore unknown events per this
/// protocol's forward-compatibility rule.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThumbnailsFailedPayload {
    pub code: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct JobStatePayload {
    pub job_id: String,
    pub state: domain::JobState,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanProgressPayload {
    pub job_id: String,
    pub frame_index: u32,
    pub frame_ordinal: u32,
    pub total_frames: u32,
    pub pass: u32,
    pub total_passes: u32,
    pub frame_percent: f64,
    pub job_percent: f64,
    pub eta_seconds: f64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FrameStatePayload {
    pub job_id: String,
    pub frame_index: u32,
    pub state: domain::FrameState,
    pub attempt: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorPayload>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FrameCompletedPayload {
    pub job_id: String,
    pub frame_index: u32,
    pub receipt: domain::ScanReceipt,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FrameIdleSample {
    pub frame_index: u32,
    pub idle_ms: u64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DutyCycleReport {
    pub per_frame_idle_ms: Vec<FrameIdleSample>,
    pub mean_idle_ms: f64,
    pub max_idle_ms: u64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ScanSummary {
    pub completed: Vec<u32>,
    pub failed: Vec<u32>,
    pub skipped: Vec<u32>,
    pub stopped: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duty_cycle: Option<DutyCycleReport>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence_package_status: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ScanCompletedPayload {
    pub job_id: String,
    pub summary: ScanSummary,
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn error_code_screaming_snake_case() {
        for (code, wire) in [
            (ErrorCode::UnknownMethod, "UNKNOWN_METHOD"),
            (ErrorCode::InvalidParams, "INVALID_PARAMS"),
            (ErrorCode::UnknownDevice, "UNKNOWN_DEVICE"),
            (ErrorCode::NotConnected, "NOT_CONNECTED"),
            (ErrorCode::AlreadyConnected, "ALREADY_CONNECTED"),
            (ErrorCode::NoMedia, "NO_MEDIA"),
            (ErrorCode::ScannerBusy, "SCANNER_BUSY"),
            (ErrorCode::UnknownJob, "UNKNOWN_JOB"),
            (ErrorCode::FeedJam, "FEED_JAM"),
            (
                ErrorCode::FilmFeedInterrupted,
                "FILM_FEED_INTERRUPTED",
            ),
            (ErrorCode::Internal, "INTERNAL"),
            (ErrorCode::ProjectNotFound, "PROJECT_NOT_FOUND"),
            (ErrorCode::ManifestInvalid, "MANIFEST_INVALID"),
            (ErrorCode::ArchiveCollision, "ARCHIVE_COLLISION"),
            (ErrorCode::ManualReviewRequired, "MANUAL_REVIEW_REQUIRED"),
            (ErrorCode::HwMotionNotArmed, "HW_MOTION_NOT_ARMED"),
            (ErrorCode::NotSupported, "NOT_SUPPORTED"),
            (ErrorCode::EjectFailed, "EJECT_FAILED"),
            (ErrorCode::FeederParked, "FEEDER_PARKED"),
        ] {
            assert_eq!(serde_json::to_value(code).unwrap(), json!(wire));
            let decoded: ErrorCode = serde_json::from_value(json!(wire)).unwrap();
            assert_eq!(decoded, code);
        }
    }

    #[test]
    fn roll_approve_requires_a_non_legacy_operation_id_on_the_wire() {
        let params = RollApproveParams {
            frame_index: 7,
            operation_id: "completed-preview-7".to_string(),
            attended: false,
        };
        assert_eq!(
            serde_json::to_value(&params).unwrap(),
            json!({"frameIndex": 7, "operationId": "completed-preview-7"})
        );
        assert!(
            serde_json::from_value::<RollApproveParams>(json!({"frameIndex": 7})).is_err(),
            "approval must not silently deserialize a legacy request without a token"
        );
    }

    #[test]
    fn fault_injection_uses_explicit_renames_not_rename_all() {
        assert_eq!(
            serde_json::to_value(FaultInjection::NoFault).unwrap(),
            json!("none")
        );
        assert_eq!(
            serde_json::to_value(FaultInjection::Demo).unwrap(),
            json!("demo")
        );
        assert_eq!(FaultInjection::default(), FaultInjection::NoFault);
    }

    #[test]
    fn connect_options_defaults_match_protocol() {
        let opts: ConnectOptions = serde_json::from_value(json!({})).unwrap();
        assert_eq!(opts.time_scale, 1.0);
        assert_eq!(opts.fault_injection, FaultInjection::NoFault);
    }

    #[test]
    fn request_params_default_when_omitted() {
        let req: Request =
            serde_json::from_value(json!({"id": 1, "method": "engine.hello"})).unwrap();
        assert_eq!(req.params, serde_json::Value::Null);
    }

    #[test]
    fn stop_mode_camel_case() {
        assert_eq!(
            serde_json::to_value(StopMode::AfterCurrentFrame).unwrap(),
            json!("afterCurrentFrame")
        );
        assert_eq!(
            serde_json::to_value(StopMode::Immediate).unwrap(),
            json!("immediate")
        );
    }

    #[test]
    fn thumbnail_uses_f64_never_f32() {
        let t = Thumbnail {
            brightness: Some(0.573579766536965),
            tint: Some(0.37058823529411766),
            image_path: None,
            boundary_rows: None,
            spacing_offset: None,
            partial: None,
            needs_approval: false,
            warnings: vec![],
        };
        let value = serde_json::to_value(&t).unwrap();
        // f64 precision must survive the round trip exactly (not truncated
        // to f32 precision).
        assert_eq!(value["brightness"].as_f64().unwrap(), 0.573579766536965);
        assert_eq!(value["tint"].as_f64().unwrap(), 0.37058823529411766);
    }

    #[test]
    fn frame_state_payload_omits_error_when_none() {
        let payload = FrameStatePayload {
            job_id: "job-1".into(),
            frame_index: 1,
            state: domain::FrameState::Active,
            attempt: 1,
            error: None,
        };
        let value = serde_json::to_value(&payload).unwrap();
        assert!(value.get("error").is_none());
    }

    #[test]
    fn error_payload_from_engine_error() {
        let engine_err = domain::EngineError::new(ErrorCode::FeedJam, "jam");
        let payload: ErrorPayload = (&engine_err).into();
        assert_eq!(payload.code, ErrorCode::FeedJam);
        assert_eq!(payload.message, "jam");
        assert!(payload.recoverable);
    }

    fn sample_project() -> domain::ScanProject {
        domain::ScanProject {
            schema_version: 1,
            id: "proj-1".into(),
            name: "Test Roll".into(),
            carrier: domain::MediaCarrier::Roll36,
            frame_count: 2,
            film_process: domain::FilmProcess::C41ColorNegative,
            recipes: domain::OutputRecipe::default(),
            roll_metadata: domain::MetadataSet::default(),
            created_at: "2026-07-22T09:00:00Z".into(),
            frames: vec![
                domain::ProjectFrame {
                    index: 1,
                    excluded: false,
                    capture_override: None,
                    processing_override: None,
                    output_override: None,
                    alignment: None,
                    metadata_override: None,
                    receipts: vec![],
                },
                domain::ProjectFrame {
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
        }
    }

    #[test]
    fn project_create_params_round_trips_and_omits_directory_key_when_none() {
        let with_directory = ProjectCreateParams {
            name: "Test Roll".into(),
            carrier: domain::MediaCarrier::Roll36,
            frame_count: 36,
            film_process: domain::FilmProcess::Positive,
            directory: Some("/tmp/scanstudio-test/proj-1".into()),
        };
        let value = serde_json::to_value(&with_directory).unwrap();
        assert_eq!(value["directory"], json!("/tmp/scanstudio-test/proj-1"));
        let decoded: ProjectCreateParams = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, with_directory);

        let without_directory = ProjectCreateParams {
            directory: None,
            ..with_directory
        };
        let value = serde_json::to_value(&without_directory).unwrap();
        assert!(
            value.get("directory").is_none(),
            "omitted directory must not serialize as a null key: {value}"
        );
        let decoded: ProjectCreateParams = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, without_directory);
    }

    #[test]
    fn project_create_result_round_trips() {
        let result = ProjectCreateResult {
            project: sample_project(),
            directory: "/tmp/scanstudio-test/proj-1".into(),
        };
        let value = serde_json::to_value(&result).unwrap();
        let decoded: ProjectCreateResult = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, result);
    }

    #[test]
    fn project_open_params_round_trips() {
        let params = ProjectOpenParams {
            directory: "/tmp/scanstudio-test/proj-1".into(),
        };
        let value = serde_json::to_value(&params).unwrap();
        let decoded: ProjectOpenParams = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, params);
    }

    #[test]
    fn project_open_result_round_trips() {
        let result = ProjectOpenResult {
            project: sample_project(),
            directory: "/tmp/scanstudio-test/proj-1".into(),
        };
        let value = serde_json::to_value(&result).unwrap();
        let decoded: ProjectOpenResult = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, result);
    }

    #[test]
    fn project_list_params_defaults_when_omitted_and_round_trips_when_populated() {
        let omitted: ProjectListParams = serde_json::from_value(json!({})).unwrap();
        assert_eq!(omitted.directory, None);

        let params = ProjectListParams {
            directory: Some("/tmp/scanstudio-test".into()),
        };
        let value = serde_json::to_value(&params).unwrap();
        let decoded: ProjectListParams = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, params);
    }

    #[test]
    fn project_list_result_round_trips() {
        let result = ProjectListResult {
            projects: vec![domain::ProjectSummary {
                id: "proj-1".into(),
                name: "Test Roll".into(),
                carrier: domain::MediaCarrier::Roll36,
                frame_count: 36,
                film_process: domain::FilmProcess::Positive,
                created_at: "2026-07-22T09:00:00Z".into(),
                directory: "/tmp/scanstudio-test/proj-1".into(),
            }],
        };
        let value = serde_json::to_value(&result).unwrap();
        let decoded: ProjectListResult = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, result);
    }

    #[test]
    fn scan_summary_with_none_duty_cycle_omits_key_entirely() {
        let summary = ScanSummary {
            completed: vec![1],
            failed: vec![],
            skipped: vec![],
            stopped: false,
            duty_cycle: None,
            evidence_package_status: None,
        };
        let value = serde_json::to_value(&summary).unwrap();
        assert!(
            value.get("dutyCycle").is_none(),
            "dutyCycle must be omitted when None: {value}"
        );
        // Default deserialization must still work for existing wire/fixture shapes.
        let decoded: ScanSummary = serde_json::from_value(value).unwrap();
        assert_eq!(decoded.duty_cycle, None);
    }

    #[test]
    fn scan_summary_duty_cycle_round_trips_with_camel_case_keys() {
        let summary = ScanSummary {
            completed: vec![1],
            failed: vec![],
            skipped: vec![],
            stopped: false,
            duty_cycle: Some(DutyCycleReport {
                per_frame_idle_ms: vec![FrameIdleSample {
                    frame_index: 2,
                    idle_ms: 250,
                }],
                mean_idle_ms: 250.0,
                max_idle_ms: 250,
            }),
            evidence_package_status: None,
        };
        let value = serde_json::to_value(&summary).unwrap();
        let duty = &value["dutyCycle"];
        assert_eq!(duty["perFrameIdleMs"][0]["frameIndex"], json!(2));
        assert_eq!(duty["perFrameIdleMs"][0]["idleMs"], json!(250));
        assert_eq!(duty["meanIdleMs"], json!(250.0));
        assert_eq!(duty["maxIdleMs"], json!(250));

        let decoded: ScanSummary = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, summary);
    }
    #[test]
    fn acquire_thumbnails_additive_fields_round_trip_with_exact_wire_values() {
        let omitted: AcquireThumbnailsParams =
            serde_json::from_value(serde_json::json!({})).unwrap();
        assert_eq!(omitted.film_process, None);
        assert_eq!(omitted.operation_id, None);

        let bw: AcquireThumbnailsParams = serde_json::from_value(serde_json::json!({
            "filmProcess": "bwNegative",
            "operationId": "preview-op-123"
        }))
        .unwrap();
        assert_eq!(bw.film_process, Some(domain::FilmProcess::BwNegative));
        assert_eq!(bw.operation_id.as_deref(), Some("preview-op-123"));
        let encoded = serde_json::to_value(bw).unwrap();
        assert_eq!(encoded["filmProcess"], serde_json::json!("bwNegative"));
        assert_eq!(encoded["operationId"], serde_json::json!("preview-op-123"));
    }

    #[test]
    fn preview_terminal_payloads_preserve_the_same_operation_id() {
        let operation_id = Some("preview-op-456".to_string());
        let failed = serde_json::to_value(ThumbnailsFailedPayload {
            code: "PREVIEW_FAILED".to_string(),
            message: "preview failed".to_string(),
            operation_id: operation_id.clone(),
        })
        .unwrap();
        let complete = serde_json::to_value(ThumbnailsCompletePayload {
            count: 0,
            operation_id,
        })
        .unwrap();

        assert_eq!(failed["operationId"], serde_json::json!("preview-op-456"));
        assert_eq!(complete["operationId"], serde_json::json!("preview-op-456"));
    }

    #[test]
    fn roll_manual_frames_params_round_trips_rows() {
        let params = RollManualFramesParams {
            rows: vec![100, 300, 500],
        };
        assert_eq!(
            serde_json::to_value(&params).unwrap(),
            json!({"rows": [100, 300, 500]})
        );
        let decoded: RollManualFramesParams =
            serde_json::from_value(json!({"rows": [100, 300, 500]})).unwrap();
        assert_eq!(decoded, params);
    }

    #[test]
    fn roll_manual_frames_result_carries_frame_index_and_operation_id() {
        let result = RollManualFramesResult {
            count: 1,
            fingerprint: "manual-fp".to_string(),
            operation_id: "manual-1".to_string(),
            thumbnails: vec![ManualFrameThumbnail {
                frame_index: 1,
                thumbnail: Thumbnail {
                    brightness: None,
                    tint: None,
                    image_path: Some("/tmp/manual/slot-0001.tif".to_string()),
                    boundary_rows: Some((100, 300)),
                    spacing_offset: Some(0),
                    partial: None,
                    needs_approval: true,
                    warnings: vec!["user-picked".to_string()],
                },
            }],
            snaps: vec![BoundarySnap {
                boundary_index: 0,
                requested_row: 100,
                snapped_row: 102,
                evidence_run: (98, 106),
            }],
        };
        let value = serde_json::to_value(&result).unwrap();
        assert_eq!(value["operationId"], json!("manual-1"));
        assert_eq!(value["thumbnails"][0]["frameIndex"], json!(1));
        assert_eq!(
            value["thumbnails"][0]["thumbnail"]["needsApproval"],
            json!(true)
        );
        assert_eq!(
            value["thumbnails"][0]["thumbnail"]["warnings"],
            json!(["user-picked"])
        );
        assert_eq!(value["snaps"][0]["snappedRow"], json!(102));
        let decoded: RollManualFramesResult = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, result);
    }

    #[test]
    fn preview_strip_result_round_trips_camel_case() {
        let result = PreviewStripResult {
            image_path: "/tmp/strip.tif".to_string(),
            row_count: 4800,
            pixels_per_row: 1,
        };
        let value = serde_json::to_value(&result).unwrap();
        assert_eq!(
            value,
            json!({
                "imagePath": "/tmp/strip.tif",
                "rowCount": 4800,
                "pixelsPerRow": 1,
            })
        );
        let decoded: PreviewStripResult = serde_json::from_value(value).unwrap();
        assert_eq!(decoded, result);
    }
}
