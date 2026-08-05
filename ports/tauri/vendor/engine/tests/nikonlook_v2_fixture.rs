//! Env-gated integration test for nikonlook v2 against a real ScanStudio
//! archive and its registered Nikon Scan reference render — following
//! `tests/real_derivative_backfill.rs`'s env-gated pattern (`#[ignore]`d by
//! default; normal `cargo test` runs never depend on files this test
//! needs).
//!
//! What this test actually proves, on one real frame ("SCANSTUDIO5"):
//! it renders both supported v2 Layer-A paths — blind
//! `log-ridge-raw-features-v1` and `inverse-hardware-exposure-v1` — through
//! the real `estimate_gains` -> `apply` chain and diffs each render against
//! the registered Nikon Scan reference on the same sampling grid. The
//! retired v1 runtime was deliberately removed; this fixture does not
//! restore it just to recreate a historical comparison. Before scoring, it
//! verifies the archive and Nikon
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
const K_EXPOSURE_SCANSTUDIO5: [f64; 3] =
    [0.5764822683598294, 0.22818411954519974, 0.2620541212542383];

/// R curve's grid_y[0] (the floor any underflowing input clamps to) — same
/// literal as `nikonlook.rs`'s in-module Group I test. There is no public
/// accessor for bundle curve data outside `processing::nikonlook`
/// (`Bundle.curves` is a private field), so this is hardcoded against the
/// vendored, never-hand-edited nikonlook-v2 model.json (see
/// `resources/nikonlook-v2/PROVENANCE.md` — Layer B is byte-identical to
/// the historical bundle, so this remains the pinned v2 literal).
const R_CURVE_GRID_Y0: f64 = 0.8745168478139992;

const MARGIN: u32 = 200;
const STEP: u32 = 5;

/// Regression ceilings, DN (16-bit full-scale), with headroom over the
/// 2026-07-28 measured values in `resources/nikonlook-v2/PROVENANCE.md`'s
/// table (v2 blind [3565, 6682, 3340]; v2 exposure [9560, 8064, 3454]) —
/// tight enough to catch a real regression, loose enough to absorb
/// legitimate measurement noise (float accumulation order, a different
/// but equally valid registration dy/dx).
const V2_BLIND_CEILING_DN: [f64; 3] = [4300.0, 8000.0, 4000.0];
const V2_EXPOSURE_CEILING_DN: [f64; 3] = [12500.0, 10500.0, 4500.0];

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
fn assert_expected_content_hash(
    actual: &str,
    expected: Option<&str>,
    env_var_name: &str,
    label: &str,
) {
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
    assert_expected_content_hash(
        "abc123",
        Some("abc123"),
        "SCANSTUDIO_TEST_EXAMPLE_SHA256",
        "example",
    );

    let mismatch = std::panic::catch_unwind(|| {
        assert_expected_content_hash(
            "abc123",
            Some("def456"),
            "SCANSTUDIO_TEST_EXAMPLE_SHA256",
            "example",
        )
    });
    assert!(
        mismatch.is_err(),
        "a wrong expected hash must panic, not silently pass"
    );

    let missing = std::panic::catch_unwind(|| {
        assert_expected_content_hash("abc123", None, "SCANSTUDIO_TEST_EXAMPLE_SHA256", "example")
    });
    assert!(
        missing.is_err(),
        "an unset expected-hash env var must panic, not silently pass"
    );
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
            if ref_y >= 0
                && ref_x >= 0
                && (ref_y as u32) < nikon_ref.height
                && (ref_x as u32) < nikon_ref.width
            {
                let rendered_px = rendered[(y * archive_width + x) as usize];
                let ref_px =
                    nikon_ref.pixels[(ref_y as u32 * nikon_ref.width + ref_x as u32) as usize];
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
    assert!(
        sampled > 0,
        "registration grid produced zero in-bounds sample points -- check dy/dx"
    );

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
    let nikon_ref_path =
        std::env::var("SCANSTUDIO_TEST_NIKON_REF_TIF").expect("set SCANSTUDIO_TEST_NIKON_REF_TIF");
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
        std::env::var("SCANSTUDIO_TEST_ARCHIVE_SHA256")
            .ok()
            .as_deref(),
        "SCANSTUDIO_TEST_ARCHIVE_SHA256",
        "archive",
    );
    assert_expected_content_hash(
        &content_hash(&nikon_ref),
        std::env::var("SCANSTUDIO_TEST_NIKON_REF_SHA256")
            .ok()
            .as_deref(),
        "SCANSTUDIO_TEST_NIKON_REF_SHA256",
        "Nikon reference",
    );

    let raw_linear = to_raw_linear(&archive);
    let bundle_v2 = nikonlook::load_bundle().expect("real v2 bundle must load");

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
    let agreement_blind = measure_agreement(
        &rendered_blind,
        archive.width,
        archive.height,
        &nikon_ref,
        dy,
        dx,
    );

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
    let agreement_exposure = measure_agreement(
        &rendered_exposure,
        archive.width,
        archive.height,
        &nikon_ref,
        dy,
        dx,
    );

    // Both v2 renders must use the same meaningful registration grid.
    assert_eq!(
        agreement_blind.sampled, agreement_exposure.sampled,
        "v2 blind and exposure renders must sample the identical registration grid"
    );
    assert!(
        agreement_blind.sampled >= 1000,
        "registration grid sampled only {} points -- too few for the median-based \
         comparisons below to be statistically meaningful",
        agreement_blind.sampled
    );

    assert!((0.0..=1.0).contains(&agreement_blind.r_pinned_fraction));
    assert!((0.0..=1.0).contains(&agreement_exposure.r_pinned_fraction));

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
