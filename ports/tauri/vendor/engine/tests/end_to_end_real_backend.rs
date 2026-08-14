//! Spawns the built `scanstudio-engine` binary and proves `Backends`
//! (Plan 09-04) dispatches through the correct backend based on
//! `SCANSTUDIO_BRIDGE_CMD`: unset means sim-only (byte-identical to
//! pre-Phase-9 behavior), a working bridge command adds the real device and
//! makes it connectable, and a broken command degrades to the identical
//! sim-only shape rather than crashing or half-registering a device.
//!
//! Mirrors `end_to_end_sim.rs`'s approach exactly (D-9d): real stdio pipes
//! against the actual compiled binary, no in-process shortcuts. `send`,
//! `recv_line`, and `recv_response_for` below are copied verbatim from
//! `end_to_end_sim.rs` — this crate's existing choice not to factor
//! `tests/*.rs` helpers into a shared `tests/common/mod.rs`.
//!
//! The bridge command used throughout is the Plan 09-01 `mock_bridge` test
//! double (`CARGO_BIN_EXE_mock_bridge`), set via `Command::env` on the
//! *child* process only — never `std::env::set_var` on this test process
//! itself. `SCANSTUDIO_BRIDGE_CMD` is never set to the real bridge, and no
//! test here touches the physical LS-5000 attached to this machine.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    mpsc,
};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

/// Reserves an empty, test-owned output directory. The create loop makes
/// repeated runs hermetic even when a prior failed run left its directory
/// behind or the operating system later reuses a process id.
fn unique_output_destination(label: &str) -> PathBuf {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    loop {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "scanstudio-e2e-{label}-{}-{id}",
            std::process::id()
        ));
        match std::fs::create_dir(&path) {
            Ok(()) => return path,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => panic!(
                "reserve unique test output directory {}: {error}",
                path.display()
            ),
        }
    }
}

fn send(stdin: &mut impl Write, id: u64, method: &str, params: Value) {
    let req = json!({"id": id, "method": method, "params": params});
    let line = serde_json::to_string(&req).expect("serialize request");
    writeln!(stdin, "{line}").expect("write request line");
    stdin.flush().expect("flush stdin");
}

fn recv_line(rx: &mpsc::Receiver<String>) -> Value {
    let line = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("timed out waiting for a line from the engine");
    serde_json::from_str(&line)
        .unwrap_or_else(|err| panic!("bad JSON line from engine: {line}: {err}"))
}

/// Drains lines until one whose top-level `id` matches `id`, returning it.
/// Events observed while draining are forwarded to `on_event`.
fn recv_response_for(
    rx: &mpsc::Receiver<String>,
    id: u64,
    mut on_event: impl FnMut(&Value),
) -> Value {
    loop {
        let v = recv_line(rx);
        if v.get("id") == Some(&json!(id)) {
            return v;
        }
        if v.get("event").is_some() {
            on_event(&v);
        }
    }
}

/// Collects lines from `rx` (both `id`-correlated responses and
/// `event`-shaped values, indiscriminately) until one matching `predicate`
/// arrives, bounded by `overall_deadline` measured from THIS call's own
/// start — deliberately NOT a per-line timeout like `recv_line`'s, so the
/// bound is exact about total elapsed wall-clock time regardless of how
/// many lines arrive along the way. Plan 10-06's whole point is measuring
/// exactly that total: the pre-fix defect and its fix differ only in HOW
/// LONG the honest-failure sequence takes to arrive, not in its shape.
fn drain_until(
    rx: &mpsc::Receiver<String>,
    overall_deadline: Duration,
    mut predicate: impl FnMut(&Value) -> bool,
) -> Vec<Value> {
    let deadline = Instant::now() + overall_deadline;
    let mut collected = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            panic!(
                "timed out after {overall_deadline:?} waiting for a matching line; \
                 collected so far: {collected:#?}"
            );
        }
        let line = match rx.recv_timeout(remaining) {
            Ok(l) => l,
            Err(_) => {
                panic!("channel closed/timed out while waiting; collected so far: {collected:#?}")
            }
        };
        let value: Value = serde_json::from_str(&line)
            .unwrap_or_else(|err| panic!("bad JSON line from engine: {line}: {err}"));
        let is_match = predicate(&value);
        collected.push(value);
        if is_match {
            return collected;
        }
    }
}

/// Bounded wait for the child to exit after `engine.shutdown` — mirrors
/// `end_to_end_sim.rs`'s own bounded-exit-wait shape
/// (`closing_stdin_cancels_an_active_job_without_hanging`). Never an
/// unbounded `child.wait()`: a hang here must fail the test loudly rather
/// than block the suite forever.
fn wait_for_exit_bounded(
    child: &mut std::process::Child,
    bound: Duration,
) -> std::process::ExitStatus {
    let deadline = std::time::Instant::now() + bound;
    loop {
        if let Some(status) = child.try_wait().expect("poll engine process") {
            return status;
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            panic!("engine did not exit within {bound:?} after engine.shutdown");
        }
        thread::sleep(Duration::from_millis(10));
    }
}

/// With `SCANSTUDIO_BRIDGE_CMD` unset, `scanner.list` must show exactly one
/// simulated device — the literal regression proof that Phase 9 changed
/// nothing about the sim-only starting behavior.
#[test]
fn sim_only_when_bridge_cmd_unset() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        // Defensive: in case the test runner's own environment happens to
        // have this set, make sure this specific session never sees it.
        .env_remove("SCANSTUDIO_BRIDGE_CMD")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-real-backend-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(&mut stdin, 2, "scanner.list", json!({}));
    let list_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        list_resp.get("error").is_none(),
        "scanner.list failed: {list_resp:?}"
    );
    let devices = list_resp["result"]["devices"]
        .as_array()
        .expect("devices must be an array");
    assert_eq!(
        devices.len(),
        1,
        "with SCANSTUDIO_BRIDGE_CMD unset, scanner.list must show exactly one device: {devices:?}"
    );
    assert_eq!(devices[0]["kind"], json!("simulated"));

    send(&mut stdin, 3, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// Starts a server session connected to the real-backend mock while applying
/// failure injection only to the bridge child. IDs 1-2 are consumed by hello
/// and connect; callers start at ID 3.
fn spawn_connected_engine_with_bridge_env(
    client_name: &str,
    bridge_env: &[(&str, &str)],
) -> (
    std::process::Child,
    std::process::ChildStdin,
    mpsc::Receiver<String>,
    thread::JoinHandle<()>,
) {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut command = Command::new(bin);
    command
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .envs(bridge_env.iter().copied())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    let mut child = command.spawn().expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(line) => {
                    if tx.send(line).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": client_name, "protocolVersion": 1}),
    );
    assert!(recv_response_for(&rx, 1, |_| {}).get("error").is_none());
    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect = recv_response_for(&rx, 2, |_| {});
    assert!(
        connect.get("error").is_none(),
        "initial real connect failed: {connect:#?}"
    );

    (child, stdin, rx, reader_handle)
}

fn read_mock_bridge_calls(log_path: &std::path::Path) -> Vec<String> {
    std::fs::read_to_string(log_path)
        .unwrap_or_else(|error| panic!("read mock bridge call log {}: {error}", log_path.display()))
        .lines()
        .map(str::to_owned)
        .collect()
}

/// The public engine wire status is a direct projection of the bridge's
/// read-only `motionArmed` observation on a fresh status request. It never
/// performs an arming action itself.
#[test]
fn real_engine_status_forwards_live_motion_armed_observation() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-real-motion-status",
        &[("MOCK_BRIDGE_MOTION_ARMED", "true")],
    );

    // The helper consumes scanner.connect's id 2 response, so make an
    // explicit fresh request as the public end-to-end proof.
    send(&mut stdin, 3, "scanner.status", json!({}));
    let status = recv_response_for(&rx, 3, |_| {});
    assert_eq!(status["result"]["motionArmed"], true, "{status:#?}");

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

/// A real bridge can reject a motion-capable preview because its live
/// SAFE-02 re-check is unarmed. The public engine error must retain that
/// operator-actionable classification rather than flattening it to INTERNAL.
#[test]
fn preview_motion_not_armed_surfaces_a_typed_public_error() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-motion-not-armed",
        &[("MOCK_BRIDGE_REJECT_PREVIEW_MOTION_NOT_ARMED", "1")],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1], "operationId": "unarmed-preview"}),
    );
    let preview = recv_response_for(&rx, 3, |_| {});
    assert_eq!(
        preview["error"]["code"],
        "HW_MOTION_NOT_ARMED",
        "the live bridge refusal must not be flattened: {preview:#?}"
    );
    assert_eq!(preview["error"]["recoverable"], false);

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

