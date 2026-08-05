use std::fmt;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathMapError {
    pub input: String,
    pub reason: String,
}

impl fmt::Display for PathMapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "unmappable path {:?}: {}", self.input, self.reason)
    }
}

impl std::error::Error for PathMapError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FromWslPath {
    Windows(String),
    WslInternal(String),
}

/// The only WSL-internal path family the renderer may read through the
/// `scanstudio-preview://` protocol.  The bridge contract writes both the
/// initial and spacing-adjusted tiles as:
///
/// `/home/<user>/.scanstudio/previews/<32-hex-session>/slot-NNNN.tif`
///
/// Keeping the parsed components (rather than accepting an arbitrary WSL
/// absolute path) lets the URI handler map the file through the pinned
/// distro's UNC share without turning the protocol into a general WSL file
/// reader.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WslPreviewPath {
    pub user: String,
    pub session: String,
    pub filename: String,
}

fn safe_wsl_component(value: &str) -> bool {
    !value.is_empty()
        && !matches!(value, "." | "..")
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
}

fn valid_preview_session(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_preview_filename(value: &str) -> bool {
    let Some(slot) = value
        .strip_prefix("slot-")
        .and_then(|value| value.strip_suffix(".tif"))
    else {
        return false;
    };
    slot.len() == 4 && slot.bytes().all(|byte| byte.is_ascii_digit())
}

/// Parse the bridge's preview artifact path without consulting WSL or the
/// host filesystem.  Every accepted value is exactly one TIFF below exactly
/// one UUID-like session directory; traversal, alternate roots, nested
/// descendants, Windows separators, and arbitrary preview filenames fail
/// closed.
pub fn parse_wsl_preview_path(input: &str) -> Result<WslPreviewPath, PathMapError> {
    if input.is_empty() {
        return Err(PathMapError {
            input: input.to_string(),
            reason: "empty path".to_string(),
        });
    }
    if input.trim() != input || input.contains('\\') || input.contains('\0') {
        return Err(PathMapError {
            input: input.to_string(),
            reason: "preview path must be an unmodified absolute WSL path".to_string(),
        });
    }

    let parts = input.split('/').collect::<Vec<_>>();
    if parts.len() != 7
        || !parts[0].is_empty()
        || parts[1] != "home"
        || !safe_wsl_component(parts[2])
        || parts[3] != ".scanstudio"
        || parts[4] != "previews"
        || !valid_preview_session(parts[5])
        || !valid_preview_filename(parts[6])
    {
        return Err(PathMapError {
            input: input.to_string(),
            reason: "expected /home/<user>/.scanstudio/previews/<32-hex-session>/slot-NNNN.tif"
                .to_string(),
        });
    }

    Ok(WslPreviewPath {
        user: parts[2].to_string(),
        session: parts[5].to_string(),
        filename: parts[6].to_string(),
    })
}

/// Map an allowlisted preview path beneath a caller-supplied distro share
/// root.  Production passes `\\wsl$\Ubuntu-24.04`; tests pass a temporary
/// directory that models the same tree without invoking WSL.
pub fn wsl_preview_paths_in_share(
    input: &str,
    distro_share_root: &Path,
) -> Result<(PathBuf, PathBuf), PathMapError> {
    let parsed = parse_wsl_preview_path(input)?;
    let preview_root = distro_share_root
        .join("home")
        .join(&parsed.user)
        .join(".scanstudio")
        .join("previews");
    let file = preview_root.join(parsed.session).join(parsed.filename);
    Ok((preview_root, file))
}

/// Build the pinned distro share root.  The distro value is internal (the
/// same constant used to launch the bridge), but it is still validated so a
/// future caller cannot accidentally widen the UNC route.
pub fn wsl_distro_share_root(distro: &str) -> Result<PathBuf, PathMapError> {
    if !safe_wsl_component(distro) {
        return Err(PathMapError {
            input: distro.to_string(),
            reason: "WSL distro must be one safe path component".to_string(),
        });
    }
    Ok(PathBuf::from(format!(r"\\wsl$\{distro}")))
}

pub fn to_wsl(win: &str) -> Result<String, PathMapError> {
    let trimmed = win.trim();
    if trimmed.is_empty() {
        return Err(PathMapError {
            input: win.to_string(),
            reason: "empty path".to_string(),
        });
    }
    if trimmed.starts_with("\\\\") || trimmed.starts_with("//") {
        return Err(PathMapError {
            input: win.to_string(),
            reason: format!("UNC path cannot be mapped to a WSL /mnt/<drive> path: {trimmed:?}"),
        });
    }
    let colon = trimmed.find(':').ok_or_else(|| PathMapError {
        input: win.to_string(),
        reason: format!("not an absolute Windows path (no drive letter): {trimmed:?}"),
    })?;
    if colon != 1 {
        return Err(PathMapError {
            input: win.to_string(),
            reason: format!("not an absolute Windows path (no single drive letter before the colon): {trimmed:?}"),
        });
    }
    let letter = trimmed.as_bytes()[0] as char;
    if !letter.is_ascii_alphabetic() {
        return Err(PathMapError {
            input: win.to_string(),
            reason: format!("drive letter is not an ASCII letter: {trimmed:?}"),
        });
    }
    let after = &trimmed[colon + 1..];
    if !after.starts_with('\\') && !after.starts_with('/') {
        return Err(PathMapError {
            input: win.to_string(),
            reason: format!(
                "drive-relative path (no separator immediately after the colon); refusing to guess a working directory: {trimmed:?}"
            ),
        });
    }
    let rest = &after[1..];
    let lower = letter.to_ascii_lowercase();
    let segments: Vec<&str> = rest
        .split(|c: char| c == '\\' || c == '/')
        .filter(|s| !s.is_empty())
        .collect();
    if segments.is_empty() {
        return Ok(format!("/mnt/{lower}"));
    }
    Ok(format!("/mnt/{lower}/{}", segments.join("/")))
}

pub fn from_wsl(wsl: &str) -> Result<FromWslPath, PathMapError> {
    let trimmed = wsl.trim();
    if trimmed.is_empty() {
        return Err(PathMapError {
            input: wsl.to_string(),
            reason: "empty path".to_string(),
        });
    }
    if let Some(rest_after_mnt) = trimmed.strip_prefix("/mnt/") {
        if let Some(slash) = rest_after_mnt.find('/') {
            let letter_seg = &rest_after_mnt[..slash];
            if letter_seg.len() == 1 && letter_seg.as_bytes()[0].is_ascii_alphabetic() {
                let upper = letter_seg.to_ascii_uppercase();
                let rest_backslashed = rest_after_mnt[slash + 1..].replace('/', "\\");
                return Ok(FromWslPath::Windows(format!("{upper}:\\{rest_backslashed}")));
            }
            return Ok(FromWslPath::WslInternal(trimmed.to_string()));
        }
        if rest_after_mnt.len() == 1 && rest_after_mnt.as_bytes()[0].is_ascii_alphabetic() {
            let upper = rest_after_mnt.to_ascii_uppercase();
            return Ok(FromWslPath::Windows(format!("{upper}:\\")));
        }
        return Ok(FromWslPath::WslInternal(trimmed.to_string()));
    }
    Ok(FromWslPath::WslInternal(trimmed.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_wsl_backslash_windows_path() {
        assert_eq!(
            to_wsl("C:\\Users\\test-user\\Scans"),
            Ok("/mnt/c/Users/test-user/Scans".to_string())
        );
    }

    #[test]
    fn to_wsl_forward_slash_windows_path() {
        assert_eq!(
            to_wsl("C:/Users/test-user/Scans"),
            Ok("/mnt/c/Users/test-user/Scans".to_string())
        );
    }

    #[test]
    fn to_wsl_different_drive_letter() {
        assert_eq!(to_wsl("D:\\Data"), Ok("/mnt/d/Data".to_string()));
    }

    #[test]
    fn to_wsl_trailing_backslash_normalized() {
        assert_eq!(
            to_wsl("C:\\Users\\test-user\\Scans\\"),
            Ok("/mnt/c/Users/test-user/Scans".to_string())
        );
    }

    #[test]
    fn to_wsl_bare_drive_root() {
        assert_eq!(to_wsl("C:\\"), Ok("/mnt/c".to_string()));
    }

    #[test]
    fn to_wsl_refuses_unc_backslash() {
        assert!(to_wsl("\\\\server\\share\\path").is_err());
    }

    #[test]
    fn to_wsl_refuses_unc_forward_slash() {
        assert!(to_wsl("//server/share/path").is_err());
    }

    #[test]
    fn to_wsl_refuses_relative_path() {
        assert!(to_wsl("Scans\\output").is_err());
    }

    #[test]
    fn to_wsl_refuses_leading_dot_relative() {
        assert!(to_wsl(".\\Scans").is_err());
    }

    #[test]
    fn to_wsl_refuses_empty() {
        assert!(to_wsl("").is_err());
    }

    #[test]
    fn to_wsl_refuses_whitespace_only() {
        assert!(to_wsl("   ").is_err());
    }

    #[test]
    fn to_wsl_refuses_drive_relative() {
        assert!(to_wsl("C:Scans").is_err());
    }

    #[test]
    fn from_wsl_windows_nested() {
        assert_eq!(
            from_wsl("/mnt/c/Users/test-user/Scans"),
            Ok(FromWslPath::Windows(
                "C:\\Users\\test-user\\Scans".to_string()
            ))
        );
    }

    #[test]
    fn from_wsl_windows_data() {
        assert_eq!(
            from_wsl("/mnt/d/Data"),
            Ok(FromWslPath::Windows("D:\\Data".to_string()))
        );
    }

    #[test]
    fn from_wsl_bare_drive_root() {
        assert_eq!(
            from_wsl("/mnt/c"),
            Ok(FromWslPath::Windows("C:\\".to_string()))
        );
    }

    #[test]
    fn from_wsl_internal_staging_path() {
        assert_eq!(
            from_wsl("/home/user/.scanstudio/wsl-staging/job-1/frame-0001.tif"),
            Ok(FromWslPath::WslInternal(
                "/home/user/.scanstudio/wsl-staging/job-1/frame-0001.tif".to_string()
            ))
        );
    }

    #[test]
    fn from_wsl_two_letter_segment_is_internal() {
        assert_eq!(
            from_wsl("/mnt/cd/something"),
            Ok(FromWslPath::WslInternal(
                "/mnt/cd/something".to_string()
            ))
        );
    }

    #[test]
    fn from_wsl_refuses_empty() {
        assert!(from_wsl("").is_err());
    }

    #[test]
    fn round_trip_windows_paths() {
        for p in ["C:\\Users\\test-user\\Scans", "D:\\Data", "C:\\"] {
            let wsl = to_wsl(p).unwrap();
            assert_eq!(from_wsl(&wsl).unwrap(), FromWslPath::Windows(p.to_string()));
        }
    }

    #[test]
    fn real_bridge_preview_maps_beneath_pinned_distro_share() {
        let session = "0123456789abcdef0123456789abcdef";
        let input = format!("/home/wsl-user/.scanstudio/previews/{session}/slot-0006.tif");
        let share = wsl_distro_share_root("Ubuntu-24.04").unwrap();
        assert_eq!(share.to_string_lossy(), r"\\wsl$\Ubuntu-24.04");

        let (root, file) = wsl_preview_paths_in_share(&input, &share).unwrap();
        let expected_root = share
            .join("home")
            .join("wsl-user")
            .join(".scanstudio")
            .join("previews");
        assert_eq!(root, expected_root);
        assert_eq!(file, root.join(session).join("slot-0006.tif"));
    }

    #[test]
    fn adjusted_real_bridge_preview_uses_the_same_allowlisted_shape() {
        let input =
            "/home/wsl-user/.scanstudio/previews/abcdef0123456789abcdef0123456789/slot-0003.tif";
        assert_eq!(
            parse_wsl_preview_path(input).unwrap(),
            WslPreviewPath {
                user: "wsl-user".to_string(),
                session: "abcdef0123456789abcdef0123456789".to_string(),
                filename: "slot-0003.tif".to_string(),
            }
        );
    }

    #[test]
    fn preview_mapping_rejects_traversal_and_other_wsl_roots() {
        for input in [
            "/home/wsl-user/.scanstudio/previews/0123456789abcdef0123456789abcdef/../slot-0001.tif",
            "/home/wsl-user/.scanstudio/previews/0123456789abcdef0123456789abcdef/nested/slot-0001.tif",
            "/home/wsl-user/.scanstudio/hw-telemetry/0123456789abcdef0123456789abcdef/slot-0001.tif",
            "/tmp/scanstudio/0123456789abcdef0123456789abcdef/slot-0001.tif",
            "/home/wsl-user/.scanstudio/previews/not-a-session/slot-0001.tif",
            "/home/wsl-user/.scanstudio/previews/0123456789abcdef0123456789abcdef/receipt.json",
            "/home/wsl-user\\evil/.scanstudio/previews/0123456789abcdef0123456789abcdef/slot-0001.tif",
        ] {
            assert!(
                parse_wsl_preview_path(input).is_err(),
                "attack path should be rejected: {input:?}"
            );
        }
    }
}
