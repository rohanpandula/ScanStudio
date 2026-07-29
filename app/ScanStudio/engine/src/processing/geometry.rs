//! Port of the owner's NegPy geometry module
//! (negpy-src/negpy/features/geometry/{logic.py,models.py}) -- batch
//! autocrop (AUTO_FILM_BORDER / AUTO_FRAME_EDGE modes) and fine deskew.
//! Owner-authored, GPL-3.0 at the NegPy source level. The repository owner
//! separately authorized this Rust port for this project's MIT-licensed code;
//! see the repository license and provenance records before redistributing
//! combined components.
//!
//! Every numeric literal in this module's test suite (Groups R, F, U, T, E,
//! X, M) was derived by actually running the real
//! `negpy.features.geometry.logic` against hand-built synthetic test
//! images (see plan 15-01's `<rotation_algorithm>` and
//! `<autocrop_ground_truth>` blocks) -- this is a faithful numeric port of
//! a verified reference implementation, not a reimplementation from first
//! principles.
//!
//! Primitive substitutions from cv2/numpy to `imageproc`/hand-rolled Rust
//! are documented per-function below; see plan 15-01's
//! `<cv2_to_rust_primitive_map>` for the full mapping this module follows.

use image::{GrayImage, ImageBuffer, Luma};
use imageproc::contours::BorderType;
use imageproc::distance_transform::Norm;
use imageproc::point::Point;

// ---------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------

/// Detection-resolution long-edge cap (matches NegPy's AUTOCROP_DETECT_RES).
/// Real corpus captures (~5959px long edge) are always downsampled for
/// detection purposes -- this path is exercised on every real slot, not a
/// rare edge case.
pub const AUTOCROP_DETECT_RES: u32 = 1800;

/// AUTO_FILM_BORDER / AUTO_FRAME_EDGE, matching NegPy's AutocropMode enum
/// ("film" / "image" string values) 1:1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutocropMode {
    /// AUTO_FILM_BORDER: crop to film extent, rebate/sprockets kept.
    /// NegPy: AutocropMode.FILM ("film").
    Film,
    /// AUTO_FRAME_EDGE: refine inward to the exposed image area (NegPy's
    /// own default). NegPy: AutocropMode.IMAGE ("image").
    Image,
}

/// float32, [0,1]-range, row-major, 3-channel [R,G,B] image buffer --
/// matches NegPy's own `ImageBuffer = npt.NDArray[np.float32]` convention.
/// Callers convert from Rgb16Image (u16 TIFF-decoded) via `/65535.0`; that
/// conversion lives in parity::candidates (plan 15-02), not here -- this
/// module never imports from parity, mirroring processing::nikonlook.
#[derive(Debug, Clone, PartialEq)]
pub struct GeometryImage {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<[f32; 3]>,
}

/// Axis-aligned ROI in NegPy's own (y1, y2, x1, x2) half-open tuple
/// convention (y1<=row<y2, x1<=col<x2). Deliberately NOT
/// parity::scoring::Rect (x,y,width,height) -- that's the PARITY-report
/// shape; plan 15-02's parity::candidates converts between the two.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Roi {
    pub y1: u32,
    pub y2: u32,
    pub x1: u32,
    pub x2: u32,
}

// ---------------------------------------------------------------------
// Rotation (fine deskew)
// ---------------------------------------------------------------------

/// Exposes `<rotation_algorithm>` step 2's closed-form 2x3 rotation-matrix
/// formula directly (`getRotationMatrix2D(center=(width/2,height/2), angle,
/// scale=1.0)`), row-major `[[cos,sin,tx],[-sin,cos,ty]]`. `apply_fine_rotation`
/// calls this internally (with `-angle_degrees`, per step 3) for its own
/// resampling; it is ALSO exposed `pub` so plan 15-02's parity scoring can
/// independently decompose a matrix back to degrees on both the reference
/// and candidate sides without duplicating this formula in the parity
/// layer.
pub fn rotation_matrix_2x3(angle_degrees: f64, width: u32, height: u32) -> [[f64; 3]; 2] {
    let center = (width as f64 / 2.0, height as f64 / 2.0);
    let theta = angle_degrees.to_radians();
    let cos_t = theta.cos();
    let sin_t = theta.sin();
    [
        [cos_t, sin_t, (1.0 - cos_t) * center.0 - sin_t * center.1],
        [-sin_t, cos_t, sin_t * center.0 + (1.0 - cos_t) * center.1],
    ]
}

/// Fine deskew: sub-degree rotation about the image center, bilinear
/// sampling, edge-replicate border handling. See plan 15-01's
/// `<rotation_algorithm>`. `angle_degrees == 0.0` returns the input
/// unchanged (no-op fast path, exact equality check matching the Python
/// source).
pub fn apply_fine_rotation(img: &GeometryImage, angle_degrees: f64) -> GeometryImage {
    if angle_degrees == 0.0 {
        return img.clone();
    }

    let (width, height) = (img.width, img.height);
    // Resampling uses the INVERSE map, which for a pure rotation about a
    // fixed center is the same formula evaluated at -angle_degrees.
    let m_inv = rotation_matrix_2x3(-angle_degrees, width, height);

    let mut pixels = vec![[0f32; 3]; (width as usize) * (height as usize)];
    let get = |xi: u32, yi: u32| img.pixels[(yi * width + xi) as usize];
    let clamp_x = |v: i64| v.clamp(0, width as i64 - 1) as u32;
    let clamp_y = |v: i64| v.clamp(0, height as i64 - 1) as u32;

    for y_out in 0..height {
        for x_out in 0..width {
            let xf = x_out as f64;
            let yf = y_out as f64;
            let src_x = m_inv[0][0] * xf + m_inv[0][1] * yf + m_inv[0][2];
            let src_y = m_inv[1][0] * xf + m_inv[1][1] * yf + m_inv[1][2];

            let x0 = src_x.floor() as i64;
            let x1 = x0 + 1;
            let fx = src_x - x0 as f64;
            let y0 = src_y.floor() as i64;
            let y1 = y0 + 1;
            let fy = src_y - y0 as f64;

            let p00 = get(clamp_x(x0), clamp_y(y0));
            let p01 = get(clamp_x(x1), clamp_y(y0));
            let p10 = get(clamp_x(x0), clamp_y(y1));
            let p11 = get(clamp_x(x1), clamp_y(y1));

            let mut out = [0f32; 3];
            for c in 0..3 {
                let top = p00[c] as f64 * (1.0 - fx) + p01[c] as f64 * fx;
                let bottom = p10[c] as f64 * (1.0 - fx) + p11[c] as f64 * fx;
                out[c] = (top * (1.0 - fy) + bottom * fy) as f32;
            }
            pixels[(y_out * width + x_out) as usize] = out;
        }
    }

    GeometryImage { width, height, pixels }
}

// ---------------------------------------------------------------------
// Percentile primitive (mirrors processing::nikonlook's private
// percentile_linear helper -- no shared kernel module exists yet, a
// private copy here is per plan 15-01's own instruction).
// ---------------------------------------------------------------------

/// NumPy's default "linear" percentile interpolation on an ALREADY SORTED
/// ascending slice. `p` is in [0, 100].
fn percentile_linear(sorted: &[f64], p: f64) -> f64 {
    let n = sorted.len();
    debug_assert!(n > 0, "percentile_linear requires a non-empty slice");
    if n == 1 {
        return sorted[0];
    }
    let idx = (p / 100.0) * (n - 1) as f64;
    let lo_idx = idx.floor() as usize;
    let hi_idx = idx.ceil() as usize;
    if lo_idx == hi_idx {
        return sorted[lo_idx];
    }
    let frac = idx - lo_idx as f64;
    sorted[lo_idx] * (1.0 - frac) + sorted[hi_idx] * frac
}

/// Percentile of an unsorted f64 slice (sorts a private copy).
fn percentile_of_f64(values: &[f64], p: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut v = values.to_vec();
    v.sort_by(f64::total_cmp);
    percentile_linear(&v, p)
}

/// Percentile of an unsorted u8 slice (sorts a private f64 copy).
fn percentile_of_u8(values: &[u8], p: f64) -> f64 {
    let v: Vec<f64> = values.iter().map(|&x| x as f64).collect();
    percentile_of_f64(&v, p)
}

/// Per-column percentile (`np.percentile(x, p, axis=0)`): one value per
/// column, reducing over rows.
fn percentile_axis0_u8(values: &[u8], width: u32, height: u32, p: f64) -> Vec<f64> {
    (0..width)
        .map(|x| {
            let col: Vec<f64> = (0..height)
                .map(|y| values[(y * width + x) as usize] as f64)
                .collect();
            percentile_of_f64(&col, p)
        })
        .collect()
}

/// Per-row percentile (`np.percentile(x, p, axis=1)`): one value per row,
/// reducing over columns.
fn percentile_axis1_u8(values: &[u8], width: u32, height: u32, p: f64) -> Vec<f64> {
    (0..height)
        .map(|y| {
            let row: Vec<f64> = (0..width)
                .map(|x| values[(y * width + x) as usize] as f64)
                .collect();
            percentile_of_f64(&row, p)
        })
        .collect()
}

// ---------------------------------------------------------------------
// Detection-resolution downsample + coord scaling
// (_normalize_detection_input, _scale_roi)
// ---------------------------------------------------------------------

/// Area-weighted box downsample -- INTER_AREA for pure downsampling IS a
/// box/area average, not an approximation. Handles fractional source-pixel
/// overlap at destination-pixel boundaries. Never called with dst >= src
/// (guarded by the `min(1.0, ...)` clamp in `normalize_detection_input`).
fn box_average_downsample(img: &GeometryImage, dst_w: u32, dst_h: u32) -> GeometryImage {
    let src_w = img.width as f64;
    let src_h = img.height as f64;
    let scale_x = src_w / dst_w as f64;
    let scale_y = src_h / dst_h as f64;
    let mut pixels = vec![[0f32; 3]; (dst_w as usize) * (dst_h as usize)];

    for dy in 0..dst_h {
        let y0 = dy as f64 * scale_y;
        let y1 = (dy as f64 + 1.0) * scale_y;
        let sy_start = y0.floor() as i64;
        let sy_end = y1.ceil() as i64;

        for dx in 0..dst_w {
            let x0 = dx as f64 * scale_x;
            let x1 = (dx as f64 + 1.0) * scale_x;
            let sx_start = x0.floor() as i64;
            let sx_end = x1.ceil() as i64;

            let mut acc = [0f64; 3];
            let mut weight_sum = 0f64;
            for sy in sy_start..sy_end {
                if sy < 0 || sy >= img.height as i64 {
                    continue;
                }
                let wy = (((sy as f64 + 1.0).min(y1)) - (sy as f64).max(y0)).max(0.0);
                if wy <= 0.0 {
                    continue;
                }
                for sx in sx_start..sx_end {
                    if sx < 0 || sx >= img.width as i64 {
                        continue;
                    }
                    let wx = (((sx as f64 + 1.0).min(x1)) - (sx as f64).max(x0)).max(0.0);
                    if wx <= 0.0 {
                        continue;
                    }
                    let weight = wx * wy;
                    let px = img.pixels[(sy as u32 * img.width + sx as u32) as usize];
                    acc[0] += px[0] as f64 * weight;
                    acc[1] += px[1] as f64 * weight;
                    acc[2] += px[2] as f64 * weight;
                    weight_sum += weight;
                }
            }

            let out = if weight_sum > 0.0 {
                [
                    (acc[0] / weight_sum) as f32,
                    (acc[1] / weight_sum) as f32,
                    (acc[2] / weight_sum) as f32,
                ]
            } else {
                [0.0, 0.0, 0.0]
            };
            pixels[(dy * dst_w + dx) as usize] = out;
        }
    }

    GeometryImage { width: dst_w, height: dst_h, pixels }
}

/// Downsamples to `detect_res` longest edge (INTER_AREA-equivalent). Never
/// upscales. Returns `(det_img, det_scale)` with `det_scale <= 1.0`.
fn normalize_detection_input(img: &GeometryImage, detect_res: u32) -> (GeometryImage, f64) {
    let (h, w) = (img.height as f64, img.width as f64);
    let det_scale = (detect_res as f64 / h.max(w)).min(1.0);
    if det_scale >= 1.0 {
        return (img.clone(), 1.0);
    }
    let d_w = ((w * det_scale).round() as u32).max(1);
    let d_h = ((h * det_scale).round() as u32).max(1);
    (box_average_downsample(img, d_w, d_h), det_scale)
}

