//! Tests for `parity::candidates` (Phase 14, plan 14-02): a fast,
//! corpus-independent guard test for `candidate_dir_conflicts_with_corpus`
//! (T-14-03), and a corpus-gated plausibility + archive-immutability proof
//! for `render_color_candidate` (T-14-05). Mirrors
//! `engine/tests/parity_corpus.rs`'s `corpus_root_or_skip()` skip-with-
//! stderr-message-exit-0-when-unset convention exactly — normal `cargo
//! test` runs never depend on the real corpus.

use std::fs;
use std::path::PathBuf;

use scanstudio_engine::parity::{candidate_dir_conflicts_with_corpus, corpus, render_color_candidate};
use scanstudio_engine::processing::nikonlook;

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

/// Removes its wrapped directory on drop — guarantees the temp dir used by
/// `candidate_dir_inside_corpus_is_rejected` is cleaned up even if an
/// assertion panics partway through (early return via unwind), not just on
/// a clean pass.
struct TempDirGuard(PathBuf);

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn candidate_dir_inside_corpus_is_rejected() {
    let tmp = std::env::temp_dir().join("nikonlook_candidates_guard_test");
    let _ = fs::remove_dir_all(&tmp);
    let _guard = TempDirGuard(tmp.clone());

    let corpus_dir = tmp.join("corpus");
    fs::create_dir_all(&corpus_dir).expect("create corpus_dir");

    // Deliberately never created — candidate_dir_conflicts_with_corpus must
    // still detect the nested case via the parent-canonicalize fallback.
    let nested = corpus_dir.join("candidates");
    let sibling = tmp.join("candidates");

    assert!(
        candidate_dir_conflicts_with_corpus(&corpus_dir, &corpus_dir),
        "candidate_dir == corpus_root must be flagged as a conflict"
    );
    assert!(
        candidate_dir_conflicts_with_corpus(&corpus_dir, &nested),
        "candidate_dir nested inside corpus_root must be flagged as a conflict, even when not yet created"
    );
    assert!(
        !candidate_dir_conflicts_with_corpus(&corpus_dir, &sibling),
        "a sibling directory outside corpus_root must not be flagged as a conflict"
    );
}

#[test]
fn rendering_slot_one_is_plausible_and_leaves_corpus_untouched() {
    let Some(root) = corpus_root_or_skip() else {
        return;
    };

    let manifest = corpus::discover(&root).expect("discover should succeed against the real corpus");
    let slot = manifest
        .slots
        .iter()
        .find(|slot| slot.slot == 1)
        .expect("slot 1 must exist in the real corpus");

    let before = fs::metadata(&slot.rgb_path)
        .expect("slot 1 rgb_path metadata (before) must be readable")
        .modified()
        .expect("slot 1 rgb_path mtime (before) must be readable");

    let bundle = nikonlook::load_bundle().expect("real nikonlook bundle must load");
    let candidate = render_color_candidate(slot, &bundle)
        .expect("render_color_candidate should succeed against the real corpus");

    assert!(
        candidate.width > 0 && candidate.height > 0,
        "candidate image must have non-zero dimensions"
    );

    // Explicit nested loop (not .flatten()) to avoid any doubt about
    // iterator trait resolution on &[u16; 3] — tracks running min/max
    // across every channel of every pixel.
    let mut min = u16::MAX;
    let mut max = u16::MIN;
    for pixel in &candidate.pixels {
        for &channel in pixel {
            if channel < min {
                min = channel;
            }
            if channel > max {
                max = channel;
            }
        }
    }
    assert!(
        max > min,
        "candidate image must not be a degenerate flat image (min={min}, max={max})"
    );

    let after = fs::metadata(&slot.rgb_path)
        .expect("slot 1 rgb_path metadata (after) must be readable")
        .modified()
        .expect("slot 1 rgb_path mtime (after) must be readable");

    // Archive-immutability proof (T-14-05): candidate generation must never
    // mutate the corpus's raw capture file.
    assert_eq!(
        before, after,
        "rendering a candidate must never mutate the corpus's raw capture file"
    );
}
