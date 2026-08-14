//! Wire envelope, method payloads, event payloads, and error codes for the
//! Scan Studio Bridge Protocol (`protocol/BRIDGE.md`, v1) — the contract
//! between the external `scanstudio-bridge` sidecar (GPL-3.0, wraps
//! CoolscanPy, lives outside this repo) and Phase 9's `RealLs5000` backend.
//!
//! BRIDGE.md is explicit that this "is a second, independent
//! NDJSON-over-stdio boundary that mirrors PROTOCOL.md's style — it is not
//! an extension of PROTOCOL.md and the two protocols never share a wire
//! connection." Accordingly this module deliberately does not `use
//! crate::domain::*` or `use crate::protocol::*` anywhere — every type
//! below is `Bridge`-prefixed instead, specifically so `real_backend.rs`
//! (Plan 09-03) can import both `crate::domain::*` and
//! `crate::bridge_protocol::*` in the same file with zero name collisions.
//!
//! JSON field names are camelCase on the wire (see BRIDGE.md "Transport").

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------
// Wire envelope — three independent shapes, no shared enum (they don't
// share a discriminant field). Shape mirrors protocol.rs's own envelope;
// kept as a fully separate type family per BRIDGE.md's independence
// requirement.
// ---------------------------------------------------------------------

/// Inbound shape (engine -> bridge). `params` may be omitted on the wire
/// (BRIDGE.md "Transport"); re-deserialized per-method via
/// `serde_json::from_value`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct BridgeRequest {
    pub id: u64,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

/// Outbound success shape (bridge -> engine): `{"id": .., "result": ..}`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct BridgeResponse<T> {
    pub id: u64,
    pub result: T,
}

impl<T> BridgeResponse<T> {
    pub fn new(id: u64, result: T) -> Self {
        BridgeResponse { id, result }
    }
}

/// Outbound error shape (bridge -> engine): `{"id": .., "error": {..}}`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct BridgeErrorResponse {
    pub id: u64,
    pub error: BridgeErrorPayload,
}

