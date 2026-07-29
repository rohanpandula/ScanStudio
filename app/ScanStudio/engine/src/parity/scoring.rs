//! Per-module parity scorers with tunable, rationale-documented thresholds.
//! Every scorer here measures agreement between a Rust-port candidate and a
//! reference render — see each threshold's doc comment for what
//! "agreement" means for that module and why the threshold sits where it
//! does.

use crate::parity::image_io::{NormalizedMask, Rgb16Image};
use crate::parity::types::ParityError;

// ---------------------------------------------------------------------
// Thresholds
// ---------------------------------------------------------------------

/// ~0.012% of the 65535 full-scale range; generous enough to absorb
/// f32-vs-f64 or accumulation-order differences between the Python
/// reference and a future Rust port of the *same* nikonlook algorithm,
/// tight enough to catch a real logic bug. This measures Rust-port
/// fidelity to the Python `nikonlook_core` reference render, not
/// real-world accuracy against true Nikon Scan color — the nikonlook
/// bundles' own `manifest.json` (Layer B: shared, unchanged across bundle
/// versions) documents a 3.55 ΔE00 gap against true Nikon color at best
/// (see PARITY.md from plan 13-02), which is a separate, orthogonal
/// quality question this threshold does not address.
pub const COLOR_PER_CHANNEL_TOLERANCE_U16: u16 = 8;

/// Same port-fidelity framing as `COLOR_PER_CHANNEL_TOLERANCE_U16`; 0.5 is
/// well under the ~1.0 "just noticeable difference" convention, appropriate
/// when comparing two implementations of the same algorithm on the same
/// input rather than measuring perceptual accuracy against ground truth.
/// That framing only holds when candidate and reference actually ARE the
/// same algorithm/bundle — `bin/parity.rs`'s `score_color` derives the
/// reference filename from the loaded bundle's own `bundle_version` rather
/// than a fixed literal specifically so this threshold can never end up
/// silently comparing two different bundle versions' output against each
/// other (see that function's own doc comment).
pub const COLOR_DELTA_E76_TOLERANCE: f64 = 0.5;

/// Validated against the real six-slot corpus by plan 15-02 (see
/// PARITY.md §5 for the full writeup). 5 of 6 slots score a PERFECT
/// `1.0` IoU against the real `render_geometry_references.py` reference
/// (Image mode) at the original placeholder value (`0.98`) -- strong
/// evidence the port itself is highly faithful. Slot 3 alone measured
/// `0.9432`, root-caused to real, verified `imageproc`-vs-`cv2` numerical
/// differences in the contour-detection path (NOT a logic bug): two
/// distinct bugs were found and fixed during this investigation (a
/// channel-order swap in the BGR2GRAY-equivalent conversion, and a
/// binary-vs-grayscale morphology mismatch in the blackhat mask) which
/// together closed most of slot 3's gap (`0.879` -> `0.9432`); the
/// remaining residual traces to `imageproc::edges::canny` producing a
/// measurably different edge map than `cv2.Canny` on this specific
/// slot's content, which is expected cross-library algorithm variance for
/// a multi-stage edge detector, not a further fixable defect. Lowered
/// from `0.98` to `0.93`: comfortably below the measured `0.9432` (a few
/// points of headroom for `imageproc`'s Otsu-level/contour-tracing noise,
/// which measured about 1 level off cv2's own Otsu in this
/// investigation) while remaining far above any value a genuinely broken
/// detection (wrong region, wrong mode, mis-scaled ROI) would produce --
/// those show IoU well under 0.5 in practice, so 0.93 still catches real
/// regressions on all six slots, including the five that hit `1.0`
/// exactly.
pub const AUTOCROP_IOU_THRESHOLD: f64 = 0.93;

/// Validated against the real six-slot corpus by plan 15-02 and left
/// UNCHANGED at its original placeholder value: this row is a
/// rotation-matrix angle-provenance check (both sides decompose
/// `rotation_matrix_2x3`'s own closed-form output via the same `atan2`
/// formula, no image resampling involved -- see PARITY.md and
/// `<deskew_metric_design_rationale>`), so it carries none of
/// `AUTOCROP_IOU_THRESHOLD`'s contour-detection numerical noise. Measured
/// `deskew_angle_degrees` on all six real slots: `~2.22e-16` (IEEE-754
/// double epsilon) -- effectively exact agreement, ~2.3e14x tighter than
/// this 0.05-degree threshold, with zero headroom needed.
pub const DESKEW_ANGLE_EPSILON_DEGREES: f64 = 0.05;

