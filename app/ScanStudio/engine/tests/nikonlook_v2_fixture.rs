//! Env-gated integration test for nikonlook v2 against a real ScanStudio
//! archive and its registered Nikon Scan reference render — following
//! `tests/real_derivative_backfill.rs`'s env-gated pattern (`#[ignore]`d by
//! default; normal `cargo test` runs never depend on files this test
//! needs). Proves the numbers cited in `resources/nikonlook-v2/
//! PROVENANCE.md` and the module doc comment in
//! `src/processing/nikonlook.rs`: v2's blind path measures materially
//! closer to Nikon Scan's own render than v1 did, on the same live frame.

use scanstudio_engine::parity::image_io::{read_rgb16, Rgb16Image};
use scanstudio_engine::processing::nikonlook;

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
/// v1's, so this is also Group F's/Group A's pinned v1 literal).
const R_CURVE_GRID_Y0: f64 = 0.8745168478139992;

const MARGIN: u32 = 200;
const STEP: u32 = 5;

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
    let raw_linear = to_raw_linear(&archive);

    let bundle = nikonlook::load_bundle().expect("real v2 bundle must load");

    let k_blind = nikonlook::estimate_gains(&raw_linear, archive.width as usize, None, &bundle)
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

    let k_exposure = nikonlook::estimate_gains(
        &raw_linear,
        archive.width as usize,
        Some(EXPOSURE_10NS_FRAME5),
        &bundle,
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

    let rendered = nikonlook::apply(&raw_linear, k_blind, &bundle);

    // Registered interior grid: sample every STEP-th pixel at least MARGIN
    // from the archive's own edges, mapping each archive (y, x) to the
    // Nikon reference's (y + dy, x + dx) -- the fixed registration shift
    // between the two rasters. Points whose shifted coordinate falls
    // outside the reference are skipped rather than clamped, so a wrong
    // dy/dx cannot silently compare the wrong pixels.
    let mut abs_diff: [Vec<f64>; 3] = [Vec::new(), Vec::new(), Vec::new()];
    let mut r_pinned = 0usize;
    let mut sampled = 0usize;

    let y_end = archive.height.saturating_sub(MARGIN);
    let x_end = archive.width.saturating_sub(MARGIN);
    let mut y = MARGIN;
    while y < y_end {
        let mut x = MARGIN;
        while x < x_end {
            let ref_y = y as i64 + dy;
            let ref_x = x as i64 + dx;
            if ref_y >= 0 && ref_x >= 0 && (ref_y as u32) < nikon_ref.height && (ref_x as u32) < nikon_ref.width {
                let rendered_px = rendered[(y * archive.width + x) as usize];
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
    let med_abs = [median(d0), median(d1), median(d2)];
    // Measured 2026-07-28: medAbs [3565, 6682, 3340], pinned R 0.0553.
    // Thresholds below have headroom but would catch a v1-style
    // regression ([19463, 14040, 17347] / 0.165).
    let thresholds = [6000.0, 8000.0, 6000.0];
    for c in 0..3 {
        assert!(
            med_abs[c] <= thresholds[c],
            "channel {c} median |delta| {} DN exceeds threshold {} DN",
            med_abs[c],
            thresholds[c]
        );
    }

    let r_pinned_fraction = r_pinned as f64 / sampled as f64;
    assert!(
        r_pinned_fraction <= 0.08,
        "R pinned-at-floor fraction {r_pinned_fraction} exceeds 0.08 ({r_pinned}/{sampled} sampled pixels)"
    );
}
