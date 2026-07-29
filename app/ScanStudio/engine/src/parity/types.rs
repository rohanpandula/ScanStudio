//! Shared types for the parity harness: the corpus manifest shapes plan
//! 13-02's loader populates, the module/status/report vocabulary a parity
//! run's JSON output is built from, and the error type every function in
//! this module returns.

use std::path::PathBuf;

use serde::Serialize;

// ---------------------------------------------------------------------
// Corpus manifest
// ---------------------------------------------------------------------

/// One numbered slot (frame) in a parity corpus, with paths to every file
/// plan 13-02's corpus loader may find for it. Optional fields reflect that
/// not every slot has a positive-strip scan, an ICE repair, or a disclosure
/// mask.
#[derive(Debug, Clone)]
pub struct CorpusSlot {
    pub slot: u8,
    pub receipt_path: PathBuf,
    pub rgb_path: PathBuf,
    pub ir_path: PathBuf,
    pub positive_path: Option<PathBuf>,
    pub repaired_path: Option<PathBuf>,
    pub repaired_ir_path: Option<PathBuf>,
    pub repaired_synth_mask_path: Option<PathBuf>,
}

/// A loaded parity corpus: its root directory and every slot found in it.
#[derive(Debug, Clone)]
pub struct CorpusManifest {
    pub root: PathBuf,
    pub slots: Vec<CorpusSlot>,
}

// ---------------------------------------------------------------------
// Report vocabulary
// ---------------------------------------------------------------------

/// Which pipeline module a score belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ModuleKind {
    Color,
    Autocrop,
    Deskew,
    Ice,
}

impl std::fmt::Display for ModuleKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let name = match self {
            ModuleKind::Color => "color",
            ModuleKind::Autocrop => "autocrop",
            ModuleKind::Deskew => "deskew",
            ModuleKind::Ice => "ice",
        };
        write!(f, "{name}")
    }
}

/// Outcome of scoring one module against one corpus slot.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case", tag = "status")]
pub enum ModuleStatus {
    Pass,
    Fail,
    NoReference { reason: String },
    NoCandidate { reason: String },
}

/// One module's score for one corpus slot.
#[derive(Debug, Clone, Serialize)]
pub struct ModuleScore {
    pub module: ModuleKind,
    pub slot: u8,
    pub status: ModuleStatus,
    pub metric_name: String,
    pub metric_value: Option<f64>,
    pub threshold: Option<f64>,
    /// Mandatory whenever `metric_value` is `Some` — distinguishes a
    /// freshly-generated, trustworthy reference from a corpus-bundled
    /// reference with known caveats (see plan 13-02's ICE handling).
    pub reference_provenance: Option<String>,
}

/// The full parity run: every module score across every slot in a corpus.
#[derive(Debug, Clone, Serialize)]
pub struct ParityReport {
    pub corpus_root: PathBuf,
    pub scores: Vec<ModuleScore>,
}

impl ParityReport {
    /// `true` iff any score's status is `Fail`. `NoReference`/`NoCandidate`
    /// are not failures — used by plan 13-02's binary for its exit code.
    pub fn has_any_failure(&self) -> bool {
        self.scores
            .iter()
            .any(|score| matches!(score.status, ModuleStatus::Fail))
    }
}

// ---------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------

/// Every function in `image_io.rs` and `corpus.rs` (plan 13-02) returns
/// `Result<_, ParityError>` and never calls `.unwrap()`/`.expect()` on data
/// read from an external file (TIFF, PNG, or JSON) — malformed corpus input
/// must produce a clear `ParityError`, not a panic.
#[derive(Debug)]
pub enum ParityError {
    Io(std::io::Error),
    Decode(String),
    Json(serde_json::Error),
}

impl std::fmt::Display for ParityError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ParityError::Io(err) => write!(f, "io error: {err}"),
            ParityError::Decode(message) => write!(f, "decode error: {message}"),
            ParityError::Json(err) => write!(f, "json error: {err}"),
        }
    }
}

impl std::error::Error for ParityError {}

impl From<std::io::Error> for ParityError {
    fn from(err: std::io::Error) -> Self {
        ParityError::Io(err)
    }
}

impl From<serde_json::Error> for ParityError {
    fn from(err: serde_json::Error) -> Self {
        ParityError::Json(err)
    }
}

/// The `image` crate's own error type — surfaced through the `Decode`
/// variant so `image::open(path)?` and `.save(path)?` work directly via
/// `?`-propagation in `image_io.rs`, without ever unwrapping.
impl From<image::ImageError> for ParityError {
    fn from(err: image::ImageError) -> Self {
        ParityError::Decode(err.to_string())
    }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn has_any_failure_is_true_only_when_a_score_is_fail() {
        let make_score = |status: ModuleStatus| ModuleScore {
            module: ModuleKind::Color,
            slot: 1,
            status,
            metric_name: "delta_e76".to_string(),
            metric_value: Some(0.1),
            threshold: Some(0.5),
            reference_provenance: Some("freshly-generated".to_string()),
        };

        let no_failures = ParityReport {
            corpus_root: PathBuf::from("/tmp/corpus"),
            scores: vec![
                make_score(ModuleStatus::Pass),
                make_score(ModuleStatus::NoReference {
                    reason: "no reference render yet".to_string(),
                }),
                make_score(ModuleStatus::NoCandidate {
                    reason: "module not ported yet".to_string(),
                }),
            ],
        };
        assert!(!no_failures.has_any_failure());

        let with_failure = ParityReport {
            corpus_root: PathBuf::from("/tmp/corpus"),
            scores: vec![make_score(ModuleStatus::Pass), make_score(ModuleStatus::Fail)],
        };
        assert!(with_failure.has_any_failure());
    }

    #[test]
    fn module_kind_serializes_snake_case() {
        assert_eq!(serde_json::to_string(&ModuleKind::Ice).unwrap(), "\"ice\"");
        assert_eq!(
            serde_json::to_string(&ModuleKind::Autocrop).unwrap(),
            "\"autocrop\""
        );
        assert_eq!(ModuleKind::Ice.to_string(), "ice");
    }

    #[test]
    fn module_status_serializes_with_status_tag() {
        let pass_json = serde_json::to_value(ModuleStatus::Pass).unwrap();
        assert_eq!(pass_json, serde_json::json!({"status": "pass"}));

        let no_reference_json = serde_json::to_value(ModuleStatus::NoReference {
            reason: "missing".to_string(),
        })
        .unwrap();
        assert_eq!(
            no_reference_json,
            serde_json::json!({"status": "no_reference", "reason": "missing"})
        );
    }
}