/// Maps a detection-space ROI back to input coordinates, clamped to
/// bounds.
fn scale_roi(roi: Roi, det_scale: f64, h: u32, w: u32) -> Roi {
    if det_scale >= 1.0 {
        return roi;
    }
    let y1 = (0i64).max((roi.y1 as f64 / det_scale).round() as i64);
    let y2 = (h as i64).min((roi.y2 as f64 / det_scale).round() as i64);
    let x1 = (0i64).max((roi.x1 as f64 / det_scale).round() as i64);
    let x2 = (w as i64).min((roi.x2 as f64 / det_scale).round() as i64);
    Roi {
        y1: y1.max(0) as u32,
        y2: y2.max(0) as u32,
        x1: x1.max(0) as u32,
        x2: x2.max(0) as u32,
    }
}

// ---------------------------------------------------------------------
// uint8 normalization + luminance conventions
//
// Three DIFFERENT luminance/gray formulas exist in the Python source and
// are ported as three DISTINCT functions -- never conflated:
//   1. `bgr_to_gray_u8` (this section): cv2.cvtColor(BGR2GRAY)-equivalent,
//      operating POSITIONALLY (0.114 on channel index 0, 0.587 on index 1,
//      0.299 on index 2) exactly as real cv2 does, regardless of what the
//      channels actually hold. NegPy's own `_detect_film_bounds` /
//      `_dark_region_bounds` / `_refine_frame_bounds` all call
//      `cv2.cvtColor(preview, cv2.COLOR_BGR2GRAY)` on `preview` arrays that
//      are genuinely RGB-ordered (not BGR) -- see this function's own doc
//      comment (plan 15-02 root-cause fix) for the verified evidence this
//      is the real, as-executed behavior, not a perceptually "corrected"
//      R/G/B weighting. Feeds the contour/morphology detection pipeline.
//   2. `raw_luminance` (below): Rec.709 (0.2126/0.7152/0.0722), computed
//      directly on the raw float image, no normalization. Matches
//      negpy.kernel.image.logic.get_luminance; used by
//      _get_threshold_autocrop_coords (plan 15-01 Task 3).
//   3. `detection_luma` (below): `raw_luminance` anchored to its own
//      99.5th percentile (so the light bed sits near 1.0) and clipped to
//      [0,2]. Matches _detection_luma; used by film-bounds refinement.
// ---------------------------------------------------------------------

/// `_normalize_to_uint8`-equivalent: percentile-stretches ALL finite
/// values across the WHOLE image (all channels flattened together -- one
/// shared [low,high] pair, not per-channel) to [0,255], truncating cast
/// (NOT round-half-up -- opposite convention from
/// processing::nikonlook/render_color_candidate's `+0.5` rounding).
/// Non-finite input values are treated as 0.0 pre-clamp rather than
/// mirroring numpy's undefined NaN-to-uint8 cast behavior -- a deliberate,
/// panic-free safety choice (threat T-15-02).
fn normalize_to_uint8(img: &GeometryImage) -> Vec<[u8; 3]> {
    let mut valid: Vec<f64> = Vec::with_capacity(img.pixels.len() * 3);
    for px in &img.pixels {
        for &c in px.iter() {
            let v = c as f64;
            if v.is_finite() {
                valid.push(v);
            }
        }
    }
    if valid.is_empty() {
        return vec![[0u8; 3]; img.pixels.len()];
    }
    valid.sort_by(f64::total_cmp);
    let low = percentile_linear(&valid, 1.0);
    let mut high = percentile_linear(&valid, 99.0);
    if high <= low {
        high = low + 1.0;
    }
    let scale = 255.0 / (high - low);

    img.pixels
        .iter()
        .map(|px| {
            let mut out = [0u8; 3];
            for c in 0..3 {
                let v = px[c] as f64;
                let scaled = if v.is_finite() {
                    ((v - low) * scale).clamp(0.0, 255.0)
                } else {
                    0.0
                };
                out[c] = scaled as u8; // truncating cast
            }
            out
        })
        .collect()
}

/// `cv2.cvtColor(preview, cv2.COLOR_BGR2GRAY)`-equivalent: cv2 applies
/// 0.299/0.587/0.114 POSITIONALLY (index 2 / index 1 / index 0
/// respectively, its own fixed "R"/"G"/"B" position assignment for a
/// BGR-ordered array), not by inspecting what the channels actually mean.
/// `preview` here is built from genuinely RGB-ordered raw scanner data
/// (channel index 0 really is R, index 2 really is B) -- so the REAL,
/// as-executed NegPy behavior swaps the 0.299/0.114 weights relative to a
/// perceptually "correct" R/G/B luma formula. Verified two independent
/// ways against a live cv2 oracle: (1) `cv2.cvtColor([100,0,0],...)`
/// really does return 11, not 30 (and `cv2.cvtColor([0,0,100],...)`
/// returns 30, not 11) -- confirming the weight-per-POSITION assignment;
/// (2) on real corpus slot 3's actual detection-resolution image, this
/// exact fix reduced full-image gray-conversion max-abs-diff against a
/// live cv2 oracle from 33/255 (mean 5.60, 87.8% of pixels differing) down
/// to 1/255 (mean 0.0007, 0.07% differing -- consistent with pure
/// rounding noise, not a remaining logic gap). A prior version of this
/// function had these weights swapped (matching neither cv2's positional
/// behavior nor, in practice, most content -- it happened to pass 15-01's
/// own synthetic Group F/T/E ground truth because those hand-built test
/// images are symmetric enough across channels for the swap not to
/// matter, but diverged visibly on real, color-cast-bearing photographic
/// content).
fn bgr_to_gray_u8(preview: &[[u8; 3]]) -> Vec<u8> {
    preview
        .iter()
        .map(|&[position0, position1, position2]| {
            let gray =
                0.114 * position0 as f64 + 0.587 * position1 as f64 + 0.299 * position2 as f64;
            gray.round().clamp(0.0, 255.0) as u8
        })
        .collect()
}

fn to_gray_image(width: u32, height: u32, gray: &[u8]) -> GrayImage {
    ImageBuffer::from_raw(width, height, gray.to_vec())
        .expect("gray buffer length must match width*height")
}

/// Rec.709 luma computed directly on the raw float image, no
/// normalization/anchoring. Matches negpy.kernel.image.logic.get_luminance
/// for (H,W,3) input.
fn raw_luminance(img: &GeometryImage) -> Vec<f64> {
    const LUMA_R: f64 = 0.2126;
    const LUMA_G: f64 = 0.7152;
    const LUMA_B: f64 = 0.0722;
    img.pixels
        .iter()
        .map(|px| LUMA_R * px[0] as f64 + LUMA_G * px[1] as f64 + LUMA_B * px[2] as f64)
        .collect()
}

/// Luminance normalized so the light bed sits near 1.0 (anchored at
/// P99.5). Content-stable alternative to `normalize_to_uint8`'s 1/99
/// stretch. Matches `_detection_luma`.
fn detection_luma(img: &GeometryImage) -> Vec<f64> {
    let lum = raw_luminance(img);
    let anchor = percentile_of_f64(&lum, 99.5).max(1e-6);
    lum.iter().map(|&v| (v / anchor).clamp(0.0, 2.0)).collect()
}

// ---------------------------------------------------------------------
// _smooth_signal -- zero-padded box convolve, mode="same"
// ---------------------------------------------------------------------

/// Zero-padded box convolve (`np.convolve(signal, ones(window)/window,
/// mode="same")`). `window <= 1` is a pure passthrough (no convolution).
/// NOT edge-replicate at the boundary -- verified via
/// `<autocrop_ground_truth>`'s literal values. The Python source's own
/// first step is `signal.astype(np.float32)` -- this function always
/// convolves in float32 regardless of the caller's own array dtype.
/// Verified directly against real numpy (`np.convolve` on a float32
/// array): the kernel tap is `1.0f32/window as f32` computed ONCE, then
/// each output sample accumulates `signal[k] as f32 * kernel_val` in f32,
/// left to right -- NOT "sum the taps in f64, then divide by window,"
/// which rounds to a different (adjacent) float32 value.
fn smooth_signal(signal: &[f64], window: usize) -> Vec<f64> {
    let n = signal.len();
    if window <= 1 || n == 0 {
        return signal.to_vec();
    }
    // numpy `mode="same"` centering offset: (kernel_len - 1) // 2 into the
    // "full" convolution array.
    let half = (window - 1) / 2;
    let kernel_val = 1.0f32 / window as f32;
    let mut out = vec![0.0; n];
    for i in 0..n {
        let center = i as i64 + half as i64;
        let lo = (center - window as i64 + 1).max(0);
        let hi = center.min(n as i64 - 1);
        let mut acc = 0.0f32;
        let mut k = lo;
        while k <= hi {
            acc += signal[k as usize] as f32 * kernel_val;
            k += 1;
        }
        out[i] = acc as f64;
    }
    out
}

// ---------------------------------------------------------------------
// Morphology helpers (structuring-element radius + explicit iteration
// loop -- NOT a single larger-radius shortcut, per plan 15-01's own
// guidance).
//
// NOTE on open/close ordering: this plan's own <cv2_to_rust_primitive_map>
// prose describes "erode-then-dilate for close; dilate-then-erode for
// open," which is the REVERSE of long-standing, extremely well documented
// OpenCV/morphology semantics (confirmed against OpenCV's own
// morphologyEx source): MORPH_OPEN = erode(iterations) then
// dilate(iterations); MORPH_CLOSE = dilate(iterations) then
// erode(iterations). That prose line appears to be a documentation slip;
// implemented here per verified OpenCV behavior, since that is what
// actually produced this plan's own ground-truth ROI literals.
// ---------------------------------------------------------------------

fn morph_dilate_n(image: &GrayImage, k: u8, iterations: u32) -> GrayImage {
    let mut out = image.clone();
    for _ in 0..iterations {
        out = imageproc::morphology::dilate(&out, Norm::LInf, k);
    }
    out
}

fn morph_erode_n(image: &GrayImage, k: u8, iterations: u32) -> GrayImage {
    let mut out = image.clone();
    for _ in 0..iterations {
        out = imageproc::morphology::erode(&out, Norm::LInf, k);
    }
    out
}

fn morph_close_n(image: &GrayImage, k: u8, iterations: u32) -> GrayImage {
    let dilated = morph_dilate_n(image, k, iterations);
    morph_erode_n(&dilated, k, iterations)
}

fn morph_open_n(image: &GrayImage, k: u8, iterations: u32) -> GrayImage {
    let eroded = morph_erode_n(image, k, iterations);
    morph_dilate_n(&eroded, k, iterations)
}

/// Blackhat = close(gray) - gray (closing minus original), per OpenCV's
/// own definition. Saturating subtract (u8, clamped at 0).
///
/// Uses `imageproc::morphology::grayscale_close` (local-max-then-local-min
/// over a square mask), NOT `morph_close_n` (plan 15-02 root-cause fix):
/// `morph_close_n`/`imageproc::morphology::{dilate,erode}` are BINARY
/// operators over a distance transform -- per their own doc comment, "A
/// pixel is treated as belonging to the foreground if it has non-zero
/// intensity", collapsing every nonzero input value to a uniform 255
/// before any distance-based dilation/erosion happens. That is exactly
/// right for the OTHER `morph_close_n`/`morph_open_n` call sites in this
/// file (they all run on already-binary 0/255 threshold/edge output,
/// matching cv2's own binary-mask morphology calls in the Python source)
/// but is wrong here: `gray` is a genuine multi-level grayscale image, and
/// real photographic content has almost no exact-zero pixels, so
/// `morph_close_n(gray, k, 1)` silently binarized nearly the entire image
/// to 255 -- making `closed` ~255 everywhere and this function's output
/// collapse to approximately `255 - gray` (a negated copy of the input),
/// not a real blackhat transform. Found via real-corpus investigation
/// (slot 3 of the six-slot parity corpus): the resulting mask had a
/// roughly uniform 0-255 histogram (mean 125) instead of blackhat's
/// expected mostly-near-zero signature (Python's real `cv2.MORPH_BLACKHAT`
/// output on the identical input: mean 30, 45% of pixels in [0,16)).
/// `grayscale_close` (true local min/max over a `Mask::square(k)`, matching
/// cv2's grayscale `MORPH_CLOSE` exactly) does not have this problem.
fn blackhat_u8(gray: &GrayImage, k: u8) -> GrayImage {
    let mask = imageproc::morphology::Mask::square(k);
    let closed = imageproc::morphology::grayscale_close(gray, &mask);
    ImageBuffer::from_fn(gray.width(), gray.height(), |x, y| {
        let c = closed.get_pixel(x, y)[0] as i32;
        let g = gray.get_pixel(x, y)[0] as i32;
        Luma([(c - g).max(0) as u8])
    })
}

