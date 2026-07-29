//! Spawns the built `scanstudio-engine` binary and drives a full
//! connect -> scan -> stop -> shutdown session over real stdio pipes — D-9d.
//!
//! Timing is driven by observed events, never fixed sleeps: `scan.stop` is
//! sent as soon as frame 2 activity is observed (genuinely mid-frame-2),
//! and `engine.shutdown` is sent only after `scan.completed` is observed in
//! the graceful-session case. A second test proves EOF cancellation is also
//! bounded while a job is active.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    mpsc,
};
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};

fn unique_test_output_root(label: &str) -> PathBuf {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    loop {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "scanstudio-e2e-sim-{label}-{}-{id}",
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

/// Motion readiness belongs to the real bridge's live SAFE-02 observation.
/// A simulator connection must omit it rather than fabricate an armed or
/// disarmed hardware state.
#[test]
fn simulated_status_omits_bridge_motion_armed() {
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .env_remove("SCANSTUDIO_BRIDGE_CMD")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn simulator-only engine");
    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "sim-motion-status", "protocolVersion": 1}),
    );
    assert!(recv_response_for(&rx, 1, |_| {}).get("error").is_none());
    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "sim-ls5000-0"}),
    );
    let connected = recv_response_for(&rx, 2, |_| {});
    assert!(connected.get("error").is_none(), "{connected:#?}");
    assert!(
        connected["result"]["status"].get("motionArmed").is_none(),
        "the simulator must omit bridge-only motion readiness: {connected:#?}"
    );

    send(&mut stdin, 3, "scanner.status", json!({}));
    let status = recv_response_for(&rx, 3, |_| {});
    assert!(
        status["result"].get("motionArmed").is_none(),
        "a fresh simulator status must still omit bridge-only motion readiness: {status:#?}"
    );

    send(&mut stdin, 4, "engine.shutdown", json!({}));
    assert!(recv_response_for(&rx, 4, |_| {}).get("error").is_none());
    assert!(child.wait().expect("wait for engine").success());
    let _ = reader_handle.join();
}

