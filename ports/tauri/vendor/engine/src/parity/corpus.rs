//! Corpus discovery: finds each numbered slot in a parity corpus by
//! globbing `acceptance_slot{NN}_receipt.json` and deriving every sibling
//! artifact path from that receipt's own basename (see plan 13-02's
//! `<corpus_naming_convention>`), plus receipt.json provenance extraction
//! for `PARITY.md` and the CLI's report (T-13-03: every field degrades to
//! `None`, never a panic, on missing or malformed receipt content).

use std::path::{Path, PathBuf};

use crate::parity::types::{CorpusManifest, CorpusSlot, ParityError};

const RECEIPT_PREFIX: &str = "acceptance_slot";
const RECEIPT_SUFFIX: &str = "_receipt.json";

/// Provenance fields pulled from one slot's `receipt.json`, per plan
/// 13-02's `<receipt_json_fields>` context block. Every field is optional —
/// a missing or wrong-typed field becomes `None`, never a parse error for
/// the whole receipt.
#[derive(Debug, Clone, Default)]
pub struct ReceiptProvenance {
    pub device_model: Option<String>,
    pub dpi: Option<u32>,
    pub depth: Option<u32>,
    pub batch_session_id: Option<String>,
    pub positive_color_mode: Option<String>,
    pub positive_builder_algorithm: Option<String>,
    pub positive_icc_name: Option<String>,
    pub repair_engine: Option<String>,
    pub repair_engine_version: Option<String>,
    pub repair_mode_resolved: Option<String>,
}

/// Scans `root` for every `acceptance_slot{NN}_receipt.json` and derives
/// the rest of that slot's artifact paths by fixed suffix from the shared
/// basename. Filenames that don't cleanly parse a slot number are skipped
/// rather than erroring the whole scan; the corpus's internal `.negpy-*`
/// cache directories are excluded naturally — they are directories, not
/// files ending in `_receipt.json`, so the filename-suffix filter alone
/// excludes them, no special-case needed. An empty `slots` vec is a valid
/// `Ok` result — the caller decides whether zero slots is fatal.
pub fn discover(root: &Path) -> Result<CorpusManifest, ParityError> {
    let mut slots = Vec::new();

    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }

        let file_name = entry.file_name();
        let Some(file_name_str) = file_name.to_str() else {
            continue; // skip non-UTF8 filenames rather than erroring the scan
        };

        if !file_name_str.starts_with(RECEIPT_PREFIX) || !file_name_str.ends_with(RECEIPT_SUFFIX) {
            continue;
        }

        let slot_digits =
            &file_name_str[RECEIPT_PREFIX.len()..file_name_str.len() - RECEIPT_SUFFIX.len()];
        let Ok(slot_number) = slot_digits.parse::<u8>() else {
            continue; // doesn't parse cleanly as a slot number — skip, don't error the scan
        };

        // Shared basename ("acceptance_slotNN") every sibling artifact is
        // derived from by fixed suffix.
        let basename = &file_name_str[..file_name_str.len() - RECEIPT_SUFFIX.len()];

        slots.push(CorpusSlot {
            slot: slot_number,
            receipt_path: root.join(file_name_str),
            rgb_path: root.join(format!("{basename}.tif")),
            ir_path: root.join(format!("{basename}_IR.tif")),
            positive_path: existing_path(root, &format!("{basename}_positive.tif")),
            repaired_path: existing_path(root, &format!("{basename}_repaired.tif")),
            repaired_ir_path: existing_path(root, &format!("{basename}_repaired_IR.tif")),
            repaired_synth_mask_path: existing_path(root, &format!("{basename}_repaired_SYNTH.png")),
        });
    }

    slots.sort_by_key(|slot| slot.slot);

    Ok(CorpusManifest {
        root: root.to_path_buf(),
        slots,
    })
}

/// `Some(root.join(file_name))` only if that path actually exists — not
/// every corpus snapshot is guaranteed to have every derivative.
fn existing_path(root: &Path, file_name: &str) -> Option<PathBuf> {
    let path = root.join(file_name);
    path.exists().then_some(path)
}

/// Reads and parses one slot's `receipt.json`, extracting every
/// `ReceiptProvenance` field via `.get()`/`.as_str()`/`.and_then()` chains
/// matching the JSON paths in plan 13-02's `<receipt_json_fields>` context
/// block. Only the top-level `serde_json::from_str` call itself can
/// produce a `ParityError` (genuinely malformed JSON); every field past
/// that degrades gracefully to `None` on a missing or wrong-typed value.
pub fn read_receipt_provenance(receipt_path: &Path) -> Result<ReceiptProvenance, ParityError> {
    let contents = std::fs::read_to_string(receipt_path)?;
    let value: serde_json::Value = serde_json::from_str(&contents)?;

    let device_model = value.get("device_model").and_then(|v| v.as_str()).map(String::from);
    let dpi = value.get("dpi").and_then(|v| v.as_u64()).map(|n| n as u32);
    let depth = value.get("depth").and_then(|v| v.as_u64()).map(|n| n as u32);

    let batch_session_id = value
        .get("nikon_density_ownership")
        .and_then(|v| v.get("batch_session_id"))
        .and_then(|v| v.as_str())
        .map(String::from);

    let outputs = value.get("outputs");
    let positive = outputs.and_then(|v| v.get("positive"));
    let repaired = outputs.and_then(|v| v.get("repaired"));

    let positive_color_mode = positive
        .and_then(|v| v.get("color_mode"))
        .and_then(|v| v.as_str())
        .map(String::from);
    let positive_builder_algorithm = positive
        .and_then(|v| v.get("builder_receipt"))
        .and_then(|v| v.get("algorithm"))
        .and_then(|v| v.as_str())
        .map(String::from);
    let positive_icc_name = positive
        .and_then(|v| v.get("icc_profile"))
        .and_then(|v| v.get("name"))
        .and_then(|v| v.as_str())
        .map(String::from);

    let repair_engine = repaired
        .and_then(|v| v.get("engine"))
        .and_then(|v| v.as_str())
        .map(String::from);
    let repair_engine_version = repaired
        .and_then(|v| v.get("engine_version"))
        .and_then(|v| v.as_str())
        .map(String::from);
    let repair_mode_resolved = repaired
        .and_then(|v| v.get("mode_resolved"))
        .and_then(|v| v.as_str())
        .map(String::from);

    Ok(ReceiptProvenance {
        device_model,
        dpi,
        depth,
        batch_session_id,
        positive_color_mode,
        positive_builder_algorithm,
        positive_icc_name,
        repair_engine,
        repair_engine_version,
        repair_mode_resolved,
    })
}
