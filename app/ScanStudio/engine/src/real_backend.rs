//! BridgeClient: subprocess supervision for the external
//! `scanstudio-bridge` sidecar (protocol/BRIDGE.md). RealLs5000's
//! ScannerBackend mapping is built on top of this in a later plan.
//!
//! `BridgeClient` is a pure transport primitive, deliberately wire-shape-
//! agnostic beyond the envelope: it owns the bridge subprocess, speaks
//! NDJSON request/response/event over its stdio, correlates responses to
//! requests by `id`, and detects + recovers from a dead or stuck bridge.
//! It does not know about `crate::domain` or `crate::protocol` at all —
//! translating bridge wire shapes into engine domain types is Plan 09-03's
//! job, one layer up.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    mpsc, Arc, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};

use crate::bridge_protocol::{BridgeHelloParams, BridgeHelloResult, BridgeRequest};

/// Fixed, short timeout for the best-effort `bridge.shutdown` attempted on
/// drop — independent of whatever `request_timeout` the client was
/// configured with, so dropping a client never blocks for a
/// production-sized request timeout.
const SHUTDOWN_TIMEOUT: Duration = Duration::from_millis(500);

/// Bound on every `BridgeClient::recv_event` call `RealLs5000`'s worker
/// threads make (Plan 09-03). The reader thread cannot distinguish
/// "bridge is thinking" from "bridge is stuck" any other way, so a silent
/// bridge is always treated as a stall after this many seconds — matches
/// `end_to_end_sim.rs`'s own 10-second convention.
const HEALTH_TIMEOUT: Duration = Duration::from_secs(10);
/// A preview worker must notice a bridge generation/session loss promptly
/// enough to release its exact reader gate before an operator can reconnect.
/// This is only a wake-up cadence: healthy long-running previews remain valid
/// until `STREAM_SILENCE_DEADLINE`, not this short interval.
const EVENT_STREAM_OWNERSHIP_RECHECK: Duration = Duration::from_millis(100);
/// CoolscanPy's `Roll.preview()` is one BLOCKING whole-roll transport read:
/// the bridge emits nothing for its entire ~60s+ traverse, then every
/// thumbnail at once (live-debugged 2026-07-23 — a 10s silence cutoff made
/// the engine abandon every real preview mid-read). Silence with a healthy
/// bridge process is therefore normal during preview/scan; only a dead
/// bridge or this hard deadline ends the wait.
const STREAM_SILENCE_DEADLINE: Duration = Duration::from_secs(600);

// ---------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------

/// Every failure mode a `BridgeClient` call can produce. `code` on
/// `BridgeError` is stored as a raw wire string (not `BridgeErrorCode`)
/// deliberately: `BridgeClient` never needs to know about specific bridge
/// error codes — that translation is Plan 09-03's job, one layer up.
#[derive(Debug)]
pub enum BridgeCallError {
    /// No response arrived within the configured request timeout.
    Timeout,
    /// The bridge subprocess exited (or its stdio disconnected) before a
    /// response arrived.
    ProcessExited,
    /// The bridge answered with a well-formed `{"error": {...}}` envelope.
    BridgeError {
        code: String,
        message: String,
        recoverable: bool,
    },
    /// Spawning the subprocess failed, or an I/O error occurred writing to
    /// its stdin, or a response line could not be interpreted.
    Io(String),
}

impl std::fmt::Display for BridgeCallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BridgeCallError::Timeout => write!(f, "bridge call timed out"),
            BridgeCallError::ProcessExited => write!(f, "bridge process exited unexpectedly"),
            BridgeCallError::BridgeError {
                code,
                message,
                recoverable,
            } => write!(f, "{code}: {message} (recoverable: {recoverable})"),
            BridgeCallError::Io(message) => write!(f, "bridge io error: {message}"),
        }
    }
}

impl std::error::Error for BridgeCallError {}

// ---------------------------------------------------------------------
// Subprocess plumbing
// ---------------------------------------------------------------------

/// Parses a configured bridge command. An exact existing filesystem path wins
/// before optional-argument splitting, so a bundled app helper continues to
/// work after the user moves `ScanStudio.app` into a directory with spaces.
/// Commands that intentionally carry arguments retain the historic simple
/// whitespace form. The packaged launcher emits the no-space PATH token
/// `scanstudio-bridge`; explicit user overrides may still use exact paths.
fn split_command(cmd: &str) -> Option<(&str, Vec<&str>)> {
    if !cmd.trim().is_empty() && std::path::Path::new(cmd).is_file() {
        return Some((cmd, Vec::new()));
    }
    let mut tokens = cmd.split_ascii_whitespace();
    let program = tokens.next()?;
    let args: Vec<&str> = tokens.collect();
    Some((program, args))
}

fn spawn_process(
    cmd: &str,
    extra_env: &[(String, String)],
) -> Result<(Child, ChildStdin, ChildStdout), BridgeCallError> {
    let (program, args) =
        split_command(cmd).ok_or_else(|| BridgeCallError::Io("bridge command is empty".into()))?;

    let mut command = Command::new(program);
    command
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    for (key, value) in extra_env {
        command.env(key, value);
    }
    let mut child = command
        .spawn()
        .map_err(|err| BridgeCallError::Io(err.to_string()))?;

    // Cargo/std guarantees both are `Some` immediately after a
    // `Stdio::piped()` spawn.
    let stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    Ok((child, stdin, stdout))
}

/// Reads NDJSON lines from the bridge's stdout for as long as the process
/// lives, dispatching each line either to its correlated `pending` waiter
/// (by `id`) or to `events_tx` (if it carries an `event` key instead).
/// Malformed lines are logged and skipped — never a panic (T-09-04).
///
/// `generation`/`my_generation` guard against a subtle restart race: if
/// this thread is superseded by a later `restart()` (a new reader thread
/// spawned for a freshly-respawned process) before it observes EOF on the
/// now-killed old process, it must not clobber the new generation's
/// `alive = true` nor drain the new generation's legitimately in-flight
/// `pending` entries. Only the reader thread whose generation still
/// matches the client's current generation is allowed to declare the
/// client dead.
#[allow(clippy::too_many_arguments)]
fn spawn_reader_thread(
    stdout: ChildStdout,
    pending: Arc<Mutex<HashMap<u64, mpsc::Sender<serde_json::Value>>>>,
    events_tx: mpsc::Sender<serde_json::Value>,
    alive: Arc<AtomicBool>,
    generation: Arc<AtomicU64>,
    my_generation: u64,
) {
    thread::spawn(move || {
        for line_result in BufReader::new(stdout).lines() {
            let line = match line_result {
                Ok(l) => l,
                Err(err) => {
                    eprintln!("scanstudio-engine: bridge stdout read error: {err}");
                    continue;
                }
            };
            if line.trim().is_empty() {
                continue;
            }

            let value: serde_json::Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(err) => {
                    eprintln!("scanstudio-engine: malformed bridge response line, skipping: {err}");
                    continue;
                }
            };

            if let Some(id) = value.get("id").and_then(|v| v.as_u64()) {
                let sender = pending.lock().unwrap().remove(&id);
                if let Some(sender) = sender {
                    let _ = sender.send(value);
                }
            } else if value.get("event").is_some() {
                let _ = events_tx.send(value);
            }
        }

        // EOF: the bridge's stdout closed, meaning the process exited.
        if generation.load(Ordering::Acquire) == my_generation {
            alive.store(false, Ordering::Release);
            // Wake an asynchronous preview/scan consumer immediately. The
            // sender stored on BridgeClient keeps the channel connected, so
            // EOF would otherwise be visible only after its next poll timeout.
            let _ = events_tx.send(serde_json::json!({
                "__bridge_client_process_exited__": true,
                "__bridge_client_generation__": my_generation
            }));
            let mut pending_guard = pending.lock().unwrap();
            let stale_ids: Vec<u64> = pending_guard.keys().copied().collect();
            for id in stale_ids {
                if let Some(sender) = pending_guard.remove(&id) {
                    let _ = sender.send(serde_json::json!({
                        "__bridge_client_process_exited__": true
                    }));
                }
            }
        }
    });
}

fn hello_request_params() -> serde_json::Value {
    serde_json::to_value(BridgeHelloParams {
        client_name: "scanstudio-engine".to_string(),
        protocol_version: 1,
    })
    .expect("serializing BridgeHelloParams cannot fail")
}

// ---------------------------------------------------------------------
// BridgeClient
// ---------------------------------------------------------------------

/// Subprocess-supervision primitive: spawns a configured bridge command,
/// speaks NDJSON request/response/event over its stdio, and transparently
/// respawns + re-handshakes on a detected hang or crash.
pub struct BridgeClient {
    cmd: String,
    /// Extra environment variables set on the spawned bridge process and
    /// re-applied on every internal `restart()` respawn, so a restarted
    /// bridge always sees the same environment as the original. Scoped to
    /// the child via `Command::env` — this process's own environment is
    /// never mutated.
    extra_env: Vec<(String, String)>,
    request_timeout: Duration,
    next_id: AtomicU64,
    child: Mutex<Child>,
    stdin: Mutex<ChildStdin>,
    pending: Arc<Mutex<HashMap<u64, mpsc::Sender<serde_json::Value>>>>,
    events_tx: mpsc::Sender<serde_json::Value>,
    events_rx: Mutex<mpsc::Receiver<serde_json::Value>>,
    /// Caches the parsed `bridge.hello` result from the most recent
    /// successful handshake (initial spawn or a later restart) so callers
    /// one layer up never need to issue a redundant second `bridge.hello`
    /// just to read `bridgeVersion` for display purposes.
    hello_info: Mutex<BridgeHelloResult>,
    alive: Arc<AtomicBool>,
    /// Bumped on every `restart()`; lets a superseded reader thread detect
    /// it no longer owns `alive`/`pending` (see `spawn_reader_thread`).
    generation: Arc<AtomicU64>,
    /// Guards `restart()` against concurrent double-invocation — both the
    /// literal case (two threads hit a timeout at once) and the reentrant
    /// case (a restart's own re-handshake fails and `call()`'s generic
    /// error handling tries to trigger another restart from inside this
    /// one).
    restarting: AtomicBool,
}

/// RAII guard resetting `restarting` back to `false` on every exit path
/// out of `restart()`, including an early return.
struct RestartGuard<'a>(&'a AtomicBool);

impl Drop for RestartGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

impl BridgeClient {
    /// Spawns `cmd`, completes the `bridge.hello` handshake, and returns a
    /// ready-to-use client. Every failure mode (command not found, version
    /// mismatch, handshake timeout) is propagated as `Err` — never a
    /// partially-initialized client.
    pub fn spawn(cmd: &str, request_timeout: Duration) -> Result<Self, BridgeCallError> {
        Self::spawn_with_env(cmd, request_timeout, &[])
    }

    /// Like [`spawn`](Self::spawn), but additionally sets `extra_env` on
    /// the spawned bridge process — scoped to that child (and re-applied
    /// to every child respawned by an internal restart), never mutating
    /// this process's own environment. Tests use this to configure
    /// `mock_bridge` failure injection; `std::env::set_var` would be
    /// process-global and leak into unrelated bridges spawned
    /// concurrently by other tests in the same test binary.
    pub fn spawn_with_env(
        cmd: &str,
        request_timeout: Duration,
        extra_env: &[(&str, &str)],
    ) -> Result<Self, BridgeCallError> {
        let extra_env: Vec<(String, String)> = extra_env
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect();
        let (child, stdin, stdout) = spawn_process(cmd, &extra_env)?;

        let pending: Arc<Mutex<HashMap<u64, mpsc::Sender<serde_json::Value>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let (events_tx, events_rx) = mpsc::channel();
        let alive = Arc::new(AtomicBool::new(true));
        let generation = Arc::new(AtomicU64::new(1));

        spawn_reader_thread(
            stdout,
            Arc::clone(&pending),
            events_tx.clone(),
            Arc::clone(&alive),
            Arc::clone(&generation),
            1,
        );

        let client = BridgeClient {
            cmd: cmd.to_string(),
            extra_env,
            request_timeout,
            next_id: AtomicU64::new(1),
            child: Mutex::new(child),
            stdin: Mutex::new(stdin),
            pending,
            events_tx,
            events_rx: Mutex::new(events_rx),
            hello_info: Mutex::new(BridgeHelloResult {
                bridge_name: String::new(),
                bridge_version: String::new(),
                protocol_version: 0,
                capabilities: vec![],
            }),
            alive,
            generation,
            restarting: AtomicBool::new(false),
        };

        // The handshake is just a normal correlated request — reuse
        // `call`. Propagate its Err verbatim: a version-mismatch or
        // timeout during the handshake must never be swallowed.
        let result_value = client.call("bridge.hello", hello_request_params())?;
        let result: BridgeHelloResult = serde_json::from_value(result_value)
            .map_err(|err| BridgeCallError::Io(format!("malformed bridge.hello result: {err}")))?;
        if result.protocol_version != 1 {
            return Err(BridgeCallError::BridgeError {
                code: "INVALID_PARAMS".to_string(),
                message: format!(
                    "bridge reported protocolVersion {}, expected 1",
                    result.protocol_version
                ),
                recoverable: false,
            });
        }
        *client.hello_info.lock().unwrap() = result;
        Ok(client)
    }

    /// Issues a correlated request and blocks (bounded by the client's
    /// configured `request_timeout`) for its response.
    pub fn call(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value, BridgeCallError> {
        self.call_with_timeout(method, params, self.request_timeout)
    }

    fn call_with_timeout(
        &self,
        method: &str,
        params: serde_json::Value,
        timeout: Duration,
    ) -> Result<serde_json::Value, BridgeCallError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel::<serde_json::Value>();

        // Register before writing anything, so a response racing ahead of
        // registration can never be missed.
        self.pending.lock().unwrap().insert(id, tx);

        let line = match serde_json::to_string(&BridgeRequest {
            id,
            method: method.to_string(),
            params,
        }) {
            Ok(l) => l,
            Err(err) => {
                self.pending.lock().unwrap().remove(&id);
                return Err(BridgeCallError::Io(err.to_string()));
            }
        };

        {
            let mut stdin = self.stdin.lock().unwrap();
            if let Err(err) = writeln!(stdin, "{line}") {
                drop(stdin);
                // A write/flush failure is only reachable once the OS has
                // already closed the child's stdin read end — i.e. the
                // process has already exited. Restart here mirrors the
                // Timeout/Disconnected arms below; the current call still
                // reports its own failure honestly.
                self.pending.lock().unwrap().remove(&id);
                self.restart();
                return Err(BridgeCallError::Io(err.to_string()));
            }
            if let Err(err) = stdin.flush() {
                drop(stdin);
                self.pending.lock().unwrap().remove(&id);
                self.restart();
                return Err(BridgeCallError::Io(err.to_string()));
            }
        }

        match rx.recv_timeout(timeout) {
            Ok(value) if value.get("__bridge_client_process_exited__").is_some() => {
                self.restart();
                Err(BridgeCallError::ProcessExited)
            }
            Ok(value) => {
                if let Some(error) = value.get("error") {
                    let code = error
                        .get("code")
                        .and_then(|c| c.as_str())
                        .unwrap_or("INTERNAL")
                        .to_string();
                    let message = error
                        .get("message")
                        .and_then(|m| m.as_str())
                        .unwrap_or("")
                        .to_string();
                    let recoverable = error
                        .get("recoverable")
                        .and_then(|r| r.as_bool())
                        .unwrap_or(false);
                    Err(BridgeCallError::BridgeError {
                        code,
                        message,
                        recoverable,
                    })
                } else if let Some(result) = value.get("result") {
                    Ok(result.clone())
                } else {
                    // Never invented as `Ok` — a line that's neither an
                    // error nor a result shape is malformed.
                    Err(BridgeCallError::Io(format!(
                        "malformed bridge response for id {id}: {value}"
                    )))
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.pending.lock().unwrap().remove(&id);
                self.restart();
                Err(BridgeCallError::Timeout)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                self.restart();
                Err(BridgeCallError::ProcessExited)
            }
        }
    }

    /// Best-effort kill + reap of whatever process currently sits in
    /// `self.child`. Always waits after killing to avoid leaving a zombie
    /// process behind.
    fn kill_and_reap_child(&self) {
        let mut child = self.child.lock().unwrap();
        let _ = child.kill();
        let _ = child.wait();
    }

    /// Kills the current subprocess, respawns it, and re-runs the
    /// `bridge.hello` handshake — exactly one attempt per detected
    /// failure. Phase 9's scope does not require unbounded reconnect
    /// retries: a permanently unavailable bridge surfaces
    /// `ProcessExited`/`Timeout` from every subsequent `call` until the
    /// process is reconfigured and the engine restarted.
    fn restart(&self) {
        if self
            .restarting
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            // A restart is already in flight for this client — either a
            // concurrent thread's, or (via call()'s generic error
            // handling) this very restart's own re-handshake attempt
            // recursing back in. Either way, do nothing further.
            return;
        }
        let _guard = RestartGuard(&self.restarting);

        self.kill_and_reap_child();

        let new_generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;

        let (new_child, new_stdin, new_stdout) = match spawn_process(&self.cmd, &self.extra_env) {
            Ok(spawned) => spawned,
            Err(_) => {
                self.alive.store(false, Ordering::Release);
                return;
            }
        };

        *self.child.lock().unwrap() = new_child;
        *self.stdin.lock().unwrap() = new_stdin;
        self.pending.lock().unwrap().clear();
        spawn_reader_thread(
            new_stdout,
            Arc::clone(&self.pending),
            self.events_tx.clone(),
            Arc::clone(&self.alive),
            Arc::clone(&self.generation),
            new_generation,
        );
        self.alive.store(true, Ordering::Release);

        match self.call("bridge.hello", hello_request_params()) {
            Ok(value) => match serde_json::from_value::<BridgeHelloResult>(value) {
                Ok(result) if result.protocol_version == 1 => {
                    *self.hello_info.lock().unwrap() = result;
                }
                _ => {
                    self.alive.store(false, Ordering::Release);
                    self.kill_and_reap_child();
                }
            },
            Err(_) => {
                // The inner re-handshake failed; call()'s own error path
                // already tried to trigger a nested restart(), which the
                // guard above turned into a no-op. Give up after this one
                // attempt.
                self.alive.store(false, Ordering::Release);
                self.kill_and_reap_child();
            }
        }
    }

    /// Blocks (bounded by `timeout`) for the next unsolicited bridge
    /// event. Callers needing to detect a stall mid-operation (e.g.
    /// Plan 09-03's `acquire_thumbnails`/`scan_start`) should call this in
    /// a loop and treat a timeout as equivalent to a crash — the reader
    /// thread cannot distinguish "bridge is thinking" from "bridge is
    /// stuck" any other way.
    pub fn recv_event(&self, timeout: Duration) -> Result<serde_json::Value, BridgeCallError> {
        let rx = self.events_rx.lock().unwrap();
        let value = rx.recv_timeout(timeout).map_err(|err| match err {
            mpsc::RecvTimeoutError::Timeout => BridgeCallError::Timeout,
            mpsc::RecvTimeoutError::Disconnected => BridgeCallError::ProcessExited,
        })?;
        if value
            .get("__bridge_client_process_exited__")
            .and_then(|flag| flag.as_bool())
            == Some(true)
        {
            Err(BridgeCallError::ProcessExited)
        } else {
            Ok(value)
        }
    }

    pub fn is_healthy(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }

    fn current_generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    /// A dead child is restarted only because the caller explicitly asked
    /// to connect. This prepares the bridge protocol process and hello
    /// handshake; it never opens a device itself.
    fn ensure_running_for_explicit_connect(&self) -> Result<(), BridgeCallError> {
        if !self.is_healthy() {
            self.restart();
        }
        if self.is_healthy() {
            Ok(())
        } else {
            Err(BridgeCallError::ProcessExited)
        }
    }

    /// The only sanctioned way to read the bridge's reported name/version
    /// — never calls `bridge.hello` a second time itself.
    pub fn hello_info(&self) -> BridgeHelloResult {
        self.hello_info.lock().unwrap().clone()
    }
}

