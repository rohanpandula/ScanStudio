//! Simulated LS-5000 backend (`SimulatedLs5000`): deterministic thumbnails,
//! timed multisample scan jobs, safe stop-after-frame, and opt-in fault
//! injection. No USB/SCSI/hardware I/O of any kind (D-20) — every delay is a
//! `thread::sleep` scaled by `timeScale`.

use std::collections::{HashMap, HashSet};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Mutex,
};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::domain::{
    frame_state_can_transition, job_state_can_transition, CaptureRecipe, Channels, DeviceInfo,
    EngineError, FilmProcess, FrameOverrides, FrameState, JobState, MediaCarrier, OutputRecipe,
    ProcessingRecipe, ScanReceipt, ScannerBackend, WrittenOutputs,
};
use crate::protocol::{
    ConnectOptions, ConnectResult, ErrorCode, ErrorPayload, Event, FaultInjection,
    FrameCompletedPayload, FrameStatePayload, JobStatePayload, Lamp, ScanCompletedPayload,
    ScanProgressPayload, ScanSummary, ScannerStatus, StopMode, Thumbnail, ThumbnailPayload,
    ThumbnailsCompletePayload, Transport,
};

const DEVICE_ID: &str = "sim-ls5000-0";

// ---------------------------------------------------------------------
// Determinism (D-08, SIM-03)
// ---------------------------------------------------------------------

/// FNV-1a 64 over ASCII bytes. Offset basis and prime per PROTOCOL.md
/// "Determinism".
pub fn fnv1a64(input: &str) -> u64 {
    const OFFSET_BASIS: u64 = 14695981039346656037;
    const PRIME: u64 = 1099511628211;
    let mut hash = OFFSET_BASIS;
    for byte in input.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(PRIME);
    }
    hash
}

/// `brightness = 0.25 + 0.6 * (((h >> 8) & 0xFFFF) / 65535.0)`,
/// `tint = (((h >> 24) & 0xFF) / 255.0) - 0.5`, hashing
/// `"{deviceId}:{frameIndex}"`.
pub fn thumbnail_for(device_id: &str, frame_index: u32) -> Thumbnail {
    let h = fnv1a64(&format!("{device_id}:{frame_index}"));
    let brightness = 0.25 + 0.6 * (((h >> 8) & 0xFFFF) as f64 / 65535.0);
    let tint = (((h >> 24) & 0xFF) as f64 / 255.0) - 0.5;
    Thumbnail {
        brightness: Some(brightness),
        tint: Some(tint),
        image_path: None,
        boundary_rows: None,
        spacing_offset: None,
        needs_approval: false,
        warnings: vec![],
    }
}

/// Lowercase 16-hex-char FNV-1a 64 of
/// `"{resolutionDpi}:{bitDepth}:{multisamplePasses}:{channels}"`.
pub fn settings_fingerprint(recipe: &CaptureRecipe) -> String {
    let s = format!(
        "{}:{}:{}:{}",
        recipe.resolution_dpi,
        recipe.bit_depth,
        recipe.multisample_passes,
        channels_str(recipe.channels)
    );
    format!("{:016x}", fnv1a64(&s))
}

fn channels_str(channels: Channels) -> &'static str {
    match channels {
        Channels::Rgb => "rgb",
        Channels::Rgbi => "rgbi",
    }
}

// ---------------------------------------------------------------------
// Dependency-free ISO-8601 UTC formatter (D-03 forbids chrono/time).
// Howard Hinnant's public-domain civil_from_days algorithm:
// http://howardhinnant.github.io/date_algorithms.html
// ---------------------------------------------------------------------

fn civil_from_days(days_since_epoch: i64) -> (i64, u32, u32) {
    let z = days_since_epoch + 719468;
    let era: i64 = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe: u64 = (z - era * 146097) as u64; // [0, 146096]
    let yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y: i64 = yoe as i64 + era * 400;
    let doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp: u64 = (5 * doy + 2) / 153; // [0, 11]
    let d: u64 = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m: u64 = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y_final: i64 = if m <= 2 { y + 1 } else { y };
    (y_final, m as u32, d as u32)
}

/// Formats a Unix timestamp (seconds since epoch) as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn format_iso8601(unix_secs: i64) -> String {
    let days = unix_secs.div_euclid(86400);
    let secs_of_day = unix_secs.rem_euclid(86400);
    let (year, month, day) = civil_from_days(days);
    let hour = secs_of_day / 3600;
    let minute = (secs_of_day % 3600) / 60;
    let second = secs_of_day % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

fn now_unix_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

// ---------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------

struct JobRecord {
    job_id: String,
    state: JobState,
    stop_request: Option<StopMode>,
    skip_current_requested: bool,
    frame_states: HashMap<u32, FrameState>,
}

fn is_job_terminal(state: JobState) -> bool {
    matches!(
        state,
        JobState::Completed | JobState::Stopped | JobState::Failed
    )
}

struct State {
    connected: bool,
    adapter: Option<String>,
    media_loaded: bool,
    carrier: Option<MediaCarrier>,
    frame_count: Option<u32>,
    lamp: Lamp,
    transport: Transport,
    job_slot: Option<JobRecord>,
    time_scale: f64,
    fault_injection: FaultInjection,
    job_seq: u64,
    thumbnail_operation_active: bool,
}

impl Default for State {
    fn default() -> Self {
        State {
            connected: false,
            adapter: None,
            media_loaded: false,
            carrier: None,
            frame_count: None,
            lamp: Lamp::Off,
            transport: Transport::Idle,
            job_slot: None,
            time_scale: 1.0,
            fault_injection: FaultInjection::NoFault,
            job_seq: 0,
            thumbnail_operation_active: false,
        }
    }
}

fn job_is_active(state: &State) -> bool {
    state
        .job_slot
        .as_ref()
        .map(|j| !is_job_terminal(j.state))
        .unwrap_or(false)
}

fn transport_is_busy(state: &State) -> bool {
    job_is_active(state) || state.thumbnail_operation_active
}

fn status_snapshot(state: &State) -> ScannerStatus {
    let active_job_id = state.job_slot.as_ref().and_then(|j| {
        if is_job_terminal(j.state) {
            None
        } else {
            Some(j.job_id.clone())
        }
    });
    ScannerStatus {
        connected: state.connected,
        adapter: state.adapter.clone(),
        media_loaded: state.media_loaded,
        carrier: state.carrier,
        frame_count: state.frame_count,
        lamp: state.lamp,
        transport: state.transport,
        active_job_id,
        // The simulator has no bridge-side SAFE-02 latch to inspect.
        motion_armed: None,
        // The simulator has no bridge to source a real film-presence read
        // from.
        film_present: None,
    }
}

// ---------------------------------------------------------------------
// SimulatedLs5000
// ---------------------------------------------------------------------

pub struct SimulatedLs5000 {
    device: DeviceInfo,
    state: Mutex<State>,
    cancelled: AtomicBool,
}

impl SimulatedLs5000 {
    pub fn new() -> Self {
        SimulatedLs5000 {
            device: DeviceInfo {
                device_id: DEVICE_ID.to_string(),
                model: "SUPER COOLSCAN 5000 ED".to_string(),
                kind: "simulated".to_string(),
                firmware: "1.03-sim".to_string(),
                connection: "USB (simulated)".to_string(),
            },
            state: Mutex::new(State::default()),
            cancelled: AtomicBool::new(false),
        }
    }

    /// `scanner.list` is device discovery, independent of connection state
    /// — always exactly one simulated device in M1. Not part of
    /// `ScannerBackend` since it doesn't touch backend connection state.
    pub fn device_info(&self) -> DeviceInfo {
        self.device.clone()
    }

    /// Marks the job's currently-active frame to be abandoned rather than
    /// completed, without stopping the rest of the batch — unlike
    /// `scan_stop`, the job continues to its next frame once the active
    /// attempt notices the request. Not part of `ScannerBackend`:
    /// real-hardware skip-current-frame is Phase 11's own concern.
    pub fn scan_skip_current_frame(&self, job_id: &str) -> Result<bool, EngineError> {
        let mut state = self.state.lock().unwrap();
        match state.job_slot.as_mut() {
            Some(job) if job.job_id == job_id => {
                if is_job_terminal(job.state) {
                    Ok(false)
                } else {
                    job.skip_current_requested = true;
                    Ok(true)
                }
            }
            _ => Err(EngineError::new(
                ErrorCode::UnknownJob,
                format!("unknown job id '{job_id}'"),
            )),
        }
    }
}

