//! Env-gated integration test for nikonlook v2 against a real ScanStudio
//! archive and its registered Nikon Scan reference render — following
//! `tests/real_derivative_backfill.rs`'s env-gated pattern (`#[ignore]`d by
//! default; normal `cargo test` runs never depend on files this test
//! needs).
//!
//! What this test actually proves, on one real frame ("SCANSTUDIO5"):
//! it renders all three Layer-A paths `nikonlook_core.py`/`nikonlook.rs`
//! support — v1's `percentile-stopgap-v1`, v2's blind
//! `log-ridge-raw-features-v1`, and v2's `inverse-hardware-exposure-v1` —
//! through the real `estimate_gains` -> `apply` chain, diffs each render's
//! interior pixels against the registered Nikon Scan reference on the same
//! sampling grid, and asserts v2's blind path is MATERIALLY closer than
//! v1's (not just under a loose ceiling): this is the actual comparison
//! `resources/nikonlook-v2/PROVENANCE.md` and `src/processing/nikonlook.rs`'s
//! module doc comment cite, not merely a single-path sanity check dressed
//! up as one. Before any of that: it verifies the archive and Nikon
//! reference files it was pointed at are the exact ones this test's
//! frame-specific literals were harvested from, via a content hash of each
//! file's decoded pixels — so pointing the path env vars at an unrelated
//! file fails loudly on that check, not on a confusing downstream number
//! mismatch (or, worse, a coincidental pass).

use scanstudio_engine::parity::image_io::{read_rgb16, Rgb16Image};
use scanstudio_engine::processing::nikonlook;
use sha2::{Digest, Sha256};

/// Same literal as the frame-5 hardware exposure ticks used by
/// `nikonlook.rs`'s in-module Group J test — the exposure path is
/// raw-independent, so this real-archive test exercises it with the same
/// constant regardless of which archive frame the env vars point at.
const EXPOSURE_10NS_FRAME5: [f64; 3] = [127992.0, 312892.0, 259345.0];

const K_BLIND_SCANSTUDIO5: [f64; 3] = [0.7767985641162477, 0.49546023790785987, 0.2824666578885106];
const K_EXPOSURE_SCANSTUDIO5: [f64; 3] = [0.5764822683598294, 0.22818411954519974, 0.2620541212542383];

/// R curve's grid_y[0] (the floor any underflowing input clamps to) — same
/// literal as `nikonlook.rs`'s in-module Group I test. There is no public
/// accessor for bundle curve data outside `processing::nikonlook`
/// (`Bundle.curves` is a private field), so this is hardcoded against the
/// vendored, never-hand-edited nikonlook-v2 model.json (see
/// `resources/nikonlook-v2/PROVENANCE.md` — Layer B is byte-identical to
/// v1's, so this is also Group F's/Group A's pinned v1 literal, and the
/// same floor applies to a v1 render just as much as a v2 one).
const R_CURVE_GRID_Y0: f64 = 0.8745168478139992;

const MARGIN: u32 = 200;
const STEP: u32 = 5;

/// Regression ceilings, DN (16-bit full-scale), with headroom over the
/// 2026-07-28 measured values in `resources/nikonlook-v2/PROVENANCE.md`'s
/// table (v2 blind [3565, 6682, 3340]; v2 exposure [9560, 8064, 3454]) —
/// tight enough to catch a real regression, loose enough to absorb
/// legitimate measurement noise (float accumulation order, a different
/// but equally valid registration dy/dx). These are a supplementary
/// regression guard; the comparative assertion against a genuinely
/// rendered v1 (below) is the primary proof of "v2 is materially better."
const V2_BLIND_CEILING_DN: [f64; 3] = [4300.0, 8000.0, 4000.0];
const V2_EXPOSURE_CEILING_DN: [f64; 3] = [12500.0, 10500.0, 4500.0];

/// How much lower v2's median |delta| must be than v1's, per channel, to
/// count as "materially" closer rather than a coincidental few-DN
/// improvement. 0.75 (v2 must be at least 25% better) is deliberately
/// generous: the measured ratios are far larger (v2 blind is roughly
/// 2x-5x better than v1 across channels per PROVENANCE.md), so this bar
/// has wide headroom while still catching a real regression that erodes
/// most of v2's advantage.
const MATERIALLY_LOWER_RATIO: f64 = 0.75;

fn to_raw_linear(image: &Rgb16Image) -> Vec<[f64; 3]> {
    image
        .pixels
        .iter()
        .map(|pixel| {
            [
                pixel[0] as f64 / 65535.0,
                pixel[1] as f64 / 65535.0,
                pixel[2] as f64 / 65535.0,
            ]
        })
        .collect()
}

