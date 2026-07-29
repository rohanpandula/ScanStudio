//! Candidate-generation glue for the color module (Phase 14, plan 14-02):
//! renders one corpus slot's raw RGB capture into a nikonlook color
//! candidate image via the pure-Rust `processing::nikonlook` port, and
//! guards against a `--candidate-dir` / `SCANSTUDIO_PARITY_CANDIDATES`
//! value that would write into the read-only corpus itself (T-14-03).
//!
//! Phase 15, plan 15-02 adds geometry candidate-generation glue (autocrop +
//! deskew) via the pure-Rust `processing::geometry` port -- see below.
//!
//! Phase 16, plan 16-03 adds ICE candidate-generation glue (Legacy/classical
//! defect repair) via the pure-Rust `processing::ice` port -- see below.

use std::path::Path;

use crate::parity::image_io::{self, Gray16Image, Rgb16Image};
use crate::parity::types::ParityError;
use crate::parity::CorpusSlot;
use crate::processing::geometry::{self, AutocropMode, GeometryImage, Roi};
use crate::processing::ice::{self, IceInputFrame, IceParameters};
use crate::processing::nikonlook::{self, Bundle};

/// True if `candidate_dir` IS the corpus root, or resolves to a path nested
/// inside it (archive-immutability guard, T-14-03). Algorithm: canonicalize
/// `corpus_root` (if that fails, return false — corpus::discover's own
/// error will surface separately). Try to canonicalize `candidate_dir`
/// directly; if it doesn't exist yet (the common case — it's usually
/// created fresh), canonicalize its PARENT instead and rejoin
/// candidate_dir's own file_name onto that — if even the parent doesn't
/// exist, return false (give up cleanly; a later create_dir_all/discovery
/// step will surface a clearer error). Compare the two canonical paths:
/// return true if equal, or if the candidate path starts_with the corpus
/// path.
pub fn candidate_dir_conflicts_with_corpus(corpus_root: &Path, candidate_dir: &Path) -> bool {
    let Ok(canonical_corpus) = corpus_root.canonicalize() else {
        return false;
    };

    let canonical_candidate = if let Ok(direct) = candidate_dir.canonicalize() {
        direct
    } else {
        let Some(parent) = candidate_dir.parent() else {
            return false;
        };
        let Ok(canonical_parent) = parent.canonicalize() else {
            return false;
        };
        let Some(file_name) = candidate_dir.file_name() else {
            return false;
        };
        canonical_parent.join(file_name)
    };

    canonical_candidate == canonical_corpus || canonical_candidate.starts_with(&canonical_corpus)
}

/// Renders one corpus slot's raw RGB capture into a nikonlook color
/// candidate: read-only load of slot.rgb_path, convert to scanner-linear
/// RGB (u16 / 65535.0), estimate_gains + apply, quantize back to u16.
/// Never writes any file — returns the image; the caller decides the path.
///
/// `bundle` is whatever the caller's `load_bundle()` returned — now
/// `nikonlook-v2` by default, so this candidate generation exercises v2's
/// blind fallback (`None` exposure metadata: no hardware-exposure telemetry
/// exists in a corpus slot).
pub fn render_color_candidate(
    slot: &CorpusSlot,
    bundle: &Bundle,
) -> Result<Rgb16Image, ParityError> {
    let raw_image = image_io::read_rgb16(&slot.rgb_path)?;

    // Scanner-linear RGB in [0, 1] — mirrors
    // scanstudio-bridge/tools/render_references.py's FULL_SCALE = 65535.0
    // convention exactly; do not use any other divisor.
    let raw_linear: Vec<[f64; 3]> = raw_image
        .pixels
        .iter()
        .map(|pixel| {
            [
                pixel[0] as f64 / 65535.0,
                pixel[1] as f64 / 65535.0,
                pixel[2] as f64 / 65535.0,
            ]
        })
        .collect();

    let k = nikonlook::estimate_gains(&raw_linear, raw_image.width as usize, None, bundle)
        .map_err(|err| ParityError::Decode(format!("nikonlook estimate_gains: {err}")))?;
    let applied = nikonlook::apply(&raw_linear, k, bundle);

    let pixels: Vec<[u16; 3]> = applied
        .iter()
        .map(|px| [quantize_u16(px[0]), quantize_u16(px[1]), quantize_u16(px[2])])
        .collect();

    Ok(Rgb16Image {
        width: raw_image.width,
        height: raw_image.height,
        pixels,
    })
}

