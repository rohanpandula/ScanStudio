//! Integration tests proving `RealLs5000`'s full `ScannerBackend` mapping
//! against the real `mock_bridge` subprocess from Plan 09-01 — a real
//! subprocess boundary, not an in-memory fake. Covers Plan 09-03's Task
//! 2 method-by-method BRIDGE.md translation, including the crash-mid-scan
//! recoverable-retry path and the device-sourced multisample-passes
//! validation.

use std::sync::{
    atomic::{AtomicU64, Ordering},
    mpsc, Arc,
};
use std::time::{Duration, Instant};

use scanstudio_engine::domain::{self, ScannerBackend};
use scanstudio_engine::protocol::{ConnectOptions, ErrorCode, StopMode};
use scanstudio_engine::real_backend::RealLs5000;

const DEVICE_ID: &str = "bridge-ls5000-0";

fn mock_bridge_bin() -> &'static str {
    env!("CARGO_BIN_EXE_mock_bridge")
}

/// Generous request timeout, matching `tests/bridge_client.rs`'s own
/// `GENEROUS_TIMEOUT` precedent: this suite runs alongside other
/// concurrently-spawning test binaries (and, in this repo, other agents'
/// builds/tests running at the same time per 09-02-SUMMARY's documented
/// flakiness finding) — a tight timeout would make correctness assertions
/// flaky under system load rather than actually exercising anything this
/// plan owns. `MOCK_BRIDGE_CRASH_ON` resolves almost instantly regardless
/// of the configured ceiling (an immediate process death, not a hang), so
/// a generous timeout costs nothing even in the crash test below.
const GENEROUS_TIMEOUT: Duration = Duration::from_secs(3);

/// `CaptureRecipe` with a `multisamplePasses` value this device actually
/// accepts. `CaptureRecipe::default()` has `multisample_passes: 1`, which
/// `RealLs5000::scan_start` now rejects (device-sourced validation —
/// see `scan_start_rejects_multisample_passes_other_than_device_supported`
/// below) — every other test that exercises `scan_start` against a
/// healthy bridge must use this instead of the bare default.
fn valid_capture_recipe() -> domain::CaptureRecipe {
    domain::CaptureRecipe {
        multisample_passes: 4,
        ..domain::CaptureRecipe::default()
    }
}

/// Routes every artifact produced by a mapping test into a newly reserved
/// test-owned directory. In particular, no `OutputRecipe::default()` path
/// may reach the user's `~/ScanStudio Projects/_Unfiled` tree.
fn isolated_output_recipe() -> domain::OutputRecipe {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    let root = loop {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "scanstudio-real-mapping-output-{}-{id}",
            std::process::id()
        ));
        match std::fs::create_dir(&path) {
            Ok(()) => break path,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => panic!(
                "reserve unique mapping-test output directory {}: {error}",
                path.display()
            ),
        }
    };
    let mut output = domain::OutputRecipe::default();
    output.archive.destination = root.join("Archive").display().to_string();
    output.raw_export.destination = root.join("Raw Negative").display().to_string();
    output.positive.destination = root.join("Positive").display().to_string();
    output.preview.destination = root.join("Preview").display().to_string();
    output
}

/// Collects parsed event JSON values from `rx` until one whose `"event"`
/// field equals `until_event` is seen (inclusive of that event), each
/// `recv` bounded by `timeout`. Panics with a clear message (including
/// everything collected so far) if `timeout` is exceeded before the
/// target event arrives.
fn drain_events(
    rx: &mpsc::Receiver<String>,
    until_event: &str,
    timeout: Duration,
) -> Vec<serde_json::Value> {
    let mut events = Vec::new();
    loop {
        let line = rx.recv_timeout(timeout).unwrap_or_else(|_| {
            panic!("timed out waiting for event '{until_event}'; collected so far: {events:#?}")
        });
        let value: serde_json::Value = serde_json::from_str(&line).expect("event json");
        let is_target = value["event"] == until_event;
        events.push(value);
        if is_target {
            break;
        }
    }
    events
}

#[cfg(unix)]
#[test]
fn full_capture_package_symlink_collision_is_refused_before_scan_start() {
    use std::os::unix::fs::symlink;

    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let call_log_path = std::env::temp_dir().join(format!(
        "scanstudio-evidence-premotion-call-log-{}-{nonce}",
        std::process::id()
    ));
    std::fs::write(&call_log_path, "").expect("create mock bridge call log");
    let call_log = call_log_path.display().to_string();
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_CALL_LOG", call_log.as_str())],
        )
        .expect("healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect before local evidence preflight");

    let root = std::env::temp_dir().join(format!(
        "scanstudio-evidence-premotion-{}-{nonce}",
        std::process::id()
    ));
    let archive = root.join("Archive");
    let outside = root.join("outside");
    std::fs::create_dir_all(&archive).unwrap();
    std::fs::create_dir(&outside).unwrap();
    let sentinel = outside.join("sentinel.txt");
    std::fs::write(&sentinel, b"outside unchanged").unwrap();
    symlink(&outside, archive.join("Capture Evidence")).unwrap();

    let mut output = domain::OutputRecipe::default();
    output.archive.destination = archive.display().to_string();
    output.archive.full_capture_package = true;
    output.positive.enabled = false;
    output.preview.enabled = false;
    output.raw_export.enabled = false;

    // Exclude connect/device-open setup calls. Everything after this reset is
    // attributable to the scan request under test.
    std::fs::write(&call_log_path, "").expect("reset mock bridge call log");
    let (tx, _rx) = mpsc::channel();
    let error = RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        output,
        std::collections::HashMap::new(),
        Some(root.clone()),
        tx,
    )
    .expect_err("a planted Capture Evidence symlink must fail before motion dispatch");

    assert_eq!(error.code, ErrorCode::InvalidParams, "{error:?}");
    assert_eq!(std::fs::read(&sentinel).unwrap(), b"outside unchanged");
    assert_eq!(
        std::fs::read_to_string(&call_log_path)
            .unwrap()
            .lines()
            .filter(|method| *method == "scan.start")
            .count(),
        0,
        "local evidence authority refusal must send zero scan.start calls"
    );
    assert!(
        std::fs::read_dir(&outside)
            .unwrap()
            .all(|entry| entry.unwrap().path() == sentinel),
        "the planted link target must receive no package or probe writes"
    );

    let _ = std::fs::remove_file(archive.join("Capture Evidence"));
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_file(call_log_path);
}