/// Otsu threshold + binary (or inverse-binary) mask.
fn threshold_otsu_binary(image: &GrayImage, invert: bool) -> GrayImage {
    let level = imageproc::contrast::otsu_level(image);
    ImageBuffer::from_fn(image.width(), image.height(), |x, y| {
        let v = image.get_pixel(x, y)[0];
        let on = if invert { v <= level } else { v > level };
        Luma([if on { 255u8 } else { 0u8 }])
    })
}

/// cv2's documented auto-sigma formula for `GaussianBlur` when `sigma=0`:
/// `sigma = 0.3*((ksize-1)*0.5 - 1) + 0.8`.
fn gaussian_blur_u8_ksize(image: &GrayImage, ksize: f32) -> GrayImage {
    let sigma = 0.3 * ((ksize - 1.0) * 0.5 - 1.0) + 0.8;
    imageproc::filter::gaussian_blur_f32(image, sigma)
}

// ---------------------------------------------------------------------
// Mask-generation strategies (_mask_from_blackhat, _mask_from_inverse_
// threshold, _mask_from_edges)
// ---------------------------------------------------------------------

fn mask_from_blackhat(gray: &GrayImage) -> GrayImage {
    let bh = blackhat_u8(gray, 15); // (31,31) kernel -> radius 15
    let blurred = gaussian_blur_u8_ksize(&bh, 5.0);
    let thresh = threshold_otsu_binary(&blurred, false); // THRESH_BINARY
    morph_close_n(&thresh, 10, 2) // (21,21) -> radius 10, iterations=2
}

fn mask_from_inverse_threshold(gray: &GrayImage) -> GrayImage {
    let blurred = gaussian_blur_u8_ksize(gray, 7.0);
    let thresh = threshold_otsu_binary(&blurred, true); // THRESH_BINARY_INV
    let closed = morph_close_n(&thresh, 8, 2); // (17,17) -> radius 8
    morph_open_n(&closed, 2, 1) // (5,5) -> radius 2, iterations=1
}

fn mask_from_edges(gray: &GrayImage) -> GrayImage {
    // imageproc::edges::canny bakes in its own internal Gaussian blur
    // (sigma=1.4) as step 1 of the algorithm, unlike cv2.Canny which
    // expects the caller to pre-blur separately. Calling our own pre-blur
    // here (mirroring the Python source's explicit
    // `cv2.GaussianBlur(gray,(5,5),0)`) would double-blur the image
    // relative to imageproc's canny. Skipping the redundant pre-blur and
    // calling canny directly is the closer match to cv2's actual
    // blur-then-canny behavior.
    let edges = imageproc::edges::canny(gray, 40.0, 160.0);
    let dilated = morph_dilate_n(&edges, 3, 2); // (7,7) -> radius 3, dilate only
    morph_close_n(&dilated, 7, 2) // (15,15) -> radius 7
}

// ---------------------------------------------------------------------
// Contour scoring + film-bounds detection
// (_score_contour, _detect_film_bounds, _film_surround_is_plausible,
// _snap_edge_to_gradient, _snap_film_bounds_to_bed_gradient)
// ---------------------------------------------------------------------

fn point_dist(a: Point<i32>, b: Point<i32>) -> f64 {
    let dx = (a.x - b.x) as f64;
    let dy = (a.y - b.y) as f64;
    (dx * dx + dy * dy).sqrt()
}

/// Matches the exact rejection thresholds (area_ratio < 0.08, short_side <
/// 40, aspect_ratio > 8.0) and score formula (area_ratio*1.5 +
/// min(fill_ratio,1.0)) from `_score_contour`.
fn score_contour(points: &[Point<i32>], image_area: f64) -> Option<(f64, [Point<i32>; 4])> {
    if points.is_empty() {
        return None;
    }
    let quad = imageproc::geometry::min_area_rect(points);
    let edge_w = point_dist(quad[0], quad[1]);
    let edge_h = point_dist(quad[1], quad[2]);
    let rect_area = edge_w * edge_h;
    if rect_area <= 0.0 {
        return None;
    }
    let c_area = imageproc::geometry::contour_area(points);
    let area_ratio = rect_area / image_area;
    let fill_ratio = c_area / rect_area;
    let short_side = edge_w.min(edge_h);
    let long_side = edge_w.max(edge_h);
    let aspect_ratio = long_side / short_side.max(1.0);

    if area_ratio < 0.08 || short_side < 40.0 || aspect_ratio > 8.0 {
        return None;
    }

    let score = area_ratio * 1.5 + fill_ratio.min(1.0);
    Some((score, quad))
}

/// A real film box sits on a light bed (uniform, near-clipping surround)
/// or in a dark holder. A mid-tone textured surround means the contour
/// latched onto image content in a borderless scan -- reject so detection
/// falls back to full frame.
fn film_surround_is_plausible(lum: &[f64], width: u32, height: u32, roi: Roi) -> bool {
    let (w, h) = (width as i64, height as i64);
    let (y1, y2, x1, x2) = (roi.y1 as i64, roi.y2 as i64, roi.x1 as i64, roi.x2 as i64);
    let mut outside: Vec<f64> = Vec::new();
    let mut inside: Vec<f64> = Vec::new();
    for y in 0..h {
        for x in 0..w {
            let v = lum[(y * w + x) as usize];
            if y >= y1 && y < y2 && x >= x1 && x < x2 {
                inside.push(v);
            } else {
                outside.push(v);
            }
        }
    }
    let total = (w * h) as f64;
    if (outside.len() as f64) < 0.005 * total {
        return true; // box covers nearly the whole scan; no surround evidence either way
    }
    let out_med = percentile_of_f64(&outside, 50.0);
    let box_med = percentile_of_f64(&inside, 50.0);
    let bed_like = out_med >= 0.85;
    let holder_like = out_med <= 0.30 && out_med <= box_med - 0.15;
    bed_like || holder_like
}

/// Snaps a coarse edge index to the strongest |gradient| of the smoothed
/// profile within an asymmetric window biased outward. Keeps `idx` unless
/// the peak clearly dominates the window (>= `min_dominance` x median).
#[allow(clippy::too_many_arguments)]
fn snap_edge_to_gradient(
    profile: &[f64],
    idx: i64,
    is_start: bool,
    window_out: f64,
    window_in: f64,
    min_dominance: f64,
    min_window_px: i64,
) -> i64 {
    let n = profile.len() as i64;
    if n < 8 {
        return idx;
    }
    let win = (3i64).max(((n as f64) * 0.01).round() as i64) as usize;
    let sm = smooth_signal(profile, win);
    let grad: Vec<f64> = sm.windows(2).map(|w| (w[1] - w[0]).abs()).collect();

    let out_px = min_window_px.max((window_out * n as f64).round() as i64);
    let in_px = min_window_px.max((window_in * n as f64).round() as i64);
    let (lo, hi) = if is_start {
        (0.max(idx - out_px), (n - 1).min(idx + in_px))
    } else {
        (0.max(idx - in_px), (n - 1).min(idx + out_px))
    };
    if hi <= lo {
        return idx;
    }
    let lo_u = lo as usize;
    let hi_u = (hi as usize).min(grad.len());
    if lo_u >= hi_u {
        return idx;
    }
    let window = &grad[lo_u..hi_u];

    let mut m = 0usize;
    let mut best = f64::NEG_INFINITY;
    for (i, &v) in window.iter().enumerate() {
        if v > best {
            best = v;
            m = i;
        }
    }
    let med = percentile_of_f64(window, 50.0);
    if window[m] >= min_dominance * med + 1e-6 {
        return lo + m as i64 + 1;
    }
    idx
}

/// Refines contour film bounds to the strongest bed->film luminance
/// gradient within a +/-2% window per edge.
fn snap_film_bounds_to_bed_gradient(roi: Roi, lum: &[f64], width: u32, height: u32) -> Roi {
    let (w, h) = (width as i64, height as i64);
    let (y1, y2, x1, x2) = (roi.y1 as i64, roi.y2 as i64, roi.x1 as i64, roi.x2 as i64);

    let col_profile: Vec<f64> = (0..w)
        .map(|x| {
            let mut sum = 0.0;
            let mut count = 0i64;
            for y in y1..y2 {
                sum += lum[(y * w + x) as usize];
                count += 1;
            }
            if count > 0 {
                sum / count as f64
            } else {
                0.0
            }
        })
        .collect();
    let row_profile: Vec<f64> = (0..h)
        .map(|y| {
            let mut sum = 0.0;
            let mut count = 0i64;
            for x in x1..x2 {
                sum += lum[(y * w + x) as usize];
                count += 1;
            }
            if count > 0 {
                sum / count as f64
            } else {
                0.0
            }
        })
        .collect();

    let nx1 = snap_edge_to_gradient(&col_profile, x1, true, 0.02, 0.02, 3.0, 16);
    let nx2 = snap_edge_to_gradient(&col_profile, x2, false, 0.02, 0.02, 3.0, 16);
    let ny1 = snap_edge_to_gradient(&row_profile, y1, true, 0.02, 0.02, 3.0, 16);
    let ny2 = snap_edge_to_gradient(&row_profile, y2, false, 0.02, 0.02, 3.0, 16);

    if ny2 - ny1 <= 0 || nx2 - nx1 <= 0 {
        return roi;
    }
    Roi {
        y1: (ny1 - 2).max(0) as u32,
        y2: (ny2 + 2).min(h) as u32,
        x1: (nx1 - 2).max(0) as u32,
        x2: (nx2 + 2).min(w) as u32,
    }
}

/// Detects the film extent against the light source / scan bed via
/// contours. Returns the outer film boundary (rebate/sprockets included),
/// or `None`.
fn detect_film_bounds(det: &GeometryImage) -> Option<Roi> {
    let preview = normalize_to_uint8(det);
    let gray_vals = bgr_to_gray_u8(&preview);
    let gray_image = to_gray_image(det.width, det.height, &gray_vals);
    let image_area = det.width as f64 * det.height as f64;

    let masks = [
        mask_from_blackhat(&gray_image),
        mask_from_inverse_threshold(&gray_image),
        mask_from_edges(&gray_image),
    ];

    let mut best_score = -1.0f64;
    let mut best_quad: Option<[Point<i32>; 4]> = None;
    for mask in &masks {
        // RETR_EXTERNAL keeps only outermost contours, discarding holes.
        // imageproc's BorderType::Outer isn't quite the same (it doesn't
        // exclude outer borders nested two-or-more levels deep inside a
        // hole), but every winning contour here must clear _score_contour's
        // area_ratio >= 0.08 floor, so a deeply-nested noise contour can
        // never outscore the true film-box contour in practice.
        let contours = imageproc::contours::find_contours::<i32>(mask);
        for contour in contours.iter().filter(|c| c.border_type == BorderType::Outer) {
            if let Some((score, quad)) = score_contour(&contour.points, image_area) {
                if score > best_score {
                    best_score = score;
                    best_quad = Some(quad);
                }
            }
        }
    }

    let quad = best_quad?;
    // Axis-aligned bounding box of the (possibly tilted) min-area-rect's 4
    // corners -- imageproc's min_area_rect already floor/ceil-snaps each
    // corner outward, so a direct min/max reproduces
    // cv2.boundingRect(boxPoints(rect).astype(float32))'s floor(min)/
    // ceil(max) behavior without a separate snap step.
    let min_x = quad.iter().map(|p| p.x).min().unwrap();
    let max_x = quad.iter().map(|p| p.x).max().unwrap();
    let min_y = quad.iter().map(|p| p.y).min().unwrap();
    let max_y = quad.iter().map(|p| p.y).max().unwrap();

    let left = min_x.max(0);
    let top = min_y.max(0);
    let right = max_x.max(0).min(det.width as i32);
    let bottom = max_y.max(0).min(det.height as i32);
    if right - left <= 0 || bottom - top <= 0 {
        return None;
    }

    let roi_pre = Roi {
        y1: top as u32,
        y2: bottom as u32,
        x1: left as u32,
        x2: right as u32,
    };

    let lum = detection_luma(det);
    if !film_surround_is_plausible(&lum, det.width, det.height, roi_pre) {
        return None;
    }

    Some(snap_film_bounds_to_bed_gradient(roi_pre, &lum, det.width, det.height))
}

