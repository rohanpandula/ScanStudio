/// WSL lane bridge spawn wiring (CONTEXT decision 2, WSL-02).
///
/// On Windows the app hands the engine the bridge launcher via the
/// `SCANSTUDIO_BRIDGE_CMD` environment variable. The exact command string we
/// build here — `wsl.exe -d Ubuntu-24.04 -e <entrypoint>` — is deliberately the composite
/// form the engine's existing `split_command` whitespace resolution already
/// handles (`real_backend.rs:103-111`): the whole string is never a literal
/// file path. The distribution is explicit because the native engine maps
/// completed WSL paths through this same pinned distribution's UNC share; a
/// user's unrelated default distribution must never redirect the bridge.
/// This module only builds strings and env vectors; it never spawns anything.
pub const BRIDGE_ENTRYPOINT: &str = "scanstudio-bridge";
pub const BRIDGE_CMD_ENV_VAR: &str = "SCANSTUDIO_BRIDGE_CMD";
pub const HW_MOTION_ENV_VAR: &str = "SCANSTUDIO_HW_MOTION";
pub const WSLENV_ENV_VAR: &str = "WSLENV";
pub const WSL_DISTRO: &str = "Ubuntu-24.04";

const HW_MOTION_ARMED_VALUE: &str = "1";
const HW_MOTION_WSLENV_ENTRY: &str = "SCANSTUDIO_HW_MOTION/u";

pub fn build_wsl_bridge_cmd(entrypoint: &str) -> String {
    format!("wsl.exe -d {WSL_DISTRO} -e {entrypoint}")
}

/// Assemble the environment the engine sees when it spawns the bridge.
///
/// Every ordinary pair in `base_env` is copied forward. Security-sensitive
/// bridge/motion keys are rebuilt here so a stale caller-supplied value can
/// never arm motion or produce a duplicate key.
///
/// `SCANSTUDIO_HW_MOTION` is forwarded only when the Windows ScanStudio
/// process already has the exact armed value `1`. In that case `WSLENV` gets
/// the `/u` entry that makes WSL forward the variable from Win32 into the
/// launched Ubuntu process. This does not create the independent WSL latch;
/// the bridge still checks both conditions on every motion request.
pub fn build_engine_env(
    base_env: &[(String, String)],
    entrypoint: &str,
    process_hw_motion: Option<&str>,
    process_wslenv: Option<&str>,
) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = base_env
        .iter()
        .filter(|(key, _)| {
            !key.eq_ignore_ascii_case(BRIDGE_CMD_ENV_VAR)
                && !key.eq_ignore_ascii_case(HW_MOTION_ENV_VAR)
                && !key.eq_ignore_ascii_case(WSLENV_ENV_VAR)
        })
        .cloned()
        .collect();
    env.push((
        BRIDGE_CMD_ENV_VAR.to_string(),
        build_wsl_bridge_cmd(entrypoint),
    ));

    if let Some(value) = process_hw_motion.filter(|value| *value == HW_MOTION_ARMED_VALUE) {
        env.push((HW_MOTION_ENV_VAR.to_string(), value.to_string()));
        env.push((
            WSLENV_ENV_VAR.to_string(),
            wslenv_with_hw_motion(process_wslenv),
        ));
    }

    env
}