/// Retries `op` while it returns `ScannerBusy`, up to `deadline`, then
/// panics with the last error. For asserting that a background drain
/// EVENTUALLY unblocks an operation: a fixed sleep before the attempt
/// races the drain worker on loaded CI runners (two main-branch flakes,
/// 2026-08-09), while polling keeps the same contract without the race.
/// Any error other than `ScannerBusy` fails immediately.
fn retry_while_busy<T>(
    what: &str,
    deadline: Duration,
    mut op: impl FnMut() -> Result<T, domain::EngineError>,
) -> T {
    let started = Instant::now();
    loop {
        match op() {
            Ok(value) => return value,
            Err(error) if error.code == ErrorCode::ScannerBusy => {
                if started.elapsed() > deadline {
                    panic!("{what} still busy after {deadline:?}: {error:?}");
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(error) => panic!("{what} failed with a non-busy error: {error:?}"),
        }
    }
}

/// Collects every event that arrives within `duration`, without waiting
/// for any specific target event — used by the crash test below, where
/// the exact event sequence isn't pinned down (per Plan 09-03's own
/// framing: "the crash path emits `scan.frameState{Failed}` before
/// anything else").
fn drain_events_for(rx: &mpsc::Receiver<String>, duration: Duration) -> Vec<serde_json::Value> {
    let deadline = std::time::Instant::now() + duration;
    let mut events = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match rx.recv_timeout(remaining) {
            Ok(line) => {
                if let Ok(value) = serde_json::from_str(&line) {
                    events.push(value);
                }
            }
            Err(_) => break,
        }
    }
    events
}

#[test]
fn connect_and_status_round_trip_through_bridge() {
    let backend = RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
        .expect("RealLs5000::new should succeed against a healthy mock bridge");

    let result = backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed against the mock bridge's own fixed device id");
    assert!(result.status.connected);

    let status = backend
        .status()
        .expect("status should succeed once connected");
    assert!(status.connected);
}

/// `device.list` advertises the mock's default SA-30-compatible capacity,
/// while `device.open` below supplies a fresh SA-21 capacity. This proves a
/// holder changed while disconnected is classified from the authoritative
/// open result, then retained for later fresh-status mappings.
#[test]
fn connect_refreshes_holder_detection_from_open_capabilities() {
    let backend = RealLs5000::new_with_env(
        mock_bridge_bin(),
        GENEROUS_TIMEOUT,
        &[
            ("MOCK_BRIDGE_OPEN_ADAPTER_FRAME_CAPACITY", "6"),
            ("MOCK_BRIDGE_OPEN_ADAPTER_FRAME_CONTROL", "true"),
        ],
    )
    .expect("RealLs5000::new should succeed against the mock bridge");

    let connected = backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");
    assert_eq!(connected.status.adapter.as_deref(), Some("SA-21"));
    assert_eq!(connected.status.carrier, Some(domain::MediaCarrier::Strip6));
    assert!(
        !connected.status.media_loaded,
        "holder detection must not fabricate a preview-established media state"
    );

    let status = backend.status().expect("fresh status should succeed");
    assert_eq!(status.adapter.as_deref(), Some("SA-21"));
    assert_eq!(status.carrier, Some(domain::MediaCarrier::Strip6));
}

#[test]
fn connect_unknown_device_id_maps_to_unknown_device() {
    let backend = RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
        .expect("RealLs5000::new should succeed against a healthy mock bridge");

    // mock_bridge's device.open rejects any deviceId other than its own
    // fixed DEVICE_ID with DEVICE_NOT_FOUND — proving map_bridge_error's
    // DEVICE_NOT_FOUND -> UnknownDevice row from the mapping table.
    let err = backend
        .connect("not-a-real-id", &ConnectOptions::default())
        .expect_err("connecting an unknown device id must fail");
    assert_eq!(err.code, ErrorCode::UnknownDevice);
}

#[test]
fn unsupported_bridge_device_is_listed_but_never_connectable() {
    // Lane D (#14): the mock advertises a recognized-but-unsupported LS-50.
    // The backend starts so scanner.list can name the unit, but connect is
    // refused fail-closed.
    let backend = RealLs5000::new_with_env(
        mock_bridge_bin(),
        GENEROUS_TIMEOUT,
        &[("MOCK_BRIDGE_DEVICE_UNSUPPORTED", "1")],
    )
    .expect("RealLs5000::new should start even for an unsupported model");

    assert_eq!(backend.device_info().model, "LS-50 ED");
    assert!(
        !backend.device_info().supported,
        "an unsupported model must never be connectable"
    );

    let err = backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect_err("connecting an unsupported model must be refused");
    assert_eq!(err.code, ErrorCode::NotSupported);
}

/// `device_info()` (which `scanner.list`/`scanner.connect` both build their
/// `DeviceInfo` response from) now forwards the exact device-sourced set
/// `scan_start`'s own gate validates against
/// (`scan_start_rejects_multisample_passes_other_than_device_supported`
/// above), instead of leaving the client to guess or hardcode it. Available
/// independent of connection state, matching `device_info()`'s own doc
/// comment.
#[test]
fn device_info_forwards_the_bridges_supported_multisample_passes() {
    let backend = RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
        .expect("RealLs5000::new should succeed against a healthy mock bridge");

    assert_eq!(
        backend.device_info().supported_multisample_passes,
        Some(vec![4]),
        "must forward mock_bridge's fixed_device_info() Capabilities.supportedMultisamplePasses verbatim"
    );
}

const UNSUPPORTED_DEVICE_ID: &str = "bridge-ls50-0";

#[test]
fn connect_decides_per_requested_device_in_a_dual_attach() {
    // Lane D, #14-C: an unsupported LS-50 alongside a supported LS-5000 must
    // not block connecting to the LS-5000, and the LS-50 must still be
    // refused when requested directly -- decided per REQUESTED device id
    // (RealLs5000::known_devices), not whichever device this engine
    // happened to see first in device.list.
    let backend = RealLs5000::new_with_env(
        mock_bridge_bin(),
        GENEROUS_TIMEOUT,
        &[("MOCK_BRIDGE_DEVICE_DUAL_ATTACH", "1")],
    )
    .expect("RealLs5000::new should start with two devices attached");

    let err = backend
        .connect(UNSUPPORTED_DEVICE_ID, &ConnectOptions::default())
        .expect_err("connecting the unsupported LS-50 must still be refused");
    assert_eq!(err.code, ErrorCode::NotSupported);

    let result = backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect(
            "connecting the supported LS-5000 must succeed even with an \
             unsupported LS-50 also attached",
        );
    assert!(result.status.connected);
}

#[test]
fn load_media_is_always_an_internal_error_and_never_calls_the_bridge() {
    let backend = RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
        .expect("RealLs5000::new should succeed against a healthy mock bridge");
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let err = backend
        .load_media(domain::MediaCarrier::Roll36)
        .expect_err("load_media is a simulator-only affordance on a real backend");
    assert_eq!(err.code, ErrorCode::Internal);
}

/// Supersedes the pre-Phase-10 version of this test (which cross-checked
/// against `sim::thumbnail_for`'s FNV values): `acquire_thumbnails`'s
/// worker no longer calls `sim::thumbnail_for` for the real backend at
/// all (Task 3) — it forwards `mock_bridge`'s real, on-disk preview-tile
/// path and honestly omits brightness/tint instead.
#[test]
fn acquire_thumbnails_emits_real_image_paths_and_omits_brightness_tint() {
    const OPERATION_ID: &str = "real-preview-op";
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("RealLs5000::new should succeed against a healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::acquire_thumbnails(
        &backend,
        None,
        domain::FilmProcess::default(),
        Some(OPERATION_ID.to_string()),
        tx,
    )
    .expect("acquire_thumbnails should accept synchronously");

    let events = drain_events(&rx, "scanner.thumbnailsComplete", GENEROUS_TIMEOUT);
    let thumbnail_events: Vec<&serde_json::Value> = events
        .iter()
        .filter(|event| event["event"] == "scanner.thumbnail")
        .collect();
    assert_eq!(
        thumbnail_events.len(),
        3,
        "mock_bridge's roll.preview worker always emits exactly 3 roll.thumbnail events: {events:#?}"
    );
    for (i, event) in thumbnail_events.iter().enumerate() {
        assert_eq!(
            event["payload"]["operationId"], OPERATION_ID,
            "every bridge-derived thumbnail must retain the engine operation id"
        );
        let expected_frame_index = (i as u32) + 1;
        assert_eq!(
            event["payload"]["frameIndex"].as_u64(),
            Some(expected_frame_index as u64),
            "thumbnails must arrive in slot order 1/2/3"
        );
        let thumbnail = &event["payload"]["thumbnail"];
        assert!(
            thumbnail["brightness"].is_null(),
            "a real backend must never fabricate brightness: {thumbnail:#?}"
        );
        assert!(
            thumbnail["tint"].is_null(),
            "a real backend must never fabricate tint: {thumbnail:#?}"
        );
        let image_path = thumbnail["imagePath"]
            .as_str()
            .expect("a real backend must always populate imagePath");
        assert!(
            std::path::Path::new(image_path).exists(),
            "mock_bridge's preview tile must actually exist on disk at {image_path}"
        );
    }
    let complete_event = events
        .iter()
        .find(|event| event["event"] == "scanner.thumbnailsComplete")
        .expect("thumbnailsComplete event must be present");
    assert_eq!(complete_event["payload"]["count"].as_u64(), Some(3));
    assert_eq!(complete_event["payload"]["operationId"], OPERATION_ID);

    let status_line = rx
        .recv_timeout(GENEROUS_TIMEOUT)
        .expect("post-preview scanner.status must follow completion");
    let status_event: serde_json::Value =
        serde_json::from_str(&status_line).expect("post-preview status event json");
    assert_eq!(status_event["event"], "scanner.status");
    assert_eq!(status_event["payload"]["operationId"], OPERATION_ID);
}

/// A healthy bridge can remain alive after the engine's preview event-stream
/// watchdog gives up. Its eventual terminal event is untagged, so the timed-
/// out session must stay quarantined: accepting a successor would let that
/// successor consume and misattribute the predecessor's late completion.
#[test]
fn healthy_preview_timeout_quarantines_successors_until_disconnect_and_reconnect() {
    let call_log_path = std::env::temp_dir().join(format!(
        "scanstudio-preview-quarantine-calls-{}.log",
        std::process::id()
    ));
    std::fs::write(&call_log_path, "").expect("create mock bridge call log");
    let call_log_path_string = call_log_path.display().to_string();
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[
                ("MOCK_BRIDGE_PREVIEW_DELAY_MS", "500"),
                ("MOCK_BRIDGE_CALL_LOG", call_log_path_string.as_str()),
            ],
        )
        .expect("preview delay does not affect bridge startup")
        .with_preview_silence_deadline(Duration::from_millis(50)),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");
    std::fs::write(&call_log_path, "").expect("reset mock bridge call log");

    let (first_tx, first_rx) = mpsc::channel();
    RealLs5000::acquire_thumbnails(
        &backend,
        Some(vec![1]),
        domain::FilmProcess::default(),
        Some("timed-out-predecessor".to_string()),
        first_tx,
    )
    .expect("the predecessor preview should be accepted");
    let first_events = drain_events(
        &first_rx,
        "scanner.thumbnailsComplete",
        Duration::from_secs(2),
    );
    assert!(
        first_events.iter().any(|event| {
            event["event"] == "scanner.thumbnailsFailed"
                && event["payload"]["code"] == "BRIDGE_STREAM_STALLED"
        }),
        "the healthy timeout must be reported honestly: {first_events:#?}"
    );

    let (successor_tx, _successor_rx) = mpsc::channel();
    let successor = RealLs5000::acquire_thumbnails(
        &backend,
        Some(vec![1]),
        domain::FilmProcess::default(),
        Some("unsafe-successor".to_string()),
        successor_tx,
    )
    .expect_err("the timed-out predecessor must quarantine the untagged event stream");
    assert_eq!(successor.code, ErrorCode::ScannerBusy);
    let calls_after_successor = std::fs::read_to_string(&call_log_path)
        .expect("read mock bridge call log after rejected successor");
    assert_eq!(
        calls_after_successor.lines().collect::<Vec<_>>(),
        vec!["roll.preview"],
        "the quarantined successor must not issue a second roll.preview call"
    );

    let (scan_tx, _scan_rx) = mpsc::channel();
    let scan = RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        domain::OutputRecipe::default(),
        std::collections::HashMap::new(),
        None,
        scan_tx,
    )
    .expect_err("a scan worker must not compete for the quarantined preview event stream");
    assert_eq!(scan.code, ErrorCode::ScannerBusy);

    let early_disconnect = backend
        .disconnect()
        .expect_err("disconnect must wait until the predecessor terminal is safely drained");
    assert_eq!(early_disconnect.code, ErrorCode::ScannerBusy);
    let direct_reconnect = backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect_err("connect cannot clear a poisoned stream in the same bridge event queue");
    assert_eq!(direct_reconnect.code, ErrorCode::ScannerBusy);
    assert_eq!(
        std::fs::read_to_string(&call_log_path)
            .expect("read call log after locally rejected session changes")
            .lines()
            .collect::<Vec<_>>(),
        vec!["roll.preview"],
        "undrained quarantine must reject session changes before bridge traffic"
    );

    // The quarantined worker keeps consuming only its own late terminal.
    // Once that terminal has been safely discarded, an explicit disconnect
    // plus reconnect establishes a clean session and a genuinely new preview
    // may be accepted. The drain runs on a background worker, so poll until
    // it unblocks disconnect instead of racing it with a fixed sleep.
    retry_while_busy(
        "disconnect after the predecessor terminal is drained",
        GENEROUS_TIMEOUT,
        || backend.disconnect(),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("explicit reconnect should establish a clean preview session");

    let (fresh_tx, fresh_rx) = mpsc::channel();
    let fresh_started_at = std::time::Instant::now();
    RealLs5000::acquire_thumbnails(
        &backend,
        Some(vec![1]),
        domain::FilmProcess::default(),
        Some("post-reconnect-preview".to_string()),
        fresh_tx,
    )
    .expect("a preview after explicit reconnect should be accepted");
    let fresh_events = drain_events(
        &fresh_rx,
        "scanner.thumbnailsComplete",
        Duration::from_secs(2),
    );
    let fresh_failure = fresh_events
        .iter()
        .find(|event| event["event"] == "scanner.thumbnailsFailed")
        .unwrap_or_else(|| {
            panic!(
                "the deliberately slow post-reconnect preview should reach its own watchdog, not a stale predecessor terminal: {fresh_events:#?}"
            )
        });
    assert_eq!(fresh_failure["payload"]["code"], "BRIDGE_STREAM_STALLED");
    assert!(
        fresh_failure["payload"]["message"]
            .as_str()
            .unwrap_or("")
            .contains("sessionEpoch=2"),
        "the post-reconnect preview must belong to the replacement session: {fresh_failure:#?}"
    );
    assert!(
        fresh_started_at.elapsed() >= Duration::from_millis(40),
        "a queued predecessor terminal would complete the new worker immediately; it must instead wait for its own configured deadline"
    );
    let _ = std::fs::remove_file(call_log_path);
}

