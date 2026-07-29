//! Corpus-dependent tests: gated behind `SCANSTUDIO_PARITY_CORPUS` and
//! skipped with a clear stderr message (exit 0) when it's unset — normal
//! `cargo test` runs never depend on the real corpus (Task 1, plan 13-02).

use std::path::{Path, PathBuf};

use scanstudio_engine::parity::corpus::{discover, read_receipt_provenance};

fn corpus_root_or_skip() -> Option<PathBuf> {
    match std::env::var("SCANSTUDIO_PARITY_CORPUS") {
        Ok(value) if !value.is_empty() => Some(PathBuf::from(value)),
        _ => {
            eprintln!(
                "SCANSTUDIO_PARITY_CORPUS not set — skipping corpus-dependent test (expected in normal cargo test runs)"
            );
            None
        }
    }
}

#[test]
fn discovers_all_six_corpus_slots() {
    let Some(root) = corpus_root_or_skip() else {
        return;
    };

    let manifest = discover(&root).expect("discover should succeed against the real corpus");
    assert_eq!(
        manifest.slots.len(),
        6,
        "expected exactly 6 slots in the refeed-7 corpus"
    );
    for slot in &manifest.slots {
        assert!(
            slot.rgb_path.exists(),
            "slot {} rgb_path does not exist: {}",
            slot.slot,
            slot.rgb_path.display()
        );
        assert!(
            slot.ir_path.exists(),
            "slot {} ir_path does not exist: {}",
            slot.slot,
            slot.ir_path.display()
        );
    }
}

#[test]
fn receipt_provenance_extracts_known_fields() {
    let Some(root) = corpus_root_or_skip() else {
        return;
    };

    let receipt_path = root.join("acceptance_slot01_receipt.json");
    let provenance = read_receipt_provenance(&receipt_path)
        .expect("read_receipt_provenance should succeed on slot 1's real receipt");

    assert_eq!(
        provenance.device_model,
        Some("Nikon LS-5000 ED 1.03".to_string())
    );
    assert_eq!(
        provenance.batch_session_id,
        Some("batch-slot01-slot06-31odjrup".to_string())
    );
}

/// Simulate `resolve_reference_path` logic: try colocated, then
/// `SCANSTUDIO_PARITY_REFS` fallback. This is an integration-level
/// stand-in that exercises the same resolution strategy as
/// `bin/parity.rs` without importing the binary module.
#[test]
fn reference_fallback_env_var_resolves_external_refs() {
    use std::fs;

    let tmp = std::env::temp_dir().join("parity_fallback_test");
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).unwrap();

    let corpus_dir = tmp.join("corpus");
    let refs_dir = tmp.join("refs");
    fs::create_dir_all(&corpus_dir).unwrap();
    fs::create_dir_all(&refs_dir).unwrap();

    // Place a dummy receipt in corpus so discover works, plus a dummy
    // reference TIFF in refs_dir (not in corpus).
    let ref_filename = "acceptance_slot01_reference_color_nikonlook-v1.tif";
    let ref_content = b"tiff-header-dummy";
    fs::write(refs_dir.join(ref_filename), ref_content).unwrap();
    let receipt_content = r#"{"device_model":"test","dpi":4000,"depth":16}"#;
    fs::write(corpus_dir.join("acceptance_slot01_receipt.json"), receipt_content).unwrap();

    // Exercise the same resolution as bin/parity.rs does via
    // resolve_reference_path: colocated should miss, fallback should hit.
    let colocated = corpus_dir.join(ref_filename);
    assert!(!colocated.exists(), "colocated file should not exist");

    std::env::set_var("SCANSTUDIO_PARITY_REFS", refs_dir.to_str().unwrap());
    let discovered_path = resolve_reference_path_test(&corpus_dir, ref_filename);
    assert!(
        discovered_path.is_some(),
        "resolve_reference_path should find the file in SCANSTUDIO_PARITY_REFS"
    );
    assert_eq!(discovered_path.unwrap(), refs_dir.join(ref_filename));

    // Cleanup
    std::env::remove_var("SCANSTUDIO_PARITY_REFS");
    let _ = fs::remove_dir_all(&tmp);
}

/// Stand-in for `resolve_reference_path` in `bin/parity.rs`.
fn resolve_reference_path_test(root: &Path, filename: &str) -> Option<PathBuf> {
    let colocated = root.join(filename);
    if colocated.exists() {
        return Some(colocated);
    }
    if let Ok(refs_dir) = std::env::var("SCANSTUDIO_PARITY_REFS") {
        if !refs_dir.is_empty() {
            let fallback = PathBuf::from(refs_dir).join(filename);
            if fallback.exists() {
                return Some(fallback);
            }
        }
    }
    None
}
