//! NDJSON dispatch loop (D-03/D-07): a blocking `stdin` read loop on the
//! main thread, a dedicated stdout writer thread fed by `std::sync::mpsc`
//! (every write is pre-serialized JSON, flushed after every line), and
//! worker threads for simulator jobs/thumbnails spawned inside
//! `SimulatedLs5000` itself (see `sim.rs`).

use std::io::{self, BufRead, Write};
use std::sync::{mpsc, Arc};
use std::thread;

use serde::Serialize;

use crate::domain::{self, EngineError, ScannerBackend};
use crate::protocol::{self, ErrorCode, ErrorPayload, Request};
use crate::real_backend::RealLs5000;
use crate::sim::SimulatedLs5000;

/// Default request timeout for the real backend's `BridgeClient`, applied
/// whenever `SCANSTUDIO_BRIDGE_CMD` is configured (`Backends::from_env` is
/// the only place this constant is used).
const DEFAULT_BRIDGE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// In-memory tracking of whichever project is currently "open" in the
/// engine (the one most recently created or opened). Every request is
/// handled sequentially on `run()`'s single stdin-reading loop, so a plain
/// `&mut` threaded through `handle_request` is enough — no `Arc`/`Mutex`
/// needed, since worker threads spawned for thumbnails/scans never touch
/// project state.
#[derive(Default)]
struct ProjectState {
    active: Option<domain::ScanProject>,
    directory: Option<std::path::PathBuf>,
}

impl ProjectState {
    fn set(&mut self, project: domain::ScanProject, directory: std::path::PathBuf) {
        self.active = Some(project);
        self.directory = Some(directory);
    }

    /// Refreshes the active manifest from its durable copy. Scan workers
    /// persist receipts directly to disk, so receipt-dependent endpoints
    /// must cross this boundary before reading the request loop's snapshot.
    fn refresh_from_disk(&mut self) -> Result<(), EngineError> {
        if self.active.is_none() {
            return Err(EngineError::new(
                ErrorCode::ProjectNotFound,
                "no project is currently open",
            ));
        }
        let directory = self.directory.clone().ok_or_else(|| {
            EngineError::new(
                ErrorCode::ProjectNotFound,
                "the active project has no manifest directory",
            )
        })?;
        self.active = Some(crate::manifest::read_manifest(&directory)?);
        Ok(())
    }
}

/// Which backend currently owns the connection, if any. `Copy` so
/// `Backends`' read-only dispatch methods (`status`/`load_media`/`eject`/
/// etc.) can match on `self.active` without holding a borrow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ActiveDevice {
    Sim,
    Real,
}

/// Backend registry/router: replaces the single hardcoded
/// `Arc<SimulatedLs5000>` `run()` used to hold directly. `scanner.list`
/// always reports the simulator, plus the real device when
/// `SCANSTUDIO_BRIDGE_CMD` is configured and started successfully;
/// `scanner.connect` decides — from the requested device id alone, never
/// from any other client input — which backend every subsequent request
/// routes through.
struct Backends {
    sim: Arc<SimulatedLs5000>,
    real: Option<Arc<RealLs5000>>,
    active: Option<ActiveDevice>,
}

impl Backends {
    /// Reads `SCANSTUDIO_BRIDGE_CMD` — the ONLY place in the engine this
    /// environment variable is read. Unset/empty AND configured-but-broken
    /// both resolve to the identical `real: None` sim-only state,
    /// deliberately a superset of the literal "not configured" fallback: a
    /// broken configuration must degrade exactly like no configuration,
    /// never crash engine startup or leave a half-working device entry
    /// (T-09-11).
    fn from_env() -> Self {
        let sim = Arc::new(SimulatedLs5000::new());
        let real = match std::env::var("SCANSTUDIO_BRIDGE_CMD") {
            Ok(cmd) if !cmd.trim().is_empty() => {
                match RealLs5000::new(&cmd, DEFAULT_BRIDGE_TIMEOUT) {
                    Ok(backend) => Some(Arc::new(backend)),
                    Err(err) => {
                        eprintln!(
                            "scanstudio-engine: SCANSTUDIO_BRIDGE_CMD configured ('{cmd}') but the real backend could not start ({err}); falling back to simulator-only scanner.list"
                        );
                        None
                    }
                }
            }
            _ => None,
        };
        Backends {
            sim,
            real,
            active: None,
        }
    }

    /// `scanner.list`: the simulator always, plus the real device only if
    /// `SCANSTUDIO_BRIDGE_CMD` was configured and started successfully.
    fn list_devices(&self) -> Vec<domain::DeviceInfo> {
        let mut v = vec![self.sim.device_info()];
        if let Some(real) = &self.real {
            v.push(real.device_info());
        }
        v
    }

    /// Routes `scanner.connect` by device id. Refuses to switch the active
    /// backend without an intervening `scanner.disconnect` (T-09-12) —
    /// closing the state-confusion risk of one engine session appearing
    /// simultaneously "connected" to both sim and real.
    fn connect(
        &mut self,
        device_id: &str,
        options: &protocol::ConnectOptions,
    ) -> Result<protocol::ConnectResult, EngineError> {
        if let Some(active) = self.active {
            let active_device_id = match active {
                ActiveDevice::Sim => self.sim.device_info().device_id,
                ActiveDevice::Real => self.real.as_ref().unwrap().device_info().device_id,
            };
            if device_id != active_device_id {
                return Err(EngineError::new(
                    ErrorCode::AlreadyConnected,
                    "another device is already connected; disconnect first",
                ));
            }
        }

        if device_id == self.sim.device_info().device_id {
            let result = self.sim.connect(device_id, options)?;
            self.active = Some(ActiveDevice::Sim);
            Ok(result)
        } else if self.real.is_some()
            && device_id == self.real.as_ref().unwrap().device_info().device_id
        {
            let result = self.real.as_ref().unwrap().connect(device_id, options)?;
            self.active = Some(ActiveDevice::Real);
            Ok(result)
        } else {
            Err(EngineError::new(
                ErrorCode::UnknownDevice,
                format!("unknown device id '{device_id}'"),
            ))
        }
    }