/// A session-scoped RPC can time out while a preview worker is blocked in the
/// shared event receiver. The live but unresponsive bridge may still own a
/// hardware operation, so it must not be killed or replaced. The old reader
/// keeps ownership until it observes the loss; reconnect stays failed closed
/// even after reader detach, and becomes possible only after an independently
/// proven process exit.
#[test]
fn restart_during_preview_keeps_old_reader_attached_until_it_detaches() {
    let call_log_path = std::env::temp_dir().join(format!(
        "scanstudio-preview-restart-calls-{}.log",
        std::process::id()
    ));
    std::fs::write(&call_log_path, "").expect("create mock bridge call log");
    let call_log_path_string = call_log_path.display().to_string();
    let exit_trigger_path = std::env::temp_dir().join(format!(
        "scanstudio-preview-owner-exit-trigger-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&exit_trigger_path);
    let exit_trigger_path_string = exit_trigger_path.display().to_string();
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            Duration::from_millis(500),
            &[
                ("MOCK_BRIDGE_PREVIEW_DELAY_MS", "2000"),
                ("MOCK_BRIDGE_HANG_ON_STATUS_WHILE_PREVIEW_PENDING", "1"),
                (
                    "MOCK_BRIDGE_EXIT_TRIGGER_ON_HUNG_STATUS",
                    exit_trigger_path_string.as_str(),
                ),
                ("MOCK_BRIDGE_CALL_LOG", call_log_path_string.as_str()),
                // Adversarial review S3 (2026-08-08): roll_approve now
                // requires the approved frame to be one the completed
                // preview flagged `needsApproval: true` -- flag frame 1
                // (the one both the predecessor and replacement preview
                // approve below) so this test keeps exercising its own
                // actual subject (stale vs. current vs. premature
                // approval across a bridge restart) rather than tripping
                // the new gate.
                ("MOCK_BRIDGE_PREVIEW_APPROVAL_SLOTS", "1"),
            ],
        )
        .expect("preview-status fault does not affect bridge startup")
        .with_preview_reader_detach_delay(Duration::from_secs(1)),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");
    std::fs::write(&call_log_path, "").expect("reset mock bridge call log");

    let (predecessor_tx, predecessor_rx) = mpsc::channel();
    RealLs5000::acquire_thumbnails(
        &backend,
        Some(vec![1]),
        domain::FilmProcess::default(),
        Some("predecessor-preview".to_string()),
        predecessor_tx,
    )
    .expect("the predecessor preview should be accepted");

    let status_error = backend
        .status()
        .expect_err("the pending-preview status read must force a bridge restart");
    assert_eq!(status_error.code, ErrorCode::NotConnected);

    let early_reconnect = backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect_err("the predecessor event reader must block reconnect until it detaches");
    assert_eq!(early_reconnect.code, ErrorCode::ScannerBusy);

    let predecessor_events = drain_events(
        &predecessor_rx,
        "scanner.thumbnailsComplete",
        Duration::from_secs(3),
    );
    let predecessor_failures = predecessor_events
        .iter()
        .filter(|event| event["event"] == "scanner.thumbnailsFailed")
        .collect::<Vec<_>>();
    assert_eq!(
        predecessor_failures.len(),
        1,
        "the predecessor must fail exactly once: {predecessor_events:#?}"
    );
    assert_eq!(predecessor_failures[0]["payload"]["code"], "NOT_CONNECTED");
    assert_eq!(
        predecessor_failures[0]["payload"]["operationId"],
        "predecessor-preview"
    );
    assert!(
        predecessor_events
            .iter()
            .all(|event| event["event"] != "scanner.thumbnail"),
        "the lost predecessor may not forward any thumbnail: {predecessor_events:#?}"
    );
    assert!(
        predecessor_events
            .iter()
            .all(|event| event.pointer("/payload/thumbnail/imagePath").is_none()),
        "the predecessor may not contain a replacement image path: {predecessor_events:#?}"
    );
    let predecessor_completions = predecessor_events
        .iter()
        .filter(|event| event["event"] == "scanner.thumbnailsComplete")
        .collect::<Vec<_>>();
    assert_eq!(
        predecessor_completions.len(),
        1,
        "the predecessor must close exactly once: {predecessor_events:#?}"
    );
    assert_eq!(predecessor_completions[0]["payload"]["count"], 0);
    assert_eq!(
        predecessor_completions[0]["payload"]["operationId"],
        "predecessor-preview"
    );

    // The preceding completion is public closure, not reader detachment. This
    // test's explicit delay keeps the private gate observable; production
    // leaves that delay at zero.
    let reconnect_deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match backend.connect(DEVICE_ID, &ConnectOptions::default()) {
            Err(error)
                if error.code == ErrorCode::ScannerBusy
                    && Instant::now() < reconnect_deadline =>
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(error) if error.code == ErrorCode::NotConnected => break,
            Ok(_) => panic!(
                "a live hung bridge may not be replaced merely because its preview reader detached"
            ),
            Err(error) => panic!(
                "after reader detach the still-live bridge must fail closed as not connected: {error:?}"
            ),
        }
    }
    assert_eq!(
        std::fs::read_to_string(&call_log_path)
            .expect("read calls while the original bridge still owns the process fence")
            .lines()
            .collect::<Vec<_>>(),
        vec!["roll.preview", "device.status"],
        "failed-closed reconnect attempts must not reach the live hung bridge"
    );

    std::fs::write(&exit_trigger_path, "exit").expect("release the mock bridge owner");
    let process_exit_deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match backend.connect(DEVICE_ID, &ConnectOptions::default()) {
            Ok(_) => break,
            Err(error)
                if error.code == ErrorCode::NotConnected
                    && Instant::now() < process_exit_deadline =>
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(error) => panic!(
                "a proven predecessor-process exit should permit an explicit reconnect: {error:?}"
            ),
        }
    }

    let stale_approval = backend
        .roll_approve(1, "predecessor-preview", false)
        .expect_err("a predecessor approval must be stale after reconnect");
    assert_eq!(stale_approval.code, ErrorCode::InvalidParams);

    let (replacement_tx, replacement_rx) = mpsc::channel();
    RealLs5000::acquire_thumbnails(
        &backend,
        Some(vec![1]),
        domain::FilmProcess::default(),
        Some("replacement-preview".to_string()),
        replacement_tx,
    )
    .expect("the replacement preview should be accepted only after the old reader detached");

    let premature_approval = backend
        .roll_approve(1, "replacement-preview", false)
        .expect_err("the replacement is not approvable before its own completion");
    assert_eq!(premature_approval.code, ErrorCode::InvalidParams);
    assert!(
        std::fs::read_to_string(&call_log_path)
            .expect("read bridge calls before replacement completion")
            .lines()
            .all(|method| method != "roll.approve"),
        "stale and premature approvals must be rejected before bridge traffic"
    );

    let replacement_events = drain_events(
        &replacement_rx,
        "scanner.thumbnailsComplete",
        Duration::from_secs(4),
    );
    assert_eq!(
        replacement_events
            .iter()
            .filter(|event| event["event"] == "scanner.thumbnailsFailed")
            .count(),
        0,
        "the replacement must not inherit a predecessor failure: {replacement_events:#?}"
    );
    let replacement_thumbnails = replacement_events
        .iter()
        .filter(|event| event["event"] == "scanner.thumbnail")
        .collect::<Vec<_>>();
    assert_eq!(
        replacement_thumbnails.len(),
        3,
        "the replacement must receive its complete three-tile stream: {replacement_events:#?}"
    );
    assert_eq!(
        replacement_thumbnails
            .iter()
            .map(|event| event["payload"]["frameIndex"].as_u64())
            .collect::<Vec<_>>(),
        vec![Some(1), Some(2), Some(3)]
    );
    assert!(replacement_thumbnails.iter().all(|event| {
        event["payload"]["operationId"] == "replacement-preview"
            && event.pointer("/payload/thumbnail/imagePath").is_some()
    }));
    let replacement_completions = replacement_events
        .iter()
        .filter(|event| event["event"] == "scanner.thumbnailsComplete")
        .collect::<Vec<_>>();
    assert_eq!(
        replacement_completions.len(),
        1,
        "the replacement must complete exactly once: {replacement_events:#?}"
    );
    assert_eq!(replacement_completions[0]["payload"]["count"], 3);
    assert_eq!(
        replacement_completions[0]["payload"]["operationId"],
        "replacement-preview"
    );

    let stale_after_replacement = backend
        .roll_approve(1, "predecessor-preview", false)
        .expect_err("the predecessor remains stale after replacement completion");
    assert_eq!(stale_after_replacement.code, ErrorCode::InvalidParams);
    let mismatched_replacement = backend
        .roll_approve(1, "wrong-replacement-preview", false)
        .expect_err("a mismatched replacement operation must be rejected locally");
    assert_eq!(mismatched_replacement.code, ErrorCode::InvalidParams);
    assert!(
        std::fs::read_to_string(&call_log_path)
            .expect("read bridge calls before valid approval")
            .lines()
            .all(|method| method != "roll.approve"),
        "stale, premature, and mismatched approvals must not reach the bridge"
    );

    backend
        .roll_approve(1, "replacement-preview", false)
        .expect("the replacement becomes approvable only after its own completion");
    let bridge_calls = std::fs::read_to_string(&call_log_path)
        .expect("read final mock bridge call log")
        .lines()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    assert_eq!(
        bridge_calls
            .iter()
            .filter(|method| method.as_str() == "roll.preview")
            .count(),
        2,
        "exactly the predecessor and replacement previews may reach the bridge: {bridge_calls:#?}"
    );
    assert_eq!(
        bridge_calls
            .iter()
            .filter(|method| method.as_str() == "roll.approve")
            .count(),
        1,
        "only the valid completed replacement approval may reach the bridge: {bridge_calls:#?}"
    );
    let _ = std::fs::remove_file(call_log_path);
    let _ = std::fs::remove_file(exit_trigger_path);
}

/// Forces the session epoch/generation to change after the worker's
/// post-receive ownership check but before it finalizes previewComplete. The
/// worker has consumed its terminal and will make no further recv_event call,
/// so it must close truthfully and release its exact gate instead of leaving
/// reconnect permanently blocked.
#[test]
fn terminal_generation_loss_before_finalization_does_not_strand_reader_gate() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("healthy mock bridge")
            .with_preview_terminal_session_loss_test_hook(),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::acquire_thumbnails(
        &backend,
        Some(vec![1]),
        domain::FilmProcess::default(),
        Some("terminal-loss-preview".to_string()),
        tx,
    )
    .expect("preview should be accepted before the terminal loss hook");

    let events = drain_events(&rx, "scanner.thumbnailsComplete", Duration::from_secs(3));
    assert!(
        events.iter().any(|event| {
            event["event"] == "scanner.thumbnailsFailed"
                && event["payload"]["code"] == "NOT_CONNECTED"
        }),
        "terminal ownership loss must close as a connection failure: {events:#?}"
    );
    assert_eq!(
        events
            .iter()
            .filter(|event| event["event"] == "scanner.thumbnailsComplete")
            .count(),
        1,
        "the predecessor must close exactly once: {events:#?}"
    );

    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("the detached terminal reader must not leave reconnect gated");
}

