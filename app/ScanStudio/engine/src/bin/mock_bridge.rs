//! Spawnable NDJSON-over-stdio test double for `protocol/BRIDGE.md`'s
//! bridge side (Plan 09-01). Answers all 10 BRIDGE.md methods with fixed,
//! deterministic data; two env vars (`MOCK_BRIDGE_VERSION_MISMATCH`,
//! `MOCK_BRIDGE_CRASH_ON`) let tests force a version-mismatch failure or a
//! mid-request crash purely from the test-runner side, with zero GPL code
//! and zero hardware. Mirrors `server.rs`'s dispatch-loop structure
//! exactly: a blocking `stdin.lock().lines()` read loop on the main
//! thread, a dedicated stdout-writer thread fed by
//! `std::sync::mpsc::channel::<String>()`, where every line sent to the
//! channel is already-serialized JSON.

use std::fs::OpenOptions;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, AtomicU32, Ordering},
    mpsc, Arc,
};
use std::thread;
use std::time::Duration;

use image::{ImageBuffer, Rgb};
use serde::Serialize;

use scanstudio_engine::bridge_protocol::*;

const DEVICE_ID: &str = "bridge-ls5000-0";
// Lane D, #14-C: a second, always-unsupported device id, reported alongside
// DEVICE_ID only when MOCK_BRIDGE_DEVICE_DUAL_ATTACH is set -- proves the
// engine's connect() decides per REQUESTED device id, not whichever device
// this engine happened to see first in device.list.
const UNSUPPORTED_DEVICE_ID: &str = "bridge-ls50-0";

struct MockState {
    device_open: bool,
    job_counter: u64,
    /// Monotonic path component for adjusted preview tiles. The app image
    /// cache is keyed by file URL, so every successful alignment response
    /// must name a fresh file just like the production bridge does.
    thumbnail_counter: u64,
    /// Read-only test fixture for BRIDGE.md's live `motionArmed` status
    /// observation. It never arms the mock or authorizes motion.
    motion_armed: bool,
    /// Optional value returned only from an explicit `device.status` request.
    /// This proves the engine reads a fresh bridge status instead of reusing
    /// the connection response it cached at `device.open`.
    motion_armed_on_status: Option<bool>,
    /// Test-only refusal seam for the existing bridge motion gate. It never
    /// moves film, creates a latch, or changes `motion_armed`.
    reject_preview_motion_not_armed: bool,
    /// Parsed once in `main()` from `MOCK_BRIDGE_FILM_PRESENT` — mirrors
    /// this file's `MOCK_BRIDGE_VERSION_MISMATCH`/`MOCK_BRIDGE_CRASH_ON`
    /// read-once pattern.
    film_present: Option<bool>,
    /// Set to true when `scan.start` is accepted while both
    /// `MOCK_BRIDGE_HANG_ON_SCAN` and
    /// `MOCK_BRIDGE_HANG_ON_STATUS_AFTER_SCAN` are set. From that point on,
    /// every `device.status` request is read and silently never answered —
    /// every OTHER method keeps answering normally, mirroring the plausible
    /// live shape "one specific hardware-status read is stuck against
    /// wedged transport state, the rest of the process is fine" without
    /// making the mock unresponsive wholesale.
    status_hang_active: bool,
    /// Test-only append-only bridge method log. It is intentionally opt-in
    /// through a child-scoped environment variable so integration tests can
    /// assert that a public engine request did not secretly trigger a motion
    /// or status call. Production bridge behavior is not modeled here.
    call_log_path: Option<PathBuf>,
    /// `roll.approve` is meaningful only after the current preview reaches
    /// its terminal success event. These atomics are shared with that worker
    /// so a pending preview cannot masquerade as completed.
    preview_established: Arc<AtomicBool>,
    preview_slot_count: Arc<AtomicU32>,
}

impl MockState {
    fn record_call(&self, method: &str) {
        let Some(path) = self.call_log_path.as_ref() else {
            return;
        };
        if let Err(error) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .and_then(|mut file| writeln!(file, "{method}"))
        {
            eprintln!("mock_bridge: could not append call log {}: {error}", path.display());
        }
    }
}

