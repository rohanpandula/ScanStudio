use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WslWriteMode {
    StageThenMove,
    Direct,
}

pub const DEFAULT_WSL_WRITE_MODE: WslWriteMode = WslWriteMode::StageThenMove;

pub fn describe_write_mode(mode: WslWriteMode) -> &'static str {
    match mode {
        WslWriteMode::StageThenMove => {
            "stage-then-move (default): bridge writes to a WSL-internal staging directory; the app copies to the Windows destination and verifies sha256 before deleting the staged copy"
        }
        WslWriteMode::Direct => {
            "direct: bridge writes straight to the mapped /mnt/<drive> destination (not recommended for files over a few MB \u{2014} see PITFALLS.md 9P throughput findings)"
        }
    }
}

pub fn staging_dir_for_job(job_id: &str) -> String {
    // WSL-side, tilde-relative string only: this module has no access to the
    // WSL user's home directory from the Windows host process and never
    // attempts to resolve `~` itself.
    format!("~/.scanstudio/wsl-staging/{job_id}")
}

pub struct ArtifactEvidence {
    pub sha256: String,
    pub byte_length: u64,
}

#[derive(Debug)]
pub enum StagingError {
    SourceMissing(String),
    CopyFailed(String),
    SizeMismatch { expected: u64, actual: u64 },
    HashMismatch { expected: String, actual: String },
}

pub trait FileHasher {
    fn hash_file(&self, path: &Path) -> std::io::Result<String>;
}

pub struct Sha256FileHasher;

