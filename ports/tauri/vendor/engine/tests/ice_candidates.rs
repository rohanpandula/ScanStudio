//! Tests for the ICE half of `parity::candidates` (Phase 16, plan 16-03):
//! fast, corpus-independent guard-reuse confirmation (Test B), plus
//! corpus-gated plausibility + archive-immutability proof (Test A) and the
//! reference-mask coverage investigation's own real, reproducible
//! measurement (Test C, `<reference_decision>`). Mirrors
//! `engine/tests/nikonlook_candidates.rs`'s/`engine/tests/geometry_candidates.rs`'s
//! `corpus_root_or_skip()` skip-with-stderr-message-exit-0-when-unset
//! convention exactly — normal `cargo test` runs never depend on the real
//! corpus.

use std::fs;
use std::path::PathBuf;

use scanstudio_engine::parity::image_io;
use scanstudio_engine::parity::scoring;
use scanstudio_engine::parity::{candidate_dir_conflicts_with_corpus, corpus, render_ice_candidate};

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
/// `candidate_dir_guard_is_reused_not_reimplemented` is cleaned up even if
/// an assertion panics partway through (early return via unwind), not just
/// on a clean pass.
struct TempDirGuard(PathBuf);

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

// -- Test A -------------------------------------------------------------

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

    let rgb_before = fs::metadata(&slot.rgb_path)
        .expect("slot 1 rgb_path metadata (before) must be readable")
        .modified()
        .expect("slot 1 rgb_path mtime (before) must be readable");
    let ir_before = fs::metadata(&slot.ir_path)
        .expect("slot 1 ir_path metadata (before) must be readable")
        .modified()
        .expect("slot 1 ir_path mtime (before) must be readable");

    let (repaired, mask) =
        render_ice_candidate(slot).expect("render_ice_candidate should succeed against the real corpus");

    assert!(
        repaired.width > 0 && repaired.height > 0,
        "repaired candidate image must have non-zero dimensions"
    );
    assert_eq!(mask.width, repaired.width, "mask/repaired width mismatch");
    assert_eq!(mask.height, repaired.height, "mask/repaired height mismatch");

    // Explicit nested loop (not .flatten()) — tracks running min/max across
    // every channel of every pixel, mirroring nikonlook_candidates.rs's/
    // geometry_candidates.rs's own degenerate-flat-image check.
    let mut min = u16::MAX;
    let mut max = u16::MIN;
    for pixel in &repaired.pixels {
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
        "repaired candidate image must not be a degenerate flat image (min={min}, max={max})"
    );

    // Real photographic content almost always has SOME dust: at least one
    // mask pixel should read above a low sanity threshold (0.01 of
    // full-scale). An all-zero mask would indicate a broken detector, not a
    // genuinely defect-free frame.
    let low_threshold_u16 = (0.01_f32 * 65535.0) as u16;
    let has_any_defect = mask.pixels.iter().any(|&value| value > low_threshold_u16);
    assert!(
        has_any_defect,
        "defect mask must have at least one pixel above the low sanity threshold — an all-zero mask would indicate a broken detector, not real photographic content"
    );

    // The mask must not be saturated everywhere either — "every pixel
    // flagged" would indicate a broken detector, not real, sparse defects.
    let saturated_count = mask.pixels.iter().filter(|&&value| value == u16::MAX).count();
    assert!(
        saturated_count < mask.pixels.len(),
        "defect mask must not be saturated on every pixel ({saturated_count}/{} pixels at max)",
        mask.pixels.len()
    );

    let rgb_after = fs::metadata(&slot.rgb_path)
        .expect("slot 1 rgb_path metadata (after) must be readable")
        .modified()
        .expect("slot 1 rgb_path mtime (after) must be readable");
    let ir_after = fs::metadata(&slot.ir_path)
        .expect("slot 1 ir_path metadata (after) must be readable")
        .modified()
        .expect("slot 1 ir_path mtime (after) must be readable");

    // Archive-immutability proof (T-16-09), extended to the two-file
    // (RGB+IR) input this module reads, matching T-14-05/T-15-05's
    // single-file precedent: candidate generation must never mutate either
    // of the corpus's raw capture files.
    assert_eq!(
        rgb_before, rgb_after,
        "rendering an ICE candidate must never mutate the corpus's raw RGB capture file"
    );
    assert_eq!(
        ir_before, ir_after,
        "rendering an ICE candidate must never mutate the corpus's raw IR capture file"
    );
}

// -- Test B ---------------------------------------------------------------