// ---------------------------------------------------------------------
// Shared sub-rectangle extraction helper.
// ---------------------------------------------------------------------

/// Extracts a row-major `(y2-y1) x (x2-x1)` sub-rectangle from a
/// full-image flat buffer (e.g. a luminance array).
fn extract_rect(values: &[f64], width: u32, y1: u32, y2: u32, x1: u32, x2: u32) -> Vec<f64> {
    let w = width as usize;
    let mut out = Vec::with_capacity(((y2 - y1) as usize) * ((x2 - x1) as usize));
    for y in y1..y2 {
        for x in x1..x2 {
            out.push(values[(y as usize) * w + x as usize]);
        }
    }
    out
}

/// Extracts a rectangular sub-image (e.g. `img[y1:y2, x1:x2]`).
fn extract_geometry_subimage(img: &GeometryImage, y1: u32, y2: u32, x1: u32, x2: u32) -> GeometryImage {
    let width = x2 - x1;
    let height = y2 - y1;
    let mut pixels = Vec::with_capacity((width as usize) * (height as usize));
    for y in y1..y2 {
        for x in x1..x2 {
            pixels.push(img.pixels[(y * img.width + x) as usize]);
        }
    }
    GeometryImage { width, height, pixels }
}

// ---------------------------------------------------------------------
// Sobel-based fallback refinement
// (_boundary_candidates, _dark_region_bounds, _refine_frame_bounds)
// ---------------------------------------------------------------------

/// Returns `(edge_idx, edge_value, inner_idx, inner_value)`. `np.argmax`
/// semantics: first occurrence of the maximum wins on ties.
fn boundary_candidates(signal: &[f64], from_start: bool) -> (i64, f64, i64, f64) {
    let length = signal.len() as i64;
    if length == 0 {
        return (0, 0.0, 0, 0.0);
    }
    let mut edge_window = ((length as f64 * 0.08).round() as i64).max(32);
    edge_window = edge_window.min((length - 1).max(1));
    let mut search_end = ((length as f64 * 0.45).round() as i64).max(edge_window + 1);
    search_end = search_end.min(length);
    let search_start = ((length as f64 * 0.55).round() as i64).min((length - edge_window - 1).max(0));

    let argmax = |s: &[f64]| -> usize {
        let mut best_i = 0usize;
        let mut best_v = f64::NEG_INFINITY;
        for (i, &v) in s.iter().enumerate() {
            if v > best_v {
                best_v = v;
                best_i = i;
            }
        }
        best_i
    };

    if from_start {
        let edge_slice = &signal[0..edge_window as usize];
        let search_slice = &signal[edge_window as usize..search_end as usize];
        let edge_idx = if !edge_slice.is_empty() { argmax(edge_slice) as i64 } else { 0 };
        let edge_value = if !edge_slice.is_empty() { edge_slice[edge_idx as usize] } else { 0.0 };
        if search_slice.is_empty() {
            return (edge_idx, edge_value, edge_idx, edge_value);
        }
        let inner_offset = argmax(search_slice) as i64;
        let inner_idx = edge_window + inner_offset;
        let inner_value = search_slice[inner_offset as usize];
        return (edge_idx, edge_value, inner_idx, inner_value);
    }

    let edge_slice = &signal[(length - edge_window) as usize..];
    let search_slice = &signal[search_start as usize..(length - edge_window) as usize];
    let edge_offset = if !edge_slice.is_empty() { argmax(edge_slice) as i64 } else { 0 };
    let edge_idx = length - edge_window + edge_offset;
    let edge_value = if !edge_slice.is_empty() { edge_slice[edge_offset as usize] } else { 0.0 };
    if search_slice.is_empty() {
        return (edge_idx, edge_value, edge_idx, edge_value);
    }
    let inner_offset = argmax(search_slice) as i64;
    let inner_idx = search_start + inner_offset;
    let inner_value = search_slice[inner_offset as usize];
    (edge_idx, edge_value, inner_idx, inner_value)
}

/// `_dark_region_bounds`-equivalent: largest-area contour on a
/// below-median-luminance mask, `cv2.boundingRect`'s INTEGER-contour path
/// (inclusive `+1` width/height -- different from `detect_film_bounds`'s
/// float-corner path, which uses `min_area_rect`'s already floor/ceil-
/// snapped corners with no `+1`).
fn dark_region_bounds(image: &GeometryImage) -> Option<(u32, u32, u32, u32)> {
    let preview = normalize_to_uint8(image);
    let gray_vals = bgr_to_gray_u8(&preview);
    let threshold = percentile_of_u8(&gray_vals, 55.0);
    let mask_vals: Vec<u8> = gray_vals.iter().map(|&g| if (g as f64) <= threshold { 255 } else { 0 }).collect();
    let mask_image = to_gray_image(image.width, image.height, &mask_vals);
    let opened = morph_open_n(&mask_image, 4, 1); // (9,9) -> radius 4
    let closed = morph_close_n(&opened, 15, 2); // (31,31) -> radius 15

    let contours = imageproc::contours::find_contours::<i32>(&closed);
    let outer: Vec<_> = contours
        .iter()
        .filter(|c| c.border_type == BorderType::Outer && !c.points.is_empty())
        .collect();
    if outer.is_empty() {
        return None;
    }
    let mut best = outer[0];
    let mut best_area = imageproc::geometry::contour_area(&best.points);
    for c in outer.iter().skip(1) {
        let area = imageproc::geometry::contour_area(&c.points);
        if area > best_area {
            best_area = area;
            best = c;
        }
    }

    let min_x = best.points.iter().map(|p| p.x).min().unwrap();
    let max_x = best.points.iter().map(|p| p.x).max().unwrap();
    let min_y = best.points.iter().map(|p| p.y).min().unwrap();
    let max_y = best.points.iter().map(|p| p.y).max().unwrap();
    let x = min_x;
    let y = min_y;
    let box_w = max_x - min_x + 1;
    let box_h = max_y - min_y + 1;

    let image_area = (image.width as f64 * image.height as f64).max(1.0);
    let area_ratio = best_area / image_area;
    if !(0.15..=0.85).contains(&area_ratio) {
        return None;
    }

    let min_width = (image.width as f64 * 0.25).round() as i32;
    let min_height = (image.height as f64 * 0.25).round() as i32;
    if box_w < min_width || box_h < min_height {
        return None;
    }

    let pad_x = ((image.width as f64 * 0.004).round() as i32).max(4);
    let pad_y = ((image.height as f64 * 0.004).round() as i32).max(4);
    let left = (x - pad_x).max(0);
    let top = (y - pad_y).max(0);
    let right = (x + box_w + pad_x).min(image.width as i32);
    let bottom = (y + box_h + pad_y).min(image.height as i32);

    let min_inset_x = (image.width as f64 * 0.03).round() as i32;
    let min_inset_y = (image.height as f64 * 0.03).round() as i32;
    if left < min_inset_x
        || top < min_inset_y
        || (image.width as i32 - right) < min_inset_x
        || (image.height as i32 - bottom) < min_inset_y
    {
        return None;
    }

    Some((left as u32, top as u32, right as u32, bottom as u32))
}

/// Sobel-gradient boundary refinement (`_refine_frame_bounds`), the
/// fallback path when tier-based refinement fails. Returns
/// `(left, top, right, bottom)`; the Python source's own cropped-image
/// first return value is unused by any caller in this plan's scope.
fn refine_frame_bounds(image: &GeometryImage) -> (u32, u32, u32, u32) {
    let (w, h) = (image.width, image.height);
    let preview = normalize_to_uint8(image);
    let gray_vals = bgr_to_gray_u8(&preview);
    let gray_image = to_gray_image(w, h, &gray_vals);

    let gx = imageproc::gradients::horizontal_sobel(&gray_image);
    let gy = imageproc::gradients::vertical_sobel(&gray_image);
    // convertScaleAbs-equivalent: |x|, saturated to u8.
    let grad_x: Vec<u8> = gx.pixels().map(|p| (p[0] as i32).unsigned_abs().min(255) as u8).collect();
    let grad_y: Vec<u8> = gy.pixels().map(|p| (p[0] as i32).unsigned_abs().min(255) as u8).collect();

    let col_signal = smooth_signal(&percentile_axis0_u8(&grad_x, w, h, 95.0), 31);
    let row_signal = smooth_signal(&percentile_axis1_u8(&grad_y, w, h, 95.0), 31);

    let (left_edge, _left_edge_value, left_inner, left_inner_value) = boundary_candidates(&col_signal, true);
    let (right_edge, _right_edge_value, right_inner, right_inner_value) = boundary_candidates(&col_signal, false);
    let (top_edge, top_edge_value, top_inner, top_inner_value) = boundary_candidates(&row_signal, true);
    let (bottom_edge, bottom_edge_value, bottom_inner, bottom_inner_value) = boundary_candidates(&row_signal, false);

    let col_noise_floor = percentile_of_f64(&col_signal, 75.0);
    let row_noise_floor = percentile_of_f64(&row_signal, 75.0);

    let mut left = left_edge;
    let mut right = right_edge + 1;
    let mut top = top_edge;
    let mut bottom = bottom_edge + 1;

    let (w_f, h_f) = (w as f64, h as f64);

    let use_inner_pair_x = left_inner >= (w_f * 0.12).round() as i64
        && right_inner <= (w_f * 0.88).round() as i64
        && left_inner_value >= col_noise_floor * 4.0
        && right_inner_value >= col_noise_floor * 4.0
        && (right_inner - left_inner) >= (w_f * 0.5).round() as i64;
    if use_inner_pair_x {
        left = left_inner;
        right = right_inner + 1;
    } else {
        if left_inner >= (w_f * 0.12).round() as i64 && left_inner_value >= col_noise_floor * 5.0 {
            left = left_inner;
        }
        if right_inner <= (w_f * 0.88).round() as i64 && right_inner_value >= col_noise_floor * 5.0 {
            right = right_inner + 1;
        }
    }

    let use_inner_pair_y = top_inner > top_edge + 20
        && bottom_inner < bottom_edge - 20
        && top_inner_value > (top_edge_value * 1.2).max(row_noise_floor + 25.0)
        && bottom_inner_value > (bottom_edge_value * 1.2).max(row_noise_floor + 25.0)
        && (bottom_inner - top_inner) >= (h_f * 0.5).round() as i64;
    if use_inner_pair_y {
        top = top_inner;
        bottom = bottom_inner + 1;
    } else {
        if top_inner > top_edge + 20 && top_inner_value > (top_edge_value * 1.45).max(row_noise_floor + 35.0) {
            top = top_inner;
        }
        if bottom_inner < bottom_edge - 20 && bottom_inner_value > (bottom_edge_value * 1.45).max(row_noise_floor + 35.0) {
            bottom = bottom_inner + 1;
        }
    }

    let pad_x = ((w_f * 0.004).round() as i64).max(4);
    let pad_y = ((h_f * 0.004).round() as i64).max(4);
    left = (left - pad_x).max(0);
    right = (right + pad_x).min(w as i64);
    top = (top - pad_y).max(0);
    bottom = (bottom + pad_y).min(h as i64);

    let min_width = ((w_f * 0.5).round() as i64).max(1);
    let min_height = ((h_f * 0.5).round() as i64).max(1);
    if right - left < min_width {
        left = 0;
        right = w as i64;
    }
    if bottom - top < min_height {
        top = 0;
        bottom = h as i64;
    }

    let refined_area_ratio = ((right - left) as f64 * (bottom - top) as f64) / (h_f * w_f).max(1.0);
    if let Some((dl, dt, dr, db)) = dark_region_bounds(image) {
        if refined_area_ratio > 0.8 {
            let dark_area_ratio = ((dr as i64 - dl as i64) as f64 * (db as i64 - dt as i64) as f64) / (h_f * w_f).max(1.0);
            if (0.15..=0.85).contains(&dark_area_ratio) {
                left = dl as i64;
                top = dt as i64;
                right = dr as i64;
                bottom = db as i64;
            }
        }
    }

    (left.max(0) as u32, top.max(0) as u32, right.max(0) as u32, bottom.max(0) as u32)
}