/// WV-5 (first live Windows validation, 2026-08-13): a preview requested on
/// an empty transport spent minutes in motion-adjacent work and completed
/// with zero frames and no explanation anywhere in the UI. The engine now
/// probes a fresh status before opening the preview lane and refuses typed
/// (`NO_MEDIA`) when film is definitively absent; the mock's call log proves
/// `roll.preview` was never sent. A `null` (undetermined) probe still
/// proceeds -- preview is exactly how presence becomes known on transports
/// that cannot report it -- so only the definitive `false` is gated.
#[test]
fn preview_with_film_definitively_absent_refuses_typed_before_any_motion() {
    let log_directory = unique_output_destination("film-absent-preview-call-log");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-film-absent-preview",
        &[
            ("MOCK_BRIDGE_FILM_PRESENT", "false"),
            ("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str()),
        ],
    );

    std::fs::write(&log_path, "").expect("reset mock bridge call log");
    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"operationId": "film-absent-preview"}),
    );
    let preview = recv_response_for(&rx, 3, |_| {});
    assert_eq!(
        preview["error"]["code"], "NO_MEDIA",
        "a definitively empty transport must refuse the preview typed: {preview:#?}"
    );
    let calls = read_mock_bridge_calls(&log_path);
    assert!(
        !calls.iter().any(|call| call == "roll.preview"),
        "the refusal must happen before any motion-capable bridge call: {calls:#?}"
    );
    assert!(
        calls.iter().any(|call| call == "device.status"),
        "the gate must have probed a fresh status rather than a cached snapshot: {calls:#?}"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// `roll.approve` is a public, real-device-only acknowledgement of an
/// existing preview warning. It must make exactly one non-motion bridge call:
/// it does not refresh status, acquire another preview, or start capture.
#[test]
fn roll_approve_for_previewed_real_frame_forwards_one_non_motion_bridge_call() {
    let log_directory = unique_output_destination("roll-approve-call-log");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-approve",
        &[
            ("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str()),
            // Adversarial review S3 (2026-08-08): roll_approve now requires
            // the approved frame to be one the completed preview flagged
            // `needsApproval: true` -- mark frame 2 (the one this test
            // approves) so this test keeps exercising its own actual
            // subject (one clean, unpolled bridge call) rather than
            // tripping the new gate.
            ("MOCK_BRIDGE_PREVIEW_APPROVAL_SLOTS", "2"),
        ],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1, 2, 3], "operationId": "approval-preview"}),
    );
    let preview = recv_response_for(&rx, 3, |_| {});
    assert!(preview.get("error").is_none(), "preview failed: {preview:#?}");

    // Wait for the real-backend preview worker's terminal status refresh,
    // then reset the observation boundary. Everything after this point must
    // be the approval request itself — no hidden status polling or motion.
    let preview_events = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "approval-preview"
    });
    assert!(
        preview_events
            .iter()
            .any(|event| event["event"] == "scanner.thumbnailsComplete"),
        "a bridge approval must follow a completed preview: {preview_events:#?}"
    );
    let terminal_status = preview_events
        .iter()
        .find(|event| event["event"] == "scanner.status")
        .expect("completed preview must publish a terminal public status");
    assert_eq!(
        terminal_status["payload"]["status"]["mediaLoaded"], true,
        "only a terminally completed preview may claim media is established: {terminal_status:#?}"
    );
    assert_eq!(
        terminal_status["payload"]["status"]["frameCount"], 3,
        "terminal public status must expose the bridge's truthful preview slot count: {terminal_status:#?}"
    );
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        4,
        "roll.approve",
        json!({"frameIndex": 2, "operationId": "approval-preview"}),
    );
    let approval = recv_response_for(&rx, 4, |_| {});
    assert!(
        approval.get("error").is_none(),
        "a previewed real frame should be approvable: {approval:#?}"
    );
    assert_eq!(approval["result"], json!({}));
    assert_eq!(
        read_mock_bridge_calls(&log_path),
        vec!["roll.approve"],
        "approval must issue exactly one bridge call and must not poll status, preview, or start capture"
    );

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// Alignment is a non-motion update to the bridge-owned preview session. The
/// public frame index maps to the bridge slot, and the refreshed thumbnail is
/// returned synchronously without a status poll or a new traversal.
#[test]
fn roll_set_spacing_offset_updates_the_bound_preview_and_returns_its_thumbnail() {
    let log_directory = unique_output_destination("roll-spacing-offset-call-log");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-spacing-offset",
        &[("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str())],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1, 2, 3], "operationId": "alignment-preview"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status" && event["payload"]["operationId"] == "alignment-preview"
    });
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        4,
        "roll.setSpacingOffset",
        json!({
            "frameIndex": 2,
            "offsetRows": -17,
            "operationId": "alignment-preview"
        }),
    );
    let update = recv_response_for(&rx, 4, |_| {});
    assert!(
        update.get("error").is_none(),
        "a current preview frame should accept a bounded spacing offset: {update:#?}"
    );
    assert_eq!(
        update["result"]["thumbnail"]["boundaryRows"],
        json!([10, 800])
    );
    assert_eq!(update["result"]["thumbnail"]["spacingOffset"], json!(-17));
    let first_image_path = update["result"]["thumbnail"]["imagePath"]
        .as_str()
        .expect("the refreshed thumbnail must remain loadable")
        .to_string();
    assert!(
        !first_image_path.is_empty(),
        "the refreshed thumbnail must remain loadable: {update:#?}"
    );

    send(
        &mut stdin,
        5,
        "roll.setSpacingOffset",
        json!({
            "frameIndex": 2,
            "offsetRows": -16,
            "operationId": "alignment-preview"
        }),
    );
    let second_update = recv_response_for(&rx, 5, |_| {});
    assert!(
        second_update.get("error").is_none(),
        "a second bounded spacing offset should replace the tile: {second_update:#?}"
    );
    let second_image_path = second_update["result"]["thumbnail"]["imagePath"]
        .as_str()
        .expect("the second refreshed thumbnail must remain loadable");
    assert_ne!(
        second_image_path, first_image_path,
        "every adjusted tile needs a fresh path so the UI image cache cannot reuse the prior crop"
    );
    assert_eq!(
        read_mock_bridge_calls(&log_path),
        vec!["roll.setSpacingOffset", "roll.setSpacingOffset"],
        "each alignment must issue exactly one non-motion bridge call"
    );

    send(&mut stdin, 6, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 6, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// A spacing update is meaningful only for a frame that the bound preview
/// actually returned. Rejecting an absent frame locally prevents a stale or
/// fabricated UI tile from reaching the driver-owned preview session.
#[test]
fn roll_set_spacing_offset_rejects_a_frame_absent_from_the_bound_preview() {
    let log_directory = unique_output_destination("roll-spacing-offset-absent-frame");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-spacing-offset-absent-frame",
        &[("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str())],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1, 2, 3], "operationId": "three-frame-preview"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "three-frame-preview"
    });
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        4,
        "roll.setSpacingOffset",
        json!({
            "frameIndex": 4,
            "offsetRows": 8,
            "operationId": "three-frame-preview"
        }),
    );
    let update = recv_response_for(&rx, 4, |_| {});
    assert_eq!(update["error"]["code"], "INVALID_PARAMS", "{update:#?}");
    assert!(
        read_mock_bridge_calls(&log_path).is_empty(),
        "an absent preview frame must be rejected before bridge traffic"
    );

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// The first frame has no predecessor to overlap, so it may move only
/// forward. Every later frame may move one full 144-row spacing interval in
/// either direction. Both endpoints are intentionally inclusive.
#[test]
fn roll_set_spacing_offset_enforces_frame_specific_inclusive_bounds_locally() {
    let log_directory = unique_output_destination("roll-spacing-offset-bounds");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-spacing-offset-bounds",
        &[("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str())],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1, 2], "operationId": "bounded-preview"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status" && event["payload"]["operationId"] == "bounded-preview"
    });
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    for (request_id, frame_index, offset_rows) in
        [(4, 1, 0), (5, 1, 144), (6, 2, -144), (7, 2, 144)]
    {
        send(
            &mut stdin,
            request_id,
            "roll.setSpacingOffset",
            json!({
                "frameIndex": frame_index,
                "offsetRows": offset_rows,
                "operationId": "bounded-preview"
            }),
        );
        let update = recv_response_for(&rx, request_id, |_| {});
        assert!(
            update.get("error").is_none(),
            "inclusive boundary ({frame_index}, {offset_rows}) was rejected: {update:#?}"
        );
        assert_eq!(
            update["result"]["thumbnail"]["spacingOffset"],
            json!(offset_rows)
        );
    }
    assert_eq!(
        read_mock_bridge_calls(&log_path),
        vec![
            "roll.setSpacingOffset",
            "roll.setSpacingOffset",
            "roll.setSpacingOffset",
            "roll.setSpacingOffset"
        ]
    );
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    for (request_id, frame_index, offset_rows) in
        [(8, 1, -1), (9, 1, 145), (10, 2, -145), (11, 2, 145)]
    {
        send(
            &mut stdin,
            request_id,
            "roll.setSpacingOffset",
            json!({
                "frameIndex": frame_index,
                "offsetRows": offset_rows,
                "operationId": "bounded-preview"
            }),
        );
        let update = recv_response_for(&rx, request_id, |_| {});
        assert_eq!(
            update["error"]["code"], "INVALID_PARAMS",
            "out-of-range ({frame_index}, {offset_rows}) was accepted: {update:#?}"
        );
    }
    assert!(
        read_mock_bridge_calls(&log_path).is_empty(),
        "out-of-range offsets must be rejected before bridge traffic"
    );

    send(&mut stdin, 12, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 12, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// A real preview alignment is consumed by the driver session when it
/// positions the frame. The persisted offset remains useful provenance, but
/// must never be interpreted a second time as a pixel crop of the completed
/// scanner raster.
#[test]
fn real_scan_does_not_reapply_transport_alignment_as_a_derivative_crop() {
    let project_directory = unique_output_destination("transport-alignment-project");
    let positive_directory = project_directory.join("Positive");
    let (mut child, mut stdin, rx, reader_handle) =
        spawn_connected_engine_with_bridge_env("e2e-transport-alignment-no-double-crop", &[]);

    send(
        &mut stdin,
        3,
        "project.create",
        json!({
            "name": "Transport Alignment Test",
            "carrier": "strip6",
            "frameCount": 3,
            "filmProcess": "positive",
            "directory": project_directory.display().to_string()
        }),
    );
    let create = recv_response_for(&rx, 3, |_| {});
    assert!(
        create.get("error").is_none(),
        "project.create failed: {create:#?}"
    );

    send(
        &mut stdin,
        4,
        "scanner.acquireThumbnails",
        json!({"frames": [1], "operationId": "transport-alignment-preview"}),
    );
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "transport-alignment-preview"
    });

    send(
        &mut stdin,
        5,
        "roll.setSpacingOffset",
        json!({
            "frameIndex": 1,
            "offsetRows": 1,
            "operationId": "transport-alignment-preview"
        }),
    );
    let alignment = recv_response_for(&rx, 5, |_| {});
    assert!(
        alignment.get("error").is_none(),
        "transport alignment failed: {alignment:#?}"
    );

    send(
        &mut stdin,
        6,
        "project.setFrameAlignment",
        json!({
            "frameIndex": 1,
            "alignment": {"offsetRows": 1, "approved": true}
        }),
    );
    let persisted = recv_response_for(&rx, 6, |_| {});
    assert!(
        persisted.get("error").is_none(),
        "project alignment persistence failed: {persisted:#?}"
    );

    send(
        &mut stdin,
        7,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "enabled": false,
                    "fullCapturePackage": false,
                    "destination": project_directory.join("disabled-archive").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {
                    "enabled": true,
                    "destination": positive_directory.display().to_string(),
                    "filenameTemplate": "frame-####",
                    "fileFormat": "tiff",
                    "colorProfile": "adobeRgb1998"
                },
                "preview": {"enabled": false}
            }
        }),
    );
    let start = recv_response_for(&rx, 7, |_| {});
    assert!(
        start.get("error").is_none(),
        "scan.start failed: {start:#?}"
    );
    let events = drain_until(&rx, Duration::from_secs(8), |event| {
        event["event"] == "scan.completed"
    });
    let completed = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .expect("scan.completed event must be present");
    assert_eq!(
        completed["payload"]["summary"]["completed"],
        json!([1]),
        "transport alignment must not make derivative rendering fail: {events:#?}"
    );
    assert_eq!(completed["payload"]["summary"]["failed"], json!([]));

    let frame_completed = events
        .iter()
        .find(|event| event["event"] == "scan.frameCompleted")
        .expect("successful derivative must emit scan.frameCompleted");
    let positive_path = frame_completed["payload"]["receipt"]["outputs"]["positivePath"]
        .as_str()
        .expect("positivePath must be present");
    assert!(
        std::path::Path::new(positive_path).is_file(),
        "positive derivative was not written: {positive_path}"
    );

    send(&mut stdin, 8, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 8, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(project_directory);
}