/// Median of a sample via a sort — fine at the grid's sample count (a few
/// thousand points at most for a full-frame archive).
fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    let n = values.len();
    assert!(n > 0, "median of an empty sample");
    if n % 2 == 1 {
        values[n / 2]
    } else {
        (values[n / 2 - 1] + values[n / 2]) / 2.0
    }
}

// ---------------------------------------------------------------------
// Input-identity guard (Finding 3): a content hash of each decoded image
// (dimensions + pixels, not the raw file bytes -- a lossless re-save under
// different TIFF compression settings still matches), checked against an
// operator-pinned expected value before any frame-specific numeric
// assertion runs.
// ---------------------------------------------------------------------

fn content_hash(image: &Rgb16Image) -> String {
    let mut hasher = Sha256::new();
    hasher.update(image.width.to_le_bytes());
    hasher.update(image.height.to_le_bytes());
    for pixel in &image.pixels {
        for channel in pixel {
            hasher.update(channel.to_le_bytes());
        }
    }
    format!("{:x}", hasher.finalize())
}

/// `expected` is already resolved from an env var by the caller (kept as a
/// plain parameter, not read here, so this function is a pure panic/no-panic
/// decision and can be unit-tested without touching global process state).
/// Panics on a mismatch (wrong file — names the field, shows both hashes)
/// or on `None` (not yet pinned — shows the computed hash so a first run
/// can bootstrap the expected value); never silently proceeds either way.
fn assert_expected_content_hash(actual: &str, expected: Option<&str>, env_var_name: &str, label: &str) {
    match expected {
        Some(expected) if expected == actual => {}
        Some(expected) => panic!(
            "{label} content hash mismatch: {env_var_name}={expected:?} but the file at the \
             configured path decodes to {actual:?}. This test's frame-specific literals \
             (K_BLIND_SCANSTUDIO5, K_EXPOSURE_SCANSTUDIO5, the regression ceilings) were \
             harvested from ONE specific frame -- pointing the path env var at a different \
             file must fail here, not produce a coincidental pass or a confusing downstream \
             number mismatch."
        ),
        None => panic!(
            "{env_var_name} is not set. Refusing to run frame-specific assertions against an \
             unpinned {label} file. This run's file decodes to content hash {actual:?} -- if \
             this is the expected SCANSTUDIO5 frame, set {env_var_name}={actual} and re-run."
        ),
    }
}

#[test]
fn assert_expected_content_hash_accepts_match_and_rejects_mismatch_or_missing() {
    assert_expected_content_hash("abc123", Some("abc123"), "SCANSTUDIO_TEST_EXAMPLE_SHA256", "example");

    let mismatch = std::panic::catch_unwind(|| {
        assert_expected_content_hash("abc123", Some("def456"), "SCANSTUDIO_TEST_EXAMPLE_SHA256", "example")
    });
    assert!(mismatch.is_err(), "a wrong expected hash must panic, not silently pass");

    let missing = std::panic::catch_unwind(|| {
        assert_expected_content_hash("abc123", None, "SCANSTUDIO_TEST_EXAMPLE_SHA256", "example")
    });
    assert!(missing.is_err(), "an unset expected-hash env var must panic, not silently pass");
}

// ---------------------------------------------------------------------
// Registered-grid agreement measurement, shared by all three rendered
// paths below so the loop logic isn't tripled.
// ---------------------------------------------------------------------

struct Agreement {
    /// Per-channel median absolute difference, in DN (16-bit full-scale).
    median_abs_diff_dn: [f64; 3],
    /// Fraction of sampled pixels whose R channel is pinned at the R
    /// curve's floor (`R_CURVE_GRID_Y0`) -- a proxy for "how often this
    /// path pushes the gain low enough to underflow the curve," which
    /// PROVENANCE.md's table also reports per path.
    r_pinned_fraction: f64,
    sampled: usize,
}