/// Exercises the same terminal/invalidation interval after a healthy timeout
/// has moved the sole reader into discard-only quarantine. Once that worker
/// consumes its late terminal, generation loss must retire the exact poison
/// gate rather than leave reconnect permanently blocked.
#[test]
fn quarantined_terminal_generation_loss_does_not_strand_poison_gate() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_PREVIEW_DELAY_MS", "100")],
        )
        .expect("healthy delayed mock bridge")
        .with_preview_silence_deadline(Duration::from_millis(20))
        .with_preview_terminal_session_loss_test_hook(),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::acquire_thumbnails(
        &backend,
        Some(vec![1]),
        domain::FilmProcess::default(),
        Some("quarantined-terminal-loss".to_string()),
        tx,
    )
    .expect("preview should be accepted before its watchdog");

    let events = drain_events(&rx, "scanner.thumbnailsComplete", Duration::from_secs(2));
    assert!(events.iter().any(|event| {
        event["event"] == "scanner.thumbnailsFailed"
            && event["payload"]["code"] == "BRIDGE_STREAM_STALLED"
    }));

    // The mock's late terminal arrives at 100ms. Its exact discard-only
    // reader consumes it and exercises the generation-loss hook immediately
    // before poison finalization on a background worker, so poll until the
    // gate retires instead of racing it with a fixed sleep.
    retry_while_busy(
        "connect after the terminal-consuming worker retires its poisoned reader gate",
        GENEROUS_TIMEOUT,
        || backend.connect(DEVICE_ID, &ConnectOptions::default()),
    );
}

/// Proves `map_status` forwards `BridgeDeviceStatus.filmPresent` verbatim
/// (a direct passthrough, no transformation) rather than leaving the field
/// unpopulated.
#[test]
fn status_surfaces_film_present_from_the_bridge() {
    let backend = RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
        .expect("RealLs5000::new should succeed against a healthy mock bridge");
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let status = backend
        .status()
        .expect("status should succeed once connected");
    assert_eq!(
        status.film_present,
        Some(true),
        "mock_bridge's default (MOCK_BRIDGE_FILM_PRESENT unset) reports Some(true)"
    );
}

/// `motionArmed` is a bridge-sourced, no-motion readiness observation. It
/// must reach both the initial real connection result and a subsequent live
/// `device.status` response without the engine inferring or changing it.
#[test]
fn status_surfaces_live_motion_armed_from_the_bridge() {
    let backend = RealLs5000::new_with_env(
        mock_bridge_bin(),
        GENEROUS_TIMEOUT,
        &[
            ("MOCK_BRIDGE_MOTION_ARMED", "false"),
            ("MOCK_BRIDGE_MOTION_ARMED_ON_STATUS", "true"),
        ],
    )
    .expect("RealLs5000::new should succeed against a healthy mock bridge");

    let connected = backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");
    assert_eq!(
        connected.status.motion_armed,
        Some(false),
        "the connection response must preserve the status it actually observed"
    );

    let status = backend
        .status()
        .expect("device.status should succeed once connected");
    assert_eq!(
        status.motion_armed,
        Some(true),
        "a fresh bridge device.status must replace, not reuse, the earlier connection observation"
    );
}

#[test]
fn scan_start_emits_completed_receipts_marked_not_simulated() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("RealLs5000::new should succeed against a healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1, 2],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("scan_start should succeed against a healthy bridge with a valid recipe");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);
    let frame_completed_events: Vec<&serde_json::Value> = events
        .iter()
        .filter(|event| event["event"] == "scan.frameCompleted")
        .collect();
    assert_eq!(frame_completed_events.len(), 2, "events: {events:#?}");
    for event in &frame_completed_events {
        assert_eq!(
            event["payload"]["receipt"]["simulated"].as_bool(),
            Some(false),
            "a real-backend receipt must never claim simulated: true"
        );
        assert_eq!(
            event["payload"]["receipt"]["deviceId"].as_str(),
            Some(DEVICE_ID)
        );
    }

    let completed_event = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .expect("scan.completed event must be present");
    let mut completed_slots: Vec<u64> = completed_event["payload"]["summary"]["completed"]
        .as_array()
        .expect("summary.completed must be an array")
        .iter()
        .map(|v| v.as_u64().expect("slot must be a number"))
        .collect();
    completed_slots.sort_unstable();
    assert_eq!(completed_slots, vec![1, 2]);
}

#[test]
fn scan_start_raw_only_maps_dng_sidecar_recipe_and_preserves_both_bridge_paths() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("RealLs5000::new should succeed against a healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let mut output = isolated_output_recipe();
    output.archive.enabled = false;
    output.positive.enabled = false;
    output.preview.enabled = false;
    output.raw_export.enabled = true;
    output.raw_export.file_format = domain::RawExportFormat::LinearDng;
    output.raw_export.tiff_infrared = domain::RawTiffInfrared::Sidecar;
    let raw_root = std::path::PathBuf::from(&output.raw_export.destination);

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        output,
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("a raw-only scan should be retained and accepted");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);
    let receipt = &events
        .iter()
        .find(|event| event["event"] == "scan.frameCompleted")
        .expect("scan.frameCompleted must be present")["payload"]["receipt"];
    let raw_path = receipt["outputs"]["rawNegativePath"]
        .as_str()
        .expect("completed receipt must expose the bridge-written raw path");
    let canonical_raw_root = std::fs::canonicalize(&raw_root)
        .expect("published raw destination has a canonical authority path");
    assert!(raw_path.ends_with(".dng"));
    assert!(std::path::Path::new(raw_path).starts_with(&canonical_raw_root));
    assert!(std::path::Path::new(raw_path).is_file());
    let raw_ir_path = receipt["outputs"]["rawNegativeIrPath"]
        .as_str()
        .expect("completed receipt must expose the paired raw IR path");
    assert!(raw_ir_path.ends_with("-ir.tif"));
    assert!(std::path::Path::new(raw_ir_path).starts_with(&canonical_raw_root));
    assert!(std::path::Path::new(raw_ir_path).is_file());
    assert!(receipt["outputs"]["archivePath"].is_null());
}

/// Proves `build_real_receipt` forwards `BridgeScanReceipt`'s capture-file
/// paths and hardware telemetry onto the engine's wire (Task 3), replacing
/// what used to be an `eprintln!`-only diagnostic dump.
#[test]
fn scan_start_receipt_carries_real_capture_paths_and_hardware_telemetry() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("RealLs5000::new should succeed against a healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let output = isolated_output_recipe();
    let expected_rgb_path = std::path::Path::new(&output.archive.destination).join(format!(
        "{}.tif",
        scanstudio_engine::render::resolve_filename(&output.archive.filename_template, 1)
    ));
    let expected_ir_path = expected_rgb_path.with_file_name(format!(
        "{}_IR.tif",
        expected_rgb_path
            .file_stem()
            .and_then(|value| value.to_str())
            .expect("archive test filename must have a UTF-8 stem")
    ));
    let expected_meter_path = expected_rgb_path.with_file_name(format!(
        "{}_METER.tif",
        expected_rgb_path
            .file_stem()
            .and_then(|value| value.to_str())
            .expect("archive test filename must have a UTF-8 stem")
    ));
    let (tx, rx) = mpsc::channel();
    let overrides = std::collections::HashMap::from([(
        1,
        domain::FrameOverrides {
            alignment: Some(domain::FrameAlignment {
                offset_rows: 0,
                approved: false,
                derivative_transform: domain::DerivativeTransform {
                    rotation_degrees: 90,
                    horizontal_mirror: true,
                    vertical_mirror: false,
                },
            }),
            ..domain::FrameOverrides::default()
        },
    )]);
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        output,
        overrides,
        None,
        tx,
    )
    .expect("scan_start should succeed against a healthy bridge with a valid recipe");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);
    let frame_completed = events
        .iter()
        .find(|event| event["event"] == "scan.frameCompleted")
        .expect("scan.frameCompleted event must be present");
    let receipt = &frame_completed["payload"]["receipt"];
    let expected_rgb_path = std::fs::canonicalize(&expected_rgb_path)
        .expect("published RGB archive has a canonical authority path");
    let expected_ir_path = std::fs::canonicalize(&expected_ir_path)
        .expect("published IR archive has a canonical authority path");
    let expected_meter_path = std::fs::canonicalize(&expected_meter_path)
        .expect("published meter archive has a canonical authority path");

    let rgb_path = receipt["rgbPath"]
        .as_str()
        .expect("rgbPath must be present in the completed receipt");
    assert_eq!(
        std::path::Path::new(rgb_path),
        expected_rgb_path,
        "rgbPath must identify the exact archive target routed from the output recipe: {receipt:#?}"
    );
    assert!(
        std::path::Path::new(rgb_path).is_file(),
        "mock_bridge must provide a real RGB16 TIFF for derivative rendering: {receipt:#?}"
    );
    assert_eq!(
        receipt["storageTransform"].as_str(),
        Some("swapaxes01-scanner-native-to-nikon-render-parity-v2"),
        "receipt must preserve the bridge storage-orientation contract: {receipt:#?}"
    );
    assert_eq!(
        receipt["outputs"]["archivePath"].as_str(),
        Some(rgb_path),
        "the rendered output receipt must retain the bridge archive path: {receipt:#?}"
    );
    for output_key in ["positivePath", "previewPath"] {
        let output_path = receipt["outputs"][output_key]
            .as_str()
            .unwrap_or_else(|| panic!("{output_key} must be present: {receipt:#?}"));
        assert!(
            std::path::Path::new(output_path).is_file(),
            "{output_key} must name a rendered derivative: {receipt:#?}"
        );
    }
    assert_eq!(
        receipt["outputs"]["derivativeTransform"],
        serde_json::json!({
            "rotationDegrees": 90,
            "horizontalMirror": true,
            "verticalMirror": false,
        }),
        "the receipt must make derivative rerender geometry reproducible: {receipt:#?}"
    );
    let archive_dimensions = image::image_dimensions(rgb_path).unwrap();
    let positive_dimensions =
        image::image_dimensions(receipt["outputs"]["positivePath"].as_str().unwrap()).unwrap();
    assert_eq!(
        positive_dimensions,
        (archive_dimensions.1, archive_dimensions.0),
        "a 90-degree finished output must swap axes while the archive keeps scanner-native dimensions"
    );
    assert_eq!(
        receipt["irPath"].as_str().map(std::path::Path::new),
        Some(expected_ir_path.as_path()),
        "RGBI capture must identify the IR sidecar beside the routed archive: {receipt:#?}"
    );
    assert!(
        expected_ir_path.is_file(),
        "mock_bridge must provide the routed IR sidecar: {receipt:#?}"
    );
    assert_eq!(
        receipt["meterRgbiPath"].as_str().map(std::path::Path::new),
        Some(expected_meter_path.as_path()),
        "meterRgbiPath must identify the METER sidecar beside the routed archive: {receipt:#?}"
    );
    let telemetry = &receipt["hardwareTelemetry"];
    assert!(
        !telemetry.is_null(),
        "hardwareTelemetry must be populated for a real-backend receipt: {receipt:#?}"
    );
    assert_eq!(
        telemetry["exposure"]["focusPosition"].as_i64(),
        Some(800),
        "must match fixed_scan_receipt's literal exposure.focus_position: {telemetry:#?}"
    );
    assert_eq!(
        receipt["startedAt"].as_str(),
        Some("2026-08-02T20:05:00+00:00"),
        "the engine receipt must forward the bridge's wall-clock capture start verbatim, never a receipt-arrival time: {receipt:#?}"
    );
    assert_eq!(
        receipt["durationMs"].as_u64(),
        Some(1900),
        "the engine receipt must forward the bridge's per-frame capture duration milliseconds: {receipt:#?}"
    );
}

