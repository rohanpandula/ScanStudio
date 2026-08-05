use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State, Wry};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;
use tokio::sync::oneshot;

use crate::wsl::bridge_cmd::{
    build_engine_env, BRIDGE_ENTRYPOINT, HW_MOTION_ENV_VAR, WSLENV_ENV_VAR,
};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EngineError {
    pub code: String,
    pub message: String,
    pub recoverable: bool,
}

type PendingMap = Mutex<HashMap<u64, oneshot::Sender<Result<Value, EngineError>>>>;

// Engine responses are prompt acks (long work is event-driven), so a response
// taking longer than this means it was lost and the waiter must not hang.
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(60);

pub struct EngineHandle {
    // Option because CommandChild::kill(self) consumes the child, so it must
    // be .take()-n out of the Mutex rather than called through the guard.
    child: Mutex<Option<CommandChild>>,
    next_id: AtomicU64,
    pending: PendingMap,
}

/// Explicit environment additions for the engine sidecar.
///
/// The child inherits the app's normal environment from `Command`; on
/// Windows we add the authoritative WSL bridge command and, only for an
/// owner-armed process, the motion-forwarding additions. Keeping this decision
/// in a pure helper lets tests prove the production spawn path uses the same
/// `build_engine_env` implementation as the unit tests.
fn engine_spawn_env(
    is_windows: bool,
    is_linux: bool,
    linux_bridge: Option<String>,
    windows_hw_motion: Option<&str>,
    windows_wslenv: Option<&str>,
) -> Vec<(String, String)> {
    if is_windows {
        build_engine_env(&[], BRIDGE_ENTRYPOINT, windows_hw_motion, windows_wslenv)
    } else if is_linux {
        linux_bridge
            .map(|command| vec![("SCANSTUDIO_BRIDGE_CMD".to_string(), command)])
            .unwrap_or_default()
    } else {
        Vec::new()
    }
}

/// Linux uses the same four-level bridge precedence as the portable launcher.
/// Inputs are already validated paths where appropriate, which keeps the
/// ordering deterministic and directly testable without touching process
/// globals from parallel tests.
fn resolve_linux_bridge_cmd(
    environment_override: Option<&str>,
    config_contents: Option<&str>,
    bundled_bridge: Option<&str>,
    path_bridge: Option<&str>,
) -> Option<String> {
    if let Some(command) = environment_override
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return Some(command.to_string());
    }
    if let Some(command) = config_contents
        .and_then(|contents| contents.lines().next())
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return Some(command.to_string());
    }
    bundled_bridge
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| path_bridge.map(str::trim).filter(|value| !value.is_empty()))
        .map(str::to_string)
}

fn command_on_path(name: &str) -> Option<std::path::PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

fn runtime_linux_bridge_cmd(app: &tauri::App<Wry>) -> Option<String> {
    let environment_override = std::env::var("SCANSTUDIO_BRIDGE_CMD").ok();
    let config_contents = std::env::var_os("HOME").and_then(|home| {
        std::fs::read_to_string(
            std::path::PathBuf::from(home)
                .join(".config")
                .join("scanstudio")
                .join("bridge-command"),
        )
        .ok()
    });
    let bundled_bridge = app
        .path()
        .resource_dir()
        .ok()
        .map(|directory| directory.join("scanstudio-bridge"))
        .filter(|candidate| candidate.is_file());
    let path_bridge = command_on_path("scanstudio-bridge");

    resolve_linux_bridge_cmd(
        environment_override.as_deref(),
        config_contents.as_deref(),
        bundled_bridge.as_ref().and_then(|path| path.to_str()),
        path_bridge.as_ref().and_then(|path| path.to_str()),
    )
}

/// Shared, Tauri-independent line dispatcher. Used identically by the
/// production reader task below AND by the Rust integration test
/// (app/src-tauri/tests/engine_sidecar.rs), so the same logic gets
/// exercised against the real binary from both call sites.
pub fn dispatch_line(line: &str, pending: &PendingMap, on_event: &dyn Fn(Value)) {
    let parsed: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => return, // ignore malformed / non-protocol stdout noise
    };
    if let Some(id) = parsed.get("id").and_then(|v| v.as_u64()) {
        let sender = pending.lock().unwrap().remove(&id);
        if let Some(sender) = sender {
            if let Some(result) = parsed.get("result") {
                let _ = sender.send(Ok(result.clone()));
            } else if let Some(err) = parsed.get("error") {
                let engine_err = EngineError {
                    code: err
                        .get("code")
                        .and_then(|c| c.as_str())
                        .unwrap_or("INTERNAL")
                        .to_string(),
                    message: err
                        .get("message")
                        .and_then(|m| m.as_str())
                        .unwrap_or("")
                        .to_string(),
                    recoverable: err
                        .get("recoverable")
                        .and_then(|r| r.as_bool())
                        .unwrap_or(false),
                };
                let _ = sender.send(Err(engine_err));
            }
        }
    } else if parsed.get("event").is_some() {
        on_event(parsed);
    }
}