// ---------------------------------------------------------------------
// Tier-level estimation + rebate detection
// (_TierLevels, _find_rebate_level, _estimate_tier_levels,
// _longest_run_above, _refine_film_roi_by_tiers, _refine_roi_to_image)
// ---------------------------------------------------------------------

#[derive(Debug, Clone, Copy)]
struct TierLevels {
    #[allow(dead_code)] // mirrors the Python source's own unused-by-callers `bed` field
    bed: f64,
    rebate: f64,
    image: f64,
    ring_spread: f64,
}

/// Searches the four border strips inside the film box for a rebate
/// plateau. Returns `(rebate_level, spread)` or `None`. Matches the
/// Python source's own `_find_rebate_level(lum, film_roi)` signature --
/// no `height` parameter is needed since `lum` is already a flat
/// full-image buffer and `width` alone suffices to index it.
fn find_rebate_level(lum: &[f64], width: u32, film_roi: Roi) -> Option<(f64, f64)> {
    let (y1, y2, x1, x2) = (film_roi.y1, film_roi.y2, film_roi.x1, film_roi.x2);
    let bh = (y2 - y1) as i64;
    let bw = (x2 - x1) as i64;
    if bh < 16 || bw < 16 {
        return None;
    }

    let bed = percentile_of_f64(lum, 99.0);
    let box_vals = extract_rect(lum, width, y1, y2, x1, x2);
    let box_median = percentile_of_f64(&box_vals, 50.0);

    let ring_w = (3i64).max(((0.04 * bh.min(bw) as f64)).round() as i64) as u32;

    let top_strip = extract_rect(lum, width, y1, (y1 + ring_w).min(y2), x1, x2);
    let bottom_strip = extract_rect(lum, width, (y2.saturating_sub(ring_w)).max(y1), y2, x1, x2);
    let left_strip = extract_rect(lum, width, y1, y2, x1, (x1 + ring_w).min(x2));
    let right_strip = extract_rect(lum, width, y1, y2, (x2.saturating_sub(ring_w)).max(x1), x2);

    let sides: [(&str, &Vec<f64>); 4] = [
        ("top", &top_strip),
        ("bottom", &bottom_strip),
        ("left", &left_strip),
        ("right", &right_strip),
    ];

    let mut qualifying: Vec<(&str, f64, f64)> = Vec::new();
    for (name, strip) in sides {
        let vals: Vec<f64> = strip.iter().copied().filter(|&v| v < bed - 0.05).collect();
        if (vals.len() as f64) < 0.25 * strip.len() as f64 {
            continue;
        }
        let spread = percentile_of_f64(&vals, 80.0) - percentile_of_f64(&vals, 20.0);
        if spread > 0.10 {
            continue;
        }
        let p60 = percentile_of_f64(&vals, 60.0);
        if p60 < box_median + 0.10 {
            continue;
        }
        qualifying.push((name, p60, spread));
    }

    let has = |n: &str| qualifying.iter().any(|q| q.0 == n);
    let has_pair = (has("top") && has("bottom")) || (has("left") && has("right"));
    if !has_pair {
        return None;
    }

    let mut best: Option<(f64, f64)> = None;
    for (_, p60, spread) in qualifying {
        match best {
            None => best = Some((p60, spread)),
            Some((bp, _)) if p60 > bp => best = Some((p60, spread)),
            _ => {}
        }
    }
    best
}

/// Estimates the three luminance tiers (bed, rebate, exposed image) for a
/// film box. Returns `None` when the tiers are not reliably separable.
fn estimate_tier_levels(lum: &[f64], width: u32, film_roi: Roi) -> Option<TierLevels> {
    let (rebate, ring_spread) = find_rebate_level(lum, width, film_roi)?;
    let bed = percentile_of_f64(lum, 99.0);
    let box_vals = extract_rect(lum, width, film_roi.y1, film_roi.y2, film_roi.x1, film_roi.x2);
    let dark: Vec<f64> = box_vals.iter().copied().filter(|&v| v < rebate - 0.02).collect();
    if (dark.len() as f64) < 0.05 * box_vals.len() as f64 {
        return None;
    }
    let image_level = percentile_of_f64(&dark, 30.0);
    let separation = rebate - image_level;
    if separation < (0.04f64).max(3.0 * ring_spread) {
        return None;
    }
    Some(TierLevels { bed, rebate, image: image_level, ring_spread })
}

/// Longest contiguous half-open index run with `profile >= threshold`.
/// `np.argmax` semantics: first occurrence of the maximum span wins on
/// ties.
fn longest_run_above(profile: &[f64], threshold: f64) -> Option<(i64, i64)> {
    let idx: Vec<i64> = profile
        .iter()
        .enumerate()
        .filter(|(_, &v)| v >= threshold)
        .map(|(i, _)| i as i64)
        .collect();
    if idx.is_empty() {
        return None;
    }

    let mut starts = vec![0usize];
    let mut ends: Vec<usize> = Vec::new();
    for i in 0..idx.len() - 1 {
        if idx[i + 1] - idx[i] > 1 {
            ends.push(i);
            starts.push(i + 1);
        }
    }
    ends.push(idx.len() - 1);

    let mut best_k = 0usize;
    let mut best_span = idx[ends[0]] - idx[starts[0]];
    for k in 1..starts.len() {
        let span = idx[ends[k]] - idx[starts[k]];
        if span > best_span {
            best_span = span;
            best_k = k;
        }
    }
    Some((idx[starts[best_k]], idx[ends[best_k]] + 1))
}

/// Tier-based image-area refinement. Returns `(roi, row_occupancy,
/// col_occupancy)` in detection-image coords (profiles padded to full
/// image length), or `None` when tiers are not separable (caller falls
/// back to the Sobel path).
fn refine_film_roi_by_tiers(lum: &[f64], width: u32, height: u32, film_roi: Roi) -> Option<(Roi, Vec<f64>, Vec<f64>)> {
    let levels = estimate_tier_levels(lum, width, film_roi)?;
    let (y1, y2, x1, x2) = (film_roi.y1, film_roi.y2, film_roi.x1, film_roi.x2);
    let bh = (y2 - y1) as usize;
    let bw = (x2 - x1) as usize;
    let box_vals = extract_rect(lum, width, y1, y2, x1, x2);

    let threshold = (0.5 * (levels.rebate + levels.image)).max(levels.rebate - (0.04f64).max(3.0 * levels.ring_spread));

    let row_occ: Vec<f64> = (0..bh)
        .map(|r| {
            let count = (0..bw).filter(|&c| box_vals[r * bw + c] < threshold).count();
            count as f64 / bw as f64
        })
        .collect();
    let (vt0, vb0) = longest_run_above(&row_occ, 0.55)?;
    let (vt_u, vb_u) = (vt0 as usize, vb0 as usize);

    let col_occ: Vec<f64> = (0..bw)
        .map(|c| {
            let count = (vt_u..vb_u).filter(|&r| box_vals[r * bw + c] < threshold).count();
            count as f64 / (vb_u - vt_u).max(1) as f64
        })
        .collect();
    let (hl0, hr0) = longest_run_above(&col_occ, 0.55)?;

    let (mut vt, mut vb) = (vt0, vb0);
    let (mut hl, mut hr) = (hl0, hr0);

    if ((vb - vt) as f64) < 0.35 * bh as f64 || ((hr - hl) as f64) < 0.35 * bw as f64 {
        return None;
    }
    let area_ratio = ((vb - vt) as f64 * (hr - hl) as f64) / (bh as f64 * bw as f64);
    if !(0.15..=0.95).contains(&area_ratio) {
        return None;
    }

    let (hl_u, hr_u) = (hl as usize, hr as usize);
    let col_profile: Vec<f64> = (0..bw)
        .map(|c| {
            let mut sum = 0.0;
            for r in vt_u..vb_u {
                sum += box_vals[r * bw + c];
            }
            sum / (vb_u - vt_u).max(1) as f64
        })
        .collect();
    let row_profile: Vec<f64> = (0..bh)
        .map(|r| {
            let mut sum = 0.0;
            for c in hl_u..hr_u {
                sum += box_vals[r * bw + c];
            }
            sum / (hr_u - hl_u).max(1) as f64
        })
        .collect();

    // _snap_edge_to_gradient's OWN defaults (window_out=0.06, window_in=
    // 0.02, min_dominance=2.0, min_window_px=3) -- NOT the explicit
    // bed-gradient params used by snap_film_bounds_to_bed_gradient.
    hl = snap_edge_to_gradient(&col_profile, hl, true, 0.06, 0.02, 2.0, 3);
    hr = snap_edge_to_gradient(&col_profile, hr, false, 0.06, 0.02, 2.0, 3);
    vt = snap_edge_to_gradient(&row_profile, vt, true, 0.06, 0.02, 2.0, 3);
    vb = snap_edge_to_gradient(&row_profile, vb, false, 0.06, 0.02, 2.0, 3);

    let pad_y = (2i64).max((0.004 * bh as f64).round() as i64);
    let pad_x = (2i64).max((0.004 * bw as f64).round() as i64);
    vt = 0.max(vt - pad_y);
    vb = (bh as i64).min(vb + pad_y);
    hl = 0.max(hl - pad_x);
    hr = (bw as i64).min(hr + pad_x);
    if vb - vt <= 0 || hr - hl <= 0 {
        return None;
    }

    let mut row_occ_full = vec![0.0; height as usize];
    for (i, &v) in row_occ.iter().enumerate() {
        row_occ_full[y1 as usize + i] = v;
    }
    let mut col_occ_full = vec![0.0; width as usize];
    for (i, &v) in col_occ.iter().enumerate() {
        col_occ_full[x1 as usize + i] = v;
    }

    Some((
        Roi {
            y1: (y1 as i64 + vt) as u32,
            y2: (y1 as i64 + vb) as u32,
            x1: (x1 as i64 + hl) as u32,
            x2: (x1 as i64 + hr) as u32,
        },
        row_occ_full,
        col_occ_full,
    ))
}

/// Refines a film-extent ROI inward to the exposed image area (rebate
/// excluded). Tier-based refinement first; Sobel gradient refinement as
/// fallback. Occupancy profiles are only ever populated by the
/// tier-based path, matching `_refine_roi_to_image`'s own
/// `(roi, row_occupancy | None, col_occupancy | None)` contract.
enum RefinedRoi {
    WithOccupancy(Roi, Vec<f64>, Vec<f64>),
    Plain(Roi),
}

fn refine_roi_to_image(img: &GeometryImage, film_roi: Roi) -> RefinedRoi {
    let lum = detection_luma(img);
    if let Some((roi, row_occ, col_occ)) = refine_film_roi_by_tiers(&lum, img.width, img.height, film_roi) {
        return RefinedRoi::WithOccupancy(roi, row_occ, col_occ);
    }

    if find_rebate_level(&lum, img.width, film_roi).is_none() {
        // No uniform rebate plateau on any side = image content runs to
        // the film edge (full-bleed frame). Nothing to refine away.
        return RefinedRoi::Plain(film_roi);
    }

    let (y1, y2, x1, x2) = (film_roi.y1, film_roi.y2, film_roi.x1, film_roi.x2);
    let sub = extract_geometry_subimage(img, y1, y2, x1, x2);
    let (ref_left, ref_top, ref_right, ref_bottom) = refine_frame_bounds(&sub);
    let roi = Roi {
        y1: y1 + ref_top,
        y2: y1 + ref_bottom,
        x1: x1 + ref_left,
        x2: x1 + ref_right,
    };

    let film_area = (((y2 - y1) as u64) * ((x2 - x1) as u64)).max(1);
    let roi_area = ((roi.y2 - roi.y1) as u64) * ((roi.x2 - roi.x1) as u64);
    if (roi_area as f64) < 0.75 * film_area as f64 {
        return RefinedRoi::Plain(film_roi);
    }
    RefinedRoi::Plain(roi)
}