impl Default for SimulatedLs5000 {
    fn default() -> Self {
        Self::new()
    }
}

impl ScannerBackend for SimulatedLs5000 {
    fn connect(
        &self,
        device_id: &str,
        options: &ConnectOptions,
    ) -> Result<ConnectResult, EngineError> {
        if device_id != DEVICE_ID {
            return Err(EngineError::new(
                ErrorCode::UnknownDevice,
                format!("unknown device id '{device_id}'"),
            ));
        }
        let mut state = self.state.lock().unwrap();
        if state.connected {
            return Err(EngineError::new(
                ErrorCode::AlreadyConnected,
                "scanner is already connected",
            ));
        }
        state.connected = true;
        state.adapter = None;
        state.media_loaded = false;
        state.carrier = None;
        state.frame_count = None;
        // No explicit warmup timing is specified by PROTOCOL.md; go
        // straight to Stable; no warmup timing is modeled.
        state.lamp = Lamp::Stable;
        state.transport = Transport::Idle;
        state.job_slot = None;
        state.time_scale = if options.time_scale > 0.0 {
            options.time_scale
        } else {
            1.0
        };
        state.fault_injection = options.fault_injection.clone();
        self.cancelled.store(false, Ordering::Release);

        let status = status_snapshot(&state);
        Ok(ConnectResult {
            device: self.device.clone(),
            status,
        })
    }

