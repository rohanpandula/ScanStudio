//! Proves the mock bridge binary (`src/bin/mock_bridge.rs`) itself is
//! correct, independent of any Phase 9 client code — mirrors
//! `end_to_end_sim.rs`'s spawn/pipe/helper structure exactly, adapted for
//! BRIDGE.md's envelope shapes and the two behavior-control env vars
//! (`MOCK_BRIDGE_VERSION_MISMATCH`, `MOCK_BRIDGE_CRASH_ON`).

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};

fn send(stdin: &mut impl Write, id: u64, method: &str, params: Value) {
    let req = json!({"id": id, "method": method, "params": params});
    let line = serde_json::to_string(&req).expect("serialize request");
    writeln!(stdin, "{line}").expect("write request line");
    stdin.flush().expect("flush stdin");
}

fn recv_line(rx: &mpsc::Receiver<String>) -> Value {
    let line = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("timed out waiting for a line from mock_bridge");
    serde_json::from_str(&line)
        .unwrap_or_else(|err| panic!("bad JSON line from mock_bridge: {line}: {err}"))
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

/// Spawns `mock_bridge`, optionally with extra env vars set, wiring stdin
/// (write side) and a background reader thread forwarding stdout lines to
/// an `mpsc::Receiver<String>`.
fn spawn_mock_bridge(envs: &[(&str, &str)]) -> (Child, ChildStdin, mpsc::Receiver<String>) {
    let bin = env!("CARGO_BIN_EXE_mock_bridge");
    let mut command = Command::new(bin);
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    for (key, value) in envs {
        command.env(key, value);
    }
    let mut child = command.spawn().expect("spawn mock_bridge binary");
    let stdin = child.stdin.take().expect("child stdin");
    let stdout = child.stdout.take().expect("child stdout");

    let (tx, rx) = mpsc::channel::<String>();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    (child, stdin, rx)
}

fn hello(stdin: &mut impl Write, rx: &mpsc::Receiver<String>, id: u64) -> Value {
    send(
        stdin,
        id,
        "bridge.hello",
        json!({"clientName": "mock-bridge-selftest", "protocolVersion": 1}),
    );
    recv_response_for(rx, id, |_| {})
}

fn scan_start_params(slots: &[u32]) -> Value {
    json!({
        "slots": slots,
        "recipe": {
            "resolutionDpi": 4000,
            "bitDepth": 16,
            "multisamplePasses": 4,
            "channels": "rgbi",
            "autofocus": true,
            "autoExposure": true
        },
        "output": {
            "destination": "/tmp/mock-bridge-selftest",
            "filenameTemplate": "frame-####.tif"
        }
    })
}

#[test]
fn hello_then_device_list_then_open_then_shutdown() {
    let (mut child, mut stdin, rx) = spawn_mock_bridge(&[]);

    let hello_resp = hello(&mut stdin, &rx, 1);
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );
    assert_eq!(
        hello_resp["result"]["bridgeName"],
        json!("mock-scanstudio-bridge")
    );
    assert_eq!(hello_resp["result"]["bridgeVersion"], json!("0.0.1-mock"));
    assert_eq!(hello_resp["result"]["protocolVersion"], json!(1));
    assert_eq!(
        hello_resp["result"]["capabilities"],
        json!(["ls5000-coolscanpy"])
    );

    send(&mut stdin, 2, "device.list", json!({}));
    let list_resp = recv_response_for(&rx, 2, |_| {});
    let devices = list_resp["result"]["devices"]
        .as_array()
        .expect("devices array");
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0]["deviceId"], json!("bridge-ls5000-0"));

    send(
        &mut stdin,
        3,
        "device.open",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let mut saw_connected_status_event = false;
    let open_resp = recv_response_for(&rx, 3, |event| {
        if event["event"] == "device.status" && event["payload"]["status"]["connected"] == true {
            saw_connected_status_event = true;
        }
    });
    assert!(
        open_resp.get("error").is_none(),
        "device.open failed: {open_resp:?}"
    );
    assert_eq!(open_resp["result"]["status"]["connected"], json!(true));
    assert!(
        saw_connected_status_event,
        "expected a device.status event with connected: true on device.open"
    );

    send(&mut stdin, 4, "bridge.shutdown", json!({}));
    let shutdown_resp = recv_response_for(&rx, 4, |_| {});
    assert!(
        shutdown_resp.get("error").is_none(),
        "shutdown failed: {shutdown_resp:?}"
    );

    let status = child.wait().expect("wait for mock_bridge process");
    assert!(status.success(), "mock_bridge did not exit 0: {status:?}");
}