// ---------------------------------------------------------------------
// Threshold fallback + opaque-border trim
// (_get_threshold_autocrop_coords, _trim_opaque_border)
// ---------------------------------------------------------------------

/// Luminance-threshold fallback. Expects a detection-resolution image;
/// returns a det-space ROI. Note the intentional `(0, H-1, 0, W-1)`
/// (last-qualifying-index, not exclusive bound) shape -- an off-by-one
/// baked into the Python source itself, ported exactly per this plan's
/// `<autocrop_ground_truth>`.
fn get_threshold_autocrop_coords(img: &GeometryImage, assist_luma: Option<f64>) -> Roi {
    let (h, w) = (img.height, img.width);
    let lum = raw_luminance(img);
    let threshold = match assist_luma {
        Some(a) => (a - 0.02).clamp(0.5, 0.98),
        None => 0.96,
    };

    let row_means: Vec<f64> = (0..h)
        .map(|y| {
            let mut sum = 0.0;
            for x in 0..w {
                sum += lum[(y * w + x) as usize];
            }
            sum / w as f64
        })
        .collect();
    let col_means: Vec<f64> = (0..w)
        .map(|x| {
            let mut sum = 0.0;
            for y in 0..h {
                sum += lum[(y * w + x) as usize];
            }
            sum / h as f64
        })
        .collect();

    let rows_det: Vec<u32> = (0..h).filter(|&y| row_means[y as usize] < threshold).collect();
    let cols_det: Vec<u32> = (0..w).filter(|&x| col_means[x as usize] < threshold).collect();

    if rows_det.len() < 10 || cols_det.len() < 10 {
        return Roi { y1: 0, y2: h, x1: 0, x2: w };
    }

    Roi {
        y1: rows_det[0],
        y2: *rows_det.last().unwrap(),
        x1: cols_det[0],
        x2: *cols_det.last().unwrap(),
    }
}

/// Shrinks each ROI edge inward past a contiguous band of opaque
/// (near-black) pixels. An edge moves only while its border line is
/// dominated (>= `frac`) by sub-`black` pixels, capped at `max_trim` of
/// the side.
fn trim_opaque_border(lum: &[f64], width: u32, roi: Roi) -> Roi {
    const BLACK: f64 = 0.02;
    const FRAC: f64 = 0.7;
    const MAX_TRIM: f64 = 0.2;

    let (y1, y2, x1, x2) = (roi.y1, roi.y2, roi.x1, roi.x2);
    let bh = (y2 - y1) as i64;
    let bw = (x2 - x1) as i64;
    if bh < 4 || bw < 4 {
        return roi;
    }

    let row_black: Vec<f64> = (y1..y2)
        .map(|y| {
            let count = (x1..x2).filter(|&x| lum[(y * width + x) as usize] < BLACK).count();
            count as f64 / bw as f64
        })
        .collect();
    let col_black: Vec<f64> = (x1..x2)
        .map(|x| {
            let count = (y1..y2).filter(|&y| lum[(y * width + x) as usize] < BLACK).count();
            count as f64 / bh as f64
        })
        .collect();

    let run = |profile: &[f64], limit: i64, from_start: bool| -> i64 {
        let n = profile.len() as i64;
        let mut i = 0i64;
        while i < limit {
            let idx = if from_start { i } else { n - 1 - i };
            if idx < 0 || idx >= n || profile[idx as usize] < FRAC {
                break;
            }
            i += 1;
        }
        i
    };

    let ly = (MAX_TRIM * bh as f64).round() as i64;
    let lx = (MAX_TRIM * bw as f64).round() as i64;
    let top = run(&row_black, ly, true);
    let bottom = run(&row_black, ly, false);
    let left = run(&col_black, lx, true);
    let right = run(&col_black, lx, false);

    let ny1 = y1 as i64 + top;
    let ny2 = y2 as i64 - bottom;
    let nx1 = x1 as i64 + left;
    let nx2 = x2 as i64 - right;
    if ny2 - ny1 <= 0 || nx2 - nx1 <= 0 {
        return roi;
    }
    Roi { y1: ny1 as u32, y2: ny2 as u32, x1: nx1 as u32, x2: nx2 as u32 }
}

// ---------------------------------------------------------------------
// Margin + aspect-ratio enforcement
// (apply_margin_to_roi, _resolve_ratio_dims, enforce_roi_aspect_ratio,
// _place_window_by_occupancy, _enforce_ratio_by_occupancy,
// _closest_standard_ratio)
// ---------------------------------------------------------------------

/// Expands/contracts an ROI by `margin_px` on every edge (positive
/// shrinks, negative grows), clamped to `[0,h) x [0,w)`.
fn apply_margin_to_roi(roi: Roi, h: u32, w: u32, margin_px: f64) -> Roi {
    let y1 = roi.y1 as f64 + margin_px;
    let y2 = roi.y2 as f64 - margin_px;
    let x1 = roi.x1 as f64 + margin_px;
    let x2 = roi.x2 as f64 - margin_px;

    Roi {
        y1: (0.0f64.max(y1)).trunc().max(0.0) as u32,
        y2: (h as f64).min(y2).trunc().max(0.0) as u32,
        x1: (0.0f64.max(x1)).trunc().max(0.0) as u32,
        x2: (w as f64).min(x2).trunc().max(0.0) as u32,
    }
}

/// Returns `(target_w, target_h) <= (cw, ch)` for the orientation-corrected
/// ratio. Malformed `target_ratio_str` (wrong shape or non-numeric parts)
/// falls back to a 1.5 aspect, matching the Python source's own `except
/// ValueError` branch.
fn resolve_ratio_dims(cw: f64, ch: f64, target_ratio_str: &str) -> (f64, f64) {
    let parts: Vec<&str> = target_ratio_str.split(':').collect();
    let mut target_aspect = 1.5;
    if parts.len() == 2 {
        if let (Ok(w_r), Ok(h_r)) = (parts[0].parse::<f64>(), parts[1].parse::<f64>()) {
            let h_r = if h_r == 0.0 { 1.0 } else { h_r };
            target_aspect = w_r / h_r;
        }
    }

    let is_vertical = ch > cw;
    if is_vertical {
        if target_aspect > 1.0 {
            target_aspect = 1.0 / target_aspect;
        }
    } else if target_aspect < 1.0 {
        target_aspect = 1.0 / target_aspect;
    }

    let current_aspect = cw / ch;
    if current_aspect > target_aspect {
        (ch * target_aspect, ch)
    } else {
        (cw, cw / target_aspect)
    }
}

/// Centers ROI within an aspect ratio, clamped to `[0,h) x [0,w)`.
/// `target_ratio_str == "Free"` is a passthrough (still clamped).
fn enforce_roi_aspect_ratio(roi: Roi, h: u32, w: u32, target_ratio_str: &str) -> Roi {
    let (mut y1, mut y2, mut x1, mut x2) = (roi.y1 as f64, roi.y2 as f64, roi.x1 as f64, roi.x2 as f64);
    let cw = x2 - x1;
    let ch = y2 - y1;
    if cw <= 0.0 || ch <= 0.0 {
        return Roi { y1: 0, y2: h, x1: 0, x2: w };
    }
    if target_ratio_str == "Free" {
        return clamp_roi_f64(y1, y2, x1, x2, h, w);
    }

    let (target_w, target_h) = resolve_ratio_dims(cw, ch, target_ratio_str);
    if target_w < cw {
        let nx1 = x1 + (cw - target_w) / 2.0;
        let nx2 = nx1 + target_w;
        x1 = nx1.trunc();
        x2 = nx2.trunc();
    } else if target_h < ch {
        let ny1 = y1 + (ch - target_h) / 2.0;
        let ny2 = ny1 + target_h;
        y1 = ny1.trunc();
        y2 = ny2.trunc();
    }
    clamp_roi_f64(y1, y2, x1, x2, h, w)
}

fn clamp_roi_f64(y1: f64, y2: f64, x1: f64, x2: f64, h: u32, w: u32) -> Roi {
    Roi {
        y1: (0.0f64.max(y1)).trunc().max(0.0) as u32,
        y2: (h as f64).min(y2).trunc().max(0.0) as u32,
        x1: (0.0f64.max(x1)).trunc().max(0.0) as u32,
        x2: (w as f64).min(x2).trunc().max(0.0) as u32,
    }
}

/// Slides a `target_len` window within `[start, end)` (input coords) to
/// maximize summed occupancy (detection coords; `scale` = det/input
/// ratio). Ties resolve toward the centered position (first-minimum-
/// distance wins, matching `np.argmin`).
fn place_window_by_occupancy(start: f64, end: f64, target_len: f64, occupancy: &[f64], scale: f64) -> f64 {
    let d_start = (0i64).max((start * scale).round() as i64);
    let d_end = (occupancy.len() as i64).min((end * scale).round() as i64);
    let d_len = (1i64).max((target_len * scale).round() as i64);
    if d_len >= d_end - d_start {
        return start;
    }

    let (d_start_u, d_end_u) = (d_start as usize, d_end as usize);
    let mut cs = vec![0.0f64; (d_end_u - d_start_u) + 1];
    for i in 0..(d_end_u - d_start_u) {
        cs[i + 1] = cs[i] + occupancy[d_start_u + i];
    }
    let n_pos = ((d_end - d_start) - d_len + 1) as usize;
    let mut scores = Vec::with_capacity(n_pos);
    for i in 0..n_pos {
        scores.push(cs[(d_len as usize) + i] - cs[i]);
    }
    let max_score = scores.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let centered = ((d_end - d_start) - d_len) as f64 / 2.0;

    let mut best_k = 0usize;
    let mut best_dist = f64::INFINITY;
    for (k, &s) in scores.iter().enumerate() {
        if s >= max_score - 1e-9 {
            let dist = (k as f64 - centered).abs();
            if dist < best_dist {
                best_dist = dist;
                best_k = k;
            }
        }
    }

    let new_start = ((d_start as f64 + best_k as f64) / scale).round();
    (start.max(new_start).min(end - target_len)).trunc()
}

/// Like `enforce_roi_aspect_ratio`, but places the shrink-axis window
/// where the image-class occupancy is highest instead of blindly
/// centering.
#[allow(clippy::too_many_arguments)]
fn enforce_ratio_by_occupancy(
    roi: Roi,
    h: u32,
    w: u32,
    target_ratio_str: &str,
    row_occupancy: &[f64],
    col_occupancy: &[f64],
    det_scale: f64,
) -> Roi {
    let (mut y1, mut y2, mut x1, mut x2) = (roi.y1 as f64, roi.y2 as f64, roi.x1 as f64, roi.x2 as f64);
    let cw = x2 - x1;
    let ch = y2 - y1;
    if cw <= 0.0 || ch <= 0.0 {
        return Roi { y1: 0, y2: h, x1: 0, x2: w };
    }
    if target_ratio_str == "Free" {
        return clamp_roi_f64(y1, y2, x1, x2, h, w);
    }

    let (target_w, target_h) = resolve_ratio_dims(cw, ch, target_ratio_str);
    if target_w < cw {
        x1 = place_window_by_occupancy(x1, x2, target_w, col_occupancy, det_scale);
        x2 = (x1 + target_w).round();
    } else if target_h < ch {
        y1 = place_window_by_occupancy(y1, y2, target_h, row_occupancy, det_scale);
        y2 = (y1 + target_h).round();
    }
    clamp_roi_f64(y1, y2, x1, x2, h, w)
}