/// Preview already owns the manual-review decision. The public engine event
/// must preserve that evidence so ScanStudio can ask for approval before the
/// first scan.start rather than discovering it after a partial hardware batch.
#[test]
fn real_preview_forwards_manual_review_metadata_before_scan_start() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-preview-manual-review-metadata",
        &[("MOCK_BRIDGE_PREVIEW_APPROVAL_SLOTS", "3")],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({
            "frames": [1, 2, 3],
            "operationId": "manual-review-preview"
        }),
    );
    let preview = recv_response_for(&rx, 3, |_| {});
    assert!(preview.get("error").is_none(), "preview failed: {preview:#?}");

    let events = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.thumbnailsComplete"
    });
    let flagged = events
        .iter()
        .find(|event| {
            event["event"] == "scanner.thumbnail"
                && event["payload"]["frameIndex"] == 3
        })
        .unwrap_or_else(|| panic!("missing frame-3 thumbnail event: {events:#?}"));
    assert_eq!(flagged["payload"]["thumbnail"]["needsApproval"], true);
    assert_eq!(
        flagged["payload"]["thumbnail"]["warnings"],
        json!(["ambiguous-content-tail-boundary"])
    );
    assert_eq!(
        flagged["payload"]["thumbnail"]["boundaryRows"],
        json!([10, 800]),
        "the public thumbnail must preserve the bridge's detected frame boundary"
    );
    assert_eq!(
        flagged["payload"]["thumbnail"]["spacingOffset"],
        json!(3),
        "the public thumbnail must preserve the bridge's current transport offset"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

/// Approval must be bound to the exact completed preview that exposed the
/// review warning. A different correlation token is a local validation
/// failure, not a reason to call into the bridge's current roll session.
#[test]
fn roll_approve_rejects_a_mismatched_preview_operation_without_bridge_call() {
    let log_directory = unique_output_destination("roll-approve-mismatched-operation");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-approve-mismatched-operation",
        &[("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str())],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1], "operationId": "bound-preview"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "bound-preview"
    });
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        4,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "wrong-preview"}),
    );
    let approval = recv_response_for(&rx, 4, |_| {});
    assert_eq!(approval["error"]["code"], "INVALID_PARAMS", "{approval:#?}");
    assert!(
        read_mock_bridge_calls(&log_path).is_empty(),
        "a mismatched operation ID must be rejected before bridge traffic"
    );

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// The public approval shape has no legacy fallback: an absent or whitespace
/// correlation token is refused locally before it could affect bridge state.
#[test]
fn roll_approve_rejects_missing_or_empty_operation_id_without_bridge_call() {
    let log_directory = unique_output_destination("roll-approve-required-operation");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-approve-required-operation",
        &[("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str())],
    );
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(&mut stdin, 3, "roll.approve", json!({"frameIndex": 1}));
    let missing = recv_response_for(&rx, 3, |_| {});
    assert_eq!(missing["error"]["code"], "INVALID_PARAMS", "{missing:#?}");

    send(
        &mut stdin,
        4,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "   "}),
    );
    let empty = recv_response_for(&rx, 4, |_| {});
    assert_eq!(empty["error"]["code"], "INVALID_PARAMS", "{empty:#?}");
    assert!(
        read_mock_bridge_calls(&log_path).is_empty(),
        "missing or empty approval tokens must be rejected before bridge traffic"
    );

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// A second completed preview supersedes the first even when both previews
/// belong to the same still-open bridge session.
#[test]
fn roll_approve_rejects_an_operation_stale_after_a_newer_preview_without_bridge_call() {
    let log_directory = unique_output_destination("roll-approve-stale-preview");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-approve-stale-preview",
        &[
            ("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str()),
            // Adversarial review S3 (2026-08-08): flag frame 1 in both
            // previews so this test's real subject (stale vs. current
            // operationId) is what decides the outcome, not the new
            // needsApproval gate.
            ("MOCK_BRIDGE_PREVIEW_APPROVAL_SLOTS", "1"),
        ],
    );

    for (id, operation_id) in [(3, "first-preview"), (4, "second-preview")] {
        send(
            &mut stdin,
            id,
            "scanner.acquireThumbnails",
            json!({"frames": [1], "operationId": operation_id}),
        );
        assert!(recv_response_for(&rx, id, |_| {}).get("error").is_none());
        let _ = drain_until(&rx, Duration::from_secs(5), |event| {
            event["event"] == "scanner.status"
                && event["payload"]["operationId"] == operation_id
        });
    }
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        5,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "first-preview"}),
    );
    let stale = recv_response_for(&rx, 5, |_| {});
    assert_eq!(stale["error"]["code"], "INVALID_PARAMS", "{stale:#?}");
    assert!(
        read_mock_bridge_calls(&log_path).is_empty(),
        "a superseded preview token must be refused before bridge traffic"
    );

    send(
        &mut stdin,
        6,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "second-preview"}),
    );
    let current = recv_response_for(&rx, 6, |_| {});
    assert!(current.get("error").is_none(), "{current:#?}");
    assert_eq!(read_mock_bridge_calls(&log_path), vec!["roll.approve"]);

    send(&mut stdin, 7, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 7, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// Bridge preview terminal events are process-global and carry no request
/// identity. A successor therefore may not be dispatched while the first
/// accepted preview still owns that event stream: otherwise the successor
/// worker could consume the predecessor's late terminal event and mint an
/// approval authority for work it did not perform.
#[test]
fn overlapping_preview_is_rejected_before_bridge_and_cannot_authorize_approval() {
    let log_directory = unique_output_destination("overlapping-preview-call-log");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-overlapping-preview",
        &[
            ("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str()),
            // Keep the predecessor terminal out of the engine queue until
            // after the successor request and approval attempt complete.
            ("MOCK_BRIDGE_PREVIEW_DELAY_MS", "1000"),
        ],
    );
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1], "operationId": "predecessor-preview"}),
    );
    let predecessor = recv_response_for(&rx, 3, |_| {});
    assert!(
        predecessor.get("error").is_none(),
        "predecessor preview should be accepted: {predecessor:#?}"
    );

    // Deliberately issue the successor without reading or draining any
    // terminal completion from the predecessor.
    send(
        &mut stdin,
        4,
        "scanner.acquireThumbnails",
        json!({"frames": [1], "operationId": "successor-preview"}),
    );
    let successor = recv_response_for(&rx, 4, |_| {});
    assert_eq!(
        successor["error"]["code"], "SCANNER_BUSY",
        "an untagged preview event stream must have exactly one engine owner: {successor:#?}"
    );
    assert_eq!(
        read_mock_bridge_calls(&log_path),
        // The accepted first preview probes film presence (one
        // device.status) and then opens its stream; the rejected successor
        // must contribute NOTHING to this log -- not a probe, not a preview.
        vec!["device.status", "roll.preview"],
        "the rejected successor must not issue any bridge call"
    );

    send(
        &mut stdin,
        5,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "successor-preview"}),
    );
    let approval = recv_response_for(&rx, 5, |_| {});
    assert_eq!(
        approval["error"]["code"], "INVALID_PARAMS",
        "a rejected successor can never acquire approval authority: {approval:#?}"
    );
    assert_eq!(
        read_mock_bridge_calls(&log_path),
        vec!["device.status", "roll.preview"],
        "neither the successor preview nor its approval may reach the bridge"
    );

    // Drain the accepted predecessor only after every adversarial assertion,
    // then close the child cleanly.
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "predecessor-preview"
    });
    send(&mut stdin, 6, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 6, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// Reconnection creates a new bridge/session identity. An approval token from
/// the prior connection must not be replayable against the replacement route.
#[test]
fn roll_approve_rejects_an_operation_stale_after_reconnect_without_bridge_call() {
    let log_directory = unique_output_destination("roll-approve-stale-reconnect");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-approve-stale-reconnect",
        &[("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str())],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1], "operationId": "old-session-preview"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "old-session-preview"
    });

    send(&mut stdin, 4, "scanner.disconnect", json!({}));
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    send(
        &mut stdin,
        5,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let reconnect = recv_response_for(&rx, 5, |_| {});
    assert!(reconnect.get("error").is_none(), "{reconnect:#?}");
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        6,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "old-session-preview"}),
    );
    let stale = recv_response_for(&rx, 6, |_| {});
    assert_eq!(stale["error"]["code"], "INVALID_PARAMS", "{stale:#?}");
    assert!(
        read_mock_bridge_calls(&log_path).is_empty(),
        "a pre-reconnect approval token must be refused before bridge traffic"
    );

    send(&mut stdin, 7, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 7, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// A terminal preview error must return the public status to the unestablished
/// state and may not leave its operation token eligible for approval.
#[test]
fn failed_preview_never_claims_established_media_or_authorizes_approval() {
    let log_directory = unique_output_destination("failed-preview-state");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-failed-preview-state",
        &[
            ("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str()),
            ("MOCK_BRIDGE_PREVIEW_ERROR_CODE", "REFEED_REQUIRED"),
        ],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1], "operationId": "failed-preview"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let events = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "failed-preview"
    });
    assert!(
        events.iter().any(|event| {
            event["event"] == "scanner.thumbnailsFailed"
                && event["payload"]["code"] == "REFEED_REQUIRED"
        }),
        "a preview error must be public rather than fabricated as a successful preview: {events:#?}"
    );
    let terminal_status = events
        .iter()
        .find(|event| event["event"] == "scanner.status")
        .expect("failed preview must publish terminal status");
    assert_eq!(terminal_status["payload"]["status"]["mediaLoaded"], false);
    assert!(terminal_status["payload"]["status"]["frameCount"].is_null());
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        4,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "failed-preview"}),
    );
    let approval = recv_response_for(&rx, 4, |_| {});
    assert_eq!(approval["error"]["code"], "INVALID_PARAMS", "{approval:#?}");
    assert!(read_mock_bridge_calls(&log_path).is_empty());

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// If the bridge dies while accepting approval, the approval is not retried
/// against its replacement process. The engine retires that session and the
/// next public request fails locally instead of accidentally approving a
/// different preview/session.
#[test]
fn roll_approve_session_loss_is_not_retried_and_requires_reconnect() {
    let log_directory = unique_output_destination("roll-approve-session-loss-log");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-approve-session-loss",
        &[
            ("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str()),
            ("MOCK_BRIDGE_CRASH_ON", "roll.approve"),
            // Adversarial review S3 (2026-08-08): flag frame 1 so the
            // approve request reaches the bridge (and hits the crash
            // injection this test is actually about) instead of being
            // refused earlier by the new needsApproval gate.
            ("MOCK_BRIDGE_PREVIEW_APPROVAL_SLOTS", "1"),
        ],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1], "operationId": "approval-loss-preview"}),
    );
    assert!(
        recv_response_for(&rx, 3, |_| {}).get("error").is_none(),
        "preview should be accepted before approval-loss injection"
    );
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "approval-loss-preview"
    });
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        4,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "approval-loss-preview"}),
    );
    let mut disconnected_events = 0;
    let loss = recv_response_for(&rx, 4, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            disconnected_events += 1;
        }
    });
    assert_eq!(loss["error"]["code"], "NOT_CONNECTED", "{loss:#?}");
    assert_eq!(disconnected_events, 1, "session loss owns one offline status");

    send(
        &mut stdin,
        5,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "approval-loss-preview"}),
    );
    let retry = recv_response_for(&rx, 5, |_| {});
    assert_eq!(retry["error"]["code"], "NOT_CONNECTED", "{retry:#?}");
    let calls_after_loss = read_mock_bridge_calls(&log_path);
    assert_eq!(
        calls_after_loss
            .iter()
            .filter(|method| method.as_str() == "roll.approve")
            .count(),
        1,
        "after loss the engine must never retry approval on a replacement bridge: {calls_after_loss:?}"
    );
    assert!(
        !calls_after_loss.iter().any(|method| {
            matches!(method.as_str(), "device.open" | "device.status" | "roll.preview" | "scan.start")
        }),
        "after loss the engine must not reconstruct a session, poll status, or move film: {calls_after_loss:?}"
    );

    send(&mut stdin, 6, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 6, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// A synchronous call made inside an established bridge-owned session must
/// not surface a process exit as a generic INTERNAL error. BridgeClient
/// restarts the child after the crash, so retaining the old active route would
/// lie about device.open ownership until a later request happened to receive
/// the replacement child's typed NOT_CONNECTED.
#[test]
fn synchronous_status_process_exit_invalidates_once_and_requires_explicit_reconnect() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-sync-status-session-loss",
        &[("MOCK_BRIDGE_CRASH_ON", "device.status")],
    );

    send(&mut stdin, 3, "scanner.status", json!({}));
    let mut disconnected_events = 0;
    let status_failure = recv_response_for(&rx, 3, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            disconnected_events += 1;
        }
    });
    assert_eq!(
        status_failure["error"]["code"],
        "NOT_CONNECTED",
        "a session-scoped process exit must be typed as connection loss: {status_failure:#?}"
    );
    assert_eq!(
        disconnected_events, 1,
        "the ownership transition must emit exactly one disconnected status"
    );

    // The route is now retired locally. This request must neither touch the
    // replacement child nor duplicate the disconnected status.
    send(&mut stdin, 4, "scanner.status", json!({}));
    let mut duplicate_disconnected_events = 0;
    let disconnected_status = recv_response_for(&rx, 4, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            duplicate_disconnected_events += 1;
        }
    });
    assert_eq!(disconnected_status["error"]["code"], "NOT_CONNECTED");
    assert_eq!(duplicate_disconnected_events, 0);

    // Only this explicit request may open the replacement bridge child.
    send(
        &mut stdin,
        5,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let reconnect = recv_response_for(&rx, 5, |_| {});
    assert!(
        reconnect.get("error").is_none(),
        "explicit reconnect must establish a fresh session: {reconnect:#?}"
    );
    assert_eq!(reconnect["result"]["status"]["connected"], true);

    send(&mut stdin, 6, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 6, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

/// A scan's terminal events are already honest and final before its safe
/// device.status refresh. If that refresh discovers that the owning bridge
/// process died, the refresh failure must still retire the session and emit
/// exactly one disconnected status instead of being silently discarded.
#[test]
fn terminal_scan_status_process_exit_invalidates_once_after_completion() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-terminal-scan-status-session-loss",
        &[("MOCK_BRIDGE_CRASH_ON", "device.status")],
    );
    let output_directory = unique_output_destination("terminal-status-session-loss");

    send(
        &mut stdin,
        3,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": output_directory.display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start = recv_response_for(&rx, 3, |_| {});
    assert!(start.get("error").is_none(), "scan.start failed: {start:#?}");

    let terminal_events = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scan.completed"
    });
    assert!(
        terminal_events
            .iter()
            .any(|event| event["event"] == "scan.completed"),
        "the accepted scan must close terminally before the status refresh: {terminal_events:#?}"
    );

    let line = rx
        .recv_timeout(Duration::from_secs(3))
        .expect("terminal status process loss must emit a disconnected status");
    let disconnected: Value =
        serde_json::from_str(&line).expect("engine must emit valid JSON after terminal loss");
    assert_eq!(
        disconnected["event"], "scanner.status",
        "the next terminal-refresh outcome must be authoritative status: {disconnected:#?}"
    );
    assert_eq!(disconnected["payload"]["status"]["connected"], false);
    assert!(disconnected["payload"]["operationId"].is_null());

    send(&mut stdin, 4, "scanner.status", json!({}));
    let mut duplicate_disconnected_events = 0;
    let local_status = recv_response_for(&rx, 4, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            duplicate_disconnected_events += 1;
        }
    });
    assert_eq!(local_status["error"]["code"], "NOT_CONNECTED");
    assert_eq!(duplicate_disconnected_events, 0);

    send(
        &mut stdin,
        5,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let reconnect = recv_response_for(&rx, 5, |_| {});
    assert!(
        reconnect.get("error").is_none(),
        "only explicit reconnect may reopen after terminal refresh loss: {reconnect:#?}"
    );

    send(&mut stdin, 6, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 6, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(output_directory);
}

/// Preview completion releases the UI's active acquisition lane before its
/// safe terminal status refresh. A bridge loss in that refresh must therefore
/// retain the operation ID on the disconnected status so the just-terminal
/// preview intent can still correlate and accept it.
#[test]
fn terminal_preview_status_process_exit_emits_correlated_disconnect() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-terminal-preview-status-session-loss",
        // :2 -- the first device.status is the pre-preview film-presence
        // gate; this test's subject is losing the POST-preview terminal
        // status refresh.
        &[("MOCK_BRIDGE_CRASH_ON", "device.status:2")],
    );
    let operation_id = "terminal-preview-status-session-loss-op";

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({
            "frames": [1, 2, 3],
            "filmProcess": "positive",
            "operationId": operation_id
        }),
    );
    let accepted = recv_response_for(&rx, 3, |_| {});
    assert!(
        accepted.get("error").is_none(),
        "preview must be accepted before terminal status loss: {accepted:#?}"
    );

    let terminal_events = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.thumbnailsComplete"
    });
    assert!(
        terminal_events
            .iter()
            .any(|event| event["event"] == "scanner.thumbnailsComplete"),
        "the preview must close before its status refresh: {terminal_events:#?}"
    );

    let line = rx
        .recv_timeout(Duration::from_secs(3))
        .expect("terminal preview status loss must emit disconnected status");
    let disconnected: Value =
        serde_json::from_str(&line).expect("engine must emit valid JSON after preview loss");
    assert_eq!(disconnected["event"], "scanner.status");
    assert_eq!(disconnected["payload"]["status"]["connected"], false);
    assert_eq!(disconnected["payload"]["operationId"], operation_id);

    send(&mut stdin, 4, "scanner.status", json!({}));
    let mut duplicate_disconnected_events = 0;
    let local_status = recv_response_for(&rx, 4, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            duplicate_disconnected_events += 1;
        }
    });
    assert_eq!(local_status["error"]["code"], "NOT_CONNECTED");
    assert_eq!(duplicate_disconnected_events, 0);

    send(
        &mut stdin,
        5,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let reconnect = recv_response_for(&rx, 5, |_| {});
    assert!(
        reconnect.get("error").is_none(),
        "only explicit reconnect may reopen after preview refresh loss: {reconnect:#?}"
    );

    send(&mut stdin, 6, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 6, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

/// scan.stop's acknowledgement is sent before the server's safe post-dispatch
/// status refresh. If that refresh loses the bridge process, the successful
/// acknowledgement remains the sole response while the session is retired by
/// one following disconnected status event.
#[test]
fn scan_stop_ack_then_status_process_exit_invalidates_without_second_response() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-scan-stop-post-status-session-loss",
        &[
            ("MOCK_BRIDGE_HANG_ON_SCAN", "1"),
            ("MOCK_BRIDGE_CRASH_ON", "device.status"),
        ],
    );
    let output_directory = unique_output_destination("scan-stop-post-status-session-loss");

    send(
        &mut stdin,
        3,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": output_directory.display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start = recv_response_for(&rx, 3, |_| {});
    assert!(start.get("error").is_none(), "scan.start failed: {start:#?}");
    let job_id = start["result"]["jobId"]
        .as_str()
        .expect("scan.start jobId")
        .to_string();

    send(
        &mut stdin,
        4,
        "scan.stop",
        json!({"jobId": job_id, "mode": "afterCurrentFrame"}),
    );
    let stop = recv_response_for(&rx, 4, |_| {});
    assert!(
        stop.get("error").is_none(),
        "scan.stop acknowledgement must remain successful: {stop:#?}"
    );
    assert_eq!(stop["result"]["acknowledged"], true);
    assert_eq!(stop["result"]["mode"], "afterCurrentFrame");

    // The engine scan worker is also awakened by the bridge EOF and may emit
    // its honest terminal frame/job events before the epoch winner emits the
    // one disconnected status. Do not assume scheduling order between those
    // producers; require the authoritative status and count it.
    let post_stop_events = drain_until(&rx, Duration::from_secs(3), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
    });
    assert_eq!(
        post_stop_events
            .iter()
            .filter(|event| {
                event["event"] == "scanner.status"
                    && event["payload"]["status"]["connected"] == false
            })
            .count(),
        1,
        "the scan worker and post-dispatch refresh must share one epoch-owned disconnect: {post_stop_events:#?}"
    );

    send(&mut stdin, 5, "scanner.status", json!({}));
    let mut duplicate_disconnected_events = 0;
    let local_status = recv_response_for(&rx, 5, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            duplicate_disconnected_events += 1;
        }
    });
    assert_eq!(local_status["error"]["code"], "NOT_CONNECTED");
    assert_eq!(duplicate_disconnected_events, 0);

    send(
        &mut stdin,
        6,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let reconnect = recv_response_for(&rx, 6, |_| {});
    assert!(
        reconnect.get("error").is_none(),
        "explicit reconnect must reopen after post-stop status loss: {reconnect:#?}"
    );

    send(&mut stdin, 7, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 7, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(output_directory);
}

/// With `SCANSTUDIO_BRIDGE_CMD` pointing at a working bridge, `scanner.list`
/// shows two devices, and connecting to the real device's id routes the
/// connection (proven via a post-connect `scanner.status` check, not just
/// the `scanner.connect` response itself) through `RealLs5000`.
#[test]
fn real_device_listed_and_connectable_when_bridge_cmd_set() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-real-backend-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(&mut stdin, 2, "scanner.list", json!({}));
    let list_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        list_resp.get("error").is_none(),
        "scanner.list failed: {list_resp:?}"
    );
    let devices = list_resp["result"]["devices"]
        .as_array()
        .expect("devices must be an array");
    assert_eq!(
        devices.len(),
        2,
        "with SCANSTUDIO_BRIDGE_CMD set to a working bridge, scanner.list must show two devices: {devices:?}"
    );
    let real_devices: Vec<&Value> = devices
        .iter()
        .filter(|device| device["kind"] == json!("real"))
        .collect();
    assert_eq!(
        real_devices.len(),
        1,
        "exactly one listed device must have kind \"real\": {devices:?}"
    );
    assert_eq!(real_devices[0]["deviceId"], json!("bridge-ls5000-0"));
    // The exact wire key WireProtocol.swift's DeviceInfo already decodes
    // (added ahead of the engine actually sending it) and the TS wire
    // client's DeviceInfo interface expects, carrying mock_bridge's fixed
    // Capabilities.supportedMultisamplePasses verbatim through
    // derive_supported_multisample_passes -- a real, over-the-wire,
    // black-box proof of the key name, not just an in-process Rust struct
    // assertion.
    assert_eq!(
        real_devices[0]["supportedMultisamplePasses"],
        json!([4]),
        "real device's scanner.list entry must forward the bridge's supported multisample passes: {devices:?}"
    );
    let sim_devices: Vec<&Value> = devices
        .iter()
        .filter(|device| device["kind"] == json!("simulated"))
        .collect();
    assert_eq!(sim_devices.len(), 1, "expected exactly one simulated device: {devices:?}");
    assert!(
        sim_devices[0].get("supportedMultisamplePasses").is_none(),
        "the simulator has no bridge-sourced capability list and must omit the key entirely, not null: {devices:?}"
    );

    send(
        &mut stdin,
        3,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect to the real device failed: {connect_resp:?}"
    );
    assert_eq!(connect_resp["result"]["status"]["connected"], json!(true));

    // The connection itself, not just the listing, must have routed
    // through the real backend — confirm with a fresh scanner.status call.
    send(&mut stdin, 4, "scanner.status", json!({}));
    let status_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        status_resp.get("error").is_none(),
        "scanner.status failed: {status_resp:?}"
    );
    assert_eq!(
        status_resp["result"]["connected"],
        json!(true),
        "scanner.status must confirm the connection routed through the real backend: {status_resp:?}"
    );

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 5, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// With `SCANSTUDIO_BRIDGE_CMD` pointing at a broken or nonexistent
/// command, the engine still starts cleanly and behaves exactly like the
/// unset case — graceful degradation, never a crash or a half-broken
/// device entry.
#[test]
fn graceful_fallback_when_bridge_cmd_points_at_broken_command() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", "/definitely/does/not/exist/xyz")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-real-backend-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed even though the broken bridge command must never affect engine startup: {hello_resp:?}"
    );

    send(&mut stdin, 2, "scanner.list", json!({}));
    let list_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        list_resp.get("error").is_none(),
        "scanner.list failed: {list_resp:?}"
    );
    let devices = list_resp["result"]["devices"]
        .as_array()
        .expect("devices must be an array");
    assert_eq!(
        devices.len(),
        1,
        "a broken SCANSTUDIO_BRIDGE_CMD must degrade exactly like no configuration — one simulated device, never a crash or a half-working entry: {devices:?}"
    );
    assert_eq!(devices[0]["kind"], json!("simulated"));

    send(&mut stdin, 3, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// Regression: proves `run_real_scan_job`'s scan-path silence watchdog
/// fires within (approximately) its configured deadline through the FULL
/// server dispatch path — the one dimension `tests/real_backend_mapping.rs`'s
/// own `scan_silence_past_deadline_reports_honest_failure_without_touching_the_bridge_process`
/// test does not cover, since it calls `RealLs5000::scan_start` directly
/// in-process, bypassing `server.rs::run()`'s dispatch loop entirely (that
/// test proves the watchdog LOOP's own logic is sound once reached; this
/// one proves the loop is actually REACHED promptly through the real
/// entry point a live client uses).
///
/// `MOCK_BRIDGE_HANG_ON_STATUS_AFTER_SCAN` reproduces a second, less
/// obvious live shape distinct from "the bridge is totally silent": a
/// `device.status` read that is separately stuck (10-06-SUMMARY.md's Root
/// Cause section: physically plausible immediately after a preview
/// traversal parks the transport at an end-stop). Before this plan's fix,
/// `run_real_scan_job` made one unconditional, unprotected
/// `backend.status()` bridge call at its own entry — BEFORE
/// `silence_deadline` is ever armed — bounded only by `BridgeClient`'s own
/// ~10s `request_timeout`, whose timeout path calls `restart()` (kills +
/// respawns the bridge subprocess: exactly the "never kill mid-USB-
/// transaction" hazard this whole watchdog exists to close). That made the
/// honest failure arrive only after ~10s (the stuck status call's own
/// timeout) plus a kill+respawn cycle plus the 2s configured silence
/// deadline below — comfortably over this test's 6s bound, which is
/// deliberately tighter than the unavoidable 10s floor the defect
/// produces. After the fix, `run_real_scan_job` makes zero bridge calls
/// before its watchdog loop starts, so a stuck `device.status` elsewhere
/// no longer matters to it at all, and the honest failure arrives within a
/// few hundred milliseconds of the 2s configured deadline.
#[test]
fn scan_watchdog_fires_promptly_even_when_a_status_read_is_separately_stuck() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("MOCK_BRIDGE_HANG_ON_SCAN", "1")
        .env("MOCK_BRIDGE_HANG_ON_STATUS_AFTER_SCAN", "1")
        .env("SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS", "2")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-watchdog-status-hang-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    let scan_start_sent_at = Instant::now();
    send(
        &mut stdin,
        5,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": unique_output_destination("watchdog-status-hang").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start_resp = recv_response_for(&rx, 5, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start's own initiating call must succeed — mock_bridge accepts scan.start \
         normally even in hang mode, only device.status is stuck: {start_resp:?}"
    );

    // The tight bound this whole test exists to enforce (see the doc
    // comment above for the exact before/after arithmetic).
    let events = drain_until(&rx, Duration::from_secs(6), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });
    let elapsed = scan_start_sent_at.elapsed();
    assert!(
        elapsed < Duration::from_secs(6),
        "watchdog took {elapsed:?} to fire — should land close to the 2s configured deadline, \
         not be bounded by an unrelated bridge.call's own ~10s request_timeout: this is exactly \
         Plan 10-06's regression"
    );

    let frame_state_failed = events
        .iter()
        .find(|event| event["event"] == "scan.frameState" && event["payload"]["state"] == "failed")
        .unwrap_or_else(|| {
            panic!("expected a scan.frameState(failed) event within {elapsed:?}: {events:#?}")
        });
    assert_eq!(
        frame_state_failed["payload"]["frameIndex"].as_u64(),
        Some(1),
        "the one requested-and-never-completed slot must be reported failed: {frame_state_failed:#?}"
    );
    assert_eq!(
        frame_state_failed["payload"]["error"]["recoverable"].as_bool(),
        Some(false),
        "the silence watchdog's failure must be recoverable:false: {frame_state_failed:#?}"
    );
    assert!(
        frame_state_failed["payload"]["error"]["message"]
            .as_str()
            .unwrap_or("")
            .contains("BRIDGE_STREAM_STALLED"),
        "error message must name BRIDGE_STREAM_STALLED: {frame_state_failed:#?}"
    );

    assert!(
        events
            .iter()
            .any(|event| event["event"] == "scan.jobState" && event["payload"]["state"] == "failed"),
        "expected a scan.jobState(failed) event: {events:#?}"
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

    // Cleanup: kill directly rather than the graceful engine.shutdown dance
    // every other test in this file uses. server.rs's own SEPARATE
    // post-dispatch `scanner.status` hook (unrelated to this plan's fix —
    // see 10-06-SUMMARY.md's Next Phase Readiness) independently issued
    // its own `device.status` call the instant `scan.start` was accepted,
    // and it is ALSO stuck against this same mock right now — the main
    // stdin-reading thread won't free up to read a fresh `engine.shutdown`
    // line until that unrelated call's own ~10s `request_timeout` elapses.
    // Waiting that out here would make this test's runtime hostage to a
    // different, out-of-scope code path instead of the one this plan
    // fixes.
    let _ = child.kill();
    let _ = child.wait();
    let _ = reader_handle.join();
}