/// Drop the child handle and fail every pending request so awaiting callers
/// return promptly instead of hanging on a dead engine. Idempotent.
fn fail_pending_requests(handle: &EngineHandle) {
    *handle.child.lock().unwrap() = None;
    let drained: Vec<_> = handle.pending.lock().unwrap().drain().collect();
    for (_, sender) in drained {
        let _ = sender.send(Err(EngineError {
            code: "INTERNAL".into(),
            message: "engine process terminated".into(),
            recoverable: false,
        }));
    }
}

pub fn setup(app: &mut tauri::App<Wry>) -> Result<(), Box<dyn std::error::Error>> {
    let linux_bridge = if cfg!(target_os = "linux") {
        runtime_linux_bridge_cmd(app)
    } else {
        None
    };
    // Motion remains owner-gated. A normal launch has no motion addition.
    // Only an exact value inherited by the Windows app process is forwarded
    // into WSL, and the bridge still independently requires its WSL latch.
    let windows_hw_motion = if cfg!(target_os = "windows") {
        std::env::var(HW_MOTION_ENV_VAR).ok()
    } else {
        None
    };
    let windows_wslenv = if cfg!(target_os = "windows") {
        std::env::var(WSLENV_ENV_VAR).ok()
    } else {
        None
    };
    let command = app
        .shell()
        .sidecar("scanstudio-engine")?
        .envs(engine_spawn_env(
            cfg!(target_os = "windows"),
            cfg!(target_os = "linux"),
            linux_bridge,
            windows_hw_motion.as_deref(),
            windows_wslenv.as_deref(),
        ));
    let (mut rx, child) = command.spawn()?;
    app.manage(EngineHandle {
        child: Mutex::new(Some(child)),
        next_id: AtomicU64::new(1),
        pending: Mutex::new(HashMap::new()),
    });
    let app_handle = app.handle().clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(line_bytes) => {
                    let line = String::from_utf8_lossy(&line_bytes).to_string();
                    let state = app_handle.state::<EngineHandle>();
                    let handle_for_emit = app_handle.clone();
                    dispatch_line(&line, &state.pending, &|payload| {
                        let _ = handle_for_emit.emit("engine://event", payload);
                    });
                }
                CommandEvent::Stderr(bytes) => {
                    eprintln!("[engine stderr] {}", String::from_utf8_lossy(&bytes));
                }
                CommandEvent::Error(err) => {
                    eprintln!("[engine error] {err}");
                }
                CommandEvent::Terminated(payload) => {
                    eprintln!("[engine terminated] {payload:?}");
                    let state = app_handle.state::<EngineHandle>();
                    fail_pending_requests(&state);
                }
                _ => {}
            }
        }
        // Channel closed (with or without a Terminated event) -- the engine
        // is gone either way.
        let state = app_handle.state::<EngineHandle>();
        fail_pending_requests(&state);
    });
    Ok(())
}

async fn send_request(
    state: &State<'_, EngineHandle>,
    method: &str,
    params: Value,
) -> Result<Value, EngineError> {
    let id = state.next_id.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = oneshot::channel();
    state.pending.lock().unwrap().insert(id, tx);
    let line = serde_json::json!({"id": id, "method": method, "params": params}).to_string() + "\n";
    {
        // Lock scope ends before the .await below -- never hold a std Mutex
        // guard across an await point.
        let mut child = state.child.lock().unwrap();
        let write_result = match child.as_mut() {
            Some(c) => c.write(line.as_bytes()).map_err(|e| e.to_string()),
            None => Err("engine process not running".to_string()),
        };
        if let Err(message) = write_result {
            drop(child);
            state.pending.lock().unwrap().remove(&id);
            return Err(EngineError {
                code: "INTERNAL".into(),
                message,
                recoverable: false,
            });
        }
    }
    match tokio::time::timeout(RESPONSE_TIMEOUT, rx).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err(EngineError {
            code: "INTERNAL".into(),
            message: "engine process terminated before responding".into(),
            recoverable: false,
        }),
        Err(_) => {
            state.pending.lock().unwrap().remove(&id);
            Err(EngineError {
                code: "INTERNAL".into(),
                message: "engine response timed out".into(),
                recoverable: false,
            })
        }
    }
}