#[test]
fn version_mismatch_env_var_forces_invalid_params() {
    let (mut child, mut stdin, rx) = spawn_mock_bridge(&[("MOCK_BRIDGE_VERSION_MISMATCH", "1")]);

    let hello_resp = hello(&mut stdin, &rx, 1);
    let error = hello_resp
        .get("error")
        .unwrap_or_else(|| panic!("expected hello to fail under version mismatch, got {hello_resp:?}"));
    assert_eq!(error["code"], json!("INVALID_PARAMS"));
    assert_eq!(error["recoverable"], json!(false));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn device_operations_require_open_device_after_hello() {
    let (mut child, mut stdin, rx) = spawn_mock_bridge(&[]);
    assert!(hello(&mut stdin, &rx, 1).get("error").is_none());

    send(&mut stdin, 2, "device.status", json!({}));
    let status_resp = recv_response_for(&rx, 2, |_| {});
    assert_eq!(status_resp["error"]["code"], json!("NOT_CONNECTED"));
    assert_eq!(status_resp["error"]["message"], json!("no device is open"));

    send(
        &mut stdin,
        3,
        "roll.preview",
        json!({"material": "colorNegative"}),
    );
    let preview_resp = recv_response_for(&rx, 3, |_| {});
    assert_eq!(preview_resp["error"]["code"], json!("NOT_CONNECTED"));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn roll_preview_emits_three_thumbnails_then_complete() {
    let (mut child, mut stdin, rx) = spawn_mock_bridge(&[]);

    let hello_resp = hello(&mut stdin, &rx, 1);
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "device.open",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let open_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        open_resp.get("error").is_none(),
        "device.open failed: {open_resp:?}"
    );

    send(
        &mut stdin,
        3,
        "roll.preview",
        json!({"material": "colorNegative"}),
    );
    let preview_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        preview_resp.get("error").is_none(),
        "roll.preview failed: {preview_resp:?}"
    );
    assert_eq!(preview_resp["result"]["accepted"], json!(true));

    let mut thumbnail_slots: Vec<u64> = Vec::new();
    let mut preview_complete: Option<Value> = None;
    while preview_complete.is_none() {
        let v = recv_line(&rx);
        match v.get("event").and_then(|e| e.as_str()) {
            Some("roll.thumbnail") => {
                thumbnail_slots.push(v["payload"]["slot"].as_u64().expect("thumbnail slot"));
            }
            Some("roll.previewComplete") => {
                preview_complete = Some(v);
            }
            _ => {}
        }
    }

    assert_eq!(thumbnail_slots, vec![1, 2, 3]);
    let complete = preview_complete.expect("roll.previewComplete must have been observed");
    assert_eq!(complete["payload"]["count"], json!(3));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn scan_start_emits_progress_and_receipt_per_slot_then_completed() {
    let (mut child, mut stdin, rx) = spawn_mock_bridge(&[]);

    let hello_resp = hello(&mut stdin, &rx, 1);
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "device.open",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let open_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        open_resp.get("error").is_none(),
        "device.open failed: {open_resp:?}"
    );

    send(&mut stdin, 3, "scan.start", scan_start_params(&[1, 2]));
    let start_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        start_resp.get("error").is_none(),
        "scan.start failed: {start_resp:?}"
    );
    let job_id = start_resp["result"]["jobId"]
        .as_str()
        .expect("scan.start result must include jobId")
        .to_string();

    let mut frame_completed_slots: Vec<u64> = Vec::new();
    let mut scan_completed: Option<Value> = None;
    while scan_completed.is_none() {
        let v = recv_line(&rx);
        match v.get("event").and_then(|e| e.as_str()) {
            Some("scan.progress") => {
                assert_eq!(v["payload"]["jobId"], json!(job_id));
            }
            Some("scan.frameCompleted") => {
                assert_eq!(v["payload"]["jobId"], json!(job_id));
                let slot = v["payload"]["slot"].as_u64().expect("frameCompleted slot");
                frame_completed_slots.push(slot);
                let rgb_path = v["payload"]["receipt"]["rgbPath"]
                    .as_str()
                    .expect("receipt.rgbPath must be a string");
                assert!(!rgb_path.is_empty(), "rgbPath must not be empty");
            }
            Some("scan.completed") => {
                scan_completed = Some(v);
            }
            _ => {}
        }
    }

    assert_eq!(frame_completed_slots, vec![1, 2]);
    let completed = scan_completed.expect("scan.completed must have been observed");
    assert_eq!(completed["payload"]["jobId"], json!(job_id));
    assert_eq!(completed["payload"]["summary"]["completed"], json!([1, 2]));
    assert_eq!(completed["payload"]["summary"]["failed"], json!([]));
    assert_eq!(completed["payload"]["summary"]["stopped"], json!(false));

    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn crash_on_env_var_kills_process_without_responding() {
    let (mut child, mut stdin, rx) = spawn_mock_bridge(&[("MOCK_BRIDGE_CRASH_ON", "scan.start")]);

    let hello_resp = hello(&mut stdin, &rx, 1);
    assert!(
        hello_resp.get("error").is_none(),
        "hello failed: {hello_resp:?}"
    );

    send(
        &mut stdin,
        2,
        "device.open",
        json!({"deviceId": "bridge-ls5000-0"}),
    );
    let open_resp = recv_response_for(&rx, 2, |_| {});
    assert!(
        open_resp.get("error").is_none(),
        "device.open failed: {open_resp:?}"
    );

    send(
        &mut stdin,
        3,
        "roll.preview",
        json!({"material": "colorNegative"}),
    );
    let preview_resp = recv_response_for(&rx, 3, |_| {});
    assert!(
        preview_resp.get("error").is_none(),
        "roll.preview failed: {preview_resp:?}"
    );
    // Drain the preview's thumbnail/previewComplete events so they can't
    // interfere with the crash assertion below.
    loop {
        let v = recv_line(&rx);
        if v.get("event").and_then(|e| e.as_str()) == Some("roll.previewComplete") {
            break;
        }
    }

    send(&mut stdin, 4, "scan.start", scan_start_params(&[1]));

    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait().expect("poll mock_bridge process") {
            break status;
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            panic!("mock_bridge did not exit after MOCK_BRIDGE_CRASH_ON=scan.start fired");
        }
        thread::sleep(Duration::from_millis(10));
    };
    assert!(
        !status.success(),
        "mock_bridge must exit non-zero on a simulated crash, got {status:?}"
    );

    // No response for the crashed scan.start request (id 4) should ever
    // have arrived.
    let never_responded_to_request_4 = match rx.recv_timeout(Duration::from_millis(200)) {
        Ok(line) => {
            let v: Value = serde_json::from_str(&line).unwrap_or(json!({}));
            v.get("id") != Some(&json!(4))
        }
        Err(_) => true,
    };
    assert!(
        never_responded_to_request_4,
        "mock_bridge must not send any response for the crashed scan.start request"
    );
}