/// Registered interior grid: sample every STEP-th pixel at least MARGIN
/// from the archive's own edges, mapping each archive (y, x) to the Nikon
/// reference's (y + dy, x + dx) -- the fixed registration shift between
/// the two rasters. Points whose shifted coordinate falls outside the
/// reference are skipped rather than clamped, so a wrong dy/dx cannot
/// silently compare the wrong pixels.
fn measure_agreement(
    rendered: &[[f64; 3]],
    archive_width: u32,
    archive_height: u32,
    nikon_ref: &Rgb16Image,
    dy: i64,
    dx: i64,
) -> Agreement {
    let mut abs_diff: [Vec<f64>; 3] = [Vec::new(), Vec::new(), Vec::new()];
    let mut r_pinned = 0usize;
    let mut sampled = 0usize;

    let y_end = archive_height.saturating_sub(MARGIN);
    let x_end = archive_width.saturating_sub(MARGIN);
    let mut y = MARGIN;
    while y < y_end {
        let mut x = MARGIN;
        while x < x_end {
            let ref_y = y as i64 + dy;
            let ref_x = x as i64 + dx;
            if ref_y >= 0 && ref_x >= 0 && (ref_y as u32) < nikon_ref.height && (ref_x as u32) < nikon_ref.width {
                let rendered_px = rendered[(y * archive_width + x) as usize];
                let ref_px = nikon_ref.pixels[(ref_y as u32 * nikon_ref.width + ref_x as u32) as usize];
                for c in 0..3 {
                    let rendered_dn = rendered_px[c] * 65535.0;
                    let ref_dn = ref_px[c] as f64;
                    abs_diff[c].push((rendered_dn - ref_dn).abs());
                }
                if (rendered_px[0] * 65535.0 - R_CURVE_GRID_Y0 * 65535.0).abs() < 1.0 {
                    r_pinned += 1;
                }
                sampled += 1;
            }
            x += STEP;
        }
        y += STEP;
    }
    assert!(sampled > 0, "registration grid produced zero in-bounds sample points -- check dy/dx");

    let [d0, d1, d2] = abs_diff;
    Agreement {
        median_abs_diff_dn: [median(d0), median(d1), median(d2)],
        r_pinned_fraction: r_pinned as f64 / sampled as f64,
        sampled,
    }
}

