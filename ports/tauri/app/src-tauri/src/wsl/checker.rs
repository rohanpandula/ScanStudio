/// Read-only WSL2 / bridge / usbipd / WebView2 setup probes (CONTEXT decision
/// 3, WSL-03).
///
/// Every probe's only side effect is reading output from a local tool via the
/// injected [`CommandExecutor`]. Nothing here ever installs, elevates, or
/// attaches hardware; `fix_command` is copy-paste text displayed to the
/// operator, never executed by this module. On non-Windows hosts every probe
/// returns the honest `Unknown` / "windows only" state so the whole parser is
/// unit-testable on macOS with canned executor outputs.
use serde::Serialize;

use super::bridge_cmd::WSL_DISTRO;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum ProbeStatus {
    Ok,
    Fail,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeResult {
    pub id: &'static str,
    pub status: ProbeStatus,
    pub detail: String,
    pub fix_command: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CommandOutput {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
}

/// Abstraction over spawning a program, so probe parsers are testable with
/// canned outputs. The production impl shells out; tests inject fakes.
pub trait CommandExecutor {
    fn run(&self, program: &str, args: &[&str]) -> CommandOutput;
}

/// The production executor. Writing this as ordinary Rust code is fine — it
/// is simply never invoked by any test or verification step on this host.
pub struct RealCommandExecutor;

impl CommandExecutor for RealCommandExecutor {
    fn run(&self, program: &str, args: &[&str]) -> CommandOutput {
        match std::process::Command::new(program).args(args).output() {
            Ok(output) => CommandOutput {
                success: output.status.success(),
                stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            },
            Err(e) => CommandOutput {
                success: false,
                stdout: String::new(),
                stderr: e.to_string(),
            },
        }
    }
}

pub const PROBE_IDS: [&str; 5] = [
    "wsl_status",
    "bridge_which",
    "bridge_version",
    "usbipd_attach",
    "webview2",
];

pub fn run_all_probes(
    executor: &dyn CommandExecutor,
    is_windows: bool,
    entrypoint: &str,
) -> Vec<ProbeResult> {
    vec![
        probe_wsl_status(executor, is_windows),
        probe_bridge_which(executor, is_windows, entrypoint),
        probe_bridge_version(executor, is_windows, entrypoint),
        probe_usbipd_attach(executor, is_windows),
        probe_webview2(executor, is_windows),
    ]
}

/// The ONLY place `Unknown` is produced: a non-Windows host cannot run these
/// probes, and the honest answer is "this check does not apply here".
fn windows_only(id: &'static str) -> ProbeResult {
    ProbeResult {
        id,
        status: ProbeStatus::Unknown,
        detail: "windows only".to_string(),
        fix_command: None,
    }
}

fn probe_wsl_status(executor: &dyn CommandExecutor, is_windows: bool) -> ProbeResult {
    if !is_windows {
        return windows_only("wsl-status");
    }
    let out = executor.run("wsl.exe", &["--status"]);
    let fix = Some("wsl --install -d Ubuntu-24.04".to_string());
    if !out.success {
        return ProbeResult {
            id: "wsl-status",
            status: ProbeStatus::Fail,
            detail: "wsl.exe --status failed to run".to_string(),
            fix_command: fix,
        };
    }
    let default_version_ok = out
        .stdout
        .lines()
        .any(|line| line.trim_start().starts_with("Default Version:") && line.contains('2'));
    let distro_ok = out.stdout.to_lowercase().contains("ubuntu-24.04");
    if default_version_ok && distro_ok {
        return ProbeResult {
            id: "wsl-status",
            status: ProbeStatus::Ok,
            detail: "WSL2 with Ubuntu-24.04 default".to_string(),
            fix_command: None,
        };
    }
    ProbeResult {
        id: "wsl-status",
        status: ProbeStatus::Fail,
        detail: format!(
            "wsl --status did not report WSL2 + Ubuntu-24.04: {}",
            out.stdout.trim()
        ),
        fix_command: fix,
    }
}

fn probe_bridge_which(
    executor: &dyn CommandExecutor,
    is_windows: bool,
    entrypoint: &str,
) -> ProbeResult {
    if !is_windows {
        return windows_only("bridge-which");
    }
    let out = executor.run(
        "wsl.exe",
        &["-d", WSL_DISTRO, "-e", "which", entrypoint],
    );
    if out.success && !out.stdout.trim().is_empty() {
        return ProbeResult {
            id: "bridge-which",
            status: ProbeStatus::Ok,
            detail: format!("found at {}", out.stdout.trim()),
            fix_command: None,
        };
    }
    ProbeResult {
        id: "bridge-which",
        status: ProbeStatus::Fail,
        detail: "scanstudio-bridge not found on PATH inside WSL".to_string(),
        fix_command: Some(
            "Run install-bridge-wsl.sh inside your WSL Ubuntu-24.04 distro (see runbooks/WINDOWS-WSL-LANE.md)"
                .to_string(),
        ),
    }
}

fn probe_bridge_version(
    executor: &dyn CommandExecutor,
    is_windows: bool,
    entrypoint: &str,
) -> ProbeResult {
    if !is_windows {
        return windows_only("bridge-version");
    }
    // The bridge CLI parses no args and would otherwise block reading stdin
    // forever; stdin is explicitly closed from /dev/null so a real probe
    // exits immediately. Pure data here — this string is never run by tests
    // (they fake the executor) and never by this module (fix_command style).
    let sh_cmd = format!("{entrypoint} --version < /dev/null");
    let out = executor.run(
        "wsl.exe",
        &["-d", WSL_DISTRO, "-e", "sh", "-c", &sh_cmd],
    );
    if out.success {
        return ProbeResult {
            id: "bridge-version",
            status: ProbeStatus::Ok,
            detail: "bridge entrypoint launches and exits cleanly".to_string(),
            fix_command: None,
        };
    }
    ProbeResult {
        id: "bridge-version",
        status: ProbeStatus::Fail,
        detail: format!("bridge entrypoint exited non-zero: {}", out.stderr.trim()),
        fix_command: Some(
            "Re-run install-bridge-wsl.sh --force and check its output for missing system libraries (sane-utils, libusb-1.0-0)"
                .to_string(),
        ),
    }
}

fn probe_usbipd_attach(executor: &dyn CommandExecutor, is_windows: bool) -> ProbeResult {
    if !is_windows {
        return windows_only("usbipd-attach");
    }
    let out = executor.run("usbipd", &["list"]);
    if !out.success {
        return ProbeResult {
            id: "usbipd-attach",
            status: ProbeStatus::Fail,
            detail: "usbipd list failed \u{2014} usbipd-win may not be installed".to_string(),
            fix_command: Some("winget install --interactive --exact dorssel.usbipd-win".to_string()),
        };
    }
    let line = out
        .stdout
        .lines()
        .find(|line| line.to_lowercase().contains("04b0:4002"));
    let Some(line) = line else {
        return ProbeResult {
            id: "usbipd-attach",
            status: ProbeStatus::Fail,
            detail: "LS-5000 (04b0:4002) not found in usbipd list output".to_string(),
            fix_command: Some(
                "usbipd bind --busid <busid> (find <busid> via `usbipd list`), then usbipd attach --wsl --busid <busid> --distribution Ubuntu-24.04"
                    .to_string(),
            ),
        };
    };
    if !line.to_lowercase().contains("attach") {
        return ProbeResult {
            id: "usbipd-attach",
            status: ProbeStatus::Fail,
            detail: "LS-5000 visible to usbipd but not attached to WSL".to_string(),
            fix_command: Some(
                "usbipd attach --wsl --busid <busid> --distribution Ubuntu-24.04".to_string(),
            ),
        };
    }
    ProbeResult {
        id: "usbipd-attach",
        status: ProbeStatus::Ok,
        detail: "LS-5000 attached to WSL".to_string(),
        fix_command: None,
    }
}

/// Parse a `reg query` `pv` value: first line containing both `pv` and
/// `REG_SZ`; the version is its last whitespace-separated token.
fn parse_webview2_version(stdout: &str) -> Option<String> {
    let line = stdout
        .lines()
        .find(|line| line.contains("pv") && line.contains("REG_SZ"))?;
    let version = line.split_ascii_whitespace().last()?.to_string();
    Some(version)
}

fn probe_webview2(executor: &dyn CommandExecutor, is_windows: bool) -> ProbeResult {
    if !is_windows {
        return windows_only("webview2");
    }
    const HKLM: &str = "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
    const HKCU: &str = "HKCU\\Software\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";

    let hklm_out = executor.run("reg", &["query", HKLM, "/v", "pv"]);
    if let Some(version) = parse_webview2_version(&hklm_out.stdout) {
        if !version.is_empty() && version != "0.0.0.0" {
            return ProbeResult {
                id: "webview2",
                status: ProbeStatus::Ok,
                detail: format!("WebView2 runtime {version} (per-machine)"),
                fix_command: None,
            };
        }
    }

    let hkcu_out = executor.run("reg", &["query", HKCU, "/v", "pv"]);
    if let Some(version) = parse_webview2_version(&hkcu_out.stdout) {
        if !version.is_empty() && version != "0.0.0.0" {
            return ProbeResult {
                id: "webview2",
                status: ProbeStatus::Ok,
                detail: format!("WebView2 runtime {version} (per-user)"),
                fix_command: None,
            };
        }
    }

    ProbeResult {
        id: "webview2",
        status: ProbeStatus::Fail,
        detail: "WebView2 Runtime not detected in HKLM or HKCU".to_string(),
        fix_command: Some(
            "Install the WebView2 Runtime: https://developer.microsoft.com/microsoft-edge/webview2/consumer/"
                .to_string(),
        ),
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MaxReadReport {
    pub max_bytes: Option<u64>,
    pub entries_scanned: usize,
}

/// Scan bridge telemetry (`scan.call` / `exit` JSONL entries) for the largest
/// single bulk-transfer read size seen so far. Malformed lines are skipped
/// (never panics); lines that do not match `method == scan.call` +
/// `outcome == exit` are ignored; `entries_scanned` counts every matching
/// entry whether or not it carried a `bytes` field.
pub fn max_single_read_from_telemetry(jsonl_lines: &[String]) -> MaxReadReport {
    let mut max_bytes: Option<u64> = None;
    let mut entries_scanned: usize = 0;
    for line in jsonl_lines {
        let value: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let is_scan_call = value.get("method").and_then(|m| m.as_str()) == Some("scan.call");
        let is_exit = value.get("outcome").and_then(|o| o.as_str()) == Some("exit");
        if !is_scan_call || !is_exit {
            continue;
        }
        entries_scanned += 1;
        if let Some(bytes) = value.get("bytes").and_then(|b| b.as_u64()) {
            max_bytes = Some(match max_bytes {
                Some(current) if current >= bytes => current,
                _ => bytes,
            });
        }
    }
    MaxReadReport {
        max_bytes,
        entries_scanned,
    }
}

pub fn describe_max_read(report: &MaxReadReport) -> String {
    match report.max_bytes {
        Some(b) => format!(
            "max single read observed: {b} bytes across {} scan.call entries",
            report.entries_scanned
        ),
        None => format!(
            "no size data recorded in {} scan.call entries (bridge telemetry does not yet emit a byte-size field on scan.call exit entries)",
            report.entries_scanned
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct FakeExecutor {
        map: HashMap<(String, Vec<String>), CommandOutput>,
        calls: Mutex<Vec<(String, Vec<String>)>>,
    }

    impl FakeExecutor {
        fn new(map: HashMap<(String, Vec<String>), CommandOutput>) -> Self {
            FakeExecutor {
                map,
                calls: Mutex::new(Vec::new()),
            }
        }

        fn called_args(&self) -> Vec<(String, Vec<String>)> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl CommandExecutor for FakeExecutor {
        fn run(&self, program: &str, args: &[&str]) -> CommandOutput {
            let key = (
                program.to_string(),
                args.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            );
            self.calls.lock().unwrap().push(key.clone());
            self.map.get(&key).cloned().unwrap_or_else(|| CommandOutput {
                success: false,
                stdout: String::new(),
                stderr: format!("no fixture for {program:?} {args:?}"),
            })
        }
    }

    fn key(program: &str, args: &[&str]) -> (String, Vec<String>) {
        (
            program.to_string(),
            args.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        )
    }

    fn success_out(stdout: &str) -> CommandOutput {
        CommandOutput {
            success: true,
            stdout: stdout.to_string(),
            stderr: String::new(),
        }
    }

    #[test]
    fn every_probe_is_unknown_windows_only_on_non_windows() {
        let fake = FakeExecutor::new(HashMap::new());
        let results = run_all_probes(&fake, false, super::super::bridge_cmd::BRIDGE_ENTRYPOINT);
        assert_eq!(results.len(), 5);
        for r in &results {
            assert_eq!(r.status, ProbeStatus::Unknown);
            assert_eq!(r.detail, "windows only");
        }
    }

    #[test]
    fn wsl_status_ok_fail_and_spawn_failure_paths() {
        let ok_map = HashMap::from([(
            key("wsl.exe", &["--status"]),
            success_out("Default Version: 2\nDefault Distribution: Ubuntu-24.04\nUbuntu-24.04 (Default)"),
        )]);
        let ok = probe_wsl_status(&FakeExecutor::new(ok_map), true);
        assert_eq!(ok.status, ProbeStatus::Ok);
        assert_eq!(ok.detail, "WSL2 with Ubuntu-24.04 default");

        let missing_distro = HashMap::from([(
            key("wsl.exe", &["--status"]),
            success_out("Default Version: 2\nDefault Distribution: Debian"),
        )]);
        let no_distro = probe_wsl_status(&FakeExecutor::new(missing_distro), true);
        assert_eq!(no_distro.status, ProbeStatus::Fail);

        let spawn_fail = HashMap::from([(
            key("wsl.exe", &["--status"]),
            CommandOutput {
                success: false,
                stdout: String::new(),
                stderr: "wsl.exe not found".to_string(),
            },
        )]);
        let spawn = probe_wsl_status(&FakeExecutor::new(spawn_fail), true);
        assert_eq!(spawn.status, ProbeStatus::Fail);
        assert_eq!(
            spawn.fix_command,
            Some("wsl --install -d Ubuntu-24.04".to_string())
        );
    }

    #[test]
    fn bridge_which_paths() {
        const EP: &str = super::super::bridge_cmd::BRIDGE_ENTRYPOINT;

        let found = HashMap::from([(
            key(
                "wsl.exe",
                &["-d", WSL_DISTRO, "-e", "which", EP],
            ),
            success_out("/home/wsl-user/.venvs/scanstudio/bin/scanstudio-bridge\n"),
        )]);
        let ok = probe_bridge_which(&FakeExecutor::new(found), true, EP);
        assert_eq!(ok.status, ProbeStatus::Ok);
        assert!(
            ok.detail
                .ends_with("/home/wsl-user/.venvs/scanstudio/bin/scanstudio-bridge")
        );

        let empty_stdout = HashMap::from([(
            key(
                "wsl.exe",
                &["-d", WSL_DISTRO, "-e", "which", EP],
            ),
            success_out(""),
        )]);
        let empty = probe_bridge_which(&FakeExecutor::new(empty_stdout), true, EP);
        assert_eq!(empty.status, ProbeStatus::Fail);

        let spawn_fail = HashMap::from([(
            key(
                "wsl.exe",
                &["-d", WSL_DISTRO, "-e", "which", EP],
            ),
            CommandOutput {
                success: false,
                stdout: String::new(),
                stderr: "no such entrypoint".to_string(),
            },
        )]);
        let fail = probe_bridge_which(&FakeExecutor::new(spawn_fail), true, EP);
        assert_eq!(fail.status, ProbeStatus::Fail);
    }

    #[test]
    fn bridge_version_paths_and_exact_constructed_args() {
        const EP: &str = super::super::bridge_cmd::BRIDGE_ENTRYPOINT;
        let sh_cmd = format!("{EP} --version < /dev/null");

        let ok_map = HashMap::from([(
            key(
                "wsl.exe",
                &["-d", WSL_DISTRO, "-e", "sh", "-c", &sh_cmd],
            ),
            success_out("scanstudio-bridge 0.1.0\n"),
        )]);
        let fake = FakeExecutor::new(ok_map);
        let ok = probe_bridge_version(&fake, true, EP);
        assert_eq!(ok.status, ProbeStatus::Ok);
        assert_eq!(
            fake.called_args(),
            vec![(
                "wsl.exe".to_string(),
                vec![
                    "-d".to_string(),
                    "Ubuntu-24.04".to_string(),
                    "-e".to_string(),
                    "sh".to_string(),
                    "-c".to_string(),
                    sh_cmd.clone(),
                ]
            )]
        );

        let fail_map = HashMap::from([(
            key(
                "wsl.exe",
                &["-d", WSL_DISTRO, "-e", "sh", "-c", &sh_cmd],
            ),
            CommandOutput {
                success: false,
                stdout: String::new(),
                stderr: "libsane missing".to_string(),
            },
        )]);
        let fail = probe_bridge_version(&FakeExecutor::new(fail_map), true, EP);
        assert_eq!(fail.status, ProbeStatus::Fail);
        assert!(fail.detail.contains("libsane missing"));
    }

    #[test]
    fn usbipd_attach_all_four_paths() {
        let attached = HashMap::from([(
            key("usbipd", &["list"]),
            success_out("BUSID  VID:PID  DEVICE            STATE\n1-2    04b0:4002  Nikon LS-5000  Attached\n"),
        )]);
        let ok = probe_usbipd_attach(&FakeExecutor::new(attached), true);
        assert_eq!(ok.status, ProbeStatus::Ok);
        assert_eq!(ok.detail, "LS-5000 attached to WSL");

        let not_attached = HashMap::from([(
            key("usbipd", &["list"]),
            success_out("BUSID  VID:PID  DEVICE            STATE\n1-2    04b0:4002  Nikon LS-5000  Shared\n"),
        )]);
        let na = probe_usbipd_attach(&FakeExecutor::new(not_attached), true);
        assert_eq!(na.status, ProbeStatus::Fail);
        assert_eq!(na.detail, "LS-5000 visible to usbipd but not attached to WSL");

        let not_found = HashMap::from([(
            key("usbipd", &["list"]),
            success_out("BUSID  VID:PID  DEVICE\n1-3    1234:5678  Something else\n"),
        )]);
        let nf = probe_usbipd_attach(&FakeExecutor::new(not_found), true);
        assert_eq!(nf.status, ProbeStatus::Fail);
        assert_eq!(nf.detail, "LS-5000 (04b0:4002) not found in usbipd list output");

        let spawn_fail = HashMap::from([(
            key("usbipd", &["list"]),
            CommandOutput {
                success: false,
                stdout: String::new(),
                stderr: "usbipd: command not found".to_string(),
            },
        )]);
        let sf = probe_usbipd_attach(&FakeExecutor::new(spawn_fail), true);
        assert_eq!(sf.status, ProbeStatus::Fail);
        assert_eq!(sf.detail, "usbipd list failed — usbipd-win may not be installed");
    }

    #[test]
    fn webview2_hklm_hkcu_and_neither_paths() {
        const HKLM: &str = "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        const HKCU: &str = "HKCU\\Software\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        let pv_line = "    pv    REG_SZ    120.0.6099.109\n";

        let hklm_map = HashMap::from([(
            key("reg", &["query", HKLM, "/v", "pv"]),
            success_out(pv_line),
        )]);
        let hklm = probe_webview2(&FakeExecutor::new(hklm_map), true);
        assert_eq!(hklm.status, ProbeStatus::Ok);
        assert_eq!(hklm.detail, "WebView2 runtime 120.0.6099.109 (per-machine)");

        let hkcu_map = HashMap::from([
            (
                key("reg", &["query", HKLM, "/v", "pv"]),
                CommandOutput {
                    success: false,
                    stdout: String::new(),
                    stderr: "ERROR: The system was unable to find the specified registry key or value.".to_string(),
                },
            ),
            (
                key("reg", &["query", HKCU, "/v", "pv"]),
                success_out(pv_line),
            ),
        ]);
        let hkcu = probe_webview2(&FakeExecutor::new(hkcu_map), true);
        assert_eq!(hkcu.status, ProbeStatus::Ok);
        assert_eq!(hkcu.detail, "WebView2 runtime 120.0.6099.109 (per-user)");

        let neither_map = HashMap::from([
            (
                key("reg", &["query", HKLM, "/v", "pv"]),
                CommandOutput {
                    success: false,
                    stdout: String::new(),
                    stderr: "not found".to_string(),
                },
            ),
            (
                key("reg", &["query", HKCU, "/v", "pv"]),
                CommandOutput {
                    success: false,
                    stdout: String::new(),
                    stderr: "not found".to_string(),
                },
            ),
        ]);
        let neither = probe_webview2(&FakeExecutor::new(neither_map), true);
        assert_eq!(neither.status, ProbeStatus::Fail);
        assert_eq!(neither.detail, "WebView2 Runtime not detected in HKLM or HKCU");
    }

    #[test]
    fn run_all_probes_returns_probe_ids_in_order() {
        let fake = FakeExecutor::new(HashMap::new());
        let results = run_all_probes(&fake, true, super::super::bridge_cmd::BRIDGE_ENTRYPOINT);
        let ids: Vec<&str> = results.iter().map(|r| r.id).collect();
        assert_eq!(
            ids,
            vec!["wsl-status", "bridge-which", "bridge-version", "usbipd-attach", "webview2"]
        );
    }

    #[test]
    fn max_single_read_from_telemetry_all_input_shapes() {
        assert_eq!(
            max_single_read_from_telemetry(&[]),
            MaxReadReport {
                max_bytes: None,
                entries_scanned: 0
            }
        );

        let three_no_bytes: Vec<String> = (0..3)
            .map(|i| {
                format!(r#"{{"method":"scan.call","outcome":"exit","frame":{i}}}"#)
            })
            .collect();
        assert_eq!(
            max_single_read_from_telemetry(&three_no_bytes),
            MaxReadReport {
                max_bytes: None,
                entries_scanned: 3
            }
        );

        let mut four = three_no_bytes.clone();
        four.push(r#"{"method":"scan.call","outcome":"exit","bytes":5242880}"#.to_string());
        assert_eq!(
            max_single_read_from_telemetry(&four),
            MaxReadReport {
                max_bytes: Some(5242880),
                entries_scanned: 4
            }
        );

        let mixed = vec![
            r#"{"method":"scan.call","outcome":"exit"}"#.to_string(),
            "this is not json at all".to_string(),
            r#"{"method":"scan.call"}"#.to_string(),
            r#"{"method":"scan.call","outcome":"exit","bytes":4096}"#.to_string(),
        ];
        let parsed = max_single_read_from_telemetry(&mixed);
        assert_eq!(parsed.entries_scanned, 2);
        assert_eq!(parsed.max_bytes, Some(4096));
    }

    #[test]
    fn describe_max_read_exact_message_shapes() {
        let none = MaxReadReport {
            max_bytes: None,
            entries_scanned: 3,
        };
        assert_eq!(
            describe_max_read(&none),
            "no size data recorded in 3 scan.call entries (bridge telemetry does not yet emit a byte-size field on scan.call exit entries)"
        );

        let some = MaxReadReport {
            max_bytes: Some(5242880),
            entries_scanned: 4,
        };
        assert_eq!(
            describe_max_read(&some),
            "max single read observed: 5242880 bytes across 4 scan.call entries"
        );
    }
}