#[test]
fn derivative_only_real_scan_routes_through_private_working_root_and_cleans_after_terminal() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT).expect("healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect");

    let mut output = isolated_output_recipe();
    let user_archive_destination = std::path::PathBuf::from(&output.archive.destination);
    output.archive.enabled = false;
    output.archive.full_capture_package = false;
    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        output,
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("derivative-only scan dispatches to mock bridge");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);
    let frame_completed = events
        .iter()
        .find(|event| event["event"] == "scan.frameCompleted")
        .expect("derivatives complete");
    let receipt = &frame_completed["payload"]["receipt"];
    let rgb_path =
        std::path::PathBuf::from(receipt["rgbPath"].as_str().expect("bridge provenance path"));
    let private_root = rgb_path
        .parent()
        .expect("private capture has a workspace parent");
    let canonical_temp_root = std::fs::canonicalize(std::env::temp_dir()).unwrap();
    assert_eq!(
        private_root.parent(),
        Some(canonical_temp_root.as_path()),
        "archive-off bridge capture must use the canonical OS temp root: {receipt:#?}"
    );
    assert!(
        private_root
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("scanstudio-engine-capture-") && name.len() == 58),
        "private workspace must have a cryptorandom, non-predictable name: {receipt:#?}"
    );
    assert!(
        !rgb_path.starts_with(&user_archive_destination),
        "private capture must never route to the disabled archive destination"
    );
    assert!(
        receipt["outputs"]["archivePath"].is_null(),
        "temporary capture is not a WrittenOutputs archive path: {receipt:#?}"
    );
    assert!(
        !user_archive_destination.exists(),
        "disabled archive must not create the user archive folder"
    );
    for key in ["positivePath", "previewPath"] {
        assert!(
            receipt["outputs"][key]
                .as_str()
                .is_some_and(|path| std::path::Path::new(path).is_file()),
            "{key} must be retained: {receipt:#?}"
        );
    }
    assert!(
        !rgb_path.exists(),
        "after scan.completed plus successful derivatives, the owned private capture must be cleaned"
    );
    let terminal = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .unwrap();
    let status = terminal["payload"]["summary"]["evidencePackageStatus"]
        .as_str()
        .expect("cleanup status");
    assert!(
        status.contains("private temporary captures cleaned")
            && status.contains("identity tombstones retained at"),
        "terminal status must state the temporary-capture lifecycle: {terminal:#?}"
    );
    let tombstones: Vec<std::path::PathBuf> = status
        .split("identity tombstones retained at ")
        .nth(1)
        .expect("reported tombstone paths")
        .split(", ")
        .map(std::path::PathBuf::from)
        .collect();
    assert_eq!(tombstones.len(), 2);
    assert!(
        std::fs::read_dir(&tombstones[0]).unwrap().next().is_none(),
        "the quarantined bridge namespace is retained empty instead of being racy-rmdir'd"
    );
    for entry in std::fs::read_dir(&tombstones[1]).unwrap() {
        let entry = entry.unwrap();
        if entry.file_name() != ".scanstudio-capture-work-owner" {
            assert_eq!(
                entry.metadata().unwrap().len(),
                0,
                "only the descriptor-bound engine capture inode may have its bytes retired"
            );
        }
    }
    for tombstone in tombstones {
        std::fs::remove_dir_all(tombstone).expect("remove explicit test-owned tombstone");
    }
}

#[test]
fn mixed_output_overrides_hold_private_capture_when_retained_package_is_incomplete() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT).expect("healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect");

    let output = isolated_output_recipe();
    assert!(output.archive.enabled && output.archive.full_capture_package);
    let archive_destination = std::path::PathBuf::from(&output.archive.destination);
    let test_root = archive_destination
        .parent()
        .expect("isolated archive has parent")
        .to_path_buf();
    let mut derivative_only = output.clone();
    derivative_only.archive.enabled = false;
    derivative_only.archive.full_capture_package = false;
    let mut overrides = std::collections::HashMap::new();
    overrides.insert(
        2,
        domain::FrameOverrides {
            output: Some(derivative_only),
            ..Default::default()
        },
    );

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1, 2],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        output,
        overrides,
        None,
        tx,
    )
    .expect("mixed retained and derivative-only batch dispatches");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);
    let retained = events
        .iter()
        .find(|event| {
            event["event"] == "scan.frameCompleted" && event["payload"]["frameIndex"] == 1
        })
        .expect("retained frame completes");
    let derivative_only = events
        .iter()
        .find(|event| {
            event["event"] == "scan.frameCompleted" && event["payload"]["frameIndex"] == 2
        })
        .expect("derivative-only frame completes");
    assert!(
        retained["payload"]["receipt"]["outputs"]["archivePath"]
            .as_str()
            .is_some_and(|path| std::path::Path::new(path).is_file()),
        "the retained frame must keep its user master"
    );
    assert!(
        derivative_only["payload"]["receipt"]["outputs"]["archivePath"].is_null(),
        "the archive-off override must not publish a hidden master"
    );
    let private_rgb = std::path::PathBuf::from(
        derivative_only["payload"]["receipt"]["rgbPath"]
            .as_str()
            .expect("private bridge provenance"),
    );

    let terminal = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .expect("terminal event");
    let job_id = terminal["payload"]["jobId"].as_str().expect("job id");
    let package_manifest = archive_destination
        .join("Capture Evidence")
        .join(format!("{job_id}.scanstudio"))
        .join("manifest.json");
    let package: serde_json::Value = serde_json::from_slice(
        &std::fs::read(&package_manifest).expect("retained frame package manifest"),
    )
    .expect("package manifest JSON");
    assert_eq!(
        package["status"], "incomplete",
        "missing attemptsRoot is not verified package success"
    );
    let packaged_frames = package["frames"].as_array().expect("package frames");
    assert_eq!(
        packaged_frames.len(),
        1,
        "only the retained-master frame is eligible"
    );
    assert_eq!(packaged_frames[0]["frameIndex"], 1);
    assert_ne!(
        packaged_frames[0]["rgb"]["path"].as_str(),
        private_rgb.to_str(),
        "a private derivative-only capture must never be copied into a master package"
    );
    assert!(
        private_rgb.is_file(),
        "an incomplete package cannot authorize deletion of the private capture"
    );
    let private_root = private_rgb
        .parent()
        .expect("private capture parent")
        .to_path_buf();
    let terminal_status = terminal["payload"]["summary"]["evidencePackageStatus"]
        .as_str()
        .expect("evidence package status");
    assert!(
        terminal_status.contains("incomplete")
            && terminal_status.contains("recovery-held at")
            && terminal_status.contains(private_root.to_str().expect("UTF-8 temp path")),
        "missing attemptsRoot makes the package incomplete and must report the held private path: {terminal:#?}"
    );
    assert!(private_root
        .join(".scanstudio-capture-work-owner")
        .is_file());
    let _ = std::fs::remove_dir_all(private_root);
    let _ = std::fs::remove_dir_all(test_root);
}

#[test]
fn derivative_only_real_scan_preserves_private_capture_when_derivative_rendering_fails() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT).expect("healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect");
    let mut output = isolated_output_recipe();
    output.archive.enabled = false;
    output.archive.full_capture_package = false;
    // The real renderer intentionally only supports Adobe RGB values. This
    // fails after mock_bridge has produced a real private RGB/IR/meter set,
    // exercising recovery preservation without a hardware device.
    output.positive.color_profile = domain::OutputColorProfile::SRgb;
    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        output,
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("bridge dispatch succeeds before derivative failure");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);
    let failure = events
        .iter()
        .find(|event| event["event"] == "scan.frameState" && event["payload"]["state"] == "failed")
        .expect("derivative failure must be visible");
    let message = failure["payload"]["error"]["message"]
        .as_str()
        .expect("failure message");
    let held_root = message
        .split("recovery-held at ")
        .nth(1)
        .and_then(|tail| tail.split(": derivative rendering failed").next())
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            panic!("failure must honestly name the held recovery workspace: {message}")
        });
    assert!(
        held_root.is_dir(),
        "the only physical capture must be preserved: {message}"
    );
    assert!(held_root.join(".scanstudio-capture-work-owner").is_file());
    let terminal = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .unwrap();
    assert!(
        terminal["payload"]["summary"]["evidencePackageStatus"]
            .as_str()
            .is_some_and(|status| status.contains("recovery-held")),
        "terminal status must not claim cleanup after derivative failure: {terminal:#?}"
    );
    let _ = std::fs::remove_dir_all(held_root);
}

#[test]
fn derivative_only_real_scan_preserves_private_capture_without_bridge_terminal_closure() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_CRASH_AFTER_FRAME_COMPLETED", "1")],
        )
        .expect("bridge starts before its scan worker crash")
        .with_scan_silence_deadline(Duration::from_secs(2)),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect");
    let mut output = isolated_output_recipe();
    output.archive.enabled = false;
    output.archive.full_capture_package = false;
    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        output,
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("scan starts");

    let events = drain_events(&rx, "scan.completed", Duration::from_secs(8));
    let receipt = &events
        .iter()
        .find(|event| event["event"] == "scan.frameCompleted")
        .expect("the bridge completes the physical frame before crashing")["payload"]["receipt"];
    let rgb_path =
        std::path::PathBuf::from(receipt["rgbPath"].as_str().expect("private provenance"));
    assert!(
        rgb_path.is_file(),
        "without a terminal bridge closure the physical capture must remain: {receipt:#?}"
    );
    let terminal = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .unwrap();
    assert!(
        terminal["payload"]["summary"]["evidencePackageStatus"]
            .as_str()
            .is_some_and(|status| status.contains("recovery-held")
                && status.contains("without a real bridge scan.completed closure")),
        "terminal status must honestly preserve recovery capture: {terminal:#?}"
    );
    let held_root = rgb_path.parent().expect("capture parent").to_path_buf();
    let _ = std::fs::remove_dir_all(held_root);
}

#[test]
fn scan_start_crash_fails_closed_without_retrying_motion() {
    // Note on what this test actually exercises: mock_bridge's crash
    // trigger fires on *every* incoming request named "scan.start" for as
    // long as the variable is set in that child's environment (checked
    // fresh per request, not a one-shot), and scan.start is the only
    // client-initiated request in a scan job's entire lifecycle — every
    // signal after it (progress, frameCompleted, completed) is a
    // bridge-emitted *event*, never a further request from the engine.
    // There is therefore no way to make MOCK_BRIDGE_CRASH_ON=scan.start
    // fire any later than the initiating call. A child restart loses both
    // its open device and preview session, so scan.start must return one
    // typed reconnect-required failure without replaying that motion call.
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_CRASH_ON", "scan.start")],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_CRASH_ON=scan.start doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed — device.open is unaffected by the crash trigger");

    let (tx, rx) = mpsc::channel();
    let error = RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect_err("bridge loss before scan.start must fail closed");
    assert_eq!(error.code, ErrorCode::NotConnected);
    assert!(error.message.contains("motion request was not retried"));

    let events = drain_events_for(&rx, Duration::from_secs(3));
    let saw_not_connected_failure = events.iter().any(|event| {
        event["event"] == "scan.frameState"
            && event["payload"]["state"] == "failed"
            && event["payload"]["error"]["code"] == "NOT_CONNECTED"
            && event["payload"]["error"]["recoverable"] == false
    });
    assert!(
        saw_not_connected_failure,
        "expected scan.frameState(failed, NOT_CONNECTED, recoverable:false) among: {events:#?}"
    );
}