#[tauri::command]
pub async fn engine_request(
    state: State<'_, EngineHandle>,
    method: String,
    params: Value,
) -> Result<Value, EngineError> {
    send_request(&state, &method, params).await
}

#[tauri::command]
pub fn engine_state(state: State<'_, EngineHandle>) -> Value {
    let child = state.child.lock().unwrap();
    let pid = child.as_ref().map(|c| c.pid()).unwrap_or(0);
    drop(child);
    serde_json::json!({"running": pid > 0, "pid": pid})
}

static SHUTDOWN_DONE: AtomicBool = AtomicBool::new(false);

pub fn handle_run_event(app_handle: &AppHandle<Wry>, event: &tauri::RunEvent) {
    if !matches!(
        event,
        tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit
    ) {
        return;
    }
    // Both ExitRequested and Exit can fire; run the shutdown path only once.
    if SHUTDOWN_DONE.swap(true, Ordering::SeqCst) {
        return;
    }
    let state = app_handle.state::<EngineHandle>();
    // Take the child first: if it is already None (engine died on its own)
    // there is nothing to stop, and engine_state stops reporting a stale PID.
    let taken = {
        let mut child = state.child.lock().unwrap();
        child.take()
    };
    let Some(mut child) = taken else {
        return;
    };
    let shutdown_line =
        serde_json::json!({"id": 0, "method": "engine.shutdown", "params": {}}).to_string() + "\n";
    let _ = child.write(shutdown_line.as_bytes());
    // Graceful wait-then-kill, once.
    std::thread::sleep(Duration::from_secs(2));
    let _ = child.kill();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn production_engine_spawn_is_unarmed_by_default_on_windows() {
        assert_eq!(
            engine_spawn_env(
                true,
                false,
                Some("ignored-linux-helper".to_string()),
                None,
                None,
            ),
            vec![(
                "SCANSTUDIO_BRIDGE_CMD".to_string(),
                "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge".to_string(),
            )]
        );
    }

    #[test]
    fn production_engine_spawn_forwards_owner_armed_windows_process_to_wsl() {
        assert_eq!(
            engine_spawn_env(
                true,
                false,
                Some("ignored-linux-helper".to_string()),
                Some("1"),
                Some("RUST_LOG/u"),
            ),
            vec![
                (
                    "SCANSTUDIO_BRIDGE_CMD".to_string(),
                    "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge".to_string(),
                ),
                ("SCANSTUDIO_HW_MOTION".to_string(), "1".to_string()),
                (
                    "WSLENV".to_string(),
                    "RUST_LOG/u:SCANSTUDIO_HW_MOTION/u".to_string(),
                ),
            ]
        );
    }

    #[test]
    fn production_engine_spawn_does_not_forward_non_exact_motion_value() {
        assert_eq!(
            engine_spawn_env(true, false, None, Some("true"), Some("OTHER/u")),
            vec![(
                "SCANSTUDIO_BRIDGE_CMD".to_string(),
                "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge".to_string(),
            )]
        );
    }

    #[test]
    fn production_engine_spawn_selects_resolved_bridge_on_linux() {
        assert_eq!(
            engine_spawn_env(
                false,
                true,
                Some("/app/scanstudio-bridge".to_string()),
                None,
                None,
            ),
            vec![(
                "SCANSTUDIO_BRIDGE_CMD".to_string(),
                "/app/scanstudio-bridge".to_string(),
            )]
        );
    }

    #[test]
    fn production_engine_spawn_does_not_override_bridge_command_on_macos() {
        assert!(engine_spawn_env(false, false, None, None, None).is_empty());
    }

    #[test]
    fn linux_bridge_resolution_uses_env_config_bundle_path_order() {
        assert_eq!(
            resolve_linux_bridge_cmd(
                Some("custom --flag"),
                Some("configured"),
                Some("/bundle/scanstudio-bridge"),
                Some("/usr/bin/scanstudio-bridge"),
            ),
            Some("custom --flag".to_string())
        );
        assert_eq!(
            resolve_linux_bridge_cmd(
                Some("  "),
                Some("configured\nignored second line"),
                Some("/bundle/scanstudio-bridge"),
                Some("/usr/bin/scanstudio-bridge"),
            ),
            Some("configured".to_string())
        );
        assert_eq!(
            resolve_linux_bridge_cmd(None, None, Some("/bundle/scanstudio-bridge"), Some("path")),
            Some("/bundle/scanstudio-bridge".to_string())
        );
        assert_eq!(
            resolve_linux_bridge_cmd(None, None, None, Some("/usr/bin/scanstudio-bridge")),
            Some("/usr/bin/scanstudio-bridge".to_string())
        );
        assert_eq!(resolve_linux_bridge_cmd(None, None, None, None), None);
    }

    #[test]
    fn result_line_resolves_pending_sender() {
        let pending: PendingMap = Mutex::new(HashMap::new());
        let (tx, mut rx) = oneshot::channel();
        pending.lock().unwrap().insert(1, tx);
        dispatch_line(r#"{"id":1,"result":{"ok":true}}"#, &pending, &|_| {
            panic!("no event expected")
        });
        let outcome = rx.try_recv().expect("pending sender should be resolved");
        assert_eq!(outcome.unwrap(), serde_json::json!({"ok": true}));
        assert!(pending.lock().unwrap().is_empty());
    }

    #[test]
    fn error_line_resolves_pending_sender_with_typed_error() {
        let pending: PendingMap = Mutex::new(HashMap::new());
        let (tx, mut rx) = oneshot::channel();
        pending.lock().unwrap().insert(2, tx);
        dispatch_line(
            r#"{"id":2,"error":{"code":"NOT_CONNECTED","message":"x","recoverable":false}}"#,
            &pending,
            &|_| panic!("no event expected"),
        );
        let err = rx
            .try_recv()
            .expect("pending sender should be resolved")
            .unwrap_err();
        assert_eq!(
            err,
            EngineError {
                code: "NOT_CONNECTED".into(),
                message: "x".into(),
                recoverable: false
            }
        );
    }

    #[test]
    fn event_line_calls_on_event_once_and_leaves_pending_untouched() {
        let pending: PendingMap = Mutex::new(HashMap::new());
        let (tx, _rx) = oneshot::channel();
        pending.lock().unwrap().insert(7, tx);
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let calls_for_closure = calls.clone();
        dispatch_line(
            r#"{"event":"scanner.status","payload":{"connected":true}}"#,
            &pending,
            &|payload| {
                calls_for_closure.fetch_add(1, Ordering::SeqCst);
                assert_eq!(payload["event"], "scanner.status");
                assert_eq!(payload["payload"]["connected"], true);
            },
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(pending.lock().unwrap().contains_key(&7));
    }

    #[test]
    fn malformed_line_is_ignored_without_panic() {
        let pending: PendingMap = Mutex::new(HashMap::new());
        dispatch_line("this is not json", &pending, &|_| {
            panic!("no event expected")
        });
        assert!(pending.lock().unwrap().is_empty());
    }

    #[test]
    fn fail_pending_requests_clears_child_and_errors_waiters() {
        let handle = EngineHandle {
            child: Mutex::new(None),
            next_id: AtomicU64::new(1),
            pending: Mutex::new(HashMap::new()),
        };
        let (tx, mut rx) = oneshot::channel();
        handle.pending.lock().unwrap().insert(5, tx);

        fail_pending_requests(&handle);

        let err = rx
            .try_recv()
            .expect("waiter should be resolved")
            .unwrap_err();
        assert_eq!(err.code, "INTERNAL");
        assert_eq!(err.message, "engine process terminated");
        assert!(!err.recoverable);
        assert!(handle.pending.lock().unwrap().is_empty());
        assert!(handle.child.lock().unwrap().is_none());

        // Idempotent: a second pass (e.g. loop end after Terminated) is a no-op.
        fail_pending_requests(&handle);
        assert!(handle.pending.lock().unwrap().is_empty());
    }

    #[test]
    fn response_with_unknown_id_is_a_noop() {
        let pending: PendingMap = Mutex::new(HashMap::new());
        dispatch_line(r#"{"id":99,"result":{"ok":true}}"#, &pending, &|_| {
            panic!("no event expected")
        });
        assert!(pending.lock().unwrap().is_empty());
    }
}