fn main() {
    let version_mismatch = std::env::var("MOCK_BRIDGE_VERSION_MISMATCH")
        .map(|v| !v.is_empty())
        .unwrap_or(false);
    let crash_on = std::env::var("MOCK_BRIDGE_CRASH_ON")
        .ok()
        .filter(|v| !v.is_empty());
    // Scan-path silence-watchdog test double: when set, scan.start still accepts
    // normally (the bridge process and its main dispatch loop stay fully
    // alive and responsive to every other request) but the job's worker
    // is never spawned, so it emits zero further events for that job —
    // simulating a scan worker that entered its blocking transport call
    // and never returned, without actually blocking any thread.
    let hang_on_scan = std::env::var("MOCK_BRIDGE_HANG_ON_SCAN")
        .map(|v| !v.is_empty())
        .unwrap_or(false);
    // Synchronous typed-session-loss seam. The bridge remains alive, but
    // retires its device handle and rejects scan.start before any worker or
    // motion event exists.
    let not_connected_on_scan_start =
        std::env::var("MOCK_BRIDGE_NOT_CONNECTED_ON_SCAN_START")
            .map(|v| !v.is_empty())
            .unwrap_or(false);
    // A companion to MOCK_BRIDGE_HANG_ON_SCAN. Only meaningful alongside it.
    // simulates a bridge whose scan worker has gone silent AND whose
    // device.status reads are separately stuck (e.g. against genuinely
    // wedged transport state right after a preview traversal), so a test
    // can prove whether anything in the job-start path still makes a
    // blocking device.status call the scan-path silence watchdog doesn't
    // own.
    let hang_status_after_scan = std::env::var("MOCK_BRIDGE_HANG_ON_STATUS_AFTER_SCAN")
        .map(|v| !v.is_empty())
        .unwrap_or(false);
    // Preview-generation ownership seam: while a preview has been accepted
    // but has not established media yet, an independent device.status call
    // is read but never answered. Its client-side timeout restarts the bridge
    // without letting a predecessor preview worker observe EOF first.
    let hang_status_while_preview_pending =
        std::env::var("MOCK_BRIDGE_HANG_ON_STATUS_WHILE_PREVIEW_PENDING")
            .map(|v| !v.is_empty())
            .unwrap_or(false);
    // Unset -> Some(true) (film present, the common case); "false" ->
    // Some(false); "null" -> None (no presence sensor wired) — lets tests
    // exercise all three DeviceStatus.filmPresent states with zero
    // hardware.
    let film_present = match std::env::var("MOCK_BRIDGE_FILM_PRESENT").as_deref() {
        Ok("false") => Some(false),
        Ok("null") => None,
        _ => Some(true),
    };
    // Test-only status shaping. This controls only the boolean reported by
    // `device.open`/`device.status`; unlike a real bridge it has no latch,
    // no environment side effect, and no impact on any mock motion request.
    let motion_armed = std::env::var("MOCK_BRIDGE_MOTION_ARMED")
        .map(|value| value == "true")
        .unwrap_or(false);
    let motion_armed_on_status = std::env::var("MOCK_BRIDGE_MOTION_ARMED_ON_STATUS")
        .ok()
        .and_then(|value| match value.as_str() {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        });
    let reject_preview_motion_not_armed =
        std::env::var("MOCK_BRIDGE_REJECT_PREVIEW_MOTION_NOT_ARMED")
            .map(|value| !value.is_empty())
            .unwrap_or(false);
    // Reproduces a bridge scan-worker error sequence observed on 2026-07-23:
    // the bridge's scan worker
    // raised a BridgeError (REFEED_REQUIRED) mid-job. When set to a
    // BRIDGE.md error-code string, the scan worker emits zero progress/
    // frameCompleted events, emits `scan.error` naming that code, then
    // immediately emits `scan.completed` with every requested slot failed
    // — mirroring scanstudio_bridge.service's own `except BridgeError` ->
    // `finally` sequence, where both events land on the wire from the same
    // worker-thread pass.
    let scan_error_code = std::env::var("MOCK_BRIDGE_SCAN_ERROR_CODE")
        .ok()
        .filter(|v| !v.is_empty());
    // 10-08: reproduces live attempt #4 (2026-07-23 evening) — hw-telemetry
    // showed `scan.start outcome ok, completed:[], failed:[1]` after an 86s
    // real scan, with no scan.error involved at all. Comma-separated slot
    // numbers that the scan worker silently fails (no progress, no
    // frameCompleted, no scan.error — straight to scan.completed's own
    // failed[] list) while every OTHER requested slot completes normally —
    // mirrors transport.start_scan itself returning a ScanSummary that
    // already accounts for the slot as failed.
    let scan_failed_slots: Vec<u32> = std::env::var("MOCK_BRIDGE_SCAN_FAILED_SLOTS")
        .ok()
        .map(|v| {
            v.split(',')
                .filter_map(|s| s.trim().parse::<u32>().ok())
                .collect()
        })
        .unwrap_or_default();
    // 10-08: reproduces BRIDGE.md's SAFE-02 anomaly halt (e.g. a
    // bounded-retry-exhausted transport smear). When set to a slot number, the scan
    // worker emits `hardware.anomaly` for that slot (skipping its
    // progress/frameCompleted) then completes every OTHER requested slot
    // normally, then emits the job's authoritative scan.completed —
    // mirroring the bridge's own FrameRetryExhausted -> anomaly_halt ->
    // finally sequence.
    let scan_anomaly_slot: Option<u32> = std::env::var("MOCK_BRIDGE_SCAN_ANOMALY_SLOT")
        .ok()
        .and_then(|v| v.trim().parse::<u32>().ok());
    // 11-02: controls the code carried by the `hardware.anomaly` event
    // above so tests can prove the engine's code-to-recoverable mapping
    // without hardcoding a single anomaly scenario. Defaults to
    // TRANSPORT_SMEAR_DETECTED for backward compatibility with existing
    // tests.
    let scan_anomaly_code: String = std::env::var("MOCK_BRIDGE_SCAN_ANOMALY_CODE")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "TRANSPORT_SMEAR_DETECTED".to_string());
    // 11-01: reproduces a real bridge session that emits a malformed
    // `scan.progress` with `ordinal: 0` for one slot (e.g. an off-by-one
    // bug in bridge-side indexing). The slot still completes normally;
    // only the progress event is wrong — this tests the engine's handling
    // of out-of-convention ordinal values without conflating it with frame
    // outcome.
    let scan_bad_ordinal_slot: Option<u32> = std::env::var("MOCK_BRIDGE_SCAN_BAD_ORDINAL_SLOT")
        .ok()
        .and_then(|v| v.trim().parse::<u32>().ok());
    // Per-task: reproduces BRIDGE.md's `scan.frameFailed` additive event.
    // When set, the scan worker emits `scan.frameFailed` for slot 1, then
    // emits `scan.completed` with slot 1 failed — a failed-only completion
    // with no `scan.error` or `hardware.anomaly`, mirroring a per-frame
    // failure that the bridge records and forwards but whose job still
    // terminates normally via `scan.completed`.
    let emit_frame_failed = std::env::var("MOCK_BRIDGE_EMIT_FRAME_FAILED")
        .map(|v| !v.is_empty())
        .unwrap_or(false);
    // 11-02: controls the code carried by the `scan.frameFailed` event
    // above. Defaults to MANUAL_REVIEW_REQUIRED for backward compatibility.
    let emit_frame_failed_code: String = std::env::var("MOCK_BRIDGE_EMIT_FRAME_FAILED_CODE")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "MANUAL_REVIEW_REQUIRED".to_string());
    // 12-02: reproduces the bridge process itself dying mid-batch (e.g. a
    // USB/driver-level crash, a segfault in the underlying transport
    // library, an OOM-kill) — as opposed to every other fault flag in this
    // file, which simulates the bridge staying alive but reporting some
    // abnormal *result*. When set to a slot number, the scan worker emits
    // `scan.frameCompleted` for that slot and then calls
    // `std::process::exit(1)` immediately, with no cleanup.
    let crash_after_frame_completed: Option<u32> = std::env::var("MOCK_BRIDGE_CRASH_AFTER_FRAME_COMPLETED")
        .ok()
        .and_then(|v| v.trim().parse::<u32>().ok());
    // Deterministic async-preview ownership-loss seam: acknowledge
    // roll.preview first, then terminate the bridge before emitting any
    // preview event. This differs from MOCK_BRIDGE_CRASH_ON=roll.preview,
    // which dies before the request can be accepted.
    let crash_after_preview_accept =
        std::env::var("MOCK_BRIDGE_CRASH_AFTER_PREVIEW_ACCEPT")
            .map(|v| !v.is_empty())
            .unwrap_or(false);
    // Preview-terminal failure seam. The request is accepted first, then the
    // worker emits the same additive `roll.previewError` shape a real bridge
    // uses. It deliberately leaves `previewEstablished` false and reports no
    // slots, so tests cannot confuse a failed preview with usable media.
    let preview_error_code = std::env::var("MOCK_BRIDGE_PREVIEW_ERROR_CODE")
        .ok()
        .filter(|v| !v.is_empty());
    // Deterministic overlap seam for the real-backend preview ownership
    // tests. A long child-scoped delay leaves the first accepted preview
    // pending while the public engine receives a successor request; the
    // production-shaped default remains the existing 20ms.
    let preview_delay_ms = std::env::var("MOCK_BRIDGE_PREVIEW_DELAY_MS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(20);
    // Preview-metadata propagation seam. Comma-separated slots carry the
    // same manual-review flag and warning a real bridge thumbnail reports;
    // this changes preview evidence only and never approves or starts motion.
    let preview_approval_slots: Vec<u32> =
        std::env::var("MOCK_BRIDGE_PREVIEW_APPROVAL_SLOTS")
            .ok()
            .map(|value| {
                value
                    .split(',')
                    .filter_map(|slot| slot.trim().parse::<u32>().ok())
                    .collect()
            })
            .unwrap_or_default();
    // 12-03: gives tests a known, controllable inter-frame gap to assert
    // the engine's frame-to-frame idle measurement against. Default 0 leaves
    // the existing 15ms per-slot pacing unchanged for every pre-existing test.
    let inter_frame_delay_extra_ms: u64 = std::env::var("MOCK_BRIDGE_INTER_FRAME_DELAY_MS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(0);
    // 2026-07-26 (frame-ordinal display bug regression coverage): the
    // per-slot loop below emits one scan.progress immediately followed by
    // its own scan.frameCompleted, in lockstep — the opposite of the real
    // bridge's documented 2026-07-25 shape, where CoolscanPyTransport.
    // start_scan fires EVERY scan.progress for the whole batch in one
    // upfront pass (0-based ordinal, naming every requested slot) before
    // scan_many() ever moves hardware, then emits nothing but
    // scan.frameCompleted from then on (see coolscanpy_transport.py's own
    // start_scan comment). The lockstep shape below never reproduces the
    // live bug (a stale frame_ordinal surviving into the real scan), so it
    // needs its own opt-in mode rather than a change to the default path
    // every other test here already depends on.
    let scan_upfront_burst = std::env::var("MOCK_BRIDGE_SCAN_UPFRONT_BURST")
        .map(|v| !v.is_empty())
        .unwrap_or(false);
    let call_log_path = std::env::var_os("MOCK_BRIDGE_CALL_LOG").map(PathBuf::from);
    // Rung 4 validation-passthrough seam: when set, `roll.manualFrames`
    // refuses every request with this exact `INVALID_PARAMS` message,
    // unmodified -- proves the real engine forwards the bridge's
    // plain-English validation text verbatim rather than reshaping it.
    let manual_frames_error = std::env::var("MOCK_BRIDGE_MANUAL_FRAMES_ERROR")
        .ok()
        .filter(|v| !v.is_empty());

    let (tx, rx) = mpsc::channel::<String>();

    // The only thread that ever writes to stdout — mirrors server.rs's own
    // writer thread exactly.
    let writer = thread::spawn(move || {
        let stdout = io::stdout();
        let mut handle = stdout.lock();
        for line in rx {
            if writeln!(handle, "{line}").is_err() {
                break;
            }
            let _ = handle.flush();
        }
    });

    let mut state = MockState {
        device_open: false,
        job_counter: 0,
        thumbnail_counter: 0,
        motion_armed,
        motion_armed_on_status,
        reject_preview_motion_not_armed,
        film_present,
        status_hang_active: false,
        call_log_path,
        preview_established: Arc::new(AtomicBool::new(false)),
        preview_slot_count: Arc::new(AtomicU32::new(0)),
    };
    let mut hello_received = false;
    let stdin = io::stdin();

    for line_result in stdin.lock().lines() {
        let line = match line_result {
            Ok(l) => l,
            Err(err) => {
                eprintln!("mock_bridge: stdin read error: {err}");
                continue;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        // Malformed JSON must never crash the process (T-09-01, mirrors
        // server.rs's own T-01-01 mitigation): log and skip.
        let request: BridgeRequest = match serde_json::from_str(&line) {
            Ok(req) => req,
            Err(err) => {
                eprintln!("mock_bridge: malformed request line, skipping: {err}");
                continue;
            }
        };

        state.record_call(&request.method);

        // Simulated hard crash: checked first, before any other handling
        // of this request (including the hello gate below), so it fires
        // regardless of which method triggers it.
        if crash_on.as_deref() == Some(request.method.as_str()) {
            std::process::exit(1);
        }

        // 10-06: once armed (inside the "scan.start" arm below),
        // device.status is read off stdin (so the pipe never backs up) but
        // never answered — checked before dispatch, mirroring crash_on's
        // own early-check placement, so it applies regardless of the hello
        // gate below.
        if request.method == "device.status"
            && (state.status_hang_active
                || (hang_status_while_preview_pending
                    && !state.preview_established.load(Ordering::Acquire)))
        {
            continue;
        }

        if !hello_received && request.method != "bridge.hello" {
            respond_error(
                &tx,
                request.id,
                BridgeErrorCode::InvalidParams,
                "bridge.hello must be the first request",
            );
            continue;
        }

        if request.method == "bridge.shutdown" {
            respond_ok(&tx, request.id, serde_json::json!({}));
            drop(tx);
            let _ = writer.join();
            std::process::exit(0);
        }

        match handle_request(
            &tx,
            &request,
            &mut state,
            version_mismatch,
            hang_on_scan,
            not_connected_on_scan_start,
            hang_status_after_scan,
            scan_error_code.clone(),
            &scan_failed_slots,
            scan_anomaly_slot,
            scan_anomaly_code.clone(),
            emit_frame_failed,
            emit_frame_failed_code.clone(),
            scan_bad_ordinal_slot,
            crash_after_frame_completed,
            crash_after_preview_accept,
            preview_error_code.clone(),
            preview_delay_ms,
            &preview_approval_slots,
            inter_frame_delay_extra_ms,
            scan_upfront_burst,
            manual_frames_error.clone(),
        ) {
            Ok(result) => {
                if request.method == "bridge.hello" {
                    hello_received = true;
                }
                respond_ok(&tx, request.id, result);
            }
            Err((code, message)) => {
                respond_error(&tx, request.id, code, &message);
            }
        }
    }

    // stdin closed without an explicit bridge.shutdown: exit cleanly
    // rather than hang the writer thread open.
    drop(tx);
    let _ = writer.join();
}

#[allow(clippy::too_many_arguments)]
/// Lane C mock: exactly one designated slot reports `partial: true` so
/// integration tests can assert the field survives the engine unmangled;
/// every other slot omits it, like a real bridge on a fully-inside frame.
/// Slot 3 -- the last of the mock's standard 1..3 preview trio -- is the
/// natural edge frame.
const MOCK_PARTIAL_SLOT: u32 = 3;

fn mock_partial_for(slot: u32) -> Option<bool> {
    (slot == MOCK_PARTIAL_SLOT).then_some(true)
}

fn handle_request(
    tx: &mpsc::Sender<String>,
    request: &BridgeRequest,
    state: &mut MockState,
    version_mismatch: bool,
    hang_on_scan: bool,
    not_connected_on_scan_start: bool,
    hang_status_after_scan: bool,
    scan_error_code: Option<String>,
    scan_failed_slots: &[u32],
    scan_anomaly_slot: Option<u32>,
    scan_anomaly_code: String,
    emit_frame_failed: bool,
    emit_frame_failed_code: String,
    scan_bad_ordinal_slot: Option<u32>,
    crash_after_frame_completed: Option<u32>,
    crash_after_preview_accept: bool,
    preview_error_code: Option<String>,
    preview_delay_ms: u64,
    preview_approval_slots: &[u32],
    inter_frame_delay_extra_ms: u64,
    scan_upfront_burst: bool,
    manual_frames_error: Option<String>,
) -> Result<serde_json::Value, (BridgeErrorCode, String)> {
    match request.method.as_str() {
        "bridge.hello" => {
            let params: BridgeHelloParams = parse_params(&request.params)?;
            if version_mismatch || params.protocol_version != 1 {
                return Err((
                    BridgeErrorCode::InvalidParams,
                    format!(
                        "unsupported protocolVersion {}; expected 1",
                        params.protocol_version
                    ),
                ));
            }
            to_json(&BridgeHelloResult {
                bridge_name: "mock-scanstudio-bridge".to_string(),
                bridge_version: "0.0.1-mock".to_string(),
                protocol_version: 1,
                capabilities: vec!["ls5000-coolscanpy".to_string()],
            })
        }
        "device.list" => {
            let mut devices = vec![fixed_device_info()];
            let dual_attach = std::env::var("MOCK_BRIDGE_DEVICE_DUAL_ATTACH")
                .map(|v| !v.is_empty())
                .unwrap_or(false);
            if dual_attach {
                devices.push(dual_attach_secondary_device_info());
            }
            to_json(&BridgeDeviceListResult { devices })
        }
        "device.open" => {
            let params: BridgeDeviceOpenParams = parse_params(&request.params)?;
            if params.device_id != DEVICE_ID {
                return Err((
                    BridgeErrorCode::DeviceNotFound,
                    format!("no such device: {}", params.device_id),
                ));
            }
            if state.device_open {
                return Err((
                    BridgeErrorCode::AlreadyConnected,
                    "a device is already open".to_string(),
                ));
            }
            state.device_open = true;
            let status = current_status(state, false);
            emit_event(
                tx,
                "device.status",
                BridgeDeviceStatusPayload {
                    status: status.clone(),
                },
            );
            to_json(&BridgeDeviceOpenResult {
                // Deliberately independently configurable from device.list
                // so real-backend tests can prove that a holder changed
                // while disconnected is refreshed at open time.
                device: open_device_info(),
                status,
            })
        }
        "device.status" => {
            require_open(state)?;
            to_json(&current_status(state, true))
        }
        "device.close" => {
            require_open(state)?;
            state.device_open = false;
            state.preview_established.store(false, Ordering::Release);
            state.preview_slot_count.store(0, Ordering::Release);
            let status = current_status(state, false);
            emit_event(tx, "device.status", BridgeDeviceStatusPayload { status });
            Ok(serde_json::json!({}))
        }
        "roll.preview" => {
            require_open(state)?;
            if state.reject_preview_motion_not_armed {
                return Err((
                    BridgeErrorCode::HwMotionNotArmed,
                    "motion refused by mock bridge's live readiness gate".to_string(),
                ));
            }
            let _params: BridgeRollPreviewParams = parse_params(&request.params)?;
            state.preview_established.store(false, Ordering::Release);
            state.preview_slot_count.store(0, Ordering::Release);
            spawn_roll_preview_worker(
                tx.clone(),
                crash_after_preview_accept,
                preview_error_code,
                preview_delay_ms,
                preview_approval_slots.to_vec(),
                Arc::clone(&state.preview_established),
                Arc::clone(&state.preview_slot_count),
            );
            to_json(&BridgeRollPreviewAck { accepted: true })
        }
        "roll.approve" => {
            require_open(state)?;
            if !state.preview_established.load(Ordering::Acquire) {
                return Err((
                    BridgeErrorCode::NoPreview,
                    "roll.approve requires an active preview session".to_string(),
                ));
            }
            let _params: BridgeRollApproveParams = parse_params(&request.params)?;
            Ok(serde_json::json!({}))
        }
        "roll.setSpacingOffset" => {
            require_open(state)?;
            if !state.preview_established.load(Ordering::Acquire) {
                return Err((
                    BridgeErrorCode::NoPreview,
                    "roll.setSpacingOffset requires an active preview session".to_string(),
                ));
            }
            let params: BridgeRollSetSpacingOffsetParams = parse_params(&request.params)?;
            state.thumbnail_counter += 1;
            let path = std::env::temp_dir().join(format!(
                "mock-bridge-preview-slot-{:04}-adjustment-{:08}.tif",
                params.slot, state.thumbnail_counter
            ));
            to_json(&BridgeRollSetSpacingOffsetResult {
                thumbnail: BridgeThumbnail {
                    slot: params.slot,
                    boundary_rows: (10, 800),
                    spacing_offset: params.offset_rows,
                    needs_approval: false,
                    warnings: vec![],
                    image_path: path.to_string_lossy().into_owned(),
                    partial: mock_partial_for(params.slot),
                },
            })
        }
        "roll.manualFrames" => {
            require_open(state)?;
            let params: BridgeManualFramesParams = parse_params(&request.params)?;
            if let Some(message) = manual_frames_error.as_ref() {
                return Err((BridgeErrorCode::InvalidParams, message.clone()));
            }
            if params.rows.len() < 2 {
                return Err((
                    BridgeErrorCode::InvalidParams,
                    "manual frame placement needs at least 2 boundary rows".to_string(),
                ));
            }
            let frame_count = (params.rows.len() - 1) as u32;
            let thumbnails: Vec<BridgeThumbnail> = params
                .rows
                .windows(2)
                .enumerate()
                .map(|(index, pair)| {
                    let slot = (index + 1) as u32;
                    state.thumbnail_counter += 1;
                    let path = std::env::temp_dir().join(format!(
                        "mock-bridge-manual-frame-slot-{:04}-{:08}.tif",
                        slot, state.thumbnail_counter
                    ));
                    BridgeThumbnail {
                        slot,
                        boundary_rows: (pair[0], pair[1]),
                        spacing_offset: 0,
                        needs_approval: true,
                        warnings: vec!["user-picked".to_string()],
                        image_path: path.to_string_lossy().into_owned(),
                        partial: mock_partial_for(slot),
                    }
                })
                .collect();
            // manual_frames() arms a usable bridge-side session exactly
            // like a successful roll.preview does (BRIDGE.md), without a
            // prior roll.preview ever having run this session -- mirrored
            // here so a following scan.start is no longer refused with
            // NO_PREVIEW purely because of test ordering.
            state.preview_established.store(true, Ordering::Release);
            state.preview_slot_count.store(frame_count, Ordering::Release);
            to_json(&BridgeManualFramesResult {
                count: frame_count,
                fingerprint: "mock-manual-fp".to_string(),
                thumbnails,
                snaps: vec![],
            })
        }
        "roll.previewStrip" => {
            require_open(state)?;
            state.thumbnail_counter += 1;
            let path = std::env::temp_dir().join(format!(
                "mock-bridge-preview-strip-{:08}.tif",
                state.thumbnail_counter
            ));
            to_json(&BridgePreviewStripResult {
                image_path: path.to_string_lossy().into_owned(),
                row_count: 4800,
                pixels_per_row: 1,
            })
        }
        "scan.start" => {
            require_open(state)?;
            if not_connected_on_scan_start {
                state.device_open = false;
                return Err((
                    BridgeErrorCode::NotConnected,
                    "no device is open".to_string(),
                ));
            }
            let params: BridgeScanStartParams = parse_params(&request.params)?;
            state.job_counter += 1;
            let job_id = format!("mock-job-{}", state.job_counter);
            // MOCK_BRIDGE_HANG_ON_SCAN: accept the job normally (it is a
            // real, well-formed acceptance — the bridge is not refusing or
            // crashing) but never spawn the worker that would emit
            // scan.progress/scan.frameCompleted/scan.completed for it.
            if !hang_on_scan {
                spawn_scan_worker(
                    tx.clone(),
                    job_id.clone(),
                    params.slots,
                    params.recipe.channels,
                    params.output,
                    scan_error_code.clone(),
                    scan_failed_slots.to_vec(),
                    scan_anomaly_slot,
                    scan_anomaly_code.clone(),
                    emit_frame_failed,
                    emit_frame_failed_code.clone(),
                    scan_bad_ordinal_slot,
                    crash_after_frame_completed,
                    inter_frame_delay_extra_ms,
                    scan_upfront_burst,
                );
            }
            if hang_status_after_scan {
                // 10-06 / 11-01: arm the device.status hang from this point
                // on — see MockState::status_hang_active and the early check
                // in main()'s dispatch loop. Independently of whether the
                // scan worker itself was spawned, so tests can observe the
                // engine's behavior when a long scan runs while status reads
                // are separately stuck.
                state.status_hang_active = true;
            }
            to_json(&BridgeScanStartResult { job_id })
        }
        "scan.stop" => {
            require_open(state)?;
            let _params: BridgeScanStopParams = parse_params(&request.params)?;
            to_json(&BridgeScanStopResult { acknowledged: true })
        }
        "device.eject" => {
            require_open(state)?;
            state.preview_established.store(false, Ordering::Release);
            state.preview_slot_count.store(0, Ordering::Release);
            let status = current_status(state, false);
            emit_event(tx, "device.status", BridgeDeviceStatusPayload { status });
            Ok(serde_json::json!({}))
        }
        other => Err((
            BridgeErrorCode::UnknownMethod,
            format!("unknown method '{other}'"),
        )),
    }
}

/// Match BRIDGE.md's session contract: discovery is deliberately available
/// before a device is open, but every operation that touches a device must be
/// rejected after a bridge respawn until a new `device.open` succeeds.
fn require_open(state: &MockState) -> Result<(), (BridgeErrorCode, String)> {
    if state.device_open {
        Ok(())
    } else {
        Err((
            BridgeErrorCode::NotConnected,
            "no device is open".to_string(),
        ))
    }
}

fn fixed_device_info() -> BridgeDeviceInfo {
    // Lane D (S04): the mock can advertise a recognized-but-unsupported
    // Nikon model so the engine's recognize-and-refuse path is testable
    // without real hardware.
    let unsupported = std::env::var("MOCK_BRIDGE_DEVICE_UNSUPPORTED")
        .map(|v| !v.is_empty())
        .unwrap_or(false);
    BridgeDeviceInfo {
        device_id: DEVICE_ID.to_string(),
        vendor: "Nikon".to_string(),
        model: if unsupported {
            "LS-50 ED".to_string()
        } else {
            "SUPER COOLSCAN 5000 ED".to_string()
        },
        supported: !unsupported,
        capabilities: BridgeCapabilities {
            ir_channel: true,
            supported_dpi: vec![4000],
            supported_depths: vec![16],
            multi_sample: true,
            adapter_frame_capacity: Some(36),
            adapter_frame_control: true,
            auto_exposure: true,
            registered_geometry: false,
            can_eject: true,
            supported_multisample_passes: vec![4],
        },
    }
}

/// Lane D, #14-C: a second, always-unsupported LS-50 alongside the primary
/// device, reported only when MOCK_BRIDGE_DEVICE_DUAL_ATTACH is set. Never
/// openable through device.open -- the engine's connect() must refuse it
/// before ever sending that request.
fn dual_attach_secondary_device_info() -> BridgeDeviceInfo {
    let mut device = fixed_device_info();
    device.device_id = UNSUPPORTED_DEVICE_ID.to_string();
    device.model = "LS-50 ED".to_string();
    device.supported = false;
    device
}

/// `device.list` stays fixed, while this open-time result can model a holder
/// changed during the disconnected interval. Values are test-only child
/// process configuration, never hardware probing.
fn open_device_info() -> BridgeDeviceInfo {
    let mut device = fixed_device_info();
    if let Ok(value) = std::env::var("MOCK_BRIDGE_OPEN_ADAPTER_FRAME_CAPACITY") {
        device.capabilities.adapter_frame_capacity = value.parse().ok();
    }
    if let Ok(value) = std::env::var("MOCK_BRIDGE_OPEN_ADAPTER_FRAME_CONTROL") {
        device.capabilities.adapter_frame_control = value == "true";
    }
    device
}

fn current_status(state: &MockState, fresh_status_read: bool) -> BridgeDeviceStatus {
    let preview_established = state.preview_established.load(Ordering::Acquire);
    BridgeDeviceStatus {
        connected: state.device_open,
        device_id: if state.device_open {
            Some(DEVICE_ID.to_string())
        } else {
            None
        },
        preview_established,
        slot_count: preview_established.then_some(
            state.preview_slot_count.load(Ordering::Acquire),
        ),
        active_job_id: None,
        lane_held: false,
        motion_armed: if fresh_status_read {
            state.motion_armed_on_status.unwrap_or(state.motion_armed)
        } else {
            state.motion_armed
        },
        film_present: state.film_present,
    }
}

/// Fires after an ack, on its own thread, so the immediate
/// `{accepted: true}` response is never blocked on it — mirrors how
/// `SimulatedLs5000`'s worker-thread operations report progress purely
/// through events (see `domain.rs`'s `ScannerBackend` doc comment).
fn spawn_roll_preview_worker(
    tx: mpsc::Sender<String>,
    crash_after_accept: bool,
    preview_error_code: Option<String>,
    preview_delay_ms: u64,
    preview_approval_slots: Vec<u32>,
    preview_established: Arc<AtomicBool>,
    preview_slot_count: Arc<AtomicU32>,
) {
    thread::spawn(move || {
        if crash_after_accept {
            // Let main enqueue and flush the accepted response before this
            // worker terminates the whole bridge process.
            thread::sleep(Duration::from_millis(50));
            std::process::exit(1);
        }
        thread::sleep(Duration::from_millis(preview_delay_ms));
        if let Some(code) = preview_error_code {
            preview_established.store(false, Ordering::Release);
            preview_slot_count.store(0, Ordering::Release);
            emit_event(
                &tx,
                "roll.previewError",
                serde_json::json!({
                    "code": code,
                    "message": "mock preview failure",
                }),
            );
            return;
        }
        for slot in [1u32, 2, 3] {
            let needs_approval = preview_approval_slots.contains(&slot);
            // Real, tiny, loadable TIFF tile — wire-shape/file-existence
            // proof (a flat-fill deterministic function of `slot`), not a
            // visual-quality test. Swift (Plan 10-03) will actually try to
            // load this file, unlike the fake receipt paths below.
            let path =
                std::env::temp_dir().join(format!("mock-bridge-preview-slot-{slot:04}.tif"));
            let tile = ImageBuffer::from_fn(137, 92, |_x, _y| {
                Rgb([(slot * 40) as u8, 128u8, 255 - (slot * 40) as u8])
            });
            if let Err(err) = tile.save(&path) {
                eprintln!(
                    "mock_bridge: failed to write preview tile for slot {slot} at {}: {err}",
                    path.display()
                );
            }
            emit_event(
                &tx,
                "roll.thumbnail",
                BridgeThumbnailEventPayload {
                    slot,
                    thumbnail: BridgeThumbnail {
                        slot,
                        boundary_rows: (10, 800),
                        spacing_offset: 3,
                        needs_approval,
                        warnings: if needs_approval {
                            vec!["ambiguous-content-tail-boundary".to_string()]
                        } else {
                            vec![]
                        },
                        // Best-effort path string either way (even on a
                        // save error above) so the wire shape is never
                        // missing this required field.
                        image_path: path.to_string_lossy().into_owned(),
                        partial: mock_partial_for(slot),
                    },
                },
            );
        }
        // This state change is intentionally immediately before the terminal
        // success event: pending preview remains false, while a terminal
        // `device.status` read can truthfully report the scanner-addressable
        // slot count the worker just established.
        preview_slot_count.store(3, Ordering::Release);
        preview_established.store(true, Ordering::Release);
        emit_event(
            &tx,
            "roll.previewComplete",
            BridgePreviewCompletePayload {
                count: 3,
                fingerprint: "mock-fingerprint-0001".to_string(),
            },
        );
    });
}

#[allow(clippy::too_many_arguments)]
fn spawn_scan_worker(
    tx: mpsc::Sender<String>,
    job_id: String,
    slots: Vec<u32>,
    channels: BridgeChannels,
    output: BridgeOutputSpec,
    scan_error_code: Option<String>,
    scan_failed_slots: Vec<u32>,
    scan_anomaly_slot: Option<u32>,
    scan_anomaly_code: String,
    emit_frame_failed: bool,
    emit_frame_failed_code: String,
    scan_bad_ordinal_slot: Option<u32>,
    crash_after_frame_completed: Option<u32>,
    inter_frame_delay_extra_ms: u64,
    scan_upfront_burst: bool,
) {
    thread::spawn(move || {
        // 2026-07-26 (frame-ordinal display bug regression coverage):
        // reproduces the REAL bridge's documented 2026-07-25 shape —
        // every scan.progress for the batch fires in one upfront pass
        // (0-based ordinal, naming every requested slot) before any
        // scan.frameCompleted, rather than this mock's normal one-
        // progress-one-frameCompleted lockstep below. Deliberately
        // exclusive of every other flag this function reads (error/
        // anomaly/failed-slot/bad-ordinal/crash simulation): none of those
        // scenarios are what this mode exists to cover.
        if scan_upfront_burst {
            let total_slots = slots.len() as u32;
            for (ordinal, &slot) in slots.iter().enumerate() {
                emit_event(
                    &tx,
                    "scan.progress",
                    BridgeScanProgress {
                        job_id: job_id.clone(),
                        slot,
                        ordinal: ordinal as u32,
                        total_slots,
                        fraction: ordinal as f64 / (total_slots.max(1) as f64),
                        message: format!("scanning slot {slot}"),
                    },
                );
            }
            let mut completed_slots: Vec<u32> = Vec::new();
            for slot in slots {
                thread::sleep(Duration::from_millis(15 + inter_frame_delay_extra_ms));
                emit_event(
                    &tx,
                    "scan.frameCompleted",
                    BridgeFrameCompletedPayload {
                        job_id: job_id.clone(),
                        slot,
                        receipt: fixed_scan_receipt(slot, channels, &output),
                    },
                );
                completed_slots.push(slot);
            }
            emit_event(
                &tx,
                "scan.completed",
                BridgeScanCompletedPayload {
                    job_id,
                    summary: BridgeScanCompletedSummary {
                        completed: completed_slots,
                        failed: vec![],
                        stopped: false,
                    },
                },
            );
            return;
        }
        // The observed error shape: the scan worker never even attempts a slot;
        // it emits `scan.error` naming the bridge code, then immediately
        // `scan.completed` with every requested slot failed. Mirrors
        // scanstudio_bridge.service's own `except BridgeError` -> `finally`
        // sequence, where both land on the wire from the same worker-
        // thread pass with no gap in between.
        if let Some(code) = scan_error_code {
            emit_event(
                &tx,
                "scan.error",
                BridgeScanErrorPayload {
                    job_id: job_id.clone(),
                    code: code.clone(),
                    message: format!("mock scan.error: {code}"),
                },
            );
            emit_event(
                &tx,
                "scan.completed",
                BridgeScanCompletedPayload {
                    job_id,
                    summary: BridgeScanCompletedSummary {
                        completed: vec![],
                        failed: slots,
                        stopped: false,
                    },
                },
            );
            return;
        }

        if emit_frame_failed {
            emit_event(
                &tx,
                "scan.frameFailed",
                BridgeFrameFailedPayload {
                    job_id: job_id.clone(),
                    slot: 1,
                    code: emit_frame_failed_code.clone(),
                    message: format!("mock scan.frameFailed: frame 1 requires manual review ({emit_frame_failed_code})"),
                },
            );
            emit_event(
                &tx,
                "scan.completed",
                BridgeScanCompletedPayload {
                    job_id,
                    summary: BridgeScanCompletedSummary {
                        completed: vec![],
                        failed: vec![1],
                        stopped: false,
                    },
                },
            );
            return;
        }

        let total_slots = slots.len() as u32;
        let mut completed_slots: Vec<u32> = Vec::new();
        let mut failed_slots: Vec<u32> = Vec::new();
        for (index, slot) in slots.iter().copied().enumerate() {
            thread::sleep(Duration::from_millis(15 + inter_frame_delay_extra_ms));

            if scan_anomaly_slot == Some(slot) {
                // 10-08: live BRIDGE.md SAFE-02 anomaly-halt shape — a
                // supplementary, non-terminal diagnostic for this one slot;
                // the worker still goes on to complete every OTHER
                // requested slot and still emits the job's own
                // authoritative scan.completed at the end (mirrors
                // FrameRetryExhausted -> anomaly_halt, which does not by
                // itself end the wire sequence).
                emit_event(
                    &tx,
                    "hardware.anomaly",
                    BridgeHardwareAnomalyPayload {
                        job_id: Some(job_id.clone()),
                        slot: Some(slot),
                        code: scan_anomaly_code.clone(),
                        message: format!("mock hardware.anomaly: slot {slot} retry budget exhausted ({scan_anomaly_code})"),
                        ejected: true,
                    },
                );
                failed_slots.push(slot);
                continue;
            }

            if scan_failed_slots.contains(&slot) {
                // 10-08: live attempt #4 shape — no scan.error at all, the
                // transport call itself returned a summary that already
                // accounts for this slot as failed (telemetry outcome
                // "ok"), so this slot gets neither scan.progress nor
                // scan.frameCompleted.
                failed_slots.push(slot);
                continue;
            }

            let ordinal = if scan_bad_ordinal_slot == Some(slot) {
                0
            } else {
                index as u32 + 1
            };
            emit_event(
                &tx,
                "scan.progress",
                BridgeScanProgress {
                    job_id: job_id.clone(),
                    slot,
                    ordinal,
                    total_slots,
                    fraction: 1.0,
                    message: "mock transfer complete".to_string(),
                },
            );
            emit_event(
                &tx,
                "scan.frameCompleted",
                BridgeFrameCompletedPayload {
                    job_id: job_id.clone(),
                    slot,
                    receipt: fixed_scan_receipt(slot, channels, &output),
                },
            );
            completed_slots.push(slot);

            // 12-02: deterministic mid-batch bridge death. The short sleep
            // gives the stdout writer thread time to drain and flush the
            // scan.frameCompleted line before process::exit tears every
            // thread down without running destructors.
            if crash_after_frame_completed == Some(slot) {
                thread::sleep(Duration::from_millis(50));
                std::process::exit(1);
            }
        }
        emit_event(
            &tx,
            "scan.completed",
            BridgeScanCompletedPayload {
                job_id,
                summary: BridgeScanCompletedSummary {
                    completed: completed_slots,
                    failed: failed_slots,
                    stopped: false,
                },
            },
        );
    });
}

fn fixed_scan_receipt(
    slot: u32,
    channels: BridgeChannels,
    output: &BridgeOutputSpec,
) -> BridgeScanReceipt {
    let (destination, filename_template) = output
        .slot_outputs
        .as_ref()
        .and_then(|values| values.get(&slot.to_string()))
        .map(|value| {
            (
                value.destination.as_str(),
                value.filename_template.as_str(),
            )
        })
        .unwrap_or((&output.destination, &output.filename_template));
    let rgb_path = std::path::Path::new(destination)
        .join(scanstudio_engine::render::resolve_filename(
            filename_template,
            slot,
        ));
    std::fs::create_dir_all(
        rgb_path
            .parent()
            .expect("mock bridge output path must have a parent"),
    )
    .expect("mock bridge must create its requested output directory");
    let tile = ImageBuffer::from_fn(8, 6, |x, y| {
        Rgb([
            (x * 700 + slot * 17) as u16,
            (y * 900 + slot * 19) as u16,
            ((x + y) * 500 + slot * 23) as u16,
        ])
    });
    tile.save(&rgb_path)
        .expect("mock bridge must write its reported RGB archive fixture");
    let sidecar = |suffix: &str| {
        let stem = rgb_path
            .file_stem()
            .and_then(|value| value.to_str())
            .expect("mock bridge archive must have a UTF-8 stem");
        rgb_path.with_file_name(format!("{stem}_{suffix}.tif"))
    };
    let ir_path = (channels == BridgeChannels::Rgbi).then(|| sidecar("IR"));
    if let Some(path) = ir_path.as_ref() {
        tile.save(path)
            .expect("mock bridge must write its reported IR sidecar fixture");
    }
    let meter_path = sidecar("METER");
    tile.save(&meter_path)
        .expect("mock bridge must write its reported meter sidecar fixture");
    let raw_export = match output.slot_outputs.as_ref() {
        Some(slot_outputs) => slot_outputs
            .get(&slot.to_string())
            .and_then(|slot_output| slot_output.raw_export.as_ref()),
        None => output.raw_export.as_ref(),
    };
    let raw_export_path = raw_export.map(|spec| {
        let path = std::path::Path::new(&spec.destination).join(
            scanstudio_engine::render::resolve_filename(&spec.filename_template, slot),
        );
        std::fs::create_dir_all(path.parent().expect("mock raw output has a parent"))
            .expect("mock bridge must create its requested raw output directory");
        tile.save_with_format(&path, image::ImageFormat::Tiff)
            .expect("mock bridge must create its reported raw export fixture");
        path
    });
    let raw_export_ir_path = raw_export.zip(raw_export_path.as_ref()).and_then(|(spec, raw)| {
        (channels == BridgeChannels::Rgbi
            && spec.tiff_infrared == BridgeRawTiffInfrared::Sidecar)
            .then(|| {
                let stem = raw
                    .file_stem()
                    .and_then(|value| value.to_str())
                    .expect("mock raw output has a UTF-8 stem");
                let path = raw.with_file_name(format!("{stem}-ir.tif"));
                tile.save_with_format(&path, image::ImageFormat::Tiff)
                    .expect("mock bridge must create its reported raw IR fixture");
                path.display().to_string()
            })
    });

    BridgeScanReceipt {
        version: 1,
        slot,
        spacing_offset: 3,
        dpi: 4000,
        depth: 16,
        device_id: DEVICE_ID.to_string(),
        device_model: "SUPER COOLSCAN 5000 ED".to_string(),
        reviewed_fingerprint_sha256: "mock-fingerprint-0001".to_string(),
        fresh_fingerprint_sha256: "mock-fingerprint-0001".to_string(),
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
            method: "laplacian-variance".to_string(),
            verdict: "measured".to_string(),
            score: Some(180.0),
            texture_span: 0.7,
        },
        transport_smear: BridgeTransportSmearAssessment {
            verdict: "clean".to_string(),
            start_row: None,
            suffix_rows: 0,
            minimum_matches: 0,
            tail_median_rms: None,
            tail_min_corr: None,
            pre_tail_median_rms: None,
            texture_span: None,
            reason: "no repeated tail rows detected".to_string(),
        },
        artifacts: std::collections::HashMap::new(),
        storage_transform:
            "swapaxes01-scanner-native-to-nikon-render-parity-v2".to_string(),
        rgb_path: rgb_path.display().to_string(),
        ir_path: ir_path.map(|path| path.display().to_string()),
        meter_rgbi_path: Some(meter_path.display().to_string()),
        raw_export_path: raw_export_path.map(|path| path.display().to_string()),
        raw_export_ir_path,
        attempts_root: None,
        exposure_authority: None,
        started_at: Some("2026-08-02T20:05:00+00:00".to_string()),
        capture_duration_ms: Some(1900),
    }
}

fn parse_params<T: serde::de::DeserializeOwned>(
    params: &serde_json::Value,
) -> Result<T, (BridgeErrorCode, String)> {
    // Mirrors server.rs's own parse_params: "params may be omitted" means
    // `BridgeRequest.params` decodes to `Value::Null`, which serde_json
    // can never deserialize a struct from directly — treat omitted the
    // same as an explicit empty object.
    let value = if params.is_null() {
        serde_json::Value::Object(serde_json::Map::new())
    } else {
        params.clone()
    };
    serde_json::from_value(value).map_err(|err| {
        (
            BridgeErrorCode::InvalidParams,
            format!("invalid params: {err}"),
        )
    })
}

fn to_json<T: Serialize>(value: &T) -> Result<serde_json::Value, (BridgeErrorCode, String)> {
    serde_json::to_value(value).map_err(|err| {
        (
            BridgeErrorCode::Internal,
            format!("failed to serialize result: {err}"),
        )
    })
}

fn emit_event<T: Serialize>(tx: &mpsc::Sender<String>, event_name: &str, payload: T) {
    let event = BridgeEvent::new(event_name, payload);
    match serde_json::to_string(&event) {
        Ok(line) => {
            let _ = tx.send(line);
        }
        Err(err) => {
            eprintln!("mock_bridge: failed to serialize event '{event_name}': {err}");
        }
    }
}

fn respond_ok(tx: &mpsc::Sender<String>, id: u64, result: serde_json::Value) {
    let response = BridgeResponse::new(id, result);
    match serde_json::to_string(&response) {
        Ok(line) => {
            let _ = tx.send(line);
        }
        Err(err) => {
            eprintln!("mock_bridge: failed to serialize response for id {id}: {err}");
        }
    }
}

fn respond_error(tx: &mpsc::Sender<String>, id: u64, code: BridgeErrorCode, message: &str) {
    let payload = BridgeErrorPayload {
        code,
        message: message.to_string(),
        recoverable: false,
    };
    let response = BridgeErrorResponse::new(id, payload);
    match serde_json::to_string(&response) {
        Ok(line) => {
            let _ = tx.send(line);
        }
        Err(err) => {
            eprintln!("mock_bridge: failed to serialize error response for id {id}: {err}");
        }
    }
}