fn wslenv_with_hw_motion(existing: Option<&str>) -> String {
    let mut entries: Vec<&str> = existing
        .into_iter()
        .flat_map(|value| value.split(':'))
        .filter(|entry| !entry.is_empty())
        .filter(|entry| {
            !entry
                .split_once('/')
                .map(|(name, _)| name)
                .unwrap_or(entry)
                .eq_ignore_ascii_case(HW_MOTION_ENV_VAR)
        })
        .collect();
    entries.push(HW_MOTION_WSLENV_ENTRY);
    entries.join(":")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_entrypoint_builds_exact_wsl_command() {
        assert_eq!(
            build_wsl_bridge_cmd(BRIDGE_ENTRYPOINT),
            "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge"
        );
    }

    #[test]
    fn constructed_cmd_is_whitespace_split_compatible() {
        let cmd = build_wsl_bridge_cmd(BRIDGE_ENTRYPOINT);
        assert!(
            !std::path::Path::new(&cmd).exists(),
            "a composite `wsl.exe -e ...` string must never be taken for a literal program path"
        );
        assert_eq!(
            cmd.split_ascii_whitespace().collect::<Vec<_>>(),
            vec!["wsl.exe", "-d", "Ubuntu-24.04", "-e", "scanstudio-bridge"]
        );
    }

    #[test]
    fn empty_base_env_gets_exactly_the_bridge_pair() {
        assert_eq!(
            build_engine_env(&[], BRIDGE_ENTRYPOINT, None, None),
            vec![(
                BRIDGE_CMD_ENV_VAR.to_string(),
                "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge".to_string()
            )]
        );
    }

    #[test]
    fn unrelated_base_env_pair_is_preserved() {
        let base = vec![("RUST_LOG".to_string(), "info".to_string())];
        let env = build_engine_env(&base, BRIDGE_ENTRYPOINT, None, None);
        assert_eq!(
            env,
            vec![
                ("RUST_LOG".to_string(), "info".to_string()),
                (
                    BRIDGE_CMD_ENV_VAR.to_string(),
                    "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge".to_string()
                )
            ]
        );
    }

    #[test]
    fn stale_bridge_cmd_entry_is_replaced_not_duplicated() {
        let base = vec![("SCANSTUDIO_BRIDGE_CMD".to_string(), "old-value".to_string())];
        let env = build_engine_env(&base, BRIDGE_ENTRYPOINT, None, None);
        let bridge_entries: Vec<_> = env
            .iter()
            .filter(|(k, _)| k == BRIDGE_CMD_ENV_VAR)
            .collect();
        assert_eq!(bridge_entries.len(), 1);
        assert_eq!(
            bridge_entries[0].1,
            "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge"
        );
        assert_ne!(bridge_entries[0].1, "old-value");
    }

    #[test]
    fn unarmed_process_does_not_add_motion_or_wslenv() {
        for value in [None, Some(""), Some("0"), Some("true"), Some(" 1 ")] {
            let env = build_engine_env(&[], BRIDGE_ENTRYPOINT, value, Some("RUST_LOG/u:OTHER/p"));
            assert_eq!(env.len(), 1, "unexpected additions for {value:?}");
            assert!(env.iter().all(|(key, _)| key != HW_MOTION_ENV_VAR));
            assert!(env.iter().all(|(key, _)| key != WSLENV_ENV_VAR));
        }
    }

    #[test]
    fn stale_sensitive_base_entries_cannot_arm_an_unarmed_process() {
        let env = build_engine_env(
            &[
                (HW_MOTION_ENV_VAR.to_string(), "1".to_string()),
                (
                    WSLENV_ENV_VAR.to_string(),
                    "SCANSTUDIO_HW_MOTION/u".to_string(),
                ),
            ],
            BRIDGE_ENTRYPOINT,
            None,
            None,
        );
        assert_eq!(
            env,
            vec![(
                BRIDGE_CMD_ENV_VAR.to_string(),
                "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge".to_string(),
            )]
        );
    }

    #[test]
    fn armed_process_adds_process_scoped_motion_and_wslenv_forwarding() {
        assert_eq!(
            build_engine_env(
                &[],
                BRIDGE_ENTRYPOINT,
                Some("1"),
                Some("RUST_LOG/u:OTHER/p"),
            ),
            vec![
                (
                    BRIDGE_CMD_ENV_VAR.to_string(),
                    "wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge".to_string(),
                ),
                (HW_MOTION_ENV_VAR.to_string(), "1".to_string()),
                (
                    WSLENV_ENV_VAR.to_string(),
                    "RUST_LOG/u:OTHER/p:SCANSTUDIO_HW_MOTION/u".to_string(),
                ),
            ]
        );
    }

    #[test]
    fn armed_process_replaces_existing_motion_wslenv_entry_once() {
        let env = build_engine_env(
            &[
                (HW_MOTION_ENV_VAR.to_string(), "stale".to_string()),
                (WSLENV_ENV_VAR.to_string(), "stale".to_string()),
            ],
            BRIDGE_ENTRYPOINT,
            Some("1"),
            Some("PATH/l:scanstudio_hw_motion/p:OTHER/u"),
        );
        assert_eq!(
            env.iter()
                .find(|(key, _)| key == WSLENV_ENV_VAR)
                .map(|(_, value)| value.as_str()),
            Some("PATH/l:OTHER/u:SCANSTUDIO_HW_MOTION/u")
        );
        assert_eq!(
            env.iter()
                .filter(|(key, _)| key.eq_ignore_ascii_case(HW_MOTION_ENV_VAR))
                .count(),
            1
        );
        assert_eq!(
            env.iter()
                .filter(|(key, _)| key.eq_ignore_ascii_case(WSLENV_ENV_VAR))
                .count(),
            1
        );
    }
}