impl FileHasher for Sha256FileHasher {
    fn hash_file(&self, path: &Path) -> std::io::Result<String> {
        let file = std::fs::File::open(path)?;
        let mut reader = std::io::BufReader::new(file);
        let mut hasher = Sha256::new();
        let mut buf = [0u8; 8192];
        loop {
            let n = reader.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        let digest = hasher.finalize();
        Ok(hex_encode(&digest))
    }
}

pub fn verify_and_finalize_move(
    hasher: &dyn FileHasher,
    staged_path: &Path,
    dest_path: &Path,
    expected: &ArtifactEvidence,
) -> Result<(), StagingError> {
    if !staged_path.exists() {
        return Err(StagingError::SourceMissing(
            staged_path.display().to_string(),
        ));
    }
    std::fs::copy(staged_path, dest_path)
        .map_err(|e| StagingError::CopyFailed(e.to_string()))?;
    let actual_size = std::fs::metadata(dest_path)
        .map_err(|e| StagingError::CopyFailed(e.to_string()))?
        .len();
    if actual_size != expected.byte_length {
        return Err(StagingError::SizeMismatch {
            expected: expected.byte_length,
            actual: actual_size,
        });
    }
    let actual_hash = hasher
        .hash_file(dest_path)
        .map_err(|e| StagingError::CopyFailed(e.to_string()))?;
    if actual_hash != expected.sha256 {
        return Err(StagingError::HashMismatch {
            expected: expected.sha256.clone(),
            actual: actual_hash,
        });
    }
    std::fs::remove_file(staged_path).map_err(|e| StagingError::CopyFailed(e.to_string()))?;
    Ok(())
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    const FIXTURE_CONTENT: &str = "scanstudio-staging-fixture";
    const FIXTURE_SHA256: &str =
        "f111265ca680cf85989c976eba26f495cb3da6a592d77ef41bba594b5db480e0";
    const WRONG_SHA256: &str = "b57045bc2ab77c3644eec6757a5fba1eb4d852a9d7c72cf52535de65231936f7";

    fn unique_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("scanstudio-wsl-staging-{}-{name}", std::process::id()))
    }

    fn write_fixture(dir: &Path) -> PathBuf {
        fs::create_dir_all(dir).unwrap();
        let staged = dir.join("frame-0001.tif");
        fs::write(&staged, FIXTURE_CONTENT.as_bytes()).unwrap();
        staged
    }

    #[test]
    fn describe_write_mode_returns_exact_strings() {
        assert_eq!(
            describe_write_mode(WslWriteMode::StageThenMove),
            "stage-then-move (default): bridge writes to a WSL-internal staging directory; the app copies to the Windows destination and verifies sha256 before deleting the staged copy"
        );
        assert_eq!(
            describe_write_mode(WslWriteMode::Direct),
            "direct: bridge writes straight to the mapped /mnt/<drive> destination (not recommended for files over a few MB \u{2014} see PITFALLS.md 9P throughput findings)"
        );
    }

    #[test]
    fn staging_dir_for_job_returns_tilde_relative_path() {
        assert_eq!(staging_dir_for_job("job-42"), "~/.scanstudio/wsl-staging/job-42");
    }

    #[test]
    fn happy_path_copies_verifies_and_deletes_staged() {
        let staged_dir = unique_dir("happy-staged");
        let dest_dir = unique_dir("happy-dest");
        fs::create_dir_all(&dest_dir).unwrap();
        let staged = write_fixture(&staged_dir);
        let dest = dest_dir.join("out.tif");

        let result = verify_and_finalize_move(
            &Sha256FileHasher,
            &staged,
            &dest,
            &ArtifactEvidence {
                sha256: FIXTURE_SHA256.to_string(),
                byte_length: 26,
            },
        );

        assert!(result.is_ok());
        assert!(dest.exists(), "dest file should exist");
        assert_eq!(fs::metadata(&dest).unwrap().len(), 26);
        assert_eq!(fs::read(&dest).unwrap(), FIXTURE_CONTENT.as_bytes());
        assert!(!staged.exists(), "staged file should be deleted after verification");

        fs::remove_dir_all(&staged_dir).ok();
        fs::remove_dir_all(&dest_dir).ok();
    }

    #[test]
    fn size_mismatch_returns_error_and_keeps_staged() {
        let staged_dir = unique_dir("size-staged");
        let dest_dir = unique_dir("size-dest");
        fs::create_dir_all(&dest_dir).unwrap();
        let staged = write_fixture(&staged_dir);
        let dest = dest_dir.join("out.tif");

        let result = verify_and_finalize_move(
            &Sha256FileHasher,
            &staged,
            &dest,
            &ArtifactEvidence {
                sha256: FIXTURE_SHA256.to_string(),
                byte_length: 999,
            },
        );

        match result {
            Err(StagingError::SizeMismatch { expected, actual }) => {
                assert_eq!(expected, 999);
                assert_eq!(actual, 26);
            }
            other => panic!("expected SizeMismatch, got {other:?}"),
        }
        assert!(staged.exists(), "staged file must NOT be deleted on size mismatch");

        fs::remove_dir_all(&staged_dir).ok();
        fs::remove_dir_all(&dest_dir).ok();
    }

    #[test]
    fn hash_mismatch_returns_error_and_keeps_staged() {
        let staged_dir = unique_dir("hash-staged");
        let dest_dir = unique_dir("hash-dest");
        fs::create_dir_all(&dest_dir).unwrap();
        let staged = write_fixture(&staged_dir);
        let dest = dest_dir.join("out.tif");

        let result = verify_and_finalize_move(
            &Sha256FileHasher,
            &staged,
            &dest,
            &ArtifactEvidence {
                sha256: WRONG_SHA256.to_string(),
                byte_length: 26,
            },
        );

        match result {
            Err(StagingError::HashMismatch { expected, actual }) => {
                assert_eq!(expected, WRONG_SHA256);
                assert_eq!(actual, FIXTURE_SHA256);
            }
            other => panic!("expected HashMismatch, got {other:?}"),
        }
        assert!(staged.exists(), "staged file must NOT be deleted on hash mismatch");

        fs::remove_dir_all(&staged_dir).ok();
        fs::remove_dir_all(&dest_dir).ok();
    }

    #[test]
    fn source_missing_returns_error() {
        let dir = unique_dir("missing");
        let missing = dir.join("never-was-created.tif");
        let dest = dir.join("out.tif");

        let result = verify_and_finalize_move(
            &Sha256FileHasher,
            &missing,
            &dest,
            &ArtifactEvidence {
                sha256: FIXTURE_SHA256.to_string(),
                byte_length: 26,
            },
        );

        assert!(matches!(result, Err(StagingError::SourceMissing(_))));

        fs::remove_dir_all(&dir).ok();
    }
}