#[test]
fn scan_start_rejects_a_respawned_non_owner_before_dispatching_motion() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_CRASH_ON", "device.status")],
        )
        .expect("status-only crash injection must not affect startup"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("initial connect");

    // Direct backend invocation intentionally bypasses server.rs's invalidator:
    // the status call crashes and respawns the bridge, leaving the logical
    // epoch present but owned by the old process generation.
    let status_error = backend
        .status()
        .expect_err("the injected status process exit must be connection loss");
    assert_eq!(status_error.code, ErrorCode::NotConnected);

    let (tx, rx) = mpsc::channel();
    let error = RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect_err("a replacement child must not inherit motion authority");
    assert_eq!(error.code, ErrorCode::NotConnected);
    assert!(
        error.message.contains("no longer current before dispatch")
            && error.message.contains("motion request was not retried"),
        "the rejection must prove it occurred at the ownership boundary: {error:?}"
    );

    let events = drain_events_for(&rx, Duration::from_secs(3));
    assert!(
        events.iter().any(|event| {
            event["event"] == "scan.frameState"
                && event["payload"]["state"] == "failed"
                && event["payload"]["error"]["code"] == "NOT_CONNECTED"
        }),
        "an unconfirmed motion request must still produce the existing fail-closed event: {events:#?}"
    );
}

/// Proves the Phase 10 Plan 04 silence watchdog
/// (`LIVE-VERIFICATION-20260723.md`: a real fine-scan job went silent for
/// 25 minutes with zero wire events and no watchdog ever fired).
/// `MOCK_BRIDGE_HANG_ON_SCAN` makes `mock_bridge` accept `scan.start`
/// normally but never spawn the worker that would emit any further event
/// for that job — simulating a scan worker stuck inside its blocking
/// transport call. With a short silence deadline, this proves both halves
/// of the must-have: an honest failure surfaces well within the deadline,
/// AND the mock bridge process itself is provably untouched (still the
/// exact same live instance, not killed/restarted) — the cardinal rule
/// this whole plan exists to enforce.
///
/// The two knobs live on opposite sides of the subprocess boundary and so
/// are configured by two different mechanisms: `MOCK_BRIDGE_HANG_ON_SCAN`
/// is read by the bridge child (child-scoped via `new_with_env`), while
/// the silence deadline is read by the engine's own watchdog loop running
/// in THIS process — `Command::env` cannot reach it, so it rides on
/// `with_scan_silence_deadline` instead of
/// `SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS`. Neither touches process-global
/// state, so this test stays correct under a parallel test runner.
#[test]
fn scan_silence_past_deadline_reports_honest_failure_without_touching_the_bridge_process() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_HANG_ON_SCAN", "1")],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_HANG_ON_SCAN doesn't affect bridge.hello/device.list",
        )
        .with_scan_silence_deadline(Duration::from_secs(2)),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed — device.open is unaffected by the hang trigger");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect(
        "scan_start's own initiating call must succeed — mock_bridge accepts scan.start normally \
         even in hang mode, it just never spawns the worker that would emit further events",
    );

    // Bounded well above the 2s configured deadline (the poll-timeout cap
    // means the watchdog fires close to 2s, not the shared 10s
    // HEALTH_TIMEOUT floor), but still a hard ceiling so a regression back
    // to "hangs forever" fails this test instead of hanging the suite.
    let events = drain_events(&rx, "scan.completed", Duration::from_secs(8));

    let frame_state_failed = events
        .iter()
        .find(|event| event["event"] == "scan.frameState" && event["payload"]["state"] == "failed")
        .unwrap_or_else(|| panic!("expected a scan.frameState(failed) event: {events:#?}"));
    assert_eq!(
        frame_state_failed["payload"]["frameIndex"].as_u64(),
        Some(1),
        "the one requested-and-never-completed slot must be reported failed: {frame_state_failed:#?}"
    );
    assert_eq!(
        frame_state_failed["payload"]["error"]["code"].as_str(),
        Some("INTERNAL"),
        "PROTOCOL.md's closed ErrorCode vocabulary has no BRIDGE_STREAM_STALLED member — it is named in the message text, not a new wire code: {frame_state_failed:#?}"
    );
    assert_eq!(
        frame_state_failed["payload"]["error"]["recoverable"].as_bool(),
        Some(false),
        "the silence watchdog's failure must be recoverable:false — unlike FeedJam, no automatic retry was ever attempted: {frame_state_failed:#?}"
    );
    assert!(
        frame_state_failed["payload"]["error"]["message"]
            .as_str()
            .unwrap_or("")
            .contains("BRIDGE_STREAM_STALLED"),
        "error message must name BRIDGE_STREAM_STALLED so a future live hang self-diagnoses: {frame_state_failed:#?}"
    );
    assert!(
        frame_state_failed["payload"]["error"]["message"]
            .as_str()
            .unwrap_or("")
            .contains(
                "sessionEpoch=1; bridgeGenerationStart=1; bridgeGenerationCurrent=1; bridgeHealthy=true"
            ),
        "same-generation healthy silence must retain explicit connection evidence: {frame_state_failed:#?}"
    );

    assert!(
        events
            .iter()
            .any(|event| event["event"] == "scan.jobState" && event["payload"]["state"] == "failed"),
        "expected a scan.jobState(failed) event marking the job slot terminal: {events:#?}"
    );

    let completed_event = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .expect("scan.completed event must be present");
    let failed_slots: Vec<u64> = completed_event["payload"]["summary"]["failed"]
        .as_array()
        .expect("summary.failed must be an array")
        .iter()
        .map(|v| v.as_u64().expect("slot must be a number"))
        .collect();
    assert_eq!(failed_slots, vec![1], "events: {events:#?}");
    assert!(
        completed_event["payload"]["summary"]["completed"]
            .as_array()
            .expect("summary.completed must be an array")
            .is_empty(),
        "no frame ever completed in hang mode: {completed_event:#?}"
    );

    // The no-kill proof (the cardinal rule this test exists to prove): a
    // fresh device.status round-trip against the SAME backend must still
    // succeed and still report connected:true. mock_bridge's MockState is
    // process-local and resets on a fresh spawn (device_open starts
    // false) — connected:true here is only possible if this is still the
    // exact process instance `connect()` opened earlier in this test, i.e.
    // the watchdog never killed or restarted the bridge subprocess, and
    // never touched its in-flight (nonexistent, in this mock's case, but
    // structurally equivalent) USB work.
    let status = backend
        .status()
        .expect("status must still succeed against the same, untouched bridge process");
    assert!(
        status.connected,
        "the bridge process must still be the same live instance (device_open persisted) — \
         a kill/restart would have reset mock_bridge's in-process state"
    );
}

#[test]
fn scan_stop_always_reports_after_current_frame_mode() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("RealLs5000::new should succeed against a healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, _rx) = mpsc::channel();
    let job_id = RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("scan_start should succeed");

    let (stop_tx, _stop_rx) = mpsc::channel();
    let (acknowledged, mode) = backend
        .scan_stop(&job_id, StopMode::Immediate, stop_tx)
        .expect("scan_stop should succeed");
    assert!(acknowledged);
    assert_eq!(
        mode,
        StopMode::AfterCurrentFrame,
        "BRIDGE.md's scan.stop has no immediate mode — the result must always report AfterCurrentFrame regardless of what was requested"
    );
}

/// Proves the coordinator-directed capability-semantics correction:
/// `multiSample: false` on the real device means "no variable multi-
/// sample control exposed", never "cannot multisample" — BRIDGE.md fixes
/// every wired colorNegative capture at `multisamplePasses: 4`, and
/// `RealLs5000::scan_start` validates against a device-sourced accepted
/// set (`derive_supported_multisample_passes`) rather than a hardcoded
/// constant, rejecting any other value with a message that names the
/// field and never claims multisampling itself is unsupported.
#[test]
fn scan_start_rejects_multisample_passes_other_than_device_supported() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("RealLs5000::new should succeed against a healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let recipe = domain::CaptureRecipe {
        multisample_passes: 1,
        ..domain::CaptureRecipe::default()
    };
    let (tx, _rx) = mpsc::channel();
    let err = RealLs5000::scan_start(
        &backend,
        vec![1],
        recipe,
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect_err("multisamplePasses: 1 must be rejected — this device only accepts 4");
    assert_eq!(err.code, ErrorCode::InvalidParams);
    assert!(
        err.message.contains("multisamplePasses"),
        "error message should name the field: {}",
        err.message
    );
    assert!(
        !err.message.to_lowercase().contains("unsupported"),
        "error message must never claim multisampling itself is unsupported — the LS-5000 always multisamples, this is a fixed-value constraint: {}",
        err.message
    );
}

/// Live attempt #3 (2026-07-23 evening): the bridge's scan
/// worker raised REFEED_REQUIRED mid-job, emitting `scan.error` followed
/// immediately by `scan.completed` with every slot failed —
/// `run_real_scan_job`'s old `_ => {}` catch-all silently dropped
/// `scan.error` entirely (an unrecognized event name), and the live
/// client's own transcript proved nothing else ever arrived. Proves the
/// new `scan.error` mapping arm reports an honest failure AND that only
/// one `scan.completed` reaches the client (the drain guard against the
/// bridge's own immediately-following real closure for the same job).
#[test]
fn scan_error_reports_honest_failure_and_emits_scan_completed_exactly_once() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_SCAN_ERROR_CODE", "REFEED_REQUIRED")],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_SCAN_ERROR_CODE doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1, 2],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect(
        "scan_start's own initiating call must succeed — the mock's scan.error trigger only affects the worker, not the initiating request",
    );

    // Bounded well above the engine's own ~500ms drain-guard window, so a
    // regression back to "silently dropped" (or back to double-emission)
    // fails loudly instead of the test racing its own assertions.
    let events = drain_events_for(&rx, Duration::from_secs(3));

    let frame_state_failures: Vec<&serde_json::Value> = events
        .iter()
        .filter(|event| {
            event["event"] == "scan.frameState" && event["payload"]["state"] == "failed"
        })
        .collect();
    assert_eq!(
        frame_state_failures.len(),
        2,
        "both requested slots must be reported failed (neither was ever confirmed complete): {events:#?}"
    );
    for event in &frame_state_failures {
        assert_eq!(
            event["payload"]["error"]["recoverable"].as_bool(),
            Some(false)
        );
        assert!(
            event["payload"]["error"]["message"]
                .as_str()
                .unwrap_or("")
                .contains("REFEED_REQUIRED"),
            "error message must name the real bridge code so a future live failure self-diagnoses: {event:#?}"
        );
    }

    let scan_completed_events: Vec<&serde_json::Value> = events
        .iter()
        .filter(|event| event["event"] == "scan.completed")
        .collect();
    assert_eq!(
        scan_completed_events.len(),
        1,
        "scan.completed must fire exactly once per job even though the bridge's own worker emits its own scan.completed right behind scan.error: {events:#?}"
    );
    let summary = &scan_completed_events[0]["payload"]["summary"];
    let mut failed_slots: Vec<u64> = summary["failed"]
        .as_array()
        .expect("failed array")
        .iter()
        .map(|v| v.as_u64().unwrap())
        .collect();
    failed_slots.sort_unstable();
    assert_eq!(failed_slots, vec![1, 2]);
    assert!(summary["completed"]
        .as_array()
        .expect("completed array")
        .is_empty());

    assert!(
        events.iter().any(|event| event["event"] == "scan.jobState"
            && event["payload"]["state"] == "failed"),
        "expected a scan.jobState(failed) event: {events:#?}"
    );

    assert!(
        !events
            .iter()
            .any(|event| event["event"] == "scan.frameCompleted"),
        "no receipt/path may ever be fabricated for a frame that never actually completed: {events:#?}"
    );
}