/// Round-half-up quantization from a `[0.0, 1.0]`-normalized channel value
/// to a full-scale `u16` sample — the `+0.5` before clamping and truncating
/// cast matches `render_references.py`'s own
/// `np.clip(x * 65535 + 0.5, 0, 65535).astype(uint16)` step exactly, which
/// is what actually produced Phase 13's reference TIFFs.
fn quantize_u16(value: f64) -> u16 {
    (value * 65535.0 + 0.5).clamp(0.0, 65535.0) as u16
}

// ---------------------------------------------------------------------
// Geometry (Phase 15, plan 15-02)
// ---------------------------------------------------------------------

/// Fixed, documented fine-deskew test angle applied uniformly across the
/// whole corpus. NegPy has no automatic deskew-ANGLE detection anywhere in
/// its source (`apply_fine_rotation` only ever APPLIES a given angle, never
/// detects one) -- unlike color's `estimate_gains`, there is nothing for
/// either implementation to estimate from a real corpus frame's pixel
/// content, so this plan uses one fixed, documented angle applied
/// identically to both the Python reference and the Rust candidate on every
/// slot (mirroring Phase 14's `render_references.py`, which applied one
/// fixed `nikonlook-v1` bundle uniformly across all six slots). Matches
/// plan 15-01's own `<rotation_algorithm>` ground-truth angle. Keep this
/// literal in sync with `render_geometry_references.py`'s own copy (see
/// PARITY.md).
pub const GEOMETRY_TEST_ANGLE_DEGREES: f64 = 1.75;

/// Converts a decoded `Rgb16Image` (u16, TIFF-decoded) into a
/// `GeometryImage` ([0,1]-range f32) via `/65535.0` per channel — the same
/// conversion convention `render_color_candidate` already uses for
/// nikonlook, just producing geometry's own image type (f32, not a flat
/// `Vec<[f64; 3]>`).
fn to_geometry_image(raw: &Rgb16Image) -> GeometryImage {
    let pixels: Vec<[f32; 3]> = raw
        .pixels
        .iter()
        .map(|pixel| {
            [
                pixel[0] as f32 / 65535.0,
                pixel[1] as f32 / 65535.0,
                pixel[2] as f32 / 65535.0,
            ]
        })
        .collect();

    GeometryImage {
        width: raw.width,
        height: raw.height,
        pixels,
    }
}

/// Renders one corpus slot's raw RGB capture into both autocrop ROIs (Film
/// mode, Image mode) via `processing::geometry::autocrop_roi`, target ratio
/// "3:2" (NegPy's own default), `offset_px=0`, `scale_factor=1.0`,
/// `detect_res=geometry::AUTOCROP_DETECT_RES`, `assist_luma=None`. Returns
/// `(film_roi, image_roi)`. Never writes any file — the caller decides the
/// path.
pub fn render_autocrop_candidate(slot: &CorpusSlot) -> Result<(Roi, Roi), ParityError> {
    let raw_image = image_io::read_rgb16(&slot.rgb_path)?;
    let geo_image = to_geometry_image(&raw_image);

    let film_roi = geometry::autocrop_roi(
        &geo_image,
        AutocropMode::Film,
        0,
        1.0,
        "3:2",
        geometry::AUTOCROP_DETECT_RES,
        None,
    );
    let image_roi = geometry::autocrop_roi(
        &geo_image,
        AutocropMode::Image,
        0,
        1.0,
        "3:2",
        geometry::AUTOCROP_DETECT_RES,
        None,
    );

    Ok((film_roi, image_roi))
}