#[test]
fn candidate_dir_guard_is_reused_not_reimplemented() {
    let tmp = std::env::temp_dir().join("ice_candidates_guard_test");
    let _ = fs::remove_dir_all(&tmp);
    let _guard = TempDirGuard(tmp.clone());

    let corpus_dir = tmp.join("corpus");
    fs::create_dir_all(&corpus_dir).expect("create corpus_dir");

    // Deliberately never created — candidate_dir_conflicts_with_corpus must
    // still detect the nested case via the parent-canonicalize fallback.
    let nested = corpus_dir.join("candidates");
    let sibling = tmp.join("candidates");

    // Same 3-path shape as nikonlook_candidates.rs's/geometry_candidates.rs's
    // own guard-reuse tests — this is intentionally a re-confirmation that
    // render_ice_candidates calls the exact same
    // parity::candidate_dir_conflicts_with_corpus function the other two
    // candidate binaries already use (Phase 14/15), not a second, forked
    // copy; the guard itself is already covered there, not new coverage
    // here (T-16-07).
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

// -- Test C -----------------------------------------------------------------

/// Threshold used to binarize both the corpus-bundled hybrid disclosure
/// mask and this port's own `DefectMap`-derived mask when computing a
/// "fraction of frame flagged" coverage statistic — matches
/// `bin/parity.rs`'s own `score_ice()` binarization threshold (`0.5`,
/// passed to `scoring::score_ice_mask_agreement`) so this test's numbers
/// are directly comparable to what the real gate would see.
const COVERAGE_THRESHOLD: f32 = 0.5;

/// Implements the FIRST step of `<reference_decision>`'s investigation as a
/// real, running, reproducible test (T-16-10): computes the fraction of
/// pixels above `COVERAGE_THRESHOLD` for BOTH the corpus's own
/// `_repaired_SYNTH.png` disclosure mask (hybrid/ML-mode provenance) and
/// this plan's own Legacy-port `DefectMap` (via `render_ice_candidate`) on
/// the same slot, plus the actual Jaccard agreement
/// (`scoring::score_ice_mask_agreement`) between the two — the exact
/// number `bin/parity.rs`'s `score_ice()` would compute if these were
/// written to disk as candidate/reference files. Logs all three via
/// `eprintln!` (deliberately, on success too) so the investigation's
/// real-world conclusion is backed by a reproducible measurement, not a
/// one-off manual observation. Does NOT assert pass/fail against a fixed
/// expectation of what the "right" fraction is — there is no ground truth
/// for that independent of running the real detector; only a basic
/// finiteness/range sanity check on each computed fraction.
#[test]
fn reference_mask_coverage_sanity_check() {
    let Some(root) = corpus_root_or_skip() else {
        return;
    };

    let manifest = corpus::discover(&root).expect("discover should succeed against the real corpus");
    let slot = manifest
        .slots
        .iter()
        .find(|slot| slot.slot == 1)
        .expect("slot 1 must exist in the real corpus");

    let Some(reference_path) = slot.repaired_synth_mask_path.clone() else {
        eprintln!(
            "slot 1 has no repaired_synth_mask_path in this corpus snapshot — skipping reference_mask_coverage_sanity_check"
        );
        return;
    };

    let reference_mask = image_io::read_mask_normalized(&reference_path)
        .expect("corpus-bundled ICE disclosure mask should decode");
    let reference_fraction = fraction_above_threshold(&reference_mask.pixels, COVERAGE_THRESHOLD);

    let (_repaired, candidate_mask) =
        render_ice_candidate(slot).expect("render_ice_candidate should succeed against the real corpus");
    let candidate_pixels: Vec<f32> = candidate_mask
        .pixels
        .iter()
        .map(|&value| value as f32 / 65535.0)
        .collect();
    let candidate_fraction = fraction_above_threshold(&candidate_pixels, COVERAGE_THRESHOLD);

    let candidate_normalized = image_io::NormalizedMask {
        width: candidate_mask.width,
        height: candidate_mask.height,
        pixels: candidate_pixels,
    };
    let agreement =
        scoring::score_ice_mask_agreement(&candidate_normalized, &reference_mask, COVERAGE_THRESHOLD)
            .expect("score_ice_mask_agreement should succeed when candidate/reference dimensions match");

    // Deliberate eprintln! on success — this is the investigation's real,
    // reproducible evidence (T-16-10), recorded in this plan's own SUMMARY
    // and PARITY.md, not just observed once and discarded.
    eprintln!(
        "reference_mask_coverage_sanity_check: slot 1 — corpus-bundled HYBRID disclosure mask coverage = {:.6}% ({} of {} pixels >= {COVERAGE_THRESHOLD}); this Legacy-port DefectMap coverage = {:.6}% ({} of {} pixels >= {COVERAGE_THRESHOLD}); Jaccard agreement between them = {:.6} (ICE_MASK_AGREEMENT_THRESHOLD = {})",
        reference_fraction * 100.0,
        (reference_fraction * reference_mask.pixels.len() as f64).round() as u64,
        reference_mask.pixels.len(),
        candidate_fraction * 100.0,
        (candidate_fraction * candidate_mask.pixels.len() as f64).round() as u64,
        candidate_mask.pixels.len(),
        agreement,
        scoring::ICE_MASK_AGREEMENT_THRESHOLD,
    );

    assert!(
        reference_fraction.is_finite() && (0.0..=1.0).contains(&reference_fraction),
        "reference coverage fraction must be a finite value in [0.0, 1.0], got {reference_fraction}"
    );
    assert!(
        candidate_fraction.is_finite() && (0.0..=1.0).contains(&candidate_fraction),
        "candidate coverage fraction must be a finite value in [0.0, 1.0], got {candidate_fraction}"
    );
    assert!(
        agreement.is_finite() && (0.0..=1.0).contains(&agreement),
        "Jaccard agreement must be a finite value in [0.0, 1.0], got {agreement}"
    );
}

fn fraction_above_threshold(pixels: &[f32], threshold: f32) -> f64 {
    let above = pixels.iter().filter(|&&value| value >= threshold).count();
    above as f64 / pixels.len().max(1) as f64
}