/// Plan 11-01 regression: a real bridge session that emits `scan.progress`
/// with `ordinal: 0` for the second frame must not leave the client without
/// a terminal `scan.completed`. Before the fix, the `progress.ordinal - 1`
/// arithmetic underflows in debug builds and panics the scan-worker thread,
/// producing the same symptom as the 2026-07-24 soak: progress stops and no
/// terminal event ever arrives. After the fix, the worker survives the bad
/// ordinal and the job completes honestly for both frames.
#[test]
fn scan_worker_panic_still_reports_an_honest_terminal_outcome() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("MOCK_BRIDGE_SCAN_BAD_ORDINAL_SLOT", "2")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-panic-safety-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    send(
        &mut stdin,
        3,
        "scan.start",
        json!({
            "frames": [1, 2],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": unique_output_destination("panic-safety").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );

    let events = drain_until(&rx, Duration::from_secs(10), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });

    let frame_one_completed = events.iter().any(|event| {
        event["event"] == "scan.frameCompleted" && event["payload"]["frameIndex"] == json!(1)
    });
    assert!(
        frame_one_completed,
        "frame 1 must still complete before the panic: {events:#?}"
    );

    let completed_event = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .expect("scan.completed event must be present");
    let completed_slots: Vec<u64> = completed_event["payload"]["summary"]["completed"]
        .as_array()
        .expect("summary.completed must be an array")
        .iter()
        .map(|v| v.as_u64().expect("slot must be a number"))
        .collect();
    let failed_slots: Vec<u64> = completed_event["payload"]["summary"]["failed"]
        .as_array()
        .expect("summary.failed must be an array")
        .iter()
        .map(|v| v.as_u64().expect("slot must be a number"))
        .collect();
    assert_eq!(completed_slots, vec![1, 2], "events: {events:#?}");
    assert!(failed_slots.is_empty(), "events: {events:#?}");

    assert!(
        events
            .iter()
            .any(|event| event["event"] == "scan.jobState"
                && event["payload"]["state"] == "completed"),
        "expected a scan.jobState(completed) event: {events:#?}"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// Plan 11-01 regression: the server post-dispatch hook must not issue a
/// synchronous `device.status` call for `scan.start` against the Real backend.
/// `MOCK_BRIDGE_HANG_ON_STATUS_AFTER_SCAN` arms a status hang the moment
/// `scan.start` is accepted, but the scan worker still proceeds normally
/// (unlike the 10-06 watchdog test, `MOCK_BRIDGE_HANG_ON_SCAN` is not set).
/// Before the fix, the post-dispatch hook's `device.status` call would hang
/// the main stdin-reading thread; after the fix, `scan.start` returns
/// promptly and the job completes.
#[test]
fn scan_start_against_real_skips_post_dispatch_device_status() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("MOCK_BRIDGE_HANG_ON_STATUS_AFTER_SCAN", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-skip-status-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    let scan_start_sent_at = Instant::now();
    send(
        &mut stdin,
        3,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": unique_output_destination("skip-status").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );
    let start_elapsed = scan_start_sent_at.elapsed();
    assert!(
        start_elapsed < Duration::from_secs(2),
        "scan.start must return promptly without waiting on a post-dispatch device.status: {start_elapsed:?}"
    );

    let events = drain_until(&rx, Duration::from_secs(5), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });

    let completed_event = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .expect("scan.completed event must be present");
    let completed_slots: Vec<u64> = completed_event["payload"]["summary"]["completed"]
        .as_array()
        .expect("summary.completed must be an array")
        .iter()
        .map(|v| v.as_u64().expect("slot must be a number"))
        .collect();
    assert_eq!(completed_slots, vec![1], "events: {events:#?}");

    // The post-dispatch hook no longer emits scanner.status for Real scan.start,
    // so we should not see one after scan.start's response.
    let post_start_status_count = events
        .iter()
        .filter(|event| event["event"] == "scanner.status")
        .count();
    assert_eq!(
        post_start_status_count, 0,
        "no post-scan.start scanner.status may be emitted for Real: {events:#?}"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// B&W is a batch-wide material rule, not a UI convention. This goes through
/// the real-backend path against the mock bridge with deliberately hostile
/// RGBI/ICE input and asserts the emitted real receipt records the effective
/// RGB/no-ICE capture configuration that reached the bridge path.
#[test]
fn bw_real_scan_forces_rgb_and_disables_digital_ice_in_the_effective_receipt() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");
    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(line) => {
                    if tx.send(line).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-bw-effective-capture", "protocolVersion": 1}),
    );
    assert!(recv_response_for(&rx, 1, |_| {}).get("error").is_none());
    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    assert!(recv_response_for(&rx, 2, |_| {}).get("error").is_none());

    let output_directory = std::env::temp_dir().join(format!(
        "scanstudio-e2e-bw-effective-capture-{}",
        scanstudio_engine::manifest::generate_project_id()
    ));
    send(
        &mut stdin,
        3,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi"
            },
            "processing": {
                "filmProcess": "bwNegative",
                "digitalIceEnabled": true
            },
            "output": {
                "archive": {
                    "destination": output_directory.display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": { "enabled": false },
                "preview": { "enabled": false }
            }
        }),
    );
    let start = recv_response_for(&rx, 3, |_| {});
    assert!(
        start.get("error").is_none(),
        "scan.start failed: {start:#?}"
    );

    let events = drain_until(&rx, Duration::from_secs(5), |event| {
        event.get("event") == Some(&json!("scan.completed"))
    });
    let receipt = events
        .iter()
        .find(|event| event["event"] == "scan.frameCompleted")
        .map(|event| &event["payload"]["receipt"])
        .unwrap_or_else(|| panic!("expected completed real receipt: {events:#?}"));
    assert_eq!(receipt["simulated"], json!(false));
    assert_eq!(receipt["channels"], json!("rgb"));
    assert_eq!(receipt["processing"]["filmProcess"], json!("bwNegative"));
    assert_eq!(receipt["processing"]["digitalIceEnabled"], json!(false));
    assert!(
        receipt.get("irPath").is_none() || receipt["irPath"].is_null(),
        "an effective RGB B&W bridge capture must not report an IR path: {receipt:#?}"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(output_directory);
}

/// Full-server-path regression: live attempt #3
/// (2026-07-23 evening) proved the bridge's own `scan.error` (REFEED_
/// REQUIRED) never reached the client at all — the client transcript's
/// last events stayed `scan.jobState{scanning}` + `scanner.status`,
/// forever. `MOCK_BRIDGE_SCAN_ERROR_CODE` reproduces the bridge's own
/// `except BridgeError` -> `finally` sequence (scan.error immediately
/// followed by scan.completed, every requested slot failed). Proves the
/// fix through the SAME entry point a live client actually uses
/// (`server.rs::run()`'s dispatch loop), not just `RealLs5000::scan_start`
/// called directly in-process.
#[test]
fn scan_error_reaches_the_client_through_the_full_server_path() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("MOCK_BRIDGE_SCAN_ERROR_CODE", "REFEED_REQUIRED")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-scan-error-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    send(
        &mut stdin,
        3,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": unique_output_destination("scan-error").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start's own initiating call must succeed — the mock's scan.error trigger only affects the worker: {start_resp:?}"
    );

    let events = drain_until(&rx, Duration::from_secs(5), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });

    let frame_state_failed = events
        .iter()
        .find(|event| event["event"] == "scan.frameState" && event["payload"]["state"] == "failed")
        .unwrap_or_else(|| panic!("expected a scan.frameState(failed) event: {events:#?}"));
    assert_eq!(
        frame_state_failed["payload"]["frameIndex"].as_u64(),
        Some(1)
    );
    assert!(
        frame_state_failed["payload"]["error"]["message"]
            .as_str()
            .unwrap_or("")
            .contains("REFEED_REQUIRED"),
        "error message must name the real bridge code: {frame_state_failed:#?}"
    );

    let scan_completed_count = events
        .iter()
        .filter(|event| event["event"] == "scan.completed")
        .count();
    assert_eq!(
        scan_completed_count, 1,
        "scan.completed must reach the client exactly once, even though the bridge's own worker \
         emits its own scan.completed immediately behind scan.error: {events:#?}"
    );

    assert!(
        !events
            .iter()
            .any(|event| event["event"] == "scan.frameCompleted"),
        "no receipt/path may ever be fabricated for a frame that never completed: {events:#?}"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// Plan 11-02 regression: `project.pendingFrames` must answer from a
/// fresh disk read, not a stale in-memory snapshot. After a real (mock-
/// backed) scan completes frame 1, the engine's in-memory project state
/// still has no receipt (the worker thread persists directly to disk),
/// so this test would fail before the fix. With the fix,
/// `project.pendingFrames` re-reads the manifest and correctly excludes
/// the completed frame.
#[test]
fn pending_frames_reflects_real_hardware_receipts_from_fresh_disk_read() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let project_directory = std::env::temp_dir().join(format!(
        "scanstudio-e2e-pending-frames-{}",
        scanstudio_engine::manifest::generate_project_id()
    ));
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-pending-frames-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "project.create",
        json!({
            "name": "Pending Frames Test",
            "carrier": "strip6",
            "frameCount": 3,
            "filmProcess": "positive",
            "directory": project_directory.display().to_string()
        }),
    );
    let create_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        create_resp.get("error").is_none(),
        "project.create failed: {create_resp:?}"
    );

    send(
        &mut stdin,
        3,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    send(
        &mut stdin,
        4,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": project_directory.join("Archive").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );

    let _events = drain_until(&rx, Duration::from_secs(5), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });

    send(&mut stdin, 5, "project.pendingFrames", json!({}));
    let pending_resp = recv_response_for(&rx, 5, |_| {});
    assert!(
        pending_resp.get("error").is_none(),
        "project.pendingFrames failed: {pending_resp:?}"
    );
    let frames: Vec<u64> = pending_resp["result"]["frames"]
        .as_array()
        .expect("frames array")
        .iter()
        .map(|v| v.as_u64().expect("frame index must be a number"))
        .collect();
    assert!(
        !frames.contains(&1),
        "frame 1 must not appear in pendingFrames after it completed: {frames:?}"
    );
    assert_eq!(
        pending_resp["result"]["completedCount"].as_u64(),
        Some(1),
        "completedCount must reflect the disk-persisted receipt"
    );
    assert_eq!(frames, vec![2, 3], "frames: {frames:?}");

    send(&mut stdin, 6, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 6, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(&project_directory);
}

/// Full-server-path regression for Plan 10-08: live attempt #4
/// (2026-07-23 evening) — hw-telemetry showed `scan.start outcome ok,
/// completed:[], failed:[1]` after an 86s real scan, no `scan.error`
/// involved at all. `MOCK_BRIDGE_SCAN_FAILED_SLOTS` reproduces the exact
/// shape: the transport call itself returns a summary with the slot
/// already accounted as failed. Locks in that the pre-existing
/// `scan.completed` mapping arm already forwards this shape honestly
/// through the full dispatch path.
#[test]
fn per_frame_failed_closure_with_no_scan_error_reaches_the_client_through_the_full_server_path() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("MOCK_BRIDGE_SCAN_FAILED_SLOTS", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-partial-failure-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    send(
        &mut stdin,
        3,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": unique_output_destination("partial-failure").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );

    let events = drain_until(&rx, Duration::from_secs(5), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });

    assert!(
        !events
            .iter()
            .any(|event| event["event"] == "scan.frameCompleted"),
        "no receipt/path may ever be fabricated for the one slot that never completed: {events:#?}"
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
    assert!(completed_event["payload"]["summary"]["completed"]
        .as_array()
        .expect("summary.completed must be an array")
        .is_empty());

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// Plan 12-02 helper: spawns the engine against the mock bridge with the
/// mid-batch death flag armed, creates a three-frame strip6 project, and
/// connects to the real device. Both 12-02 tests reuse this setup; ids 1-3
/// are consumed, so callers start from id 4.
fn spawn_engine_for_bridge_crash_test(
    project_directory: &std::path::Path,
    crash_after_frame: u32,
) -> (
    std::process::Child,
    std::process::ChildStdin,
    mpsc::Receiver<String>,
    thread::JoinHandle<()>,
) {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS", "3")
        .env(
            "MOCK_BRIDGE_CRASH_AFTER_FRAME_COMPLETED",
            crash_after_frame.to_string(),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-bridge-crash-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "project.create",
        json!({
            "name": "Bridge Crash Test",
            "carrier": "strip6",
            "frameCount": 3,
            "filmProcess": "positive",
            "directory": project_directory.display().to_string()
        }),
    );
    let create_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        create_resp.get("error").is_none(),
        "project.create failed: {create_resp:?}"
    );

    send(
        &mut stdin,
        3,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    (child, stdin, rx, reader_handle)
}

/// Starts a connected real-backend engine whose mock bridge acknowledges
/// roll.preview and then exits asynchronously before emitting preview data.
/// ids 1-2 are consumed; callers start from id 3.
fn spawn_engine_for_preview_crash_test() -> (
    std::process::Child,
    std::process::ChildStdin,
    mpsc::Receiver<String>,
    thread::JoinHandle<()>,
) {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("MOCK_BRIDGE_CRASH_AFTER_PREVIEW_ACCEPT", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(line) => {
                    if tx.send(line).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-preview-bridge-crash-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    (child, stdin, rx, reader_handle)
}

/// Plan 12-02 regression: killing the bridge subprocess mid-batch never
/// loses the receipts of frames that already completed and always produces
/// an honest terminal client outcome within the configured silence deadline.
/// The kill is deterministic (`MOCK_BRIDGE_CRASH_AFTER_FRAME_COMPLETED=1`);
/// the existing silence watchdog (Phase 10) detects the real process death
/// and fails the remaining frames.
#[test]
fn bridge_crash_mid_batch_reports_honest_failure_with_zero_receipt_loss() {
    let project_directory = std::env::temp_dir().join(format!(
        "scanstudio-e2e-bridge-crash-{}",
        scanstudio_engine::manifest::generate_project_id()
    ));
    let (mut child, mut stdin, rx, reader_handle) =
        spawn_engine_for_bridge_crash_test(&project_directory, 1);

    send(
        &mut stdin,
        4,
        "scan.start",
        json!({
            "frames": [1, 2, 3],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": project_directory.join("Archive").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );

    let events = drain_until(&rx, Duration::from_secs(8), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });

    let frame_completed_events: Vec<&Value> = events
        .iter()
        .filter(|event| event["event"] == "scan.frameCompleted")
        .collect();
    assert_eq!(
        frame_completed_events.len(),
        1,
        "exactly one frame must have completed before the bridge died: {events:#?}"
    );
    assert_eq!(
        frame_completed_events[0]["payload"]["frameIndex"],
        json!(1),
        "only frame 1 may have completed: {events:#?}"
    );

    for frame_index in [2, 3] {
        let frame_state = events
            .iter()
            .find(|event| {
                event["event"] == "scan.frameState"
                    && event["payload"]["frameIndex"] == json!(frame_index)
                    && event["payload"]["state"] == "failed"
            })
            .unwrap_or_else(|| {
                panic!("expected scan.frameState{{failed}} for frame {frame_index}: {events:#?}")
            });
        assert_eq!(
            frame_state["payload"]["error"]["recoverable"].as_bool(),
            Some(false),
            "post-crash frame failure must be recoverable:false: {frame_state:#?}"
        );
        assert_eq!(
            frame_state["payload"]["error"]["code"],
            "NOT_CONNECTED",
            "dead bridge ownership is a typed connection loss: {frame_state:#?}"
        );
        let message = frame_state["payload"]["error"]["message"]
            .as_str()
            .unwrap_or("");
        assert!(
            [
                "sessionEpoch=1; bridgeGenerationStart=1; bridgeGenerationCurrent=1; bridgeHealthy=false",
                "no device call, automatic open, or motion retry was attempted",
            ]
            .iter()
            .all(|evidence| message.contains(evidence)),
            "connection evidence must survive in the technical error: {frame_state:#?}"
        );
        assert!(
            !message.contains("bridge-ls5000-0") && !message.contains('/'),
            "async connection evidence must not disclose device IDs or paths: {frame_state:#?}"
        );
    }

    assert!(
        events
            .iter()
            .any(|event| event["event"] == "scan.jobState" && event["payload"]["state"] == "failed"),
        "expected a scan.jobState(failed) event: {events:#?}"
    );

    let completed_events: Vec<&Value> = events
        .iter()
        .filter(|event| event["event"] == "scan.completed")
        .collect();
    assert_eq!(
        completed_events.len(),
        1,
        "exactly one scan.completed may be emitted: {events:#?}"
    );
    let summary = &completed_events[0]["payload"]["summary"];
    assert_eq!(
        summary["completed"].as_array().map(|a| a.clone()),
        Some(vec![json!(1)]),
        "summary.completed: {summary:#?}"
    );
    assert_eq!(
        summary["failed"].as_array().map(|a| a.clone()),
        Some(vec![json!(2), json!(3)]),
        "summary.failed: {summary:#?}"
    );
    assert!(
        summary["skipped"].as_array().map_or(true, |a| a.is_empty()),
        "summary.skipped must be empty: {summary:#?}"
    );
    assert_eq!(
        summary["stopped"].as_bool(),
        Some(false),
        "summary.stopped must be false: {summary:#?}"
    );

    send(&mut stdin, 5, "project.pendingFrames", json!({}));
    let pending_resp = recv_response_for(&rx, 5, |_| {});
    assert!(
        pending_resp.get("error").is_none(),
        "project.pendingFrames failed: {pending_resp:?}"
    );
    assert_eq!(
        pending_resp["result"]["completedCount"].as_u64(),
        Some(1),
        "completedCount must be 1: {pending_resp:#?}"
    );
    assert_eq!(
        pending_resp["result"]["totalFrames"].as_u64(),
        Some(3),
        "totalFrames must be 3: {pending_resp:#?}"
    );
    let pending_frames: Vec<u64> = pending_resp["result"]["frames"]
        .as_array()
        .expect("frames array")
        .iter()
        .map(|v| v.as_u64().expect("frame index must be a number"))
        .collect();
    assert_eq!(
        pending_frames,
        vec![2, 3],
        "pending frames: {pending_frames:?}"
    );

    // Independent disk-level corroboration: the manifest on disk must show
    // frame 1 completed and frames 2/3 pending.
    let manifest =
        scanstudio_engine::manifest::read_manifest(&project_directory).expect("read manifest");
    let frame_one_has_receipt = manifest
        .frames
        .iter()
        .find(|f| f.index == 1)
        .map(|f| !f.receipts.is_empty())
        .unwrap_or(false);
    assert!(
        frame_one_has_receipt,
        "manifest must contain frame 1 receipt: {manifest:#?}"
    );
    let manifest_pending = scanstudio_engine::manifest::pending_frames(&manifest);
    assert_eq!(
        manifest_pending,
        vec![2, 3],
        "manifest pending frames: {manifest_pending:?}"
    );

    send(&mut stdin, 6, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 6, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(&project_directory);
}

/// A bridge respawn starts with no device open. The engine must invalidate its
/// own active-real session and explicitly tell the client to reconnect; it
/// must never silently carry the old connection across process ownership.
#[test]
fn bridge_respawn_invalidates_real_session_and_requires_reconnect() {
    let project_directory = std::env::temp_dir().join(format!(
        "scanstudio-e2e-resume-after-crash-{}",
        scanstudio_engine::manifest::generate_project_id()
    ));
    let (mut child, mut stdin, rx, reader_handle) =
        spawn_engine_for_bridge_crash_test(&project_directory, 1);

    send(
        &mut stdin,
        4,
        "scan.start",
        json!({
            "frames": [1, 2, 3],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": project_directory.join("Archive").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "initial scan.start failed: {start_resp:?}"
    );

    let events = drain_until(&rx, Duration::from_secs(8), |v| {
        v["event"] == "scanner.status" && v["payload"]["status"]["connected"] == false
    });
    assert!(
        events
            .iter()
            .any(|event| event["event"] == "scan.completed"),
        "the scan must close terminally before or with ownership invalidation: {events:#?}"
    );
    let disconnected_events: Vec<&Value> = events
        .iter()
        .filter(|event| {
            event["event"] == "scanner.status"
                && event["payload"]["status"]["connected"] == false
        })
        .collect();
    assert_eq!(
        disconnected_events.len(),
        1,
        "async bridge death must emit exactly one disconnected status: {events:#?}"
    );
    assert!(
        disconnected_events[0]["payload"]["operationId"].is_null(),
        "scan-path ownership loss is not preview-scoped: {disconnected_events:#?}"
    );

    // Reconciliation must make scanner.status a local, safe query. It must
    // neither call the dead bridge nor emit a duplicate disconnected event.
    send(&mut stdin, 5, "scanner.status", json!({}));
    let mut duplicate_disconnected_events = 0;
    let status_while_disconnected = recv_response_for(&rx, 5, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            duplicate_disconnected_events += 1;
        }
    });
    assert!(
        status_while_disconnected.get("result").is_none(),
        "scanner.status must not retain a connected real route: {status_while_disconnected:?}"
    );
    assert_eq!(
        status_while_disconnected["error"]["code"],
        "NOT_CONNECTED",
        "scanner.status must fail locally until explicit reconnect: {status_while_disconnected:?}"
    );
    assert_eq!(
        duplicate_disconnected_events, 0,
        "safe status reconciliation must not duplicate ownership-loss events"
    );

    // Only an explicit connect may spawn/open a replacement bridge session.
    send(
        &mut stdin,
        6,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let reconnect_resp = recv_response_for(&rx, 6, |_| {});
    assert!(
        reconnect_resp.get("error").is_none(),
        "explicit reconnect must establish a new bridge-owned device session: {reconnect_resp:?}"
    );
    assert_eq!(reconnect_resp["result"]["status"]["connected"], true);

    send(&mut stdin, 7, "scanner.status", json!({}));
    let reconnected_status = recv_response_for(&rx, 7, |_| {});
    assert!(
        reconnected_status.get("error").is_none(),
        "scanner.status must be safe after explicit reconnect: {reconnected_status:?}"
    );
    assert_eq!(reconnected_status["result"]["connected"], true);

    send(&mut stdin, 8, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 8, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(&project_directory);
}

/// A preview owns SessionModel's preview-intent lane after its synchronous
/// acceptance. If the bridge dies then, the disconnected status must be
/// emitted exactly once and retain that operationId so the UI accepts it.
#[test]
fn preview_bridge_death_emits_correlated_disconnect_and_requires_reconnect() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_engine_for_preview_crash_test();
    let preview_operation_id = "preview-bridge-death-op";

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({
            "frames": [1, 2, 3],
            "filmProcess": "positive",
            "operationId": preview_operation_id
        }),
    );
    let preview_ack = recv_response_for(&rx, 3, |_| {});
    assert!(
        preview_ack.get("error").is_none(),
        "roll.preview must be accepted before the injected death: {preview_ack:?}"
    );

    let events = drain_until(&rx, Duration::from_secs(13), |event| {
        event["event"] == "scanner.thumbnailsComplete"
    });
    let preview_failure = events
        .iter()
        .find(|event| event["event"] == "scanner.thumbnailsFailed")
        .unwrap_or_else(|| panic!("preview bridge death must emit thumbnailsFailed: {events:#?}"));
    assert_eq!(
        preview_failure["payload"]["code"],
        "NOT_CONNECTED",
        "dead preview bridge must surface typed connection loss"
    );
    let preview_failure_message = preview_failure["payload"]["message"]
        .as_str()
        .unwrap_or("");
    assert!(
        [
            "sessionEpoch=1",
            "sessionEpochCurrent=1",
            "bridgeGenerationStart=1",
            "bridgeGenerationCurrent=1",
            "bridgeHealthy=false",
        ]
        .iter()
        .all(|evidence| preview_failure_message.contains(evidence)),
        "preview failure must retain non-sensitive connection evidence: {preview_failure:#?}"
    );
    assert!(
        !preview_failure_message.contains("bridge-ls5000-0")
            && !preview_failure_message.contains('/'),
        "preview connection evidence must not disclose device IDs or paths: {preview_failure:#?}"
    );
    assert!(
        events
            .iter()
            .any(|event| event["event"] == "scanner.thumbnailsComplete"),
        "preview bridge death must close the preview event sequence: {events:#?}"
    );
    let disconnected_events: Vec<&Value> = events
        .iter()
        .filter(|event| {
            event["event"] == "scanner.status"
                && event["payload"]["status"]["connected"] == false
        })
        .collect();
    assert_eq!(
        disconnected_events.len(),
        1,
        "preview ownership loss must emit exactly one disconnected status: {events:#?}"
    );
    assert_eq!(
        disconnected_events[0]["payload"]["operationId"],
        preview_operation_id,
        "the disconnected status must stay correlated to the preview lane"
    );

    send(&mut stdin, 4, "scanner.status", json!({}));
    let mut duplicate_disconnected_events = 0;
    let disconnected_status = recv_response_for(&rx, 4, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            duplicate_disconnected_events += 1;
        }
    });
    assert_eq!(
        disconnected_status["error"]["code"],
        "NOT_CONNECTED",
        "status must reconcile locally without touching the dead bridge: {disconnected_status:?}"
    );
    assert_eq!(duplicate_disconnected_events, 0);

    send(
        &mut stdin,
        5,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let reconnect_resp = recv_response_for(&rx, 5, |_| {});
    assert!(
        reconnect_resp.get("error").is_none(),
        "explicit reconnect must reopen a fresh bridge session: {reconnect_resp:?}"
    );
    assert_eq!(reconnect_resp["result"]["status"]["connected"], true);

    send(&mut stdin, 6, "scanner.status", json!({}));
    let reconnected_status = recv_response_for(&rx, 6, |_| {});
    assert!(
        reconnected_status.get("error").is_none(),
        "status must work after explicit reconnect: {reconnected_status:?}"
    );
    assert_eq!(reconnected_status["result"]["connected"], true);

    send(&mut stdin, 7, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 7, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// A derivative-only output creates a private engine workspace before
/// scan.start is sent. A typed bridge NOT_CONNECTED must survive that
/// recovery context instead of being rewritten to INTERNAL.
#[test]
fn private_workspace_scan_rejection_preserves_not_connected_and_invalidates_once() {
    let test_root = unique_output_destination("typed-not-connected-private-workspace");
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("TMPDIR", &test_root)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("MOCK_BRIDGE_NOT_CONNECTED_ON_SCAN_START", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");
    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(line) => {
                    if tx.send(line).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-private-workspace-not-connected", "protocolVersion": 1}),
    );
    assert!(recv_response_for(&rx, 1, |_| {}).get("error").is_none());
    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    assert!(recv_response_for(&rx, 2, |_| {}).get("error").is_none());

    send(
        &mut stdin,
        3,
        "scan.start",
        json!({
            "frames": [1],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "enabled": false,
                    "fullCapturePackage": false,
                    "destination": test_root.join("disabled-archive").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {
                    "enabled": true,
                    "destination": test_root.join("positive").display().to_string(),
                    "filenameTemplate": "frame-####",
                    "fileFormat": "tiff",
                    "colorProfile": "adobeRgb1998"
                },
                "preview": {"enabled": false}
            }
        }),
    );
    let mut disconnected_events = 0;
    let mut scan_events = 0;
    let rejection = recv_response_for(&rx, 3, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            disconnected_events += 1;
        }
        if event["event"]
            .as_str()
            .is_some_and(|name| name.starts_with("scan."))
        {
            scan_events += 1;
        }
    });
    assert_eq!(
        rejection["error"]["code"],
        "NOT_CONNECTED",
        "private-workspace recovery context must preserve the typed bridge error: {rejection:?}"
    );
    let message = rejection["error"]["message"].as_str().unwrap_or("");
    assert!(
        message.contains("bridge error NOT_CONNECTED")
            && message.contains("recovery-held"),
        "error must retain both bridge semantics and workspace provenance: {rejection:?}"
    );
    assert_eq!(
        disconnected_events, 1,
        "typed ownership loss must emit exactly one disconnected status"
    );
    assert_eq!(
        scan_events, 0,
        "a rejected scan.start must spawn no job and retry no motion"
    );

    send(&mut stdin, 4, "scanner.status", json!({}));
    let mut duplicate_disconnected_events = 0;
    let status = recv_response_for(&rx, 4, |event| {
        if event["event"] == "scanner.status"
            && event["payload"]["status"]["connected"] == false
        {
            duplicate_disconnected_events += 1;
        }
    });
    assert_eq!(status["error"]["code"], "NOT_CONNECTED");
    assert_eq!(duplicate_disconnected_events, 0);

    send(
        &mut stdin,
        5,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let reconnect = recv_response_for(&rx, 5, |_| {});
    assert!(
        reconnect.get("error").is_none(),
        "explicit reconnect must re-open the live bridge: {reconnect:?}"
    );

    send(&mut stdin, 6, "scanner.status", json!({}));
    let connected_status = recv_response_for(&rx, 6, |_| {});
    assert_eq!(connected_status["result"]["connected"], true);

    send(&mut stdin, 7, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 7, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(&test_root);
}

/// Plan 12-03 helper: spawns the engine against the mock bridge with the
/// given per-slot extra delay and optional anomaly slot, says hello, and
/// connects to the real device. ids 1-2 are consumed; callers start from id 3.
fn spawn_engine_for_duty_cycle_test(
    inter_frame_delay_ms: u64,
    scan_anomaly_slot: Option<u32>,
) -> (
    std::process::Child,
    std::process::ChildStdin,
    mpsc::Receiver<String>,
    thread::JoinHandle<()>,
) {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut cmd = Command::new(bin);
    cmd.env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("SCANSTUDIO_SCAN_SILENCE_DEADLINE_SECS", "3")
        .env(
            "MOCK_BRIDGE_INTER_FRAME_DELAY_MS",
            inter_frame_delay_ms.to_string(),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    if let Some(slot) = scan_anomaly_slot {
        cmd.env("MOCK_BRIDGE_SCAN_ANOMALY_SLOT", slot.to_string());
    }
    let mut child = cmd.spawn().expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-duty-cycle-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    (child, stdin, rx, reader_handle)
}

fn duty_cycle_scan_start_params(frames: &[u32]) -> Value {
    json!({
        "frames": frames,
        "recipe": {
            "resolutionDpi": 4000,
            "bitDepth": 16,
            "multisamplePasses": 4,
            "channels": "rgbi",
            "autofocusEachFrame": true,
            "autoExposureEachFrame": true
        },
        "output": {
            "archive": {
                "destination": unique_output_destination("duty-cycle").display().to_string(),
                "filenameTemplate": "frame-####"
            },
            "positive": {"enabled": false},
            "preview": {"enabled": false}
        }
    })
}

/// Plan 12-03: the engine measures the wall-clock gap between one frame's
/// resolution and the next frame's first activity, and attaches the result
/// to the terminal `scan.completed` summary. Frame 1 has no predecessor and
/// contributes no sample; frames 2 and 3 each contribute one sample.
#[test]
fn duty_cycle_measures_a_known_configured_inter_frame_gap() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_engine_for_duty_cycle_test(250, None);

    send(
        &mut stdin,
        3,
        "scan.start",
        duty_cycle_scan_start_params(&[1, 2, 3]),
    );
    let start_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );

    let events = drain_until(&rx, Duration::from_secs(10), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });

    let completed_event = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .expect("scan.completed event must be present");
    let duty = &completed_event["payload"]["summary"]["dutyCycle"];
    assert!(
        duty.is_object(),
        "dutyCycle report must be present: {completed_event:#?}"
    );

    let samples = duty["perFrameIdleMs"]
        .as_array()
        .expect("perFrameIdleMs must be an array");
    assert_eq!(
        samples.len(),
        2,
        "expected exactly 2 idle samples (frames 2 and 3): {duty:#?}"
    );
    assert_eq!(samples[0]["frameIndex"], json!(2));
    assert_eq!(samples[1]["frameIndex"], json!(3));

    let configured_total_ms = 250 + 15; // extra delay + base per-slot pacing
    for sample in samples {
        let idle_ms = sample["idleMs"].as_u64().expect("idleMs must be a number");
        assert!(
            (150..=800).contains(&idle_ms),
            "measured idle {idle_ms}ms must fall within generous tolerance of ~{configured_total_ms}ms: {duty:#?}"
        );
    }

    let max_idle_ms = duty["maxIdleMs"]
        .as_u64()
        .expect("maxIdleMs must be a number");
    let sample_max = samples
        .iter()
        .map(|s| s["idleMs"].as_u64().unwrap())
        .max()
        .unwrap();
    assert_eq!(max_idle_ms, sample_max, "maxIdleMs mismatch: {duty:#?}");

    let mean_idle_ms = duty["meanIdleMs"]
        .as_f64()
        .expect("meanIdleMs must be a number");
    let sample_mean = samples
        .iter()
        .map(|s| s["idleMs"].as_u64().unwrap() as f64)
        .sum::<f64>()
        / samples.len() as f64;
    assert!(
        (mean_idle_ms - sample_mean).abs() < 0.001,
        "meanIdleMs {mean_idle_ms} must equal arithmetic mean {sample_mean}: {duty:#?}"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// Plan 12-03: a mid-roll failure must still resolve the idle clock for the
/// frame that follows it. Frame 1 completes; frame 2 fails via
/// `hardware.anomaly`; frame 3 completes. Frame 3's measured idle must reflect
/// one inter-frame delay period since frame 2's anomaly, not two stacked
/// periods since frame 1's completion.
#[test]
fn duty_cycle_still_resolves_correctly_across_a_mid_roll_failure() {
    let (mut child, mut stdin, rx, reader_handle) = spawn_engine_for_duty_cycle_test(250, Some(2));

    send(
        &mut stdin,
        3,
        "scan.start",
        duty_cycle_scan_start_params(&[1, 2, 3]),
    );
    let start_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );

    let events = drain_until(&rx, Duration::from_secs(10), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });

    let completed_event = events
        .iter()
        .find(|event| event["event"] == "scan.completed")
        .expect("scan.completed event must be present");
    let duty = &completed_event["payload"]["summary"]["dutyCycle"];
    assert!(
        duty.is_object(),
        "dutyCycle report must be present: {completed_event:#?}"
    );

    let samples = duty["perFrameIdleMs"]
        .as_array()
        .expect("perFrameIdleMs must be an array");
    let frame_three = samples
        .iter()
        .find(|s| s["frameIndex"] == json!(3))
        .expect("frame 3 must contribute an idle sample after frame 2 failed: {duty:#?}");
    let frame_three_idle_ms = frame_three["idleMs"]
        .as_u64()
        .expect("idleMs must be a number");

    // One inter-frame delay period: roughly 150-450ms. Two stacked periods
    // would be roughly 400-800ms, so this band is the discriminating assertion.
    assert!(
        (150..=450).contains(&frame_three_idle_ms),
        "frame 3 idle {frame_three_idle_ms}ms must reflect one delay period since frame 2's failure, not two stacked periods since frame 1: {duty:#?}"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

/// Live 2026-07-25 regression: a 34-frame batch (slots 5-38) displayed
/// "Frame 37 of 38" while the scanner was physically on slot 17 (the
/// batch's 13th frame) — the client-facing `frameOrdinal`/`totalFrames`
/// were being forwarded straight from `CoolscanPyTransport.start_scan`'s
/// upfront `scan.progress` burst (every requested slot named, 0-based
/// ordinal, ALL fired before `scan_many()` ever moves hardware — see
/// `coolscanpy_transport.py`'s own start_scan comment), which always ends
/// on this batch's LAST requested slot, frozen there for the rest of the
/// job.
///
/// `MOCK_BRIDGE_SCAN_UPFRONT_BURST` reproduces that exact shape (unlike
/// this file's other scan tests, which emit one scan.progress paired
/// immediately with its own scan.frameCompleted, in lockstep — a shape
/// that never actually exercises the bug). With a 5-frame batch, the
/// upfront burst's last message names ordinal 4 (0-based) of 5 — before
/// the fix, `frameOrdinal` would stay pinned at 4 no matter how many
/// frames had actually completed. After only 2 of 5 frames complete, the
/// honest ordinal is 3 (2 resolved, so frame 3 is now active) — this test
/// asserts exactly that, using the most recent `scan.progress` event
/// observed by that point.
#[test]
fn scan_progress_ordinal_tracks_completions_not_the_upfront_burst() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env("SCANSTUDIO_BRIDGE_CMD", env!("CARGO_BIN_EXE_mock_bridge"))
        .env("MOCK_BRIDGE_SCAN_UPFRONT_BURST", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");

    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-frame-ordinal-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let connect_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    send(
        &mut stdin,
        3,
        "scan.start",
        json!({
            "frames": [10, 20, 30, 40, 50],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "destination": unique_output_destination("frame-ordinal").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );

    // Stop at the 3rd of 5 frames' scan.frameCompleted (slot 30). Each
    // frame's resolution emits scan.frameState, then scan.frameCompleted,
    // then the corrected scan.progress reflecting that resolution (in that
    // wire order) -- so by the time slot 30's scan.frameCompleted arrives,
    // the progress event produced by slot 20's resolution (frame_ordinal
    // 3, the honest "2 resolved -> frame 3 now active" value) is already
    // on the wire, while slot 30's own progress event (frame_ordinal 4)
    // is not yet -- exactly capturing "2 of 5 resolved" without a race.
    let mut frame_completed_seen = 0;
    let events = drain_until(&rx, Duration::from_secs(10), |v| {
        if v.get("event") == Some(&json!("scan.frameCompleted")) {
            frame_completed_seen += 1;
        }
        frame_completed_seen >= 3
    });

    let progress_events: Vec<&Value> = events
        .iter()
        .filter(|v| v.get("event") == Some(&json!("scan.progress")))
        .collect();
    assert!(
        !progress_events.is_empty(),
        "expected at least one scan.progress event: {events:#?}"
    );
    let latest_progress = progress_events.last().expect("checked non-empty above");

    assert_eq!(
        latest_progress["payload"]["frameOrdinal"],
        json!(3),
        "with 2 of 5 frames resolved, frame 3 is now active -- must not be \
         the upfront burst's frozen last-slot ordinal (4): {events:#?}"
    );
    assert_eq!(
        latest_progress["payload"]["totalFrames"],
        json!(5),
        "totalFrames must be this batch's own frame count: {events:#?}"
    );

    // Drain to the job's natural end before shutting down cleanly.
    let _ = drain_until(&rx, Duration::from_secs(10), |v| {
        v.get("event") == Some(&json!("scan.completed"))
    });

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );
    let status = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(status.success(), "engine did not exit 0: {status:?}");
    let _ = reader_handle.join();
}

// -- roll.manualFrames / roll.previewStrip (Rung 4 of the feeding UX ladder) ----

/// End-to-end proof of the whole point of `RealLs5000::roll_manual_frames`'s
/// approval-binding logic: `roll.manualFrames` never went through
/// `roll.preview`'s own async worker (so `finalize_active_preview_terminal`
/// never ran), yet the frame it returns must still be approvable through
/// the exact same `roll.approve` path a normal preview's flagged frame
/// uses -- using the `operationId` THIS response minted, not one the app
/// supplied. Mirrors the Python bridge's own
/// `test_roll_manual_frames_dispatch_routes_rows_and_rearms_scan_gate`.
#[test]
fn roll_manual_frames_arms_a_session_whose_frame_is_approvable() {
    let (mut child, mut stdin, rx, reader_handle) =
        spawn_connected_engine_with_bridge_env("e2e-manual-frames-approve", &[]);

    send(
        &mut stdin,
        3,
        "roll.manualFrames",
        json!({"rows": [100, 300, 500]}),
    );
    let manual = recv_response_for(&rx, 3, |_| {});
    assert!(
        manual.get("error").is_none(),
        "a structurally valid manual placement must be accepted: {manual:#?}"
    );
    assert_eq!(manual["result"]["count"], json!(2));
    assert_eq!(manual["result"]["fingerprint"], json!("mock-manual-fp"));
    let operation_id = manual["result"]["operationId"]
        .as_str()
        .expect("roll.manualFrames must mint an operationId")
        .to_string();
    assert!(!operation_id.is_empty());

    let thumbnails = manual["result"]["thumbnails"]
        .as_array()
        .expect("thumbnails array");
    assert_eq!(thumbnails.len(), 2);
    assert_eq!(thumbnails[0]["frameIndex"], json!(1));
    assert_eq!(thumbnails[0]["thumbnail"]["boundaryRows"], json!([100, 300]));
    assert_eq!(thumbnails[0]["thumbnail"]["needsApproval"], json!(true));
    assert_eq!(
        thumbnails[0]["thumbnail"]["warnings"],
        json!(["user-picked"])
    );
    assert_eq!(manual["result"]["snaps"], json!([]));

    // The real proof: roll.approve works on this frame using the
    // engine-minted operationId, even though roll.preview was never called
    // this session.
    send(
        &mut stdin,
        4,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": operation_id}),
    );
    let approval = recv_response_for(&rx, 4, |_| {});
    assert!(
        approval.get("error").is_none(),
        "the frame roll.manualFrames returned must be approvable with its own operationId: {approval:#?}"
    );

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

/// `roll.approve` must still refuse a stale/mismatched operationId after a
/// manual placement -- the new binding logic must not accidentally become
/// permissive of any string.
#[test]
fn roll_manual_frames_frame_rejects_approval_with_a_foreign_operation_id() {
    let (mut child, mut stdin, rx, reader_handle) =
        spawn_connected_engine_with_bridge_env("e2e-manual-frames-wrong-op-id", &[]);

    send(
        &mut stdin,
        3,
        "roll.manualFrames",
        json!({"rows": [100, 300, 500]}),
    );
    let manual = recv_response_for(&rx, 3, |_| {});
    assert!(manual.get("error").is_none(), "{manual:#?}");

    send(
        &mut stdin,
        4,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "not-the-real-operation-id"}),
    );
    let approval = recv_response_for(&rx, 4, |_| {});
    assert!(
        approval.get("error").is_some(),
        "a foreign operationId must never be accepted: {approval:#?}"
    );
    assert_eq!(approval["error"]["code"], json!("INVALID_PARAMS"));

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

/// 2026-08-08 adversarial review, S1 (part 4): a completed preview binding
/// must be retired the moment a `roll.manualFrames` request is issued, and
/// stay retired if that request fails -- never left honorable against a
/// replacement session that never actually arrived. Without this, an old
/// approval (still shown by a UI that has not yet learned the replacement
/// placement failed) could be submitted while the driver's Roll session
/// itself has already moved on.
#[test]
fn roll_manual_frames_retires_the_prior_completed_binding_before_and_on_failure() {
    let log_directory = unique_output_destination("roll-manual-frames-retires-binding");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-manual-frames-retires-binding",
        &[
            ("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str()),
            (
                "MOCK_BRIDGE_MANUAL_FRAMES_ERROR",
                "manual placement rejected for this test",
            ),
        ],
    );

    // Establish a completed binding ("binding-a") via a normal preview --
    // the exact "placement/preview A completed" half of the S1 scenario.
    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1, 2, 3], "operationId": "binding-a"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status" && event["payload"]["operationId"] == "binding-a"
    });
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    // A replacement manual placement is attempted and fails (mock bridge
    // configured to reject every roll.manualFrames call).
    send(
        &mut stdin,
        4,
        "roll.manualFrames",
        json!({"rows": [100, 300, 500]}),
    );
    let manual = recv_response_for(&rx, 4, |_| {});
    assert!(
        manual.get("error").is_some(),
        "expected the mock bridge's configured manual-frames rejection: {manual:#?}"
    );
    assert_eq!(
        read_mock_bridge_calls(&log_path),
        vec!["roll.manualFrames"],
        "the failed placement must still have reached the bridge exactly once"
    );

    // Binding A must no longer be approvable: it was retired BEFORE the
    // (failing) roll.manualFrames request was even issued, and the failure
    // never restored it. This must be refused client-side, before any
    // bridge call -- the log below must show nothing new.
    send(
        &mut stdin,
        5,
        "roll.approve",
        json!({"frameIndex": 1, "operationId": "binding-a"}),
    );
    let approval = recv_response_for(&rx, 5, |_| {});
    let error = approval
        .get("error")
        .expect("binding A must stay retired after a failed replacement placement");
    assert_eq!(error["code"], json!("INVALID_PARAMS"));
    assert!(
        error["message"]
            .as_str()
            .is_some_and(|m| m.contains("does not match")),
        "{error:#?}"
    );
    assert_eq!(
        read_mock_bridge_calls(&log_path),
        vec!["roll.manualFrames"],
        "a retired binding must be refused before any roll.approve bridge call"
    );

    send(&mut stdin, 6, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 6, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(log_directory);
}

/// `roll.previewStrip` returns the wire shape a manual-placement editor
/// needs to seed itself: a loadable path plus the row<->pixel coordinate
/// space `roll.manualFrames`'s own `rows` are given in.
#[test]
fn roll_preview_strip_returns_the_wire_shape() {
    let (mut child, mut stdin, rx, reader_handle) =
        spawn_connected_engine_with_bridge_env("e2e-preview-strip", &[]);

    send(&mut stdin, 3, "roll.previewStrip", json!({}));
    let strip = recv_response_for(&rx, 3, |_| {});
    assert!(strip.get("error").is_none(), "{strip:#?}");
    assert_eq!(strip["result"]["rowCount"], json!(4800));
    assert_eq!(strip["result"]["pixelsPerRow"], json!(1));
    let image_path = strip["result"]["imagePath"]
        .as_str()
        .expect("imagePath is a string");
    assert!(!image_path.is_empty());

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

/// The bridge's own plain-English `INVALID_PARAMS` text (manual_frames.py's
/// gates) must survive into the public engine error unmodified, the same
/// "never reshape a validation message" contract `roll.setSpacingOffset`
/// and every other bridge-rejection path already honors.
#[test]
fn roll_manual_frames_propagates_invalid_params_message_unmodified() {
    let sentence = "the 1st frame you placed is about 8 mm tall (between rows 10 and 40), \
        outside the 15-75 mm range this driver accepts for manual placement";
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-manual-frames-invalid-params",
        &[("MOCK_BRIDGE_MANUAL_FRAMES_ERROR", sentence)],
    );

    send(&mut stdin, 3, "roll.manualFrames", json!({"rows": [10, 40]}));
    let manual = recv_response_for(&rx, 3, |_| {});
    let error = manual.get("error").expect("expected a rejected placement");
    assert_eq!(error["code"], json!("INVALID_PARAMS"));
    let message = error["message"].as_str().expect("message is a string");
    assert!(
        message.contains(sentence),
        "expected the exact bridge sentence to survive unmodified, got: {message}"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

// -- Adversarial review round 2 (2026-08-08): S3, approval/scan constrained --
// -- to frames actually shown by the completed preview ----------------------

/// S3: matching operationId/session identity alone must not be enough to
/// approve an arbitrary frame index -- the frame must be one the completed
/// preview actually returned AND actually flagged `needsApproval: true`.
/// Frame 2 here is previewed (so it exists) but never flagged, proving both
/// halves of the gate: existence in the binding is not sufficient on its
/// own either.
#[test]
fn roll_approve_rejects_a_frame_the_completed_preview_never_flagged() {
    let log_directory = unique_output_destination("roll-approve-unflagged-frame");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    // Deliberately no MOCK_BRIDGE_PREVIEW_APPROVAL_SLOTS: every previewed
    // frame comes back needsApproval: false.
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-roll-approve-unflagged",
        &[("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str())],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1, 2, 3], "operationId": "unflagged-preview"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "unflagged-preview"
    });
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    send(
        &mut stdin,
        4,
        "roll.approve",
        json!({"frameIndex": 2, "operationId": "unflagged-preview"}),
    );
    let approval = recv_response_for(&rx, 4, |_| {});
    let error = approval.get("error").expect("an unflagged frame must never be approvable");
    assert_eq!(error["code"], json!("INVALID_PARAMS"));
    assert!(
        error["message"]
            .as_str()
            .is_some_and(|m| m.contains("flagged for manual review")),
        "{error:#?}"
    );
    assert!(
        read_mock_bridge_calls(&log_path).is_empty(),
        "an unflagged approval must be refused before any bridge call"
    );

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}

/// S3: `scan.start` must refuse a requested frame the completed preview
/// never returned at all -- the mock bridge's preview worker always
/// returns exactly slots {1, 2, 3} (BRIDGE.md: "the bridge always
/// physically reads the full roll regardless of `slots`" -- a `frames`
/// filter on `scanner.acquireThumbnails` narrows which events a caller is
/// told about, not which slots the completed preview binding contains), so
/// requesting frame 4 alongside frame 1 must name frame 4 and never reach
/// the bridge, closing the "hidden slot" gap a caller could otherwise
/// exploit by asking for a frame the operator was never shown at all.
#[test]
fn scan_start_rejects_a_frame_the_completed_preview_never_returned() {
    let log_directory = unique_output_destination("scan-start-hidden-frame-call-log");
    let log_path = log_directory.join("bridge-calls.log");
    std::fs::write(&log_path, "").expect("create mock bridge call log");
    let log_path_string = log_path.display().to_string();
    let (mut child, mut stdin, rx, reader_handle) = spawn_connected_engine_with_bridge_env(
        "e2e-scan-start-hidden-frame",
        &[("MOCK_BRIDGE_CALL_LOG", log_path_string.as_str())],
    );

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1], "operationId": "hidden-frame-preview"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let _ = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.status"
            && event["payload"]["operationId"] == "hidden-frame-preview"
    });
    std::fs::write(&log_path, "").expect("reset mock bridge call log");

    let output_directory = unique_output_destination("scan-start-hidden-frame-output");
    send(
        &mut stdin,
        4,
        "scan.start",
        json!({
            "frames": [1, 4],
            "recipe": {
                "resolutionDpi": 4000,
                "bitDepth": 16,
                "multisamplePasses": 4,
                "channels": "rgbi",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": true
            },
            "output": {
                "archive": {
                    "enabled": false,
                    "fullCapturePackage": false,
                    "destination": output_directory.join("disabled-archive").display().to_string(),
                    "filenameTemplate": "frame-####"
                },
                "positive": {
                    "enabled": true,
                    "destination": output_directory.join("positive").display().to_string(),
                    "filenameTemplate": "frame-####",
                    "fileFormat": "tiff",
                    "colorProfile": "adobeRgb1998"
                },
                "preview": {"enabled": false}
            }
        }),
    );
    let start = recv_response_for(&rx, 4, |_| {});
    let error = start
        .get("error")
        .expect("a frame the completed preview never returned must refuse scan.start");
    assert_eq!(error["code"], json!("INVALID_PARAMS"));
    assert!(
        error["message"].as_str().is_some_and(|m| m.contains("frame 4")),
        "expected the refusal to name the hidden frame: {error:#?}"
    );
    assert!(
        read_mock_bridge_calls(&log_path)
            .iter()
            .all(|method| method != "scan.start"),
        "a hidden-frame request must be refused before any bridge call"
    );

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(output_directory);
}

#[test]
fn partial_frame_marker_survives_bridge_to_engine_wire() {
    // Lane C: the bridge marks a frame `partial: true` when its crop runs
    // off the preview edge. The engine used to drop the field silently
    // (BridgeThumbnail had no such field, serde discarded it); this pins
    // the whole path: mock bridge -> engine -> public wire. The mock's
    // designated partial slot is 39 (outside the standard 1..3 preview
    // trio, so no other test's thumbnail expectations change).
    let (mut child, mut stdin, rx, reader_handle) =
        spawn_connected_engine_with_bridge_env("e2e-partial-marker", &[]);

    send(
        &mut stdin,
        3,
        "scanner.acquireThumbnails",
        json!({"frames": [1, 2, 3], "operationId": "partial-preview"}),
    );
    assert!(recv_response_for(&rx, 3, |_| {}).get("error").is_none());
    let events = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.thumbnail" && event["payload"]["frameIndex"] == 1
    });
    let thumbnail_event = events.last().expect("slot 1 thumbnail event");
    assert!(
        thumbnail_event["payload"]["thumbnail"].get("partial").is_none(),
        "an ordinary fully-inside frame must not carry the marker: {thumbnail_event}"
    );

    let events = drain_until(&rx, Duration::from_secs(5), |event| {
        event["event"] == "scanner.thumbnail" && event["payload"]["frameIndex"] == 3
    });
    let partial_event = events.last().expect("slot 3 thumbnail event");
    assert_eq!(
        partial_event["payload"]["thumbnail"]["partial"],
        json!(true),
        "the mock's designated partial slot must reach the public wire intact: {partial_event}"
    );

    send(&mut stdin, 5, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 5, |_| {}).get("error").is_none());
    let exit = wait_for_exit_bounded(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "engine did not exit 0: {exit:?}");
    let _ = reader_handle.join();
}
