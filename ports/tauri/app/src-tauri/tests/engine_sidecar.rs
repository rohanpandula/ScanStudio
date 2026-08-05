use std::collections::HashMap;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use scanstudio_app_lib::engine::{dispatch_line, EngineError};
use serde_json::Value;
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
    let line = serde_json::json!({"id": 2, "method": "scanner.list", "params": {}}).to_string() + "\n";
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
    stdin.write_all(line.as_bytes()).await.expect("write connect");
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
    let line = serde_json::json!({"id": 4, "method": "engine.shutdown", "params": {}}).to_string() + "\n";
    stdin.write_all(line.as_bytes()).await.expect("write shutdown");
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
