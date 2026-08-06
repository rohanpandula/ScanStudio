use std::collections::HashMap;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use scanstudio_app_lib::engine::{dispatch_line, engine_request, spawn_engine, EngineError};
use serde_json::Value;
use tauri::Manager;
use tauri_plugin_shell::ShellExt;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::oneshot;

type PendingMap = Mutex<HashMap<u64, oneshot::Sender<Result<Value, EngineError>>>>;

#[tokio::test]
async fn handshake_against_real_engine_binary() {
    let engine_path = match std::env::var("SCANSTUDIO_ENGINE_PATH") {
        Ok(p) => p,
        Err(_) => {
            println!("[engine_sidecar] SCANSTUDIO_ENGINE_PATH not set - skipping integration test");
            return;
        }
    };

    let mut child = tokio::process::Command::new(&engine_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("failed to spawn engine binary");

    let stdout = child.stdout.take().expect("stdout was piped");
    let mut stdin = child.stdin.take().expect("stdin was piped");

    let pending: Arc<PendingMap> = Arc::new(Mutex::new(HashMap::new()));
    let events: Arc<Mutex<Vec<Value>>> = Arc::new(Mutex::new(Vec::new()));

    let pending_for_reader = pending.clone();
    let events_for_reader = events.clone();
    let reader_task = tokio::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let events_for_dispatch = events_for_reader.clone();
            dispatch_line(&line, &pending_for_reader, &|payload| {
                events_for_dispatch.lock().unwrap().push(payload);
            });
        }
    });

    // id 1: engine.hello
    let (tx, rx) = oneshot::channel();
    pending.lock().unwrap().insert(1, tx);
    let line = serde_json::json!({"id": 1, "method": "engine.hello", "params": {"clientName": "skeleton-test", "protocolVersion": 1}}).to_string() + "\n";
    stdin.write_all(line.as_bytes()).await.expect("write hello");
    stdin.flush().await.expect("flush hello");
    let hello = rx
        .await
        .expect("engine terminated before responding")
        .expect("engine.hello returned an error");
    assert_eq!(hello["engineName"], "scanstudio-engine");
    assert_eq!(hello["protocolVersion"], 1);
    assert!(hello["capabilities"]
        .as_array()
        .expect("capabilities array")
        .iter()
        .any(|c| c == "simulated-ls5000"));

    // id 2: scanner.list
    let (tx, rx) = oneshot::channel();
    pending.lock().unwrap().insert(2, tx);
    let line =
        serde_json::json!({"id": 2, "method": "scanner.list", "params": {}}).to_string() + "\n";
    stdin.write_all(line.as_bytes()).await.expect("write list");
    stdin.flush().await.expect("flush list");
    let list = rx
        .await
        .expect("engine terminated before responding")
        .expect("scanner.list returned an error");
    let devices = list["devices"].as_array().expect("devices array");
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0]["deviceId"], "sim-ls5000-0");

    // id 3: scanner.connect with timeScale 0.01
    let (tx, rx) = oneshot::channel();
    pending.lock().unwrap().insert(3, tx);
    let line = serde_json::json!({"id": 3, "method": "scanner.connect", "params": {"deviceId": "sim-ls5000-0", "options": {"timeScale": 0.01}}}).to_string() + "\n";
    stdin
        .write_all(line.as_bytes())
        .await
        .expect("write connect");
    stdin.flush().await.expect("flush connect");
    let connect = rx
        .await
        .expect("engine terminated before responding")
        .expect("scanner.connect returned an error");
    assert_eq!(connect["status"]["connected"], true);
    assert!(
        !events.lock().unwrap().is_empty(),
        "expected at least one unsolicited scanner.status event"
    );

    // id 4: engine.shutdown, then the engine must exit 0
    let (tx, rx) = oneshot::channel();
    pending.lock().unwrap().insert(4, tx);
    let line =
        serde_json::json!({"id": 4, "method": "engine.shutdown", "params": {}}).to_string() + "\n";
    stdin
        .write_all(line.as_bytes())
        .await
        .expect("write shutdown");
    stdin.flush().await.expect("flush shutdown");
    let shutdown = rx
        .await
        .expect("engine terminated before responding")
        .expect("engine.shutdown returned an error");
    assert_eq!(shutdown, serde_json::json!({}));

    let exit_status = tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .expect("engine did not exit within 5s of shutdown")
        .expect("failed to wait on engine child");
    assert!(exit_status.success(), "engine should exit 0 after shutdown");

    reader_task.abort();
}