#[test]
fn connect_scan_stop_after_current_frame_shutdown() {
    // Real archive/positive/preview files land on disk now (Plan 03-02) --
    // never write into "/Scans/..." (unwritable in CI); use a fresh,
    // uniquely-named temp directory as the shared base for all three
    // output destinations instead.
    let base = unique_test_output_root("scan-stop");

    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
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

    // 1. engine.hello — must be first.
    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "e2e-test", "protocolVersion": 1}),
    );
    let hello_resp = recv_response_for(&rx, 1, |_| {});
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );
    assert!(hello_resp["result"]["protocolVersion"].is_number());

    // 2. scanner.list
    send(&mut stdin, 2, "scanner.list", json!({}));
    let list_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        list_resp.get("error").is_none(),
        "scanner.list failed: {list_resp:?}"
    );
    assert_eq!(
        list_resp["result"]["devices"].as_array().map(|a| a.len()),
        Some(1)
    );

    // 3. scanner.connect, timeScale ~= 0.01
    send(
        &mut stdin,
        3,
        "scanner.connect",
        json!({"deviceId": "sim-ls5000-0", "options": {"timeScale": 0.01}}),
    );
    let connect_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        connect_resp.get("error").is_none(),
        "connect failed: {connect_resp:?}"
    );

    // 4. sim.loadMedia(roll36)
    send(&mut stdin, 4, "sim.loadMedia", json!({"carrier": "roll36"}));
    let load_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        load_resp.get("error").is_none(),
        "loadMedia failed: {load_resp:?}"
    );

    // 5. scan.start with capture, per-frame preparation, processing, and output recipes.
    send(
        &mut stdin,
        5,
        "scan.start",
        json!({
            "frames": [1, 2, 3],
            // resolutionDpi kept small (not the 4000 native max) so real
            // TIFF/JPEG encoding stays fast in this test.
            "recipe": {"resolutionDpi": 40, "bitDepth": 16, "multisamplePasses": 2, "channels": "rgbi"},
            "processing": {
                "filmProcess": "c41ColorNegative",
                "autofocusEachFrame": true,
                "autoExposureEachFrame": false,
                "digitalIceEnabled": true,
                "digitalIceMode": "hybrid"
            },
            "output": {
                "archive": {
                    "filenameTemplate": "Archive_####",
                    "destination": base.join("Archive").display().to_string()
                },
                "positive": {
                    "enabled": true,
                    "fileFormat": "tiff",
                    "colorProfile": "proPhotoRgb",
                    "filenameTemplate": "Positive_####",
                    "destination": base.join("Positive").display().to_string()
                },
                "preview": {
                    "enabled": true,
                    "fileFormat": "jpeg",
                    "maxLongEdgePx": 2048,
                    "filenameTemplate": "Preview_####",
                    "destination": base.join("Preview").display().to_string()
                }
            }
        }),
    );

    let mut stop_sent = false;
    let mut job_states: Vec<String> = Vec::new();
    let mut final_summary: Option<Value> = None;
    let mut first_receipt: Option<Value> = None;

    // Capture the jobId from the scan.start response, tolerating events
    // (e.g. scan.jobState "scanning") interleaved before it on the wire.
    let start_resp = recv_response_for(&rx, 5, |event| {
        record_job_state(event, &mut job_states);
    });
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );
    let job_id: String = start_resp["result"]["jobId"]
        .as_str()
        .unwrap_or_else(|| panic!("scan.start result must include jobId: {start_resp:?}"))
        .to_string();

    loop {
        let v = recv_line(&rx);
        let Some(event) = v.get("event").and_then(|e| e.as_str()) else {
            continue;
        };

        record_job_state(&v, &mut job_states);

        match event {
            "scan.progress" | "scan.frameState" => {
                let frame_index = v["payload"]["frameIndex"].as_u64();
                if !stop_sent && frame_index == Some(2) {
                    send(
                        &mut stdin,
                        6,
                        "scan.stop",
                        json!({"jobId": job_id.clone(), "mode": "afterCurrentFrame"}),
                    );
                    stop_sent = true;
                }
            }
            "scan.completed" => {
                final_summary = Some(v["payload"]["summary"].clone());
            }
            "scan.frameCompleted" if first_receipt.is_none() => {
                first_receipt = Some(v["payload"]["receipt"].clone());
            }
            _ => {}
        }

        if final_summary.is_some() {
            break;
        }
    }

    assert!(
        stop_sent,
        "never observed frame 2 activity to trigger scan.stop"
    );

    // scan.stop's own response may or may not have been drained above
    // (it is not guaranteed to arrive before scan.completed) — drain for
    // it explicitly if not already seen, tolerating either order.
    // (No-op if it already flowed through the loop above as an
    // unrecognized top-level id — the loop only inspects `event` lines, so
    // the {"id":6,...} response, if it arrives before scan.completed,
    // is simply skipped by the `let Some(event) = ... else { continue }`
    // guard. Nothing further to do here.)

    let summary = final_summary.expect("scan.completed summary must have been observed");
    let receipt = first_receipt.expect("scan.frameCompleted receipt must have been observed");
    assert_eq!(receipt["processing"]["autofocusEachFrame"], true);
    assert_eq!(receipt["processing"]["autoExposureEachFrame"], false);
    assert_eq!(receipt["processing"]["digitalIceMode"], "hybrid");
    assert!(receipt["processing"].get("grainReduction").is_none());
    assert!(receipt["processing"].get("fadingCorrection").is_none());
    assert!(receipt["processing"].get("outputRendering").is_none());
    assert_eq!(
        receipt["output"]["archive"]["filenameTemplate"],
        "Archive_####"
    );
    assert_eq!(
        receipt["output"]["archive"]["destination"],
        base.join("Archive").display().to_string()
    );
    assert_eq!(receipt["output"]["positive"]["fileFormat"], "tiff");
    assert_eq!(receipt["output"]["positive"]["colorProfile"], "proPhotoRgb");
    assert_eq!(receipt["output"]["preview"]["fileFormat"], "jpeg");
    assert!(receipt["output"]["archive"].get("fileFormat").is_none());
    assert!(receipt["output"]["archive"].get("colorProfile").is_none());

    // Plan 03-02's core deliverable: the completed frame's receipt carries
    // real, on-disk file paths -- not a stub.
    let archive_path = receipt["outputs"]["archivePath"]
        .as_str()
        .expect("archivePath present on a completed receipt");
    assert!(
        std::path::Path::new(archive_path).is_file(),
        "archive file must exist on disk at {archive_path}"
    );
    let positive_path = receipt["outputs"]["positivePath"]
        .as_str()
        .expect("positivePath present (positive recipe was enabled)");
    assert!(
        std::path::Path::new(positive_path).is_file(),
        "positive file must exist on disk at {positive_path}"
    );
    let preview_path = receipt["outputs"]["previewPath"]
        .as_str()
        .expect("previewPath present (preview recipe was enabled)");
    assert!(
        std::path::Path::new(preview_path).is_file(),
        "preview file must exist on disk at {preview_path}"
    );

    let completed: Vec<u64> = summary["completed"]
        .as_array()
        .expect("summary.completed is an array")
        .iter()
        .map(|v| v.as_u64().expect("completed entries are u32 frame indices"))
        .collect();
    assert_eq!(
        completed,
        vec![1, 2],
        "expected frames 1 and 2 completed, got {completed:?}"
    );
    assert!(
        !completed.contains(&3),
        "frame 3 must be absent from completed (never started)"
    );
    assert_eq!(
        summary["stopped"],
        json!(true),
        "summary.stopped must be true"
    );
    assert_eq!(
        job_states.last().map(|s| s.as_str()),
        Some("stopped"),
        "job state sequence must end in stopped, got {job_states:?}"
    );

    // 7. engine.shutdown — only after observing scan.completed above.
    send(&mut stdin, 7, "engine.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 7, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );

    let status = child.wait().expect("wait for engine process");
    assert!(status.success(), "engine did not exit 0: {status:?}");

    let _ = reader_handle.join();
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn closing_stdin_cancels_an_active_job_without_hanging() {
    let output_root = unique_test_output_root("closing-stdin");
    let bin = env!("CARGO_BIN_EXE_scanstudio-engine");
    let mut child = Command::new(bin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn engine binary");
    let mut stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");
    let (tx, rx) = mpsc::channel::<String>();
    let reader_handle = thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    send(
        &mut stdin,
        1,
        "engine.hello",
        json!({"clientName": "eof-test", "protocolVersion": 1}),
    );
    let _ = recv_response_for(&rx, 1, |_| {});
    send(
        &mut stdin,
        2,
        "scanner.connect",
        json!({"deviceId": "sim-ls5000-0", "options": {"timeScale": 10.0}}),
    );
    let _ = recv_response_for(&rx, 2, |_| {});
    send(&mut stdin, 3, "sim.loadMedia", json!({"carrier": "roll36"}));
    let _ = recv_response_for(&rx, 3, |_| {});
    send(
        &mut stdin,
        4,
        "scan.start",
        json!({
            "frames": [1, 2, 3],
            "recipe": {"resolutionDpi": 4000, "bitDepth": 16, "multisamplePasses": 2, "channels": "rgbi"},
            "output": {
                "archive": {
                    "filenameTemplate": "Archive_####",
                    "destination": output_root.join("Archive").display().to_string()
                },
                "positive": {"enabled": false},
                "preview": {"enabled": false}
            }
        }),
    );
    let start = recv_response_for(&rx, 4, |_| {});
    assert!(start.get("error").is_none(), "scan.start failed: {start:?}");

    drop(stdin);
    let deadline = std::time::Instant::now() + Duration::from_secs(1);
    let status = loop {
        if let Some(status) = child.try_wait().expect("poll engine") {
            break status;
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            panic!("engine did not exit within one second after stdin closed");
        }
        thread::sleep(Duration::from_millis(10));
    };
    assert!(
        status.success(),
        "engine did not exit 0 after EOF: {status:?}"
    );
    let _ = reader_handle.join();
}

fn record_job_state(event: &Value, job_states: &mut Vec<String>) {
    if event.get("event").and_then(|e| e.as_str()) == Some("scan.jobState") {
        if let Some(state) = event["payload"]["state"].as_str() {
            job_states.push(state.to_string());
        }
    }
}