    fn disconnect(&mut self) -> Result<protocol::ScannerStatus, EngineError> {
        match self.active.take() {
            Some(ActiveDevice::Sim) => match self.sim.disconnect() {
                Ok(s) => Ok(s),
                Err(e) => {
                    self.active = Some(ActiveDevice::Sim);
                    Err(e)
                }
            },
            Some(ActiveDevice::Real) => {
                let real = self.real.as_ref().unwrap().clone();
                match real.disconnect() {
                    Ok(s) => Ok(s),
                    Err(e) => {
                        self.active = Some(ActiveDevice::Real);
                        Err(e)
                    }
                }
            }
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    fn status(&self) -> Result<protocol::ScannerStatus, EngineError> {
        match self.active {
            Some(ActiveDevice::Sim) => self.sim.status(),
            Some(ActiveDevice::Real) => self.real.as_ref().unwrap().status(),
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    /// Async real-backend workers own no mutable reference to this router.
    /// They retire the shared connection epoch instead; the next request
    /// reconciles that authoritative latch before choosing a backend.
    fn reconcile_async_real_session(&mut self) {
        if self.active == Some(ActiveDevice::Real)
            && self
                .real
                .as_ref()
                .is_some_and(|real| !real.session_is_connected())
        {
            self.active = None;
        }
    }

    /// A bridge child owns the physical device handle. If it was restarted,
    /// the new child correctly reports `NOT_CONNECTED` until `device.open`
    /// succeeds again; retaining `ActiveDevice::Real` here would make the
    /// engine (and therefore the UI) claim a connection that no longer exists.
    ///
    /// Do not reopen automatically: a replacement bridge has also lost its
    /// preview/session state, and replaying a motion request would be unsafe.
    /// The caller receives both its typed failure and an authoritative
    /// disconnected status event, then must explicitly reconnect.
    fn invalidate_real_session_after_bridge_not_connected(
        &mut self,
        error: &mut EngineError,
    ) -> Option<protocol::ScannerStatus> {
        let bridge_reported_no_open_device =
            self.active == Some(ActiveDevice::Real) && error.code == ErrorCode::NotConnected;
        if !bridge_reported_no_open_device {
            return None;
        }

        let real = self.real.as_ref().unwrap();
        let owns_disconnected_event = real.invalidate_current_session();
        self.active = None;
        error.message = format!(
            "{}; bridge session ownership was lost — reconnect required",
            error.message
        );
        owns_disconnected_event.then(RealLs5000::disconnected_status)
    }

    fn load_media(
        &self,
        carrier: domain::MediaCarrier,
    ) -> Result<protocol::ScannerStatus, EngineError> {
        match self.active {
            Some(ActiveDevice::Sim) => self.sim.load_media(carrier),
            Some(ActiveDevice::Real) => self.real.as_ref().unwrap().load_media(carrier),
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    fn eject(&self) -> Result<protocol::ScannerStatus, EngineError> {
        match self.active {
            Some(ActiveDevice::Sim) => self.sim.eject(),
            Some(ActiveDevice::Real) => self.real.as_ref().unwrap().eject(),
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    fn acquire_thumbnails(
        &self,
        frames: Option<Vec<u32>>,
        film_process: domain::FilmProcess,
        operation_id: Option<String>,
        event_tx: mpsc::Sender<String>,
    ) -> Result<Vec<u32>, EngineError> {
        match self.active {
            Some(ActiveDevice::Sim) => SimulatedLs5000::acquire_thumbnails(
                &self.sim,
                frames,
                film_process,
                operation_id,
                event_tx,
            ),
            Some(ActiveDevice::Real) => RealLs5000::acquire_thumbnails(
                self.real.as_ref().unwrap(),
                frames,
                film_process,
                operation_id,
                event_tx,
            ),
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    /// Explicit manual-review acknowledgement for the currently connected
    /// real bridge session. `roll.approve` is deliberately not folded into
    /// `scan.start`: the operator must make a distinct, reviewable decision
    /// before a frame that was flagged by preview can move.
    fn roll_approve(&self, frame_index: u32, operation_id: &str) -> Result<(), EngineError> {
        if frame_index == 0 {
            return Err(EngineError::new(
                ErrorCode::InvalidParams,
                "frameIndex must be greater than zero",
            ));
        }
        if operation_id.trim().is_empty() {
            return Err(EngineError::new(
                ErrorCode::InvalidParams,
                "operationId must name the exact completed preview being approved",
            ));
        }
        match self.active {
            Some(ActiveDevice::Real) => self
                .real
                .as_ref()
                .unwrap()
                .roll_approve(frame_index, operation_id),
            Some(ActiveDevice::Sim) => Err(EngineError::new(
                ErrorCode::InvalidParams,
                "roll.approve is available only for an active real-device preview; the simulator has no manual-review gate",
            )),
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    fn roll_set_spacing_offset(
        &self,
        frame_index: u32,
        offset_rows: i64,
        operation_id: &str,
    ) -> Result<protocol::Thumbnail, EngineError> {
        if frame_index == 0 {
            return Err(EngineError::new(
                ErrorCode::InvalidParams,
                "frameIndex must be greater than zero",
            ));
        }
        if operation_id.trim().is_empty() {
            return Err(EngineError::new(
                ErrorCode::InvalidParams,
                "operationId must name the exact completed preview being aligned",
            ));
        }
        let valid_offset = if frame_index == 1 {
            (0..=144).contains(&offset_rows)
        } else {
            (-144..=144).contains(&offset_rows)
        };
        if !valid_offset {
            let allowed = if frame_index == 1 {
                "0...144"
            } else {
                "-144...144"
            };
            return Err(EngineError::new(
                ErrorCode::InvalidParams,
                format!("offsetRows for frame {frame_index} must be within {allowed}"),
            ));
        }
        match self.active {
            Some(ActiveDevice::Real) => self.real.as_ref().unwrap().roll_set_spacing_offset(
                frame_index,
                offset_rows,
                operation_id,
            ),
            Some(ActiveDevice::Sim) => Err(EngineError::new(
                ErrorCode::InvalidParams,
                "roll.setSpacingOffset is available only for an active real-device preview",
            )),
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    fn scan_start(
        &self,
        frames: Vec<u32>,
        recipe: domain::CaptureRecipe,
        processing: domain::ProcessingRecipe,
        output: domain::OutputRecipe,
        overrides: std::collections::HashMap<u32, domain::FrameOverrides>,
        project_directory: Option<std::path::PathBuf>,
        event_tx: mpsc::Sender<String>,
    ) -> Result<String, EngineError> {
        match self.active {
            Some(ActiveDevice::Sim) => SimulatedLs5000::scan_start(
                &self.sim,
                frames,
                recipe,
                processing,
                output,
                overrides,
                project_directory,
                event_tx,
            ),
            Some(ActiveDevice::Real) => RealLs5000::scan_start(
                self.real.as_ref().unwrap(),
                frames,
                recipe,
                processing,
                output,
                overrides,
                project_directory,
                event_tx,
            ),
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    fn scan_stop(
        &self,
        job_id: &str,
        mode: protocol::StopMode,
        event_tx: mpsc::Sender<String>,
    ) -> Result<(bool, protocol::StopMode), EngineError> {
        match self.active {
            Some(ActiveDevice::Sim) => self.sim.scan_stop(job_id, mode, event_tx),
            Some(ActiveDevice::Real) => self
                .real
                .as_ref()
                .unwrap()
                .scan_stop(job_id, mode, event_tx),
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    /// Simulator-only: the real backend has no bridge primitive capable of
    /// abandoning an in-flight frame (BRIDGE.md's `scan.stop` always lets the
    /// current slot finish). The real-hardware equivalent of "skip an upcoming
    /// frame" is `project.setFrameExcluded` on that frame, followed by
    /// `scan.stop{afterCurrentFrame}` and a fresh `scan.start`/resume — three
    /// already-existing methods, not a new one. This backend refuses
    /// `scan.skipCurrentFrame` for Real rather than silently no-op or forward
    /// an undefined bridge call (T-04-04).
    fn scan_skip_current_frame(&self, job_id: &str) -> Result<bool, EngineError> {
        match self.active {
            Some(ActiveDevice::Sim) => self.sim.scan_skip_current_frame(job_id),
            Some(ActiveDevice::Real) => Err(EngineError::new(
                ErrorCode::InvalidParams,
                "skipping the currently-active frame has no real-hardware equivalent — the in-flight frame always completes; to skip an upcoming frame, exclude it (project.setFrameExcluded) before resuming",
            )),
            None => Err(EngineError::new(
                ErrorCode::NotConnected,
                "scanner is not connected",
            )),
        }
    }

    fn shutdown(&self) {
        self.sim.shutdown();
        if let Some(real) = &self.real {
            real.shutdown();
        }
    }
}

/// Returns true if the post-dispatch hook in `run()` may safely issue a
/// synchronous `backends.status()` call for this method. Returns false for
/// `scan.start` and `scanner.acquireThumbnails` against the Real backend:
/// both operations may hold the hardware for minutes, and the hook's own
/// `device.status` call is bounded only by `BridgeClient::request_timeout`,
/// whose timeout path restarts (kills) the bridge subprocess — exactly the
/// "never kill mid-USB-transaction" hazard the Real scan path avoids.
/// `scan.stop` and every simulator path are left unchanged.
fn post_dispatch_status_is_safe(active: Option<ActiveDevice>, method: &str) -> bool {
    !matches!(
        (active, method),
        (
            Some(ActiveDevice::Real),
            "scan.start" | "scanner.acquireThumbnails"
        )
    )
}

fn validate_output_retention(
    label: &str,
    output: &domain::OutputRecipe,
) -> Result<(), EngineError> {
    if !output.has_retained_output() {
        return Err(EngineError::new(
            ErrorCode::InvalidParams,
            format!(
                "{label} must retain at least one of master TIFF, positive TIFF, or positive JPEG"
            ),
        ));
    }
    if output.archive.full_capture_package && !output.archive.enabled {
        return Err(EngineError::new(
            ErrorCode::InvalidParams,
            format!("{label} enables a full capture package without keeping a master TIFF"),
        ));
    }
    Ok(())
}

/// Runs the engine: reads NDJSON requests from stdin, dispatches them
/// against `Backends` (simulator always, plus the real backend when
/// `SCANSTUDIO_BRIDGE_CMD` is configured), and writes NDJSON responses/
/// events to stdout until `engine.shutdown` is received (or stdin closes).
pub fn run() {
    let mut backends = Backends::from_env();
    let (tx, rx) = mpsc::channel::<String>();
    let mut project_state = ProjectState::default();

    // The only thread that ever writes to stdout. Producers (this loop for
    // responses, worker threads inside sim.rs for events) serialize their
    // own JSON before sending it here, so this loop is a trivial,
    // panic-resistant write-and-flush.
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

    let mut hello_received = false;
    let stdin = io::stdin();

    for line_result in stdin.lock().lines() {
        let line = match line_result {
            Ok(l) => l,
            Err(err) => {
                eprintln!("scanstudio-engine: stdin read error: {err}");
                continue;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        // Malformed JSON must never crash the process (T-01-01): log and
        // skip, answering INTERNAL if an `id` was at least parseable.
        let request: Request = match serde_json::from_str(&line) {
            Ok(req) => req,
            Err(err) => {
                eprintln!("scanstudio-engine: malformed request line, skipping: {err}");
                if let Some(id) = best_effort_id(&line) {
                    let internal = EngineError::new(ErrorCode::Internal, "malformed request line");
                    respond_error(&tx, id, &internal);
                }
                continue;
            }
        };

        if let Some(err) = reject_before_hello(hello_received, &request.method) {
            respond_error(&tx, request.id, &err);
            continue;
        }

        if request.method == "engine.shutdown" {
            respond_ok(&tx, request.id, serde_json::json!({}));
            backends.shutdown();
            drop(tx);
            let _ = writer.join();
            std::process::exit(0);
        }

        match handle_request(&mut backends, &tx, &request, &mut project_state) {
            Ok(result) => {
                if request.method == "engine.hello" {
                    hello_received = true;
                }
                respond_ok(&tx, request.id, result);
                // Start/stop operations mutate transport synchronously. Send
                // their acknowledgement first, then the authoritative status
                // snapshot, so clients never need to infer busy state — but
                // only when that status call is safe. Real scan.start and
                // scanner.acquireThumbnails skip it: their own worker threads
                // already emit the authoritative status signal, and a stuck
                // device.status here could restart the bridge subprocess mid-
                // USB-transaction (11-01).
                if matches!(
                    request.method.as_str(),
                    "scanner.acquireThumbnails" | "scan.start" | "scan.stop"
                ) && post_dispatch_status_is_safe(backends.active, request.method.as_str())
                {
                    match backends.status() {
                        Ok(status) => {
                            emit_event(
                                &tx,
                                "scanner.status",
                                protocol::ScannerStatusPayload {
                                    status,
                                    operation_id: None,
                                },
                            );
                        }
                        Err(mut status_error) => {
                            // The operation acknowledgement is already on the
                            // wire. If its safe follow-up status read proves
                            // that the real bridge owner was lost, retire that
                            // epoch and emit the one authoritative offline
                            // status; do not invent a second response or retry
                            // any device/motion request. Simulator and
                            // non-connection status errors retain the historic
                            // no-event behavior.
                            if let Some(status) = backends
                                .invalidate_real_session_after_bridge_not_connected(
                                    &mut status_error,
                                )
                            {
                                emit_event(
                                    &tx,
                                    "scanner.status",
                                    protocol::ScannerStatusPayload {
                                        status,
                                        operation_id: None,
                                    },
                                );
                            }
                        }
                    }
                }
            }
            Err(mut engine_err) => {
                if let Some(status) =
                    backends.invalidate_real_session_after_bridge_not_connected(&mut engine_err)
                {
                    emit_event(
                        &tx,
                        "scanner.status",
                        protocol::ScannerStatusPayload {
                            status,
                            operation_id: None,
                        },
                    );
                }
                respond_error(&tx, request.id, &engine_err);
            }
        }
    }

    // stdin closed without an explicit shutdown: cancel workers before
    // joining the writer so their sender clones cannot hold it open.
    backends.shutdown();
    drop(tx);
    let _ = writer.join();
}

/// `engine.hello` must be the first request; every other method before it
/// is rejected with `INVALID_PARAMS`. Extracted as a pure function so it's
/// unit-testable without a real stdin/stdout session.
fn reject_before_hello(hello_received: bool, method: &str) -> Option<EngineError> {
    if !hello_received && method != "engine.hello" {
        Some(EngineError::new(
            ErrorCode::InvalidParams,
            "engine.hello must be the first request",
        ))
    } else {
        None
    }
}

fn handle_request(
    backends: &mut Backends,
    tx: &mpsc::Sender<String>,
    request: &Request,
    project_state: &mut ProjectState,
) -> Result<serde_json::Value, EngineError> {
    backends.reconcile_async_real_session();
    match request.method.as_str() {
        "engine.hello" => {
            let params: protocol::HelloParams = parse_params(&request.params)?;
            if params.protocol_version != 1 {
                return Err(EngineError::new(
                    ErrorCode::InvalidParams,
                    format!(
                        "unsupported protocolVersion {}; expected 1",
                        params.protocol_version
                    ),
                ));
            }
            to_json(&protocol::HelloResult {
                engine_name: "scanstudio-engine".to_string(),
                engine_version: env!("CARGO_PKG_VERSION").to_string(),
                protocol_version: 1,
                capabilities: vec!["simulated-ls5000".to_string()],
            })
        }
        "scanner.list" => to_json(&protocol::ScannerListResult {
            devices: backends.list_devices(),
        }),
        "scanner.connect" => {
            let params: protocol::ConnectParams = parse_params(&request.params)?;
            let options = params.options.unwrap_or_default();
            let result = backends.connect(&params.device_id, &options)?;
            emit_event(
                tx,
                "scanner.status",
                protocol::ScannerStatusPayload {
                    status: result.status.clone(),
                    operation_id: None,
                },
            );
            to_json(&result)
        }
        "scanner.disconnect" => {
            let status = backends.disconnect()?;
            emit_event(
                tx,
                "scanner.status",
                protocol::ScannerStatusPayload {
                    status,
                    operation_id: None,
                },
            );
            Ok(serde_json::json!({}))
        }
        "scanner.status" => {
            let status = backends.status()?;
            to_json(&status)
        }
        "sim.loadMedia" => {
            let params: protocol::LoadMediaParams = parse_params(&request.params)?;
            let status = backends.load_media(params.carrier)?;
            emit_event(
                tx,
                "scanner.status",
                protocol::ScannerStatusPayload {
                    status: status.clone(),
                    operation_id: None,
                },
            );
            to_json(&status)
        }
        "scanner.acquireThumbnails" => {
            let params: protocol::AcquireThumbnailsParams = parse_params(&request.params)?;
            // A preview before a project exists needs the caller's selected
            // material. Once a project is active, that persisted roll-level
            // decision is authoritative: accepting a different wire value
            // would make a project and its thumbnails disagree about what
            // was previewed.
            let film_process = if let Some(project) = project_state.active.as_ref() {
                if let Some(requested) = params.film_process {
                    if requested != project.film_process {
                        return Err(EngineError::new(
                            ErrorCode::InvalidParams,
                            "filmProcess conflicts with the active project's filmProcess",
                        ));
                    }
                }
                project.film_process
            } else {
                params.film_process.unwrap_or_default()
            };
            let frames = backends.acquire_thumbnails(
                params.frames,
                film_process,
                params.operation_id,
                tx.clone(),
            )?;
            to_json(&protocol::AcquireThumbnailsAck {
                accepted: true,
                frames,
            })
        }
        "roll.approve" => {
            let params: protocol::RollApproveParams = parse_params(&request.params)?;
            backends.roll_approve(params.frame_index, &params.operation_id)?;
            to_json(&protocol::RollApproveResult {})
        }
        "roll.setSpacingOffset" => {
            let params: protocol::RollSetSpacingOffsetParams = parse_params(&request.params)?;
            let thumbnail = backends.roll_set_spacing_offset(
                params.frame_index,
                params.offset_rows,
                &params.operation_id,
            )?;
            to_json(&protocol::RollSetSpacingOffsetResult { thumbnail })
        }
        "scan.start" => {
            let mut params: protocol::ScanStartParams = parse_params(&request.params)?;
            crate::render::validate_user_output_recipe_paths(&params.output)?;
            params.processing = params.processing.effective();
            // Resolve per-frame overrides and enforce exclusion from the
            // engine's own project_state BEFORE anything else -- the
            // override map is never trusted from client-supplied override
            // data directly (T-04-03), and exclusion must be refused
            // before a job is ever created (PROTOCOL.md: "excluded frames
            // never enter a job at all").
            let mut overrides: std::collections::HashMap<u32, domain::FrameOverrides> =
                std::collections::HashMap::new();
            if let Some(project) = project_state.active.as_ref() {
                // A physical scan is batch-wide. The active project's film
                // process is therefore the sole material authority. The
                // roll-wide request field is normalized for compatibility
                // with older clients that omitted it and decoded to C-41;
                // a legacy per-frame manifest override, however, cannot be
                // honored safely and is rejected below before capture.
                params.processing.film_process = project.film_process;
                params.processing = params.processing.effective();
                for &requested in &params.frames {
                    if let Some(frame) = project.frames.iter().find(|f| f.index == requested) {
                        if frame.excluded {
                            return Err(EngineError::new(
                                ErrorCode::InvalidParams,
                                format!("frame {requested} is excluded and cannot be scanned"),
                            ));
                        }
                        if let Some(override_processing) = &frame.processing_override {
                            if override_processing.film_process != project.film_process {
                                return Err(EngineError::new(
                                    ErrorCode::InvalidParams,
                                    format!(
                                        "frame {requested} processingOverride.filmProcess conflicts with the active project's filmProcess"
                                    ),
                                ));
                            }
                        }
                        if frame.capture_override.is_some()
                            || frame.processing_override.is_some()
                            || frame.output_override.is_some()
                            || frame.alignment.is_some()
                        {
                            overrides.insert(
                                requested,
                                domain::FrameOverrides {
                                    capture: frame.capture_override.clone(),
                                    processing: frame.processing_override.clone(),
                                    output: frame.output_override.clone(),
                                    alignment: frame.alignment.clone(),
                                },
                            );
                        }
                    }
                }
            }
            for override_values in overrides.values() {
                if let Some(output) = override_values.output.as_ref() {
                    crate::render::validate_user_output_recipe_paths(output)?;
                }
            }
            // Reject an all-off effective recipe before persistence,
            // backend dispatch, bridge startup, or any possible scanner
            // motion. A capture package depends on retaining the master;
            // it cannot be requested for a derivative-only scan.
            validate_output_retention("scan output", &params.output)?;
            for (frame_index, override_values) in &overrides {
                if let Some(output) = override_values.output.as_ref() {
                    validate_output_retention(
                        &format!("frame {frame_index} output override"),
                        output,
                    )?;
                }
            }
            // Persist this scan's raw recipe set onto the active project's
            // manifest BEFORE params.output is moved into scan_start below
            // -- token templates remain editable and reopenable. A separate
            // effective clone is materialized below solely for this job.
            // Best-effort: a persistence failure must never block the scan.
            //
            // Routes through persist_project_update rather than a direct
            // write (PERSIST-02): project_state.active has been sitting
            // stale in memory since project.create/open, and carries none
            // of the receipts the scan worker thread has been durably
            // attaching straight to disk since -- a direct write here used
            // to overwrite every one of them at the start of every
            // subsequent scan. persist_project_update reads disk fresh,
            // keeps whatever receipts are already there, and the merged
            // result is folded back into project_state.active so it
            // converges toward disk truth on every call instead of
            // drifting further from it.
            if let Some(project) = project_state.active.as_mut() {
                project.recipes = params.output.clone();
                let directory = project_state.directory.as_ref().expect(
                    "directory is always Some whenever active is Some — ProjectState::set sets both together",
                );
                match crate::manifest::persist_project_update(directory, project) {
                    Ok(merged) => project_state.active = Some(merged),
                    Err(err) => {
                        eprintln!("scanstudio-engine: failed to persist recipes to manifest: {err}")
                    }
                }
            }
            let roll_metadata = project_state
                .active
                .as_ref()
                .map(|project| project.roll_metadata.clone())
                .unwrap_or_default();
            let mut effective_output = params.output.clone();
            crate::render::materialize_output_filename_tokens(
                &mut effective_output,
                &roll_metadata,
            );
            crate::render::validate_user_output_recipe_paths(&effective_output)?;
            for (frame_index, override_values) in overrides.iter_mut() {
                if let Some(output) = override_values.output.as_mut() {
                    let metadata = project_state
                        .active
                        .as_ref()
                        .and_then(|project| {
                            project
                                .frames
                                .iter()
                                .find(|frame| frame.index == *frame_index)
                        })
                        .and_then(|frame| frame.metadata_override.as_ref())
                        .unwrap_or(&roll_metadata);
                    crate::render::materialize_output_filename_tokens(output, metadata);
                    crate::render::validate_user_output_recipe_paths(output)?;
                }
            }
            // Metadata overrides affect the actual per-frame output names
            // even when the operator did not also create an output override.
            // Materialize a job-local output override from the roll recipe;
            // the manifest retains the raw token template above.
            if let Some(project) = project_state.active.as_ref() {
                for frame_index in &params.frames {
                    let Some(metadata) = project
                        .frames
                        .iter()
                        .find(|frame| frame.index == *frame_index)
                        .and_then(|frame| frame.metadata_override.as_ref())
                    else {
                        continue;
                    };
                    let frame_values = overrides.entry(*frame_index).or_default();
                    // Start with the raw token template, not the roll-level
                    // materialized output above; otherwise per-frame Camera/
                    // Lens/date metadata has no tokens left to replace.
                    let mut frame_output = frame_values
                        .output
                        .clone()
                        .unwrap_or_else(|| params.output.clone());
                    crate::render::materialize_output_filename_tokens(&mut frame_output, metadata);
                    crate::render::validate_user_output_recipe_paths(&frame_output)?;
                    frame_values.output = Some(frame_output);
                }
            }
            // A single `#` is the new default's sequence token, unlike the
            // established `####` physical-frame token. Reserve concrete
            // per-frame names across every enabled output before any
            // preflight can permit hardware motion; manifests retain the
            // editable raw template persisted above.
            crate::render::reserve_auto_sequence_filenames(
                &params.frames,
                &params.recipe,
                &params.processing,
                &effective_output,
                &mut overrides,
            )?;
            // Reject the complete batch's physical target graph before the
            // backend receives a job: all slots, enabled derivatives, and
            // possible bridge IR/meter sidecars participate in one
            // collision set. No simulator write, bridge request, progress
            // event, or hardware motion can precede this check.
            crate::render::validate_batch_output_paths(
                &params.frames,
                &params.recipe,
                &params.processing,
                &effective_output,
                &overrides,
            )?;
            let job_id = backends.scan_start(
                params.frames,
                params.recipe,
                params.processing,
                effective_output,
                overrides,
                project_state.directory.clone(),
                tx.clone(),
            )?;
            to_json(&protocol::ScanStartResult { job_id })
        }
        "scan.stop" => {
            let params: protocol::ScanStopParams = parse_params(&request.params)?;
            let (acknowledged, mode) =
                backends.scan_stop(&params.job_id, params.mode, tx.clone())?;
            to_json(&protocol::ScanStopResult { acknowledged, mode })
        }
        "scan.skipCurrentFrame" => {
            let params: protocol::ScanSkipCurrentFrameParams = parse_params(&request.params)?;
            let acknowledged = backends.scan_skip_current_frame(&params.job_id)?;
            to_json(&protocol::ScanSkipCurrentFrameResult { acknowledged })
        }
        "scanner.eject" => {
            let status = backends.eject()?;
            emit_event(
                tx,
                "scanner.status",
                protocol::ScannerStatusPayload {
                    status: status.clone(),
                    operation_id: None,
                },
            );
            Ok(serde_json::json!({}))
        }
        "project.create" => {
            let params: protocol::ProjectCreateParams = parse_params(&request.params)?;
            let (project, directory) = crate::manifest::create_project(
                &params.name,
                params.carrier,
                params.frame_count,
                params.film_process,
                params.directory.as_deref().map(std::path::Path::new),
            )?;
            project_state.set(project.clone(), directory.clone());
            to_json(&protocol::ProjectCreateResult {
                project,
                directory: directory.display().to_string(),
            })
        }
        "project.open" => {
            let params: protocol::ProjectOpenParams = parse_params(&request.params)?;
            let project = crate::manifest::open_project(std::path::Path::new(&params.directory))?;
            crate::render::validate_user_output_recipe_paths(&project.recipes)?;
            for frame in &project.frames {
                if let Some(output) = frame.output_override.as_ref() {
                    crate::render::validate_user_output_recipe_paths(output)?;
                }
            }
            project_state.set(project.clone(), std::path::PathBuf::from(&params.directory));
            to_json(&protocol::ProjectOpenResult {
                project,
                directory: params.directory,
            })
        }
        "project.list" => {
            let params: protocol::ProjectListParams = parse_params(&request.params)?;
            let directory = params
                .directory
                .as_ref()
                .map(std::path::PathBuf::from)
                .unwrap_or_else(crate::manifest::default_projects_root);
            let projects = crate::manifest::list_projects(&directory);
            to_json(&protocol::ProjectListResult { projects })
        }
        "project.setFrameExcluded" => {
            let params: protocol::SetFrameExcludedParams = parse_params(&request.params)?;
            let project = apply_frame_mutation(project_state, params.frame_index, |frame| {
                frame.excluded = params.excluded;
            })?;
            to_json(&protocol::SetFrameResult { project })
        }
        "project.setFrameCaptureOverride" => {
            let params: protocol::SetFrameCaptureOverrideParams = parse_params(&request.params)?;
            let project = apply_frame_mutation(project_state, params.frame_index, |frame| {
                frame.capture_override = params.capture.clone();
            })?;
            to_json(&protocol::SetFrameResult { project })
        }
        "project.setFrameProcessingOverride" => {
            let params: protocol::SetFrameProcessingOverrideParams = parse_params(&request.params)?;
            if let Some(processing) = params.processing.as_ref() {
                let project = project_state.active.as_ref().ok_or_else(|| {
                    EngineError::new(ErrorCode::ProjectNotFound, "no project is currently open")
                })?;
                if processing.film_process != project.film_process {
                    return Err(EngineError::new(
                        ErrorCode::InvalidParams,
                        "processing.filmProcess must match the active project's filmProcess",
                    ));
                }
            }
            let project = apply_frame_mutation(project_state, params.frame_index, |frame| {
                frame.processing_override = params.processing.clone();
            })?;
            to_json(&protocol::SetFrameResult { project })
        }
        "project.setFrameOutputOverride" => {
            let params: protocol::SetFrameOutputOverrideParams = parse_params(&request.params)?;
            if let Some(output) = params.output.as_ref() {
                crate::render::validate_user_output_recipe_paths(output)?;
                validate_output_retention("frame output override", output)?;
            }
            let project = apply_frame_mutation(project_state, params.frame_index, |frame| {
                frame.output_override = params.output.clone();
            })?;
            to_json(&protocol::SetFrameResult { project })
        }
        "project.setFrameAlignment" => {
            let params: protocol::SetFrameAlignmentParams = parse_params(&request.params)?;
            let project = apply_frame_mutation(project_state, params.frame_index, |frame| {
                frame.alignment = params.alignment.clone();
            })?;
            to_json(&protocol::SetFrameResult { project })
        }
        "project.setRollMetadata" => {
            let params: protocol::SetRollMetadataParams = parse_params(&request.params)?;
            let project = project_state.active.as_mut().ok_or_else(|| {
                EngineError::new(ErrorCode::ProjectNotFound, "no project is currently open")
            })?;
            project.roll_metadata = params.metadata;
            let directory = project_state.directory.clone().expect(
                "directory is always Some whenever active is Some — ProjectState::set sets both together",
            );
            // persist_project_update (PERSIST-02), not a direct write: this
            // mutated in-memory project is otherwise exactly the stale
            // snapshot that used to clobber every receipt the scan worker
            // thread had durably attached to disk since this project was
            // last loaded. The merge preserves them; propagating any
            // persistence error here (via `?`) is unchanged from before.
            let mutated = project_state.active.clone().unwrap();
            let merged = crate::manifest::persist_project_update(&directory, &mutated)?;
            project_state.active = Some(merged.clone());
            to_json(&protocol::SetFrameResult { project: merged })
        }
        "project.setFrameMetadataOverride" => {
            let params: protocol::SetFrameMetadataOverrideParams = parse_params(&request.params)?;
            let project = apply_frame_mutation(project_state, params.frame_index, |frame| {
                frame.metadata_override = params.metadata.clone();
            })?;
            to_json(&protocol::SetFrameResult { project })
        }
        "project.pendingFrames" => {
            project_state.refresh_from_disk()?;
            let project = project_state
                .active
                .as_ref()
                .expect("refresh_from_disk sets active after reading the manifest");
            let frames = crate::manifest::pending_frames(&project);
            to_json(&protocol::PendingFramesResult {
                frames,
                total_frames: project.frame_count,
                completed_count: project
                    .frames
                    .iter()
                    .filter(|f| !f.receipts.is_empty())
                    .count() as u32,
                excluded_count: project.frames.iter().filter(|f| f.excluded).count() as u32,
            })
        }
        "project.analyzeFrameDefects" => {
            let params: protocol::AnalyzeFrameDefectsParams = parse_params(&request.params)?;
            project_state.refresh_from_disk()?;
            let project = project_state.active.as_ref().ok_or_else(|| {
                EngineError::new(ErrorCode::ProjectNotFound, "no project is currently open")
            })?;
            let frame = project
                .frames
                .iter()
                .find(|f| f.index == params.frame_index)
                .ok_or_else(|| {
                    EngineError::new(
                        ErrorCode::InvalidParams,
                        format!(
                            "frame index {} does not exist in this project",
                            params.frame_index
                        ),
                    )
                })?;
            let effective_capture = frame
                .capture_override
                .clone()
                .unwrap_or_else(|| params.capture.clone());
            let effective_processing = frame
                .processing_override
                .clone()
                .unwrap_or_else(|| params.processing.clone());

            // `simulated` and `digital_ice_enabled` are deliberately
            // independent, orthogonal signals. A real-capture-backed frame
            // with ICE currently toggled off is
            // `{simulated: false, digitalIceEnabled: false, defects: []}`,
            // so the UI can show its "ICE is off" state honestly instead of
            // mistaking it for a real, clean frame. `simulated` reports
            // provenance; `digital_ice_enabled` reports whether analysis was
            // enabled this call.
            let real_capture_receipt = most_recent_real_capture_receipt(frame);
            let has_real_capture = real_capture_receipt
                .map(|r| {
                    let rgb = std::path::Path::new(
                        r.rgb_path
                            .as_deref()
                            .expect("filtered by most_recent_real_capture_receipt"),
                    );
                    let ir = std::path::Path::new(
                        r.ir_path
                            .as_deref()
                            .expect("filtered by most_recent_real_capture_receipt"),
                    );
                    rgb.exists() && ir.exists()
                })
                .unwrap_or(false);

            let defects = if has_real_capture {
                let receipt = real_capture_receipt
                    .expect("has_real_capture implies a real capture receipt was resolved");
                crate::render::real_frame_defects(
                    std::path::Path::new(
                        receipt
                            .rgb_path
                            .as_deref()
                            .expect("filtered by most_recent_real_capture_receipt"),
                    ),
                    std::path::Path::new(
                        receipt
                            .ir_path
                            .as_deref()
                            .expect("filtered by most_recent_real_capture_receipt"),
                    ),
                    &effective_processing,
                )?
            } else {
                crate::render::generate_synthetic_defects(
                    params.frame_index,
                    &effective_capture,
                    &effective_processing,
                )
            };
            let simulated = !has_real_capture;

            // Transport-smear resolution is independent of real-capture
            // resolution: the most recent receipt overall may carry
            // telemetry even if a different receipt supplied the real capture.
            let latest_receipt = frame.receipts.last();
            let transport_smear = latest_receipt
                .and_then(|r| r.hardware_telemetry.as_ref())
                .map(|t| &t.transport_smear);
            let transport_smear_flagged = transport_smear
                .map(|a| a.verdict != "clean")
                .unwrap_or(false);
            let transport_smear_reason = if transport_smear_flagged {
                transport_smear.map(|a| a.reason.clone())
            } else {
                None
            };

            to_json(&protocol::AnalyzeFrameDefectsResult {
                frame_index: params.frame_index,
                defects,
                simulated,
                digital_ice_enabled: effective_processing.digital_ice_enabled,
                transport_smear_flagged,
                transport_smear_reason,
            })
        }
        "exiftool.detect" => to_json(&crate::exiftool::detect_exiftool()),
        "project.previewMetadataCommand" => {
            let params: protocol::PreviewMetadataCommandParams = parse_params(&request.params)?;
            project_state.refresh_from_disk()?;
            let project = project_state.active.as_ref().ok_or_else(|| {
                EngineError::new(ErrorCode::ProjectNotFound, "no project is currently open")
            })?;
            let frame = project
                .frames
                .iter()
                .find(|f| f.index == params.frame_index)
                .ok_or_else(|| {
                    EngineError::new(
                        ErrorCode::InvalidParams,
                        format!(
                            "frame index {} does not exist in this project",
                            params.frame_index
                        ),
                    )
                })?;

            let metadata =
                crate::exiftool::resolve_effective_metadata(project, params.frame_index)?;
            let targets = crate::exiftool::resolve_targets(project, params.frame_index)?;
            let archive_path = frame
                .receipts
                .last()
                .and_then(|r| r.outputs.as_ref())
                .and_then(|o| o.archive_path.as_ref())
                .map(std::path::PathBuf::from);
            if let Some(archive_path) = &archive_path {
                crate::exiftool::assert_no_archive_target(&targets, archive_path)?;
            }

            let mut arguments = crate::exiftool::build_exiftool_arguments(&metadata);
            let target_strings: Vec<String> =
                targets.iter().map(|t| t.display().to_string()).collect();
            let detection = crate::exiftool::detect_exiftool();
            let available = if arguments.is_empty() {
                true
            } else {
                arguments.push("-overwrite_original".to_string());
                arguments.extend(target_strings.iter().cloned());
                detection.available
            };

            to_json(&protocol::PreviewMetadataCommandResult {
                available,
                exiftool_path: detection.path,
                targets: target_strings,
                arguments,
            })
        }
        "project.applyMetadata" => {
            let params: protocol::ApplyMetadataParams = parse_params(&request.params)?;
            project_state.refresh_from_disk()?;
            let project = project_state.active.as_ref().ok_or_else(|| {
                EngineError::new(ErrorCode::ProjectNotFound, "no project is currently open")
            })?;
            let frame = project
                .frames
                .iter()
                .find(|f| f.index == params.frame_index)
                .ok_or_else(|| {
                    EngineError::new(
                        ErrorCode::InvalidParams,
                        format!(
                            "frame index {} does not exist in this project",
                            params.frame_index
                        ),
                    )
                })?;

            // Never trust a client-supplied argument array (04-02's own
            // "override map built from project_state alone" precedent) —
            // every argument and target below is rebuilt server-side from
            // the active project's own resolved metadata and receipts.
            let metadata =
                crate::exiftool::resolve_effective_metadata(project, params.frame_index)?;
            let targets = crate::exiftool::resolve_targets(project, params.frame_index)?;
            let archive_path = frame
                .receipts
                .last()
                .and_then(|r| r.outputs.as_ref())
                .and_then(|o| o.archive_path.as_ref())
                .map(std::path::PathBuf::from);
            if let Some(archive_path) = &archive_path {
                crate::exiftool::assert_no_archive_target(&targets, archive_path)?;
            }

            if targets.is_empty() {
                return Err(EngineError::new(
                    ErrorCode::InvalidParams,
                    format!(
                        "frame {} has no scanned outputs yet — nothing to tag",
                        params.frame_index
                    ),
                ));
            }

            let target_strings: Vec<String> =
                targets.iter().map(|t| t.display().to_string()).collect();
            let mut arguments = crate::exiftool::build_exiftool_arguments(&metadata);
            if arguments.is_empty() {
                return to_json(&protocol::ApplyMetadataResult {
                    success: true,
                    exit_code: 0,
                    stdout: "No metadata fields are set; scanned outputs were left unchanged."
                        .to_string(),
                    stderr: String::new(),
                    targets: target_strings,
                });
            }

            let detection = crate::exiftool::detect_exiftool();
            if !detection.available {
                return Err(EngineError::new(
                    ErrorCode::InvalidParams,
                    "ExifTool is not available — install it or set SCANSTUDIO_EXIFTOOL_PATH",
                ));
            }

            arguments.push("-overwrite_original".to_string());
            arguments.extend(target_strings.iter().cloned());

            let exiftool_path = detection
                .path
                .expect("detection.available implies a resolved path");
            let output = std::process::Command::new(&exiftool_path)
                .args(&arguments)
                .output()
                .map_err(|err| {
                    EngineError::new(
                        ErrorCode::Internal,
                        format!("failed to spawn exiftool: {err}"),
                    )
                })?;

            to_json(&protocol::ApplyMetadataResult {
                success: output.status.success(),
                exit_code: output.status.code().unwrap_or(-1),
                stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                targets: target_strings,
            })
        }
        other => Err(EngineError::new(
            ErrorCode::UnknownMethod,
            format!("unknown method '{other}'"),
        )),
    }
}

fn parse_params<T: serde::de::DeserializeOwned>(
    params: &serde_json::Value,
) -> Result<T, EngineError> {
    // PROTOCOL.md: "params may be omitted" — `Request.params` then decodes
    // to `Value::Null`, but serde_json can never deserialize a struct from
    // `null` (even an all-`Option`/`Default` one; struct deserialization
    // requires a map to begin with). Treat "entirely omitted" the same as
    // "explicit empty object" so all-optional param types (e.g.
    // `AcquireThumbnailsParams`) still resolve to their defaults; types
    // with required fields correctly still fail with INVALID_PARAMS either
    // way.
    let value = if params.is_null() {
        serde_json::Value::Object(serde_json::Map::new())
    } else {
        params.clone()
    };
    serde_json::from_value(value)
        .map_err(|err| EngineError::new(ErrorCode::InvalidParams, format!("invalid params: {err}")))
}

fn to_json<T: Serialize>(value: &T) -> Result<serde_json::Value, EngineError> {
    serde_json::to_value(value).map_err(|err| {
        EngineError::new(
            ErrorCode::Internal,
            format!("failed to serialize result: {err}"),
        )
    })
}

/// Shared by every `project.setFrame*` handler: finds the active project's
/// frame at `frame_index`, applies `mutate` to it via `manifest::mutate_frame`
/// (`InvalidParams` if no such frame exists — T-04-01), persists the whole
/// project, and returns the updated project.
///
/// Persistence-failure behavior deliberately differs from `scan.start`'s
/// best-effort recipe persistence: here, the persistence error propagates
/// via `?` (a real error to the caller), because durably persisting the
/// mutation is this method's entire point — silently swallowing that
/// failure would let the UI believe an exclude/override took effect when it
/// didn't.
///
/// Persists through `manifest::persist_project_update` rather than a direct
/// `write_manifest_atomically` (PERSIST-02): `project_state.active` can be
/// missing receipts the scan worker thread has durably attached straight to
/// disk since this project was last loaded, and a direct write here used to
/// silently overwrite them. The merged project persist_project_update
/// returns is folded back into `project_state.active`, so in-memory state
/// converges toward disk truth on every mutation instead of drifting
/// further from it.
fn apply_frame_mutation(
    project_state: &mut ProjectState,
    frame_index: u32,
    mutate: impl FnOnce(&mut domain::ProjectFrame),
) -> Result<domain::ScanProject, EngineError> {
    let project = project_state.active.as_mut().ok_or_else(|| {
        EngineError::new(ErrorCode::ProjectNotFound, "no project is currently open")
    })?;
    crate::manifest::mutate_frame(project, frame_index, mutate)?;
    let directory = project_state.directory.clone().expect(
        "directory is always Some whenever active is Some — ProjectState::set sets both together",
    );
    let mutated = project_state.active.clone().unwrap();
    let merged = crate::manifest::persist_project_update(&directory, &mutated)?;
    project_state.active = Some(merged.clone());
    Ok(merged)
}

fn most_recent_real_capture_receipt(frame: &domain::ProjectFrame) -> Option<&domain::ScanReceipt> {
    frame
        .receipts
        .iter()
        .rev()
        .find(|r| r.rgb_path.is_some() && r.ir_path.is_some())
}

fn emit_event<T: Serialize>(tx: &mpsc::Sender<String>, event_name: &str, payload: T) {
    let event = protocol::Event::new(event_name, payload);
    match serde_json::to_string(&event) {
        Ok(line) => {
            let _ = tx.send(line);
        }
        Err(err) => {
            eprintln!("scanstudio-engine: failed to serialize event '{event_name}': {err}");
        }
    }
}

fn respond_ok(tx: &mpsc::Sender<String>, id: u64, result: serde_json::Value) {
    let response = protocol::Response::new(id, result);
    match serde_json::to_string(&response) {
        Ok(line) => {
            let _ = tx.send(line);
        }
        Err(err) => {
            eprintln!("scanstudio-engine: failed to serialize response for id {id}: {err}");
        }
    }
}

fn respond_error(tx: &mpsc::Sender<String>, id: u64, error: &EngineError) {
    let payload: ErrorPayload = error.into();
    let response = protocol::ErrorResponse::new(id, payload);
    match serde_json::to_string(&response) {
        Ok(line) => {
            let _ = tx.send(line);
        }
        Err(err) => {
            eprintln!("scanstudio-engine: failed to serialize error response for id {id}: {err}");
        }
    }
}

/// Best-effort recovery of just the `id` field from an otherwise-malformed
/// request line, so we can still answer with a proper `{id, error}`
/// response instead of silently dropping the line.
fn best_effort_id(line: &str) -> Option<u64> {
    #[derive(serde::Deserialize)]
    struct JustId {
        id: u64,
    }
    serde_json::from_str::<JustId>(line).ok().map(|v| v.id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pre_hello_requests_are_rejected_with_invalid_params() {
        let err = reject_before_hello(false, "scanner.list").expect("must reject before hello");
        assert_eq!(err.code, ErrorCode::InvalidParams);
    }

    #[test]
    fn post_dispatch_status_is_safe_table() {
        // Simulator: all three methods are safe (in-process, no bridge to restart).
        assert!(post_dispatch_status_is_safe(
            Some(ActiveDevice::Sim),
            "scan.start"
        ));
        assert!(post_dispatch_status_is_safe(
            Some(ActiveDevice::Sim),
            "scanner.acquireThumbnails"
        ));
        assert!(post_dispatch_status_is_safe(
            Some(ActiveDevice::Sim),
            "scan.stop"
        ));

        // Real: scan.start and scanner.acquireThumbnails are hazardous; scan.stop is not.
        assert!(!post_dispatch_status_is_safe(
            Some(ActiveDevice::Real),
            "scan.start"
        ));
        assert!(!post_dispatch_status_is_safe(
            Some(ActiveDevice::Real),
            "scanner.acquireThumbnails"
        ));
        assert!(post_dispatch_status_is_safe(
            Some(ActiveDevice::Real),
            "scan.stop"
        ));

        // No active device: the status call itself returns NotConnected cheaply,
        // so the hook is safe regardless of method.
        assert!(post_dispatch_status_is_safe(None, "scan.start"));
        assert!(post_dispatch_status_is_safe(
            None,
            "scanner.acquireThumbnails"
        ));
        assert!(post_dispatch_status_is_safe(None, "scan.stop"));
    }

    #[test]
    fn parse_params_treats_omitted_params_as_empty_object_for_all_optional_types() {
        // Regression: `{"id":5,"method":"scanner.acquireThumbnails"}` (no
        // `params` key at all) is explicitly valid per PROTOCOL.md ("params
        // may be omitted"), and `AcquireThumbnailsParams.frames` is
        // `Option<Vec<u32>>` — omission must resolve to `frames: None`, not
        // an INVALID_PARAMS error.
        let omitted = serde_json::Value::Null;
        let parsed: protocol::AcquireThumbnailsParams =
            parse_params(&omitted).expect("omitted params must parse");
        assert_eq!(parsed.frames, None);
    }

    #[test]
    fn acquire_thumbnails_uses_a_matching_active_project_film_process() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("acquire-matching-project-film-process");

        for request in [
            Request {
                id: 1,
                method: "scanner.connect".into(),
                params: serde_json::json!({ "deviceId": "sim-ls5000-0", "options": { "timeScale": 0.01 } }),
            },
            Request {
                id: 2,
                method: "sim.loadMedia".into(),
                params: serde_json::json!({ "carrier": "mounted" }),
            },
            Request {
                id: 3,
                method: "project.create".into(),
                params: serde_json::json!({
                    "name": "Matching preview material",
                    "carrier": "mounted",
                    "frameCount": 1,
                    "filmProcess": "bwNegative",
                    "directory": directory.display().to_string(),
                }),
            },
        ] {
            handle_request(&mut backends, &tx, &request, &mut project_state)
                .expect("setup request must succeed");
        }

        let response = handle_request(
            &mut backends,
            &tx,
            &Request {
                id: 4,
                method: "scanner.acquireThumbnails".into(),
                params: serde_json::json!({ "filmProcess": "bwNegative" }),
            },
            &mut project_state,
        )
        .expect("matching active-project film process must be accepted");
        assert_eq!(response["accepted"], serde_json::json!(true));

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn acquire_thumbnails_rejects_a_conflicting_active_project_film_process() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("acquire-conflicting-project-film-process");
        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Conflicting preview material",
                "carrier": "mounted",
                "frameCount": 1,
                "filmProcess": "c41ColorNegative",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project create");

        let err = handle_request(
            &mut backends,
            &tx,
            &Request {
                id: 2,
                method: "scanner.acquireThumbnails".into(),
                params: serde_json::json!({ "filmProcess": "bwNegative" }),
            },
            &mut project_state,
        )
        .expect_err("conflicting active-project film process must be rejected before hardware");
        assert_eq!(err.code, ErrorCode::InvalidParams);
        assert!(err.message.contains("filmProcess conflicts"));

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn parse_params_still_rejects_omitted_params_for_required_fields() {
        // scanner.connect's deviceId is required — omitting params entirely
        // must still fail with INVALID_PARAMS, not silently default.
        let omitted = serde_json::Value::Null;
        let err = parse_params::<protocol::ConnectParams>(&omitted).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);
    }

    #[test]
    fn hello_itself_is_never_rejected_by_the_pre_hello_gate() {
        assert!(reject_before_hello(false, "engine.hello").is_none());
    }

    #[test]
    fn hello_rejects_an_incompatible_protocol_version() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let request = Request {
            id: 1,
            method: "engine.hello".into(),
            params: serde_json::json!({"clientName":"test","protocolVersion":999}),
        };
        assert_eq!(
            handle_request(&mut backends, &tx, &request, &mut ProjectState::default())
                .unwrap_err()
                .code,
            ErrorCode::InvalidParams
        );
    }

    #[test]
    fn disconnect_emits_the_offline_status_snapshot() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let connect = Request {
            id: 1,
            method: "scanner.connect".into(),
            params: serde_json::json!({"deviceId":"sim-ls5000-0"}),
        };
        handle_request(&mut backends, &tx, &connect, &mut project_state).expect("connect");
        let _ = rx.recv().expect("connected status event");

        let disconnect = Request {
            id: 2,
            method: "scanner.disconnect".into(),
            params: serde_json::json!({}),
        };
        handle_request(&mut backends, &tx, &disconnect, &mut project_state).expect("disconnect");
        let line = rx.recv().expect("disconnected status event");
        let event: serde_json::Value = serde_json::from_str(&line).expect("event json");
        assert_eq!(event["event"], "scanner.status");
        assert_eq!(event["payload"]["status"]["connected"], false);
    }

    #[test]
    fn once_hello_received_other_methods_are_allowed() {
        assert!(reject_before_hello(true, "scanner.list").is_none());
        assert!(reject_before_hello(true, "engine.shutdown").is_none());
    }

    #[test]
    fn best_effort_id_recovers_id_from_syntactically_valid_but_wrong_shaped_line() {
        // Genuinely broken JSON syntax (unterminated strings, truncated
        // input) can never be parsed for ANY field, id included — JSON
        // syntax validation happens before struct-shape reconciliation.
        // `best_effort_id` only helps when the line is valid JSON that
        // just doesn't match `Request`'s shape (here: `method` is a number
        // instead of a string), which is the realistic "malformed request"
        // case this fallback exists for.
        let line = r#"{"id": 42, "method": 123}"#;
        assert!(
            serde_json::from_str::<Request>(line).is_err(),
            "line must fail full Request parsing"
        );
        assert_eq!(best_effort_id(line), Some(42));
    }

    #[test]
    fn best_effort_id_is_none_for_totally_unparseable_line() {
        assert_eq!(best_effort_id("not json at all"), None);
    }

    /// Isolated per-test directory under the OS temp dir — never the real
    /// `~/ScanStudio Projects/` (mirrors the helper in `manifest.rs`'s own
    /// test module; kept separate since it's `server.rs`-local usage).
    fn temp_test_dir(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "scanstudio-server-test-{label}-{}",
            crate::manifest::generate_project_id()
        ))
    }

    #[test]
    fn project_create_then_open_round_trips_through_handle_request() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("create-open");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Test",
                "carrier": "roll36",
                "frameCount": 36,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        let create_result = handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");
        assert_eq!(create_result["project"]["frameCount"], 36);
        assert_eq!(create_result["project"]["schemaVersion"], 4);
        assert!(
            project_state.active.is_some(),
            "project.create must populate the active-project state"
        );

        let open_request = Request {
            id: 2,
            method: "project.open".into(),
            params: serde_json::json!({ "directory": directory.display().to_string() }),
        };
        let open_result = handle_request(&mut backends, &tx, &open_request, &mut project_state)
            .expect("project.open");
        assert_eq!(open_result["project"], create_result["project"]);

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn project_open_of_a_missing_directory_is_project_not_found() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();

        let request = Request {
            id: 1,
            method: "project.open".into(),
            params: serde_json::json!({ "directory": "/definitely/does/not/exist" }),
        };
        let err = handle_request(&mut backends, &tx, &request, &mut project_state).unwrap_err();
        assert_eq!(err.code, ErrorCode::ProjectNotFound);
    }

    #[test]
    fn project_list_returns_exactly_the_one_project_just_created() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let root = temp_test_dir("list-root");
        let project_directory = root.join("only-project");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Only Project",
                "carrier": "mounted",
                "frameCount": 1,
                "filmProcess": "kodachrome",
                "directory": project_directory.display().to_string(),
            }),
        };
        let create_result = handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");
        let created_id = create_result["project"]["id"].clone();

        let list_request = Request {
            id: 2,
            method: "project.list".into(),
            params: serde_json::json!({ "directory": root.display().to_string() }),
        };
        let list_result = handle_request(&mut backends, &tx, &list_request, &mut project_state)
            .expect("project.list");
        let projects = list_result["projects"].as_array().expect("projects array");
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0]["id"], created_id);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn project_set_frame_excluded_then_reopen_round_trips() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("set-frame-excluded");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Exclude Test",
                "carrier": "strip6",
                "frameCount": 3,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let set_request = Request {
            id: 2,
            method: "project.setFrameExcluded".into(),
            params: serde_json::json!({ "frameIndex": 2, "excluded": true }),
        };
        let set_result = handle_request(&mut backends, &tx, &set_request, &mut project_state)
            .expect("project.setFrameExcluded");
        let frames = set_result["project"]["frames"]
            .as_array()
            .expect("frames array");
        assert_eq!(frames[0]["excluded"], false, "frame 1 must be untouched");
        assert_eq!(frames[1]["excluded"], true, "frame 2 must be excluded");
        assert_eq!(frames[2]["excluded"], false, "frame 3 must be untouched");

        // A fresh, independent ProjectState -- proves the exclusion
        // survived the manifest write itself, not just this run's
        // in-memory ProjectState.
        let mut reopened_state = ProjectState::default();
        let open_request = Request {
            id: 3,
            method: "project.open".into(),
            params: serde_json::json!({ "directory": directory.display().to_string() }),
        };
        let open_result = handle_request(&mut backends, &tx, &open_request, &mut reopened_state)
            .expect("project.open");
        let reopened_frames = open_result["project"]["frames"]
            .as_array()
            .expect("frames array");
        assert_eq!(reopened_frames[1]["excluded"], true);

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn project_set_frame_capture_override_set_then_cleared_round_trips() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("set-frame-capture-override");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Capture Override Test",
                "carrier": "strip6",
                "frameCount": 2,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        let create_result = handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");
        let original_recipes = create_result["project"]["recipes"].clone();

        let set_request = Request {
            id: 2,
            method: "project.setFrameCaptureOverride".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "capture": {
                    "resolutionDpi": 2000,
                    "bitDepth": 16,
                    "multisamplePasses": 1,
                    "channels": "rgbi",
                },
            }),
        };
        let set_result = handle_request(&mut backends, &tx, &set_request, &mut project_state)
            .expect("project.setFrameCaptureOverride");
        let frames = set_result["project"]["frames"]
            .as_array()
            .expect("frames array");
        assert_eq!(frames[0]["captureOverride"]["resolutionDpi"], 2000);
        assert!(
            frames[1]["captureOverride"].is_null(),
            "sibling frame must be untouched"
        );
        assert_eq!(
            set_result["project"]["recipes"], original_recipes,
            "a per-frame override must never touch the roll-wide recipes"
        );

        let clear_request = Request {
            id: 3,
            method: "project.setFrameCaptureOverride".into(),
            params: serde_json::json!({ "frameIndex": 1, "capture": null }),
        };
        let clear_result = handle_request(&mut backends, &tx, &clear_request, &mut project_state)
            .expect("project.setFrameCaptureOverride (clear)");
        assert!(
            clear_result["project"]["frames"][0]["captureOverride"].is_null(),
            "sending null must clear the override back to None"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn project_set_frame_processing_and_output_override_round_trip() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("set-frame-processing-output-override");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Processing/Output Override Test",
                "carrier": "strip6",
                "frameCount": 1,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let set_processing_request = Request {
            id: 2,
            method: "project.setFrameProcessingOverride".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "processing": {
                    "filmProcess": "positive",
                    "autofocusEachFrame": true,
                    "autoExposureEachFrame": true,
                    "digitalIceEnabled": false,
                    "digitalIceMode": "legacy",
                },
            }),
        };
        let processing_result = handle_request(
            &mut backends,
            &tx,
            &set_processing_request,
            &mut project_state,
        )
        .expect("project.setFrameProcessingOverride");
        assert_eq!(
            processing_result["project"]["frames"][0]["processingOverride"]["filmProcess"],
            "positive"
        );

        let set_output_request = Request {
            id: 3,
            method: "project.setFrameOutputOverride".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "output": {
                    "archive": {"filenameTemplate": "Override_####", "destination": "/tmp/override-archive"},
                    "positive": {"enabled": false, "fileFormat": "jpeg", "colorProfile": "sRgb", "filenameTemplate": "Override_####", "destination": "/tmp/override-positive"},
                    "preview": {"enabled": false, "fileFormat": "jpeg", "maxLongEdgePx": 1024, "filenameTemplate": "Override_####", "destination": "/tmp/override-preview"},
                },
            }),
        };
        let output_result =
            handle_request(&mut backends, &tx, &set_output_request, &mut project_state)
                .expect("project.setFrameOutputOverride");
        assert_eq!(
            output_result["project"]["frames"][0]["outputOverride"]["archive"]["filenameTemplate"],
            "Override_####"
        );
        // Setting the output override must not disturb the processing
        // override set moments earlier on the same frame -- proves the four
        // setFrame* methods write to isolated slots, never one shared blob.
        assert_eq!(
            output_result["project"]["frames"][0]["processingOverride"]["filmProcess"],
            "positive"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn reserved_sequence_marker_is_rejected_before_frame_override_persistence() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("reserved-sequence-marker-rejection");
        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Reserved Marker Test",
                "carrier": "mounted",
                "frameCount": 1,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let mut injected = domain::OutputRecipe::default();
        injected.archive.filename_template = "ScanStudio$ScanStudioSequence(91)".into();
        let request = Request {
            id: 2,
            method: "project.setFrameOutputOverride".into(),
            params: serde_json::json!({"frameIndex": 1, "output": injected}),
        };
        let error = handle_request(&mut backends, &tx, &request, &mut project_state).unwrap_err();

        assert_eq!(error.code, ErrorCode::InvalidParams);
        assert!(error.message.contains("reserved"));
        assert!(project_state.active.as_ref().unwrap().frames[0]
            .output_override
            .is_none());
        let manifest = std::fs::read_to_string(directory.join("manifest.json")).unwrap();
        assert!(!manifest.contains("ScanStudioSequence"));
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn all_off_frame_output_override_is_rejected_without_mutating_state_or_manifest() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("all-off-frame-output-override-rejection");
        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "All-off Override Test",
                "carrier": "mounted",
                "frameCount": 1,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");
        let manifest_path = directory.join("manifest.json");
        let manifest_before = std::fs::read(&manifest_path).expect("read manifest before request");

        let mut all_off = domain::OutputRecipe::default();
        all_off.archive.enabled = false;
        all_off.archive.full_capture_package = false;
        all_off.positive.enabled = false;
        all_off.preview.enabled = false;
        let request = Request {
            id: 2,
            method: "project.setFrameOutputOverride".into(),
            params: serde_json::json!({"frameIndex": 1, "output": all_off}),
        };
        let error = handle_request(&mut backends, &tx, &request, &mut project_state)
            .expect_err("an all-off override must be rejected");

        assert_eq!(error.code, ErrorCode::InvalidParams);
        assert!(error.message.contains("at least one"));
        assert!(
            project_state.active.as_ref().unwrap().frames[0]
                .output_override
                .is_none(),
            "rejection must leave the in-memory frame unchanged"
        );
        assert_eq!(
            std::fs::read(&manifest_path).expect("read manifest after request"),
            manifest_before,
            "rejection must not rewrite the project manifest"
        );
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn scan_start_rejects_a_client_reserved_marker_before_backend_dispatch() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let mut output = domain::OutputRecipe::default();
        output.preview.filename_template = "Preview$ScanStudioSequence(4)".into();
        let request = Request {
            id: 1,
            method: "scan.start".into(),
            params: serde_json::json!({
                "frames": [1],
                "recipe": domain::CaptureRecipe::default(),
                "processing": domain::ProcessingRecipe::default(),
                "output": output,
            }),
        };

        let error = handle_request(&mut backends, &tx, &request, &mut project_state).unwrap_err();

        assert_eq!(error.code, ErrorCode::InvalidParams);
        assert!(error.message.contains("reserved"));
        assert!(
            backends.active.is_none(),
            "no backend may be dispatched or connected"
        );
    }

    #[test]
    fn project_set_frame_processing_override_rejects_a_different_film_process_at_write_time() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("set-frame-processing-material-conflict");
        let create = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Write-time material invariant",
                "carrier": "mounted",
                "frameCount": 1,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create, &mut project_state).expect("project.create");

        let invalid_write = Request {
            id: 2,
            method: "project.setFrameProcessingOverride".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "processing": { "filmProcess": "bwNegative" },
            }),
        };
        let err = handle_request(&mut backends, &tx, &invalid_write, &mut project_state)
            .expect_err("a new mixed-material frame override must never persist");
        assert_eq!(err.code, ErrorCode::InvalidParams);
        assert!(err.message.contains("must match"));
        assert!(project_state.active.as_ref().unwrap().frames[0]
            .processing_override
            .is_none());

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn project_set_frame_methods_require_an_open_project() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default(); // no project ever opened

        let request = Request {
            id: 1,
            method: "project.setFrameExcluded".into(),
            params: serde_json::json!({ "frameIndex": 1, "excluded": true }),
        };
        let err = handle_request(&mut backends, &tx, &request, &mut project_state).unwrap_err();
        assert_eq!(err.code, ErrorCode::ProjectNotFound);
    }

    #[test]
    fn project_set_frame_excluded_rejects_an_out_of_range_frame_index() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("set-frame-out-of-range");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Out Of Range Test",
                "carrier": "strip6",
                "frameCount": 2,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let request = Request {
            id: 2,
            method: "project.setFrameExcluded".into(),
            params: serde_json::json!({ "frameIndex": 99, "excluded": true }),
        };
        let err = handle_request(&mut backends, &tx, &request, &mut project_state).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn scan_start_rejects_a_request_naming_an_excluded_frame() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("scan-start-excluded-frame");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Excluded Frame Scan Test",
                "carrier": "strip6",
                "frameCount": 2,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let exclude_request = Request {
            id: 2,
            method: "project.setFrameExcluded".into(),
            params: serde_json::json!({ "frameIndex": 1, "excluded": true }),
        };
        handle_request(&mut backends, &tx, &exclude_request, &mut project_state)
            .expect("project.setFrameExcluded");

        // No scanner.connect anywhere in this test on purpose: exclusion
        // must be enforced before scan.start ever reaches the backend, so
        // this proves the rejection happens even without a connected
        // scanner (not just as an incidental side effect of some other
        // check firing first).
        let scan_request = Request {
            id: 3,
            method: "scan.start".into(),
            params: serde_json::json!({
                "frames": [1],
                "recipe": {},
            }),
        };
        let err =
            handle_request(&mut backends, &tx, &scan_request, &mut project_state).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn scan_start_rejects_legacy_per_frame_film_process_conflicts_before_capture() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("scan-start-conflicting-frame-film-process");

        let create = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Material invariant",
                "carrier": "mounted",
                "frameCount": 1,
                "filmProcess": "c41ColorNegative",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create, &mut project_state).expect("project.create");
        // A pre-invariant manifest may already contain this conflict. Seed
        // ProjectState directly to prove scan.start remains the defensive
        // boundary for existing persisted projects, even though new writes
        // are rejected by project.setFrameProcessingOverride.
        project_state
            .active
            .as_mut()
            .expect("active project")
            .frames[0]
            .processing_override = Some(domain::ProcessingRecipe {
            film_process: domain::FilmProcess::BwNegative,
            ..domain::ProcessingRecipe::default()
        });