/// Set lower than the geometry/color thresholds deliberately — the only
/// mask data available in the corpus was produced in `hybrid` (ML-assisted)
/// mode, while Phase 16 ports Legacy (classical) ICE only; some divergence
/// between a correct Legacy port and this hybrid-mode mask is expected and
/// does not necessarily indicate a bug (see PARITY.md).
pub const ICE_MASK_AGREEMENT_THRESHOLD: f64 = 0.85;

// ---------------------------------------------------------------------
// Color
// ---------------------------------------------------------------------

/// Color agreement between a candidate and reference RGB render.
#[derive(Debug, Clone, Copy)]
pub struct ColorScore {
    pub max_channel_diff_u16: u16,
    pub delta_e76: f64,
}

/// Adobe RGB (1998) gamma-decode, then linear RGB -> XYZ (D65) -> CIE Lab,
/// for one normalized-`[0.0, 1.0]` RGB triple. Called once per image (on
/// its mean pixel), not per-pixel, so `score_color` stays fast.
fn adobe_rgb_to_lab(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    // Step 1: Adobe RGB (1998) pure power-law gamma decode.
    let gamma = |channel: f64| channel.powf(2.19921875);
    let (rl, gl, bl) = (gamma(r), gamma(g), gamma(b));

    // Step 2: linear RGB -> XYZ, Adobe RGB (1998) D65 matrix. For RGB
    // normalized to [0.0, 1.0] this matrix (rows sum to ~1.0) yields X/Y/Z
    // on the same relative scale (white -> Y=1.0). Multiply by 100.0 so
    // X/Y/Z land on the conventional 0-100 XYZ scale that the white point
    // below is quoted on (Yn=100.0) — required for the ratios in step 3 to
    // be meaningful (white must map to X/Xn = Y/Yn = Z/Zn = 1.0).
    let x = (0.5767309 * rl + 0.1855540 * gl + 0.1881852 * bl) * 100.0;
    let y = (0.2973769 * rl + 0.6273491 * gl + 0.0752741 * bl) * 100.0;
    let z = (0.0270343 * rl + 0.0706872 * gl + 0.9911085 * bl) * 100.0;

    // Step 3: XYZ -> Lab, D65 white point, standard CIE piecewise function.
    const XN: f64 = 95.0429;
    const YN: f64 = 100.0;
    const ZN: f64 = 108.8900;
    let f = |t: f64| {
        const DELTA: f64 = 6.0 / 29.0;
        if t > DELTA.powi(3) {
            t.powf(1.0 / 3.0)
        } else {
            t / (3.0 * DELTA * DELTA) + 4.0 / 29.0
        }
    };
    let (fx, fy, fz) = (f(x / XN), f(y / YN), f(z / ZN));

    let l = 116.0 * fy - 16.0;
    let a = 500.0 * (fx - fy);
    let bb = 200.0 * (fy - fz);
    (l, a, bb)
}