#[test]
#[ignore = "requires explicit real-archive environment variables"]
fn nikonlook_v2_blind_render_tracks_the_nikon_reference_on_a_real_frame() {
    let archive_path =
        std::env::var("SCANSTUDIO_TEST_ARCHIVE_TIF").expect("set SCANSTUDIO_TEST_ARCHIVE_TIF");
    let nikon_ref_path = std::env::var("SCANSTUDIO_TEST_NIKON_REF_TIF")
        .expect("set SCANSTUDIO_TEST_NIKON_REF_TIF");
    let dy: i64 = std::env::var("SCANSTUDIO_TEST_REG_DY")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(-4);
    let dx: i64 = std::env::var("SCANSTUDIO_TEST_REG_DX")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(-12);

    let archive = read_rgb16(std::path::Path::new(&archive_path)).expect("archive TIF must decode");
    let nikon_ref =
        read_rgb16(std::path::Path::new(&nikon_ref_path)).expect("Nikon reference TIF must decode");

    // Input-identity guard -- must run before any frame-specific numeric
    // assertion below (see this module's doc comment and Finding 3).
    assert_expected_content_hash(
        &content_hash(&archive),
        std::env::var("SCANSTUDIO_TEST_ARCHIVE_SHA256").ok().as_deref(),
        "SCANSTUDIO_TEST_ARCHIVE_SHA256",
        "archive",
    );
    assert_expected_content_hash(
        &content_hash(&nikon_ref),
        std::env::var("SCANSTUDIO_TEST_NIKON_REF_SHA256").ok().as_deref(),
        "SCANSTUDIO_TEST_NIKON_REF_SHA256",
        "Nikon reference",
    );

    let raw_linear = to_raw_linear(&archive);
    let bundle_v2 = nikonlook::load_bundle().expect("real v2 bundle must load");
    let bundle_v1 = nikonlook::load_bundle_v1().expect("real v1 bundle must load");

    // -- v1: percentile-stopgap-v1. No exact gain literal to pin (this
    // fixture's original author never harvested one), so this path is
    // proven purely by the comparative assertions below, not an exact
    // number -- inventing an unverifiable literal would be worse than not
    // having one.
    let k_v1 = nikonlook::estimate_gains(&raw_linear, archive.width as usize, None, &bundle_v1)
        .expect("v1 estimate_gains never fails");
    let rendered_v1 = nikonlook::apply(&raw_linear, k_v1, &bundle_v1);
    let agreement_v1 = measure_agreement(&rendered_v1, archive.width, archive.height, &nikon_ref, dy, dx);

    // -- v2 blind: log-ridge-raw-features-v1 (the production default path
    // when no exposure metadata is supplied).
    let k_blind = nikonlook::estimate_gains(&raw_linear, archive.width as usize, None, &bundle_v2)
        .expect("blind gain estimation must succeed on a real archive");
    for c in 0..3 {
        let diff = (k_blind[c] - K_BLIND_SCANSTUDIO5[c]).abs();
        assert!(
            diff < 1e-6,
            "blind gain[{c}]: expected {}, got {} (diff {diff})",
            K_BLIND_SCANSTUDIO5[c],
            k_blind[c]
        );
    }
    let rendered_blind = nikonlook::apply(&raw_linear, k_blind, &bundle_v2);
    let agreement_blind = measure_agreement(&rendered_blind, archive.width, archive.height, &nikon_ref, dy, dx);

    // -- v2 exposure: inverse-hardware-exposure-v1. Previously computed but
    // never actually rendered or compared against the reference (Finding
    // 3) -- now genuinely proven like the other two paths.
    let k_exposure = nikonlook::estimate_gains(
        &raw_linear,
        archive.width as usize,
        Some(EXPOSURE_10NS_FRAME5),
        &bundle_v2,
    )
    .expect("exposure gain estimation never fails");
    for c in 0..3 {
        let diff = (k_exposure[c] - K_EXPOSURE_SCANSTUDIO5[c]).abs();
        assert!(
            diff < 1e-9,
            "exposure gain[{c}]: expected {}, got {} (diff {diff})",
            K_EXPOSURE_SCANSTUDIO5[c],
            k_exposure[c]
        );
    }
    let rendered_exposure = nikonlook::apply(&raw_linear, k_exposure, &bundle_v2);
    let agreement_exposure =
        measure_agreement(&rendered_exposure, archive.width, archive.height, &nikon_ref, dy, dx);

    // Not `sampled > 0` -- `measure_agreement` already asserts that
    // internally on every call (see its own doc comment), so repeating it
    // here could never fail regardless of what this test's logic actually
    // did. What isn't already guaranteed: all three renders share the same
    // archive dimensions and the same fixed dy/dx, so their in-bounds
    // sample counts must be identical to each other (a future edit that
    // accidentally passed mismatched dimensions to one of the three
    // `measure_agreement` calls would silently compare each render against
    // a different-sized sample without this); and the shared count must be
    // large enough for the median-based comparisons below to mean anything
    // -- a technically-nonzero but tiny sample would make those medians
    // noise, not signal.
    assert_eq!(
        agreement_v1.sampled, agreement_blind.sampled,
        "v1 and v2-blind must sample the identical registration grid"
    );
    assert_eq!(
        agreement_v1.sampled, agreement_exposure.sampled,
        "v1 and v2-exposure must sample the identical registration grid"
    );
    assert!(
        agreement_v1.sampled >= 1000,
        "registration grid sampled only {} points -- too few for the median-based \
         comparisons below to be statistically meaningful",
        agreement_v1.sampled
    );

    // Primary proof: v2 blind is MATERIALLY closer to the Nikon reference
    // than v1, per channel -- not just under a loose absolute ceiling. This
    // is the actual "v1-vs-v2 comparison table" this module's doc comment
    // and PROVENANCE.md describe.
    for c in 0..3 {
        let v1 = agreement_v1.median_abs_diff_dn[c];
        let v2 = agreement_blind.median_abs_diff_dn[c];
        assert!(
            v2 <= v1 * MATERIALLY_LOWER_RATIO,
            "channel {c}: v2 blind median |delta| {v2} DN is not materially lower than v1's {v1} DN \
             (required <= {}% of v1)",
            MATERIALLY_LOWER_RATIO * 100.0
        );
    }
    assert!(
        agreement_blind.r_pinned_fraction < agreement_v1.r_pinned_fraction,
        "v2 blind R-pinned fraction {} must be lower than v1's {}",
        agreement_blind.r_pinned_fraction,
        agreement_v1.r_pinned_fraction
    );

    // v2 exposure must also materially beat v1 (PROVENANCE.md measured it
    // as an improvement over v1 on every channel, just not as large a one
    // as blind) -- proves the exposure path isn't silently broken, without
    // requiring it to beat blind (it measurably doesn't, on B).
    for c in 0..3 {
        let v1 = agreement_v1.median_abs_diff_dn[c];
        let exposure = agreement_exposure.median_abs_diff_dn[c];
        assert!(
            exposure <= v1 * MATERIALLY_LOWER_RATIO,
            "channel {c}: v2 exposure median |delta| {exposure} DN is not materially lower than v1's {v1} DN"
        );
    }

    // Supplementary absolute regression ceilings (secondary to the
    // comparative proof above -- see the constants' own doc comment).
    for c in 0..3 {
        assert!(
            agreement_blind.median_abs_diff_dn[c] <= V2_BLIND_CEILING_DN[c],
            "channel {c}: v2 blind median |delta| {} DN exceeds ceiling {} DN",
            agreement_blind.median_abs_diff_dn[c],
            V2_BLIND_CEILING_DN[c]
        );
        assert!(
            agreement_exposure.median_abs_diff_dn[c] <= V2_EXPOSURE_CEILING_DN[c],
            "channel {c}: v2 exposure median |delta| {} DN exceeds ceiling {} DN",
            agreement_exposure.median_abs_diff_dn[c],
            V2_EXPOSURE_CEILING_DN[c]
        );
    }
    assert!(
        agreement_blind.r_pinned_fraction <= 0.08,
        "v2 blind R-pinned-at-floor fraction {} exceeds 0.08",
        agreement_blind.r_pinned_fraction
    );
}