impl BridgeErrorResponse {
    pub fn new(id: u64, error: BridgeErrorPayload) -> Self {
        BridgeErrorResponse { id, error }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeErrorPayload {
    pub code: BridgeErrorCode,
    pub message: String,
    pub recoverable: bool,
}

/// Outbound event shape (bridge -> engine, unsolicited):
/// `{"event": .., "payload": ..}`. Events may interleave with responses.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct BridgeEvent<T> {
    pub event: String,
    pub payload: T,
}

impl<T> BridgeEvent<T> {
    pub fn new(event: impl Into<String>, payload: T) -> Self {
        BridgeEvent {
            event: event.into(),
            payload,
        }
    }
}

// ---------------------------------------------------------------------
// Error codes — the 22 codes this engine names in its closed enum.
// BRIDGE.md documents additional wire codes (24 in total) that travel
// through the String-typed runtime paths below without an enum
// variant (see `BridgeErrorEventPayload.code`). `recoverable` is
// `true` only for `HARDWARE_LANE_BUSY`: retrying the identical request
// once the lane frees can succeed with no other action. Every other code
// needs a different action first, so it is always `recoverable: false`.
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum BridgeErrorCode {
    UnknownMethod,
    InvalidParams,
    NotConnected,
    AlreadyConnected,
    DeviceNotFound,
    DeviceBusy,
    NoPreview,
    UnknownJob,
    HwMotionNotArmed,
    HardwareLaneBusy,
    EjectFailed,
    FeederParked,
    AdapterUnsupported,
    FingerprintRefused,
    ManualReviewRequired,
    RefeedRequired,
    TransportSmearDetected,
    GeometryValidationError,
    SplitAlignmentError,
    BatchIntegrityError,
    NotImplemented,
    Internal,
}

// ---------------------------------------------------------------------
// Device vocabulary (BRIDGE.md "Types": Capabilities, DeviceInfo,
// DeviceStatus).
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeCapabilities {
    pub ir_channel: bool,
    pub supported_dpi: Vec<u32>,
    pub supported_depths: Vec<u32>,
    pub multi_sample: bool,
    pub adapter_frame_capacity: Option<u32>,
    pub adapter_frame_control: bool,
    pub auto_exposure: bool,
    pub registered_geometry: bool,
    pub can_eject: bool,
    /// Device-sourced accepted set for `CaptureRecipe.multisample_passes`
    /// (BRIDGE.md "Recipe constraints") — always `[4]` for the LS-5000
    /// today, replacing what was previously hardcoded client-side; a
    /// future device with different pass options supplies its own list
    /// here instead of requiring a code change.
    pub supported_multisample_passes: Vec<u32>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeDeviceInfo {
    pub device_id: String,
    pub vendor: String,
    pub model: String,
    pub capabilities: BridgeCapabilities,
    /// False for a recognized-but-unsupported Nikon model (Lane D, #14): the
    /// bridge reports it so it is visible but never connectable. The bridge
    /// always sends this; the default keeps older test fixtures valid.
    #[serde(default = "bridge_device_default_supported")]
    pub supported: bool,
}

fn bridge_device_default_supported() -> bool {
    true
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeDeviceStatus {
    pub connected: bool,
    pub device_id: Option<String>,
    pub preview_established: bool,
    pub slot_count: Option<u32>,
    pub active_job_id: Option<String>,
    pub lane_held: bool,
    /// Live re-check result, never a cached value (BRIDGE.md "SAFE-02
    /// guardrails").
    pub motion_armed: bool,
    /// Live, no-motion film-presence read, distinct from
    /// `preview_established` (only means "a preview has run this
    /// session," never "film is physically loaded right now"). `None`
    /// means the transport could not establish a trustworthy verdict,
    /// never that film is absent (BRIDGE.md `DeviceStatus`).
    pub film_present: Option<bool>,
    /// The scanner's own page-01h adapter identity string ("Mount",
    /// "6Strip", "36Strip", "240", "Feeder"), re-read per status
    /// snapshot because adapters are hot-swappable. `None` (or the
    /// field missing entirely, for older bridges) means unreadable,
    /// never a particular adapter (BRIDGE.md `DeviceStatus.adapter`).
    #[serde(default)]
    pub adapter: Option<String>,
}

// ---------------------------------------------------------------------
// Capture recipe / output spec (BRIDGE.md "Types": CaptureRecipe,
// OutputSpec).
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BridgeChannels {
    Rgb,
    Rgbi,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeCaptureRecipe {
    pub resolution_dpi: u32,
    pub bit_depth: u32,
    pub multisample_passes: u32,
    pub channels: BridgeChannels,
    pub autofocus: bool,
    pub auto_exposure: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum BridgeRawExportFormat {
    LinearDng,
    LinearTiff,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum BridgeRawTiffInfrared {
    FourthChannel,
    Omitted,
    Sidecar,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeRawExportSpec {
    pub destination: String,
    pub filename_template: String,
    pub file_format: BridgeRawExportFormat,
    pub tiff_infrared: BridgeRawTiffInfrared,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeOutputSpec {
    pub destination: String,
    /// `"####"` -> zero-padded slot number (BRIDGE.md "Types").
    pub filename_template: String,
    /// Optional per-slot archive templates for one batched hardware scan.
    /// Keys are decimal slot strings because JSON object keys are strings.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slot_outputs: Option<std::collections::HashMap<String, BridgeSlotOutputSpec>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_export: Option<BridgeRawExportSpec>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeSlotOutputSpec {
    pub destination: String,
    pub filename_template: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_export: Option<BridgeRawExportSpec>,
}

// ---------------------------------------------------------------------
// Roll preview vocabulary (BRIDGE.md "Types": Thumbnail).
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeThumbnail {
    pub slot: u32,
    pub boundary_rows: (u32, u32),
    pub spacing_offset: i64,
    pub needs_approval: bool,
    pub warnings: Vec<String>,
    /// Bridge-added, not CoolscanPy-native: the normalized 8-bit TIFF the
    /// bridge writes for this slot's preview crop (BRIDGE.md "Types" note
    /// under `Thumbnail`) — a path, never image bytes on the wire.
    pub image_path: String,
    /// Lane C, additive (BRIDGE.md): `true` only on a frame whose crop
    /// overlaps the preview with >=90% of its height inside but not all of
    /// it. Absent everywhere else; older bridges never send it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partial: Option<bool>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeRollSetSpacingOffsetParams {
    pub slot: u32,
    pub offset_rows: i64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeRollSetSpacingOffsetResult {
    pub thumbnail: BridgeThumbnail,
}

// ---------------------------------------------------------------------
// roll.manualFrames / roll.previewStrip (additive, 2026-08-07 -- Rung 4 of
// the feeding UX ladder, BRIDGE.md "roll.manualFrames"/"roll.previewStrip").
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeManualFramesParams {
    pub rows: Vec<u32>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeManualFramesResult {
    pub count: u32,
    pub fingerprint: String,
    pub thumbnails: Vec<BridgeThumbnail>,
    pub snaps: Vec<BridgeBoundarySnap>,
}

/// One snap-assist adjustment `roll.manualFrames` applied to a picked
/// boundary row (BRIDGE.md "Types" -> `BoundarySnap`).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeBoundarySnap {
    pub boundary_index: u32,
    pub requested_row: u32,
    pub snapped_row: u32,
    pub evidence_run: (u32, u32),
}

/// `roll.previewStrip`'s result (BRIDGE.md "Types" -> `PreviewStrip`). No
/// params type: the request carries `{}` on the wire, same as
/// `device.eject`/`bridge.shutdown`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgePreviewStripResult {
    pub image_path: String,
    pub row_count: u32,
    pub pixels_per_row: u32,
}

// ---------------------------------------------------------------------
// Scan progress + telemetry vocabulary (BRIDGE.md "Types": ScanProgress,
// ExposureVector, ClippingTelemetry, FocusDetailTelemetry,
// TransportSmearAssessment, ArtifactEvidence, ApprovalReceipt,
// ScanReceipt).
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeScanProgress {
    pub job_id: String,
    pub slot: u32,
    pub ordinal: u32,
    pub total_slots: u32,
    pub fraction: f64,
    pub message: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeExposureVector {
    pub focus_position: i64,
    pub exposure_multiplier: f64,
    pub red_exposure_us: f64,
    pub green_exposure_us: f64,
    pub blue_exposure_us: f64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeClippingTelemetry {
    pub fractions: (f64, f64, f64),
    pub clip_level: f64,
    pub warning_fraction: f64,
    pub warning: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeFocusDetailTelemetry {
    pub method: String,
    pub verdict: String,
    pub score: Option<f64>,
    pub texture_span: f64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeTransportSmearAssessment {
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

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeArtifactEvidence {
    pub sha256: String,
    pub byte_length: u64,
    pub shape: Vec<u32>,
    pub dtype: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeApprovalReceipt {
    pub reviewed_fingerprint_sha256: String,
    pub slot: u32,
    pub spacing_offset: i64,
    pub thumbnail_sha256: String,
    pub reviewed_lookup_row: u32,
    pub reviewed_native_origin: u32,
    pub review_reasons: Vec<String>,
}

/// Bridge-facing mirror of `domain::ExposureAuthority`. This protocol
/// module stays independent of the domain module, so the two shapes are
/// mapped explicitly in `real_backend.rs`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeExposureAuthority {
    pub rgb_source: String,
    pub ir_source: String,
    pub commanded_channels_raw_10ns: std::collections::BTreeMap<String, u32>,
    pub active_controller_channels_raw_10ns: std::collections::BTreeMap<String, u32>,
    pub device_bound_clamped_channels_raw_10ns: std::collections::BTreeMap<String, u32>,
    pub device_exposure_bounds_raw_10ns: [u32; 2],
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeScanReceipt {
    pub version: u32,
    pub slot: u32,
    pub spacing_offset: i64,
    pub dpi: u32,
    pub depth: u32,
    pub device_id: String,
    pub device_model: String,
    pub reviewed_fingerprint_sha256: String,
    pub fresh_fingerprint_sha256: String,
    pub manual_approval: Option<BridgeApprovalReceipt>,
    pub exposure: BridgeExposureVector,
    /// Opaque, always `null` for the one wired route (single-pass RGBI4
    /// shares one pass for RGB and IR) — see BRIDGE.md "Types" note under
    /// `ScanReceipt`.
    pub split_alignment: Option<serde_json::Value>,
    pub clipping: BridgeClippingTelemetry,
    pub focus_detail: BridgeFocusDetailTelemetry,
    pub transport_smear: BridgeTransportSmearAssessment,
    pub artifacts: std::collections::HashMap<String, BridgeArtifactEvidence>,
    /// Versioned transform applied between scanner-native planes and the
    /// stored RGB/IR raster orientation. Consumers must branch on this
    /// value rather than guessing between transforms that differ by a flip.
    #[serde(default)]
    pub storage_transform: String,
    /// Bridge-added — CoolscanPy's roll engine returns in-memory arrays,
    /// never files; the bridge is what writes them to disk (BRIDGE.md
    /// "Types" note).
    pub rgb_path: String,
    pub ir_path: Option<String>,
    /// CoolscanPy's `Frame.meter_rgbi` (a 285dpi auto-exposure prepass),
    /// written by the bridge to `{stem}_METER.tif` unconditionally
    /// whenever CoolscanPy supplies it — never fabricated; `None` only if
    /// absent (BRIDGE.md "Types" note under `ScanReceipt`).
    pub meter_rgbi_path: Option<String>,
    #[serde(default)]
    pub attempts_root: Option<String>,
    /// Best-effort exposure provenance forwarded from CoolscanPy's
    /// per-frame journal. Malformed or absent values must not invalidate an
    /// otherwise complete frame receipt.
    #[serde(default, deserialize_with = "deserialize_exposure_authority_fail_soft")]
    pub exposure_authority: Option<BridgeExposureAuthority>,
    /// Wall-clock capture start (ISO-8601 UTC) and per-frame hardware capture
    /// duration in milliseconds, forwarded verbatim from CoolscanPy's journal
    /// at the authoritative capture boundary. Optional so older bridge
    /// payloads and mock receipts stay valid; absent stays `None` (never an
    /// engine-receipt-arrival time).
    #[serde(default)]
    pub started_at: Option<String>,
    #[serde(default)]
    pub capture_duration_ms: Option<u64>,
    #[serde(default)]
    pub raw_export_path: Option<String>,
    #[serde(default)]
    pub raw_export_ir_path: Option<String>,
}

fn deserialize_exposure_authority_fail_soft<'de, D>(
    deserializer: D,
) -> Result<Option<BridgeExposureAuthority>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw: Option<serde_json::Value> = Option::deserialize(deserializer)?;
    Ok(raw.and_then(|value| match serde_json::from_value(value) {
        Ok(parsed) => Some(parsed),
        Err(err) => {
            eprintln!(
                "scanstudio-engine: malformed exposureAuthority on a bridge receipt, \
                 treating as absent rather than failing the whole frame-completed event: {err}"
            );
            None
        }
    }))
}

// ---------------------------------------------------------------------
// bridge.hello
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeHelloParams {
    pub client_name: String,
    pub protocol_version: u32,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeHelloResult {
    pub bridge_name: String,
    pub bridge_version: String,
    pub protocol_version: u32,
    pub capabilities: Vec<String>,
}

// ---------------------------------------------------------------------
// device.list / device.open
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeDeviceListResult {
    pub devices: Vec<BridgeDeviceInfo>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeDeviceOpenParams {
    pub device_id: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeDeviceOpenResult {
    pub device: BridgeDeviceInfo,
    pub status: BridgeDeviceStatus,
}

// ---------------------------------------------------------------------
// roll.preview / roll.approve
// ---------------------------------------------------------------------

/// Explicit per-variant renames, not `rename_all`, since neither variant's
/// wire string is a simple lowercase conversion of its Rust name.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeMaterial {
    #[serde(rename = "colorNegative")]
    ColorNegative,
    #[serde(rename = "blackAndWhiteNegative")]
    BlackAndWhiteNegative,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeRollPreviewParams {
    pub material: BridgeMaterial,
    /// Filters only *which* `roll.thumbnail` events fire — the bridge
    /// always physically reads the full roll regardless (BRIDGE.md
    /// "Methods" -> `roll.preview`).
    #[serde(default)]
    pub slots: Option<Vec<u32>>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeRollPreviewAck {
    pub accepted: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeRollApproveParams {
    pub slot: u32,
    /// Additive (2026-08-08 adversarial review, S1): the Roll fingerprint
    /// the approval being submitted was minted against. `None` for the
    /// existing automatic-preview approval path -- omitted from the wire
    /// entirely (`skip_serializing_if`) so a bridge or bridge test double
    /// that predates this field sees byte-identical params to before it
    /// existed. Only `RealLs5000::roll_manual_frames`'s own binding
    /// populates this today; the bridge refuses the approval with
    /// `FINGERPRINT_REFUSED` when it is present and does not match the
    /// roll's current fingerprint (BRIDGE.md `roll.approve`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fingerprint: Option<String>,
    /// Attended binding (feed-detector round; ScanStudio #24/#16/#42).
    /// Omitted from the wire entirely when false (`skip_serializing_if`),
    /// so a bridge or bridge test double that predates this field sees
    /// byte-identical params to before it existed.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub attended: bool,
}

// ---------------------------------------------------------------------
// scan.start / scan.stop
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeScanStartParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    pub slots: Vec<u32>,
    pub recipe: BridgeCaptureRecipe,
    pub output: BridgeOutputSpec,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeScanStartResult {
    pub job_id: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeScanStopParams {
    pub job_id: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeScanStopResult {
    pub acknowledged: bool,
}

// ---------------------------------------------------------------------
// Event payloads (BRIDGE.md "Events").
// ---------------------------------------------------------------------

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeDeviceStatusPayload {
    pub status: BridgeDeviceStatus,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeThumbnailEventPayload {
    pub slot: u32,
    pub thumbnail: BridgeThumbnail,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgePreviewCompletePayload {
    pub count: u32,
    /// The roll's bound identity, later compared against a fresh read at
    /// scan time (`FINGERPRINT_REFUSED` on mismatch).
    pub fingerprint: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeFrameRetryingPayload {
    pub job_id: String,
    pub slot: u32,
    pub attempt: u32,
    pub reason: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeFrameCompletedPayload {
    pub job_id: String,
    pub slot: u32,
    pub receipt: BridgeScanReceipt,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeScanCompletedSummary {
    pub completed: Vec<u32>,
    pub failed: Vec<u32>,
    pub stopped: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeScanCompletedPayload {
    pub job_id: String,
    pub summary: BridgeScanCompletedSummary,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeHardwareAnomalyPayload {
    pub job_id: Option<String>,
    pub slot: Option<u32>,
    pub code: String,
    pub message: String,
    pub ejected: bool,
}

/// `scan.error`'s payload (BRIDGE.md "`scan.error` (additive,
/// 2026-07-23)"): a supplementary diagnostic report, NOT a replacement for
/// `scan.completed` — BRIDGE.md is explicit that a client "may therefore
/// see `scan.error` and, arbitrarily later (or never), also see
/// `scan.completed` for the same `jobId`." `code` is typed as a raw
/// `String` here, deliberately unlike `BridgeErrorPayload.code`'s closed
/// `BridgeErrorCode` enum: this event's whole reason for existing is to
/// report a failure that must never itself be dropped by a strict-enum
/// deserialization failure on some future/unrecognized code value (10-08:
/// this exact silent-drop failure mode is what let `scan.error` vanish
/// before ever reaching the client).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeScanErrorPayload {
    pub job_id: String,
    pub code: String,
    pub message: String,
}

/// `scan.frameFailed`'s payload (BRIDGE.md "`scan.frameFailed` (additive,
/// 2026-07-23)"): a durable per-frame failure reason emitted for any slot
/// failure during `scan.start`, before `scan.completed`. Non-terminal by
/// design — the bridge still emits its authoritative `scan.completed`
/// afterward. `code` is a raw `String` for the same forward-compatibility
/// reason as `BridgeScanErrorPayload.code`: an unrecognized future bridge
/// code must not silently drop the event.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BridgeFrameFailedPayload {
    pub job_id: String,
    pub slot: u32,
    pub code: String,
    pub message: String,
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
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
    fn bridge_error_code_screaming_snake_case_all_21_variants() {
        for (code, wire) in [
            (BridgeErrorCode::UnknownMethod, "UNKNOWN_METHOD"),
            (BridgeErrorCode::InvalidParams, "INVALID_PARAMS"),
            (BridgeErrorCode::NotConnected, "NOT_CONNECTED"),
            (BridgeErrorCode::AlreadyConnected, "ALREADY_CONNECTED"),
            (BridgeErrorCode::DeviceNotFound, "DEVICE_NOT_FOUND"),
            (BridgeErrorCode::DeviceBusy, "DEVICE_BUSY"),
            (BridgeErrorCode::NoPreview, "NO_PREVIEW"),
            (BridgeErrorCode::UnknownJob, "UNKNOWN_JOB"),
            (BridgeErrorCode::HwMotionNotArmed, "HW_MOTION_NOT_ARMED"),
            (BridgeErrorCode::HardwareLaneBusy, "HARDWARE_LANE_BUSY"),
            (BridgeErrorCode::EjectFailed, "EJECT_FAILED"),
            (BridgeErrorCode::FeederParked, "FEEDER_PARKED"),
            (BridgeErrorCode::AdapterUnsupported, "ADAPTER_UNSUPPORTED"),
            (BridgeErrorCode::FingerprintRefused, "FINGERPRINT_REFUSED"),
            (
                BridgeErrorCode::ManualReviewRequired,
                "MANUAL_REVIEW_REQUIRED",
            ),
            (BridgeErrorCode::RefeedRequired, "REFEED_REQUIRED"),
            (
                BridgeErrorCode::TransportSmearDetected,
                "TRANSPORT_SMEAR_DETECTED",
            ),
            (
                BridgeErrorCode::GeometryValidationError,
                "GEOMETRY_VALIDATION_ERROR",
            ),
            (
                BridgeErrorCode::SplitAlignmentError,
                "SPLIT_ALIGNMENT_ERROR",
            ),
            (
                BridgeErrorCode::BatchIntegrityError,
                "BATCH_INTEGRITY_ERROR",
            ),
            (BridgeErrorCode::NotImplemented, "NOT_IMPLEMENTED"),
            (BridgeErrorCode::Internal, "INTERNAL"),
        ] {
            assert_eq!(serde_json::to_value(code).unwrap(), json!(wire));
            let decoded: BridgeErrorCode = serde_json::from_value(json!(wire)).unwrap();
            assert_eq!(decoded, code);
        }
    }

    #[test]
    fn bridge_material_uses_explicit_renames_not_rename_all() {
        assert_eq!(
            serde_json::to_value(BridgeMaterial::ColorNegative).unwrap(),
            json!("colorNegative")
        );
        assert_eq!(
            serde_json::to_value(BridgeMaterial::BlackAndWhiteNegative).unwrap(),
            json!("blackAndWhiteNegative")
        );
        let decoded: BridgeMaterial = serde_json::from_value(json!("colorNegative")).unwrap();
        assert_eq!(decoded, BridgeMaterial::ColorNegative);
        let decoded: BridgeMaterial =
            serde_json::from_value(json!("blackAndWhiteNegative")).unwrap();
        assert_eq!(decoded, BridgeMaterial::BlackAndWhiteNegative);
    }

    #[test]
    fn bridge_channels_round_trips_lowercase() {
        for (variant, wire) in [(BridgeChannels::Rgb, "rgb"), (BridgeChannels::Rgbi, "rgbi")] {
            assert_eq!(serde_json::to_value(variant).unwrap(), json!(wire));
            round_trip(&variant);
        }
    }

    #[test]
    fn bridge_request_params_default_when_omitted() {
        let req: BridgeRequest =
            serde_json::from_value(json!({"id": 1, "method": "bridge.hello"})).unwrap();
        assert_eq!(req.params, serde_json::Value::Null);
    }

    #[test]
    fn bridge_thumbnail_round_trips_with_needs_approval_and_warnings() {
        let thumbnail = BridgeThumbnail {
            slot: 7,
            boundary_rows: (12, 884),
            spacing_offset: 3,
            needs_approval: true,
            warnings: vec![
                "low-contrast-edge".to_string(),
                "possible-double-exposure".to_string(),
            ],
            image_path: "/tmp/slot-0007.tif".to_string(),
            partial: None,
        };
        let value = serde_json::to_value(&thumbnail).unwrap();
        assert_eq!(value["needsApproval"], json!(true));
        assert_eq!(value["boundaryRows"], json!([12, 884]));
        assert_eq!(
            value["warnings"],
            json!(["low-contrast-edge", "possible-double-exposure"])
        );
        round_trip(&thumbnail);
    }

    /// Literal field values taken from BRIDGE.md's "Examples" section
    /// (`scan.start` through completion, one slot) — this is the same
    /// receipt shape `mock_bridge.rs` (Task 2) emits, so getting it exactly
    /// right here prevents a Task 2 rework.
    #[test]
    fn bridge_scan_receipt_round_trips_bridge_md_worked_example() {
        let mut artifacts = std::collections::HashMap::new();
        artifacts.insert(
            "rgb".to_string(),
            BridgeArtifactEvidence {
                sha256: "a1b2c3d4e5f60718293a4b5c6d7e8f90".into(),
                byte_length: 25165824,
                shape: vec![2954, 4429, 3],
                dtype: "uint16".into(),
            },
        );

        let receipt = BridgeScanReceipt {
            version: 1,
            slot: 1,
            spacing_offset: 3,
            dpi: 4000,
            depth: 16,
            device_id: "ls5000-usb-0".into(),
            device_model: "SUPER COOLSCAN 5000 ED".into(),
            reviewed_fingerprint_sha256: "3f9a7e2c8b1d4560a9e4c1d7f6b2a830".into(),
            fresh_fingerprint_sha256: "3f9a7e2c8b1d4560a9e4c1d7f6b2a830".into(),
            manual_approval: None,
            exposure: BridgeExposureVector {
                focus_position: 812,
                exposure_multiplier: 1.0,
                red_exposure_us: 1200.0,
                green_exposure_us: 950.0,
                blue_exposure_us: 1400.0,
            },
            split_alignment: None,
            clipping: BridgeClippingTelemetry {
                fractions: (0.001, 0.0, 0.0),
                clip_level: 0.995,
                warning_fraction: 0.02,
                warning: false,
            },
            focus_detail: BridgeFocusDetailTelemetry {
                method: "laplacian-variance".into(),
                verdict: "measured".into(),
                score: Some(184.2),
                texture_span: 0.71,
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
            rgb_path: "/tmp/scanstudio-test-output/roll-042/frame-0001.tif".into(),
            ir_path: None,
            meter_rgbi_path: None,
            raw_export_path: Some("/Scans/Raw/ScanStudio1.dng".into()),
            raw_export_ir_path: Some("/Scans/Raw/ScanStudio1-ir.tif".into()),
            attempts_root: None,
            exposure_authority: None,
            started_at: Some("2026-07-22T09:00:00+00:00".into()),
            capture_duration_ms: Some(1900),
        };

        let value = serde_json::to_value(&receipt).unwrap();
        assert_eq!(value["deviceId"], json!("ls5000-usb-0"));
        assert_eq!(value["spacingOffset"], json!(3));
        assert_eq!(value["manualApproval"], serde_json::Value::Null);
        assert_eq!(value["splitAlignment"], serde_json::Value::Null);
        assert_eq!(
            value["storageTransform"],
            json!("swapaxes01-scanner-native-to-nikon-render-parity-v2")
        );
        assert_eq!(value["irPath"], serde_json::Value::Null);
        assert_eq!(value["rawExportPath"], json!("/Scans/Raw/ScanStudio1.dng"));
        assert_eq!(
            value["rawExportIrPath"],
            json!("/Scans/Raw/ScanStudio1-ir.tif")
        );
        assert_eq!(value["artifacts"]["rgb"]["byteLength"], json!(25165824u64));
        round_trip(&receipt);

        let mut legacy_value = value;
        let legacy_object = legacy_value
            .as_object_mut()
            .expect("receipt JSON must be an object");
        legacy_object.remove("storageTransform");
        legacy_object.remove("startedAt");
        legacy_object.remove("captureDurationMs");
        legacy_object.remove("rawExportPath");
        legacy_object.remove("rawExportIrPath");
        let legacy: BridgeScanReceipt =
            serde_json::from_value(legacy_value).expect("legacy receipt must still deserialize");
        assert!(
            legacy.storage_transform.is_empty(),
            "a missing legacy storageTransform must become an explicit unsupported value"
        );
        assert!(legacy.started_at.is_none());
        assert!(legacy.capture_duration_ms.is_none());
        assert!(legacy.raw_export_path.is_none());
        assert!(legacy.raw_export_ir_path.is_none());
    }

    #[test]
    fn bridge_scan_receipt_exposure_authority_is_camelcase_legacy_safe_and_fail_soft() {
        let authority = BridgeExposureAuthority {
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
        };
        let block = serde_json::to_value(&authority).unwrap();
        assert_eq!(block["rgbSource"], json!("nikon-parity-guarded-v2"));
        assert_eq!(block["commandedChannelsRaw10ns"]["IR"], json!(311725));
        assert_eq!(
            block["deviceBoundClampedChannelsRaw10ns"],
            json!({"B": 340200})
        );
        round_trip(&authority);

        // Exercise the receipt field's custom deserializer directly: both
        // an omitted legacy key and malformed additive telemetry become
        // absence rather than losing the completed frame.
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Wrapper {
            #[serde(default, deserialize_with = "deserialize_exposure_authority_fail_soft")]
            exposure_authority: Option<BridgeExposureAuthority>,
        }
        assert!(serde_json::from_value::<Wrapper>(json!({}))
            .unwrap()
            .exposure_authority
            .is_none());
        assert!(
            serde_json::from_value::<Wrapper>(json!({"exposureAuthority": "bad"}))
                .unwrap()
                .exposure_authority
                .is_none()
        );
    }

    /// `code` must round-trip as a plain wire string, including a value
    /// outside the closed `BridgeErrorCode` set (BRIDGE.md: `scan.error`'s
    /// `code` "is always `INTERNAL`" for the soft-timeout watchdog, but the
    /// `except BridgeError` path can forward any of the 21 codes verbatim
    /// — this type must never fail to deserialize regardless of which).
    #[test]
    fn bridge_scan_error_payload_round_trips_with_arbitrary_code_string() {
        let payload = BridgeScanErrorPayload {
            job_id: "job-7f3a".to_string(),
            code: "REFEED_REQUIRED".to_string(),
            message: "roll fingerprint mismatch mid-batch".to_string(),
        };
        let value = serde_json::to_value(&payload).unwrap();
        assert_eq!(value["jobId"], json!("job-7f3a"));
        assert_eq!(value["code"], json!("REFEED_REQUIRED"));
        round_trip(&payload);

        // A code string outside the 22-member BridgeErrorCode enum must
        // still deserialize cleanly -- this is the entire point of typing
        // `code` as `String` rather than `BridgeErrorCode`.
        let future_code: BridgeScanErrorPayload = serde_json::from_value(json!({
            "jobId": "job-9",
            "code": "SOME_FUTURE_CODE_NOT_YET_INVENTED",
            "message": "forward-compat check"
        }))
        .expect("an unrecognized code string must not fail deserialization");
        assert_eq!(future_code.code, "SOME_FUTURE_CODE_NOT_YET_INVENTED");
    }

    #[test]
    fn bridge_frame_failed_payload_round_trips_with_arbitrary_code_string() {
        let payload = BridgeFrameFailedPayload {
            job_id: "job-7f3a".to_string(),
            slot: 1,
            code: "MANUAL_REVIEW_REQUIRED".to_string(),
            message: "frame 1 transport origin requires manual review".to_string(),
        };
        let value = serde_json::to_value(&payload).unwrap();
        assert_eq!(value["jobId"], json!("job-7f3a"));
        assert_eq!(value["slot"], json!(1));
        assert_eq!(value["code"], json!("MANUAL_REVIEW_REQUIRED"));
        round_trip(&payload);

        let future_code: BridgeFrameFailedPayload = serde_json::from_value(json!({
            "jobId": "job-9",
            "slot": 7,
            "code": "SOME_FUTURE_CODE_NOT_YET_INVENTED",
            "message": "forward-compat check"
        }))
        .expect("an unrecognized code string must not fail deserialization");
        assert_eq!(future_code.code, "SOME_FUTURE_CODE_NOT_YET_INVENTED");
    }

    /// Field values taken from `bridge/tests/test_service_dispatch.py`'s own
    /// `test_roll_manual_frames_dispatch_routes_rows_and_rearms_scan_gate` --
    /// pins the Rust mirror to the exact wire shape the real Python bridge
    /// emits, not just an internally-consistent round trip.
    #[test]
    fn bridge_manual_frames_result_matches_python_bridge_worked_example() {
        let result = BridgeManualFramesResult {
            count: 2,
            fingerprint: "stub-manual-fp".to_string(),
            thumbnails: vec![
                BridgeThumbnail {
                    slot: 1,
                    boundary_rows: (100, 300),
                    spacing_offset: 0,
                    needs_approval: true,
                    warnings: vec!["user-picked".to_string()],
                    image_path: "/tmp/stub-manual/slot-0001.tif".to_string(),
                    partial: None,
                },
                BridgeThumbnail {
                    slot: 2,
                    boundary_rows: (300, 500),
                    spacing_offset: 0,
                    needs_approval: true,
                    warnings: vec!["user-picked".to_string()],
                    image_path: "/tmp/stub-manual/slot-0002.tif".to_string(),
                    partial: None,
                },
            ],
            snaps: vec![BridgeBoundarySnap {
                boundary_index: 0,
                requested_row: 100,
                snapped_row: 100,
                evidence_run: (98, 102),
            }],
        };
        let value = serde_json::to_value(&result).unwrap();
        assert_eq!(value["count"], json!(2));
        assert_eq!(value["fingerprint"], json!("stub-manual-fp"));
        assert_eq!(
            value["thumbnails"].as_array().unwrap().iter().map(|t| t["slot"].clone()).collect::<Vec<_>>(),
            vec![json!(1), json!(2)]
        );
        assert_eq!(value["thumbnails"][0]["boundaryRows"], json!([100, 300]));
        assert_eq!(value["thumbnails"][0]["needsApproval"], json!(true));
        assert_eq!(
            value["snaps"],
            json!([{
                "boundaryIndex": 0,
                "requestedRow": 100,
                "snappedRow": 100,
                "evidenceRun": [98, 102],
            }])
        );
        round_trip(&result);
    }

    /// Field values taken from `bridge/tests/test_service_dispatch.py`'s own
    /// `test_roll_preview_strip_dispatch_returns_wire_shape`.
    #[test]
    fn bridge_preview_strip_result_matches_python_bridge_worked_example() {
        let result = BridgePreviewStripResult {
            image_path: "/tmp/stub-preview/strip.tif".to_string(),
            row_count: 4800,
            pixels_per_row: 1,
        };
        let value = serde_json::to_value(&result).unwrap();
        assert_eq!(
            value,
            json!({
                "imagePath": "/tmp/stub-preview/strip.tif",
                "rowCount": 4800,
                "pixelsPerRow": 1,
            })
        );
        round_trip(&result);
    }

    #[test]
    fn bridge_manual_frames_params_round_trips_rows() {
        let params = BridgeManualFramesParams {
            rows: vec![100, 300, 500],
        };
        assert_eq!(
            serde_json::to_value(&params).unwrap(),
            json!({"rows": [100, 300, 500]})
        );
        round_trip(&params);
    }

    #[test]
    fn bridge_thumbnail_partial_round_trips_and_defaults_absent() {
        let with_partial = BridgeThumbnail {
            slot: 39,
            boundary_rows: (10, 800),
            spacing_offset: 0,
            needs_approval: true,
            warnings: vec![],
            image_path: "/tmp/t.tif".to_string(),
            partial: Some(true),
        };
        let value = serde_json::to_value(&with_partial).unwrap();
        assert_eq!(value["partial"], serde_json::json!(true));
        round_trip(&with_partial);

        let without: BridgeThumbnail = serde_json::from_value(serde_json::json!({
            "slot": 1,
            "boundaryRows": [10, 800],
            "spacingOffset": 0,
            "needsApproval": false,
            "warnings": [],
            "imagePath": "/tmp/t.tif",
        }))
        .unwrap();
        assert_eq!(without.partial, None);
        assert!(serde_json::to_value(&without)
            .unwrap()
            .get("partial")
            .is_none());
    }
}