impl Drop for BridgeClient {
    fn drop(&mut self) {
        // Best-effort: never let a dropped BridgeClient leave an orphaned
        // subprocess running, regardless of whether it answers shutdown.
        let _ = self.call_with_timeout("bridge.shutdown", serde_json::json!({}), SHUTDOWN_TIMEOUT);
        if let Ok(mut child) = self.child.lock() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

// ---------------------------------------------------------------------
// RealLs5000 (Plan 09-03): the ScannerBackend built on top of BridgeClient
// above, mapping every PROTOCOL.md-shaped call onto BRIDGE.md's wire
// shapes and back. BridgeClient itself is Plan 09-02 and is left
// untouched by this section.
// ---------------------------------------------------------------------

use crate::bridge_protocol::*;
use crate::domain::{
    self, CaptureRecipe, Channels, EngineError, FilmProcess, FrameState, JobState, MediaCarrier,
    OutputRecipe, ProcessingRecipe, ScannerBackend,
};
use crate::protocol::{
    ConnectOptions, ConnectResult, DutyCycleReport, ErrorCode, ErrorPayload, Event,
    FrameCompletedPayload, FrameIdleSample, FrameStatePayload, JobStatePayload, Lamp,
    ScanCompletedPayload, ScanProgressPayload, ScanSummary, ScannerStatus, ScannerStatusPayload,
    StopMode, ThumbnailPayload, ThumbnailsCompletePayload, ThumbnailsFailedPayload, Transport,
};
use serde::Serialize;

/// Backend for the real Nikon LS-5000, speaking to it through the
/// `scanstudio-bridge` subprocess over `BridgeClient`. Every
/// `ScannerBackend` method translates the engine's PROTOCOL.md-shaped call
/// into a BRIDGE.md request/event sequence, and translates the response
/// back.
pub struct RealLs5000 {
    bridge: BridgeClient,
    /// Monotonic identity for each successful explicit `device.open`.
    /// Async workers capture it so a late worker from an old connection can
    /// never invalidate a newer connection.
    next_session_epoch: AtomicU64,
    /// Zero means no bridge child currently owns an open device for this
    /// engine session. A nonzero value is the current explicit-connect epoch.
    active_session_epoch: AtomicU64,
    /// Bridge subprocess generation which successfully completed device.open
    /// for `active_session_epoch`. A respawned child has no inherited device
    /// handle, even if the logical epoch has not yet been retired by the
    /// server's request loop.
    active_session_bridge_generation: AtomicU64,
    /// Monotonic token for each real preview start. It prevents a late worker
    /// from an older preview in the same bridge session from authorizing an
    /// approval after a newer preview has superseded it.
    next_preview_token: AtomicU64,
    /// The sole public-approval authority: one exact, successfully completed
    /// preview operation tied to the session/process that produced it. A
    /// single mutex keeps a late preview worker from replacing a newer
    /// preview's binding in the same bridge session.
    preview_approval_state: Mutex<PreviewApprovalState>,
    /// Hard deadline for this backend's preview event stream. Stored per
    /// instance so tests can exercise timeout quarantine without mutating
    /// process-global environment or waiting for the production 10-minute
    /// ceiling.
    preview_silence_deadline: Duration,
    /// Deterministic integration-test seam for observing the tiny interval
    /// between session invalidation and an old preview reader's final detach.
    /// Production leaves this at zero.
    preview_reader_detach_delay: Duration,
    /// Builder-only regression seam: after a preview terminal has been
    /// received and ownership checked, force a bridge-generation/session loss
    /// immediately before terminal state finalization. Production leaves this
    /// disabled and no environment variable can enable it.
    preview_terminal_generation_loss_test_hook: bool,
    device_id: String,
    model: String,
    /// The holder classification derived from the bridge's authoritative
    /// `DeviceInfo.capabilities`. `device.list` supplies the initial value,
    /// and every successful `device.open` refreshes it because a holder may
    /// have changed while the device was disconnected.
    detected_holder: Mutex<Option<DetectedHolder>>,
    /// BRIDGE.md's `DeviceInfo` has no firmware field at all — this is the
    /// most honest available substitute (which bridge build is actually
    /// running), clearly distinct from the simulator's fabricated
    /// `"1.03-sim"`, and it doubles as a diagnostic.
    firmware_label: String,
    /// `CaptureRecipe.multisample_passes` values this device accepts for
    /// `scan.start`. Device-sourced and model-agnostic by construction —
    /// see `derive_supported_multisample_passes`.
    supported_multisample_passes: Vec<u32>,
    /// This backend's own scan-path silence-watchdog deadline, resolved
    /// once at construction from `SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS`
    /// (see `scan_silence_deadline_from_env`). Held per instance rather
    /// than re-read from the process environment on every job so a test
    /// can drive a short deadline through
    /// [`with_scan_silence_deadline`](Self::with_scan_silence_deadline)
    /// without mutating process-global state that a concurrently-running
    /// test would also see.
    scan_silence_deadline: Duration,
}

/// Preserves whether a session-scoped call was cleanly rejected by the same
/// bridge owner or lost the process/session boundary itself. Most callers need
/// only the mapped `EngineError`; scan.start additionally uses the distinction
/// to report an unconfirmed motion request without turning an ordinary typed
/// bridge rejection into a synthetic job event.
enum SessionCallError {
    BridgeRejected(EngineError),
    OwnershipLost(EngineError),
}

#[derive(Debug, Clone, PartialEq)]
struct CompletedPreviewApproval {
    operation_id: String,
    session_epoch: u64,
    bridge_generation: u64,
    thumbnails: HashMap<u32, BridgeThumbnail>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ActivePreviewApproval {
    token: u64,
    session_epoch: u64,
    bridge_generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PoisonedPreviewStream {
    token: u64,
    session_epoch: u64,
    bridge_generation: u64,
    terminal_drained: bool,
}

#[derive(Debug, Default)]
struct PreviewApprovalState {
    active: Option<ActivePreviewApproval>,
    completed: Option<CompletedPreviewApproval>,
    /// A healthy bridge timed out before its untagged preview terminal.
    /// The original worker remains the sole event consumer in discard-only
    /// mode until `terminal_drained` is true. No successor event consumer or
    /// reconnect may cross that boundary.
    poisoned: Option<PoisonedPreviewStream>,
}

impl SessionCallError {
    fn into_engine_error(self) -> EngineError {
        match self {
            Self::BridgeRejected(error) | Self::OwnershipLost(error) => error,
        }
    }
}

/// A freshly-created engine-owned directory used only while a real scan is
/// being converted into retained derivatives. It is never a user output
/// destination. The marker/token make deletion fail closed: if ownership is
/// not still provable after bridge closure, captures stay in place for
/// recovery. Successful cleanup retires bytes through identity-bound file
/// descriptors and leaves tiny namespace tombstones because macOS has no
/// conditional unlink-by-inode primitive.
#[derive(Debug, Clone)]
struct PrivateCaptureWorkingDirectory {
    root: std::path::PathBuf,
    owner_token: String,
}

#[derive(Debug, Clone)]
struct ExpectedCapturePaths {
    rgb: std::path::PathBuf,
}

#[derive(Debug, Clone)]
struct RealCapturePlan {
    bridge_output: BridgeOutputSpec,
    expected_by_slot: HashMap<u32, ExpectedCapturePaths>,
    private_working_directory: Option<PrivateCaptureWorkingDirectory>,
    private_slots: std::collections::HashSet<u32>,
}

const PRIVATE_CAPTURE_MARKER: &str = ".scanstudio-capture-work-owner";
static NEXT_PRIVATE_CAPTURE_DIRECTORY: AtomicU64 = AtomicU64::new(0);

impl PrivateCaptureWorkingDirectory {
    fn create() -> Result<Self, EngineError> {
        let parent = std::env::temp_dir().join("scanstudio-engine-capture-work");
        std::fs::create_dir_all(&parent).map_err(|error| {
            EngineError::new(
                ErrorCode::Internal,
                format!("create private capture workspace parent {}: {error}", parent.display()),
            )
        })?;
        for _ in 0..128 {
            let ordinal = NEXT_PRIVATE_CAPTURE_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let owner_token = format!("{:x}-{:x}-{:x}", std::process::id(), nanos, ordinal);
            let root = parent.join(format!("capture-{owner_token}"));
            match std::fs::create_dir(&root) {
                Ok(()) => {
                    let marker = root.join(PRIVATE_CAPTURE_MARKER);
                    let mut file = std::fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(&marker)
                        .map_err(|error| EngineError::new(
                            ErrorCode::Internal,
                            format!("create private capture workspace marker {}: {error}", marker.display()),
                        ))?;
                    file.write_all(owner_token.as_bytes()).map_err(|error| EngineError::new(
                        ErrorCode::Internal,
                        format!("write private capture workspace marker {}: {error}", marker.display()),
                    ))?;
                    file.sync_all().map_err(|error| EngineError::new(
                        ErrorCode::Internal,
                        format!("sync private capture workspace marker {}: {error}", marker.display()),
                    ))?;
                    return Ok(Self { root, owner_token });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(EngineError::new(
                    ErrorCode::Internal,
                    format!("create private capture workspace {}: {error}", root.display()),
                )),
            }
        }
        Err(EngineError::new(
            ErrorCode::Internal,
            "could not reserve a collision-isolated private capture workspace",
        ))
    }

    fn recovery_message(&self, reason: &str) -> String {
        self.recovery_message_at(&self.root, reason)
    }

    fn recovery_message_at(&self, recovery_root: &std::path::Path, reason: &str) -> String {
        format!(
            "temporary hardware captures are recovery-held at {}: {reason}",
            recovery_root.display()
        )
    }

    fn recovery_message_for_hold(&self, hold: &PrivateCleanupHold) -> String {
        let roots = if hold.roots.is_empty() {
            self.root.display().to_string()
        } else {
            hold.roots
                .iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        };
        format!(
            "temporary hardware captures are recovery-held at {roots}: {}",
            hold.describe()
        )
    }
}

impl RealLs5000 {
    /// Spawns `bridge_cmd`, completes the `bridge.hello` handshake (via
    /// `BridgeClient::spawn`), and resolves the one device `device.list`
    /// reports. Never returns a partially-initialized backend — every
    /// failure mode is `Err`.
    pub fn new(
        bridge_cmd: &str,
        request_timeout: std::time::Duration,
    ) -> Result<Self, EngineError> {
        Self::new_with_env(bridge_cmd, request_timeout, &[])
    }

    /// Like [`new`](Self::new), but additionally sets `bridge_env` on the
    /// spawned bridge subprocess — scoped to that child (and re-applied to
    /// every child respawned by an internal restart) via
    /// [`BridgeClient::spawn_with_env`], never mutating this process's own
    /// environment. Tests use this to configure `mock_bridge` failure
    /// injection; `std::env::set_var` would be process-global and leak
    /// into unrelated bridges spawned concurrently by other tests in the
    /// same test binary.
    pub fn new_with_env(
        bridge_cmd: &str,
        request_timeout: std::time::Duration,
        bridge_env: &[(&str, &str)],
    ) -> Result<Self, EngineError> {
        // This is the ONE place in Phase 9 where a bridge connectivity
        // failure becomes a plain `Internal` engine error: it happens
        // before any device even exists to attach a more specific code to.
        let bridge = BridgeClient::spawn_with_env(bridge_cmd, request_timeout, bridge_env)
            .map_err(|err| {
                EngineError::new(
                    ErrorCode::Internal,
                    format!("bridge spawn/handshake failed: {err}"),
                )
            })?;

        let devices_value = bridge
            .call("device.list", serde_json::json!({}))
            .map_err(map_bridge_error)?;
        let devices_result: BridgeDeviceListResult = serde_json::from_value(devices_value)
            .map_err(|err| {
                EngineError::new(
                    ErrorCode::Internal,
                    format!("malformed device.list result: {err}"),
                )
            })?;
        let bridge_device = devices_result.devices.into_iter().next().ok_or_else(|| {
            EngineError::new(ErrorCode::Internal, "bridge reported zero devices")
        })?;

        let supported_multisample_passes =
            derive_supported_multisample_passes(&bridge_device.capabilities);
        let detected_holder = derive_detected_holder(&bridge_device.capabilities);
        let firmware_label = format!("bridge {}", bridge.hello_info().bridge_version);

        Ok(RealLs5000 {
            bridge,
            next_session_epoch: AtomicU64::new(0),
            active_session_epoch: AtomicU64::new(0),
            active_session_bridge_generation: AtomicU64::new(0),
            next_preview_token: AtomicU64::new(0),
            preview_approval_state: Mutex::new(PreviewApprovalState::default()),
            preview_silence_deadline: STREAM_SILENCE_DEADLINE,
            preview_reader_detach_delay: Duration::ZERO,
            preview_terminal_generation_loss_test_hook: false,
            device_id: bridge_device.device_id,
            model: bridge_device.model,
            detected_holder: Mutex::new(detected_holder),
            firmware_label,
            supported_multisample_passes,
            scan_silence_deadline: scan_silence_deadline_from_env(),
        })
    }

    /// Overrides this backend's scan-path silence-watchdog deadline,
    /// replacing whatever `SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS` resolved
    /// to at construction. The watchdog runs inside THIS process (it is
    /// the engine's own event-poll loop, not anything the bridge child
    /// does), so unlike `mock_bridge`'s failure-injection knobs it cannot
    /// be scoped to a child via `Command::env` — this is the in-process
    /// equivalent, and the reason a test never needs `std::env::set_var`
    /// for it either.
    pub fn with_scan_silence_deadline(mut self, deadline: Duration) -> Self {
        self.scan_silence_deadline = deadline;
        self
    }

    /// Overrides the preview-path silence deadline for this backend instance.
    /// Production construction retains [`STREAM_SILENCE_DEADLINE`]; tests use
    /// this to exercise the same watchdog branch without a ten-minute wait.
    pub fn with_preview_silence_deadline(mut self, deadline: Duration) -> Self {
        self.preview_silence_deadline = deadline;
        self
    }

    /// Deterministic test seam for the interval after a lost reader has
    /// truthfully closed its public operation but before it releases its
    /// private event-stream ownership. Production keeps this at zero.
    pub fn with_preview_reader_detach_delay(mut self, delay: Duration) -> Self {
        self.preview_reader_detach_delay = delay;
        self
    }

    /// Deterministically exercises the terminal/invalidation interleaving.
    /// This is a builder-only test seam; production construction cannot enable
    /// it through process or bridge environment.
    pub fn with_preview_terminal_generation_loss_test_hook(mut self) -> Self {
        self.preview_terminal_generation_loss_test_hook = true;
        self
    }

    /// Device discovery info, independent of connection state — mirrors
    /// `SimulatedLs5000::device_info`. Not part of `ScannerBackend` since it
    /// doesn't touch backend connection state.
    pub fn device_info(&self) -> domain::DeviceInfo {
        domain::DeviceInfo {
            device_id: self.device_id.clone(),
            model: self.model.clone(),
            kind: "real".to_string(),
            firmware: self.firmware_label.clone(),
            connection: "USB (bridge)".to_string(),
        }
    }

    pub(crate) fn session_is_connected(&self) -> bool {
        self.active_session_epoch.load(Ordering::Acquire) != 0
    }

    pub(crate) fn invalidate_current_session(&self) -> bool {
        let mut preview_state = self.preview_approval_state.lock().unwrap();
        let epoch = self.active_session_epoch.swap(0, Ordering::AcqRel);
        let invalidated = epoch != 0;
        if invalidated {
            // A request-side session loss cannot prove that a preview worker
            // has stopped reading the process-global event queue. Retire
            // completed approval immediately, but leave the exact active or
            // undrained quarantined reader attached until that worker observes
            // the generation loss and detaches itself. A quarantine whose
            // terminal was already consumed has no reader left to do that, so
            // invalidation retires it here.
            Self::invalidate_preview_state_for_epoch_locked(&mut preview_state, epoch);
        }
        invalidated
    }

    pub(crate) fn disconnected_status() -> ScannerStatus {
        ScannerStatus {
            connected: false,
            adapter: None,
            media_loaded: false,
            carrier: None,
            frame_count: None,
            lamp: Lamp::Off,
            transport: Transport::Idle,
            active_job_id: None,
            motion_armed: None,
            film_present: None,
        }
    }

    fn mark_session_connected(&self) {
        self.clear_completed_preview_approval();
        let epoch = self.next_session_epoch.fetch_add(1, Ordering::AcqRel) + 1;
        self.active_session_bridge_generation
            .store(self.bridge.current_generation(), Ordering::Release);
        self.active_session_epoch.store(epoch, Ordering::Release);
    }

    fn active_session_epoch(&self) -> Result<u64, EngineError> {
        let epoch = self.active_session_epoch.load(Ordering::Acquire);
        if epoch == 0 {
            Err(EngineError::new(
                ErrorCode::NotConnected,
                "bridge device session is not open; explicit reconnect required",
            ))
        } else {
            Ok(epoch)
        }
    }

    fn active_session_identity(&self) -> Result<(u64, u64), EngineError> {
        let epoch = self.active_session_epoch()?;
        let bridge_generation = self
            .active_session_bridge_generation
            .load(Ordering::Acquire);
        if bridge_generation == 0 {
            return Err(EngineError::new(
                ErrorCode::NotConnected,
                "bridge device session has no owning process generation; explicit reconnect required",
            ));
        }
        Ok((epoch, bridge_generation))
    }

    fn session_identity_is_current(
        &self,
        expected_epoch: u64,
        expected_bridge_generation: u64,
    ) -> bool {
        expected_epoch != 0
            && self.active_session_epoch.load(Ordering::Acquire) == expected_epoch
            && self
                .active_session_bridge_generation
                .load(Ordering::Acquire)
                == expected_bridge_generation
            && self.bridge.current_generation() == expected_bridge_generation
            && self.bridge.is_healthy()
    }

    fn begin_preview_approval_window(
        &self,
        session_epoch: u64,
        bridge_generation: u64,
    ) -> Result<u64, EngineError> {
        let mut state = self.preview_approval_state.lock().unwrap();
        if state.active.is_some() {
            return Err(EngineError::new(
                ErrorCode::ScannerBusy,
                "a real preview still owns the bridge event stream; wait for its terminal result before starting another preview",
            ));
        }
        if let Some(poisoned) = state.poisoned.as_ref() {
            let detail = if poisoned.terminal_drained {
                "the predecessor terminal was safely drained; disconnect and reconnect before starting another preview"
            } else {
                "the timed-out predecessor terminal is still being quarantined; wait, then disconnect and reconnect before starting another preview"
            };
            return Err(EngineError::new(
                ErrorCode::ScannerBusy,
                format!("the real preview event stream is quarantined: {detail}"),
            ));
        }
        let token = self.next_preview_token.fetch_add(1, Ordering::AcqRel) + 1;
        state.active = Some(ActivePreviewApproval {
            token,
            session_epoch,
            bridge_generation,
        });
        state.completed = None;
        Ok(token)
    }

    fn retire_preview_approval_window(
        &self,
        token: u64,
        session_epoch: u64,
        bridge_generation: u64,
    ) {
        let mut state = self.preview_approval_state.lock().unwrap();
        if state.active.as_ref().is_some_and(|active| {
            active.token == token
                && active.session_epoch == session_epoch
                && active.bridge_generation == bridge_generation
        }) {
            state.active = None;
            state.completed = None;
        }
    }

    fn clear_completed_preview_approval(&self) {
        self.preview_approval_state.lock().unwrap().completed = None;
    }

    fn clear_completed_preview_approval_for_epoch(&self, session_epoch: u64) {
        let mut state = self.preview_approval_state.lock().unwrap();
        Self::clear_completed_preview_approval_for_epoch_locked(&mut state, session_epoch);
    }

    fn clear_completed_preview_approval_for_epoch_locked(
        state: &mut PreviewApprovalState,
        session_epoch: u64,
    ) {
        if state
            .completed
            .as_ref()
            .is_some_and(|completed| completed.session_epoch == session_epoch)
        {
            state.completed = None;
        }
    }

    fn invalidate_preview_state_for_epoch_locked(
        state: &mut PreviewApprovalState,
        session_epoch: u64,
    ) {
        Self::clear_completed_preview_approval_for_epoch_locked(state, session_epoch);
        if state.poisoned.as_ref().is_some_and(|poisoned| {
            poisoned.session_epoch == session_epoch && poisoned.terminal_drained
        }) {
            state.poisoned = None;
        }
    }

    fn clear_preview_approvals_for_epoch(&self, session_epoch: u64) {
        let mut state = self.preview_approval_state.lock().unwrap();
        if state
            .active
            .as_ref()
            .is_some_and(|active| active.session_epoch == session_epoch)
        {
            state.active = None;
        }
        if state
            .completed
            .as_ref()
            .is_some_and(|completed| completed.session_epoch == session_epoch)
        {
            state.completed = None;
        }
        if state
            .poisoned
            .as_ref()
            .is_some_and(|poisoned| poisoned.session_epoch == session_epoch)
        {
            state.poisoned = None;
        }
    }

    /// Releases the one worker which owned this exact preview event stream.
    /// Only the worker itself may call this after it has stopped receiving
    /// bridge events; request-side invalidation must retain the reader gate
    /// so a successor cannot consume a predecessor's untagged terminal.
    fn release_preview_event_reader(
        &self,
        token: u64,
        session_epoch: u64,
        bridge_generation: u64,
    ) {
        let mut state = self.preview_approval_state.lock().unwrap();
        if state.active.as_ref().is_some_and(|active| {
            active.token == token
                && active.session_epoch == session_epoch
                && active.bridge_generation == bridge_generation
        }) {
            state.active = None;
            state.completed = None;
        }
        if state.poisoned.as_ref().is_some_and(|poisoned| {
            poisoned.token == token
                && poisoned.session_epoch == session_epoch
                && poisoned.bridge_generation == bridge_generation
        }) {
            state.poisoned = None;
            state.completed = None;
        }
    }

    fn poison_preview_stream(
        &self,
        token: u64,
        session_epoch: u64,
        bridge_generation: u64,
    ) -> bool {
        let mut state = self.preview_approval_state.lock().unwrap();
        if !state.active.as_ref().is_some_and(|active| {
            active.token == token
                && active.session_epoch == session_epoch
                && active.bridge_generation == bridge_generation
        }) {
            return false;
        }
        state.active = None;
        state.completed = None;
        state.poisoned = Some(PoisonedPreviewStream {
            token,
            session_epoch,
            bridge_generation,
            terminal_drained: false,
        });
        true
    }

    fn finalize_poisoned_preview_terminal(
        &self,
        token: u64,
        session_epoch: u64,
        bridge_generation: u64,
    ) -> bool {
        let mut state = self.preview_approval_state.lock().unwrap();
        if !state.poisoned.as_ref().is_some_and(|poisoned| {
            poisoned.token == token
                && poisoned.session_epoch == session_epoch
                && poisoned.bridge_generation == bridge_generation
        }) {
            return false;
        }

        // The state mutex also guards every epoch-invalidating transition.
        // Therefore ownership cannot be retired between this proof and the
        // terminal-drained state change.
        if self.session_identity_is_current(session_epoch, bridge_generation) {
            let poisoned = state
                .poisoned
                .as_mut()
                .expect("exact poisoned preview was established above");
            poisoned.terminal_drained = true;
            true
        } else {
            // This worker consumed the terminal and will never receive again.
            // Its exact gate can therefore be retired even though session
            // ownership was lost before finalization.
            state.poisoned = None;
            state.completed = None;
            false
        }
    }

    fn ensure_preview_stream_allows_scan(
        &self,
        session_epoch: u64,
        bridge_generation: u64,
    ) -> Result<(), EngineError> {
        let state = self.preview_approval_state.lock().unwrap();
        if state.active.as_ref().is_some_and(|active| {
            active.session_epoch == session_epoch
                && active.bridge_generation == bridge_generation
        }) || state.poisoned.as_ref().is_some_and(|poisoned| {
            poisoned.session_epoch == session_epoch
                && poisoned.bridge_generation == bridge_generation
        }) {
            return Err(EngineError::new(
                ErrorCode::ScannerBusy,
                "the real preview event stream is still owned or quarantined; scan.start is blocked until preview closure and, after a timeout, explicit disconnect and reconnect",
            ));
        }
        Ok(())
    }

    fn ensure_preview_stream_allows_disconnect(
        &self,
        session_epoch: u64,
        bridge_generation: u64,
    ) -> Result<(), EngineError> {
        let state = self.preview_approval_state.lock().unwrap();
        if state.active.as_ref().is_some_and(|active| {
            active.session_epoch == session_epoch
                && active.bridge_generation == bridge_generation
        }) {
            return Err(EngineError::new(
                ErrorCode::ScannerBusy,
                "the active preview has not emitted its terminal result; disconnect is blocked so its untagged event cannot cross a session boundary",
            ));
        }
        if state.poisoned.as_ref().is_some_and(|poisoned| {
            poisoned.session_epoch == session_epoch
                && poisoned.bridge_generation == bridge_generation
                && !poisoned.terminal_drained
        }) {
            return Err(EngineError::new(
                ErrorCode::ScannerBusy,
                "the timed-out preview terminal has not yet been safely drained; disconnect is blocked so it cannot cross into a replacement session",
            ));
        }
        Ok(())
    }

    fn ensure_preview_stream_allows_connect_or_eject(&self) -> Result<(), EngineError> {
        let state = self.preview_approval_state.lock().unwrap();
        if state.active.is_some() || state.poisoned.is_some() {
            return Err(EngineError::new(
                ErrorCode::ScannerBusy,
                "the real preview event stream is still owned or quarantined; wait for closure, then disconnect and reconnect before opening a session or ejecting",
            ));
        }
        Ok(())
    }

    fn finalize_active_preview_terminal(
        &self,
        token: u64,
        operation_id: Option<&str>,
        session_epoch: u64,
        bridge_generation: u64,
        thumbnails: HashMap<u32, BridgeThumbnail>,
    ) -> bool {
        let mut state = self.preview_approval_state.lock().unwrap();
        if !state.active.as_ref().is_some_and(|active| {
            active.token == token
                && active.session_epoch == session_epoch
                && active.bridge_generation == bridge_generation
        }) {
            return false;
        }

        // Every epoch invalidator acquires this same mutex before transitioning
        // the epoch. Keep it held across the identity proof and active ->
        // completed/retired transition so no request can interleave between
        // them. A bridge-generation loss is still detected by the proof.
        let session_is_current =
            self.session_identity_is_current(session_epoch, bridge_generation);
        state.active = None;
        state.completed = None;
        if session_is_current {
            if let Some(operation_id) = operation_id.filter(|value| !value.trim().is_empty()) {
                state.completed = Some(CompletedPreviewApproval {
                    operation_id: operation_id.to_string(),
                    session_epoch,
                    bridge_generation,
                    thumbnails,
                });
            }
        }
        session_is_current
    }

    fn clear_completed_preview_if_session_is_current(
        &self,
        session_epoch: u64,
        bridge_generation: u64,
    ) {
        if self.active_session_identity() == Ok((session_epoch, bridge_generation)) {
            let mut state = self.preview_approval_state.lock().unwrap();
            if state.active.is_none() && state.completed.as_ref().is_some_and(|binding| {
                binding.session_epoch == session_epoch
                    && binding.bridge_generation == bridge_generation
            }) {
                state.completed = None;
            }
        }
    }

    fn session_ownership_lost_error(
        &self,
        method: &str,
        expected_epoch: u64,
        expected_bridge_generation: u64,
        detail: impl std::fmt::Display,
    ) -> EngineError {
        let current_epoch = self.active_session_epoch.load(Ordering::Acquire);
        let current_bridge_generation = self.bridge.current_generation();
        let bridge_healthy = self.bridge.is_healthy();
        EngineError::new(
            ErrorCode::NotConnected,
            format!(
                "bridge session ownership was lost during session-scoped {method}; reconnect required; sessionEpochExpected={expected_epoch}; sessionEpochCurrent={current_epoch}; bridgeGenerationExpected={expected_bridge_generation}; bridgeGenerationCurrent={current_bridge_generation}; bridgeHealthy={bridge_healthy}; {detail}; no automatic open or motion retry was attempted"
            ),
        )
    }

    /// Calls a bridge method only while the exact device.open epoch and child
    /// process generation which own that session are still current. A bridge
    /// transport/wire failure is a typed connection loss in this scope:
    /// BridgeClient may have respawned a protocol process, but that replacement
    /// never inherits the old process's device handle. Clean bridge rejections
    /// retain their existing typed mapping.
    fn call_session_scoped_detailed(
        &self,
        expected_epoch: u64,
        expected_bridge_generation: u64,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value, SessionCallError> {
        let current_epoch = self.active_session_epoch.load(Ordering::Acquire);
        let session_bridge_generation = self
            .active_session_bridge_generation
            .load(Ordering::Acquire);
        let current_bridge_generation = self.bridge.current_generation();
        if expected_epoch == 0
            || current_epoch != expected_epoch
            || session_bridge_generation != expected_bridge_generation
            || current_bridge_generation != expected_bridge_generation
            || !self.bridge.is_healthy()
        {
            self.clear_completed_preview_approval_for_epoch(expected_epoch);
            return Err(SessionCallError::OwnershipLost(
                self.session_ownership_lost_error(
                    method,
                    expected_epoch,
                    expected_bridge_generation,
                    "the expected open-device owner was no longer current before dispatch",
                ),
            ));
        }

        let result = match self.bridge.call(method, params) {
            Ok(result) => result,
            Err(bridge_error @ BridgeCallError::BridgeError { .. }) => {
                return Err(SessionCallError::BridgeRejected(map_bridge_error(
                    bridge_error,
                )));
            }
            Err(transport_error) => {
                // The request crossed a broken bridge ownership boundary.
                // Retire its exact preview authority immediately, even for
                // direct backend callers that do not have server.rs around
                // to reconcile the resulting NOT_CONNECTED error.
                self.clear_completed_preview_approval_for_epoch(expected_epoch);
                return Err(SessionCallError::OwnershipLost(
                    self.session_ownership_lost_error(
                        method,
                        expected_epoch,
                        expected_bridge_generation,
                        format!("bridge transport failure: {transport_error}"),
                    ),
                ));
            }
        };

        // Close the response/ownership race as far as an in-process check can:
        // a syntactically valid response from a child which has already exited
        // must not leave the UI claiming that child still owns device.open.
        let current_epoch = self.active_session_epoch.load(Ordering::Acquire);
        let current_bridge_generation = self.bridge.current_generation();
        if current_epoch != expected_epoch
            || current_bridge_generation != expected_bridge_generation
            || !self.bridge.is_healthy()
        {
            self.clear_completed_preview_approval_for_epoch(expected_epoch);
            return Err(SessionCallError::OwnershipLost(
                self.session_ownership_lost_error(
                    method,
                    expected_epoch,
                    expected_bridge_generation,
                    "the expected open-device owner was no longer current after its response",
                ),
            ));
        }

        Ok(result)
    }

    fn call_session_scoped(
        &self,
        expected_epoch: u64,
        expected_bridge_generation: u64,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value, EngineError> {
        self.call_session_scoped_detailed(
            expected_epoch,
            expected_bridge_generation,
            method,
            params,
        )
        .map_err(SessionCallError::into_engine_error)
    }

    /// Atomically retires only the connection epoch that accepted an async
    /// operation. Winning the transition also owns the one disconnected
    /// status event for that epoch.
    fn invalidate_async_session(
        &self,
        expected_epoch: u64,
        event_tx: &mpsc::Sender<String>,
        operation_id: Option<String>,
    ) -> bool {
        let mut preview_state = self.preview_approval_state.lock().unwrap();
        if expected_epoch == 0
            || self
                .active_session_epoch
                .compare_exchange(
                    expected_epoch,
                    0,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_err()
        {
            return false;
        }

        Self::invalidate_preview_state_for_epoch_locked(&mut preview_state, expected_epoch);
        drop(preview_state);

        emit(
            event_tx,
            "scanner.status",
            ScannerStatusPayload {
                status: Self::disconnected_status(),
                operation_id,
            },
        );
        true
    }

    /// Shared by `disconnect`/`status`/`eject`: `device.close`/`device.eject`
    /// both return `{}`, not a status — fetch a fresh `device.status`
    /// snapshot and map it (mirrors PROTOCOL.md's own contract that these
    /// calls return the resulting status).
    fn fresh_status_for_session(
        &self,
        session_epoch: u64,
        bridge_generation: u64,
    ) -> Result<ScannerStatus, EngineError> {
        let status_value = self.call_session_scoped(
            session_epoch,
            bridge_generation,
            "device.status",
            serde_json::json!({}),
        )?;
        let status: BridgeDeviceStatus = serde_json::from_value(status_value).map_err(|err| {
            EngineError::new(
                ErrorCode::Internal,
                format!("malformed device.status result: {err}"),
            )
        })?;
        if !status.preview_established {
            self.clear_completed_preview_if_session_is_current(
                session_epoch,
                bridge_generation,
            );
        }
        Ok(map_status(&status, self.detected_holder()))
    }

    fn emit_terminal_status_or_invalidate(
        &self,
        session_epoch: u64,
        bridge_generation: u64,
        event_tx: &mpsc::Sender<String>,
        operation_id: Option<String>,
    ) {
        match self.fresh_status_for_session(session_epoch, bridge_generation) {
            Ok(status) => emit(
                event_tx,
                "scanner.status",
                ScannerStatusPayload {
                    status,
                    operation_id,
                },
            ),
            Err(error) if error.code == ErrorCode::NotConnected => {
                // The epoch CAS is the sole owner of the disconnected event.
                // A late terminal worker from an older epoch therefore cannot
                // invalidate or emit status for a newer explicit reconnect.
                self.invalidate_async_session(session_epoch, event_tx, operation_id);
            }
            // A malformed status payload or another non-ownership error does
            // not prove the device handle was lost. The terminal scan/preview
            // events already emitted above remain authoritative.
            Err(_) => {}
        }
    }

    /// Closes an async preview after its bridge/session ownership was lost.
    /// The release of the exact reader token is deliberately the final action:
    /// until then, reconnect and all successor event consumers remain gated.
    fn close_lost_preview_reader(
        &self,
        token: u64,
        session_epoch: u64,
        bridge_generation: u64,
        event_tx: &mpsc::Sender<String>,
        operation_id: &Option<String>,
        received_count: u32,
    ) {
        let current_epoch = self.active_session_epoch.load(Ordering::Acquire);
        let current_bridge_generation = self.bridge.current_generation();
        let bridge_healthy = self.bridge.is_healthy();
        let connection_evidence = format!(
            "sessionEpoch={session_epoch}; sessionEpochCurrent={current_epoch}; bridgeGenerationStart={bridge_generation}; bridgeGenerationCurrent={current_bridge_generation}; bridgeHealthy={bridge_healthy}"
        );
        emit(
            event_tx,
            "scanner.thumbnailsFailed",
            ThumbnailsFailedPayload {
                code: "NOT_CONNECTED".to_string(),
                message: format!(
                    "bridge session ownership was lost asynchronously mid-preview; reconnect required; {connection_evidence}"
                ),
                operation_id: operation_id.clone(),
            },
        );
        self.invalidate_async_session(session_epoch, event_tx, operation_id.clone());
        emit(
            event_tx,
            "scanner.thumbnailsComplete",
            ThumbnailsCompletePayload {
                count: received_count,
                operation_id: operation_id.clone(),
            },
        );
        self.detach_lost_preview_reader(token, session_epoch, bridge_generation);
    }

    /// Optional delay exists only for the deterministic integration seam; the
    /// release itself must be the final action of a lost worker.
    fn detach_lost_preview_reader(
        &self,
        token: u64,
        session_epoch: u64,
        bridge_generation: u64,
    ) {
        if !self.preview_reader_detach_delay.is_zero() {
            thread::sleep(self.preview_reader_detach_delay);
        }
        self.release_preview_event_reader(token, session_epoch, bridge_generation);
    }

    fn detected_holder(&self) -> Option<DetectedHolder> {
        *self.detected_holder.lock().unwrap()
    }

    fn refresh_detected_holder(&self, capabilities: &BridgeCapabilities) {
        *self.detected_holder.lock().unwrap() = derive_detected_holder(capabilities);
    }

    /// Forwards one explicit operator approval to the bridge-owned preview
    /// session. The `frame_index` name belongs to the public engine protocol;
    /// current real previews use the same stable number as BRIDGE.md's
    /// scanner-addressable `slot`. This is intentionally a single
    /// session-scoped request: it never starts a preview, moves film, starts
    /// capture, or follows up with `device.status`.
    pub fn roll_approve(
        &self,
        frame_index: u32,
        operation_id: &str,
    ) -> Result<(), EngineError> {
        if operation_id.trim().is_empty() {
            return Err(EngineError::new(
                ErrorCode::InvalidParams,
                "operationId must name the exact completed preview being approved",
            ));
        }
        let (session_epoch, bridge_generation) = self.active_session_identity()?;
        let binding = self.preview_approval_state.lock().unwrap().completed.clone();
        if !binding.as_ref().is_some_and(|binding| {
            binding.operation_id == operation_id
                && binding.session_epoch == session_epoch
                && binding.bridge_generation == bridge_generation
        }) {
            return Err(EngineError::new(
                ErrorCode::InvalidParams,
                "operationId does not match a successfully completed preview in the current bridge session",
            ));
        }
        let params = BridgeRollApproveParams { slot: frame_index };
        let value = serde_json::to_value(params).expect("BridgeRollApproveParams serializes");
        self.call_session_scoped(
            session_epoch,
            bridge_generation,
            "roll.approve",
            value,
        )?;
        Ok(())
    }

    /// Updates the current preview session's driver-owned frame alignment.
    /// This is a non-motion bridge request: it does not refresh device status,
    /// start another preview, or enter the scan lane.
    pub fn roll_set_spacing_offset(
        &self,
        frame_index: u32,
        offset_rows: i64,
        operation_id: &str,
    ) -> Result<crate::protocol::Thumbnail, EngineError> {
        let (session_epoch, bridge_generation) = self.active_session_identity()?;
        let binding = self
            .preview_approval_state
            .lock()
            .unwrap()
            .completed
            .clone();
        let binding_matches = binding.as_ref().is_some_and(|binding| {
            binding.operation_id == operation_id
                && binding.session_epoch == session_epoch
                && binding.bridge_generation == bridge_generation
                && binding.thumbnails.contains_key(&frame_index)
        });
        if !binding_matches {
            return Err(EngineError::new(
                ErrorCode::InvalidParams,
                "frameIndex and operationId must identify a frame returned by the successfully completed preview in the current bridge session",
            ));
        }

        let value = self.call_session_scoped(
            session_epoch,
            bridge_generation,
            "roll.setSpacingOffset",
            serde_json::to_value(BridgeRollSetSpacingOffsetParams {
                slot: frame_index,
                offset_rows,
            })
            .expect("BridgeRollSetSpacingOffsetParams serializes"),
        )?;
        let result: BridgeRollSetSpacingOffsetResult =
            serde_json::from_value(value).map_err(|error| {
                EngineError::new(
                    ErrorCode::Internal,
                    format!("malformed roll.setSpacingOffset result: {error}"),
                )
            })?;
        Ok(crate::protocol::Thumbnail {
            brightness: None,
            tint: None,
            image_path: Some(result.thumbnail.image_path),
            boundary_rows: Some(result.thumbnail.boundary_rows),
            spacing_offset: Some(result.thumbnail.spacing_offset),
            needs_approval: result.thumbnail.needs_approval,
            warnings: result.thumbnail.warnings,
        })
    }
}

impl ScannerBackend for RealLs5000 {
    fn connect(
        &self,
        device_id: &str,
        _options: &ConnectOptions,
    ) -> Result<ConnectResult, EngineError> {
        self.ensure_preview_stream_allows_connect_or_eject()?;
        // BRIDGE.md has no equivalent of the simulator's `timeScale` /
        // `faultInjection` concepts — both are simulator-only, so
        // `options` is intentionally ignored here.
        self.bridge
            .ensure_running_for_explicit_connect()
            .map_err(|err| {
                EngineError::new(
                    ErrorCode::NotConnected,
                    format!("bridge is unavailable for explicit reconnect: {err}"),
                )
            })?;
        let result_value = self
            .bridge
            .call("device.open", serde_json::json!({ "deviceId": device_id }))
            .map_err(|error| match error {
                bridge_error @ BridgeCallError::BridgeError { .. } => {
                    map_bridge_error(bridge_error)
                }
                transport_error => EngineError::new(
                    ErrorCode::NotConnected,
                    format!(
                        "bridge was lost while establishing an explicit device session; reconnect remains required; bridge transport failure: {transport_error}; device.open was not retried"
                    ),
                ),
            })?;
        let result: BridgeDeviceOpenResult =
            serde_json::from_value(result_value).map_err(|err| {
                EngineError::new(
                    ErrorCode::Internal,
                    format!("malformed device.open result: {err}"),
                )
            })?;
        // `device.open` is newer than the construction-time `device.list`
        // result: the physical holder can change while disconnected.
        self.refresh_detected_holder(&result.device.capabilities);
        self.mark_session_connected();
        Ok(ConnectResult {
            device: self.device_info(),
            status: map_status(&result.status, self.detected_holder()),
        })
    }

    fn disconnect(&self) -> Result<ScannerStatus, EngineError> {
        let (session_epoch, bridge_generation) = self.active_session_identity()?;
        self.ensure_preview_stream_allows_disconnect(session_epoch, bridge_generation)?;
        self.call_session_scoped(
            session_epoch,
            bridge_generation,
            "device.close",
            serde_json::json!({}),
        )?;
        // The stream gate above proved that no active reader remains (a
        // drained timeout is also safe to retire here), so this clean close
        // may clear the entire session-scoped preview state.
        self.clear_preview_approvals_for_epoch(session_epoch);
        self.invalidate_current_session();
        Ok(Self::disconnected_status())
    }

    fn status(&self) -> Result<ScannerStatus, EngineError> {
        let (session_epoch, bridge_generation) = self.active_session_identity()?;
        self.fresh_status_for_session(session_epoch, bridge_generation)
    }

    fn load_media(&self, _carrier: MediaCarrier) -> Result<ScannerStatus, EngineError> {
        Err(EngineError::new(
            ErrorCode::Internal,
            "sim.loadMedia is a simulator-only affordance (see PROTOCOL.md: 'a real backend detects media'); the real backend detects media via roll.preview, not an explicit load-media call",
        ))
    }

    fn eject(&self) -> Result<ScannerStatus, EngineError> {
        let (session_epoch, bridge_generation) = self.active_session_identity()?;
        self.ensure_preview_stream_allows_connect_or_eject()?;
        self.call_session_scoped(
            session_epoch,
            bridge_generation,
            "device.eject",
            serde_json::json!({}),
        )?;
        self.clear_preview_approvals_for_epoch(session_epoch);
        self.fresh_status_for_session(session_epoch, bridge_generation)
    }

    fn acquire_thumbnails(
        backend: &Arc<Self>,
        frames: Option<Vec<u32>>,
        film_process: FilmProcess,
        operation_id: Option<String>,
        event_tx: mpsc::Sender<String>,
    ) -> Result<Vec<u32>, EngineError> {
        let (session_epoch, bridge_generation) = backend.active_session_identity()?;
        let preview_token =
            backend.begin_preview_approval_window(session_epoch, bridge_generation)?;
        // "Reject before accepting": validate/round-trip synchronously,
        // exactly like every other ScannerBackend method; the actual
        // preview stream is reported purely through events afterward.
        backend
            .call_session_scoped(
                session_epoch,
                bridge_generation,
                "roll.preview",
                serde_json::json!({ "material": map_material(film_process) }),
            )
            .map_err(|error| {
                backend.retire_preview_approval_window(
                    preview_token,
                    session_epoch,
                    bridge_generation,
                );
                error
            })?;

        let backend_for_thread = Arc::clone(backend);
        thread::spawn(move || {
            let mut received_count: u32 = 0;
            let mut dropped_count: u32 = 0;
            let mut received_thumbnails = HashMap::new();
            let silence_deadline = Instant::now() + backend_for_thread.preview_silence_deadline;
            loop {
                if !backend_for_thread
                    .session_identity_is_current(session_epoch, bridge_generation)
                {
                    backend_for_thread.close_lost_preview_reader(
                        preview_token,
                        session_epoch,
                        bridge_generation,
                        &event_tx,
                        &operation_id,
                        received_count,
                    );
                    return;
                }
                let poll_timeout = HEALTH_TIMEOUT.min(
                    silence_deadline.saturating_duration_since(Instant::now()),
                )
                .min(EVENT_STREAM_OWNERSHIP_RECHECK);
                match backend_for_thread.bridge.recv_event(poll_timeout) {
                    Ok(value) => {
                        // The event receiver spans bridge subprocess
                        // generations. Re-prove ownership after receiving and
                        // before decoding anything: an old reader must never
                        // forward a replacement session's untagged event.
                        if !backend_for_thread
                            .session_identity_is_current(session_epoch, bridge_generation)
                        {
                            backend_for_thread.close_lost_preview_reader(
                                preview_token,
                                session_epoch,
                                bridge_generation,
                                &event_tx,
                                &operation_id,
                                received_count,
                            );
                            return;
                        }
                        match value.get("event").and_then(|v| v.as_str()).unwrap_or("") {
                            "roll.thumbnail" => {
                                // Live-debugged 2026-07-23: the bridge sends
                                // `{"thumbnail": {...}}` with `slot` INSIDE
                                // the thumbnail — the old struct demanded a
                                // second top-level `slot` and silently
                                // dropped all 37 real events while both
                                // sides' mocks agreed with their own reader.
                                // Decode the thumbnail itself as the single
                                // source of truth and count what we drop.
                                let decoded = value
                                    .pointer("/payload/thumbnail")
                                    .cloned()
                                    .and_then(|t| {
                                        serde_json::from_value::<BridgeThumbnail>(t).ok()
                                    });
                                let Some(bridge_thumbnail) = decoded else {
                                    dropped_count += 1;
                                    continue;
                                };
                                // Phase 10: BRIDGE.md's bridge-written
                                // preview-tile file (`imagePath`) is now the
                                // real data, forwarded verbatim; there is no
                                // "real" brightness/tint to report, so they
                                // are honestly omitted rather than reusing
                                // sim.rs's FNV-fake derivation.
                                let thumbnail = crate::protocol::Thumbnail {
                                    brightness: None,
                                    tint: None,
                                    image_path: Some(bridge_thumbnail.image_path.clone()),
                                    boundary_rows: Some(bridge_thumbnail.boundary_rows),
                                    spacing_offset: Some(bridge_thumbnail.spacing_offset),
                                    needs_approval: bridge_thumbnail.needs_approval,
                                    warnings: bridge_thumbnail.warnings.clone(),
                                };
                                emit(
                                    &event_tx,
                                    "scanner.thumbnail",
                                    ThumbnailPayload {
                                        frame_index: bridge_thumbnail.slot,
                                        thumbnail,
                                        operation_id: operation_id.clone(),
                                    },
                                );
                                received_thumbnails.insert(bridge_thumbnail.slot, bridge_thumbnail);
                                received_count += 1;
                            }
                            "roll.previewComplete" => {
                                if backend_for_thread
                                    .preview_terminal_generation_loss_test_hook
                                {
                                    backend_for_thread.bridge.restart();
                                    backend_for_thread.invalidate_current_session();
                                }
                                let approval_operation_id = if dropped_count == 0 {
                                    operation_id.as_deref()
                                } else {
                                    None
                                };
                                if !backend_for_thread.finalize_active_preview_terminal(
                                    preview_token,
                                    approval_operation_id,
                                    session_epoch,
                                    bridge_generation,
                                    received_thumbnails,
                                ) {
                                    backend_for_thread.close_lost_preview_reader(
                                        preview_token,
                                        session_epoch,
                                        bridge_generation,
                                        &event_tx,
                                        &operation_id,
                                        received_count,
                                    );
                                    return;
                                }
                                if dropped_count > 0 {
                                    emit(
                                        &event_tx,
                                        "scanner.thumbnailsFailed",
                                        ThumbnailsFailedPayload {
                                            code: "THUMBNAIL_DECODE_MISMATCH".to_string(),
                                            message: format!(
                                                "{dropped_count} bridge thumbnail event(s) failed to decode and were dropped"
                                            ),
                                            operation_id: operation_id.clone(),
                                        },
                                    );
                                }
                                emit(
                                    &event_tx,
                                    "scanner.thumbnailsComplete",
                                    ThumbnailsCompletePayload {
                                        count: received_count,
                                        operation_id: operation_id.clone(),
                                    },
                                );
                                backend_for_thread.emit_terminal_status_or_invalidate(
                                    session_epoch,
                                    bridge_generation,
                                    &event_tx,
                                    operation_id.clone(),
                                );
                                return;
                            }
                            "roll.previewError" => {
                                if !backend_for_thread.finalize_active_preview_terminal(
                                    preview_token,
                                    None,
                                    session_epoch,
                                    bridge_generation,
                                    HashMap::new(),
                                ) {
                                    backend_for_thread.close_lost_preview_reader(
                                        preview_token,
                                        session_epoch,
                                        bridge_generation,
                                        &event_tx,
                                        &operation_id,
                                        received_count,
                                    );
                                    return;
                                }
                                // Live-debugged 2026-07-23: CoolscanPy's
                                // frame detection RAISES (e.g. RollSessionError
                                // "no scanner-addressable slots") rather than
                                // returning an empty session; the bridge now
                                // forwards that as roll.previewError. Surface
                                // the real reason instead of a fake success.
                                let code = value
                                    .pointer("/payload/code")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("INTERNAL")
                                    .to_string();
                                let message = value
                                    .pointer("/payload/message")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("bridge preview failed")
                                    .to_string();
                                emit(
                                    &event_tx,
                                    "scanner.thumbnailsFailed",
                                    ThumbnailsFailedPayload {
                                        code: code.clone(),
                                        message,
                                        operation_id: operation_id.clone(),
                                    },
                                );
                                if code == "NOT_CONNECTED" {
                                    // Emit while the preview operation still
                                    // owns the UI lane; operation_id makes the
                                    // authoritative disconnect correlatable.
                                    backend_for_thread.invalidate_async_session(
                                        session_epoch,
                                        &event_tx,
                                        operation_id.clone(),
                                    );
                                }
                                emit(
                                    &event_tx,
                                    "scanner.thumbnailsComplete",
                                    ThumbnailsCompletePayload {
                                        count: received_count,
                                        operation_id: operation_id.clone(),
                                    },
                                );
                                if code != "NOT_CONNECTED" {
                                    backend_for_thread.emit_terminal_status_or_invalidate(
                                        session_epoch,
                                        bridge_generation,
                                        &event_tx,
                                        operation_id.clone(),
                                    );
                                }
                                return;
                            }
                            // Forward compatibility (PROTOCOL.md's own
                            // rule): ignore unknown event names.
                            _ => {}
                        }
                    }
                    Err(_) => {
                        // Silence while the bridge process is alive is the
                        // NORMAL shape of a blocking CoolscanPy preview
                        // (~60s+ with zero events) — keep waiting until the
                        // process dies or the hard deadline lapses.
                        let owns_session = backend_for_thread
                            .session_identity_is_current(session_epoch, bridge_generation);
                        if Instant::now() < silence_deadline && owns_session {
                            continue;
                        }
                        // A dead bridge or an exhausted deadline is a
                        // FAILURE, not an empty success: say so on the
                        // wire, then close the acquisition state with the
                        // count that truly arrived — closes 08-03-SUMMARY's
                        // flagged gap (a bridge-side roll.preview worker
                        // that can die mid-preview with no wire-level
                        // report).
                        if !owns_session {
                            backend_for_thread.close_lost_preview_reader(
                                preview_token,
                                session_epoch,
                                bridge_generation,
                                &event_tx,
                                &operation_id,
                                received_count,
                            );
                            return;
                        }
                        backend_for_thread.poison_preview_stream(
                            preview_token,
                            session_epoch,
                            bridge_generation,
                        );
                        let bridge_healthy = backend_for_thread.bridge.is_healthy();
                        let bridge_generation_current =
                            backend_for_thread.bridge.current_generation();
                        let connection_evidence = format!(
                            "sessionEpoch={session_epoch}; bridgeGenerationStart={bridge_generation}; bridgeGenerationCurrent={bridge_generation_current}; bridgeHealthy={bridge_healthy}"
                        );
                        emit(
                            &event_tx,
                            "scanner.thumbnailsFailed",
                            ThumbnailsFailedPayload {
                                code: "BRIDGE_STREAM_STALLED".to_string(),
                                message: format!(
                                    "bridge event stream stalled mid-preview (BRIDGE_STREAM_STALLED); {connection_evidence}; the predecessor stream is quarantined and its sole worker will discard the late terminal before disconnect and explicit reconnect are allowed"
                                ),
                                operation_id: operation_id.clone(),
                            },
                        );
                        emit(
                            &event_tx,
                            "scanner.thumbnailsComplete",
                            ThumbnailsCompletePayload {
                                count: received_count,
                                operation_id: operation_id.clone(),
                            },
                        );
                        // The bridge event channel is process-global and
                        // preview terminal events carry no request identity.
                        // Returning here would leave the predecessor's late
                        // terminal for a successor worker to consume. Keep
                        // this exact worker as the sole discard-only reader
                        // until it proves that terminal has crossed the wire.
                        loop {
                            if !backend_for_thread
                                .session_identity_is_current(session_epoch, bridge_generation)
                            {
                                backend_for_thread.invalidate_async_session(
                                    session_epoch,
                                    &event_tx,
                                    operation_id.clone(),
                                );
                                backend_for_thread.detach_lost_preview_reader(
                                    preview_token,
                                    session_epoch,
                                    bridge_generation,
                                );
                                return;
                            }
                            match backend_for_thread
                                .bridge
                                .recv_event(EVENT_STREAM_OWNERSHIP_RECHECK)
                            {
                                Ok(value) => {
                                    // Do not even classify a received value
                                    // until its process generation is still
                                    // the one this discard-only reader owns.
                                    if !backend_for_thread
                                        .session_identity_is_current(
                                            session_epoch,
                                            bridge_generation,
                                        )
                                    {
                                        backend_for_thread.invalidate_async_session(
                                            session_epoch,
                                            &event_tx,
                                            operation_id.clone(),
                                        );
                                        backend_for_thread.detach_lost_preview_reader(
                                            preview_token,
                                            session_epoch,
                                            bridge_generation,
                                        );
                                        return;
                                    }
                                    if matches!(
                                        value.get("event").and_then(|event| event.as_str()),
                                        Some("roll.previewComplete" | "roll.previewError")
                                    ) {
                                        if backend_for_thread
                                            .preview_terminal_generation_loss_test_hook
                                        {
                                            backend_for_thread.bridge.restart();
                                            backend_for_thread.invalidate_current_session();
                                        }
                                        if !backend_for_thread.finalize_poisoned_preview_terminal(
                                            preview_token,
                                            session_epoch,
                                            bridge_generation,
                                        ) {
                                            backend_for_thread.invalidate_async_session(
                                                session_epoch,
                                                &event_tx,
                                                operation_id.clone(),
                                            );
                                            backend_for_thread.detach_lost_preview_reader(
                                                preview_token,
                                                session_epoch,
                                                bridge_generation,
                                            );
                                        }
                                        return;
                                    }
                                    // Pre-terminal thumbnails and unknown
                                    // forward-compatible events are discarded:
                                    // the public operation already closed as
                                    // failed at the watchdog boundary.
                                }
                                Err(_) => {
                                    if !backend_for_thread.session_identity_is_current(
                                        session_epoch,
                                        bridge_generation,
                                    ) {
                                        backend_for_thread.invalidate_async_session(
                                            session_epoch,
                                            &event_tx,
                                            operation_id.clone(),
                                        );
                                        backend_for_thread.detach_lost_preview_reader(
                                            preview_token,
                                            session_epoch,
                                            bridge_generation,
                                        );
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        });

        // BRIDGE.md's roll.preview always reads the whole roll regardless
        // of a slots filter, and this phase does not yet know the real
        // slot count before roll.previewComplete arrives — echo the
        // caller's own requested frames back (or an empty vec if `None`
        // was requested), mirroring SimulatedLs5000's own
        // accepted-frames-returned-synchronously contract.
        Ok(frames.unwrap_or_default())
    }

    fn scan_start(
        backend: &Arc<Self>,
        frames: Vec<u32>,
        recipe: CaptureRecipe,
        processing: ProcessingRecipe,
        output: OutputRecipe,
        // Capture overrides are not yet mapped to the bridge protocol.
        // Processing/output overrides are applied to engine-side derivative
        // rendering after the bridge writes the real archive. Alignment is
        // already owned by the live bridge preview/driver session and is
        // retained here only as project/evidence provenance.
        overrides: std::collections::HashMap<u32, domain::FrameOverrides>,
        // Phase 11 (Real Batch Queue) owns receipt persistence for real
        // hardware scans. Accepted here only so this backend satisfies the
        // shared ScannerBackend trait; unused.
        project_directory: Option<std::path::PathBuf>,
        event_tx: mpsc::Sender<String>,
    ) -> Result<String, EngineError> {
        let (session_epoch, bridge_generation) = backend.active_session_identity()?;
        backend.ensure_preview_stream_allows_scan(session_epoch, bridge_generation)?;
        let processing = processing.effective();
        let recipe = recipe.effective_for_process(processing.film_process);
        // Device-sourced, model-agnostic (see
        // derive_supported_multisample_passes): the real device's
        // `multiSample: false` capability means "no *variable* multi-
        // sample control exposed by the transport", never "cannot
        // multisample" — the LS-5000 always can, it's a hallmark feature.
        // The rejection names the field and states the real reason (fixed
        // by hardware capability), so the engine/UI never sees a false
        // "multisampling unsupported" claim.
        if !backend
            .supported_multisample_passes
            .contains(&recipe.multisample_passes)
        {
            return Err(EngineError::new(
                ErrorCode::InvalidParams,
                format!(
                    "multisamplePasses must be one of {:?} for this device (fixed by hardware capability, not a multisampling limitation)",
                    backend.supported_multisample_passes
                ),
            ));
        }

        let capture_plan = build_real_capture_plan(&frames, &output, &overrides)?;
        let bridge_params = build_scan_start_params_with_bridge_output(
            frames.clone(),
            &recipe,
            &processing,
            capture_plan.bridge_output.clone(),
        );
        let params_value = serde_json::to_value(&bridge_params)
            .expect("serializing BridgeScanStartParams cannot fail");

        let job_id = match backend.call_session_scoped_detailed(
            session_epoch,
            bridge_generation,
            "scan.start",
            params_value,
        ) {
            Ok(value) => decode_scan_start_job_id(value)?,
            // A clean rejection (INVALID_PARAMS, NOT_CONNECTED, etc.) —
            // the bridge itself is fine, it just refused this request.
            // Return early, exactly like every other synchronous
            // validation failure.
            Err(SessionCallError::BridgeRejected(mut engine_error)) => {
                if let Some(working) = capture_plan.private_working_directory.as_ref() {
                    engine_error.message = format!(
                        "{}; {}",
                        engine_error.message,
                        working.recovery_message(
                            "bridge rejected scan.start; workspace was preserved without cleanup",
                        )
                    );
                }
                return Err(engine_error);
            }
            // Timeout / ProcessExited / Io means that the bridge process
            // which owned the physical device has been lost or restarted.
            // A replacement process has neither an open Device nor the
            // preview/session state that made this motion request safe, so
            // fail closed: never retry scan.start after this boundary.
            Err(SessionCallError::OwnershipLost(ownership_error)) => {
                let mut message = format!(
                    "bridge session was lost before scan.start; reconnect required; motion request was not retried: {}",
                    ownership_error.message
                );
                if let Some(working) = capture_plan.private_working_directory.as_ref() {
                    message.push_str("; ");
                    message.push_str(&working.recovery_message(
                        "bridge start lost its response or closed before terminal confirmation",
                    ));
                }
                emit(
                    &event_tx,
                    "scan.frameState",
                    FrameStatePayload {
                        job_id: String::new(),
                        frame_index: *frames.first().unwrap_or(&0),
                        state: FrameState::Failed,
                        attempt: 1,
                        error: Some(ErrorPayload {
                            code: ErrorCode::NotConnected,
                            message: message.clone(),
                            recoverable: false,
                        }),
                    },
                );
                return Err(EngineError::new(ErrorCode::NotConnected, message));
            }
        };
        let backend_for_thread = Arc::clone(backend);
        let thread_job_id = job_id.clone();
        let thread_project_directory = project_directory.clone();
        thread::spawn(move || {
            run_real_scan_job(
                backend_for_thread,
                thread_job_id,
                frames,
                recipe,
                processing,
                output,
                overrides,
                capture_plan,
                thread_project_directory,
                event_tx,
                session_epoch,
                bridge_generation,
            );
        });

        Ok(job_id)
    }

    fn scan_stop(
        &self,
        job_id: &str,
        _mode: StopMode,
        _event_tx: mpsc::Sender<String>,
    ) -> Result<(bool, StopMode), EngineError> {
        let (session_epoch, bridge_generation) = self.active_session_identity()?;
        let result_value = self.call_session_scoped(
            session_epoch,
            bridge_generation,
            "scan.stop",
            serde_json::json!({ "jobId": job_id }),
        )?;
        let result: BridgeScanStopResult =
            serde_json::from_value(result_value).map_err(|err| {
                EngineError::new(
                    ErrorCode::Internal,
                    format!("malformed scan.stop result: {err}"),
                )
            })?;
        // BRIDGE.md: "scan.stop has no mode — no safe immediate abort
        // exists against real hardware" — the result always reports
        // AfterCurrentFrame, regardless of what the caller requested.
        Ok((result.acknowledged, StopMode::AfterCurrentFrame))
    }

    fn shutdown(&self) {
        // Best-effort, mirrors SimulatedLs5000::shutdown's never-block
        // contract. BridgeClient's own Drop impl (Plan 09-02) is the real
        // safety net if this call fails or hangs.
        let _ = self.bridge.call("bridge.shutdown", serde_json::json!({}));
    }
}

/// Maps a `BridgeCallError` (Plan 09-02's transport-level error vocabulary)
/// onto `domain::EngineError`. PROTOCOL.md's `ErrorCode` enum is a closed,
/// Swift-decoded wire vocabulary: bridge codes with an exact application
/// meaning map explicitly; every other bridge code becomes `Internal`, never
/// silently dropped and always with the real code/message in the text.
fn map_bridge_error(err: BridgeCallError) -> EngineError {
    match err {
        BridgeCallError::Timeout | BridgeCallError::ProcessExited => EngineError::new(
            ErrorCode::Internal,
            format!("bridge connection lost or unresponsive: {err}"),
        ),
        BridgeCallError::Io(ref msg) => {
            EngineError::new(ErrorCode::Internal, format!("bridge process error: {msg}"))
        }
        BridgeCallError::BridgeError {
            ref code,
            ref message,
            ..
        } => {
            let mapped = map_bridge_error_code_str(code);
            EngineError::new(mapped, format!("bridge error {code}: {message}"))
                .with_recoverable(map_bridge_error_code_recoverable(code))
        }
    }
}

/// Maps a raw bridge error-code wire string onto PROTOCOL.md's closed
/// `ErrorCode` vocabulary — factored out of `map_bridge_error` (10-08) so
/// every call site that receives a bridge code as plain text (a
/// `BridgeCallError::BridgeError`'s own `code`, `scan.error`'s `code`,
/// `hardware.anomaly`'s `code`) shares exactly one mapping table. Same
/// "never silently drop, always Internal with the real code in the
/// message text" policy as `map_bridge_error`'s own doc comment.
fn map_bridge_error_code_str(code: &str) -> ErrorCode {
    match code {
        "INVALID_PARAMS" => ErrorCode::InvalidParams,
        "NOT_CONNECTED" => ErrorCode::NotConnected,
        "ALREADY_CONNECTED" => ErrorCode::AlreadyConnected,
        "DEVICE_NOT_FOUND" => ErrorCode::UnknownDevice,
        "DEVICE_BUSY" => ErrorCode::ScannerBusy,
        "HARDWARE_LANE_BUSY" => ErrorCode::ScannerBusy,
        "MANUAL_REVIEW_REQUIRED" => ErrorCode::ManualReviewRequired,
        "FILM_FEED_INTERRUPTED" => ErrorCode::FilmFeedInterrupted,
        "HW_MOTION_NOT_ARMED" => ErrorCode::HwMotionNotArmed,
        "UNKNOWN_JOB" => ErrorCode::UnknownJob,
        _ => ErrorCode::Internal,
    }
}

/// Shares BRIDGE.md's own recoverable policy — `true` only for
/// `HARDWARE_LANE_BUSY` — with every call site that receives a bridge code
/// as plain text. Every other code needs a different action first, so they
/// are always `false`. This is intentionally code-string-based, not a
/// trust-the-wire-bool policy, so the three async event arms (`scan.error`,
/// `hardware.anomaly`, `scan.frameFailed`) and the synchronous RPC error
/// path all share exactly one source of truth.
fn map_bridge_error_code_recoverable(code: &str) -> bool {
    code == "HARDWARE_LANE_BUSY"
}

/// A holder classification derived only from BRIDGE.md's mechanical
/// `adapterFrameCapacity` capability, never from preview `slotCount`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DetectedHolder {
    adapter: &'static str,
    carrier: MediaCarrier,
}

/// Classifies the supported LS-5000 holder family from the SANE/CoolscanPy
/// mechanical adapter bound. Capacity is not an exposure count: 1 denotes
/// the MA-21 mounted holder; 2...6 and 7...40 additionally require active
/// roll-adapter frame control before they can identify SA-21 or SA-30.
/// CoolscanPy's mounted-holder path explicitly omits the roll-adapter frame
/// argument, so MA-21 intentionally does not require frame control.
///
/// Any missing, zero, out-of-family, or frame-control-inconsistent value is
/// unknown. The caller must not invent a holder from `slotCount` or from a
/// missing capability.
fn derive_detected_holder(capabilities: &BridgeCapabilities) -> Option<DetectedHolder> {
    match capabilities.adapter_frame_capacity {
        Some(1) => Some(DetectedHolder {
            adapter: "MA-21",
            carrier: MediaCarrier::Mounted,
        }),
        Some(2..=6) if capabilities.adapter_frame_control => Some(DetectedHolder {
            adapter: "SA-21",
            carrier: MediaCarrier::Strip6,
        }),
        Some(7..=40) if capabilities.adapter_frame_control => Some(DetectedHolder {
            adapter: "SA-30",
            carrier: MediaCarrier::Roll36,
        }),
        _ => None,
    }
}

/// Accepts a bridge preview count only after the bridge itself has established
/// a preview. A known holder adds a tighter mechanical consistency check; an
/// unknown holder must not erase an otherwise valid completed preview. The
/// count is never used to infer a holder or carrier: it is only the number of
/// scanner-addressable frames the successful preview actually returned.
fn preview_frame_count_for_holder(
    preview_established: bool,
    slot_count: Option<u32>,
    holder: Option<DetectedHolder>,
) -> Option<u32> {
    let slot_count = preview_established.then_some(slot_count).flatten()?;
    match holder.map(|known| known.carrier) {
        Some(MediaCarrier::Mounted) if slot_count == 1 => Some(slot_count),
        Some(MediaCarrier::Strip6) if (1..=6).contains(&slot_count) => Some(slot_count),
        Some(MediaCarrier::Roll36) if (1..=40).contains(&slot_count) => Some(slot_count),
        Some(_) => None,
        // BRIDGE.md limits the LS-5000 family's scanner-addressable preview
        // table to forty slots. `slotCount` here is from a successful
        // roll.preview, not holder capacity, so it is enough to retain the
        // real thumbnails and let the UI ask for holder confirmation later.
        None if (1..=40).contains(&slot_count) => Some(slot_count),
        None => None,
    }
}

/// Maps BRIDGE.md's `DeviceStatus` onto PROTOCOL.md's `ScannerStatus`,
/// overlaying the previously authoritative `DeviceInfo.capabilities`
/// classification. A disconnected status never advertises a cached holder,
/// and `media_loaded` remains the bridge's `preview_established` signal.
fn map_status(
    bridge: &BridgeDeviceStatus,
    detected_holder: Option<DetectedHolder>,
) -> ScannerStatus {
    let detected_holder = bridge.connected.then_some(detected_holder).flatten();
    ScannerStatus {
        connected: bridge.connected,
        adapter: detected_holder.map(|holder| holder.adapter.to_string()),
        media_loaded: bridge.preview_established,
        carrier: detected_holder.map(|holder| holder.carrier),
        // `slotCount` becomes an actual film-frame count only after the
        // bridge established a successful preview. Mechanical holder
        // capacity is carried separately in `detected_holder` and must never
        // manufacture scan targets before that preview.
        frame_count: preview_frame_count_for_holder(
            bridge.preview_established,
            bridge.slot_count,
            detected_holder,
        ),
        lamp: if bridge.connected {
            Lamp::Stable
        } else {
            Lamp::Off
        },
        transport: if bridge.lane_held {
            Transport::Locked
        } else if bridge.active_job_id.is_some() {
            Transport::Busy
        } else {
            Transport::Idle
        },
        active_job_id: bridge.active_job_id.clone(),
        motion_armed: Some(bridge.motion_armed),
        film_present: bridge.film_present,
    }
}

/// Derives the device's accepted `CaptureRecipe.multisamplePasses` values.
///
/// Model-agnostic by construction. BRIDGE.md's `Capabilities.multiSample`
/// is a bool today meaning "is *variable* multi-sample control exposed by
/// the transport" — NOT "can this device multisample" (the LS-5000 always
/// can; it's a hallmark feature). The real device reports `multiSample:
/// false` because variable control isn't exposed over this wire — every
/// wired colorNegative capture is fixed at `multisamplePasses: 4` by
/// BRIDGE.md's own "Recipe constraints" contract. MockTransport (used only
/// by the bridge's own test suite, distinct from this crate's
/// `mock_bridge` binary) reports `multiSample: true` on its permissive
/// test path — that `true` is a mock/real divergence and must never be
/// read as real-hardware semantics.
///
/// BRIDGE.md's wire `Capabilities` struct now carries
/// `supportedMultisamplePasses` for real (Phase 10) — this IS that one-line
/// change, now landed: the accepted set is read directly from the device's
/// own wire field rather than a fixed-contract fallback, with zero changes
/// to the validation code that reads `RealLs5000::supported_multisample_passes`.
fn derive_supported_multisample_passes(capabilities: &BridgeCapabilities) -> Vec<u32> {
    capabilities.supported_multisample_passes.clone()
}

/// BRIDGE.md's `roll.preview` only distinguishes two material buckets;
/// `Positive` and `Kodachrome` are approximated onto `colorNegative` (both
/// are chemically non-B&W) since the bridge has no finer-grained bucket —
/// a deliberate, documented approximation, not an oversight.
fn map_material(process: FilmProcess) -> BridgeMaterial {
    match process {
        FilmProcess::BwNegative => BridgeMaterial::BlackAndWhiteNegative,
        FilmProcess::Positive | FilmProcess::C41ColorNegative | FilmProcess::Kodachrome => {
            BridgeMaterial::ColorNegative
        }
    }
}

fn map_channels(channels: Channels) -> BridgeChannels {
    match channels {
        Channels::Rgb => BridgeChannels::Rgb,
        Channels::Rgbi => BridgeChannels::Rgbi,
    }
}

/// Mirrors `sim.rs`'s own private `channels_str` (not reusable across
/// modules since it isn't `pub`) — kept in sync manually; both encode the
/// same "rgb"/"rgbi" wire strings used by `domain::ScanReceipt.channels`.
fn channels_str(channels: Channels) -> &'static str {
    match channels {
        Channels::Rgb => "rgb",
        Channels::Rgbi => "rgbi",
    }
}

/// Builds BRIDGE.md's `scan.start` params from the engine's own recipe
/// vocabulary. Shared by `scan_start`'s initial call and
/// `run_real_scan_job`'s crash-retry call, so the field mapping lives in
/// exactly one place.
#[cfg(test)]
fn build_scan_start_params(
    slots: Vec<u32>,
    recipe: &CaptureRecipe,
    processing: &ProcessingRecipe,
    output: &OutputRecipe,
    slot_outputs: Option<std::collections::HashMap<String, BridgeSlotOutputSpec>>,
) -> BridgeScanStartParams {
    build_scan_start_params_with_bridge_output(
        slots,
        recipe,
        processing,
        BridgeOutputSpec {
            destination: output.archive.destination.clone(),
            filename_template: bridge_archive_template(&output.archive.filename_template),
            slot_outputs,
        },
    )
}

fn build_scan_start_params_with_bridge_output(
    slots: Vec<u32>,
    recipe: &CaptureRecipe,
    processing: &ProcessingRecipe,
    bridge_output: BridgeOutputSpec,
) -> BridgeScanStartParams {
    BridgeScanStartParams {
        slots,
        recipe: BridgeCaptureRecipe {
            resolution_dpi: recipe.resolution_dpi,
            bit_depth: recipe.bit_depth,
            multisample_passes: recipe.multisample_passes,
            channels: map_channels(recipe.channels),
            autofocus: processing.autofocus_each_frame,
            auto_exposure: processing.auto_exposure_each_frame,
        },
        // The bridge always writes one full-fidelity TIFF capture per slot.
        // The supplied plan is either the retained master route or a
        // private engine-owned working route for derivative-only scans;
        // derivatives remain engine-rendered and have no bridge equivalent.
        output: bridge_output,
    }
}

#[cfg(test)]
fn bridge_slot_outputs(
    slots: &[u32],
    output: &OutputRecipe,
    overrides: &std::collections::HashMap<u32, domain::FrameOverrides>,
) -> Option<std::collections::HashMap<String, BridgeSlotOutputSpec>> {
    let base_template = bridge_archive_template(&output.archive.filename_template);
    let base_destination = output.archive.destination.clone();
    let mut differs = false;
    let templates = slots
        .iter()
        .map(|slot| {
            let override_output = overrides.get(slot).and_then(|value| value.output.as_ref());
            let template = override_output
                .map(|value| bridge_archive_template(&value.archive.filename_template))
                .unwrap_or_else(|| base_template.clone());
            let destination = override_output
                .map(|value| value.archive.destination.clone())
                .unwrap_or_else(|| base_destination.clone());
            differs |= template != base_template || destination != base_destination;
            (
                slot.to_string(),
                BridgeSlotOutputSpec {
                    destination,
                    filename_template: template,
                },
            )
        })
        .collect();
    differs.then_some(templates)
}

fn effective_output_for_slot<'a>(
    slot: u32,
    output: &'a OutputRecipe,
    overrides: &'a std::collections::HashMap<u32, domain::FrameOverrides>,
) -> &'a OutputRecipe {
    overrides
        .get(&slot)
        .and_then(|value| value.output.as_ref())
        .unwrap_or(output)
}

/// Plans the bridge's mandatory RGB/IR/meter capture locations independently
/// from user-retained outputs. For archive-off frames every bridge write is
/// routed into one newly-created, job-private directory with private names;
/// user output folders never receive an intermediate TIFF or sidecar.
fn build_real_capture_plan(
    slots: &[u32],
    output: &OutputRecipe,
    overrides: &std::collections::HashMap<u32, domain::FrameOverrides>,
) -> Result<RealCapturePlan, EngineError> {
    let private_slots: std::collections::HashSet<u32> = slots
        .iter()
        .copied()
        .filter(|slot| !effective_output_for_slot(*slot, output, overrides).archive.enabled)
        .collect();
    let private_working_directory = (!private_slots.is_empty())
        .then(PrivateCaptureWorkingDirectory::create)
        .transpose()?;

    let base_output = effective_output_for_slot(*slots.first().unwrap_or(&0), output, overrides);
    let base_spec = if base_output.archive.enabled {
        BridgeSlotOutputSpec {
            destination: base_output.archive.destination.clone(),
            filename_template: bridge_archive_template(&base_output.archive.filename_template),
        }
    } else {
        let working = private_working_directory.as_ref().expect("private slot has working directory");
        BridgeSlotOutputSpec {
            destination: working.root.display().to_string(),
            filename_template: format!("capture-{}-####.tif", working.owner_token),
        }
    };

    let mut expected_by_slot = HashMap::new();
    let mut slot_outputs = HashMap::new();
    let mut differs_from_base = false;
    for slot in slots {
        let effective = effective_output_for_slot(*slot, output, overrides);
        let spec = if effective.archive.enabled {
            BridgeSlotOutputSpec {
                destination: effective.archive.destination.clone(),
                filename_template: bridge_archive_template(&effective.archive.filename_template),
            }
        } else {
            let working = private_working_directory.as_ref().expect("private slot has working directory");
            BridgeSlotOutputSpec {
                destination: working.root.display().to_string(),
                filename_template: format!("capture-{}-####.tif", working.owner_token),
            }
        };
        differs_from_base |= spec != base_spec;
        let rgb = std::path::Path::new(&spec.destination)
            .join(crate::render::resolve_filename(&spec.filename_template, *slot));
        // Force the sidecar derivation to validate the private base name
        // while receipt validation below derives the same exact paths.
        let _ = crate::render::archive_sidecar_path(&rgb, "IR")?;
        let _ = crate::render::archive_sidecar_path(&rgb, "METER")?;
        expected_by_slot.insert(*slot, ExpectedCapturePaths { rgb });
        slot_outputs.insert(slot.to_string(), spec);
    }

    // A private route always sends a complete per-slot plan, even when all
    // private slots share a root/template. This leaves no bridge-side
    // fallback that could accidentally use a user archive destination.
    let use_slot_outputs = private_working_directory.is_some() || differs_from_base;
    Ok(RealCapturePlan {
        bridge_output: BridgeOutputSpec {
            destination: base_spec.destination,
            filename_template: base_spec.filename_template,
            slot_outputs: use_slot_outputs.then_some(slot_outputs),
        },
        expected_by_slot,
        private_working_directory,
        private_slots,
    })
}

/// Applies the same TIFF extension policy used by preflight, simulator
/// writes, receipt validation, and derivative rendering before the archive
/// template crosses the independent bridge protocol boundary.
fn ensure_archive_extension(filename_template: &str) -> String {
    crate::render::normalize_output_filename_template(
        filename_template,
        domain::OutputFileFormat::Tiff,
    )
}

/// Converts the engine's implicit no-marker fallback into an explicit wire
/// marker. The bridge protocol has always documented `####` substitution,
/// so sending the marker keeps legacy and current bridge builds on the same
/// four-digit path the engine reserves and later validates from the receipt.
fn bridge_archive_template(filename_template: &str) -> String {
    let normalized = ensure_archive_extension(filename_template);
    if normalized.contains('#') || crate::render::is_reserved_sequence_template(&normalized) {
        return normalized;
    }
    let extension_start = normalized
        .rfind('.')
        .expect("TIFF normalization always supplies a terminal extension");
    format!(
        "{}_####{}",
        &normalized[..extension_start],
        &normalized[extension_start..]
    )
}

/// Decodes a successful `scan.start` response into just the `jobId` the
/// rest of `RealLs5000::scan_start` needs — shared by the initiating call
/// and its one crash-retry.
fn decode_scan_start_job_id(value: serde_json::Value) -> Result<String, EngineError> {
    serde_json::from_value::<BridgeScanStartResult>(value)
        .map(|result| result.job_id)
        .map_err(|err| {
            EngineError::new(
                ErrorCode::Internal,
                format!("malformed scan.start result: {err}"),
            )
        })
}

/// Mirrors `bridge_protocol::BridgeExposureVector` field-for-field into
/// `domain::ExposureVector` — no logic, every field name and type matches
/// exactly between the `Bridge`-prefixed and unprefixed pairs.
fn map_exposure_vector(exposure: &BridgeExposureVector) -> domain::ExposureVector {
    domain::ExposureVector {
        focus_position: exposure.focus_position,
        exposure_multiplier: exposure.exposure_multiplier,
        red_exposure_us: exposure.red_exposure_us,
        green_exposure_us: exposure.green_exposure_us,
        blue_exposure_us: exposure.blue_exposure_us,
    }
}

/// Gates nikonlook v2's optional hardware-exposure path (see
/// `processing::nikonlook::estimate_gains`'s `LayerA::V2` branch). Default
/// off: measured 2026-07-28 on a live frame, the blind fallback's median
/// |Delta| vs the registered Nikon Scan reference was [3565, 6682, 3340] DN
/// per channel vs [9560, 8064, 3454] DN for the exposure path, and the
/// exposure anchor is "experimental-one-frame" per the v2 bundle manifest —
/// so production stays on the blind path until a validation roll lands. Set
/// SCANSTUDIO_NIKONLOOK_EXPOSURE_META=1 (or "true") to opt in.
fn nikonlook_exposure_meta_enabled() -> bool {
    matches!(
        std::env::var("SCANSTUDIO_NIKONLOOK_EXPOSURE_META").as_deref(),
        Ok("1") | Ok("true")
    )
}

/// Builds nikonlook v2's `exposure_10ns` argument from the bridge receipt's
/// own exposure telemetry (µs -> 10ns ticks, RGB order), gated by
/// `nikonlook_exposure_meta_enabled`. `None` whenever the gate is off, or
/// whenever any of the three channels isn't a finite positive value —
/// `estimate_gains`'s exposure path only trusts a value that passes
/// `processing::nikonlook::exposure_is_usable` (finite and > 0 on every
/// channel), routing anything else to its blind fallback instead of
/// asserting or erroring (see that function's own doc comment), so a
/// partially-populated or degenerate receipt is caught here too rather than
/// relying solely on that downstream fallback.
fn nikonlook_exposure_10ns_from_receipt(exposure: &BridgeExposureVector) -> Option<[f64; 3]> {
    if !nikonlook_exposure_meta_enabled() {
        return None;
    }
    let (r, g, b) = (
        exposure.red_exposure_us,
        exposure.green_exposure_us,
        exposure.blue_exposure_us,
    );
    let finite_positive = |value: f64| value.is_finite() && value > 0.0;
    if finite_positive(r) && finite_positive(g) && finite_positive(b) {
        Some([r * 100.0, g * 100.0, b * 100.0])
    } else {
        None
    }
}

/// Mirrors `bridge_protocol::BridgeClippingTelemetry` field-for-field.
fn map_clipping_telemetry(clipping: &BridgeClippingTelemetry) -> domain::ClippingTelemetry {
    domain::ClippingTelemetry {
        fractions: clipping.fractions,
        clip_level: clipping.clip_level,
        warning_fraction: clipping.warning_fraction,
        warning: clipping.warning,
    }
}

/// Mirrors `bridge_protocol::BridgeFocusDetailTelemetry` field-for-field.
fn map_focus_detail_telemetry(
    focus_detail: &BridgeFocusDetailTelemetry,
) -> domain::FocusDetailTelemetry {
    domain::FocusDetailTelemetry {
        method: focus_detail.method.clone(),
        verdict: focus_detail.verdict.clone(),
        score: focus_detail.score,
        texture_span: focus_detail.texture_span,
    }
}

/// Mirrors `bridge_protocol::BridgeTransportSmearAssessment` field-for-field.
fn map_transport_smear_assessment(
    transport_smear: &BridgeTransportSmearAssessment,
) -> domain::TransportSmearAssessment {
    domain::TransportSmearAssessment {
        verdict: transport_smear.verdict.clone(),
        start_row: transport_smear.start_row,
        suffix_rows: transport_smear.suffix_rows,
        minimum_matches: transport_smear.minimum_matches,
        tail_median_rms: transport_smear.tail_median_rms,
        tail_min_corr: transport_smear.tail_min_corr,
        pre_tail_median_rms: transport_smear.pre_tail_median_rms,
        texture_span: transport_smear.texture_span,
        reason: transport_smear.reason.clone(),
    }
}

/// Mirrors `bridge_protocol::BridgeExposureAuthority` field-for-field.
fn map_exposure_authority(authority: &BridgeExposureAuthority) -> domain::ExposureAuthority {
    domain::ExposureAuthority {
        rgb_source: authority.rgb_source.clone(),
        ir_source: authority.ir_source.clone(),
        commanded_channels_raw_10ns: authority.commanded_channels_raw_10ns.clone(),
        active_controller_channels_raw_10ns: authority
            .active_controller_channels_raw_10ns
            .clone(),
        device_bound_clamped_channels_raw_10ns: authority
            .device_bound_clamped_channels_raw_10ns
            .clone(),
        device_exposure_bounds_raw_10ns: authority.device_exposure_bounds_raw_10ns,
    }
}

/// Builds the engine's `ScanReceipt` for a completed real-backend frame.
/// `duration_ms`/`started_at` are documented approximations: BRIDGE.md's
/// `ScanReceipt` carries neither a timestamp nor a duration field at all.
/// `started_at` is approximated as receipt-arrival time; `duration_ms: 0`
/// is an honest "not available", never a fabricated number — no bridge
/// field exists to source either from. BRIDGE.md's rich exposure/clipping/
/// focus/transport-smear telemetry, plus the rgb/ir/meter capture-file
/// paths, now flow onto `hardware_telemetry`/`rgb_path`/`ir_path`/
/// `meter_rgbi_path` (Phase 10) — superseding the stderr-only diagnostic
/// dump this used to be the caller's only option.
fn build_real_receipt(
    job_id: &str,
    slot: u32,
    recipe: &CaptureRecipe,
    processing: &ProcessingRecipe,
    output: &OutputRecipe,
    bridge_receipt: &BridgeScanReceipt,
) -> domain::ScanReceipt {
    let now_unix_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    domain::ScanReceipt {
        exposure_authority: bridge_receipt
            .exposure_authority
            .as_ref()
            .map(map_exposure_authority),
        auto_crop: None,
        job_id: job_id.to_string(),
        frame_index: slot,
        started_at: crate::sim::format_iso8601(now_unix_secs),
        duration_ms: 0,
        passes: recipe.multisample_passes,
        resolution_dpi: bridge_receipt.dpi,
        bit_depth: bridge_receipt.depth,
        channels: channels_str(recipe.channels).to_string(),
        engine_version: env!("CARGO_PKG_VERSION").to_string(),
        device_id: bridge_receipt.device_id.clone(),
        simulated: false,
        settings_fingerprint: crate::sim::settings_fingerprint(recipe),
        processing: Some(processing.clone()),
        output: Some(crate::render::receipt_output_recipe(output)),
        // No real file-writing exists yet in this plan's scope — Plan
        // 03-02 owns rendering/writing and populating this field with the
        // paths it actually wrote.
        outputs: None,
        // Bridge-written capture-file locations (hardware side) —
        // BridgeScanReceipt.rgb_path is non-optional, ir_path/
        // meter_rgbi_path already are Option<String>, matching the target
        // fields' own optionality exactly.
        rgb_path: Some(bridge_receipt.rgb_path.clone()),
        ir_path: bridge_receipt.ir_path.clone(),
        storage_transform: Some(bridge_receipt.storage_transform.clone()),
        meter_rgbi_path: bridge_receipt.meter_rgbi_path.clone(),
        hardware_telemetry: Some(domain::HardwareTelemetry {
            exposure: map_exposure_vector(&bridge_receipt.exposure),
            clipping: map_clipping_telemetry(&bridge_receipt.clipping),
            focus_detail: map_focus_detail_telemetry(&bridge_receipt.focus_detail),
            transport_smear: map_transport_smear_assessment(&bridge_receipt.transport_smear),
        }),
        // Derivative rendering (and thus nikonlook) hasn't run yet at this
        // point -- mirrors `outputs: None` above. Patched in alongside
        // `outputs` once `render_derivative_from_archive_with_processing`
        // actually completes, from its own `WrittenPaths.nikonlook`.
        nikonlook: None,
    }
}

/// Mirrors `sim.rs`'s own private `emit` helper exactly (copied, not
/// imported — it isn't `pub` and lives in a different module).
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

/// Scan-path mirror of `acquire_thumbnails`'s own silence-tolerant
/// `STREAM_SILENCE_DEADLINE` — a separate, env-tunable knob
/// (`SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS`) so an out-of-process test
/// harness can drive a short deadline without touching the shared preview
/// constant. Read exactly once per `RealLs5000` construction and stored on
/// the backend (`RealLs5000::scan_silence_deadline`); in-process tests
/// override it per instance via `RealLs5000::with_scan_silence_deadline`
/// rather than by mutating this process-global variable, which would leak
/// into concurrently-running tests that expect the default. Unset or
/// unparseable falls back to `STREAM_SILENCE_DEADLINE` (600s), the same
/// default the preview path already uses.
fn scan_silence_deadline_from_env() -> Duration {
    std::env::var("SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(STREAM_SILENCE_DEADLINE)
}

/// Computes a passive duty-cycle report from observed frame-to-frame idle
/// gaps. Returns `None` when no transitions were observed — a one-frame job
/// or a job that failed before frame 2 ever started has nothing honest to
/// report. This is instrumentation only: it measures and reports, never
/// judges or gates.
fn compute_duty_cycle_report(samples: &[FrameIdleSample]) -> Option<DutyCycleReport> {
    if samples.is_empty() {
        return None;
    }
    let max_idle_ms = samples.iter().map(|s| s.idle_ms).max().unwrap_or(0);
    let mean_idle_ms =
        samples.iter().map(|s| s.idle_ms as f64).sum::<f64>() / samples.len() as f64;
    Some(DutyCycleReport {
        per_frame_idle_ms: samples.to_vec(),
        mean_idle_ms,
        max_idle_ms,
    })
}

/// The 1-based ordinal of whichever frame is now actually active in this
/// job: one more than the count of frames already resolved (completed or
/// failed), capped at `total_frames` once every frame is resolved. This is
/// the ONLY correct source for the client-facing "Frame N of M" ordinal —
/// deliberately never `BridgeScanProgress::ordinal`/`total_slots`.
///
/// Root cause (live 2026-07-25): `CoolscanPyTransport.start_scan`
/// (scanstudio-bridge's `coolscanpy_transport.py`) emits every
/// `scan.progress` for a batch in ONE upfront pass — naming every
/// requested slot with an `ordinal`/`total_slots` pair — before
/// `scan_many()` ever begins moving hardware, and never emits another
/// `scan.progress` for the rest of the job. The engine used to forward
/// that burst's `ordinal`/`total_slots` directly as `frame_ordinal`/
/// `total_frames`, so the value the client ended up displaying was
/// whatever the LAST burst message said — this batch's LAST requested
/// slot — frozen there for the rest of the job no matter which frame
/// was actually in flight. Observed live: a 34-frame batch (slots 5-38)
/// showed "Frame 37 of 38" (the burst's last slot, 38, minus one) while
/// the scanner was physically on slot 17, the batch's 13th frame, per
/// the worker's own session-journal `active_frame_index`. This function
/// is instead called after every point `completed`/`failed` actually
/// change (see `run_real_scan_job_inner`'s `emit_frame_progress`), so
/// the ordinal it returns tracks frames actually started/completed.
fn compute_frame_ordinal(completed: &[u32], failed: &[u32], total_frames: u32) -> u32 {
    let resolved = (completed.len() + failed.len()) as u32;
    (resolved + 1).min(total_frames.max(1))
}

fn reconcile_derivative_failures(
    mut completed: Vec<u32>,
    mut failed: Vec<u32>,
    derivative_failed: &[u32],
) -> (Vec<u32>, Vec<u32>) {
    completed.retain(|slot| !derivative_failed.contains(slot));
    for slot in derivative_failed {
        if !failed.contains(slot) {
            failed.push(*slot);
        }
    }
    (completed, failed)
}

/// Marks every requested-but-not-yet-completed frame Failed and emits a
/// single terminal `scan.jobState{Failed}` + `scan.completed` — the exact
/// shape `run_real_scan_job`'s own silence watchdog (below) has always
/// emitted when the bridge goes silent past its deadline. Factored out so a
/// bridge-reported `scan.error` gets an equally honest, identically-shaped
/// terminal report instead of the old silent drop — both callers share
/// exactly one "how do we tell the client the job died" implementation.
/// `remaining` is drained into `failed` (mirrors the pre-10-08 inline code
/// exactly); `completed` is read-only here since a frame already reported
/// `scan.frameCompleted` must never be re-labeled.
fn emit_terminal_job_failure(
    event_tx: &mpsc::Sender<String>,
    job_id: &str,
    remaining: &mut Vec<u32>,
    completed: &[u32],
    failed: &mut Vec<u32>,
    error_payload: &ErrorPayload,
    duty_cycle: Option<DutyCycleReport>,
    evidence_package_status: Option<String>,
) {
    for &frame in remaining.iter() {
        emit(
            event_tx,
            "scan.frameState",
            FrameStatePayload {
                job_id: job_id.to_string(),
                frame_index: frame,
                state: FrameState::Failed,
                attempt: 1,
                error: Some(error_payload.clone()),
            },
        );
    }
    failed.append(remaining);
    emit(
        event_tx,
        "scan.jobState",
        JobStatePayload {
            job_id: job_id.to_string(),
            state: JobState::Failed,
        },
    );
    emit(
        event_tx,
        "scan.completed",
        ScanCompletedPayload {
            job_id: job_id.to_string(),
            summary: ScanSummary {
                completed: completed.to_vec(),
                failed: failed.clone(),
                skipped: vec![],
                stopped: false,
                duty_cycle,
                evidence_package_status,
            },
        },
    );
}

/// `terminal_error` names the reason the bridge's own terminal closure
/// happened to be a failure (`scan.error`'s code+message) rather than a
/// clean `scan.completed` -- `None` for the ordinary success path. Threaded
/// straight into `evidence_package::finalize`, which folds it into the
/// written package's own `detail`/`status` -- without it, a package
/// finalized after a `scan.error` recorded every attempted frame's own
/// outcome but never *why the job itself* stopped, leaving that reason
/// nowhere but engine stderr once this process exits.
fn finalize_evidence_status_after_bridge_terminal(
    output: &OutputRecipe,
    overrides: &std::collections::HashMap<u32, domain::FrameOverrides>,
    capture_plan: &RealCapturePlan,
    job_id: &str,
    evidence: &Arc<Mutex<Vec<crate::evidence_package::EvidenceFrame>>>,
    settings: &serde_json::Value,
    terminal_error: Option<&str>,
) -> EvidenceFinalization {
    let mut requested_destinations = std::collections::BTreeMap::<String, Vec<u32>>::new();
    for slot in capture_plan.expected_by_slot.keys() {
        let effective = effective_output_for_slot(*slot, output, overrides);
        if effective.archive.enabled && effective.archive.full_capture_package {
            requested_destinations
                .entry(effective.archive.destination.clone())
                .or_default()
                .push(*slot);
        }
    }
    if requested_destinations.is_empty() {
        return EvidenceFinalization {
            summary: "disabled".to_string(),
            cleanup_gate: EvidenceCleanupGate::NotRequested,
        };
    }

    // A package is a retained-master artifact, never a way to make a
    // derivative-only private bridge capture user-visible. Grouping by the
    // effective frame destination also permits explicit per-frame archive
    // destinations without letting the roll-wide default silently win.
    let observed_frames = evidence
        .lock()
        .map(|guard| guard.clone())
        .unwrap_or_else(|poisoned| poisoned.into_inner().clone());
    let mut frames_by_destination = requested_destinations
        .iter()
        .map(|(destination, _)| (destination.clone(), Vec::new()))
        .collect::<std::collections::BTreeMap<_, Vec<_>>>();
    for frame in observed_frames {
        let Some((destination, _)) = requested_destinations
            .iter()
            .find(|(_, slots)| slots.contains(&frame.frame_index))
        else {
            continue;
        };
        frames_by_destination
            .get_mut(destination)
            .expect("requested evidence destination was initialized")
            .push(frame);
    }

    let mut failures = Vec::new();
    let mut finalized = Vec::new();
    let mut every_package_verified_complete = true;
    for (destination, frames) in frames_by_destination {
        match crate::evidence_package::finalize(
            std::path::Path::new(&destination),
            job_id,
            &frames,
            settings,
            terminal_error,
        ) {
            Ok(result) => {
                every_package_verified_complete &= result.status == "complete";
                finalized.push(format!("{}: {}", result.status, result.detail));
            }
            Err(error) => {
                every_package_verified_complete = false;
                failures.push(format!("failed: {error}"));
            }
        }
    }
    failures.extend(finalized);
    EvidenceFinalization {
        summary: failures.join("; "),
        cleanup_gate: if every_package_verified_complete {
            EvidenceCleanupGate::VerifiedComplete
        } else {
            EvidenceCleanupGate::Hold
        },
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EvidenceCleanupGate {
    /// No effective frame requested a capture package, so there is no
    /// package work that private-capture cleanup must wait for.
    NotRequested,
    /// Every requested package finalized with the exact status `complete`.
    VerifiedComplete,
    /// At least one package failed, was incomplete, or returned an unknown
    /// future status. Private captures remain recovery-held.
    Hold,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct EvidenceFinalization {
    summary: String,
    cleanup_gate: EvidenceCleanupGate,
}

/// Synthetic engine-side termination (panic, watchdog, or a bridge
/// `scan.error` with no following `scan.completed`) is not proof that the
/// bridge worker has released its files. Never inspect or copy capture
/// sources on those paths. The terminal summary still tells the client
/// exactly why the requested package is incomplete.
fn deferred_evidence_status(
    output: &OutputRecipe,
    overrides: &std::collections::HashMap<u32, domain::FrameOverrides>,
    capture_plan: &RealCapturePlan,
    reason: &str,
) -> String {
    let package_requested = capture_plan.expected_by_slot.keys().any(|slot| {
        let effective = effective_output_for_slot(*slot, output, overrides);
        effective.archive.enabled && effective.archive.full_capture_package
    });
    let package = if package_requested {
        format!("incomplete (deferred): {reason}; capture sources were not read or copied")
    } else {
        "disabled".to_string()
    };
    if let Some(working) = capture_plan.private_working_directory.as_ref() {
        format!("{package}; {}", working.recovery_message(reason))
    } else {
        package
    }
}

fn direct_known_capture_names(
    root: &std::path::Path,
    observed_paths: &[std::path::PathBuf],
) -> Result<std::collections::HashSet<std::ffi::OsString>, String> {
    if observed_paths.is_empty() {
        return Err("receipt paths do not prove owned private-capture provenance".to_string());
    }
    let mut names = std::collections::HashSet::new();
    for path in observed_paths {
        if path.parent() != Some(root) {
            return Err(format!(
                "receipt path is not a direct child of the private workspace: {}",
                path.display()
            ));
        }
        let name = path
            .file_name()
            .ok_or_else(|| format!("receipt path has no file name: {}", path.display()))?;
        if name == PRIVATE_CAPTURE_MARKER {
            return Err("a capture receipt cannot identify the ownership marker".to_string());
        }
        names.insert(name.to_os_string());
    }
    Ok(names)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PrivateFileIdentity {
    device: u64,
    inode: u64,
    file_type: u32,
    links: u64,
}

#[cfg(unix)]
fn private_file_identity(metadata: &std::fs::Metadata) -> PrivateFileIdentity {
    use std::os::unix::fs::MetadataExt as _;

    PrivateFileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
        file_type: metadata.mode() & 0o170000,
        links: metadata.nlink(),
    }
}

#[cfg(not(unix))]
fn private_file_identity(_metadata: &std::fs::Metadata) -> PrivateFileIdentity {
    PrivateFileIdentity {
        device: 0,
        inode: 0,
        file_type: 0,
        links: 0,
    }
}

fn identity_at_path(path: &std::path::Path) -> Result<PrivateFileIdentity, String> {
    std::fs::symlink_metadata(path)
        .map(|metadata| private_file_identity(&metadata))
        .map_err(|error| format!("inspect identity {}: {error}", path.display()))
}

/// The private capture workspace is deliberately flat. Requiring one exact
/// marker plus the exact regular files reported by validated bridge receipts
/// means cleanup never needs to recurse, follow links, or infer ownership of
/// a newly-created entry. The returned device/inode/type records bind every
/// later no-replace move and descriptor operation to this exact snapshot.
fn snapshot_flat_private_workspace(
    root: &std::path::Path,
    owner_token: &str,
    known_names: &std::collections::HashSet<std::ffi::OsString>,
) -> Result<std::collections::HashMap<std::ffi::OsString, PrivateFileIdentity>, String> {
    let mut identities = std::collections::HashMap::new();
    let mut saw_marker = false;
    for entry in std::fs::read_dir(root)
        .map_err(|error| format!("read workspace {}: {error}", root.display()))?
    {
        let entry = entry.map_err(|error| format!("read workspace entry: {error}"))?;
        let name = entry.file_name();
        let path = entry.path();
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|error| format!("inspect workspace entry {}: {error}", path.display()))?;
        if metadata.file_type().is_symlink() {
            return Err(format!("workspace contains an ambiguous symlink {}", path.display()));
        }
        let identity = private_file_identity(&metadata);
        if !metadata.is_file() || identity.links != 1 {
            return Err(format!(
                "workspace contains a non-regular, linked, or nested entry {}",
                path.display()
            ));
        }
        if name == PRIVATE_CAPTURE_MARKER {
            if std::fs::read_to_string(&path)
                .map(|value| value == owner_token)
                .unwrap_or(false)
            {
                saw_marker = true;
            } else {
                return Err("workspace ownership marker is missing or changed".to_string());
            }
        } else if known_names.contains(&name) {
            identities.insert(name, identity);
        } else {
            return Err(format!(
                "workspace contains an unaccounted capture artifact {}",
                path.display()
            ));
        }
    }
    if !saw_marker {
        return Err("workspace ownership marker is missing or changed".to_string());
    }
    if identities.keys().collect::<std::collections::HashSet<_>>()
        != known_names.iter().collect::<std::collections::HashSet<_>>()
    {
        return Err("workspace is missing one or more receipt-proven capture files".to_string());
    }
    let marker = root.join(PRIVATE_CAPTURE_MARKER);
    identities.insert(
        std::ffi::OsString::from(PRIVATE_CAPTURE_MARKER),
        identity_at_path(&marker)?,
    );
    Ok(identities)
}

#[cfg(target_os = "macos")]
mod private_cleanup_sys {
    use std::ffi::{CString, OsStr};
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _};
    use std::os::raw::{c_char, c_int, c_uint};
    use std::os::unix::ffi::OsStrExt as _;
    use std::os::unix::fs::OpenOptionsExt as _;

    const RENAME_EXCL: c_uint = 0x0000_0004;
    const RENAME_NOFOLLOW_ANY: c_uint = 0x0000_0010;
    const O_WRONLY: c_int = 0x0000_0001;
    const O_NOFOLLOW: c_int = 0x0000_0100;
    const O_DIRECTORY: c_int = 0x0010_0000;
    const O_CLOEXEC: c_int = 0x0100_0000;

    unsafe extern "C" {
        fn renameatx_np(
            from_fd: c_int,
            from: *const c_char,
            to_fd: c_int,
            to: *const c_char,
            flags: c_uint,
        ) -> c_int;
        fn mkdirat(directory_fd: c_int, path: *const c_char, mode: u16) -> c_int;
        fn openat(directory_fd: c_int, path: *const c_char, flags: c_int, ...) -> c_int;
    }

    fn component(value: &OsStr) -> io::Result<CString> {
        if value.as_bytes().contains(&b'/') {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "secure cleanup accepts exactly one path component",
            ));
        }
        CString::new(value.as_bytes()).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "secure cleanup component contains NUL",
            )
        })
    }

    pub fn open_directory_nofollow(path: &std::path::Path) -> io::Result<std::fs::File> {
        std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            .open(path)
    }

    pub fn rename_exclusive(
        from_directory: &std::fs::File,
        from_name: &OsStr,
        to_directory: &std::fs::File,
        to_name: &OsStr,
    ) -> io::Result<()> {
        let from = component(from_name)?;
        let to = component(to_name)?;
        let result = unsafe {
            renameatx_np(
                from_directory.as_raw_fd(),
                from.as_ptr(),
                to_directory.as_raw_fd(),
                to.as_ptr(),
                RENAME_EXCL | RENAME_NOFOLLOW_ANY,
            )
        };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    pub fn open_regular_for_truncate(
        directory: &std::fs::File,
        name: &OsStr,
    ) -> io::Result<std::fs::File> {
        let name = component(name)?;
        let fd = unsafe {
            openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
            )
        };
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(unsafe { std::fs::File::from_raw_fd(fd) })
        }
    }

    pub fn create_directory_exclusive(
        parent: &std::fs::File,
        name: &OsStr,
    ) -> io::Result<()> {
        let name = component(name)?;
        let result = unsafe { mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod private_cleanup_sys {
    use std::ffi::OsStr;
    use std::io;

    fn unsupported() -> io::Error {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "identity-safe private cleanup requires macOS renameatx_np(RENAME_EXCL)",
        )
    }

    pub fn open_directory_nofollow(_path: &std::path::Path) -> io::Result<std::fs::File> {
        Err(unsupported())
    }

    pub fn rename_exclusive(
        _from_directory: &std::fs::File,
        _from_name: &OsStr,
        _to_directory: &std::fs::File,
        _to_name: &OsStr,
    ) -> io::Result<()> {
        Err(unsupported())
    }

    pub fn open_regular_for_truncate(
        _directory: &std::fs::File,
        _name: &OsStr,
    ) -> io::Result<std::fs::File> {
        Err(unsupported())
    }

    pub fn create_directory_exclusive(
        _parent: &std::fs::File,
        _name: &OsStr,
    ) -> io::Result<()> {
        Err(unsupported())
    }
}

#[allow(dead_code)] // Production uses the no-op hook; fields are consumed by deterministic race tests.
#[derive(Debug, Clone)]
enum PrivateCleanupHookEvent {
    BeforeQuarantineMove {
        source: std::path::PathBuf,
        destination: std::path::PathBuf,
    },
    BeforeStageMove {
        source: std::path::PathBuf,
        destination: std::path::PathBuf,
    },
    BeforeRollbackMove {
        source: std::path::PathBuf,
        destination: std::path::PathBuf,
    },
    BeforeQuarantineSeal {
        quarantine: std::path::PathBuf,
    },
    BeforeFinalDelete {
        path: std::path::PathBuf,
    },
}

#[derive(Debug, Clone)]
struct PrivateCleanupHold {
    roots: std::collections::BTreeSet<std::path::PathBuf>,
    reasons: Vec<String>,
}

impl PrivateCleanupHold {
    fn new(reason: impl Into<String>, roots: impl IntoIterator<Item = std::path::PathBuf>) -> Self {
        Self {
            roots: roots
                .into_iter()
                .filter(|path| std::fs::symlink_metadata(path).is_ok())
                .collect(),
            reasons: vec![reason.into()],
        }
    }

    fn describe(&self) -> String {
        self.reasons.join("; ")
    }
}

#[derive(Debug, Clone)]
struct PrivateCleanupRetired {
    tombstones: Vec<std::path::PathBuf>,
}

fn quarantine_and_retire_known_private_files(
    working: &PrivateCaptureWorkingDirectory,
    observed_paths: &[std::path::PathBuf],
) -> Result<PrivateCleanupRetired, PrivateCleanupHold> {
    quarantine_and_retire_known_private_files_with_hook(working, observed_paths, |_| Ok(()))
}

fn quarantine_and_retire_known_private_files_with_hook<F>(
    working: &PrivateCaptureWorkingDirectory,
    observed_paths: &[std::path::PathBuf],
    mut hook: F,
) -> Result<PrivateCleanupRetired, PrivateCleanupHold>
where
    F: FnMut(&PrivateCleanupHookEvent) -> Result<(), String>,
{
    let known_names = direct_known_capture_names(&working.root, observed_paths)
        .map_err(|reason| PrivateCleanupHold::new(reason, [working.root.clone()]))?;
    let workspace_identity = identity_at_path(&working.root)
        .map_err(|reason| PrivateCleanupHold::new(reason, [working.root.clone()]))?;
    let initial_snapshot = snapshot_flat_private_workspace(
        &working.root,
        &working.owner_token,
        &known_names,
    )
    .map_err(|reason| PrivateCleanupHold::new(reason, [working.root.clone()]))?;

    let parent = working
        .root
        .parent()
        .ok_or_else(|| {
            PrivateCleanupHold::new(
                "private workspace has no parent",
                [working.root.clone()],
            )
        })?;
    let parent_directory = private_cleanup_sys::open_directory_nofollow(parent).map_err(|error| {
        PrivateCleanupHold::new(
            format!("open private workspace parent without following links: {error}"),
            [working.root.clone()],
        )
    })?;
    let quarantine = parent.join(format!(
        ".scanstudio-capture-quarantine-{}",
        working.owner_token
    ));
    hook(&PrivateCleanupHookEvent::BeforeQuarantineMove {
        source: working.root.clone(),
        destination: quarantine.clone(),
    })
    .map_err(|reason| {
        PrivateCleanupHold::new(reason, [working.root.clone(), quarantine.clone()])
    })?;
    private_cleanup_sys::rename_exclusive(
        &parent_directory,
        working.root.file_name().expect("private root has a name"),
        &parent_directory,
        quarantine.file_name().expect("quarantine has a name"),
    )
    .map_err(|error| {
        PrivateCleanupHold::new(
            format!(
                "atomically quarantine private workspace without replacement: {error}"
            ),
            [working.root.clone(), quarantine.clone()],
        )
    })?;
    let quarantined_identity = identity_at_path(&quarantine).map_err(|reason| {
        PrivateCleanupHold::new(reason, [working.root.clone(), quarantine.clone()])
    })?;
    if quarantined_identity != workspace_identity {
        return Err(PrivateCleanupHold::new(
            "quarantine destination identity does not match the verified workspace",
            [working.root.clone(), quarantine.clone()],
        ));
    }
    let quarantine_snapshot = snapshot_flat_private_workspace(
        &quarantine,
        &working.owner_token,
        &known_names,
    )
    .map_err(|reason| PrivateCleanupHold::new(reason, [quarantine.clone()]))?;
    if quarantine_snapshot != initial_snapshot {
        return Err(PrivateCleanupHold::new(
            "private workspace entry identities changed during quarantine",
            [quarantine.clone()],
        ));
    }

    let quarantine_directory = private_cleanup_sys::open_directory_nofollow(&quarantine)
        .map_err(|error| {
            PrivateCleanupHold::new(
                format!("open quarantined workspace without following links: {error}"),
                [quarantine.clone()],
            )
        })?;
    let staging = parent.join(format!(
        ".scanstudio-capture-tombstone-{}",
        working.owner_token
    ));
    private_cleanup_sys::create_directory_exclusive(
        &parent_directory,
        staging.file_name().expect("tombstone has a name"),
    )
    .map_err(|error| {
        PrivateCleanupHold::new(
            format!(
                "reserve identity tombstone directory {} without replacement: {error}",
                staging.display()
            ),
            [quarantine.clone(), staging.clone()],
        )
    })?;
    let staging_directory = private_cleanup_sys::open_directory_nofollow(&staging).map_err(|error| {
        PrivateCleanupHold::new(
            format!("open identity tombstone without following links: {error}"),
            [quarantine.clone(), staging.clone()],
        )
    })?;

    let mut sorted_names: Vec<_> = quarantine_snapshot.keys().cloned().collect();
    sorted_names.sort();
    let mut moved_names: Vec<(std::ffi::OsString, PrivateFileIdentity)> = Vec::new();
    for name in &sorted_names {
        let source = quarantine.join(name);
        let destination = staging.join(name);
        hook(&PrivateCleanupHookEvent::BeforeStageMove {
            source: source.clone(),
            destination: destination.clone(),
        })
        .map_err(|reason| {
            failure_with_secure_rollback(
                reason,
                &quarantine_directory,
                &staging_directory,
                &quarantine,
                &staging,
                &moved_names,
                &mut hook,
            )
        })?;
        let expected = quarantine_snapshot[name];
        if identity_at_path(&source).ok() != Some(expected) {
            return Err(failure_with_secure_rollback(
                format!("verified source identity changed before no-replace move: {}", source.display()),
                &quarantine_directory,
                &staging_directory,
                &quarantine,
                &staging,
                &moved_names,
                &mut hook,
            ));
        }
        if let Err(error) = private_cleanup_sys::rename_exclusive(
            &quarantine_directory,
            name,
            &staging_directory,
            name,
        ) {
            return Err(failure_with_secure_rollback(
                format!("stage exact private identity without replacement: {error}"),
                &quarantine_directory,
                &staging_directory,
                &quarantine,
                &staging,
                &moved_names,
                &mut hook,
            ));
        }
        if identity_at_path(&destination).ok() != Some(expected) {
            let mut hold = failure_with_secure_rollback(
                format!("staged destination identity does not match source: {}", destination.display()),
                &quarantine_directory,
                &staging_directory,
                &quarantine,
                &staging,
                &moved_names,
                &mut hook,
            );
            hold.roots.insert(staging.clone());
            return Err(hold);
        }
        moved_names.push((name.clone(), expected));
    }

    hook(&PrivateCleanupHookEvent::BeforeQuarantineSeal {
        quarantine: quarantine.clone(),
    })
    .map_err(|reason| {
        failure_with_secure_rollback(
            reason,
            &quarantine_directory,
            &staging_directory,
            &quarantine,
            &staging,
            &moved_names,
            &mut hook,
        )
    })?;
    if std::fs::read_dir(&quarantine)
        .map_err(|error| {
            failure_with_secure_rollback(
                format!("inspect quarantined namespace before retirement: {error}"),
                &quarantine_directory,
                &staging_directory,
                &quarantine,
                &staging,
                &moved_names,
                &mut hook,
            )
        })?
        .next()
        .is_some()
    {
        return Err(failure_with_secure_rollback(
            "quarantined namespace gained an unknown entry; preserving every identity",
            &quarantine_directory,
            &staging_directory,
            &quarantine,
            &staging,
            &moved_names,
            &mut hook,
        ));
    }

    // macOS has no unlink primitive conditioned on device+inode. Never use a
    // metadata-then-unlink sequence: a same-name replacement could become the
    // victim. Instead open each expected inode relative to the already-opened
    // no-follow tombstone directory, compare identity, and reclaim only that
    // descriptor's bytes. Names and the marker remain as tiny identity
    // tombstones; a substituted source is recovery-held without modification.
    for name in sorted_names
        .iter()
        .filter(|name| name.as_os_str() != PRIVATE_CAPTURE_MARKER)
    {
        let path = staging.join(name);
        hook(&PrivateCleanupHookEvent::BeforeFinalDelete { path: path.clone() })
            .map_err(|reason| {
                PrivateCleanupHold::new(reason, [quarantine.clone(), staging.clone()])
            })?;
        let expected = quarantine_snapshot[name];
        let file = private_cleanup_sys::open_regular_for_truncate(&staging_directory, name)
            .map_err(|error| {
                PrivateCleanupHold::new(
                    format!("open exact staged identity without following links: {error}"),
                    [quarantine.clone(), staging.clone()],
                )
            })?;
        let opened_identity = file.metadata().map(|metadata| private_file_identity(&metadata));
        if opened_identity.ok() != Some(expected) {
            return Err(PrivateCleanupHold::new(
                format!("final staged name no longer identifies the verified capture: {}", path.display()),
                [quarantine.clone(), staging.clone()],
            ));
        }
        file.set_len(0).map_err(|error| {
            PrivateCleanupHold::new(
                format!("reclaim exact verified capture bytes through bound descriptor: {error}"),
                [quarantine.clone(), staging.clone()],
            )
        })?;
        if identity_at_path(&path).ok() != Some(expected) {
            return Err(PrivateCleanupHold::new(
                format!("staged name changed while its verified inode was retired: {}", path.display()),
                [quarantine.clone(), staging.clone()],
            ));
        }
    }

    Ok(PrivateCleanupRetired {
        tombstones: vec![quarantine, staging],
    })
}

fn failure_with_secure_rollback<F>(
    reason: impl Into<String>,
    quarantine_directory: &std::fs::File,
    staging_directory: &std::fs::File,
    quarantine: &std::path::Path,
    staging: &std::path::Path,
    moved_names: &[(std::ffi::OsString, PrivateFileIdentity)],
    hook: &mut F,
) -> PrivateCleanupHold
where
    F: FnMut(&PrivateCleanupHookEvent) -> Result<(), String>,
{
    let mut hold = PrivateCleanupHold::new(
        reason,
        [quarantine.to_path_buf(), staging.to_path_buf()],
    );
    for (name, expected) in moved_names.iter().rev() {
        let source = staging.join(name);
        let destination = quarantine.join(name);
        if let Err(reason) = hook(&PrivateCleanupHookEvent::BeforeRollbackMove {
            source: source.clone(),
            destination: destination.clone(),
        }) {
            hold.reasons.push(format!("rollback hook failed: {reason}"));
            continue;
        }
        if identity_at_path(&source).ok() != Some(*expected) {
            hold.reasons.push(format!(
                "rollback source identity changed; preserved at {}",
                source.display()
            ));
            continue;
        }
        if let Err(error) = private_cleanup_sys::rename_exclusive(
            staging_directory,
            name,
            quarantine_directory,
            name,
        ) {
            hold.reasons.push(format!(
                "rollback no-replace move preserved both names for {}: {error}",
                name.to_string_lossy()
            ));
            continue;
        }
        if identity_at_path(&destination).ok() != Some(*expected) {
            hold.reasons.push(format!(
                "rollback destination identity mismatch at {}",
                destination.display()
            ));
        }
    }
    hold.roots.extend(
        [quarantine.to_path_buf(), staging.to_path_buf()]
            .into_iter()
            .filter(|path| std::fs::symlink_metadata(path).is_ok()),
    );
    hold
}

/// Private working capture bytes are retired only after the bridge emitted
/// the real terminal closure, every private slot has a successful derivative,
/// no bridge-summary failure remains, and directory/file identities remain
/// exact. This function deliberately recovery-holds every ambiguity.
fn finalize_private_capture_workspace(
    capture_plan: &RealCapturePlan,
    terminal_completed: &[u32],
    terminal_failed: &[u32],
    successful_private_slots: &std::collections::HashSet<u32>,
    observed_paths: &[std::path::PathBuf],
    evidence_finalization: &EvidenceFinalization,
) -> String {
    let Some(working) = capture_plan.private_working_directory.as_ref() else {
        return "not applicable".to_string();
    };
    if evidence_finalization.cleanup_gate == EvidenceCleanupGate::Hold {
        return working.recovery_message(&format!(
            "evidence package was not explicitly verified complete ({})",
            evidence_finalization.summary
        ));
    }
    if terminal_failed.iter().any(|slot| capture_plan.private_slots.contains(slot))
        || !capture_plan.private_slots.iter().all(|slot| terminal_completed.contains(slot))
        || !capture_plan.private_slots.is_subset(successful_private_slots)
    {
        return working.recovery_message(
            "bridge terminal summary or derivative outcomes did not prove every private capture completed successfully",
        );
    }
    match quarantine_and_retire_known_private_files(working, observed_paths) {
        Ok(retired) => format!(
            "private temporary captures cleaned from {}; identity tombstones retained at {}",
            working.root.display(),
            retired
                .tombstones
                .iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Err(hold) => working.recovery_message_for_hold(&hold),
    }
}

/// Bounded, best-effort drain for a "late bridge closure" racing behind an
/// already-handled `scan.error` (10-08). BRIDGE.md is explicit that
/// `scan.error` "does not replace `scan.completed`" — the SAME worker
/// thread's own `finally` block (the common case: a `BridgeError`-raising
/// or bad-summary-shape failure, where the real `scan.completed` follows
/// within microseconds) or, rarely, the soft-timeout watchdog's stuck call
/// finally returning on its own minutes later, can still emit a real
/// terminal event for this exact job after we've already reported our own
/// honest failure and committed to "`scan.completed` fires exactly once
/// per job." `BridgeClient`'s `events_rx` is one process-wide channel, not
/// scoped per job, so anything left unread here would otherwise sit queued
/// and could be misdelivered into a LATER, unrelated job's own polling
/// loop. Bounded short: the common same-thread-`finally` case resolves in
/// microseconds; the rare true-watchdog case is deliberately not waited
/// out here. Never consumes an event that doesn't carry this exact
/// `job_id` — BRIDGE.md's single-hardware-lane guarantee means that
/// shouldn't normally happen while this job still (nominally) holds the
/// lane, but this function must never swallow a signal that doesn't
/// provably belong to the job it just terminated.
///
/// Returns whether this job's real bridge `scan.completed` closure was
/// actually observed
/// (2026-07-25 incident fix, stale SCANNING after a zero-completed batch)
/// — the caller uses this to decide whether a follow-up `backend.status()`
/// poll is safe: seeing a real event for this exact `job_id` here proves
/// the worker thread's own `finally` has already run (bridge-side hardware
/// lane released, mirrors BRIDGE.md's "terminal events fire after the lane
/// is released" guarantee), which is the same precondition the
/// `scan.completed` arm below always has when it unconditionally polls
/// status. `false` (the rare true-watchdog case, or a bridge that has gone
/// fully silent) means that precondition is NOT established — the
/// underlying call may still genuinely be in flight — so the caller must
/// skip the poll, preserving this function's original "never risk
/// restarting the bridge mid-USB-transaction" guarantee.
fn drain_late_bridge_closure_for(backend: &Arc<RealLs5000>, job_id: &str) -> bool {
    const DRAIN_WINDOW: Duration = Duration::from_millis(500);
    let deadline = Instant::now() + DRAIN_WINDOW;
    loop {
        let remaining_time = deadline.saturating_duration_since(Instant::now());
        if remaining_time.is_zero() {
            return false;
        }
        match backend.bridge.recv_event(remaining_time) {
            Ok(value) => {
                let event_job_id = value.pointer("/payload/jobId").and_then(|v| v.as_str());
                if event_job_id != Some(job_id) {
                    return false;
                }
                // Only the bridge worker's own terminal closure proves
                // that it has released every source file. Other same-job
                // events are drained but never authorize packaging.
                if value.get("event").and_then(|v| v.as_str()) == Some("scan.completed") {
                    return true;
                }
            }
            Err(_) => return false,
        }
    }
}

/// Worker-thread body for `RealLs5000::scan_start`, driven by bridge
/// events instead of internal timers (mirrors `sim.rs::run_scan_job`'s
/// overall shape). `total_frames` is fixed at the *original* requested
/// frame count for the whole job's lifetime — `job_percent` is computed
/// against it throughout.
///
/// Silence watchdog (live-debugged 2026-07-23): a
/// real fine-scan job went silent for 25 minutes with zero wire events and
/// no watchdog ever fired — the exact preview-path defect
/// `09-real-backend/HARDWARE-NOTES-20260723.md` fixed live, never mirrored
/// onto this path until now. This function now tolerates bridge silence
/// (CoolscanPy's per-slot `Roll.scan` call is blocking, exactly like
/// `Roll.preview` — zero events while it runs is normal) up to a rolling
/// deadline, then reports an honest failure. It deliberately no longer
/// retries by re-issuing `scan.start`: that old recovery path could itself
/// call `BridgeClient::call()`, whose own timeout handling restarts
/// (kills) the bridge subprocess — precisely the "never kill mid-USB-
/// transaction" hazard this fix exists to close (see
/// `HARDWARE-NOTES-20260723.md`). No test exercised that old retry path
/// (confirmed: `scan_start_crash_mid_job_emits_feed_jam_then_recovers`
/// only exercises the crash-handling around the *initiating*
/// `scan.start` call in `RealLs5000::scan_start`, before this function's
/// thread is ever spawned), so removing it breaks nothing.
///
/// Root-caused 2026-07-23: live attempt #2
/// proved this watchdog can still be defeated even though its own loop
/// logic is correct — because this function used to make ONE unconditional
/// `backend.status()` bridge call at its own entry, BEFORE
/// `silence_deadline` is ever armed. Fixed by deleting that call (see the
/// comment at this function's first few lines) rather than adding a
/// second timeout around it — the exact "zero further bridge calls"
/// principle 10-04 already applied to this function's OWN terminal-failure
/// branch, just missed at the function's entry.
fn run_real_scan_job(
    backend: Arc<RealLs5000>,
    job_id: String,
    frames: Vec<u32>,
    recipe: CaptureRecipe,
    processing: ProcessingRecipe,
    output: OutputRecipe,
    overrides: std::collections::HashMap<u32, domain::FrameOverrides>,
    capture_plan: RealCapturePlan,
    project_directory: Option<std::path::PathBuf>,
    event_tx: mpsc::Sender<String>,
    session_epoch: u64,
    bridge_generation: u64,
) {
    // 11-01: panic-safety net. The worker thread must never die silently:
    // whatever real progress was already reported to the client must still
    // be wrapped in an honest terminal scan.completed. Shared progress is
    // updated incrementally so it survives a caught panic.
    let shared_progress: Arc<Mutex<(Vec<u32>, Vec<u32>)>> = Arc::new(Mutex::new((vec![], vec![])));
    let shared_evidence: Arc<Mutex<Vec<crate::evidence_package::EvidenceFrame>>> =
        Arc::new(Mutex::new(Vec::new()));

    emit(
        &event_tx,
        "scan.jobState",
        JobStatePayload {
            job_id: job_id.clone(),
            state: JobState::Scanning,
        },
    );

    let backend_for_inner = Arc::clone(&backend);
    let job_id_for_inner = job_id.clone();
    let shared_progress_for_inner = Arc::clone(&shared_progress);
    let shared_evidence_for_inner = Arc::clone(&shared_evidence);
    let event_tx_for_inner = event_tx.clone();
    let frames_for_inner = frames.clone();
    let recipe_for_inner = recipe.clone();
    let processing_for_inner = processing.clone();
    let output_for_inner = output.clone();
    let overrides_for_inner = overrides.clone();
    let capture_plan_for_inner = capture_plan.clone();

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        run_real_scan_job_inner(
            backend_for_inner,
            job_id_for_inner,
            frames_for_inner,
            recipe_for_inner,
            processing_for_inner,
            output_for_inner,
            overrides_for_inner,
            capture_plan_for_inner,
            project_directory,
            event_tx_for_inner,
            shared_progress_for_inner,
            shared_evidence_for_inner,
            session_epoch,
            bridge_generation,
        );
    }));

    if let Err(_) = result {
        eprintln!(
            "scanstudio-engine: scan worker thread panicked for job {job_id}; \
             emitting honest terminal failure with best-known progress"
        );
        let (known_completed, known_failed) = shared_progress
            .lock()
            .map(|guard| (guard.0.clone(), guard.1.clone()))
            .unwrap_or_else(|poisoned| {
                let guard = poisoned.into_inner();
                (guard.0.clone(), guard.1.clone())
            });
        let mut remaining: Vec<u32> = frames
            .into_iter()
            .filter(|f| !known_completed.contains(f) && !known_failed.contains(f))
            .collect();
        let mut failed = known_failed;
        let error = EngineError::new(
            ErrorCode::Internal,
            "scan worker thread panicked unexpectedly; frame outcome for this slot is unknown",
        );
        let error_payload = ErrorPayload::from(&error);
        let evidence_package_status = deferred_evidence_status(
            &output,
            &overrides,
            &capture_plan,
            "the engine worker panicked before a real bridge scan.completed closure",
        );
        emit_terminal_job_failure(
            &event_tx,
            &job_id,
            &mut remaining,
            &known_completed,
            &mut failed,
            &error_payload,
            None,
            Some(evidence_package_status),
        );
    }
}

/// Worker-thread body for `RealLs5000::scan_start`, driven by bridge
/// events instead of internal timers (mirrors `sim.rs::run_scan_job`'s
/// overall shape). `total_frames` is fixed at the *original* requested
/// frame count for the whole job's lifetime — `job_percent` is computed
/// against it throughout.
///
/// Silence watchdog (live-debugged 2026-07-23): a
/// real fine-scan job went silent for 25 minutes with zero wire events and
/// no watchdog ever fired — the exact preview-path defect
/// `09-real-backend/HARDWARE-NOTES-20260723.md` fixed live, never mirrored
/// onto this path until now. This function now tolerates bridge silence
/// (CoolscanPy's per-slot `Roll.scan` call is blocking, exactly like
/// `Roll.preview` — zero events while it runs is normal) up to a rolling
/// deadline, then reports an honest failure. It deliberately no longer
/// retries by re-issuing `scan.start`: that old recovery path could itself
/// call `BridgeClient::call()`, whose own timeout handling restarts
/// (kills) the bridge subprocess — precisely the "never kill mid-USB-
/// transaction" hazard this fix exists to close (see
/// `HARDWARE-NOTES-20260723.md`). No test exercised that old retry path
/// (confirmed: `scan_start_crash_mid_job_emits_feed_jam_then_recovers`
/// only exercises the crash-handling around the *initiating*
/// `scan.start` call in `RealLs5000::scan_start`, before this function's
/// thread is ever spawned), so removing it breaks nothing.
///
/// Root-caused 2026-07-23: live attempt #2
/// proved this watchdog can still be defeated even though its own loop
/// logic is correct — because this function used to make ONE unconditional
/// `backend.status()` bridge call at its own entry, BEFORE
/// `silence_deadline` is ever armed. Fixed by deleting that call (see the
/// comment at this function's first few lines) rather than adding a second
/// timeout around it — the exact "zero further bridge calls"
/// principle 10-04 already applied to this function's OWN terminal-failure
/// branch, just missed at this function's entry.
fn run_real_scan_job_inner(
    backend: Arc<RealLs5000>,
    job_id: String,
    frames: Vec<u32>,
    recipe: CaptureRecipe,
    processing: ProcessingRecipe,
    output: OutputRecipe,
    overrides: std::collections::HashMap<u32, domain::FrameOverrides>,
    capture_plan: RealCapturePlan,
    project_directory: Option<std::path::PathBuf>,
    event_tx: mpsc::Sender<String>,
    shared_progress: Arc<Mutex<(Vec<u32>, Vec<u32>)>>,
    shared_evidence: Arc<Mutex<Vec<crate::evidence_package::EvidenceFrame>>>,
    session_epoch: u64,
    bridge_generation: u64,
) {
    // Deliberately NO backend.status() call here: this used to be
    // an unconditional bridge.call("device.status", ...) right before the
    // silence watchdog below is even armed (`silence_deadline` is not set
    // until after this point). That call is bounded only by
    // BridgeClient's own `request_timeout`/`restart()` machinery, NOT by
    // this function's watchdog — so a slow or stuck reply from the bridge
    // here could (a) delay entry into the watchdog loop by the full
    // request_timeout, well past whatever short SCANSTUDIO_SCAN_SILENCE_
    // DEADLINE_SECS the caller configured, and (b) trigger
    // BridgeClient::restart() (kill + respawn the bridge subprocess) —
    // exactly the "never kill mid-USB-transaction" hazard this whole
    // watchdog exists to close (HARDWARE-NOTES-20260723.md), and — worse —
    // if the killed process cannot actually be reaped (e.g. genuinely
    // wedged in a kernel-level USB wait), `BridgeClient::restart()`'s
    // `child.wait()` never returns, permanently parking this thread BEFORE
    // the watchdog loop is ever reached, no matter how correct that loop's
    // own logic is. This is the identical reasoning the Err(_) branch's own
    // terminal-failure path below already applies to omit ITS OWN
    // status() call (see that comment) — this fix just extends the same
    // principle to this function's entry, the one place it was missed.
    // Nothing downstream depends on this event: server.rs's own
    // post-dispatch hook already emits an equivalent scanner.status for
    // every "scan.start" request (`matches!(request.method.as_str(),
    // "scanner.acquireThumbnails" | "scan.start" | "scan.stop")`), so this
    // was a purely redundant, unprotected duplicate — not a second source
    // of information the client relied on.

    let total_frames = frames.len() as u32;
    let mut remaining: Vec<u32> = frames;
    let mut completed: Vec<u32> = Vec::new();
    let mut failed: Vec<u32> = Vec::new();
    // Frames captured successfully by the bridge whose engine-side
    // derivative render failed. The terminal bridge summary must not
    // re-label these frames completed.
    let mut derivative_failed: Vec<u32> = Vec::new();
    // Private capture artifacts are eligible for deletion only if their
    // exact receipt paths, derivative outcomes, and bridge terminal
    // closure all agree. Any uncertainty leaves the entire workspace held
    // for recovery.
    let mut successful_private_slots = std::collections::HashSet::<u32>::new();
    let mut observed_private_capture_paths = Vec::<std::path::PathBuf>::new();
    // Collected only after a frame's bridge capture and engine receipt have
    // both succeeded. Packaging waits for terminal scan.completed below.
    let sync_progress = |completed: &[u32], failed: &[u32]| {
        if let Ok(mut guard) = shared_progress.lock() {
            guard.0 = completed.to_vec();
            guard.1 = failed.to_vec();
        }
    };
    // 2026-07-26 fix (frame-ordinal display bug, live 2026-07-25):
    // scan.frameCompleted/hardware.anomaly/scan.frameFailed are the only
    // signals that a frame actually started or finished during the real
    // scan — scan.progress's entire burst fires up front, before any of
    // them (see the "scan.progress" arm's own comment below and
    // `compute_frame_ordinal`'s doc comment). Called immediately after
    // `sync_progress` at every point `completed`/`failed` change, this
    // re-emits an honest `scan.progress` from this job's own bookkeeping
    // so the client-facing ordinal actually advances with real progress,
    // instead of staying silent (and stale) until the next bridge-side
    // scan.progress, which never comes. `frame_index` names whichever
    // slot is now the newest one in flight (falling back to the
    // most-recently-resolved slot once nothing remains).
    let emit_frame_progress = |completed: &[u32], failed: &[u32], remaining: &[u32]| {
        let frame_index = remaining
            .first()
            .copied()
            .or_else(|| completed.last().copied())
            .or_else(|| failed.last().copied())
            .unwrap_or(0);
        emit(
            &event_tx,
            "scan.progress",
            ScanProgressPayload {
                job_id: job_id.clone(),
                frame_index,
                frame_ordinal: compute_frame_ordinal(completed, failed, total_frames),
                total_frames,
                pass: 1,
                total_passes: recipe.multisample_passes,
                // The frame this event now names just started (or, at
                // job end, nothing remains) — never a fabricated
                // sub-frame fraction. Mirrors eta_seconds' own "honest
                // unknown" convention elsewhere in this function.
                frame_percent: 0.0,
                job_percent: (completed.len() + failed.len()) as f64 * 100.0
                    / total_frames.max(1) as f64,
                eta_seconds: 0.0,
            },
        );
    };
    // Rolling silence deadline: unlike acquire_thumbnails's fixed "600s
    // from the start of one blocking call" deadline (correct there —
    // roll.preview is a single burst-or-nothing read), a real scan job can
    // legitimately run for many minutes across multiple frames while
    // remaining perfectly healthy, so this deadline is pushed forward
    // every time any scan-scoped event arrives (see the `Ok(value)` arm
    // below) and only expires on genuine, continuous silence.
    let mut silence_deadline = Instant::now() + backend.scan_silence_deadline;

    // Frame-to-frame idle measurement (12-03): purely observational, from
    // event-arrival Instants this process already sees. The first requested
    // frame has no predecessor and contributes no sample.
    let mut idle_samples: Vec<FrameIdleSample> = Vec::new();
    let mut last_resolved_at: Option<Instant> = None;
    let mut last_progress_slot: Option<u32> = None;

    loop {
        // Never wait past the still-open silence window in one poll — this
        // matters for the short test deadlines (~2s, set either via
        // SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS on an out-of-process engine
        // or via RealLs5000::with_scan_silence_deadline in-process);
        // production's 600s default makes this cap a no-op since
        // HEALTH_TIMEOUT's 10s always wins the min().
        let poll_timeout =
            HEALTH_TIMEOUT.min(silence_deadline.saturating_duration_since(Instant::now()));
        match backend.bridge.recv_event(poll_timeout) {
            Ok(value) => {
                // Any scan-scoped event — recognized or not — proves the
                // bridge is actively communicating: push the silence
                // window forward before dispatching on the event name.
                silence_deadline = Instant::now() + backend.scan_silence_deadline;
                match value.get("event").and_then(|v| v.as_str()).unwrap_or("") {
                    "scan.progress" => {
                        let Some(payload) = value.get("payload").cloned() else {
                            continue;
                        };
                        let Ok(progress) = serde_json::from_value::<BridgeScanProgress>(payload)
                        else {
                            continue;
                        };
                        if last_progress_slot != Some(progress.slot) {
                            last_progress_slot = Some(progress.slot);
                            if let Some(prev) = last_resolved_at {
                                idle_samples.push(FrameIdleSample {
                                    frame_index: progress.slot,
                                    idle_ms: prev.elapsed().as_millis() as u64,
                                });
                            }
                        }
                        // frame_ordinal/total_frames/job_percent are
                        // deliberately NOT progress.ordinal/total_slots
                        // here: this whole "scan.progress" event fires as
                        // part of CoolscanPyTransport.start_scan's upfront
                        // per-slot naming pass (every requested slot, all
                        // before scan_many() ever moves hardware — see
                        // compute_frame_ordinal's doc comment for the live
                        // incident this caused), so those wire fields never
                        // reflect real progress. They're recomputed from
                        // this job's own completed/failed bookkeeping
                        // instead, exactly like emit_frame_progress above.
                        // frame_index and frame_percent keep echoing the
                        // bridge's own per-slot announcement (still true
                        // and still useful: "this slot is one of the ones
                        // requested").
                        emit(
                            &event_tx,
                            "scan.progress",
                            ScanProgressPayload {
                                job_id: job_id.clone(),
                                frame_index: progress.slot,
                                frame_ordinal: compute_frame_ordinal(
                                    &completed,
                                    &failed,
                                    total_frames,
                                ),
                                total_frames,
                                pass: 1,
                                total_passes: recipe.multisample_passes,
                                frame_percent: progress.fraction * 100.0,
                                // BRIDGE.md's ScanProgress has no per-pass
                                // or ETA telemetry — pass/total_passes
                                // echo the request's own recipe rather
                                // than a real per-pass count, and
                                // eta_seconds: 0.0 below is an honest
                                // "unknown", never a fabricated estimate.
                                job_percent: (completed.len() + failed.len()) as f64 * 100.0
                                    / total_frames.max(1) as f64,
                                eta_seconds: 0.0,
                            },
                        );
                    }
                    "scan.frameRetrying" => {
                        let Some(payload) = value.get("payload").cloned() else {
                            continue;
                        };
                        let Ok(retrying) =
                            serde_json::from_value::<BridgeFrameRetryingPayload>(payload)
                        else {
                            continue;
                        };
                        // The bridge's own bounded-retry already ran — the
                        // engine just mirrors the attempt counter.
                        emit(
                            &event_tx,
                            "scan.frameState",
                            FrameStatePayload {
                                job_id: job_id.clone(),
                                frame_index: retrying.slot,
                                state: FrameState::Active,
                                attempt: retrying.attempt,
                                error: None,
                            },
                        );
                    }
                    "scan.frameCompleted" => {
                        let Some(payload) = value.get("payload").cloned() else {
                            continue;
                        };
                        let Ok(frame_completed) =
                            serde_json::from_value::<BridgeFrameCompletedPayload>(payload)
                        else {
                            continue;
                        };
                        let frame_overrides = overrides.get(&frame_completed.slot);
                        let effective_output = frame_overrides
                            .and_then(|value| value.output.as_ref())
                            .unwrap_or(&output);
                        let effective_processing = frame_overrides
                            .and_then(|value| value.processing.as_ref())
                            .unwrap_or(&processing)
                            .effective();
                        let effective_alignment =
                            frame_overrides.and_then(|value| value.alignment.as_ref());
                        // The bridge already applies an approved spacing
                        // offset while positioning this real frame, so the
                        // engine must not crop it a second time. Rotation and
                        // flips are different: they are derivative-only pixel
                        // geometry and still belong in the renderer.
                        let derivative_geometry = effective_alignment.map(|value| {
                            domain::FrameAlignment {
                                offset_rows: 0,
                                approved: false,
                                derivative_transform: value.derivative_transform,
                            }
                        });

                        let receipt_path_validation = if frame_completed.receipt.slot
                            != frame_completed.slot
                        {
                            Err(EngineError::new(
                                ErrorCode::InvalidParams,
                                format!(
                                    "bridge frameCompleted slot {} disagrees with receipt slot {}",
                                    frame_completed.slot, frame_completed.receipt.slot
                                ),
                            ))
                        } else if let Some(expected) = capture_plan.expected_by_slot.get(&frame_completed.slot) {
                            crate::render::validate_bridge_capture_receipt_paths_for_expected(
                                &expected.rgb,
                                frame_completed.slot,
                                recipe.channels,
                                std::path::Path::new(&frame_completed.receipt.rgb_path),
                                frame_completed
                                    .receipt
                                    .ir_path
                                    .as_deref()
                                    .map(std::path::Path::new),
                                frame_completed
                                    .receipt
                                    .meter_rgbi_path
                                    .as_deref()
                                    .map(std::path::Path::new),
                            )
                        } else {
                            Err(EngineError::new(
                                ErrorCode::InvalidParams,
                                format!("bridge completed unplanned frame {}", frame_completed.slot),
                            ))
                        };
                        if let Err(error) = receipt_path_validation {
                            // The bridge says hardware captured this frame,
                            // but an unexpected file path is never safe to
                            // open, persist, or package. Fail this engine
                            // outcome without touching the reported source.
                            emit(
                                &event_tx,
                                "scan.frameState",
                                FrameStatePayload {
                                    job_id: job_id.clone(),
                                    frame_index: frame_completed.slot,
                                    state: FrameState::Failed,
                                    attempt: 1,
                                    error: Some(ErrorPayload::from(&error)),
                                },
                            );
                            remaining.retain(|&frame| frame != frame_completed.slot);
                            if !failed.contains(&frame_completed.slot) {
                                failed.push(frame_completed.slot);
                            }
                            if !derivative_failed.contains(&frame_completed.slot) {
                                derivative_failed.push(frame_completed.slot);
                            }
                            sync_progress(&completed, &failed);
                            emit_frame_progress(&completed, &failed, &remaining);
                            last_resolved_at = Some(Instant::now());
                            continue;
                        }

                        // The hardware capture is evidence as soon as the
                        // bridge completes it. Derivative rendering is a
                        // later, fallible engine step and must never erase
                        // the exact RGB/IR/meter provenance.
                        let base_receipt = build_real_receipt(
                            &job_id,
                            frame_completed.slot,
                            &recipe,
                            &effective_processing,
                            effective_output,
                            &frame_completed.receipt,
                        );
                        if let Ok(mut evidence) = shared_evidence.lock() {
                            let receipt_output = crate::render::receipt_output_recipe(effective_output);
                            evidence.push(crate::evidence_package::EvidenceFrame {
                                frame_index: frame_completed.slot,
                                rgb_path: std::path::PathBuf::from(&frame_completed.receipt.rgb_path),
                                ir_path: frame_completed.receipt.ir_path.as_ref().map(std::path::PathBuf::from),
                                meter_path: frame_completed.receipt.meter_rgbi_path.as_ref().map(std::path::PathBuf::from),
                                bridge_receipt: serde_json::to_value(&frame_completed.receipt)
                                    .expect("BridgeScanReceipt must serialize"),
                                engine_receipt: serde_json::json!({
                                    "receipt": base_receipt,
                                    "effectiveSettings": {
                                        "capture": recipe,
                                        "processing": effective_processing,
                                        "output": receipt_output,
                                        "alignment": effective_alignment,
                                    },
                                    "derivativeOutcome": {"status": "pending"}
                                }),
                                attempts_root: frame_completed.receipt.attempts_root.as_ref().map(std::path::PathBuf::from),
                            });
                        }
                        let derivative = crate::render::render_derivative_from_archive_with_processing(
                            std::path::Path::new(&frame_completed.receipt.rgb_path),
                            frame_completed.slot,
                            &effective_processing,
                            effective_output,
                            Some(frame_completed.receipt.storage_transform.as_str()),
                            None,
                            // The driver session already applied the preview's
                            // spacing offset while positioning this real
                            // frame. Reusing that transport offset as a pixel
                            // crop would shift the completed raster twice.
                            None,
                            derivative_geometry.as_ref(),
                            nikonlook_exposure_10ns_from_receipt(&frame_completed.receipt.exposure),
                        );

                        match derivative {
                            Ok(written) => {
                                let mut receipt = base_receipt;
                                receipt.outputs = Some(domain::WrittenOutputs {
                                    archive_path: written
                                        .archive_path
                                        .as_ref()
                                        .map(|path| path.display().to_string()),
                                    positive_path: written
                                        .positive_path
                                        .map(|path| path.display().to_string()),
                                    preview_path: written
                                        .preview_path
                                        .map(|path| path.display().to_string()),
                                    derivative_transform: written.derivative_transform,
                                });
                                // Which nikonlook bundle/path/gains actually
                                // rendered this frame -- see build_real_receipt's
                                // own `nikonlook: None` comment above.
                                receipt.nikonlook = written.nikonlook;
                                receipt.auto_crop = written.auto_crop;
                                if let Ok(mut evidence) = shared_evidence.lock() {
                                    if let Some(frame) = evidence.iter_mut().rev().find(|value| value.frame_index == frame_completed.slot) {
                                        frame.engine_receipt["receipt"] = serde_json::to_value(&receipt)
                                            .expect("ScanReceipt must serialize");
                                        frame.engine_receipt["derivativeOutcome"] =
                                            serde_json::json!({"status": "completed", "outputs": receipt.outputs});
                                    }
                                }
                                // A receipt persistence failure here does not
                                // mean the frame failed -- the master and any
                                // derivatives are already durably on disk, so
                                // reporting FrameState::Failed would be its
                                // own dishonesty (D-08's transition table has
                                // no "completed but actually failed" state,
                                // and nothing about the capture failed). What
                                // did not happen is the provenance record
                                // landing in the project manifest, and pre-fix
                                // that gap reached nowhere but this process's
                                // stderr -- invisible to the app and the
                                // person who scanned this frame. Attaching the
                                // error to this same Completed event (rather
                                // than inventing a new event the app doesn't
                                // already parse) reuses FrameStatePayload's
                                // existing optional `error` field, which
                                // SessionModel.applyFrameState already stores
                                // per frame regardless of state and already
                                // logs as a diagnostic.
                                let manifest_persist_error = match &project_directory {
                                    Some(directory) => crate::manifest::persist_frame_receipt(
                                        directory,
                                        frame_completed.slot,
                                        &receipt,
                                    )
                                    .err(),
                                    None => None,
                                };
                                if let Some(err) = &manifest_persist_error {
                                    eprintln!(
                                        "scanstudio-engine: failed to persist frame receipt to manifest: {err}"
                                    );
                                    if let Ok(mut evidence) = shared_evidence.lock() {
                                        if let Some(frame) = evidence.iter_mut().rev().find(|value| value.frame_index == frame_completed.slot) {
                                            frame.engine_receipt["manifestPersistence"] = serde_json::json!({
                                                "status": "failed",
                                                "error": ErrorPayload::from(err),
                                            });
                                        }
                                    }
                                }
                                emit(
                                    &event_tx,
                                    "scan.frameState",
                                    FrameStatePayload {
                                        job_id: job_id.clone(),
                                        frame_index: frame_completed.slot,
                                        state: FrameState::Completed,
                                        attempt: 1,
                                        error: manifest_persist_error.as_ref().map(ErrorPayload::from),
                                    },
                                );
                                emit(
                                    &event_tx,
                                    "scan.frameCompleted",
                                    FrameCompletedPayload {
                                        job_id: job_id.clone(),
                                        frame_index: frame_completed.slot,
                                        receipt,
                                    },
                                );
                                remaining.retain(|&frame| frame != frame_completed.slot);
                                completed.push(frame_completed.slot);
                                if capture_plan.private_slots.contains(&frame_completed.slot) {
                                    successful_private_slots.insert(frame_completed.slot);
                                    observed_private_capture_paths.push(std::path::PathBuf::from(&frame_completed.receipt.rgb_path));
                                    if let Some(path) = frame_completed.receipt.ir_path.as_ref() {
                                        observed_private_capture_paths.push(std::path::PathBuf::from(path));
                                    }
                                    if let Some(path) = frame_completed.receipt.meter_rgbi_path.as_ref() {
                                        observed_private_capture_paths.push(std::path::PathBuf::from(path));
                                    }
                                }
                            }
                            Err(err) => {
                                let err = if capture_plan.private_slots.contains(&frame_completed.slot) {
                                    if let Some(working) = capture_plan.private_working_directory.as_ref() {
                                        EngineError::new(
                                            err.code,
                                            format!("{}; {}", err.message, working.recovery_message("derivative rendering failed")),
                                        )
                                        .with_recoverable(err.recoverable())
                                    } else {
                                        err
                                    }
                                } else {
                                    err
                                };
                                if let Ok(mut evidence) = shared_evidence.lock() {
                                    if let Some(frame) = evidence.iter_mut().rev().find(|value| value.frame_index == frame_completed.slot) {
                                        frame.engine_receipt["derivativeOutcome"] = serde_json::json!({
                                            "status": "failed",
                                            "error": ErrorPayload::from(&err),
                                        });
                                    }
                                }
                                emit(
                                    &event_tx,
                                    "scan.frameState",
                                    FrameStatePayload {
                                        job_id: job_id.clone(),
                                        frame_index: frame_completed.slot,
                                        state: FrameState::Failed,
                                        attempt: 1,
                                        error: Some(ErrorPayload::from(&err)),
                                    },
                                );
                                remaining.retain(|&frame| frame != frame_completed.slot);
                                if !failed.contains(&frame_completed.slot) {
                                    failed.push(frame_completed.slot);
                                }
                                if !derivative_failed.contains(&frame_completed.slot) {
                                    derivative_failed.push(frame_completed.slot);
                                }
                            }
                        }
                        sync_progress(&completed, &failed);
                        emit_frame_progress(&completed, &failed, &remaining);
                        last_resolved_at = Some(Instant::now());
                    }
                    "hardware.anomaly" => {
                        // BRIDGE.md's SAFE-02 anomaly halt (10-08: this
                        // event was defined in bridge_protocol.rs but never
                        // matched here — silently dropped by the old
                        // catch-all below). Non-terminal by design: the
                        // SAME worker thread's own `finally` block still
                        // emits this job's authoritative `scan.completed`
                        // moments later, so this arm relays an honest
                        // per-slot (or, if the bridge named no specific
                        // slot, whole-batch) failure now and deliberately
                        // does NOT return — the loop continues to receive
                        // that real terminal event normally. Extracted with
                        // `.pointer()`/`.and_then()` rather than a strict
                        // typed deserialize (mirrors `roll.previewError`'s
                        // own handling in `acquire_thumbnails` above): a
                        // malformed payload must still produce an honest
                        // failure, never a second silent drop.
                        let slot = value
                            .pointer("/payload/slot")
                            .and_then(|v| v.as_u64())
                            .map(|v| v as u32);
                        let code = value
                            .pointer("/payload/code")
                            .and_then(|v| v.as_str())
                            .unwrap_or("INTERNAL")
                            .to_string();
                        let message = value
                            .pointer("/payload/message")
                            .and_then(|v| v.as_str())
                            .unwrap_or("bridge reported a hardware anomaly")
                            .to_string();
                        let ejected = value
                            .pointer("/payload/ejected")
                            .and_then(|v| v.as_bool())
                            .unwrap_or(false);
                        let mapped_code = map_bridge_error_code_str(&code);
                        let error = EngineError::new(
                            mapped_code,
                            format!(
                                "bridge hardware.anomaly ({code}): {message} (scanner {})",
                                if ejected { "ejected" } else { "not ejected" }
                            ),
                        )
                        .with_recoverable(map_bridge_error_code_recoverable(&code));
                        let error_payload = ErrorPayload::from(&error);
                        // Never re-label a frame that already reported
                        // scan.frameCompleted (FrameState has no
                        // Completed -> Failed transition) — only slots
                        // still in `remaining` are eligible.
                        let affected: Vec<u32> = match slot {
                            Some(s) if remaining.contains(&s) => vec![s],
                            Some(_) => vec![],
                            None => remaining.clone(),
                        };
                        for &frame in &affected {
                            emit(
                                &event_tx,
                                "scan.frameState",
                                FrameStatePayload {
                                    job_id: job_id.clone(),
                                    frame_index: frame,
                                    state: FrameState::Failed,
                                    attempt: 1,
                                    error: Some(error_payload.clone()),
                                },
                            );
                        }
                        remaining.retain(|f| !affected.contains(f));
                        for frame in affected {
                            if !failed.contains(&frame) {
                                failed.push(frame);
                            }
                        }
                        sync_progress(&completed, &failed);
                        emit_frame_progress(&completed, &failed, &remaining);
                        last_resolved_at = Some(Instant::now());
                    }
                    "scan.frameFailed" => {
                        // BRIDGE.md "scan.frameFailed (additive,
                        // 2026-07-23)": durable per-frame failure reason.
                        // Non-terminal by design — the SAME worker thread's
                        // own `finally` block still emits this job's
                        // authoritative `scan.completed`, so this arm marks
                        // the named slot failed now and deliberately does
                        // NOT return. Mirrors `hardware.anomaly`'s non-
                        // terminal shape but carries an exact single slot
                        // and the bridge's own code/message (no ejected
                        // flag). Uses loose pointer extraction so a malformed
                        // payload still produces an honest failure rather
                        // than a silent drop.
                        let slot = value
                            .pointer("/payload/slot")
                            .and_then(|v| v.as_u64())
                            .map(|v| v as u32);
                        let code = value
                            .pointer("/payload/code")
                            .and_then(|v| v.as_str())
                            .unwrap_or("INTERNAL")
                            .to_string();
                        let message = value
                            .pointer("/payload/message")
                            .and_then(|v| v.as_str())
                            .unwrap_or("bridge reported a frame failure")
                            .to_string();
                        let mapped_code = map_bridge_error_code_str(&code);
                        let error = EngineError::new(
                            mapped_code,
                            format!("bridge scan.frameFailed ({code}): {message}"),
                        )
                        .with_recoverable(map_bridge_error_code_recoverable(&code));
                        let error_payload = ErrorPayload::from(&error);
                        if let Some(slot) = slot {
                            if remaining.contains(&slot) {
                                emit(
                                    &event_tx,
                                    "scan.frameState",
                                    FrameStatePayload {
                                        job_id: job_id.clone(),
                                        frame_index: slot,
                                        state: FrameState::Failed,
                                        attempt: 1,
                                        error: Some(error_payload),
                                    },
                                );
                                remaining.retain(|&f| f != slot);
                                if !failed.contains(&slot) {
                                    failed.push(slot);
                                }
                            }
                        }
                        sync_progress(&completed, &failed);
                        emit_frame_progress(&completed, &failed, &remaining);
                        last_resolved_at = Some(Instant::now());
                    }
                    "scan.error" => {
                        // BRIDGE.md "scan.error (additive, 2026-07-23)":
                        // dropped by the old catch-all below (10-08 — live
                        // attempt #3, 2026-07-23 evening: the bridge
                        // emitted scan.error naming REFEED_REQUIRED and the
                        // client transcript's last events stayed
                        // scan.jobState{scanning} + scanner.status,
                        // forever). Unlike hardware.anomaly, this arm DOES
                        // treat the signal as immediately terminal: the
                        // engine cannot distinguish, from the wire shape
                        // alone, "the same worker thread is about to emit a
                        // real scan.completed within microseconds" from
                        // "the soft-timeout watchdog is reporting a call
                        // that may never return" — waiting to find out
                        // would defeat the entire point of this event
                        // existing. Reuses emit_terminal_job_failure, the
                        // exact shape the silence watchdog (Err(_) branch
                        // below) has always emitted, then drains any
                        // immediately-following real bridge closure for
                        // this same job so scan.completed still fires
                        // exactly once on the wire.
                        let code = value
                            .pointer("/payload/code")
                            .and_then(|v| v.as_str())
                            .unwrap_or("INTERNAL")
                            .to_string();
                        let message = value
                            .pointer("/payload/message")
                            .and_then(|v| v.as_str())
                            .unwrap_or("bridge reported a scan error")
                            .to_string();
                        let mapped_code = map_bridge_error_code_str(&code);
                        let error = EngineError::new(
                            mapped_code,
                            format!("bridge scan.error ({code}): {message}"),
                        )
                        .with_recoverable(map_bridge_error_code_recoverable(&code));
                        let error_payload = ErrorPayload::from(&error);
                        // `scan.error` is additive, not a terminal bridge
                        // closure. Give its worker a bounded opportunity to
                        // emit the authoritative `scan.completed` before
                        // deciding whether source files are safe to copy.
                        let observed_bridge_terminal =
                            drain_late_bridge_closure_for(&backend, &job_id);
                        let evidence_package_status = if observed_bridge_terminal {
                            let settings = serde_json::json!({
                                "capture": recipe,
                                "processing": processing,
                                "output": output,
                            });
                            let package_finalization = finalize_evidence_status_after_bridge_terminal(
                                &output,
                                &overrides,
                                &capture_plan,
                                &job_id,
                                &shared_evidence,
                                &settings,
                                Some(&error.message),
                            );
                            if let Some(working) = capture_plan.private_working_directory.as_ref() {
                                format!("{}; {}", package_finalization.summary, working.recovery_message("scan.error ended this engine job before derivative/terminal reconciliation"))
                            } else {
                                package_finalization.summary
                            }
                        } else {
                            deferred_evidence_status(
                                &output,
                                &overrides,
                                &capture_plan,
                                "bridge scan.error was not followed by a real scan.completed closure",
                            )
                        };
                        emit_terminal_job_failure(
                            &event_tx,
                            &job_id,
                            &mut remaining,
                            &completed,
                            &mut failed,
                            &error_payload,
                            compute_duty_cycle_report(&idle_samples),
                            Some(evidence_package_status),
                        );
                        sync_progress(&completed, &failed);
                        // 2026-07-25 incident fix (stale SCANNING after a
                        // zero-completed batch): a job that failed via
                        // scan.error left the app showing scanner.status
                        // SCANNING forever, even though the hardware lane
                        // was provably free — this arm returned before the
                        // scan.completed arm below (which DOES poll status)
                        // was ever reached, and used to skip its own poll
                        // unconditionally. It is not always safe to poll
                        // here directly: scan.error can (rarely) correlate
                        // with a genuinely stuck bridge call (the soft-
                        // timeout watchdog case), and a status() request's
                        // own timeout path can itself restart (kill) the
                        // bridge subprocess — the "never kill mid-USB-
                        // transaction" hazard this codepath exists to
                        // avoid. drain_late_bridge_closure_for's return
                        // value distinguishes the two: seeing this job's
                        // own real terminal event during the drain (the
                        // common case — the same worker thread's `finally`
                        // emits its real scan.completed within
                        // microseconds of a BridgeError/bad-summary-shape
                        // failure) proves that worker has already released
                        // the hardware lane, the exact precondition the
                        // scan.completed arm's own unconditional poll below
                        // always relies on — so it is equally safe to poll
                        // here. Seeing nothing (the rare true-watchdog
                        // case: the underlying call may still be in
                        // flight) skips the poll, preserving the original
                        // guarantee.
                        if mapped_code == ErrorCode::NotConnected {
                            backend.invalidate_async_session(
                                session_epoch,
                                &event_tx,
                                None,
                            );
                        } else if observed_bridge_terminal {
                            backend.emit_terminal_status_or_invalidate(
                                session_epoch,
                                bridge_generation,
                                &event_tx,
                                None,
                            );
                        }
                        return;
                    }
                    "scan.completed" => {
                        let Some(payload) = value.get("payload").cloned() else {
                            continue;
                        };
                        let Ok(scan_completed) =
                            serde_json::from_value::<BridgeScanCompletedPayload>(payload)
                        else {
                            continue;
                        };
                        let (completed_after_derivatives, failed_after_derivatives) =
                            reconcile_derivative_failures(
                                scan_completed.summary.completed,
                                scan_completed.summary.failed,
                                &derivative_failed,
                            );
                        // Terminal-only finalization: all successful frame
                        // receipts are already persisted above, so a package
                        // failure never makes a real capture retryable.
                        let settings = serde_json::json!({
                            "capture": recipe,
                            "processing": processing,
                            "output": output,
                        });
                        let package_finalization =
                            finalize_evidence_status_after_bridge_terminal(
                                &output,
                                &overrides,
                                &capture_plan,
                                &job_id,
                                &shared_evidence,
                                &settings,
                                None,
                            );
                        let private_capture_status = finalize_private_capture_workspace(
                            &capture_plan,
                            &completed_after_derivatives,
                            &failed_after_derivatives,
                            &successful_private_slots,
                            &observed_private_capture_paths,
                            &package_finalization,
                        );
                        let evidence_package_status = if capture_plan.private_working_directory.is_some() {
                            format!("{}; {private_capture_status}", package_finalization.summary)
                        } else {
                            package_finalization.summary
                        };
                        emit(
                            &event_tx,
                            "scan.jobState",
                            JobStatePayload {
                                job_id: job_id.clone(),
                                state: JobState::Completed,
                            },
                        );
                        emit(
                            &event_tx,
                            "scan.completed",
                            ScanCompletedPayload {
                                job_id: job_id.clone(),
                                summary: ScanSummary {
                                    completed: completed_after_derivatives,
                                    failed: failed_after_derivatives,
                                    // BRIDGE.md's scan.completed summary
                                    // has no "skipped" list at all — a
                                    // requested-but-unattempted slot is
                                    // simply absent from both arrays.
                                    skipped: vec![],
                                    stopped: scan_completed.summary.stopped,
                                    duty_cycle: compute_duty_cycle_report(&idle_samples),
                                    evidence_package_status: Some(evidence_package_status),
                                },
                            },
                        );
                        backend.emit_terminal_status_or_invalidate(
                            session_epoch,
                            bridge_generation,
                            &event_tx,
                            None,
                        );
                        return;
                    }
                    // Forward compatibility: ignore unknown event names.
                    _ => {}
                }
            }
            Err(_) => {
                let bridge_healthy = backend.bridge.is_healthy();
                let bridge_generation_current = backend.bridge.current_generation();
                let bridge_generation_lost =
                    bridge_generation_current != bridge_generation;
                // Silence while the bridge process is alive is the NORMAL
                // shape of a blocking CoolscanPy fine-scan pass (mirrors
                // acquire_thumbnails's own tolerance — see its doc
                // comment) — keep waiting until the process dies or the
                // rolling deadline above is genuinely exhausted.
                if Instant::now() < silence_deadline
                    && bridge_healthy
                    && !bridge_generation_lost
                {
                    continue;
                }
                // A dead bridge or an exhausted silence deadline is a
                // FAILURE, not a silent hang: report it honestly and mark
                // every not-yet-completed frame failed, then stop —
                // WITHOUT issuing a single further bridge.call() of any
                // kind (including a status refresh) and WITHOUT
                // restarting or otherwise touching the bridge process or
                // its in-flight USB work. HARDWARE-NOTES-20260723.md:
                // "NEVER kill a process mid-USB-transaction: half-read
                // bulk pipes poison subsequent sessions (libusb -8 desync)
                // until power cycle" — BridgeClient::call()'s own timeout
                // path restarts (kills+respawns) the bridge subprocess, so
                // this branch deliberately never calls it again once it
                // has decided to fail the job (recv_event, used above for
                // polling, never triggers a restart on its own timeout —
                // only call() does).
                let ownership_lost = !bridge_healthy || bridge_generation_lost;
                let connection_evidence = format!(
                    "sessionEpoch={session_epoch}; bridgeGenerationStart={bridge_generation}; bridgeGenerationCurrent={bridge_generation_current}; bridgeHealthy={bridge_healthy}"
                );
                let error = if ownership_lost {
                    EngineError::new(
                        ErrorCode::NotConnected,
                        format!(
                            "bridge session ownership was lost asynchronously mid-scan; reconnect required; {connection_evidence}; no device call, automatic open, or motion retry was attempted"
                        ),
                    )
                } else {
                    EngineError::new(
                        ErrorCode::Internal,
                        format!(
                            "bridge event stream stalled mid-scan (BRIDGE_STREAM_STALLED): no scan-scoped event arrived within the silence deadline while the same bridge process remained alive; {connection_evidence}; the bridge process and any in-flight USB work were left untouched, per hardware-safety policy"
                        ),
                    )
                };
                let error_payload = ErrorPayload::from(&error);
                // 10-08: this used to be inlined here directly; now shared
                // with the scan.error arm above via emit_terminal_job_failure
                // so both codepaths emit byte-for-byte the same shape for
                // "the job died, here's who's failed." Behavior is
                // unchanged — see that function's own doc comment.
                emit_terminal_job_failure(
                    &event_tx,
                    &job_id,
                    &mut remaining,
                    &completed,
                    &mut failed,
                    &error_payload,
                    compute_duty_cycle_report(&idle_samples),
                    Some(deferred_evidence_status(
                        &output,
                        &overrides,
                        &capture_plan,
                        "the silence watchdog fired without a real bridge scan.completed closure",
                    )),
                );
                sync_progress(&completed, &failed);
                if ownership_lost {
                    // Pure in-process ownership transition: no device call,
                    // process restart, automatic open, or motion retry.
                    backend.invalidate_async_session(
                        session_epoch,
                        &event_tx,
                        None,
                    );
                }
                return;
            }
        }
    }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn capabilities(capacity: Option<u32>, frame_control: bool) -> BridgeCapabilities {
        BridgeCapabilities {
            ir_channel: true,
            supported_dpi: vec![4000],
            supported_depths: vec![16],
            multi_sample: false,
            adapter_frame_capacity: capacity,
            adapter_frame_control: frame_control,
            auto_exposure: true,
            registered_geometry: true,
            can_eject: true,
            supported_multisample_passes: vec![4],
        }
    }

    #[cfg(target_os = "macos")]
    fn private_cleanup_fixture(
    ) -> (
        PrivateCaptureWorkingDirectory,
        [std::path::PathBuf; 2],
        std::path::PathBuf,
        std::path::PathBuf,
    ) {
        let working = PrivateCaptureWorkingDirectory::create()
            .expect("create isolated private cleanup fixture");
        let capture_paths = ["capture-0001.tif", "capture-0001_IR.tif"]
            .map(|name| working.root.join(name));
        std::fs::write(&capture_paths[0], b"engine-rgb").unwrap();
        std::fs::write(&capture_paths[1], b"engine-ir").unwrap();
        let parent = working.root.parent().expect("workspace parent");
        let quarantine = parent.join(format!(
            ".scanstudio-capture-quarantine-{}",
            working.owner_token
        ));
        let tombstone = parent.join(format!(
            ".scanstudio-capture-tombstone-{}",
            working.owner_token
        ));
        (working, capture_paths, quarantine, tombstone)
    }

    #[cfg(target_os = "macos")]
    fn remove_private_cleanup_fixture(paths: &[&std::path::Path]) {
        for path in paths {
            if path.exists() {
                std::fs::remove_dir_all(path).expect("remove explicit test-owned fixture");
            }
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn quarantine_move_never_replaces_a_raced_same_name_destination() {
        let (working, captures, quarantine, tombstone) = private_cleanup_fixture();
        let result = quarantine_and_retire_known_private_files_with_hook(
            &working,
            &captures,
            |event| {
                if let PrivateCleanupHookEvent::BeforeQuarantineMove { destination, .. } = event {
                    std::fs::create_dir(destination).unwrap();
                    std::fs::write(destination.join("foreign.txt"), b"foreign quarantine").unwrap();
                }
                Ok(())
            },
        );

        let hold = result.expect_err("RENAME_EXCL must reject the raced quarantine");
        assert_eq!(std::fs::read(&captures[0]).unwrap(), b"engine-rgb");
        assert_eq!(
            std::fs::read(quarantine.join("foreign.txt")).unwrap(),
            b"foreign quarantine"
        );
        assert!(hold.roots.contains(&working.root) && hold.roots.contains(&quarantine));
        remove_private_cleanup_fixture(&[&working.root, &quarantine, &tombstone]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn stage_move_never_replaces_a_destination_inserted_immediately_before_move() {
        let (working, captures, quarantine, tombstone) = private_cleanup_fixture();
        let mut injected = false;
        let result = quarantine_and_retire_known_private_files_with_hook(
            &working,
            &captures,
            |event| {
                if let PrivateCleanupHookEvent::BeforeStageMove { destination, .. } = event {
                    if !injected
                        && destination.file_name() == captures[0].file_name()
                    {
                        std::fs::write(destination, b"foreign staging").unwrap();
                        injected = true;
                    }
                }
                Ok(())
            },
        );

        let hold = result.expect_err("atomic no-replace stage move must fail closed");
        assert_eq!(
            std::fs::read(tombstone.join(captures[0].file_name().unwrap())).unwrap(),
            b"foreign staging"
        );
        assert_eq!(
            std::fs::read(quarantine.join(captures[0].file_name().unwrap())).unwrap(),
            b"engine-rgb"
        );
        assert!(hold.roots.contains(&quarantine) && hold.roots.contains(&tombstone));
        remove_private_cleanup_fixture(&[&working.root, &quarantine, &tombstone]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn rollback_move_never_replaces_a_destination_inserted_immediately_before_rollback() {
        let (working, captures, quarantine, tombstone) = private_cleanup_fixture();
        let mut stage_collision = false;
        let mut rollback_collision = false;
        let result = quarantine_and_retire_known_private_files_with_hook(
            &working,
            &captures,
            |event| {
                match event {
                    PrivateCleanupHookEvent::BeforeStageMove { destination, .. }
                        if !stage_collision
                            && destination.file_name() == captures[1].file_name() =>
                    {
                        std::fs::write(destination, b"foreign stage trigger").unwrap();
                        stage_collision = true;
                    }
                    PrivateCleanupHookEvent::BeforeRollbackMove { destination, .. }
                        if !rollback_collision
                            && destination.file_name() == captures[0].file_name() =>
                    {
                        std::fs::write(destination, b"foreign rollback destination").unwrap();
                        rollback_collision = true;
                    }
                    _ => {}
                }
                Ok(())
            },
        );

        let hold = result.expect_err("rollback collision must preserve both identities");
        assert_eq!(
            std::fs::read(quarantine.join(captures[0].file_name().unwrap())).unwrap(),
            b"foreign rollback destination"
        );
        assert_eq!(
            std::fs::read(tombstone.join(captures[0].file_name().unwrap())).unwrap(),
            b"engine-rgb"
        );
        assert_eq!(
            std::fs::read(tombstone.join(captures[1].file_name().unwrap())).unwrap(),
            b"foreign stage trigger"
        );
        assert!(
            hold.describe().contains("rollback no-replace")
                && hold.roots.contains(&quarantine)
                && hold.roots.contains(&tombstone),
            "every rollback ambiguity and held root must be reported: {hold:#?}"
        );
        remove_private_cleanup_fixture(&[&working.root, &quarantine, &tombstone]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn substituted_known_source_is_preserved_and_never_moved_or_deleted() {
        let (working, captures, quarantine, tombstone) = private_cleanup_fixture();
        let backup = quarantine.join("engine-source-original.tif");
        let mut injected = false;
        let result = quarantine_and_retire_known_private_files_with_hook(
            &working,
            &captures,
            |event| {
                if let PrivateCleanupHookEvent::BeforeStageMove { source, .. } = event {
                    if !injected && source.file_name() == captures[0].file_name() {
                        std::fs::rename(source, &backup).unwrap();
                        std::fs::write(source, b"foreign source replacement").unwrap();
                        injected = true;
                    }
                }
                Ok(())
            },
        );

        let hold = result.expect_err("source identity mismatch must fail closed");
        assert_eq!(std::fs::read(&backup).unwrap(), b"engine-rgb");
        assert_eq!(
            std::fs::read(quarantine.join(captures[0].file_name().unwrap())).unwrap(),
            b"foreign source replacement"
        );
        assert!(hold.roots.contains(&quarantine));
        remove_private_cleanup_fixture(&[&working.root, &quarantine, &tombstone]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn replacement_inserted_immediately_before_final_delete_is_never_unlinked_or_truncated() {
        let (working, captures, quarantine, tombstone) = private_cleanup_fixture();
        let backup = tombstone.join("engine-final-original.tif");
        let mut injected = false;
        let result = quarantine_and_retire_known_private_files_with_hook(
            &working,
            &captures,
            |event| {
                if let PrivateCleanupHookEvent::BeforeFinalDelete { path } = event {
                    if !injected && path.file_name() == captures[0].file_name() {
                        std::fs::rename(path, &backup).unwrap();
                        std::fs::write(path, b"foreign final replacement").unwrap();
                        injected = true;
                    }
                }
                Ok(())
            },
        );

        let hold = result.expect_err("final identity mismatch must preserve both files");
        assert_eq!(std::fs::read(&backup).unwrap(), b"engine-rgb");
        assert_eq!(
            std::fs::read(tombstone.join(captures[0].file_name().unwrap())).unwrap(),
            b"foreign final replacement"
        );
        assert_eq!(
            std::fs::read(tombstone.join(captures[1].file_name().unwrap())).unwrap(),
            b"engine-ir",
            "cleanup aborts before touching later engine identities"
        );
        assert!(
            hold.roots.contains(&quarantine) && hold.roots.contains(&tombstone),
            "every actual engine capture root must be reported: {hold:#?}"
        );
        remove_private_cleanup_fixture(&[&working.root, &quarantine, &tombstone]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn late_unknown_file_directory_and_symlink_are_preserved_before_retirement() {
        #[derive(Debug, Clone, Copy)]
        enum LateEntry {
            File,
            Directory,
            Symlink,
        }

        for late_entry in [LateEntry::File, LateEntry::Directory, LateEntry::Symlink] {
            let (working, captures, quarantine, tombstone) = private_cleanup_fixture();
            let outside_target = quarantine
                .parent()
                .unwrap()
                .join(format!("foreign-target-{}", working.owner_token));
            if matches!(late_entry, LateEntry::Symlink) {
                std::fs::write(&outside_target, b"foreign target").unwrap();
            }
            let result = quarantine_and_retire_known_private_files_with_hook(
                &working,
                &captures,
                |event| {
                    if let PrivateCleanupHookEvent::BeforeQuarantineSeal { quarantine } = event {
                        match late_entry {
                            LateEntry::File => {
                                std::fs::write(quarantine.join("late.txt"), b"foreign file")
                                    .unwrap();
                            }
                            LateEntry::Directory => {
                                let directory = quarantine.join("late-directory");
                                std::fs::create_dir(&directory).unwrap();
                                std::fs::write(directory.join("keep.txt"), b"foreign directory")
                                    .unwrap();
                            }
                            LateEntry::Symlink => {
                                std::os::unix::fs::symlink(
                                    &outside_target,
                                    quarantine.join("late-link"),
                                )
                                .unwrap();
                            }
                        }
                    }
                    Ok(())
                },
            );

            let hold = result.expect_err("an unknown quarantine entry must preserve all identities");
            assert_eq!(
                std::fs::read(quarantine.join(captures[0].file_name().unwrap())).unwrap(),
                b"engine-rgb"
            );
            assert_eq!(
                std::fs::read(quarantine.join(captures[1].file_name().unwrap())).unwrap(),
                b"engine-ir"
            );
            match late_entry {
                LateEntry::File => {
                    assert_eq!(std::fs::read(quarantine.join("late.txt")).unwrap(), b"foreign file");
                }
                LateEntry::Directory => {
                    assert_eq!(
                        std::fs::read(quarantine.join("late-directory/keep.txt")).unwrap(),
                        b"foreign directory"
                    );
                }
                LateEntry::Symlink => {
                    let link = quarantine.join("late-link");
                    assert!(std::fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
                    assert_eq!(std::fs::read(&outside_target).unwrap(), b"foreign target");
                }
            }
            assert!(
                hold.roots.contains(&quarantine) && hold.roots.contains(&tombstone),
                "all held engine roots must be reported: {hold:#?}"
            );
            remove_private_cleanup_fixture(&[&working.root, &quarantine, &tombstone]);
            if outside_target.exists() {
                std::fs::remove_file(outside_target).unwrap();
            }
        }
    }

    #[test]
    fn detects_every_supported_mechanical_holder_capacity() {
        for (capacity, frame_control, adapter, carrier) in [
            (1, false, "MA-21", MediaCarrier::Mounted),
            (1, true, "MA-21", MediaCarrier::Mounted),
            (2, true, "SA-21", MediaCarrier::Strip6),
            (6, true, "SA-21", MediaCarrier::Strip6),
            (7, true, "SA-30", MediaCarrier::Roll36),
            (40, true, "SA-30", MediaCarrier::Roll36),
        ] {
            assert_eq!(
                derive_detected_holder(&capabilities(Some(capacity), frame_control)),
                Some(DetectedHolder { adapter, carrier }),
                "capacity {capacity}, frame control {frame_control}"
            );
        }
    }

    #[test]
    fn holder_detection_fails_closed_for_unknown_or_inconsistent_capabilities() {
        for (capacity, frame_control) in [
            (None, false),
            (None, true),
            (Some(0), false),
            (Some(2), false),
            (Some(6), false),
            (Some(7), false),
            (Some(40), false),
            (Some(41), true),
        ] {
            assert_eq!(
                derive_detected_holder(&capabilities(capacity, frame_control)),
                None,
                "capacity {capacity:?}, frame control {frame_control}"
            );
        }
    }

    #[test]
    fn status_overlays_a_known_holder_without_changing_media_loaded_semantics() {
        let bridge_status = BridgeDeviceStatus {
            connected: true,
            device_id: Some("coolscan3:usb:libusb:000:013".to_string()),
            preview_established: false,
            slot_count: Some(39),
            active_job_id: None,
            lane_held: false,
            motion_armed: false,
            film_present: Some(true),
        };
        let holder = derive_detected_holder(&capabilities(Some(40), true));
        let status = map_status(&bridge_status, holder);

        assert_eq!(status.adapter.as_deref(), Some("SA-30"));
        assert_eq!(status.carrier, Some(MediaCarrier::Roll36));
        assert!(
            !status.media_loaded,
            "holder identity must not claim a preview"
        );
        assert_eq!(
            status.frame_count, None,
            "adapter capacity/slot observations must not become an exposure count before preview"
        );

        let preview_established = map_status(
            &BridgeDeviceStatus {
                preview_established: true,
                ..bridge_status.clone()
            },
            holder,
        );
        assert_eq!(
            preview_established.frame_count,
            Some(39),
            "the successful preview is the sole source of the actual count"
        );

        let disconnected = map_status(
            &BridgeDeviceStatus {
                connected: false,
                ..bridge_status
            },
            holder,
        );
        assert_eq!(disconnected.adapter, None);
        assert_eq!(disconnected.carrier, None);
    }

    #[test]
    fn completed_preview_retains_its_count_when_holder_identity_is_unavailable() {
        let bridge_status = BridgeDeviceStatus {
            connected: true,
            device_id: Some("coolscan3:usb:libusb:002:007".to_string()),
            preview_established: true,
            slot_count: Some(6),
            active_job_id: None,
            lane_held: false,
            motion_armed: true,
            film_present: None,
        };

        let status = map_status(&bridge_status, None);

        assert!(status.media_loaded, "only the completed preview establishes media");
        assert_eq!(status.frame_count, Some(6));
        assert_eq!(status.adapter, None, "a count must not invent a holder");
        assert_eq!(status.carrier, None, "a count must not invent a carrier");

        let before_preview = map_status(
            &BridgeDeviceStatus {
                preview_established: false,
                ..bridge_status
            },
            None,
        );
        assert_eq!(before_preview.frame_count, None);
    }

    #[test]
    fn unknown_holder_preview_count_respects_ls5000_physical_boundaries() {
        for count in [1, 40] {
            assert_eq!(
                preview_frame_count_for_holder(true, Some(count), None),
                Some(count),
                "a completed unknown-holder preview may retain {count} frame(s)"
            );
        }
        for count in [0, 41] {
            assert_eq!(
                preview_frame_count_for_holder(true, Some(count), None),
                None,
                "an impossible unknown-holder preview count must fail closed"
            );
        }
        assert_eq!(
            preview_frame_count_for_holder(false, Some(1), None),
            None,
            "a holder-less capacity observation before preview is not a frame count"
        );
    }

    #[test]
    fn status_fails_closed_for_preview_counts_inconsistent_with_detected_holder() {
        let cases = [
            (Some(1), false, 2, "MA-21 only supports one mounted frame"),
            (
                Some(6),
                true,
                7,
                "SA-21 cannot preview more than six frames",
            ),
            (
                Some(40),
                true,
                41,
                "SA-30 cannot preview more than forty frames",
            ),
        ];

        for (capacity, frame_control, slot_count, description) in cases {
            let status = map_status(
                &BridgeDeviceStatus {
                    connected: true,
                    device_id: Some("coolscan3:usb:libusb:000:013".to_string()),
                    preview_established: true,
                    slot_count: Some(slot_count),
                    active_job_id: None,
                    lane_held: false,
                    motion_armed: false,
                    film_present: Some(true),
                },
                derive_detected_holder(&capabilities(capacity, frame_control)),
            );
            assert_eq!(status.frame_count, None, "{description}");
        }
    }

    #[test]
    fn bw_preproject_preview_uses_the_bridge_black_and_white_material() {
        assert_eq!(
            map_material(FilmProcess::BwNegative),
            BridgeMaterial::BlackAndWhiteNegative
        );
    }

    /// Live 2026-07-25 regression: a 34-frame batch (slots 5-38) showed
    /// "Frame 37 of 38" while the scanner was on slot 17, the batch's 13th
    /// frame — the session-journal's own `active_frame_index`. 13 resolved
    /// frames (12 completed, 0 failed) means frame 13 is the one now
    /// active, matching that ground truth exactly; it must never be
    /// derived from the bridge's upfront `scan.progress` burst (see this
    /// function's own doc comment).
    #[test]
    fn compute_frame_ordinal_matches_session_journal_active_frame_index() {
        let completed: Vec<u32> = (5..17).collect(); // slots 5..16: 12 completed
        assert_eq!(completed.len(), 12);
        assert_eq!(compute_frame_ordinal(&completed, &[], 34), 13);
    }

    #[test]
    fn compute_frame_ordinal_starts_at_one_before_any_frame_resolves() {
        assert_eq!(compute_frame_ordinal(&[], &[], 34), 1);
    }

    #[test]
    fn compute_frame_ordinal_counts_failed_frames_as_resolved_too() {
        // 10 completed + 2 failed = 12 resolved -> frame 13 is now active,
        // regardless of which of the 12 succeeded vs failed.
        let completed: Vec<u32> = (1..=10).collect();
        let failed = vec![11, 12];
        assert_eq!(compute_frame_ordinal(&completed, &failed, 34), 13);
    }

    #[test]
    fn compute_frame_ordinal_caps_at_total_once_every_frame_is_resolved() {
        let completed: Vec<u32> = (1..=34).collect();
        assert_eq!(compute_frame_ordinal(&completed, &[], 34), 34);
    }

    #[test]
    fn split_command_separates_program_from_args() {
        let (program, args) = split_command("scanstudio-bridge --verbose").unwrap();
        assert_eq!(program, "scanstudio-bridge");
        assert_eq!(args, vec!["--verbose"]);
    }

    #[test]
    fn split_command_preserves_an_existing_executable_path_with_spaces() {
        let executable = std::env::temp_dir().join(format!(
            "scanstudio bridge path {}",
            std::process::id()
        ));
        std::fs::write(&executable, "#!/bin/sh\nexit 0\n").expect("fixture executable");

        let command = executable.to_str().expect("utf-8 fixture path");
        let (program, args) = split_command(command).expect("existing path parses");
        assert_eq!(program, command);
        assert!(args.is_empty());
        std::fs::remove_file(executable).expect("remove fixture executable");
    }

    #[test]
    fn map_bridge_error_code_recoverable_matches_bridge_md_policy() {
        assert!(
            map_bridge_error_code_recoverable("HARDWARE_LANE_BUSY"),
            "HARDWARE_LANE_BUSY is the only recoverable bridge code"
        );
        for code in [
            "REFEED_REQUIRED",
            "MANUAL_REVIEW_REQUIRED",
            "FEEDER_PARKED",
            "TRANSPORT_SMEAR_DETECTED",
            "FINGERPRINT_REFUSED",
            "DEVICE_BUSY",
            "INTERNAL",
            "SOME_FUTURE_CODE_NOT_YET_INVENTED",
        ] {
            assert!(
                !map_bridge_error_code_recoverable(code),
                "{code} must not be recoverable"
            );
        }
    }

    #[test]
    fn film_feed_interrupted_bridge_code_is_typed_not_internal() {
        assert_eq!(
            map_bridge_error_code_str("FILM_FEED_INTERRUPTED"),
            ErrorCode::FilmFeedInterrupted
        );
        assert!(!map_bridge_error_code_recoverable(
            "FILM_FEED_INTERRUPTED"
        ));
    }

    #[test]
    fn split_command_handles_bare_program_with_no_args() {
        let (program, args) = split_command("scanstudio-bridge").unwrap();
        assert_eq!(program, "scanstudio-bridge");
        assert!(args.is_empty());
    }

    #[test]
    fn split_command_rejects_empty_or_whitespace_only_input() {
        assert!(split_command("").is_none());
        assert!(split_command("   ").is_none());
    }

    /// Defect 8 (2026-07-25): the real archive file landed on disk as
    /// `Archive_0007` with no extension while its `_IR.tif`/`_METER.tif`
    /// siblings had one. `default_archive_filename_template()`'s
    /// `"Archive_####"` has never carried an extension, and the bridge's
    /// template resolver is deliberately format-agnostic — so the real
    /// backend must ensure one itself before the wire call.
    #[test]
    fn ensure_archive_extension_appends_tif_when_the_template_has_none() {
        assert_eq!(ensure_archive_extension("Archive_####"), "Archive_####.tif");
    }

    #[test]
    fn ensure_archive_extension_leaves_an_already_extensioned_template_alone() {
        assert_eq!(ensure_archive_extension("Archive_####.tif"), "Archive_####.tif");
        assert_eq!(ensure_archive_extension("MyArchive_####.tiff"), "MyArchive_####.tiff");
    }

    #[test]
    fn ensure_archive_extension_does_not_mistake_a_dotted_lens_for_a_tiff_suffix() {
        assert_eq!(
            ensure_archive_extension("KodakGold200-Canon7E-EF50mmF1.8STM-####"),
            "KodakGold200-Canon7E-EF50mmF1.8STM-####.tif"
        );
    }

    #[test]
    fn bridge_archive_template_preserves_a_reserved_exact_sequence_name() {
        assert_eq!(
            bridge_archive_template("ScanStudio$ScanStudioSequence(3)"),
            "ScanStudio$ScanStudioSequence(3).tif"
        );
    }

    #[test]
    fn build_scan_start_params_sends_an_extensioned_archive_template_to_the_bridge() {
        let recipe = CaptureRecipe::default();
        let processing = ProcessingRecipe::default();
        let output = OutputRecipe::default();

        let params = build_scan_start_params(vec![7], &recipe, &processing, &output, None);

        assert_eq!(params.output.filename_template, "ScanStudio#.tif");
    }

    #[test]
    fn no_hash_real_archive_template_keeps_bridge_and_receipt_path_identical() {
        let destination = std::env::temp_dir().join(format!(
            "scanstudio-no-hash-receipt-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock after Unix epoch")
                .as_nanos()
        ));
        std::fs::create_dir_all(&destination).expect("create receipt test directory");
        let mut output = OutputRecipe::default();
        output.archive.destination = destination.display().to_string();
        output.archive.filename_template = "Archive".into();

        let params = build_scan_start_params(
            vec![7],
            &CaptureRecipe::default(),
            &ProcessingRecipe::default(),
            &output,
            None,
        );
        assert_eq!(params.output.filename_template, "Archive_####.tif");

        let bridge_name = crate::render::resolve_filename(&params.output.filename_template, 7);
        let receipt_path = crate::render::resolve_archive_output_path(&output, 7);
        let receipt_name = receipt_path
            .file_name()
            .and_then(|value| value.to_str())
            .expect("resolved archive path has a UTF-8 filename");
        assert_eq!(bridge_name, "Archive_0007.tif");
        assert_eq!(bridge_name, receipt_name);
        let bridge_path = destination.join(&bridge_name);
        std::fs::write(&bridge_path, b"bridge capture fixture")
            .expect("write bridge receipt fixture");
        crate::render::validate_bridge_capture_receipt_paths(
            &output,
            7,
            Channels::Rgb,
            &bridge_path,
            None,
            None,
        )
        .expect("the real receipt path must match the engine's reserved archive path");
        std::fs::remove_dir_all(destination).expect("remove receipt test directory");
    }

    #[test]
    fn tokenized_real_scan_templates_resolve_to_distinct_bridge_paths_per_slot() {
        let mut output = OutputRecipe::default();
        output.archive.filename_template = "$FilmStock-$Frame".to_string();
        let metadata = crate::domain::MetadataSet {
            film_stock: Some("Kodak Gold 200".to_string()),
            ..Default::default()
        };
        crate::render::materialize_output_filename_tokens(&mut output, &metadata);
        let params = build_scan_start_params(
            vec![1, 2],
            &CaptureRecipe::default(),
            &ProcessingRecipe::default(),
            &output,
            None,
        );

        assert_eq!(params.output.filename_template, "KodakGold200-####.tif");
        assert_eq!(
            crate::render::resolve_filename(&params.output.filename_template, 1),
            "KodakGold200-0001.tif"
        );
        assert_eq!(
            crate::render::resolve_filename(&params.output.filename_template, 2),
            "KodakGold200-0002.tif"
        );
    }

    #[test]
    fn real_batch_sends_per_slot_templates_only_when_metadata_output_differs() {
        let output = OutputRecipe::default();
        let mut per_frame = output.clone();
        per_frame.archive.filename_template = "KodakGold200-Canon7E-####".into();
        per_frame.archive.destination = "/B".into();
        let mut overrides = std::collections::HashMap::new();
        overrides.insert(2, domain::FrameOverrides { output: Some(per_frame), ..Default::default() });
        let templates = bridge_slot_outputs(&[1, 2], &output, &overrides);
        let params = build_scan_start_params(
            vec![1, 2], &CaptureRecipe::default(), &ProcessingRecipe::default(), &output, templates,
        );
        assert_eq!(params.output.slot_outputs.as_ref().unwrap().get("1").unwrap().filename_template, "ScanStudio#.tif");
        assert_eq!(params.output.slot_outputs.as_ref().unwrap().get("2").unwrap().filename_template, "KodakGold200-Canon7E-####.tif");
        assert_eq!(params.output.slot_outputs.as_ref().unwrap().get("2").unwrap().destination, "/B");
    }

    #[test]
    fn no_hash_real_batch_slot_outputs_match_dotted_engine_receipt_paths() {
        let mut output = OutputRecipe::default();
        output.archive.destination = "/A".into();
        output.archive.filename_template = "Roll.v1.tiff".into();
        let mut per_frame = output.clone();
        per_frame.archive.destination = "/B".into();
        per_frame.archive.filename_template = "Roll.v2.TiF".into();
        let mut overrides = std::collections::HashMap::new();
        overrides.insert(
            2,
            domain::FrameOverrides {
                output: Some(per_frame.clone()),
                ..Default::default()
            },
        );

        let slot_outputs = bridge_slot_outputs(&[1, 2], &output, &overrides)
            .expect("different per-frame output requires an exact slot map");
        let first = slot_outputs.get("1").expect("slot 1 output");
        let second = slot_outputs.get("2").expect("slot 2 output");
        assert_eq!(first.filename_template, "Roll.v1_####.tiff");
        assert_eq!(second.filename_template, "Roll.v2_####.TiF");

        let first_bridge_path = std::path::Path::new(&first.destination)
            .join(crate::render::resolve_filename(&first.filename_template, 1));
        let second_bridge_path = std::path::Path::new(&second.destination).join(
            crate::render::resolve_filename(&second.filename_template, 2),
        );
        assert_eq!(
            first_bridge_path,
            crate::render::resolve_archive_output_path(&output, 1)
        );
        assert_eq!(
            second_bridge_path,
            crate::render::resolve_archive_output_path(&per_frame, 2)
        );
        assert_ne!(first_bridge_path, second_bridge_path);
    }

    /// 11-01: directly exercises the same panic-safety pattern the worker
    /// thread uses — a caught panic must still emit an honest terminal
    /// `scan.jobState{Failed}` + `scan.completed` reflecting the progress
    /// captured before the panic, never perpetual silence.
    #[test]
    fn scan_worker_panic_safety_net_emits_terminal_events_with_known_progress() {
        let (event_tx, event_rx) = mpsc::channel::<String>();
        let job_id = "panic-test-job".to_string();
        let frames = vec![1u32, 2];
        let shared_progress: Arc<Mutex<(Vec<u32>, Vec<u32>)>> =
            Arc::new(Mutex::new((vec![1], vec![])));

        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            panic!("test-injected panic");
        }));

        assert!(result.is_err(), "the injected panic must be caught");

        let (known_completed, known_failed) = shared_progress
            .lock()
            .map(|guard| (guard.0.clone(), guard.1.clone()))
            .unwrap_or_else(|poisoned| {
                let guard = poisoned.into_inner();
                (guard.0.clone(), guard.1.clone())
            });
        let mut remaining: Vec<u32> = frames
            .into_iter()
            .filter(|f| !known_completed.contains(f) && !known_failed.contains(f))
            .collect();
        let mut failed = known_failed;
        let error = EngineError::new(
            ErrorCode::Internal,
            "scan worker thread panicked unexpectedly; frame outcome for this slot is unknown",
        );
        let error_payload = ErrorPayload::from(&error);
        emit_terminal_job_failure(
            &event_tx,
            &job_id,
            &mut remaining,
            &known_completed,
            &mut failed,
            &error_payload,
            None,
            None,
        );
        drop(event_tx);

        let events: Vec<Value> = event_rx.into_iter()
            .map(|line| serde_json::from_str(&line).expect("valid JSON"))
            .collect();

        let frame_state_failed = events
            .iter()
            .find(|event| event["event"] == "scan.frameState" && event["payload"]["state"] == "failed")
            .expect("expected scan.frameState(failed) for the unknown slot");
        assert_eq!(frame_state_failed["payload"]["frameIndex"], json!(2));

        let job_state_failed = events
            .iter()
            .find(|event| event["event"] == "scan.jobState" && event["payload"]["state"] == "failed")
            .expect("expected scan.jobState(failed)");
        assert_eq!(job_state_failed["payload"]["jobId"], json!("panic-test-job"));

        let completed_event = events
            .iter()
            .find(|event| event["event"] == "scan.completed")
            .expect("expected scan.completed");
        assert_eq!(
            completed_event["payload"]["summary"]["completed"],
            json!([1])
        );
        assert_eq!(
            completed_event["payload"]["summary"]["failed"],
            json!([2])
        );
    }

    #[test]
    fn compute_duty_cycle_report_returns_none_for_empty_samples() {
        assert_eq!(compute_duty_cycle_report(&[]), None);
    }

    #[test]
    fn compute_duty_cycle_report_calculates_mean_and_max() {
        let samples = vec![
            FrameIdleSample {
                frame_index: 2,
                idle_ms: 100,
            },
            FrameIdleSample {
                frame_index: 3,
                idle_ms: 300,
            },
        ];
        let report = compute_duty_cycle_report(&samples).expect("expected a report");
        assert_eq!(report.per_frame_idle_ms, samples);
        assert_eq!(report.max_idle_ms, 300);
        assert_eq!(report.mean_idle_ms, 200.0);
    }

    #[test]
    fn derivative_failures_cannot_be_relabelled_completed_by_bridge_summary() {
        let (completed, failed) =
            reconcile_derivative_failures(vec![14, 17], vec![22], &[17, 22]);

        assert_eq!(completed, vec![14]);
        assert_eq!(failed, vec![22, 17]);
    }
}