/// Standard candidate ratios (excludes Free/Original), in NegPy's own
/// `AspectRatio` enum declaration order (tie-break order matters: `min()`
/// keeps the first minimal-distance candidate).
const STANDARD_RATIOS: [(&str, f64, f64); 11] = [
    ("3:2", 3.0, 2.0),
    ("4:3", 4.0, 3.0),
    ("5:4", 5.0, 4.0),
    ("6:7", 6.0, 7.0),
    ("1:1", 1.0, 1.0),
    ("65:24", 65.0, 24.0),
    ("2:3", 2.0, 3.0),
    ("3:4", 3.0, 4.0),
    ("4:5", 4.0, 5.0),
    ("7:6", 7.0, 6.0),
    ("24:65", 24.0, 65.0),
];

/// Returns the standard ratio string closest to the ROI's aspect
/// (log-space distance), sanity-checked against the full image
/// dimensions.
fn closest_standard_ratio(roi: Roi, img_height: u32, img_width: u32, fallback: &str) -> String {
    let cw = roi.x2 as f64 - roi.x1 as f64;
    let ch = roi.y2 as f64 - roi.y1 as f64;
    if cw <= 0.0 || ch <= 0.0 {
        return fallback.to_string();
    }
    let detected = cw / ch;
    let is_landscape = cw >= ch;

    let mut candidates: Vec<(&str, f64)> = Vec::new();
    for &(name, w_r, h_r) in STANDARD_RATIOS.iter() {
        let target = w_r / h_r;
        let target_landscape = target >= 1.0;
        if is_landscape != target_landscape && target != 1.0 {
            continue;
        }
        candidates.push((name, target));
    }
    if candidates.is_empty() {
        return fallback.to_string();
    }

    let log_dist = |a: f64, b: f64| (a.max(1e-6).ln() - b.max(1e-6).ln()).abs();

    let mut best = candidates[0];
    let mut best_dist = log_dist(detected, best.1);
    for &c in candidates.iter().skip(1) {
        let d = log_dist(detected, c.1);
        if d < best_dist {
            best_dist = d;
            best = c;
        }
    }

    let img_ratio = img_width as f64 / img_height as f64;
    if log_dist(img_ratio, best.1) > 0.3 {
        let mut best2 = candidates[0];
        let mut best2_dist = log_dist(img_ratio, best2.1);
        for &c in candidates.iter().skip(1) {
            let d = log_dist(img_ratio, c.1);
            if d < best2_dist {
                best2_dist = d;
                best2 = c;
            }
        }
        best = best2;
    }

    best.0.to_string()
}

// ---------------------------------------------------------------------
// Public entry point (get_autocrop_coords)
// ---------------------------------------------------------------------

/// Batch autocrop entry point -- ports `get_autocrop_coords` exactly,
/// including its margin + aspect-ratio-enforcement tail.
/// `target_ratio_str` matches NegPy's own strings ("3:2", "Free", etc.);
/// "3:2" is NegPy's own default and this phase's parity-test ratio. The
/// Python source's `assist_point` parameter is dead/vestigial (never
/// referenced in the function body) and is not ported.
pub fn autocrop_roi(
    img: &GeometryImage,
    mode: AutocropMode,
    offset_px: i32,
    scale_factor: f64,
    target_ratio_str: &str,
    detect_res: u32,
    assist_luma: Option<f64>,
) -> Roi {
    let (h, w) = (img.height, img.width);
    let (det, det_scale) = normalize_detection_input(img, detect_res);

    let film_roi_contours = detect_film_bounds(&det);
    let from_contours = film_roi_contours.is_some();
    let mut film_roi = film_roi_contours.unwrap_or_else(|| get_threshold_autocrop_coords(&det, assist_luma));

    let det_lum = detection_luma(&det);
    film_roi = trim_opaque_border(&det_lum, det.width, film_roi);

    let (roi_pre_scale, row_occ, col_occ) = if mode == AutocropMode::Film || !from_contours {
        (film_roi, None, None)
    } else {
        match refine_roi_to_image(&det, film_roi) {
            RefinedRoi::WithOccupancy(roi, r, c) => (roi, Some(r), Some(c)),
            RefinedRoi::Plain(roi) => (roi, None, None),
        }
    };

    let roi_scaled = scale_roi(roi_pre_scale, det_scale, h, w);

    let ratio_str: String = if target_ratio_str == "Free" {
        closest_standard_ratio(roi_scaled, h, w, "3:2")
    } else {
        target_ratio_str.to_string()
    };

    let margin = (2.0 + offset_px as f64) * scale_factor;
    let roi_margined = apply_margin_to_roi(roi_scaled, h, w, margin);

    match (row_occ, col_occ) {
        (Some(r), Some(c)) => enforce_ratio_by_occupancy(roi_margined, h, w, &ratio_str, &r, &c, det_scale),
        _ => enforce_roi_aspect_ratio(roi_margined, h, w, &ratio_str),
    }
}