/// Field-report regression (fix/engine-hello-ordering): reproduces the
/// Windows report end to end through the app's *actual* production
/// engine-session code (`engine::spawn_engine` / `engine::engine_request`),
/// never a hand-rolled protocol client. Nothing in ports/tauri/app/src ever
/// constructs an `engine.hello` request itself -- `spawn_engine`'s handshake
/// task is solely responsible for sending it before anything else can reach
/// the engine's stdin. Against the pre-fix `engine.rs` (no handshake task,
/// `send_request` writing straight to the child), this test fails on its
/// first request with exactly the field report's error: "engine.hello must
/// be the first request".
///
/// Drives the field sequence in the order it actually happens in the app:
/// (1) device listing, fired automatically on `DeviceBar` mount before any
/// user interaction -- the report's "Devices list is simultaneously EMPTY"
/// symptom; (2) New Project / Create, `ProjectPanel`'s submit handler -- the
/// report's red "engine.hello must be the first request" banner; (3) device
/// listing again, proving the whole session stays healthy afterward, not
/// just the first call.
///
/// Runs against a `tauri::test` mock (windowless) app rather than a real
/// window: `tauri_plugin_shell::process::Command::spawn` and the
/// `CommandChild`/`CommandEvent` types it returns do not depend on the
/// windowing runtime, only `Manager::manage`/`AppHandle::state` do, and both
/// work identically under `tauri::test::mock_builder`'s `MockRuntime`.
#[tokio::test]
async fn field_sequence_succeeds_without_the_frontend_ever_sending_hello() {
    let engine_path = match std::env::var("SCANSTUDIO_ENGINE_PATH") {
        Ok(p) => p,
        Err(_) => {
            println!("[engine_sidecar] SCANSTUDIO_ENGINE_PATH not set - skipping integration test");
            return;
        }
    };

    let app = tauri::test::mock_builder()
        .plugin(tauri_plugin_shell::init())
        .build(tauri::test::mock_context(tauri::test::noop_assets()))
        .expect("failed to build mock tauri app");
    let handle = app.handle().clone();

    let command = handle.shell().command(&engine_path);
    spawn_engine(&handle, command).expect("failed to spawn the engine sidecar for the mock app");

    let assert_never_raced_the_handshake = |label: &str, result: &Result<Value, EngineError>| {
        if let Err(err) = result {
            assert!(
                !err.message.contains("must be the first request"),
                "{label} raced the handshake: {}",
                err.message
            );
        }
    };

    // (1) scanner.list, unprompted -- DeviceBar.tsx's mount effect.
    let list_result = engine_request(
        handle.state(),
        "scanner.list".to_string(),
        serde_json::json!({}),
    )
    .await;
    assert_never_raced_the_handshake("scanner.list", &list_result);
    let list = list_result.expect("scanner.list must succeed without a manually-sent hello");
    let devices = list["devices"].as_array().expect("devices array");
    assert!(!devices.is_empty(), "device list must not be empty");
    let device_id = devices[0]["deviceId"]
        .as_str()
        .expect("deviceId string")
        .to_string();

    // (2) project.create with the field report's exact recipe -- strip6, 6
    // frames, c41ColorNegative -- into a throwaway directory standing in for
    // the report's "F:\" output folder.
    let temp_dir = std::env::temp_dir().join(format!(
        "scanstudio-engine-sidecar-field-repro-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default(),
    ));
    std::fs::create_dir_all(&temp_dir).expect("create temp project dir");
    let create_result = engine_request(
        handle.state(),
        "project.create".to_string(),
        serde_json::json!({
            "name": "field-report-repro",
            "carrier": "strip6",
            "frameCount": 6,
            "filmProcess": "c41ColorNegative",
            "directory": temp_dir.display().to_string(),
        }),
    )
    .await;
    assert_never_raced_the_handshake("project.create", &create_result);
    create_result.expect("project.create must succeed without a manually-sent hello");

    // (3) scanner.list again -- the session must stay healthy for the rest
    // of the app's life, not just its first call.
    let relist_result = engine_request(
        handle.state(),
        "scanner.list".to_string(),
        serde_json::json!({}),
    )
    .await;
    assert_never_raced_the_handshake("scanner.list (after create)", &relist_result);
    let relist = relist_result.expect("scanner.list must still succeed after project.create");
    let redevices = relist["devices"].as_array().expect("devices array");
    assert!(!redevices.is_empty(), "device list must stay populated");
    assert_eq!(redevices[0]["deviceId"].as_str(), Some(device_id.as_str()));

    let shutdown_result = engine_request(
        handle.state(),
        "engine.shutdown".to_string(),
        serde_json::json!({}),
    )
    .await;
    assert_eq!(
        shutdown_result.expect("engine.shutdown must succeed"),
        serde_json::json!({})
    );

    let _ = std::fs::remove_dir_all(&temp_dir);
}