/// Live attempt #3's `scan.error` is followed almost immediately by the
/// bridge's own real `scan.completed` for the SAME job (BRIDGE.md:
/// `scan.error` "does not replace `scan.completed`"). `BridgeClient`'s
/// `events_rx` is one process-wide channel, not scoped per job — without
/// `drain_late_bridge_closure_for` reading and discarding that trailing
/// event before `run_real_scan_job`'s thread for the FAILED job exits, it
/// would sit unread in the channel and could be wrongly consumed by the
/// NEXT job's own polling loop, which performs no `jobId` filtering of its
/// own on the (structurally guaranteed, per BRIDGE.md's single-hardware-
/// lane rule) assumption that only ITS OWN job's events can arrive while
/// it runs.
///
/// `MOCK_BRIDGE_SCAN_ERROR_CODE` is read once at mock_bridge's own process
/// startup (matching every other mock_bridge behavior-control env var's
/// established convention) — every `scan.start` against one subprocess
/// instance shares the same mode, so both jobs below run against the same
/// always-erroring subprocess rather than "job A fails, job B succeeds":
/// that still exercises exactly the race this test exists to catch (does
/// job B's own polling loop see job A's stale trailing closure instead of
/// its own scan.error?), just with both jobs on the failure path.
#[test]
fn a_second_scan_error_job_never_sees_the_first_jobs_stale_closure() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_SCAN_ERROR_CODE", "REFEED_REQUIRED")],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_SCAN_ERROR_CODE doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    // Job A: frame 1, fails via scan.error immediately followed by the
    // bridge's own real trailing scan.completed for job A.
    let (tx_a, rx_a) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx_a,
    )
    .expect("job A's initiating scan.start call must succeed");
    // Wait for job A's own client-visible terminal event — by the time
    // this arrives, job A's engine thread has already emitted its own
    // scan.completed (synchronously, before its own drain step runs).
    let _ = drain_events(&rx_a, "scan.completed", GENEROUS_TIMEOUT);

    // Give job A's own drain_late_bridge_closure_for window (bounded at
    // 500ms) room to actually run and finish reading the bridge's trailing
    // real scan.completed for job A before job B starts — this is exactly
    // the scenario the guard exists to close: without it, this sleep does
    // nothing to help, since the stale event would simply sit in the
    // channel indefinitely either way, available for job B to wrongly
    // consume the instant it starts polling.
    std::thread::sleep(Duration::from_millis(700));

    // Job B: a DIFFERENT frame (99), on the SAME backend/subprocess/
    // events_rx channel. Without the guard, job B's own polling loop would
    // dequeue job A's stale trailing scan.completed FIRST and treat IT as
    // job B's own terminal event — corrupting job B's summary with job A's
    // frame/failure data and never even reaching job B's own scan.error.
    let (tx_b, rx_b) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![99],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx_b,
    )
    .expect("job B's initiating scan.start call must succeed");

    let events_b = drain_events_for(&rx_b, Duration::from_secs(3));

    let frame_state_b = events_b
        .iter()
        .find(|event| event["event"] == "scan.frameState" && event["payload"]["state"] == "failed")
        .unwrap_or_else(|| {
            panic!("expected job B's own scan.frameState(failed) for frame 99: {events_b:#?}")
        });
    assert_eq!(
        frame_state_b["payload"]["frameIndex"].as_u64(),
        Some(99),
        "job B's own failure must name ITS OWN frame (99), never job A's leaked frame (1): {events_b:#?}"
    );

    let completed_b = events_b
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .expect("scan.completed event must be present");
    assert_eq!(
        completed_b["payload"]["summary"]["failed"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap())
            .collect::<Vec<_>>(),
        vec![99],
        "job B's own summary must reflect its own frame, never job A's leaked failure data: {events_b:#?}"
    );

    let scan_completed_count_b = events_b
        .iter()
        .filter(|event| event["event"] == "scan.completed")
        .count();
    assert_eq!(
        scan_completed_count_b, 1,
        "job B's own scan.completed must fire exactly once: {events_b:#?}"
    );
}

/// 2026-07-25 incident fix: a batch that failed via `scan.error` with zero
/// completed frames left the client's last-known `scanner.status` stuck at
/// SCANNING/busy forever, even though the hardware lane was provably free
/// by the time the bridge's own trailing `scan.completed` (for this exact
/// job) arrived. The `scan.error` mapping arm used to return without ever
/// polling status at all — unlike the `scan.completed` arm just below it,
/// and unlike both `acquire_thumbnails` arms (`roll.previewComplete`/
/// `roll.previewError`), which already poll unconditionally on success OR
/// failure. Reuses this same `MOCK_BRIDGE_SCAN_ERROR_CODE` zero-completed
/// scenario as `scan_error_reports_honest_failure_and_emits_scan_completed_exactly_once`
/// above — proves the fix without changing that test's own, narrower
/// "exactly one scan.completed" focus.
#[test]
fn scan_error_with_zero_completed_frames_still_reports_status_after_completed() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_SCAN_ERROR_CODE", "REFEED_REQUIRED")],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_SCAN_ERROR_CODE doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1, 2],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect(
        "scan_start's own initiating call must succeed — the mock's scan.error trigger only affects the worker, not the initiating request",
    );

    // Bounded well above both the engine's ~500ms drain-guard window and
    // the follow-up backend.status() bridge call this fix adds.
    let events = drain_events_for(&rx, Duration::from_secs(3));

    let completed_index = events
        .iter()
        .position(|event| event["event"] == "scan.completed")
        .unwrap_or_else(|| panic!("expected scan.completed: {events:#?}"));
    // Confirms this reproduces the exact zero-completed-frames incident
    // shape, not some other failure mode.
    assert!(
        events[completed_index]["payload"]["summary"]["completed"]
            .as_array()
            .expect("completed array")
            .is_empty(),
        "this test must reproduce a batch that failed with zero completed frames: {events:#?}"
    );

    let status_index = events
        .iter()
        .position(|event| event["event"] == "scanner.status")
        .unwrap_or_else(|| {
            panic!(
                "expected a scanner.status event after scan.error's scan.completed -- \
                 without it the client's last-known status is stuck SCANNING/busy \
                 forever even though the hardware lane is already free \
                 (2026-07-25 incident): {events:#?}"
            )
        });
    assert!(
        status_index > completed_index,
        "scanner.status must be reported AFTER scan.completed, not before or in place of it: {events:#?}"
    );
}

/// Live attempt #4 (2026-07-23 evening): hw-telemetry
/// showed `scan.start outcome ok, completed:[], failed:[1]` after an 86s
/// real scan — the transport call itself returned a summary with the slot
/// already accounted as failed, with NO `scan.error` at all. Proves the
/// pre-existing `scan.completed` mapping arm already forwards a
/// failed-only summary honestly (no receipt/path fabricated for the failed
/// slot) — locking this exact live-observed shape in as a regression test.
#[test]
fn scan_completed_with_failed_slot_and_no_scan_error_reports_honest_partial_failure() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_SCAN_FAILED_SLOTS", "1")],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_SCAN_FAILED_SLOTS doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("scan_start should succeed against a healthy bridge with a valid recipe");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);

    assert!(
        !events
            .iter()
            .any(|event| event["event"] == "scan.frameCompleted"),
        "no receipt/path may ever be fabricated for the one slot that never completed: {events:#?}"
    );

    let scan_completed_events: Vec<&serde_json::Value> = events
        .iter()
        .filter(|event| event["event"] == "scan.completed")
        .collect();
    assert_eq!(
        scan_completed_events.len(),
        1,
        "scan.completed must fire exactly once: {events:#?}"
    );
    let summary = &scan_completed_events[0]["payload"]["summary"];
    assert_eq!(
        summary["failed"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap())
            .collect::<Vec<_>>(),
        vec![1]
    );
    assert!(summary["completed"].as_array().unwrap().is_empty());
}

/// BRIDGE.md's `hardware.anomaly` (e.g. a bounded-retry-exhausted transport
/// smear) is a supplementary, non-terminal diagnostic — the SAME worker
/// thread's own `finally` block still emits the job's authoritative
/// `scan.completed` moments later. `run_real_scan_job`'s old `_ => {}`
/// catch-all silently dropped this event too (confirmed before this plan:
/// zero references to `hardware.anomaly` anywhere in real_backend.rs).
/// Proves the new mapping arm relays an honest per-slot failure for the
/// anomalied slot without pre-empting the bridge's own subsequent
/// authoritative completion of the other requested slot.
#[test]
fn hardware_anomaly_reports_honest_per_slot_failure_without_preempting_completion() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_SCAN_ANOMALY_SLOT", "1")],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_SCAN_ANOMALY_SLOT doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1, 2],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("scan_start should succeed");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);

    let anomaly_failure = events.iter().find(|event| {
        event["event"] == "scan.frameState"
            && event["payload"]["frameIndex"] == 1
            && event["payload"]["state"] == "failed"
    });
    assert!(
        anomaly_failure.is_some(),
        "expected slot 1's hardware.anomaly to surface as a frame failure: {events:#?}"
    );
    let message = anomaly_failure.unwrap()["payload"]["error"]["message"]
        .as_str()
        .unwrap_or("");
    assert!(
        message.contains("ejected"),
        "the anomaly's ejected flag must be named in the message so an operator knows the strip state: {anomaly_failure:#?}"
    );
    assert!(
        message.contains("TRANSPORT_SMEAR_DETECTED"),
        "error message must name the real bridge code: {anomaly_failure:#?}"
    );

    let frame_completed_2 = events.iter().find(|event| {
        event["event"] == "scan.frameCompleted" && event["payload"]["frameIndex"] == 2
    });
    assert!(
        frame_completed_2.is_some(),
        "slot 2 must still complete normally after slot 1's anomaly: {events:#?}"
    );

    let scan_completed_events: Vec<&serde_json::Value> = events
        .iter()
        .filter(|event| event["event"] == "scan.completed")
        .collect();
    assert_eq!(
        scan_completed_events.len(),
        1,
        "scan.completed must fire exactly once: {events:#?}"
    );
    let summary = &scan_completed_events[0]["payload"]["summary"];
    assert_eq!(
        summary["failed"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap())
            .collect::<Vec<_>>(),
        vec![1]
    );
    assert_eq!(
        summary["completed"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap())
            .collect::<Vec<_>>(),
        vec![2]
    );
}