// ---------------------------------------------------------------------
// Tests -- ground truth generated directly from the real
// negpy.features.geometry.logic against real hand-built synthetic images
// (plan 15-01's <rotation_algorithm> and <autocrop_ground_truth> blocks).
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- Group R: rotation -------------------------------------------

    const ROTATION_EPSILON: f64 = 1e-5;

    fn assert_close(actual: f64, expected: f64, context: &str) {
        assert!(
            (actual - expected).abs() < ROTATION_EPSILON,
            "{context}: expected {expected}, got {actual} (diff {})",
            (actual - expected).abs()
        );
    }

    fn assert_pixel_close(actual: [f32; 3], expected: [f64; 3], context: &str) {
        for c in 0..3 {
            assert_close(actual[c] as f64, expected[c], &format!("{context}[{c}]"));
        }
    }

    /// 6x8x3 synthetic test image: v = 0.05 + 0.9*(((y*8+x)*37) % 97)/97.0
    /// for channel 0; channel 1 = v*0.6+0.1; channel 2 = v*0.3+0.2.
    fn make_rotation_test_image() -> GeometryImage {
        let width = 8u32;
        let height = 6u32;
        let mut pixels = Vec::with_capacity((width * height) as usize);
        for y in 0..height {
            for x in 0..width {
                let idx = (y * width + x) as i64;
                let v = 0.05 + 0.9 * (((idx * 37) % 97) as f64) / 97.0;
                pixels.push([v as f32, (v * 0.6 + 0.1) as f32, (v * 0.3 + 0.2) as f32]);
            }
        }
        GeometryImage { width, height, pixels }
    }

    #[test]
    fn group_r_rotation_matrix_2x3_matches_ground_truth() {
        let m1 = rotation_matrix_2x3(1.75, 8, 6);
        let expected1 = [
            [0.9995335908367129, 0.03053851320982266, -0.08974990297631955],
            [-0.03053851320982266, 0.9995335908367129, 0.12355328032915196],
        ];
        for r in 0..2 {
            for c in 0..3 {
                assert_close(m1[r][c], expected1[r][c], &format!("m1[{r}][{c}]"));
            }
        }

        let m2 = rotation_matrix_2x3(-3.2, 8, 6);
        let expected2 = [
            [0.998440764181981, -0.0558215049931638, 0.17370145825156733],
            [0.0558215049931638, 0.998440764181981, -0.21860831251859827],
        ];
        for r in 0..2 {
            for c in 0..3 {
                assert_close(m2[r][c], expected2[r][c], &format!("m2[{r}][{c}]"));
            }
        }
    }

    #[test]
    fn group_r_center_pixel_invariant_under_rotation() {
        let img = make_rotation_test_image();
        let expected = [0.6623711585998535, 0.4974226951599121, 0.39871135354042053];
        for angle in [1.75, -3.2, 12.0] {
            let rotated = apply_fine_rotation(&img, angle);
            let actual = rotated.pixels[(3 * img.width + 4) as usize];
            assert_pixel_close(actual, expected, &format!("center pixel at angle {angle}"));
        }
    }

    #[test]
    fn group_r_apply_fine_rotation_corner_pixels_at_1_75_degrees() {
        let img = make_rotation_test_image();
        let rotated = apply_fine_rotation(&img, 1.75);
        let w = img.width;
        assert_pixel_close(
            rotated.pixels[(0 * w + 0) as usize],
            [0.08209199458360672, 0.1492551863193512, 0.22462759912014008],
            "[0,0] at 1.75deg",
        );
        assert_pixel_close(
            rotated.pixels[(0 * w + 7) as usize],
            [0.6574079394340515, 0.49444475769996643, 0.3972223699092865],
            "[0,7] at 1.75deg",
        );
        assert_pixel_close(
            rotated.pixels[(5 * w + 0) as usize],
            [0.2762485444545746, 0.26574912667274475, 0.28287455439567566],
            "[5,0] at 1.75deg",
        );
        assert_pixel_close(
            rotated.pixels[(5 * w + 7) as usize],
            [0.8636035323143005, 0.6181620955467224, 0.4590810537338257],
            "[5,7] at 1.75deg",
        );
    }

    #[test]
    fn group_r_apply_fine_rotation_corner_pixels_at_neg_3_2_degrees() {
        let img = make_rotation_test_image();
        let rotated = apply_fine_rotation(&img, -3.2);
        let w = img.width;
        assert_pixel_close(
            rotated.pixels[(0 * w + 0) as usize],
            [0.060575637966394424, 0.13634537160396576, 0.21817269921302795],
            "[0,0] at -3.2deg",
        );
        assert_pixel_close(
            rotated.pixels[(5 * w + 7) as usize],
            [0.8771378993988037, 0.6262827515602112, 0.46314138174057007],
            "[5,7] at -3.2deg",
        );
    }

    #[test]
    fn group_r_apply_fine_rotation_zero_degrees_is_exact_identity() {
        let img = make_rotation_test_image();
        let rotated = apply_fine_rotation(&img, 0.0);
        assert_eq!(rotated, img, "angle=0.0 must be an exact identity, no computation");
    }

    #[test]
    fn group_r_border_replicate_5x5_at_25_degrees() {
        let width = 5u32;
        let height = 5u32;
        let mut pixels = Vec::with_capacity(25);
        for y in 0..height {
            for x in 0..width {
                let v = 0.1 * (y as f64 + 1.0) + 0.02 * x as f64;
                pixels.push([v as f32, v as f32, v as f32]);
            }
        }
        let img = GeometryImage { width, height, pixels };
        let rotated = apply_fine_rotation(&img, 25.0);

        let expected_rows: [[f64; 5]; 5] = [
            [0.1258155256509781, 0.14394168555736542, 0.16435997188091278, 0.22455397248268127, 0.26681581139564514],
            [0.1257624328136444, 0.1861504167318344, 0.24653840065002441, 0.3069263696670532, 0.357446551322937],
            [0.20794084668159485, 0.26832881569862366, 0.32871681451797485, 0.38910481333732605, 0.44807735085487366],
            [0.2901192903518677, 0.3505072593688965, 0.4108952581882477, 0.4712832272052765, 0.5316712260246277],
            [0.380291610956192, 0.43268564343452454, 0.49307361245155334, 0.5463845729827881, 0.564510703086853],
        ];
        for (row, expected_row) in expected_rows.iter().enumerate() {
            for (col, &expected) in expected_row.iter().enumerate() {
                let actual = rotated.pixels[row * (width as usize) + col][0] as f64;
                assert_close(actual, expected, &format!("border-replicate row{row} col{col}"));
            }
        }
    }

    // -- Group F: film-bounds detection --------------------------------

    /// The <autocrop_ground_truth> synthetic "film scan" image: W=480,
    /// H=320. Bright bed at 0.95, film rebate rect at 0.55, an 18px-inset
    /// content rect with a per-pixel gradient + sinusoidal texture.
    fn make_autocrop_test_image() -> GeometryImage {
        let width = 480u32;
        let height = 320u32;
        let mut pixels = vec![[0.95f32, 0.95f32, 0.95f32]; (width * height) as usize];

        for y in 40..280u32 {
            for x in 40..440u32 {
                let idx = (y * width + x) as usize;
                pixels[idx] = [0.55, 0.55, 0.55];
            }
        }

        for y in 58..262u32 {
            for x in 58..422u32 {
                let base = 0.15
                    + 0.20 * ((x - 58) as f64 / (422 - 58) as f64)
                    + 0.025 * ((y as f64) * 0.3).sin()
                    + 0.05;
                let idx = (y * width + x) as usize;
                pixels[idx] = [
                    (base * (0.8 + 0.1 * 0.0)) as f32,
                    (base * (0.8 + 0.1 * 1.0)) as f32,
                    (base * (0.8 + 0.1 * 2.0)) as f32,
                ];
            }
        }

        GeometryImage { width, height, pixels }
    }

    /// +/-5px tolerance per edge: absorbs legitimate imageproc-vs-cv2
    /// numerical differences in contour/morphology results (border padding
    /// convention, min-area-rect corner snapping, Otsu tie-breaking).
    ///
    /// Investigated against the real reference implementation directly
    /// (ran negpy.features.geometry.logic with numpy/cv2 installed
    /// locally, traced every intermediate value): this synthetic image's
    /// clean two-level step edge makes `_snap_edge_to_gradient`'s gradient
    /// array a mathematically EXACT tie across `window` consecutive
    /// positions (a uniform-height step divided by a uniform box-filter
    /// window necessarily produces identical deltas at every position
    /// inside the transition). This Rust port's f32 accumulation resolves
    /// that tie exactly (verified: 5 bit-identical gradient values), while
    /// real numpy's internal convolution accumulation order introduces
    /// its own implementation-defined, undocumented rounding noise at the
    /// 1e-7 scale that breaks the tie in numpy's favor toward a specific
    /// (but not portably-reproducible) position. Confirmed by direct
    /// comparison: same col_profile (matching to 6 decimals), same
    /// smoothing window (5), same lo/hi search bounds -- only the
    /// winning index within an exactly-tied gradient plateau differs.
    /// Worst case spread equals `window - 1`; for this test's window=5
    /// that is 4px, so 5px covers the observed deviation with margin.
    /// This is exactly the class of primitive-substitution noise this
    /// plan's own mapping table anticipates, not a logic bug -- real
    /// (noisy, non-degenerate) scan content will not exhibit this
    /// pathological perfect-tie structure.
    const FILM_BOUNDS_TOLERANCE_PX: i64 = 5;

    fn assert_roi_close(actual: Roi, expected: (u32, u32, u32, u32), tolerance: i64, context: &str) {
        let (ey1, ey2, ex1, ex2) = expected;
        let checks = [
            (actual.y1 as i64, ey1 as i64, "y1"),
            (actual.y2 as i64, ey2 as i64, "y2"),
            (actual.x1 as i64, ex1 as i64, "x1"),
            (actual.x2 as i64, ex2 as i64, "x2"),
        ];
        for (a, e, field) in checks {
            assert!(
                (a - e).abs() <= tolerance,
                "{context}.{field}: expected {e} +/-{tolerance}, got {a}"
            );
        }
    }

    #[test]
    fn group_f_detect_film_bounds_matches_ground_truth() {
        let img = make_autocrop_test_image();
        let roi = detect_film_bounds(&img);
        assert!(roi.is_some(), "contour path must fire (not the caller's own fallback)");
        assert_roi_close(roi.unwrap(), (37, 282, 40, 444), FILM_BOUNDS_TOLERANCE_PX, "detect_film_bounds");
    }

    // -- Group T: tier + Sobel refinement --------------------------------

    /// Scalar tier-level tolerance: rebate/image/bed are percentiles
    /// computed over the film-box interior, which shifts slightly when
    /// `detect_film_bounds`'s own contour-detected `film_roi` differs by
    /// a few px from the literal ground truth (same root cause as
    /// `FILM_BOUNDS_TOLERANCE_PX`, propagated one stage downstream).
    const TIER_LEVEL_EPSILON: f64 = 0.02;

    fn assert_tier_close(actual: f64, expected: f64, context: &str) {
        assert!(
            (actual - expected).abs() < TIER_LEVEL_EPSILON,
            "{context}: expected {expected}, got {actual} (diff {})",
            (actual - expected).abs()
        );
    }

    #[test]
    fn group_t_find_rebate_level_matches_ground_truth() {
        let img = make_autocrop_test_image();
        let film_roi = detect_film_bounds(&img).expect("contour path must fire");
        let lum = detection_luma(&img);
        let (rebate, spread) = find_rebate_level(&lum, img.width, film_roi).expect("rebate must be found");
        assert_tier_close(rebate, 0.5789473652839661, "rebate");
        assert_tier_close(spread, 0.0, "ring_spread");
    }

    #[test]
    fn group_t_estimate_tier_levels_matches_ground_truth() {
        let img = make_autocrop_test_image();
        let film_roi = detect_film_bounds(&img).expect("contour path must fire");
        let lum = detection_luma(&img);
        let levels = estimate_tier_levels(&lum, img.width, film_roi).expect("tiers must be separable");
        assert_tier_close(levels.bed, 1.0, "bed");
        assert_tier_close(levels.rebate, 0.5789473652839661, "rebate");
        assert_tier_close(levels.image, 0.24259716272354126, "image");
        assert_tier_close(levels.ring_spread, 0.0, "ring_spread");
    }

    #[test]
    fn group_t_refine_film_roi_by_tiers_matches_ground_truth() {
        let img = make_autocrop_test_image();
        let film_roi = detect_film_bounds(&img).expect("contour path must fire");
        let lum = detection_luma(&img);
        let (roi, row_occ, col_occ) =
            refine_film_roi_by_tiers(&lum, img.width, img.height, film_roi).expect("tier refinement must succeed");
        assert_roi_close(roi, (55, 265, 40, 444), FILM_BOUNDS_TOLERANCE_PX, "refine_film_roi_by_tiers");
        assert_eq!(row_occ.len(), img.height as usize, "row occupancy padded to full image height");
        assert_eq!(col_occ.len(), img.width as usize, "col occupancy padded to full image width");
    }

    // -- Group E: end-to-end autocrop_roi --------------------------------

    /// Slightly looser than Group F/T: end-to-end composes contour
    /// detection, tier refinement, margin, and aspect-ratio enforcement,
    /// so small per-stage deviations (each individually within their own
    /// documented tolerance) can compound across stages.
    const AUTOCROP_ROI_TOLERANCE_PX: i64 = 6;

    #[test]
    fn group_e_autocrop_roi_film_mode_matches_ground_truth() {
        let img = make_autocrop_test_image();
        let roi = autocrop_roi(&img, AutocropMode::Film, 0, 1.0, "3:2", 1800, None);
        assert_roi_close(roi, (39, 280, 61, 422), AUTOCROP_ROI_TOLERANCE_PX, "autocrop_roi(Film)");
    }

    #[test]
    fn group_e_autocrop_roi_image_mode_matches_ground_truth() {
        let img = make_autocrop_test_image();
        let roi = autocrop_roi(&img, AutocropMode::Image, 0, 1.0, "3:2", 1800, None);
        assert_roi_close(roi, (57, 263, 87, 396), AUTOCROP_ROI_TOLERANCE_PX, "autocrop_roi(Image)");
    }

    // -- Group X: fallback path -------------------------------------------

    fn make_uniform_test_image(width: u32, height: u32, value: f32) -> GeometryImage {
        GeometryImage {
            width,
            height,
            pixels: vec![[value; 3]; (width as usize) * (height as usize)],
        }
    }

    #[test]
    fn group_x_threshold_autocrop_coords_uniform_image_off_by_one() {
        let img = make_uniform_test_image(300, 200, 0.5);
        let roi = get_threshold_autocrop_coords(&img, None);
        // (0, H-1, 0, W-1) -- last qualifying index, NOT an exclusive
        // bound. An intentional-looking off-by-one baked into the Python
        // source itself; ported exactly, not "fixed."
        assert_eq!(roi, Roi { y1: 0, y2: 199, x1: 0, x2: 299 });
    }

    #[test]
    fn group_x_autocrop_roi_uniform_image_matches_ground_truth() {
        let img = make_uniform_test_image(300, 200, 0.5);
        let roi = autocrop_roi(&img, AutocropMode::Image, 0, 1.0, "3:2", 1800, None);
        assert_roi_close(roi, (2, 198, 3, 297), FILM_BOUNDS_TOLERANCE_PX, "autocrop_roi(uniform)");
    }

    // -- Group M: margin/ratio (pure arithmetic, exact) -------------------

    #[test]
    fn group_m_apply_margin_to_roi_shrink() {
        let roi = Roi { y1: 10, y2: 90, x1: 5, x2: 95 };
        let result = apply_margin_to_roi(roi, 100, 100, 3.0);
        assert_eq!(result, Roi { y1: 13, y2: 87, x1: 8, x2: 92 });
    }

    #[test]
    fn group_m_apply_margin_to_roi_expand_clamped_to_full_frame() {
        let roi = Roi { y1: 0, y2: 100, x1: 0, x2: 100 };
        let result = apply_margin_to_roi(roi, 100, 100, -5.0);
        assert_eq!(result, Roi { y1: 0, y2: 100, x1: 0, x2: 100 });
    }

    #[test]
    fn group_m_enforce_roi_aspect_ratio_3_2() {
        let roi = Roi { y1: 0, y2: 100, x1: 0, x2: 100 };
        let result = enforce_roi_aspect_ratio(roi, 200, 200, "3:2");
        assert_eq!(result, Roi { y1: 16, y2: 83, x1: 0, x2: 100 });
    }

    #[test]
    fn group_m_enforce_roi_aspect_ratio_free_is_passthrough() {
        let roi = Roi { y1: 0, y2: 100, x1: 0, x2: 100 };
        let result = enforce_roi_aspect_ratio(roi, 200, 200, "Free");
        assert_eq!(result, Roi { y1: 0, y2: 100, x1: 0, x2: 100 });
    }

    // -- Group U: utilities ---------------------------------------------

    const TIGHT_EPSILON: f64 = 1e-6;

    fn assert_tight(actual: f64, expected: f64, context: &str) {
        assert!(
            (actual - expected).abs() < TIGHT_EPSILON,
            "{context}: expected {expected}, got {actual} (diff {})",
            (actual - expected).abs()
        );
    }

    #[test]
    fn group_u_smooth_signal_window_3_matches_ground_truth() {
        let input = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0];
        let expected = [
            1.0,
            2.3333334922790527,
            4.6666669845581055,
            9.333333969116211,
            18.666667938232422,
            37.333335876464844,
            32.0,
        ];
        let actual = smooth_signal(&input, 3);
        for (i, (&a, &e)) in actual.iter().zip(expected.iter()).enumerate() {
            assert_tight(a, e, &format!("smooth_signal(window=3)[{i}]"));
        }
    }

    #[test]
    fn group_u_smooth_signal_window_1_is_passthrough() {
        let input = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0];
        let actual = smooth_signal(&input, 1);
        assert_eq!(actual, input.to_vec());
    }

    #[test]
    fn group_u_bgr_to_gray_u8_matches_real_cv2_probes() {
        // Positional weights (cv2 treats index 0 as its own "B" slot and
        // index 2 as its own "R" slot for BGR2GRAY, independent of what a
        // caller's channels actually mean) -- re-verified directly against
        // a live cv2.cvtColor(..., COLOR_BGR2GRAY) call on these exact
        // literal arrays during plan 15-02's real-corpus investigation.
        // The previous version of this test asserted 30/59/11 for these
        // same three inputs (R/B swapped relative to real cv2) -- that was
        // never actually checked against a live cv2 call with this literal
        // channel ordering; see bgr_to_gray_u8's own doc comment.
        assert_eq!(bgr_to_gray_u8(&[[100, 0, 0]]), vec![11u8], "position0=100-only -> 11");
        assert_eq!(bgr_to_gray_u8(&[[0, 100, 0]]), vec![59u8], "position1=100-only -> 59");
        assert_eq!(bgr_to_gray_u8(&[[0, 0, 100]]), vec![30u8], "position2=100-only -> 30");
    }

    #[test]
    fn group_u_percentile_axis_helpers_reduce_correct_dimension() {
        // 2x3 (height=2, width=3): rows [0,1,2] and [3,4,5].
        let values: Vec<u8> = vec![0, 1, 2, 3, 4, 5];
        let axis0 = percentile_axis0_u8(&values, 3, 2, 50.0); // length = width = 3
        assert_eq!(axis0.len(), 3);
        let axis1 = percentile_axis1_u8(&values, 3, 2, 50.0); // length = height = 2
        assert_eq!(axis1.len(), 2);
    }
}