/// Renders one corpus slot's raw RGB capture rotated by
/// `GEOMETRY_TEST_ANGLE_DEGREES` via
/// `processing::geometry::apply_fine_rotation`, quantized back to u16 with
/// the same round-half-up formula `render_color_candidate` uses (reuses
/// `quantize_u16` directly rather than duplicating it). Never writes any
/// file — the caller decides the path.
pub fn render_deskew_candidate(slot: &CorpusSlot) -> Result<Rgb16Image, ParityError> {
    let raw_image = image_io::read_rgb16(&slot.rgb_path)?;
    let geo_image = to_geometry_image(&raw_image);

    let rotated = geometry::apply_fine_rotation(&geo_image, GEOMETRY_TEST_ANGLE_DEGREES);

    let pixels: Vec<[u16; 3]> = rotated
        .pixels
        .iter()
        .map(|px| {
            [
                quantize_u16(px[0] as f64),
                quantize_u16(px[1] as f64),
                quantize_u16(px[2] as f64),
            ]
        })
        .collect();

    Ok(Rgb16Image {
        width: rotated.width,
        height: rotated.height,
        pixels,
    })
}

// ---------------------------------------------------------------------
// ICE (Phase 16, plan 16-03)
// ---------------------------------------------------------------------

/// Renders one corpus slot's raw RGB+IR capture into a Legacy (classical)
/// ICE repair candidate: reads `slot.rgb_path`/`slot.ir_path`, builds an
/// `IceInputFrame` directly from the decoded raw u16 counts -- no
/// `/65535.0` normalization, unlike `render_color_candidate`/
/// `to_geometry_image`'s `[0,1]`-normalized conventions, because
/// `processing::ice`'s response-LUT conversion operates on raw u16 scanner
/// counts directly (see plan 16-01's `IceInputFrame` doc comment) --
/// derives `IceParameters::for_main_scan` from that same frame (the
/// single-acquisition substitute; see plan 16-01's
/// `<single_acquisition_adaptation>`), and calls `ice::repair_frame`.
/// Returns `(repaired Rgb16Image, defect mask as a Gray16Image)`: the
/// mask is `DefectMap.score` (already `[0,1]`-normalized, `0.0`=clean)
/// scaled to a full-scale `u16` via the same round-half-up `quantize_u16`
/// helper `render_color_candidate` already uses (reused directly, not
/// duplicated) -- this reuses the existing `image_io::write_gray16` path
/// rather than adding a new `write_mask_normalized` function, since the
/// conversion is identical in shape to quantizing a `[0,1]` color channel.
/// Never writes any file -- the caller decides the path.
pub fn render_ice_candidate(slot: &CorpusSlot) -> Result<(Rgb16Image, Gray16Image), ParityError> {
    let rgb_image = image_io::read_rgb16(&slot.rgb_path)?;
    let ir_image = image_io::read_gray16(&slot.ir_path)?;

    if rgb_image.width != ir_image.width || rgb_image.height != ir_image.height {
        return Err(ParityError::Decode(format!(
            "render_ice_candidate: RGB/IR dimension mismatch — rgb {}x{}, ir {}x{}",
            rgb_image.width, rgb_image.height, ir_image.width, ir_image.height
        )));
    }

    let frame = IceInputFrame {
        width: rgb_image.width,
        height: rgb_image.height,
        rgb: rgb_image.pixels,
        ir: ir_image.pixels,
    };

    let params = IceParameters::for_main_scan(&frame);
    let result = ice::repair_frame(&frame, &params);

    let repaired = Rgb16Image {
        width: frame.width,
        height: frame.height,
        pixels: result.repaired_rgb,
    };

    let mask_pixels: Vec<u16> = result
        .defect_map
        .score
        .iter()
        .map(|&score| quantize_u16(score as f64))
        .collect();
    let mask = Gray16Image {
        width: result.defect_map.width,
        height: result.defect_map.height,
        pixels: mask_pixels,
    };

    Ok((repaired, mask))
}