/// Per-frame failure event `scan.frameFailed` (BRIDGE.md additive,
/// 2026-07-23): the bridge emits this event for a failing slot before
/// `scan.completed`, alongside (not replacing) the job-level terminal
/// event. `run_real_scan_job` must map it to a client-visible
/// `scan.frameState{failed}` for that exact slot, carrying the bridge's
/// code and message, and keep polling so the bridge's own `scan.completed`
/// still arrives exactly once.
#[test]
fn scan_frame_failed_maps_per_frame_failure_and_stays_non_terminal() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[("MOCK_BRIDGE_EMIT_FRAME_FAILED", "1")],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_EMIT_FRAME_FAILED doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("scan_start should succeed");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);

    let frame_state_failed = events
        .iter()
        .find(|event| {
            event["event"] == "scan.frameState"
                && event["payload"]["frameIndex"] == 1
                && event["payload"]["state"] == "failed"
        })
        .unwrap_or_else(|| {
            panic!("expected slot 1's scan.frameFailed to surface as a frame failure: {events:#?}")
        });
    let message = frame_state_failed["payload"]["error"]["message"]
        .as_str()
        .unwrap_or("");
    assert_eq!(
        frame_state_failed["payload"]["error"]["code"],
        "MANUAL_REVIEW_REQUIRED",
        "the bridge classification must remain typed on the public frame failure: {frame_state_failed:#?}"
    );
    assert_eq!(
        frame_state_failed["payload"]["error"]["recoverable"], false,
        "manual review cannot be auto-retried as if it were a transient transport failure: {frame_state_failed:#?}"
    );
    assert!(
        message.contains("MANUAL_REVIEW_REQUIRED"),
        "error message must name the real bridge code: {frame_state_failed:#?}"
    );
    assert!(
        message.contains("frame 1 requires manual review"),
        "error message must carry the bridge's payload message: {frame_state_failed:#?}"
    );

    let scan_completed_events: Vec<&serde_json::Value> = events
        .iter()
        .filter(|event| event["event"] == "scan.completed")
        .collect();
    assert_eq!(
        scan_completed_events.len(),
        1,
        "scan.completed must fire exactly once: {events:#?}"
    );
    let summary = &scan_completed_events[0]["payload"]["summary"];
    assert_eq!(
        summary["failed"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap())
            .collect::<Vec<_>>(),
        vec![1]
    );
    assert!(summary["completed"].as_array().unwrap().is_empty());
}

/// Proves `derive_supported_multisample_passes` now reads
/// `capabilities.supported_multisample_passes` off the wire (Task 3) —
/// `mock_bridge`'s `fixed_device_info()` (Task 2) reports
/// `supportedMultisamplePasses: [4]`, and that exact device-sourced value
/// is embedded in the rejection message. The accepted VALUE is unchanged
/// from 09-03 (still `[4]`) — only its SOURCE moved onto the wire, which
/// is why `scan_start_rejects_multisample_passes_other_than_device_supported`
/// above still passes unmodified as the value-level proof; this test uses
/// a different rejected value (`2`, not `1`) to exercise a distinct input.
#[test]
fn supported_multisample_passes_are_sourced_from_wire_capabilities() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("RealLs5000::new should succeed against a healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let recipe = domain::CaptureRecipe {
        multisample_passes: 2,
        ..domain::CaptureRecipe::default()
    };
    let (tx, _rx) = mpsc::channel();
    let err = RealLs5000::scan_start(
        &backend,
        vec![1],
        recipe,
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect_err(
        "multisamplePasses: 2 must be rejected — mock_bridge's wire capabilities only report [4]",
    );
    assert!(
        err.message.contains("[4]"),
        "rejection message must embed the wire-reported accepted set exactly: {}",
        err.message
    );
}

/// Plan 11-02: BRIDGE.md's own policy says `HARDWARE_LANE_BUSY` is the
/// only recoverable bridge code. Proves the `hardware.anomaly` path
/// forwards `error.recoverable: true` end to end when the bridge reports
/// that code, not the old hardcoded FeedJam-only `false`.
#[test]
fn hardware_anomaly_hardware_lane_busy_is_recoverable() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[
                ("MOCK_BRIDGE_SCAN_ANOMALY_SLOT", "1"),
                ("MOCK_BRIDGE_SCAN_ANOMALY_CODE", "HARDWARE_LANE_BUSY"),
            ],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_SCAN_ANOMALY_SLOT doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1, 2],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("scan_start should succeed");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);

    let anomaly_failure = events.iter().find(|event| {
        event["event"] == "scan.frameState"
            && event["payload"]["frameIndex"] == 1
            && event["payload"]["state"] == "failed"
    });
    assert!(
        anomaly_failure.is_some(),
        "expected slot 1's hardware.anomaly to surface as a frame failure: {events:#?}"
    );
    assert_eq!(
        anomaly_failure.unwrap()["payload"]["error"]["recoverable"].as_bool(),
        Some(true),
        "HARDWARE_LANE_BUSY must reach the client as recoverable:true: {anomaly_failure:#?}"
    );
}

/// Plan 11-02: the inverse of the above — a non-HARDWARE_LANE_BUSY bridge
/// code (FEEDER_PARKED) on `hardware.anomaly` must still report
/// `recoverable: false`, because every other code needs a different action
/// first per BRIDGE.md.
#[test]
fn hardware_anomaly_feeder_parked_is_not_recoverable() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[
                ("MOCK_BRIDGE_SCAN_ANOMALY_SLOT", "1"),
                ("MOCK_BRIDGE_SCAN_ANOMALY_CODE", "FEEDER_PARKED"),
            ],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_SCAN_ANOMALY_SLOT doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("scan_start should succeed");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);

    let anomaly_failure = events.iter().find(|event| {
        event["event"] == "scan.frameState"
            && event["payload"]["frameIndex"] == 1
            && event["payload"]["state"] == "failed"
    });
    assert!(
        anomaly_failure.is_some(),
        "expected slot 1's hardware.anomaly to surface as a frame failure: {events:#?}"
    );
    assert_eq!(
        anomaly_failure.unwrap()["payload"]["error"]["recoverable"].as_bool(),
        Some(false),
        "FEEDER_PARKED must reach the client as recoverable:false: {anomaly_failure:#?}"
    );
}

/// Plan 11-02: proves the `scan.frameFailed` path also uses
/// BRIDGE.md's code-to-recoverable table, not the FeedJam-only default.
#[test]
fn scan_frame_failed_hardware_lane_busy_is_recoverable() {
    let backend = Arc::new(
        RealLs5000::new_with_env(
            mock_bridge_bin(),
            GENEROUS_TIMEOUT,
            &[
                ("MOCK_BRIDGE_EMIT_FRAME_FAILED", "1"),
                ("MOCK_BRIDGE_EMIT_FRAME_FAILED_CODE", "HARDWARE_LANE_BUSY"),
            ],
        )
        .expect(
            "RealLs5000::new_with_env should succeed — MOCK_BRIDGE_EMIT_FRAME_FAILED doesn't affect bridge.hello/device.list",
        ),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        isolated_output_recipe(),
        std::collections::HashMap::new(),
        None,
        tx,
    )
    .expect("scan_start should succeed");

    let events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);

    let frame_state_failed = events
        .iter()
        .find(|event| {
            event["event"] == "scan.frameState"
                && event["payload"]["frameIndex"] == 1
                && event["payload"]["state"] == "failed"
        })
        .unwrap_or_else(|| {
            panic!("expected slot 1's scan.frameFailed to surface as a frame failure: {events:#?}")
        });
    assert_eq!(
        frame_state_failed["payload"]["error"]["recoverable"].as_bool(),
        Some(true),
        "HARDWARE_LANE_BUSY via scan.frameFailed must be recoverable:true: {frame_state_failed:#?}"
    );
}

/// Plan 11-02: a completed real-hardware frame's receipt is durably
/// persisted to the on-disk manifest, independent of the wire event and
/// independent of `server.rs`'s in-memory project state. Mirrors the
/// simulator's existing receipt-persistence policy (sim.rs).
#[test]
fn scan_start_persists_frame_receipts_to_manifest_for_real_hardware() {
    let backend = Arc::new(
        RealLs5000::new(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("RealLs5000::new should succeed against a healthy mock bridge"),
    );
    backend
        .connect(DEVICE_ID, &ConnectOptions::default())
        .expect("connect should succeed");

    // The process id is part of the name deliberately, not decoration:
    // `generate_project_id()` is a `SystemTime::now()` nanosecond count,
    // but macOS only advances that clock in 1µs steps (measured: ~96% of
    // back-to-back calls return the identical value). `std::env::temp_dir()`
    // is shared per-user across processes, so two concurrently-running
    // copies of this test binary that reach this line in the same
    // microsecond would otherwise agree on the directory — and the first
    // one to finish would `remove_dir_all` it out from under the other's
    // manifest write (observed as a create_project ENOENT). The pid makes
    // the path unique per process; the timestamp keeps it unique within one.
    let project_directory = std::env::temp_dir().join(format!(
        "scanstudio-real-receipt-test-{}-{}",
        std::process::id(),
        scanstudio_engine::manifest::generate_project_id()
    ));
    let (project, _directory) = scanstudio_engine::manifest::create_project(
        "Real Receipt Test",
        domain::MediaCarrier::Strip6,
        3,
        domain::FilmProcess::C41ColorNegative,
        Some(&project_directory),
    )
    .expect("create_project should succeed");

    let (tx, rx) = mpsc::channel();
    RealLs5000::scan_start(
        &backend,
        vec![1, 2],
        valid_capture_recipe(),
        domain::ProcessingRecipe::default(),
        project.recipes.clone(),
        std::collections::HashMap::new(),
        Some(project_directory.clone()),
        tx,
    )
    .expect("scan_start should succeed against a healthy bridge with a valid recipe");

    let _events = drain_events(&rx, "scan.completed", GENEROUS_TIMEOUT);

    let read_back = scanstudio_engine::manifest::read_manifest(&project_directory)
        .expect("manifest must be readable after the job");
    assert_eq!(read_back.id, project.id);
    assert!(
        !read_back.frames[0].receipts.is_empty(),
        "frame 1's receipt must be persisted to the manifest: {read_back:#?}"
    );
    assert!(
        !read_back.frames[1].receipts.is_empty(),
        "frame 2's receipt must be persisted to the manifest: {read_back:#?}"
    );
    assert!(
        read_back.frames[2].receipts.is_empty(),
        "frame 3 was not scanned and must remain receiptless: {read_back:#?}"
    );
    assert!(
        !read_back.frames[0].receipts[0].simulated,
        "the persisted receipt must be marked not simulated for real hardware"
    );
    for frame_index in 0..2 {
        let receipt = &read_back.frames[frame_index].receipts[0];
        assert_eq!(
            receipt.started_at, "2026-08-02T20:05:00+00:00",
            "the authoritative capture start must survive manifest persistence"
        );
        assert_eq!(
            receipt.duration_ms, 1900,
            "the authoritative capture duration must survive manifest persistence"
        );
    }

    let _ = std::fs::remove_dir_all(&project_directory);
}
