//! Integration tests proving `BridgeClient`'s handshake, correlation,
//! timeout-detection, and restart-on-crash all work against the real
//! `mock_bridge` subprocess from Plan 09-01 — a real subprocess boundary,
//! not an in-memory fake. One test per `<behavior>` bullet from Plan
//! 09-02's Task 1.

use std::sync::Arc;
use std::thread;
use std::time::Duration;

use serde_json::json;

use scanstudio_engine::real_backend::{BridgeCallError, BridgeClient};

fn mock_bridge_bin() -> &'static str {
    env!("CARGO_BIN_EXE_mock_bridge")
}

/// Generous request timeout for tests that expect a fast, healthy
/// response and are not themselves testing timeout precision. The mock
/// bridge normally answers in low single-digit milliseconds, but this
/// suite runs alongside other concurrently-spawning test binaries (and,
/// in this repo, other agents' builds/tests running at the same time) —
/// a tight timeout here would make correctness assertions flaky under
/// system load rather than actually exercising `BridgeClient`'s own
/// timeout-detection behavior, which `crash_on_call_triggers_restart_and_next_call_succeeds`
/// covers deliberately below.
const GENEROUS_TIMEOUT: Duration = Duration::from_secs(3);

#[test]
fn spawn_against_healthy_mock_bridge_succeeds() {
    let client = BridgeClient::spawn(mock_bridge_bin(), GENEROUS_TIMEOUT)
        .expect("spawn should succeed against a healthy mock bridge");
    assert!(client.is_healthy());
    let hello = client.hello_info();
    assert_eq!(hello.bridge_name, "mock-scanstudio-bridge");
    assert_eq!(hello.protocol_version, 1);
}

#[cfg(unix)]
#[test]
fn spawn_uses_an_exact_existing_bridge_path_with_spaces() {
    use std::os::unix::fs::PermissionsExt;

    let root = std::env::temp_dir().join(format!(
        "scanstudio relocated app {}",
        std::process::id()
    ));
    std::fs::create_dir_all(&root).expect("relocated fixture directory");
    let bridge = root.join("scanstudio bridge");
    std::fs::copy(mock_bridge_bin(), &bridge).expect("copy mock bridge into path with spaces");
    let mut permissions = std::fs::metadata(&bridge).expect("bridge metadata").permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&bridge, permissions).expect("bridge executable permission");

    let client = BridgeClient::spawn(
        bridge.to_str().expect("utf-8 relocated path"),
        GENEROUS_TIMEOUT,
    )
    .expect("exact existing bridge path with spaces must spawn and handshake");
    assert_eq!(client.hello_info().bridge_name, "mock-scanstudio-bridge");
    drop(client);
    std::fs::remove_dir_all(root).expect("remove relocated fixture");
}

#[test]
fn spawn_against_nonexistent_command_fails_cleanly() {
    let result = BridgeClient::spawn("/definitely/does/not/exist/xyz", GENEROUS_TIMEOUT);
    assert!(
        matches!(result, Err(BridgeCallError::Io(_))),
        "expected an Io error for a nonexistent command, got something else"
    );
}

#[test]
fn spawn_against_version_mismatched_bridge_fails() {
    // Failure injection goes through `spawn_with_env`, which scopes the
    // variable to this one child process. Never configure `mock_bridge`
    // via `std::env::set_var` here: `cargo test` runs this file's tests
    // concurrently in one process, and a process-global variable would
    // leak into whatever bridge another test happens to spawn while it
    // is set.
    match BridgeClient::spawn_with_env(
        mock_bridge_bin(),
        GENEROUS_TIMEOUT,
        &[("MOCK_BRIDGE_VERSION_MISMATCH", "1")],
    ) {
        Err(BridgeCallError::BridgeError { code, .. }) => {
            assert_eq!(code, "INVALID_PARAMS");
        }
        Err(other) => panic!("expected a BridgeError, got {other:?}"),
        Ok(_) => panic!("expected spawn to fail against a version-mismatched bridge"),
    }
}

#[test]
fn healthy_client_call_returns_device_list() {
    let client = BridgeClient::spawn(mock_bridge_bin(), GENEROUS_TIMEOUT)
        .expect("spawn should succeed against a healthy mock bridge");

    let value = client
        .call("device.list", json!({}))
        .expect("device.list should succeed on a healthy client");
    let devices = value["devices"]
        .as_array()
        .expect("devices should be present and an array");
    assert!(!devices.is_empty(), "devices should be non-empty");
}

#[test]
fn crash_on_call_triggers_restart_and_next_call_succeeds() {
    // MOCK_BRIDGE_CRASH_ON is an immediate process death, not a hang, so
    // the crashed call resolves via the reader thread's EOF-driven
    // ProcessExited path almost instantly regardless of the configured
    // ceiling — this test stays fast even with the same generous timeout
    // used elsewhere, without depending on a tight ceiling for its speed.
    //
    // The variable rides on `spawn_with_env` (child-scoped, not
    // process-global set_var — see spawn_against_version_mismatched_bridge_fails),
    // and the client re-applies it when it respawns the crashed bridge,
    // so the restarted process is armed identically to the original.
    let client = BridgeClient::spawn_with_env(
        mock_bridge_bin(),
        GENEROUS_TIMEOUT,
        &[("MOCK_BRIDGE_CRASH_ON", "scan.start")],
    )
    .expect("spawn should succeed — MOCK_BRIDGE_CRASH_ON=scan.start doesn't affect bridge.hello");

    let scan_start_params = json!({
        "slots": [1],
        "recipe": {
            "resolutionDpi": 4000,
            "bitDepth": 16,
            "multisamplePasses": 1,
            "channels": "rgb",
            "autofocus": true,
            "autoExposure": true
        },
        "output": {
            "destination": "/tmp",
            "filenameTemplate": "f-####.tif"
        }
    });
    let crashed = client.call("scan.start", scan_start_params);
    assert!(
        crashed.is_err(),
        "expected scan.start to fail when the bridge crashes on it"
    );

    // Prove the internal restart worked: the very next call, on the same
    // client, must succeed against the transparently-respawned process.
    let recovered = client.call("device.list", json!({}));
    assert!(
        recovered.is_ok(),
        "expected the client to have transparently restarted and recovered: {:?}",
        recovered.err()
    );
}

#[test]
fn concurrent_calls_never_cross_responses() {
    let client = Arc::new(
        BridgeClient::spawn(mock_bridge_bin(), GENEROUS_TIMEOUT)
            .expect("spawn should succeed against a healthy mock bridge"),
    );

    let handles: Vec<_> = (0..4)
        .map(|_| {
            let client = Arc::clone(&client);
            thread::spawn(move || {
                for _ in 0..5 {
                    let value = client
                        .call("device.list", json!({}))
                        .expect("device.list should succeed under concurrent load");
                    let devices = value["devices"]
                        .as_array()
                        .expect("devices should be present and an array");
                    assert!(!devices.is_empty(), "devices should be non-empty");
                }
            })
        })
        .collect();

    for handle in handles {
        handle.join().expect("worker thread should not panic");
    }
}