/// Mean-pixel color agreement: per-channel max-abs-diff (u16 full-scale)
/// plus a single-scalar ΔE76 computed on each image's mean pixel (not
/// per-pixel — this keeps the harness fast and simple; see
/// `COLOR_DELTA_E76_TOLERANCE`'s doc comment for what this threshold does
/// and does not measure).
pub fn score_color(
    candidate: &Rgb16Image,
    reference: &Rgb16Image,
) -> Result<ColorScore, ParityError> {
    if candidate.width != reference.width || candidate.height != reference.height {
        return Err(ParityError::Decode(format!(
            "score_color: dimension mismatch — candidate {}x{}, reference {}x{}",
            candidate.width, candidate.height, reference.width, reference.height
        )));
    }

    let mut max_channel_diff_u16: u16 = 0;
    for (candidate_pixel, reference_pixel) in candidate.pixels.iter().zip(reference.pixels.iter())
    {
        for channel in 0..3 {
            let diff = candidate_pixel[channel].abs_diff(reference_pixel[channel]);
            if diff > max_channel_diff_u16 {
                max_channel_diff_u16 = diff;
            }
        }
    }

    let mean_pixel = |pixels: &[[u16; 3]]| -> (f64, f64, f64) {
        let count = (pixels.len().max(1)) as f64;
        let (mut r_sum, mut g_sum, mut b_sum) = (0.0f64, 0.0f64, 0.0f64);
        for pixel in pixels {
            r_sum += pixel[0] as f64;
            g_sum += pixel[1] as f64;
            b_sum += pixel[2] as f64;
        }
        (
            r_sum / count / 65535.0,
            g_sum / count / 65535.0,
            b_sum / count / 65535.0,
        )
    };

    let (cr, cg, cb) = mean_pixel(&candidate.pixels);
    let (rr, rg, rb) = mean_pixel(&reference.pixels);
    let candidate_lab = adobe_rgb_to_lab(cr, cg, cb);
    let reference_lab = adobe_rgb_to_lab(rr, rg, rb);
    let delta_e76 = ((candidate_lab.0 - reference_lab.0).powi(2)
        + (candidate_lab.1 - reference_lab.1).powi(2)
        + (candidate_lab.2 - reference_lab.2).powi(2))
    .sqrt();

    Ok(ColorScore {
        max_channel_diff_u16,
        delta_e76,
    })
}

// ---------------------------------------------------------------------
// Autocrop
// ---------------------------------------------------------------------

/// An axis-aligned crop rectangle, in source-image pixel coordinates.
#[derive(Debug, Clone, Copy)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

/// Axis-aligned intersection-over-union between two crop rectangles.
/// Returns `0.0` if there is no overlap. If both rectangles are zero-area,
/// returns `1.0` (degenerate agreement case — nothing to disagree about).
pub fn score_crop_iou(candidate: Rect, reference: Rect) -> f64 {
    let candidate_area = candidate.width as u64 * candidate.height as u64;
    let reference_area = reference.width as u64 * reference.height as u64;

    if candidate_area == 0 && reference_area == 0 {
        return 1.0;
    }

    let intersection_x0 = candidate.x.max(reference.x);
    let intersection_y0 = candidate.y.max(reference.y);
    let intersection_x1 = (candidate.x + candidate.width).min(reference.x + reference.width);
    let intersection_y1 = (candidate.y + candidate.height).min(reference.y + reference.height);

    if intersection_x1 <= intersection_x0 || intersection_y1 <= intersection_y0 {
        return 0.0;
    }

    let intersection_area = (intersection_x1 - intersection_x0) as u64
        * (intersection_y1 - intersection_y0) as u64;
    let union_area = candidate_area + reference_area - intersection_area;

    intersection_area as f64 / union_area as f64
}

// ---------------------------------------------------------------------
// Deskew
// ---------------------------------------------------------------------

/// Absolute difference between candidate and reference deskew angles, in
/// degrees.
pub fn score_deskew_angle(candidate_degrees: f64, reference_degrees: f64) -> f64 {
    (candidate_degrees - reference_degrees).abs()
}

// ---------------------------------------------------------------------
// ICE mask agreement
// ---------------------------------------------------------------------

/// Jaccard index (intersection / union) between two masks, each binarized
/// at `threshold`. Returns `1.0` if both masks are entirely below
/// `threshold` (degenerate agreement case — nothing "on" to disagree
/// about).
pub fn score_ice_mask_agreement(
    candidate: &NormalizedMask,
    reference: &NormalizedMask,
    threshold: f32,
) -> Result<f64, ParityError> {
    if candidate.width != reference.width || candidate.height != reference.height {
        return Err(ParityError::Decode(format!(
            "score_ice_mask_agreement: dimension mismatch — candidate {}x{}, reference {}x{}",
            candidate.width, candidate.height, reference.width, reference.height
        )));
    }

    let mut intersection_count: u64 = 0;
    let mut union_count: u64 = 0;
    for (candidate_value, reference_value) in
        candidate.pixels.iter().zip(reference.pixels.iter())
    {
        let candidate_on = *candidate_value >= threshold;
        let reference_on = *reference_value >= threshold;
        if candidate_on && reference_on {
            intersection_count += 1;
        }
        if candidate_on || reference_on {
            union_count += 1;
        }
    }

    if union_count == 0 {
        return Ok(1.0);
    }

    Ok(intersection_count as f64 / union_count as f64)
}