        let scan = Request {
            id: 3,
            method: "scan.start".into(),
            params: serde_json::json!({
                "frames": [1],
                "recipe": {},
                "processing": { "filmProcess": "c41ColorNegative" },
            }),
        };
        let err = handle_request(&mut backends, &tx, &scan, &mut project_state)
            .expect_err("mixed material batch must be rejected before scanner access");
        assert_eq!(err.code, ErrorCode::InvalidParams);
        assert!(err.message.contains("processingOverride.filmProcess"));

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn analyze_frame_defects_returns_defects_for_a_valid_frame() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("analyze-frame-defects-valid");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Analyze Defects Test",
                "carrier": "strip6",
                "frameCount": 2,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let analyze_request = Request {
            id: 2,
            method: "project.analyzeFrameDefects".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "capture": {},
                "processing": { "digitalIceEnabled": true },
            }),
        };
        let result = handle_request(&mut backends, &tx, &analyze_request, &mut project_state)
            .expect("project.analyzeFrameDefects");
        assert_eq!(result["frameIndex"], 1);
        assert_eq!(result["simulated"], true);
        let defects = result["defects"].as_array().expect("defects array");
        assert!(
            !defects.is_empty(),
            "digital ICE on must produce at least one defect"
        );
        assert_eq!(result["digitalIceEnabled"], true);
        assert_eq!(result["transportSmearFlagged"], false);

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn analyze_frame_defects_rejects_an_out_of_range_frame_index() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("analyze-frame-defects-out-of-range");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Analyze Defects Out Of Range Test",
                "carrier": "strip6",
                "frameCount": 2,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let analyze_request = Request {
            id: 2,
            method: "project.analyzeFrameDefects".into(),
            params: serde_json::json!({
                "frameIndex": 99,
                "capture": {},
                "processing": {},
            }),
        };
        let err =
            handle_request(&mut backends, &tx, &analyze_request, &mut project_state).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn analyze_frame_defects_requires_an_open_project() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default(); // no project.create call

        let analyze_request = Request {
            id: 1,
            method: "project.analyzeFrameDefects".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "capture": {},
                "processing": {},
            }),
        };
        let err =
            handle_request(&mut backends, &tx, &analyze_request, &mut project_state).unwrap_err();
        assert_eq!(err.code, ErrorCode::ProjectNotFound);
    }

    #[test]
    fn analyze_frame_defects_is_deterministic_across_two_calls() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("analyze-frame-defects-deterministic");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Analyze Defects Deterministic Test",
                "carrier": "strip6",
                "frameCount": 1,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let analyze_request = Request {
            id: 2,
            method: "project.analyzeFrameDefects".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "capture": {},
                "processing": { "digitalIceEnabled": true },
            }),
        };
        let first = handle_request(&mut backends, &tx, &analyze_request, &mut project_state)
            .expect("project.analyzeFrameDefects (first)");
        let second_request = Request {
            id: 3,
            ..analyze_request
        };
        let second = handle_request(&mut backends, &tx, &second_request, &mut project_state)
            .expect("project.analyzeFrameDefects (second)");
        assert_eq!(
            first["defects"], second["defects"],
            "the same request issued twice must return identical defects"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    fn scan_receipt_with_transport_smear_verdict(
        frame_index: u32,
        verdict: &str,
        reason: &str,
    ) -> domain::ScanReceipt {
        domain::ScanReceipt {
            exposure_authority: None,
            auto_crop: None,
            job_id: "job-smear-1".into(),
            frame_index,
            started_at: "2026-07-23T09:00:00Z".into(),
            duration_ms: 1200,
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
            hardware_telemetry: Some(domain::HardwareTelemetry {
                exposure: domain::ExposureVector {
                    focus_position: 800,
                    exposure_multiplier: 1.0,
                    red_exposure_us: 1200.0,
                    green_exposure_us: 950.0,
                    blue_exposure_us: 1400.0,
                },
                clipping: domain::ClippingTelemetry {
                    fractions: (0.0, 0.0, 0.0),
                    clip_level: 0.995,
                    warning_fraction: 0.02,
                    warning: false,
                },
                focus_detail: domain::FocusDetailTelemetry {
                    method: "laplacian-variance".into(),
                    verdict: "measured".into(),
                    score: Some(180.0),
                    texture_span: 0.7,
                },
                transport_smear: domain::TransportSmearAssessment {
                    verdict: verdict.into(),
                    reason: reason.into(),
                    start_row: Some(1200),
                    suffix_rows: 40,
                    minimum_matches: 6,
                    tail_median_rms: Some(0.02),
                    tail_min_corr: Some(0.91),
                    pre_tail_median_rms: Some(0.001),
                    texture_span: Some(0.15),
                },
            }),
            nikonlook: None,
        }
    }

    #[test]
    fn analyze_frame_defects_flags_transport_smear_and_ignores_a_clean_verdict() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("transport-smear");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Transport Smear Test",
                "carrier": "strip6",
                "frameCount": 2,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        crate::manifest::persist_frame_receipt(
            &directory,
            1,
            &scan_receipt_with_transport_smear_verdict(
                1,
                "smear",
                "repeated tail rows detected past row 1200",
            ),
        )
        .expect("persist smear receipt");
        crate::manifest::persist_frame_receipt(
            &directory,
            2,
            &scan_receipt_with_transport_smear_verdict(
                2,
                "clean",
                "no repeated tail rows detected",
            ),
        )
        .expect("persist clean receipt");

        let smear_request = Request {
            id: 2,
            method: "project.analyzeFrameDefects".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "capture": {},
                "processing": { "digitalIceEnabled": true },
            }),
        };
        let smear_result = handle_request(&mut backends, &tx, &smear_request, &mut project_state)
            .expect("project.analyzeFrameDefects (smear)");
        assert_eq!(smear_result["simulated"], true);
        assert_eq!(smear_result["digitalIceEnabled"], true);
        assert_eq!(smear_result["transportSmearFlagged"], true);
        assert_eq!(
            smear_result["transportSmearReason"],
            "repeated tail rows detected past row 1200"
        );

        let clean_request = Request {
            id: 3,
            method: "project.analyzeFrameDefects".into(),
            params: serde_json::json!({
                "frameIndex": 2,
                "capture": {},
                "processing": { "digitalIceEnabled": true },
            }),
        };
        let clean_result = handle_request(&mut backends, &tx, &clean_request, &mut project_state)
            .expect("project.analyzeFrameDefects (clean)");
        assert_eq!(clean_result["transportSmearFlagged"], false);
        assert!(clean_result["transportSmearReason"].is_null());

        let _ = std::fs::remove_dir_all(&directory);
    }

    fn corpus_root_or_skip() -> Option<std::path::PathBuf> {
        match std::env::var("SCANSTUDIO_PARITY_CORPUS") {
            Ok(value) if !value.is_empty() => Some(std::path::PathBuf::from(value)),
            _ => {
                eprintln!(
                    "SCANSTUDIO_PARITY_CORPUS not set — skipping corpus-dependent test (expected in normal cargo test runs)"
                );
                None
            }
        }
    }

    fn real_capture_receipt_for_corpus_slot(
        slot: &crate::parity::types::CorpusSlot,
    ) -> domain::ScanReceipt {
        domain::ScanReceipt {
            exposure_authority: None,
            auto_crop: None,
            job_id: "job-real-1".into(),
            frame_index: 1,
            started_at: "2026-07-23T09:00:00Z".into(),
            duration_ms: 1200,
            passes: 1,
            resolution_dpi: 4000,
            bit_depth: 16,
            channels: "rgbi".into(),
            engine_version: "0.1.0".into(),
            device_id: "usb-ls5000-0".into(),
            simulated: false,
            settings_fingerprint: "1a3d265e0b54bbd2".into(),
            processing: None,
            output: None,
            outputs: None,
            rgb_path: Some(slot.rgb_path.to_string_lossy().into_owned()),
            ir_path: Some(slot.ir_path.to_string_lossy().into_owned()),
            storage_transform: None,
            meter_rgbi_path: None,
            hardware_telemetry: None,
            nikonlook: None,
        }
    }

    #[test]
    fn analyze_frame_defects_returns_real_masks_for_a_corpus_backed_frame() {
        let Some(root) = corpus_root_or_skip() else {
            return;
        };

        let manifest =
            crate::parity::corpus::discover(&root).expect("corpus discover should succeed");
        let slot = manifest
            .slots
            .iter()
            .find(|slot| slot.slot == 1)
            .expect("slot 1 must exist in the real corpus");

        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("analyze-frame-defects-corpus-real");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Analyze Defects Corpus Real Test",
                "carrier": "strip6",
                "frameCount": 1,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let project = project_state
            .active
            .as_mut()
            .expect("project.create sets active");
        project.frames[0]
            .receipts
            .push(real_capture_receipt_for_corpus_slot(slot));

        let analyze_request = Request {
            id: 2,
            method: "project.analyzeFrameDefects".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "capture": {},
                "processing": { "digitalIceEnabled": true },
            }),
        };
        let result = handle_request(&mut backends, &tx, &analyze_request, &mut project_state)
            .expect("project.analyzeFrameDefects");
        assert_eq!(result["simulated"], false);
        assert_eq!(result["digitalIceEnabled"], true);
        assert_eq!(result["transportSmearFlagged"], false);
        let defects = result["defects"].as_array().expect("defects array");
        assert!(
            !defects.is_empty(),
            "a real corpus-backed frame with ICE on must produce at least one defect instance"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn analyze_frame_defects_digital_ice_off_wins_over_a_real_capture() {
        let Some(root) = corpus_root_or_skip() else {
            return;
        };

        let manifest =
            crate::parity::corpus::discover(&root).expect("corpus discover should succeed");
        let slot = manifest
            .slots
            .iter()
            .find(|slot| slot.slot == 1)
            .expect("slot 1 must exist in the real corpus");

        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("analyze-frame-defects-corpus-ice-off");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Analyze Defects ICE Off Test",
                "carrier": "strip6",
                "frameCount": 1,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let project = project_state
            .active
            .as_mut()
            .expect("project.create sets active");
        project.frames[0]
            .receipts
            .push(real_capture_receipt_for_corpus_slot(slot));

        let analyze_request = Request {
            id: 2,
            method: "project.analyzeFrameDefects".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "capture": {},
                "processing": { "digitalIceEnabled": false },
            }),
        };
        let result = handle_request(&mut backends, &tx, &analyze_request, &mut project_state)
            .expect("project.analyzeFrameDefects");
        assert_eq!(result["digitalIceEnabled"], false);
        assert_eq!(result["simulated"], false);
        let defects = result["defects"].as_array().expect("defects array");
        assert!(
            defects.is_empty(),
            "ICE off must produce an empty defect list even when a real capture exists"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn project_set_frame_alignment_set_then_cleared_round_trips() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("set-frame-alignment");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Alignment Test",
                "carrier": "strip6",
                "frameCount": 2,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let set_request = Request {
            id: 2,
            method: "project.setFrameAlignment".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "alignment": { "offsetRows": 7, "approved": true },
            }),
        };
        let set_result = handle_request(&mut backends, &tx, &set_request, &mut project_state)
            .expect("project.setFrameAlignment");
        assert_eq!(
            set_result["project"]["frames"][0]["alignment"]["offsetRows"],
            7
        );
        assert_eq!(
            set_result["project"]["frames"][0]["alignment"]["approved"],
            true
        );
        assert!(
            set_result["project"]["frames"][1]["alignment"].is_null(),
            "sibling frame must be untouched"
        );

        let clear_request = Request {
            id: 3,
            method: "project.setFrameAlignment".into(),
            params: serde_json::json!({ "frameIndex": 1, "alignment": null }),
        };
        let clear_result = handle_request(&mut backends, &tx, &clear_request, &mut project_state)
            .expect("project.setFrameAlignment (clear)");
        assert!(
            clear_result["project"]["frames"][0]["alignment"].is_null(),
            "sending null must clear the alignment"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn project_set_roll_metadata_then_reopen_round_trips() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("set-roll-metadata");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Roll Metadata Test",
                "carrier": "strip6",
                "frameCount": 2,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let set_request = Request {
            id: 2,
            method: "project.setRollMetadata".into(),
            params: serde_json::json!({
                "metadata": {
                    "camera": "Nikon F100",
                    "date": { "kind": "yearOnly", "year": 2026 },
                },
            }),
        };
        let set_result = handle_request(&mut backends, &tx, &set_request, &mut project_state)
            .expect("project.setRollMetadata");
        assert_eq!(
            set_result["project"]["rollMetadata"]["camera"],
            "Nikon F100"
        );
        assert_eq!(
            set_result["project"]["rollMetadata"]["date"]["kind"],
            "yearOnly"
        );

        let mut reopened_state = ProjectState::default();
        let open_request = Request {
            id: 3,
            method: "project.open".into(),
            params: serde_json::json!({ "directory": directory.display().to_string() }),
        };
        let open_result = handle_request(&mut backends, &tx, &open_request, &mut reopened_state)
            .expect("project.open");
        assert_eq!(
            open_result["project"]["rollMetadata"]["camera"],
            "Nikon F100"
        );
        assert_eq!(
            open_result["project"]["rollMetadata"]["date"]["kind"],
            "yearOnly"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn project_set_frame_metadata_override_set_then_cleared_round_trips() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("set-frame-metadata-override");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Frame Metadata Override Test",
                "carrier": "strip6",
                "frameCount": 2,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let set_request = Request {
            id: 2,
            method: "project.setFrameMetadataOverride".into(),
            params: serde_json::json!({
                "frameIndex": 1,
                "metadata": {
                    "location": "Home",
                    "date": { "kind": "monthOnly", "year": 2026, "month": 7 },
                },
            }),
        };
        let set_result = handle_request(&mut backends, &tx, &set_request, &mut project_state)
            .expect("project.setFrameMetadataOverride");
        assert_eq!(
            set_result["project"]["frames"][0]["metadataOverride"]["location"],
            "Home"
        );
        assert_eq!(
            set_result["project"]["frames"][0]["metadataOverride"]["date"]["kind"],
            "monthOnly"
        );
        assert!(
            set_result["project"]["frames"][1]["metadataOverride"].is_null(),
            "sibling frame must be untouched"
        );

        let clear_request = Request {
            id: 3,
            method: "project.setFrameMetadataOverride".into(),
            params: serde_json::json!({ "frameIndex": 1, "metadata": null }),
        };
        let clear_result = handle_request(&mut backends, &tx, &clear_request, &mut project_state)
            .expect("project.setFrameMetadataOverride (clear)");
        assert!(
            clear_result["project"]["frames"][0]["metadataOverride"].is_null(),
            "sending null must clear the metadata override"
        );

        let mut reopened_state = ProjectState::default();
        let open_request = Request {
            id: 4,
            method: "project.open".into(),
            params: serde_json::json!({ "directory": directory.display().to_string() }),
        };
        let open_result = handle_request(&mut backends, &tx, &open_request, &mut reopened_state)
            .expect("project.open");
        assert!(
            open_result["project"]["frames"][0]["metadataOverride"].is_null(),
            "cleared override must stay None after reopen"
        );

        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn scan_start_params_round_trips_with_frame_alignments() {
        let params = protocol::ScanStartParams {
            frames: vec![1, 2],
            recipe: domain::CaptureRecipe::default(),
            processing: domain::ProcessingRecipe::default(),
            output: domain::OutputRecipe::default(),
            frame_alignments: {
                let mut m = std::collections::HashMap::new();
                m.insert(1, domain::FrameAlignment::approved(5));
                m.insert(2, domain::FrameAlignment::draft(-3));
                m
            },
        };
        let value = serde_json::to_value(&params).unwrap();
        assert_eq!(value["frameAlignments"]["1"]["offsetRows"], 5);
        assert_eq!(value["frameAlignments"]["2"]["approved"], false);
        let decoded: protocol::ScanStartParams = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(decoded, params);

        // Omitted field deserializes to empty map for backward compat.
        let bare: protocol::ScanStartParams = serde_json::from_value(serde_json::json!({
            "frames": [1],
            "recipe": {},
        }))
        .unwrap();
        assert!(bare.frame_alignments.is_empty());
    }

    #[test]
    fn project_pending_frames_reports_the_remaining_resume_set() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("pending-frames");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Pending Frames Test",
                "carrier": "strip6",
                "frameCount": 3,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let completed_receipt = domain::ScanReceipt {
            exposure_authority: None,
            auto_crop: None,
            job_id: "job-resume-1".into(),
            frame_index: 1,
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
        };
        // Attach the receipt both to the on-disk manifest (the production
        // path) and to the in-memory project state so the subsequent
        // setFrameExcluded write does not clobber it.
        crate::manifest::persist_frame_receipt(&directory, 1, &completed_receipt)
            .expect("persist receipt for frame 1");
        project_state
            .active
            .as_mut()
            .expect("project.create sets active")
            .frames[0]
            .receipts
            .push(completed_receipt);

        let exclude_request = Request {
            id: 2,
            method: "project.setFrameExcluded".into(),
            params: serde_json::json!({ "frameIndex": 2, "excluded": true }),
        };
        handle_request(&mut backends, &tx, &exclude_request, &mut project_state)
            .expect("project.setFrameExcluded");

        let pending_request = Request {
            id: 3,
            method: "project.pendingFrames".into(),
            params: serde_json::json!({}),
        };
        let pending_result =
            handle_request(&mut backends, &tx, &pending_request, &mut project_state)
                .expect("project.pendingFrames");

        let frames: Vec<u64> = pending_result["frames"]
            .as_array()
            .expect("frames array")
            .iter()
            .map(|v| v.as_u64().expect("frame index must be a number"))
            .collect();
        assert_eq!(frames, vec![3]);
        assert_eq!(pending_result["totalFrames"], 3);
        assert_eq!(pending_result["completedCount"], 1);
        assert_eq!(pending_result["excludedCount"], 1);

        let _ = std::fs::remove_dir_all(&directory);
    }

    fn sample_receipt(job_id: &str, frame_index: u32) -> domain::ScanReceipt {
        domain::ScanReceipt {
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

    /// PERSIST-02 regression: replays the exact live loss table from the
    /// 2026-07-29 incident report end to end at the manifest+server layer.
    /// Frame 3 scans at "10:46" (persist_frame_receipt, the scan worker
    /// thread's own durable write), then the frame 5 scan starts at "10:58"
    /// (scan.start's best-effort recipe-persistence block, server.rs:
    /// pre-fix, this is the exact write that clobbered project_state.active
    /// -- stale since project.create, zero receipts -- straight over
    /// whatever the worker thread had just attached), then frame 5 itself
    /// completes, then frame 3 is rescanned at "11:13" (another scan.start,
    /// clobbering again pre-fix) and completes a second time. Live evidence
    /// was: after the frame 5 scan, the manifest held ONLY frame 5's
    /// receipt (frame 3's was gone); after the frame 3 rescan, the manifest
    /// held ONLY frame 3's newest receipt (frame 5's was gone). Post-fix,
    /// the manifest must hold all three receipts, and project_state.active
    /// must agree with disk.
    ///
    /// No scanner is ever connected in this test: scan.start's own backend
    /// dispatch (`backends.scan_start`) sits after its recipe-persistence
    /// block (server.rs's `"scan.start"` arm) and is left to fail with
    /// NotConnected, which is irrelevant here -- the clobber this test
    /// guards against happens earlier in that same arm, unconditionally on
    /// whether the scan that follows ever actually runs. This isolates the
    /// exact defect site without needing a real (or simulated) capture.
    #[test]
    fn scan_start_recipe_persistence_never_drops_previously_persisted_receipts() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("scan-start-receipt-loss");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Receipt Loss Regression",
                "carrier": "strip6",
                "frameCount": 6,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let (output_recipe, _output_dir) = isolated_output_recipe("scan-start-receipt-loss");
        let scan_start_request = |id: u64, frame_index: u32| Request {
            id,
            method: "scan.start".into(),
            params: serde_json::json!({
                "frames": [frame_index],
                "recipe": { "resolutionDpi": 200 },
                "output": serde_json::to_value(&output_recipe).expect("serialize output recipe"),
            }),
        };

        // 10:46 -- frame 3 completes; the scan worker thread durably
        // attaches its receipt straight to the on-disk manifest, exactly
        // like real_backend.rs's/sim.rs's own post-completion call.
        let receipt_3a = sample_receipt("job-frame-3-first", 3);
        crate::manifest::persist_frame_receipt(&directory, 3, &receipt_3a)
            .expect("persist frame 3's first receipt");

        // 10:58 -- starting the frame 5 scan. Pre-fix, this call's own
        // best-effort recipe persistence clobbers the manifest with
        // project_state.active as it stood since project.create (zero
        // receipts), destroying frame 3's receipt before frame 5 is ever
        // touched. The backend dispatch that follows is expected to fail
        // (no scanner connected) and is deliberately ignored.
        let _ = handle_request(
            &mut backends,
            &tx,
            &scan_start_request(2, 5),
            &mut project_state,
        );

        let receipt_5 = sample_receipt("job-frame-5", 5);
        crate::manifest::persist_frame_receipt(&directory, 5, &receipt_5)
            .expect("persist frame 5's receipt");

        // 11:13 -- starting a rescan of frame 3. Pre-fix, this clobbers
        // again, this time destroying frame 5's just-persisted receipt.
        let _ = handle_request(
            &mut backends,
            &tx,
            &scan_start_request(3, 3),
            &mut project_state,
        );

        let receipt_3b = sample_receipt("job-frame-3-second", 3);
        crate::manifest::persist_frame_receipt(&directory, 3, &receipt_3b)
            .expect("persist frame 3's second receipt");

        let on_disk = crate::manifest::read_manifest(&directory).expect("read final manifest");
        let frame3 = on_disk
            .frames
            .iter()
            .find(|f| f.index == 3)
            .expect("frame 3 exists");
        let frame5 = on_disk
            .frames
            .iter()
            .find(|f| f.index == 5)
            .expect("frame 5 exists");
        assert_eq!(
            frame3.receipts,
            vec![receipt_3a.clone(), receipt_3b.clone()],
            "frame 3 must retain both its receipts on disk, not just the most recent scan.start's stale overwrite"
        );
        assert_eq!(
            frame5.receipts,
            vec![receipt_5.clone()],
            "frame 5's receipt must survive the later frame 3 rescan's scan.start"
        );

        // persist_frame_receipt (the scan worker thread's own write path)
        // never touches project_state -- by design, only a server-thread
        // operation does. So project_state.active is only obliged to agree
        // with disk as of the last such operation it actually ran; assert
        // that first, matching what scan.start's own merge left behind
        // after the frame 5 scan's receipt was folded in above:
        let in_memory = project_state
            .active
            .as_ref()
            .expect("project.create sets active");
        assert_eq!(
            in_memory.frames.iter().find(|f| f.index == 3).unwrap().receipts,
            vec![receipt_3a.clone()],
            "project_state.active reflects disk as of the last server-thread sync, not the worker-thread-only rescan receipt that follows it"
        );

        // Then drive one more server-thread operation (project.setRollMetadata,
        // a second of the three fixed call sites) and confirm THAT converges
        // project_state.active with everything now on disk, including the
        // frame 3 rescan receipt persist_frame_receipt just attached above.
        let set_roll_metadata_request = Request {
            id: 4,
            method: "project.setRollMetadata".into(),
            params: serde_json::json!({ "metadata": { "camera": "Nikon F3" } }),
        };
        handle_request(
            &mut backends,
            &tx,
            &set_roll_metadata_request,
            &mut project_state,
        )
        .expect("project.setRollMetadata");

        let in_memory = project_state
            .active
            .as_ref()
            .expect("project.create sets active");
        let frame3_mem = in_memory
            .frames
            .iter()
            .find(|f| f.index == 3)
            .expect("frame 3 exists");
        let frame5_mem = in_memory
            .frames
            .iter()
            .find(|f| f.index == 5)
            .expect("frame 5 exists");
        assert_eq!(
            frame3_mem.receipts, frame3.receipts,
            "setRollMetadata's own merge must converge project_state.active with disk, picking up the rescan receipt"
        );
        assert_eq!(frame5_mem.receipts, frame5.receipts);

        let _ = std::fs::remove_dir_all(&directory);
    }

    /// Isolated per-test output destination (mirrors `sim.rs`'s own private
    /// `isolated_output_recipe` test helper) so a real `scan.start` in this
    /// file's tests never collides with another test's archive write —
    /// `ArchiveRecipe` writes are create-only (`ARCHIVE_COLLISION` on a
    /// naming/destination collision).
    fn isolated_output_recipe(label: &str) -> (domain::OutputRecipe, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "scanstudio-server-test-{label}-{}",
            crate::manifest::generate_project_id()
        ));
        let mut recipe = domain::OutputRecipe::default();
        recipe.archive.destination = dir.join("Archive").display().to_string();
        recipe.positive.destination = dir.join("Positive").display().to_string();
        recipe.preview.destination = dir.join("Preview").display().to_string();
        (recipe, dir)
    }

    #[test]
    fn scan_start_rejects_all_outputs_off_before_backend_dispatch() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let mut output = domain::OutputRecipe::default();
        output.archive.enabled = false;
        output.archive.full_capture_package = false;
        output.positive.enabled = false;
        output.preview.enabled = false;
        let request = Request {
            id: 1,
            method: "scan.start".into(),
            params: serde_json::json!({
                "frames": [1],
                "recipe": {"resolutionDpi": 200},
                "output": output,
            }),
        };
        let error = handle_request(&mut backends, &tx, &request, &mut project_state)
            .expect_err("all-off output is rejected before the disconnected backend could run");
        assert_eq!(error.code, ErrorCode::InvalidParams);
        assert!(error.message.contains("at least one"));
    }

    #[test]
    fn scan_start_rejects_an_all_off_effective_per_frame_override_before_backend_dispatch() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let directory = temp_test_dir("all-off-effective-override");
        let (project, project_directory) = crate::manifest::create_project(
            "Effective Output Validation",
            domain::MediaCarrier::Strip6,
            1,
            domain::FilmProcess::C41ColorNegative,
            Some(&directory),
        )
        .expect("create test project");
        let mut project_state = ProjectState::default();
        project_state.set(project, project_directory);
        let mut all_off = domain::OutputRecipe::default();
        all_off.archive.enabled = false;
        all_off.archive.full_capture_package = false;
        all_off.positive.enabled = false;
        all_off.preview.enabled = false;
        project_state
            .active
            .as_mut()
            .expect("project active")
            .frames[0]
            .output_override = Some(all_off);

        let request = Request {
            id: 1,
            method: "scan.start".into(),
            params: serde_json::json!({
                "frames": [1],
                "recipe": {"resolutionDpi": 200},
                "output": domain::OutputRecipe::default(),
            }),
        };
        let error = handle_request(&mut backends, &tx, &request, &mut project_state).expect_err(
            "effective all-off override must fail before the disconnected backend could run",
        );
        assert_eq!(error.code, ErrorCode::InvalidParams);
        assert!(error.message.contains("frame 1") && error.message.contains("at least one"));
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn exiftool_detect_reports_the_real_installed_binary() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();

        let request = Request {
            id: 1,
            method: "exiftool.detect".into(),
            params: serde_json::json!({}),
        };
        let result = handle_request(&mut backends, &tx, &request, &mut project_state)
            .expect("exiftool.detect");

        if result["available"] != true {
            eprintln!(
                "exiftool not found on this machine — skipping the strict availability assertion (mirrors exiftool::tests's own real-binary skip)"
            );
            return;
        }
        assert_eq!(result["available"], true);
        assert!(
            result["path"].is_string(),
            "expected a resolved path: {result}"
        );
        assert!(
            result["version"].is_string(),
            "expected a captured version string: {result}"
        );
    }

    #[test]
    fn preview_metadata_command_never_includes_the_archive_path_among_targets() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("preview-metadata-command");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Preview Metadata Command Test",
                "carrier": "strip6",
                "frameCount": 1,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        let connect_request = Request {
            id: 2,
            method: "scanner.connect".into(),
            params: serde_json::json!({
                "deviceId": "sim-ls5000-0",
                "options": { "timeScale": 0.01 },
            }),
        };
        handle_request(&mut backends, &tx, &connect_request, &mut project_state)
            .expect("scanner.connect");

        let load_media_request = Request {
            id: 3,
            method: "sim.loadMedia".into(),
            params: serde_json::json!({ "carrier": "strip6" }),
        };
        handle_request(&mut backends, &tx, &load_media_request, &mut project_state)
            .expect("sim.loadMedia");

        // Disable the positive/preview derivatives and shrink the
        // resolution well below the 4000 dpi default -- mirrors sim.rs's
        // own `scan_start_persists_frame_receipts_to_manifest_for_resume`
        // test, which disables the same two derivatives for the same
        // reason: `timeScale` only scales the simulator's own sleep
        // timers, never the real disk I/O/image-encoding cost of writing
        // full-resolution derivatives, and this test only needs the
        // archive path (always written) to exist.
        let (mut output_recipe, output_dir) = isolated_output_recipe("preview-metadata-command");
        output_recipe.positive.enabled = false;
        output_recipe.preview.enabled = false;
        let scan_request = Request {
            id: 4,
            method: "scan.start".into(),
            params: serde_json::json!({
                "frames": [1],
                "recipe": { "resolutionDpi": 200 },
                "output": serde_json::to_value(&output_recipe).expect("serialize output recipe"),
            }),
        };
        handle_request(&mut backends, &tx, &scan_request, &mut project_state).expect("scan.start");

        // Drain events (scanner.status from connect/loadMedia, then the
        // job's own scan.jobState/scan.progress/scan.frameState/
        // scan.frameCompleted stream) until the job reaches its terminal
        // scan.completed event -- mirrors sim.rs's own
        // scan_start_persists_frame_receipts_to_manifest_for_resume test.
        loop {
            let line = rx
                .recv_timeout(std::time::Duration::from_secs(10))
                .expect("scan.completed event");
            let value: serde_json::Value = serde_json::from_str(&line).expect("event json");
            if value["event"] == "scan.completed" {
                break;
            }
        }

        // The worker persisted the receipt directly to disk. Metadata
        // preview must refresh that durable truth itself.
        let preview_request = Request {
            id: 5,
            method: "project.previewMetadataCommand".into(),
            params: serde_json::json!({ "frameIndex": 1 }),
        };
        let preview_result =
            handle_request(&mut backends, &tx, &preview_request, &mut project_state)
                .expect("project.previewMetadataCommand immediately after scan");

        let archive_path = project_state
            .active
            .as_ref()
            .expect("metadata preview refreshes active")
            .frames[0]
            .receipts
            .last()
            .expect("frame 1 must have a receipt after the scan completed")
            .outputs
            .as_ref()
            .expect("a completed simulated scan always writes outputs")
            .archive_path
            .clone();
        let archive_path = archive_path.expect("this archive-retaining fixture writes a master");

        let targets = preview_result["targets"].as_array().expect("targets array");
        assert!(
            !targets.is_empty(),
            "a completed frame must have at least the xmp sidecar as a target"
        );
        assert!(
            !targets
                .iter()
                .any(|t| t.as_str() == Some(archive_path.as_str())),
            "the archive path must never appear among previewMetadataCommand's targets: {targets:?}"
        );
        assert_eq!(preview_result["available"], true);
        assert_eq!(preview_result["arguments"], serde_json::json!([]));

        let apply_request = Request {
            id: 6,
            method: "project.applyMetadata".into(),
            params: serde_json::json!({ "frameIndex": 1 }),
        };
        let apply_result = handle_request(&mut backends, &tx, &apply_request, &mut project_state)
            .expect("project.applyMetadata immediately after scan");
        assert_eq!(apply_result["success"], true);
        assert_eq!(apply_result["exitCode"], 0);
        assert!(apply_result["stdout"]
            .as_str()
            .is_some_and(|text| text.contains("left unchanged")));

        let _ = std::fs::remove_dir_all(&directory);
        let _ = std::fs::remove_dir_all(&output_dir);
    }

    #[test]
    fn apply_metadata_rejects_a_frame_with_no_receipts() {
        let mut backends = Backends {
            sim: Arc::new(SimulatedLs5000::new()),
            real: None,
            active: None,
        };
        let (tx, _rx) = mpsc::channel();
        let mut project_state = ProjectState::default();
        let directory = temp_test_dir("apply-metadata-no-receipts");

        let create_request = Request {
            id: 1,
            method: "project.create".into(),
            params: serde_json::json!({
                "name": "Apply Metadata No Receipts Test",
                "carrier": "strip6",
                "frameCount": 1,
                "filmProcess": "positive",
                "directory": directory.display().to_string(),
            }),
        };
        handle_request(&mut backends, &tx, &create_request, &mut project_state)
            .expect("project.create");

        // No scan ever run against this project -- frame 1 has zero
        // receipts, so applyMetadata must refuse cleanly rather than spawn
        // exiftool against a target list it cannot honestly resolve.
        let apply_request = Request {
            id: 2,
            method: "project.applyMetadata".into(),
            params: serde_json::json!({ "frameIndex": 1 }),
        };
        let err =
            handle_request(&mut backends, &tx, &apply_request, &mut project_state).unwrap_err();
        assert_eq!(err.code, ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&directory);
    }
}