    fn disconnect(&self) -> Result<ScannerStatus, EngineError> {
        let mut state = self.state.lock().unwrap();
        if !state.connected {
            return Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            ));
        }
        if transport_is_busy(&state) {
            return Err(EngineError::new(
                ErrorCode::ScannerBusy,
                "cannot disconnect while a scanner transport operation is active",
            ));
        }
        state.connected = false;
        state.adapter = None;
        state.media_loaded = false;
        state.carrier = None;
        state.frame_count = None;
        state.lamp = Lamp::Off;
        state.transport = Transport::Idle;
        Ok(status_snapshot(&state))
    }

    fn status(&self) -> Result<ScannerStatus, EngineError> {
        let state = self.state.lock().unwrap();
        if !state.connected {
            return Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            ));
        }
        Ok(status_snapshot(&state))
    }

    fn load_media(&self, carrier: MediaCarrier) -> Result<ScannerStatus, EngineError> {
        let mut state = self.state.lock().unwrap();
        if !state.connected {
            return Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            ));
        }
        if transport_is_busy(&state) {
            return Err(EngineError::new(
                ErrorCode::ScannerBusy,
                "cannot load media while a scanner transport operation is active",
            ));
        }
        let (frame_count, adapter) = match carrier {
            MediaCarrier::Roll36 => (36, "SA-30 (simulated)"),
            MediaCarrier::Strip6 => (6, "SA-21 (simulated)"),
            MediaCarrier::Mounted => (1, "MA-21 (simulated)"),
        };
        state.media_loaded = true;
        state.carrier = Some(carrier);
        state.frame_count = Some(frame_count);
        state.adapter = Some(adapter.to_string());
        Ok(status_snapshot(&state))
    }

    fn eject(&self) -> Result<ScannerStatus, EngineError> {
        let mut state = self.state.lock().unwrap();
        if !state.connected {
            return Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            ));
        }
        if !state.media_loaded {
            return Err(EngineError::new(ErrorCode::NoMedia, "no media is loaded"));
        }
        // Safety-critical (SAFE-01): refuse regardless of what any client
        // does, enforced here inside the engine.
        if transport_is_busy(&state) {
            let job_id = state
                .job_slot
                .as_ref()
                .map(|j| j.job_id.as_str())
                .unwrap_or("?");
            return Err(EngineError::new(
                ErrorCode::ScannerBusy,
                format!("Eject refused: scanner transport operation {job_id} is active"),
            ));
        }
        state.media_loaded = false;
        state.carrier = None;
        state.frame_count = None;
        state.adapter = None;
        Ok(status_snapshot(&state))
    }

    fn acquire_thumbnails(
        backend: &Arc<Self>,
        frames: Option<Vec<u32>>,
        _film_process: FilmProcess,
        operation_id: Option<String>,
        event_tx: mpsc::Sender<String>,
    ) -> Result<Vec<u32>, EngineError> {
        let (accepted_frames, time_scale, device_id) = {
            let mut state = backend.state.lock().unwrap();
            if !state.connected {
                return Err(EngineError::new(
                    ErrorCode::NotConnected,
                    "scanner is not connected",
                ));
            }
            if !state.media_loaded {
                return Err(EngineError::new(ErrorCode::NoMedia, "no media is loaded"));
            }
            if transport_is_busy(&state) {
                return Err(EngineError::new(
                    ErrorCode::ScannerBusy,
                    "a scanner transport operation is active",
                ));
            }
            let frame_count = state.frame_count.unwrap_or(0);
            let accepted = frames.unwrap_or_else(|| (1..=frame_count).collect());
            state.transport = Transport::Busy;
            state.thumbnail_operation_active = true;
            (accepted, state.time_scale, backend.device.device_id.clone())
        };

        let thread_frames = accepted_frames.clone();
        let backend_for_thread = Arc::clone(backend);
        thread::spawn(move || {
            let tick_ms = scale_ms(80, time_scale).max(1);
            for &frame_index in &thread_frames {
                if !sleep_until_or_cancelled(&backend_for_thread, tick_ms) {
                    return;
                }
                let thumbnail = thumbnail_for(&device_id, frame_index);
                emit(
                    &event_tx,
                    "scanner.thumbnail",
                    ThumbnailPayload {
                        frame_index,
                        thumbnail,
                        operation_id: operation_id.clone(),
                    },
                );
            }
            if backend_for_thread.cancelled.load(Ordering::Acquire) {
                return;
            }
            emit(
                &event_tx,
                "scanner.thumbnailsComplete",
                ThumbnailsCompletePayload {
                    count: thread_frames.len() as u32,
                    operation_id: operation_id.clone(),
                },
            );
            let mut state = backend_for_thread.state.lock().unwrap();
            state.thumbnail_operation_active = false;
            if !job_is_active(&state) {
                state.transport = Transport::Idle;
            }
            let status = status_snapshot(&state);
            drop(state);
            emit(
                &event_tx,
                "scanner.status",
                crate::protocol::ScannerStatusPayload {
                    status,
                    operation_id,
                },
            );
        });

        Ok(accepted_frames)
    }

    fn scan_start(
        backend: &Arc<Self>,
        frames: Vec<u32>,
        recipe: CaptureRecipe,
        processing: ProcessingRecipe,
        output: OutputRecipe,
        overrides: std::collections::HashMap<u32, FrameOverrides>,
        project_directory: Option<std::path::PathBuf>,
        event_tx: mpsc::Sender<String>,
    ) -> Result<String, EngineError> {
        let (job_id, time_scale, fault_injection) = {
            let mut state = backend.state.lock().unwrap();
            if !state.connected {
                return Err(EngineError::new(
                    ErrorCode::NotConnected,
                    "scanner is not connected",
                ));
            }
            if !state.media_loaded {
                return Err(EngineError::new(ErrorCode::NoMedia, "no media is loaded"));
            }
            if transport_is_busy(&state) {
                return Err(EngineError::new(
                    ErrorCode::ScannerBusy,
                    "a scanner transport operation is already active",
                ));
            }
            let frame_count = state.frame_count.unwrap_or(0);
            if frames.is_empty() {
                return Err(EngineError::new(
                    ErrorCode::InvalidParams,
                    "frames must not be empty",
                ));
            }
            if frames.iter().any(|&f| f < 1 || f > frame_count) {
                return Err(EngineError::new(
                    ErrorCode::InvalidParams,
                    format!("frame indices must be within 1..={frame_count}"),
                ));
            }
            let mut unique_frames = HashSet::with_capacity(frames.len());
            if !frames.iter().all(|frame| unique_frames.insert(*frame)) {
                return Err(EngineError::new(
                    ErrorCode::InvalidParams,
                    "frames must not contain duplicate indices",
                ));
            }
            // Load-bearing hardening (not just descriptive-only anymore):
            // resolutionDpi now directly drives render::generate_sim_frame's
            // pixel-buffer allocation, so an unbounded value could allocate
            // an unreasonable amount of memory.
            if recipe.resolution_dpi == 0 || recipe.resolution_dpi > 4_000 {
                return Err(EngineError::new(
                    ErrorCode::InvalidParams,
                    "resolutionDpi must be between 1 and 4000 (the LS-5000's native maximum)",
                ));
            }
            if !matches!(recipe.bit_depth, 8 | 16) {
                return Err(EngineError::new(
                    ErrorCode::InvalidParams,
                    "bitDepth must be 8 or 16",
                ));
            }
            if !matches!(recipe.multisample_passes, 1 | 2 | 4 | 8 | 16) {
                return Err(EngineError::new(
                    ErrorCode::InvalidParams,
                    "multisamplePasses must be one of 1, 2, 4, 8, 16",
                ));
            }

            state.job_seq += 1;
            let job_id = format!("job-{}", state.job_seq);
            state.job_slot = Some(JobRecord {
                job_id: job_id.clone(),
                state: JobState::Queued,
                stop_request: None,
                skip_current_requested: false,
                frame_states: frames
                    .iter()
                    .copied()
                    .map(|frame| (frame, FrameState::Waiting))
                    .collect(),
            });
            state.transport = Transport::Busy;
            (job_id, state.time_scale, state.fault_injection.clone())
        };

        let backend_for_thread = Arc::clone(backend);
        let thread_job_id = job_id.clone();
        thread::spawn(move || {
            run_scan_job(
                backend_for_thread,
                thread_job_id,
                frames,
                recipe,
                processing,
                output,
                overrides,
                project_directory,
                time_scale,
                fault_injection,
                event_tx,
            );
        });

        Ok(job_id)
    }

    fn scan_stop(
        &self,
        job_id: &str,
        mode: StopMode,
        event_tx: mpsc::Sender<String>,
    ) -> Result<(bool, StopMode), EngineError> {
        let mut state = self.state.lock().unwrap();
        match state.job_slot.as_mut() {
            Some(job) if job.job_id == job_id => {
                if is_job_terminal(job.state) {
                    Ok((false, mode))
                } else {
                    job.stop_request = Some(mode);
                    let stopping = match mode {
                        StopMode::AfterCurrentFrame => JobState::StoppingAfterCurrentFrame,
                        StopMode::Immediate => JobState::StoppingImmediately,
                    };
                    if job_state_can_transition(job.state, stopping) {
                        job.state = stopping;
                        let job_id = job.job_id.clone();
                        let status = status_snapshot(&state);
                        drop(state);
                        emit(
                            &event_tx,
                            "scan.jobState",
                            JobStatePayload {
                                job_id,
                                state: stopping,
                            },
                        );
                        emit(
                            &event_tx,
                            "scanner.status",
                            crate::protocol::ScannerStatusPayload {
                                status,
                                operation_id: None,
                            },
                        );
                    }
                    Ok((true, mode))
                }
            }
            _ => Err(EngineError::new(
                ErrorCode::UnknownJob,
                format!("unknown job id '{job_id}'"),
            )),
        }
    }

    fn shutdown(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

// ---------------------------------------------------------------------
// Worker-thread job execution
// ---------------------------------------------------------------------

fn scale_ms(base_ms: u64, time_scale: f64) -> u64 {
    ((base_ms as f64) * time_scale).round().max(0.0) as u64
}

fn take_stop_request(backend: &Arc<SimulatedLs5000>, job_id: &str) -> Option<StopMode> {
    let mut state = backend.state.lock().unwrap();
    state.job_slot.as_mut().and_then(|job| {
        if job.job_id == job_id {
            job.stop_request.take()
        } else {
            None
        }
    })
}

fn peek_stop_request(backend: &Arc<SimulatedLs5000>, job_id: &str) -> Option<StopMode> {
    let state = backend.state.lock().unwrap();
    state.job_slot.as_ref().and_then(|job| {
        if job.job_id == job_id {
            job.stop_request
        } else {
            None
        }
    })
}

fn take_skip_current_request(backend: &Arc<SimulatedLs5000>, job_id: &str) -> bool {
    let mut state = backend.state.lock().unwrap();
    if let Some(job) = state.job_slot.as_mut().filter(|j| j.job_id == job_id) {
        if job.skip_current_requested {
            job.skip_current_requested = false;
            return true;
        }
    }
    false
}

fn set_job_state(backend: &Arc<SimulatedLs5000>, job_id: &str, new_state: JobState) -> bool {
    let mut state = backend.state.lock().unwrap();
    if let Some(job) = state.job_slot.as_mut() {
        if job.job_id == job_id {
            if !job_state_can_transition(job.state, new_state) {
                return false;
            }
            job.state = new_state;
            return true;
        }
    }
    false
}

fn set_frame_state(
    backend: &Arc<SimulatedLs5000>,
    job_id: &str,
    frame: u32,
    new_state: FrameState,
) -> bool {
    let mut state = backend.state.lock().unwrap();
    let Some(job) = state.job_slot.as_mut().filter(|job| job.job_id == job_id) else {
        return false;
    };
    let Some(previous) = job.frame_states.get(&frame).copied() else {
        return false;
    };
    if !frame_state_can_transition(previous, new_state) {
        return false;
    }
    job.frame_states.insert(frame, new_state);
    true
}

fn clear_transport_if_idle(backend: &Arc<SimulatedLs5000>) {
    let mut state = backend.state.lock().unwrap();
    state.transport = Transport::Idle;
}

fn emit_status(backend: &Arc<SimulatedLs5000>, event_tx: &mpsc::Sender<String>) {
    let status = { status_snapshot(&backend.state.lock().unwrap()) };
    emit(
        event_tx,
        "scanner.status",
        crate::protocol::ScannerStatusPayload {
            status,
            operation_id: None,
        },
    );
}

fn sleep_until_or_cancelled(backend: &Arc<SimulatedLs5000>, total_ms: u64) -> bool {
    let mut left = total_ms;
    while left > 0 {
        if backend.cancelled.load(Ordering::Acquire) {
            return false;
        }
        let step = left.min(10);
        thread::sleep(Duration::from_millis(step));
        left -= step;
    }
    !backend.cancelled.load(Ordering::Acquire)
}

fn emit<T: Serialize>(event_tx: &mpsc::Sender<String>, event_name: &str, payload: T) {
    let event = Event::new(event_name, payload);
    match serde_json::to_string(&event) {
        Ok(line) => {
            let _ = event_tx.send(line);
        }
        Err(err) => {
            eprintln!("scanstudio-engine: failed to serialize event '{event_name}': {err}");
        }
    }
}

fn pass_number_for(elapsed_ms: u64, overhead_ms: u64, pass_ms: u64, total_passes: u32) -> u32 {
    if elapsed_ms <= overhead_ms || pass_ms == 0 {
        return 1;
    }
    let into_passes = elapsed_ms - overhead_ms;
    let pass = (into_passes / pass_ms) as u32 + 1;
    pass.min(total_passes.max(1))
}

#[allow(clippy::too_many_arguments)]
fn build_receipt(
    job_id: &str,
    frame_index: u32,
    duration_ms: u64,
    recipe: &CaptureRecipe,
    processing: &ProcessingRecipe,
    output: &OutputRecipe,
    device_id: &str,
    written: &crate::render::WrittenPaths,
) -> ScanReceipt {
    let now = now_unix_secs();
    let started_at_secs = now - (duration_ms as i64 / 1000).max(0);
    ScanReceipt {
        job_id: job_id.to_string(),
        frame_index,
        started_at: format_iso8601(started_at_secs),
        duration_ms,
        passes: recipe.multisample_passes,
        resolution_dpi: recipe.resolution_dpi,
        bit_depth: recipe.bit_depth,
        channels: channels_str(recipe.channels).to_string(),
        engine_version: env!("CARGO_PKG_VERSION").to_string(),
        device_id: device_id.to_string(),
        simulated: true,
        settings_fingerprint: settings_fingerprint(recipe),
        processing: Some(processing.clone()),
        output: Some(crate::render::receipt_output_recipe(output)),
        outputs: Some(WrittenOutputs {
            archive_path: written
                .archive_path
                .as_ref()
                .map(|path| path.display().to_string()),
            positive_path: written
                .positive_path
                .as_ref()
                .map(|p| p.display().to_string()),
            preview_path: written
                .preview_path
                .as_ref()
                .map(|p| p.display().to_string()),
        }),
        // Bridge-only concepts — the simulator has no bridge subprocess to
        // source a capture-file location or hardware telemetry from.
        rgb_path: None,
        ir_path: None,
        storage_transform: None,
        meter_rgbi_path: None,
        hardware_telemetry: None,
        nikonlook: written.nikonlook.clone(),
    }
}

enum AttemptOutcome {
    Completed,
    Faulted,
    AbortedImmediately,
    SkippedByUser,
}

#[allow(clippy::too_many_arguments)]
fn run_one_attempt(
    backend: &Arc<SimulatedLs5000>,
    job_id: &str,
    frame_index: u32,
    frame_ordinal: u32,
    total_frames: u32,
    attempt: u32,
    frame_total_ms: u64,
    overhead_ms: u64,
    pass_ms: u64,
    tick_ms: u64,
    total_passes: u32,
    check_fault: bool,
    event_tx: &mpsc::Sender<String>,
) -> AttemptOutcome {
    let mut elapsed_ms: u64 = 0;

    if frame_total_ms == 0 {
        return AttemptOutcome::Completed;
    }

    while elapsed_ms < frame_total_ms {
        if let Some(StopMode::Immediate) = peek_stop_request(backend, job_id) {
            take_stop_request(backend, job_id);
            return AttemptOutcome::AbortedImmediately;
        }

        if take_skip_current_request(backend, job_id) {
            return AttemptOutcome::SkippedByUser;
        }

        let step = tick_ms.min(frame_total_ms - elapsed_ms);
        if !sleep_until_or_cancelled(backend, step) {
            return AttemptOutcome::AbortedImmediately;
        }
        elapsed_ms += step;

        let frame_percent = (elapsed_ms as f64 / frame_total_ms as f64) * 100.0;
        let pass = pass_number_for(elapsed_ms, overhead_ms, pass_ms, total_passes);
        let job_percent =
            ((frame_ordinal - 1) as f64 * 100.0 + frame_percent) / total_frames as f64;
        let remaining_this_frame_ms = frame_total_ms.saturating_sub(elapsed_ms);
        // Documented approximation, not an exact remaining-time calculation:
        // assumes every remaining frame takes as long as this one. Now that
        // per-frame timing can vary via overrides, that assumption no
        // longer holds exactly for a batch mixing overridden and
        // roll-default frames -- eta_seconds stays a best-effort estimate,
        // never a hard guarantee.
        let remaining_other_frames_ms = (total_frames - frame_ordinal) as u64 * frame_total_ms;
        let eta_seconds = (remaining_this_frame_ms + remaining_other_frames_ms) as f64 / 1000.0;

        emit(
            event_tx,
            "scan.progress",
            ScanProgressPayload {
                job_id: job_id.to_string(),
                frame_index,
                frame_ordinal,
                total_frames,
                pass,
                total_passes,
                frame_percent,
                job_percent,
                eta_seconds,
            },
        );

        if check_fault && attempt == 1 && frame_percent >= 40.0 {
            let _ = set_frame_state(backend, job_id, frame_index, FrameState::Failed);
            emit(
                event_tx,
                "scan.frameState",
                FrameStatePayload {
                    job_id: job_id.to_string(),
                    frame_index,
                    state: FrameState::Failed,
                    attempt,
                    error: Some(ErrorPayload {
                        code: ErrorCode::FeedJam,
                        message: format!("Simulated feed jam on frame {frame_index}"),
                        recoverable: true,
                    }),
                },
            );
            return AttemptOutcome::Faulted;
        }
    }

    AttemptOutcome::Completed
}

#[allow(clippy::too_many_arguments)]
fn run_scan_job(
    backend: Arc<SimulatedLs5000>,
    job_id: String,
    frames: Vec<u32>,
    recipe: CaptureRecipe,
    processing: ProcessingRecipe,
    output: OutputRecipe,
    overrides: HashMap<u32, FrameOverrides>,
    project_directory: Option<std::path::PathBuf>,
    time_scale: f64,
    fault_injection: FaultInjection,
    event_tx: mpsc::Sender<String>,
) {
    let device_id = backend.device.device_id.clone();
    let carrier = backend
        .state
        .lock()
        .unwrap()
        .carrier
        .unwrap_or(MediaCarrier::Roll36);

    // Tiny window between scan_start's bookkeeping and this thread's first
    // tick: honor a stop request that arrived before we could even start
    // ("queued -> stopped" direct edge).
    if take_stop_request(&backend, &job_id).is_some() {
        set_job_state(&backend, &job_id, JobState::Stopped);
        emit(
            &event_tx,
            "scan.jobState",
            JobStatePayload {
                job_id: job_id.clone(),
                state: JobState::Stopped,
            },
        );
        emit(
            &event_tx,
            "scan.completed",
            ScanCompletedPayload {
                job_id: job_id.clone(),
                summary: ScanSummary {
                    completed: vec![],
                    failed: vec![],
                    skipped: vec![],
                    stopped: true,
                    duty_cycle: None,
                    evidence_package_status: None,
                },
            },
        );
        clear_transport_if_idle(&backend);
        emit_status(&backend, &event_tx);
        return;
    }

    set_job_state(&backend, &job_id, JobState::Scanning);
    emit(
        &event_tx,
        "scan.jobState",
        JobStatePayload {
            job_id: job_id.clone(),
            state: JobState::Scanning,
        },
    );
    emit_status(&backend, &event_tx);

    let total_frames = frames.len() as u32;
    // The rest of this frame's timing (preparation_ms/overhead_ms/pass_ms/
    // total_passes/frame_total_ms/width/height) now varies per frame via
    // `overrides` -- recomputed inside the loop below, not here. tick_ms
    // never depends on any recipe field, so it stays computed once.
    let tick_ms = scale_ms(150, time_scale).max(1);

    let mut summary = ScanSummary::default();
    let mut stop_seen: Option<StopMode> = None;

    'frames: for (i, &frame_index) in frames.iter().enumerate() {
        let frame_ordinal = i as u32 + 1;
        let is_last_frame = frame_ordinal == total_frames;

        // This frame's own override if present, else the job's roll-wide
        // recipe/processing/output -- the load-bearing resolution this
        // plan exists for. Recomputed every iteration since a different
        // frame can carry a different override.
        let effective_recipe = overrides
            .get(&frame_index)
            .and_then(|o| o.capture.clone())
            .unwrap_or_else(|| recipe.clone());
        let effective_processing = overrides
            .get(&frame_index)
            .and_then(|o| o.processing.clone())
            .unwrap_or_else(|| processing.clone())
            .effective();
        let effective_recipe = effective_recipe.effective_for_process(effective_processing.film_process);
        let effective_output = overrides
            .get(&frame_index)
            .and_then(|o| o.output.clone())
            .unwrap_or_else(|| output.clone());
        let (width, height) =
            crate::render::frame_dimensions(carrier, effective_recipe.resolution_dpi);
        let preparation_ms = 500
            + if effective_processing.autofocus_each_frame {
                350
            } else {
                0
            }
            + if effective_processing.auto_exposure_each_frame {
                250
            } else {
                0
            };
        let overhead_ms = scale_ms(preparation_ms, time_scale);
        let pass_ms = scale_ms(700, time_scale);
        let total_passes = effective_recipe.multisample_passes;
        let frame_total_ms = overhead_ms + pass_ms * total_passes as u64;

        // Stop requested before this frame began — covers both the
        // pre-first-frame race and the normal between-frames case.
        if let Some(mode) = take_stop_request(&backend, &job_id) {
            stop_seen = Some(mode);
            break 'frames;
        }

        let _ = set_frame_state(&backend, &job_id, frame_index, FrameState::Active);
        emit(
            &event_tx,
            "scan.frameState",
            FrameStatePayload {
                job_id: job_id.clone(),
                frame_index,
                state: FrameState::Active,
                attempt: 1,
                error: None,
            },
        );

        let inject_fault = matches!(fault_injection, FaultInjection::Demo) && frame_index == 13;
        let mut attempt: u32 = 1;

        let mut outcome = run_one_attempt(
            &backend,
            &job_id,
            frame_index,
            frame_ordinal,
            total_frames,
            attempt,
            frame_total_ms,
            overhead_ms,
            pass_ms,
            tick_ms,
            total_passes,
            inject_fault,
            &event_tx,
        );

        if matches!(outcome, AttemptOutcome::Faulted) {
            attempt = 2;
            let _ = set_frame_state(&backend, &job_id, frame_index, FrameState::Active);
            emit(
                &event_tx,
                "scan.frameState",
                FrameStatePayload {
                    job_id: job_id.clone(),
                    frame_index,
                    state: FrameState::Active,
                    attempt,
                    error: None,
                },
            );
            outcome = run_one_attempt(
                &backend,
                &job_id,
                frame_index,
                frame_ordinal,
                total_frames,
                attempt,
                frame_total_ms,
                overhead_ms,
                pass_ms,
                tick_ms,
                total_passes,
                false,
                &event_tx,
            );
        }

        match outcome {
            AttemptOutcome::AbortedImmediately => {
                let _ = set_frame_state(&backend, &job_id, frame_index, FrameState::Skipped);
                emit(
                    &event_tx,
                    "scan.frameState",
                    FrameStatePayload {
                        job_id: job_id.clone(),
                        frame_index,
                        state: FrameState::Skipped,
                        attempt,
                        error: None,
                    },
                );
                summary.skipped.push(frame_index);
                stop_seen = Some(StopMode::Immediate);
                break 'frames;
            }
            AttemptOutcome::SkippedByUser => {
                let _ = set_frame_state(&backend, &job_id, frame_index, FrameState::Skipped);
                emit(
                    &event_tx,
                    "scan.frameState",
                    FrameStatePayload {
                        job_id: job_id.clone(),
                        frame_index,
                        state: FrameState::Skipped,
                        attempt,
                        error: None,
                    },
                );
                summary.skipped.push(frame_index);
                // Deliberately does NOT set stop_seen or break 'frames --
                // unlike an immediate stop, the job continues to its next
                // frame.
            }
            AttemptOutcome::Faulted => {
                // Only reachable if a second attempt itself faults, which
                // no fault-injection scenario in M1 triggers (the "demo"
                // fault only ever fires on attempt 1). Handled defensively.
                let _ = set_frame_state(&backend, &job_id, frame_index, FrameState::Failed);
                emit(
                    &event_tx,
                    "scan.frameState",
                    FrameStatePayload {
                        job_id: job_id.clone(),
                        frame_index,
                        state: FrameState::Failed,
                        attempt,
                        error: Some(ErrorPayload {
                            code: ErrorCode::Internal,
                            message: "unexpected repeated fault".to_string(),
                            recoverable: false,
                        }),
                    },
                );
                summary.failed.push(frame_index);
            }
            AttemptOutcome::Completed => {
                // Synthetic detected boundary for the simulator: a deterministic
                // inset relative to the full capture so alignment offsets have a
                // meaningful base region to act on. This is engine-side-only
                // synthetic geometry; a real backend supplies the boundary from
                // its fresh traversal.
                let detected_boundary = {
                    let margin = (height as f64 * 0.05).round() as u32;
                    (margin, height.saturating_sub(margin + 1))
                };
                let effective_alignment = overrides
                    .get(&frame_index)
                    .and_then(|o| o.alignment.as_ref());

                match crate::render::render_and_write_frame_with_processing(
                    &device_id,
                    frame_index,
                    &effective_processing,
                    width,
                    height,
                    effective_recipe.bit_depth,
                    &effective_output,
                    Some(detected_boundary),
                    effective_alignment,
                ) {
                    Ok(written) => {
                        // Load-bearing honesty guarantee: the receipt must show
                        // what was ACTUALLY used for this frame, not the
                        // job-wide request.
                        let receipt = build_receipt(
                            &job_id,
                            frame_index,
                            frame_total_ms,
                            &effective_recipe,
                            &effective_processing,
                            &effective_output,
                            &device_id,
                            &written,
                        );
                        let _ = set_frame_state(
                            &backend,
                            &job_id,
                            frame_index,
                            FrameState::Completed,
                        );
                        emit(
                            &event_tx,
                            "scan.frameState",
                            FrameStatePayload {
                                job_id: job_id.clone(),
                                frame_index,
                                state: FrameState::Completed,
                                attempt,
                                error: None,
                            },
                        );
                        if let Some(directory) = &project_directory {
                            if let Err(err) =
                                crate::manifest::persist_frame_receipt(directory, frame_index, &receipt)
                            {
                                eprintln!("scanstudio-engine: failed to persist frame receipt to manifest: {err}");
                            }
                        }
                        emit(
                            &event_tx,
                            "scan.frameCompleted",
                            FrameCompletedPayload {
                                job_id: job_id.clone(),
                                frame_index,
                                receipt,
                            },
                        );
                        summary.completed.push(frame_index);
                    }
                    Err(write_err) => {
                        // A single frame's write failure (e.g. ARCHIVE_COLLISION)
                        // must not abort the rest of the batch -- mirrors how
                        // AttemptOutcome::Faulted already behaves above.
                        let _ =
                            set_frame_state(&backend, &job_id, frame_index, FrameState::Failed);
                        emit(
                            &event_tx,
                            "scan.frameState",
                            FrameStatePayload {
                                job_id: job_id.clone(),
                                frame_index,
                                state: FrameState::Failed,
                                attempt,
                                error: Some(ErrorPayload {
                                    code: write_err.code,
                                    message: write_err.message.clone(),
                                    recoverable: write_err.recoverable(),
                                }),
                            },
                        );
                        summary.failed.push(frame_index);
                    }
                }
            }
        }

        // Between-frames stop check, with the "last frame anyway" nuance:
        // a stop request that lands exactly as the final frame finishes
        // doesn't truncate anything, so it's left unclaimed and the job
        // completes normally (PROTOCOL.md: "completed when the stopped
        // frame was the last one anyway").
        if !is_last_frame {
            if let Some(mode) = take_stop_request(&backend, &job_id) {
                stop_seen = Some(mode);
                break 'frames;
            }
        }
    }

    if let Some(mode) = stop_seen {
        let stopping_state = match mode {
            StopMode::AfterCurrentFrame => JobState::StoppingAfterCurrentFrame,
            StopMode::Immediate => JobState::StoppingImmediately,
        };
        set_job_state(&backend, &job_id, stopping_state);
        emit(
            &event_tx,
            "scan.jobState",
            JobStatePayload {
                job_id: job_id.clone(),
                state: stopping_state,
            },
        );
    }

    let final_state = if stop_seen.is_some() {
        JobState::Stopped
    } else {
        JobState::Completed
    };
    summary.stopped = stop_seen.is_some();

    set_job_state(&backend, &job_id, final_state);
    emit(
        &event_tx,
        "scan.jobState",
        JobStatePayload {
            job_id: job_id.clone(),
            state: final_state,
        },
    );
    emit(
        &event_tx,
        "scan.completed",
        ScanCompletedPayload {
            job_id: job_id.clone(),
            summary,
        },
    );
    clear_transport_if_idle(&backend);
    emit_status(&backend, &event_tx);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Isolated per-test directory under the OS temp dir — never the
    /// shared `OutputRecipe::default()` destinations, which every process
    /// run reuses. Now that a completed frame writes a REAL archive file
    /// (create-only), any test that lets a job run to completion must not
    /// point at those shared defaults: a second `cargo test` run in the
    /// same environment would find the prior run's archive file still on
    /// disk and spuriously collide.
    fn isolated_output_recipe(label: &str) -> (OutputRecipe, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "scanstudio-sim-test-{label}-{}",
            crate::manifest::generate_project_id()
        ));
        let mut recipe = OutputRecipe::default();
        recipe.archive.destination = dir.join("Archive").display().to_string();
        recipe.positive.destination = dir.join("Positive").display().to_string();
        recipe.preview.destination = dir.join("Preview").display().to_string();
        (recipe, dir)
    }

    #[test]
    fn fnv1a64_matches_golden_thumbnails() {
        for (frame_index, brightness, tint) in [
            (1u32, 0.573579766536965_f64, 0.37058823529411766_f64),
            (13, 0.6080407415884641, -0.3588235294117647),
            (36, 0.6227077134355687, -0.3588235294117647),
        ] {
            let t = thumbnail_for(DEVICE_ID, frame_index);
            assert!(
                (t.brightness.expect("simulator always sets brightness") - brightness).abs()
                    < 1e-9,
                "frame {frame_index} brightness"
            );
            assert!(
                (t.tint.expect("simulator always sets tint") - tint).abs() < 1e-9,
                "frame {frame_index} tint"
            );
            assert!(
                t.image_path.is_none(),
                "simulator must never populate image_path"
            );
        }
    }

    #[test]
    fn settings_fingerprint_matches_golden() {
        let recipe = CaptureRecipe {
            resolution_dpi: 4000,
            bit_depth: 16,
            multisample_passes: 2,
            channels: Channels::Rgbi,
        };
        assert_eq!(settings_fingerprint(&recipe), "1a3d265e0b54bbd2");
    }

    #[test]
    fn build_receipt_carries_written_nikonlook_provenance_through_unchanged() {
        // The one line this test exists to guard: `build_receipt`'s
        // `nikonlook: written.nikonlook.clone()` (unlike real_backend.rs's
        // two-phase `None`-then-patch, the simulator has its
        // `WrittenPaths` in hand before it ever constructs a receipt, so it
        // wires the field directly). Deleting that line and replacing it
        // with `None` would compile fine and, before this test, break
        // nothing else.
        let recipe = CaptureRecipe::default();
        let processing = ProcessingRecipe {
            film_process: FilmProcess::C41ColorNegative,
            ..ProcessingRecipe::default()
        };
        let output = OutputRecipe::default();
        let provenance = crate::domain::NikonlookProvenance {
            bundle_version: "nikonlook-v2".to_string(),
            layer_a_path: crate::domain::NikonlookLayerAPath::Blind,
            gains: [0.7767985641162477, 0.49546023790785987, 0.2824666578885106],
        };
        let written = crate::render::WrittenPaths {
            archive_path: None,
            positive_path: None,
            preview_path: None,
            nikonlook: Some(provenance.clone()),
        };

        let receipt = build_receipt("job-1", 1, 1000, &recipe, &processing, &output, DEVICE_ID, &written);
        assert_eq!(receipt.nikonlook, Some(provenance));

        // The `None` side must also pass through unchanged -- a C41 render
        // is not guaranteed to have provenance either (e.g. a legacy
        // pre-Fix-2 written struct), and build_receipt must not fabricate one.
        let written_none = crate::render::WrittenPaths { nikonlook: None, ..written };
        let receipt_none =
            build_receipt("job-1", 1, 1000, &recipe, &processing, &output, DEVICE_ID, &written_none);
        assert_eq!(receipt_none.nikonlook, None);
    }

    #[test]
    fn iso8601_epoch_zero_canary() {
        assert_eq!(format_iso8601(0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn iso8601_known_date() {
        // 2026-07-22T09:00:00Z, cross-checked independently against a
        // reference implementation before writing this Rust port.
        let days = 20656_i64; // days from 1970-01-01 to 2026-07-22
        let secs = days * 86400 + 9 * 3600;
        assert_eq!(format_iso8601(secs), "2026-07-22T09:00:00Z");
    }

    #[test]
    fn iso8601_pre_epoch_is_handled() {
        assert_eq!(format_iso8601(-1), "1969-12-31T23:59:59Z");
    }

    #[test]
    fn connect_then_load_media_reports_correct_adapter_and_frame_count() {
        let sim = SimulatedLs5000::new();
        let options = ConnectOptions {
            time_scale: 1.0,
            fault_injection: FaultInjection::NoFault,
        };
        sim.connect(DEVICE_ID, &options).expect("connect");
        let status = sim.load_media(MediaCarrier::Roll36).expect("load media");
        assert_eq!(status.frame_count, Some(36));
        assert_eq!(status.adapter.as_deref(), Some("SA-30 (simulated)"));
        assert!(status.media_loaded);
    }

    #[test]
    fn every_supported_carrier_reports_its_frame_count_and_adapter() {
        let sim = SimulatedLs5000::new();
        sim.connect(DEVICE_ID, &ConnectOptions::default())
            .expect("connect");

        for (carrier, frame_count, adapter) in [
            (MediaCarrier::Mounted, 1, "MA-21 (simulated)"),
            (MediaCarrier::Strip6, 6, "SA-21 (simulated)"),
            (MediaCarrier::Roll36, 36, "SA-30 (simulated)"),
        ] {
            let status = sim.load_media(carrier).expect("load carrier");
            assert_eq!(status.carrier, Some(carrier));
            assert_eq!(status.frame_count, Some(frame_count));
            assert_eq!(status.adapter.as_deref(), Some(adapter));
        }
    }

    #[test]
    fn connect_unknown_device_is_rejected() {
        let sim = SimulatedLs5000::new();
        let options = ConnectOptions::default();
        let err = sim.connect("not-a-real-device", &options).unwrap_err();
        assert_eq!(err.code, ErrorCode::UnknownDevice);
    }

    #[test]
    fn double_connect_is_rejected() {
        let sim = SimulatedLs5000::new();
        let options = ConnectOptions::default();
        sim.connect(DEVICE_ID, &options).expect("first connect");
        let err = sim.connect(DEVICE_ID, &options).unwrap_err();
        assert_eq!(err.code, ErrorCode::AlreadyConnected);
    }

    #[test]
    fn eject_without_media_is_no_media() {
        let sim = SimulatedLs5000::new();
        let options = ConnectOptions::default();
        sim.connect(DEVICE_ID, &options).expect("connect");
        let err = sim.eject().unwrap_err();
        assert_eq!(err.code, ErrorCode::NoMedia);
    }

    #[test]
    fn scan_start_rejects_out_of_range_frames() {
        let sim = Arc::new(SimulatedLs5000::new());
        let options = ConnectOptions::default();
        sim.connect(DEVICE_ID, &options).expect("connect");
        sim.load_media(MediaCarrier::Roll36).expect("load media");
        let (tx, _rx) = mpsc::channel();
        let err = SimulatedLs5000::scan_start(
            &sim,
            vec![37],
            CaptureRecipe::default(),
            ProcessingRecipe::default(),
            OutputRecipe::default(),
            HashMap::new(),
            None,
            tx,
        )
        .unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);
    }

    #[test]
    fn scan_start_rejects_empty_frames() {
        let sim = Arc::new(SimulatedLs5000::new());
        let options = ConnectOptions::default();
        sim.connect(DEVICE_ID, &options).expect("connect");
        sim.load_media(MediaCarrier::Roll36).expect("load media");
        let (tx, _rx) = mpsc::channel();
        let err = SimulatedLs5000::scan_start(
            &sim,
            vec![],
            CaptureRecipe::default(),
            ProcessingRecipe::default(),
            OutputRecipe::default(),
            HashMap::new(),
            None,
            tx,
        )
        .unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);
    }

    #[test]
    fn scan_start_rejects_duplicate_frames() {
        let sim = Arc::new(SimulatedLs5000::new());
        let options = ConnectOptions::default();
        sim.connect(DEVICE_ID, &options).expect("connect");
        sim.load_media(MediaCarrier::Roll36).expect("load media");
        let (tx, _rx) = mpsc::channel();
        let err = SimulatedLs5000::scan_start(
            &sim,
            vec![1, 1],
            CaptureRecipe::default(),
            ProcessingRecipe::default(),
            OutputRecipe::default(),
            HashMap::new(),
            None,
            tx,
        )
        .unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);
    }

    #[test]
    fn scan_start_rejects_invalid_recipe_bit_depth() {
        let sim = Arc::new(SimulatedLs5000::new());
        let options = ConnectOptions::default();
        sim.connect(DEVICE_ID, &options).expect("connect");
        sim.load_media(MediaCarrier::Roll36).expect("load media");
        let (tx, _rx) = mpsc::channel();
        let bad_recipe = CaptureRecipe {
            bit_depth: 12,
            ..CaptureRecipe::default()
        };
        let err = SimulatedLs5000::scan_start(
            &sim,
            vec![1],
            bad_recipe,
            ProcessingRecipe::default(),
            OutputRecipe::default(),
            HashMap::new(),
            None,
            tx,
        )
        .unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);
    }

    #[test]
    fn scan_stop_unknown_job_is_rejected() {
        let sim = SimulatedLs5000::new();
        let (tx, _rx) = mpsc::channel();
        let err = sim
            .scan_stop("no-such-job", StopMode::Immediate, tx)
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::UnknownJob);
    }

    #[test]
    fn eject_refused_while_job_active() {
        let sim = Arc::new(SimulatedLs5000::new());
        let options = ConnectOptions {
            time_scale: 0.01,
            fault_injection: FaultInjection::NoFault,
        };
        sim.connect(DEVICE_ID, &options).expect("connect");
        sim.load_media(MediaCarrier::Roll36).expect("load media");
        let (tx, _rx) = mpsc::channel();
        let recipe = CaptureRecipe {
            multisample_passes: 1,
            // Small on purpose: the background job below runs to real
            // completion (writing real files) whether or not this test
            // waits for it, so keep that write cheap and fast.
            resolution_dpi: 40,
            ..CaptureRecipe::default()
        };
        let (output, output_dir) = isolated_output_recipe("eject-refused");
        SimulatedLs5000::scan_start(
            &sim,
            vec![1, 2],
            recipe,
            ProcessingRecipe::default(),
            output,
            HashMap::new(),
            None,
            tx,
        )
        .expect("scan start");
        // The job is now active (state machine set this synchronously
        // before the worker thread was spawned) — eject must be refused
        // immediately, regardless of timing.
        let err = sim.eject().unwrap_err();
        assert_eq!(err.code, ErrorCode::ScannerBusy);
        assert!(!err.recoverable());

        // Best-effort: the spawned worker thread keeps running in the
        // background past this test function's own return (it is not
        // joined), so this cleanup may race it. That race is harmless --
        // either it removes the directory before or after the background
        // writes land, and nothing here asserts on the writes' outcome.
        let _ = std::fs::remove_dir_all(&output_dir);
    }

    #[test]
    fn thumbnail_acquisition_exclusively_owns_transport_until_complete() {
        let sim = Arc::new(SimulatedLs5000::new());
        sim.connect(
            DEVICE_ID,
            &ConnectOptions {
                time_scale: 1.0,
                fault_injection: FaultInjection::NoFault,
            },
        )
        .expect("connect");
        sim.load_media(MediaCarrier::Roll36).expect("load media");
        let (tx, _rx) = mpsc::channel();
        SimulatedLs5000::acquire_thumbnails(&sim, Some(vec![1]), FilmProcess::default(), None, tx)
            .expect("acquire");
        assert_eq!(sim.eject().unwrap_err().code, ErrorCode::ScannerBusy);
        assert_eq!(
            sim.load_media(MediaCarrier::Strip6).unwrap_err().code,
            ErrorCode::ScannerBusy
        );
        let (tx, _rx) = mpsc::channel();
        assert_eq!(
            SimulatedLs5000::scan_start(
                &sim,
                vec![1],
                CaptureRecipe::default(),
                ProcessingRecipe::default(),
                OutputRecipe::default(),
                HashMap::new(),
                None,
                tx,
            )
            .unwrap_err()
            .code,
            ErrorCode::ScannerBusy
        );
    }

    #[test]
    fn thumbnail_acquisition_tags_every_worker_event_with_its_operation_id() {
        let sim = Arc::new(SimulatedLs5000::new());
        sim.connect(
            DEVICE_ID,
            &ConnectOptions {
                time_scale: 0.01,
                fault_injection: FaultInjection::NoFault,
            },
        )
        .expect("connect");
        sim.load_media(MediaCarrier::Mounted).expect("load media");

        let operation_id = "sim-preview-op";
        let (tx, rx) = mpsc::channel();
        SimulatedLs5000::acquire_thumbnails(
            &sim,
            Some(vec![1]),
            FilmProcess::default(),
            Some(operation_id.to_string()),
            tx,
        )
        .expect("acquire");

        for expected_event in [
            "scanner.thumbnail",
            "scanner.thumbnailsComplete",
            "scanner.status",
        ] {
            let line = rx
                .recv_timeout(Duration::from_secs(1))
                .unwrap_or_else(|_| panic!("timed out waiting for {expected_event}"));
            let event: serde_json::Value = serde_json::from_str(&line).expect("event json");
            assert_eq!(event["event"], expected_event);
            assert_eq!(event["payload"]["operationId"], operation_id);
        }
    }

    #[test]
    fn disconnect_returns_the_offline_status_snapshot() {
        let sim = SimulatedLs5000::new();
        sim.connect(DEVICE_ID, &ConnectOptions::default())
            .expect("connect");
        let status = sim.disconnect().expect("disconnect");
        assert!(!status.connected);
        assert_eq!(status.lamp, Lamp::Off);
        assert_eq!(status.transport, Transport::Idle);
        assert!(!status.media_loaded);
        assert_eq!(status.active_job_id, None);
    }

    #[test]
    fn shutdown_cancels_worker_waits_within_a_short_bound() {
        let sim = Arc::new(SimulatedLs5000::new());
        sim.shutdown();
        let started = std::time::Instant::now();
        assert!(!sleep_until_or_cancelled(&sim, 10_000));
        assert!(started.elapsed() < Duration::from_millis(20));
    }

    #[test]
    fn scan_start_applies_a_per_frame_capture_override() {
        let sim = Arc::new(SimulatedLs5000::new());
        let options = ConnectOptions {
            time_scale: 0.01,
            fault_injection: FaultInjection::NoFault,
        };
        sim.connect(DEVICE_ID, &options).expect("connect");
        sim.load_media(MediaCarrier::Roll36).expect("load media");
        let (mut output, output_dir) = isolated_output_recipe("per-frame-capture-override");
        // Only the archive write is needed to observe resolutionDpi in the
        // receipt -- disabling positive/preview skips the (comparatively
        // expensive) nikonlook color pass and derivative writes for what
        // is otherwise a full-resolution (4000dpi) real render.
        output.positive.enabled = false;
        output.preview.enabled = false;

        let mut overrides = HashMap::new();
        overrides.insert(
            2,
            FrameOverrides {
                capture: Some(CaptureRecipe {
                    resolution_dpi: 1000,
                    ..CaptureRecipe::default()
                }),
                processing: None,
                output: None,
                alignment: None,
            },
        );

        let (tx, rx) = mpsc::channel();
        SimulatedLs5000::scan_start(
            &sim,
            vec![1, 2],
            CaptureRecipe::default(),
            ProcessingRecipe::default(),
            output,
            overrides,
            None,
            tx,
        )
        .expect("scan start");

        let mut receipt_resolutions: HashMap<u32, u32> = HashMap::new();
        while receipt_resolutions.len() < 2 {
            let line = rx
                .recv_timeout(Duration::from_secs(30))
                .expect("both frames must complete");
            let value: serde_json::Value = serde_json::from_str(&line).expect("event json");
            if value["event"] == "scan.frameCompleted" {
                let frame_index = value["payload"]["frameIndex"].as_u64().unwrap() as u32;
                let resolution_dpi = value["payload"]["receipt"]["resolutionDpi"]
                    .as_u64()
                    .unwrap() as u32;
                receipt_resolutions.insert(frame_index, resolution_dpi);
            }
        }

        assert_eq!(
            receipt_resolutions.get(&1),
            Some(&4000),
            "frame 1 has no override -- its receipt must reflect the roll-wide default"
        );
        assert_eq!(
            receipt_resolutions.get(&2),
            Some(&1000),
            "frame 2's own capture override must be what actually scanned, not the roll default"
        );

        let _ = std::fs::remove_dir_all(&output_dir);
    }

    #[test]
    fn scan_skip_current_frame_on_unknown_job_is_rejected() {
        let sim = SimulatedLs5000::new();
        let err = sim.scan_skip_current_frame("no-such-job").unwrap_err();
        assert_eq!(err.code, ErrorCode::UnknownJob);
    }

    #[test]
    fn scan_skip_current_frame_on_a_terminal_job_returns_false() {
        let sim = Arc::new(SimulatedLs5000::new());
        let options = ConnectOptions {
            time_scale: 0.01,
            fault_injection: FaultInjection::NoFault,
        };
        sim.connect(DEVICE_ID, &options).expect("connect");
        sim.load_media(MediaCarrier::Roll36).expect("load media");
        let (tx, rx) = mpsc::channel();
        let recipe = CaptureRecipe {
            resolution_dpi: 40,
            ..CaptureRecipe::default()
        };
        let (output, output_dir) = isolated_output_recipe("skip-current-frame-terminal");
        let job_id = SimulatedLs5000::scan_start(
            &sim,
            vec![1],
            recipe,
            ProcessingRecipe::default(),
            output,
            HashMap::new(),
            None,
            tx,
        )
        .expect("scan start");

        loop {
            let line = rx
                .recv_timeout(Duration::from_secs(30))
                .expect("scan.completed event");
            let value: serde_json::Value = serde_json::from_str(&line).expect("event json");
            if value["event"] == "scan.completed" {
                break;
            }
        }

        let acknowledged = sim
            .scan_skip_current_frame(&job_id)
            .expect("known job id must not error");
        assert!(
            !acknowledged,
            "a terminal job must return acknowledged: false, not an error"
        );

        let _ = std::fs::remove_dir_all(&output_dir);
    }

    #[test]
    fn scan_skip_current_frame_continues_the_batch_instead_of_stopping_it() {
        let sim = Arc::new(SimulatedLs5000::new());
        let options = ConnectOptions {
            // Deliberately not the usual 0.01 used elsewhere in this file:
            // this test must issue scan_skip_current_frame while frame 1 is
            // still mid-attempt, so it needs a real window to reliably win
            // the race against the frame's own (scaled) duration.
            time_scale: 0.2,
            fault_injection: FaultInjection::NoFault,
        };
        sim.connect(DEVICE_ID, &options).expect("connect");
        sim.load_media(MediaCarrier::Roll36).expect("load media");
        let (tx, rx) = mpsc::channel();
        let recipe = CaptureRecipe {
            resolution_dpi: 40,
            ..CaptureRecipe::default()
        };
        let (output, output_dir) = isolated_output_recipe("skip-current-frame-continues-batch");
        let job_id = SimulatedLs5000::scan_start(
            &sim,
            vec![1, 2, 3],
            recipe,
            ProcessingRecipe::default(),
            output,
            HashMap::new(),
            None,
            tx,
        )
        .expect("scan start");

        // Wait for frame 1's own first `active` frameState before racing to
        // skip it -- skipping before the job even begins its first frame
        // would prove nothing about abandoning an in-progress frame.
        loop {
            let line = rx
                .recv_timeout(Duration::from_secs(30))
                .expect("frame 1 active event");
            let value: serde_json::Value = serde_json::from_str(&line).expect("event json");
            if value["event"] == "scan.frameState"
                && value["payload"]["frameIndex"] == 1
                && value["payload"]["state"] == "active"
            {
                break;
            }
        }

        let acknowledged = sim
            .scan_skip_current_frame(&job_id)
            .expect("job is known and not yet terminal");
        assert!(acknowledged);

        let mut skipped_states: Vec<u32> = Vec::new();
        let summary_skipped: Vec<u64>;
        let summary_failed: Vec<u64>;
        let mut final_job_state: Option<String> = None;
        loop {
            let line = rx
                .recv_timeout(Duration::from_secs(30))
                .expect("job must reach a terminal state");
            let value: serde_json::Value = serde_json::from_str(&line).expect("event json");
            match value["event"].as_str() {
                Some("scan.frameState") if value["payload"]["state"] == "skipped" => {
                    skipped_states.push(value["payload"]["frameIndex"].as_u64().unwrap() as u32);
                }
                Some("scan.jobState") => {
                    let state = value["payload"]["state"].as_str().unwrap_or("").to_string();
                    assert!(
                        state == "scanning" || state == "completed",
                        "job state must never become a Stopping* variant after a \
                         skip-current-frame -- saw {state}"
                    );
                    final_job_state = Some(state);
                }
                Some("scan.completed") => {
                    summary_skipped = value["payload"]["summary"]["skipped"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| v.as_u64().unwrap())
                        .collect();
                    summary_failed = value["payload"]["summary"]["failed"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| v.as_u64().unwrap())
                        .collect();
                    break;
                }
                _ => {}
            }
        }

        assert_eq!(
            skipped_states,
            vec![1],
            "exactly one frame (the one active when skip was requested) must transition to Skipped"
        );
        assert_eq!(
            summary_skipped,
            vec![1],
            "scan.completed's summary must list frame 1 under skipped"
        );
        assert!(
            summary_failed.is_empty(),
            "the skipped frame must never appear under failed"
        );
        assert_eq!(
            final_job_state.as_deref(),
            Some("completed"),
            "the job must reach Completed, not Stopped, after a skip-current-frame"
        );

        let _ = std::fs::remove_dir_all(&output_dir);
    }

    #[test]
    fn scan_start_persists_frame_receipts_to_manifest_for_resume() {
        let dir = std::env::temp_dir().join(format!(
            "scanstudio-sim-resume-test-{}",
            crate::manifest::generate_project_id()
        ));
        let (_project, project_dir) = crate::manifest::create_project(
            "Resume Test",
            MediaCarrier::Strip6,
            2,
            FilmProcess::Positive,
            Some(&dir),
        )
        .expect("create_project should succeed");

        let sim = Arc::new(SimulatedLs5000::new());
        let options = ConnectOptions {
            time_scale: 0.01,
            fault_injection: FaultInjection::NoFault,
        };
        sim.connect(DEVICE_ID, &options).expect("connect");
        sim.load_media(MediaCarrier::Strip6).expect("load media");

        let (mut output, output_dir) = isolated_output_recipe("resume-persistence");
        output.positive.enabled = false;
        output.preview.enabled = false;

        let (tx, rx) = mpsc::channel();
        SimulatedLs5000::scan_start(
            &sim,
            vec![1, 2],
            CaptureRecipe::default(),
            ProcessingRecipe::default(),
            output,
            HashMap::new(),
            Some(project_dir.clone()),
            tx,
        )
        .expect("scan start");

        loop {
            let line = rx
                .recv_timeout(Duration::from_secs(30))
                .expect("scan.completed event");
            let value: serde_json::Value = serde_json::from_str(&line).expect("event json");
            if value["event"] == "scan.completed" {
                break;
            }
        }

        let read_back = crate::manifest::read_manifest(&project_dir)
            .expect("fresh read_manifest after simulated quit");
        assert_eq!(read_back.frames.len(), 2);
        assert!(
            !read_back.frames[0].receipts.is_empty(),
            "frame 1 receipt must be persisted"
        );
        assert!(
            !read_back.frames[1].receipts.is_empty(),
            "frame 2 receipt must be persisted"
        );
        assert_eq!(
            read_back.frames[0].receipts[0].job_id,
            read_back.frames[1].receipts[0].job_id,
            "both persisted receipts must belong to the same job"
        );

        let _ = std::fs::remove_dir_all(&project_dir);
        let _ = std::fs::remove_dir_all(&output_dir);
    }
}
