//! Renders deterministic simulated frame data to real files per an
//! `OutputRecipe` (REC-01/REC-02/REC-03). When retained, archive writes are
//! strict create-only: the archive is PROJECT.md's "regenerable derivatives"
//! boundary — the capture master, never touched again once written.
//! Positive/preview writes may overwrite an existing file; they are the
//! regenerable derivatives, by design.

use std::io::Write as _;

use crate::domain;
use crate::parity::image_io;
use crate::processing::ice;
use crate::protocol;

// ---------------------------------------------------------------------
// Frame geometry
// ---------------------------------------------------------------------

/// Mirrors the Swift `ScanSizeEstimator.uncompressedBytes` dimension math
/// exactly (native 3946x5782 for Mounted, 3946x5959 otherwise, scaled by
/// `resolutionDpi / 4000`) -- do not invent different numbers.
pub fn frame_dimensions(carrier: domain::MediaCarrier, resolution_dpi: u32) -> (u32, u32) {
    let native_width = 3946.0_f64;
    let native_height = if carrier == domain::MediaCarrier::Mounted {
        5782.0_f64
    } else {
        5959.0_f64
    };
    let scale = resolution_dpi as f64 / 4000.0;
    let width = (native_width * scale).round().max(1.0) as u32;
    let height = (native_height * scale).round().max(1.0) as u32;
    (width, height)
}

/// Resolves an absolute vertical crop region from a detected frame boundary
/// and a user-approved relative offset. A retained archive master is never
/// cropped; this region is applied only when producing derived output. Width is
/// always unchanged; only top/bottom rows are shifted by the relative intent
/// and clamped to the image bounds.
///
/// Returns `(top, bottom_inclusive, new_height)`. `bottom_inclusive` is the
/// last row included in the crop (i.e., the range is `[top, bottom_inclusive]`
/// inclusive), so callers can compute `new_height` as
/// `bottom_inclusive - top + 1`.
pub fn resolve_aligned_crop(
    boundary_top: u32,
    boundary_bottom: u32,
    offset_rows: i64,
    image_height: u32,
) -> (u32, u32, u32) {
    let shifted_top = (boundary_top as i64 + offset_rows).clamp(0, image_height as i64 - 1) as u32;
    let shifted_bottom = (boundary_bottom as i64 + offset_rows)
        .clamp(shifted_top as i64, image_height as i64 - 1) as u32;
    let new_height = shifted_bottom - shifted_top + 1;
    (shifted_top, shifted_bottom, new_height)
}

/// Detects one frame's film ROI on its raw archive raster (stored
/// orientation) using the parity-proven NegPy AUTO_FRAME_EDGE port and the
/// exact parameters validated by the parity harness. Detection only reads
/// the buffer; a degenerate or out-of-bounds result fails open to the full
/// derivative and is recorded in the receipt.
fn detect_auto_crop(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
) -> domain::AutoCropOutcome {
    let pixels: Vec<[f32; 3]> = raw
        .iter()
        .map(|pixel| [pixel[0] as f32, pixel[1] as f32, pixel[2] as f32])
        .collect();
    let image = crate::processing::geometry::GeometryImage { width, height, pixels };
    let roi = crate::processing::geometry::autocrop_roi(
        &image,
        crate::processing::geometry::AutocropMode::Image,
        0,
        1.0,
        "3:2",
        crate::processing::geometry::AUTOCROP_DETECT_RES,
        None,
    );
    let usable = roi.y1 < roi.y2 && roi.x1 < roi.x2 && roi.y2 <= height && roi.x2 <= width;
    if usable {
        domain::AutoCropOutcome {
            mode: "image".to_string(),
            applied: true,
            roi: Some(domain::AutoCropRoi { y1: roi.y1, y2: roi.y2, x1: roi.x1, x2: roi.x2 }),
            source_width: width,
            source_height: height,
            reason: None,
        }
    } else {
        domain::AutoCropOutcome {
            mode: "image".to_string(),
            applied: false,
            roi: None,
            source_width: width,
            source_height: height,
            reason: Some(format!(
                "detected ROI y{}..{} x{}..{} is not a usable region of the {}x{} raster; derivatives left uncropped",
                roi.y1, roi.y2, roi.x1, roi.x2, width, height
            )),
        }
    }
}

fn auto_crop_deferred_to_alignment(width: u32, height: u32) -> domain::AutoCropOutcome {
    domain::AutoCropOutcome {
        mode: "image".to_string(),
        applied: false,
        roi: None,
        source_width: width,
        source_height: height,
        reason: Some(
            "approved manual frame alignment supersedes auto-crop for this frame".to_string(),
        ),
    }
}

/// Extracts a half-open ROI from a row-major `[0,1]` float buffer.
fn crop_to_roi(
    buffer: &[[f64; 3]],
    width: u32,
    roi: &domain::AutoCropRoi,
) -> (Vec<[f64; 3]>, u32, u32) {
    let new_width = roi.x2 - roi.x1;
    let new_height = roi.y2 - roi.y1;
    let mut cropped = Vec::with_capacity((new_width as usize) * (new_height as usize));
    for row in roi.y1..roi.y2 {
        let start = (row * width + roi.x1) as usize;
        cropped.extend_from_slice(&buffer[start..start + new_width as usize]);
    }
    (cropped, new_width, new_height)
}

/// Applies an approved vertical crop to a row-major `[0,1]` float buffer.
/// Unapproved alignments and missing boundaries are treated as no-ops:
/// the full buffer is returned unchanged. This is the render-side half of
/// the archive-immutability guarantee.
pub fn apply_alignment_crop(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
) -> (Vec<[f64; 3]>, u32, u32) {
    let Some(alignment) = alignment else {
        return (raw.to_vec(), width, height);
    };
    if !alignment.approved {
        return (raw.to_vec(), width, height);
    }
    let Some((boundary_top, boundary_bottom)) = detected_boundary else {
        return (raw.to_vec(), width, height);
    };
    let (top, _bottom, new_height) =
        resolve_aligned_crop(boundary_top, boundary_bottom, alignment.offset_rows, height);
    let start = (top * width) as usize;
    let end = start + (new_height * width) as usize;
    let cropped = raw[start..end].to_vec();
    (cropped, width, new_height)
}

// ---------------------------------------------------------------------
// Synthetic defect generation (DEF-02)
// ---------------------------------------------------------------------

/// Lower bound for a generated `DefectInstance.severity` draw. Mirrors
/// `processing::ice::DefectMap.score`'s own `[0.0,1.0]` convention (see
/// `domain::DefectInstance`'s doc comment) without calling into that frozen
/// module.
pub const DEFECT_SEVERITY_FLOOR: f32 = 0.15;
/// `severity >= this` classifies `Uncertain` (amber, least-certain); below
/// it, `WillCorrect` (red, confident) -- mirrors the mid-range-vs-near-1.0
/// band shape `processing::ice::DefectMap`'s own doc comment documents for
/// Phase 17.
pub const DEFECT_CLASSIFICATION_THRESHOLD: f32 = 0.78;
pub const MIN_DEFECT_COUNT: u32 = 3;
pub const MAX_DEFECT_COUNT: u32 = 40;

/// Resolves a raw `[0.0,1.0]` severity into DEF-02's red("will correct")/
/// amber("uncertain") classification band. See `DEFECT_CLASSIFICATION_THRESHOLD`.
pub fn classify_defect_severity(severity: f32) -> domain::DefectClassification {
    if severity >= DEFECT_CLASSIFICATION_THRESHOLD {
        domain::DefectClassification::Uncertain
    } else {
        domain::DefectClassification::WillCorrect
    }
}

/// Deterministic `[0.0,1.0)` value stream seeded from `seed`: each value
/// re-hashes the previous `u64` state (formatted as lowercase hex) through
/// `fnv1a64` again, then takes the top 32 bits of the new state over
/// `2^32` for a half-open unit-interval value. A private, reusable helper so
/// every field draw in `generate_synthetic_defects` pulls its own next value
/// off one single stream instead of reimplementing this ad hoc per call site.
fn defect_seed_stream(seed: u64) -> impl Iterator<Item = f64> {
    let mut state = seed;
    std::iter::from_fn(move || {
        state = crate::sim::fnv1a64(&format!("{state:x}"));
        Some((state >> 32) as f64 / 4294967296.0)
    })
}

/// Deterministic, seeded synthetic dust/scratch defect generator for DEF-02.
/// A pure function of its three arguments (SIM-03): identical arguments
/// always return a byte-identical `Vec`; a different `frame_index` (all else
/// equal) varies the result. Returns an empty `Vec` whenever
/// `processing.digital_ice_enabled` is `false` -- real dust/scratch
/// detection fundamentally requires the infrared channel, so an "off"
/// result is never fabricated (see 05-01-PLAN.md's scope_decision notes).
pub fn generate_synthetic_defects(
    frame_index: u32,
    capture: &domain::CaptureRecipe,
    processing: &domain::ProcessingRecipe,
) -> Vec<domain::DefectInstance> {
    if !processing.digital_ice_enabled {
        return Vec::new();
    }

    let seed_string = format!(
        "defects:{frame_index}:{}:{:?}:{:?}",
        capture.resolution_dpi, processing.film_process, processing.digital_ice_mode
    );
    let seed = crate::sim::fnv1a64(&seed_string);
    let mut stream = defect_seed_stream(seed);
    let mut draw = || stream.next().expect("defect_seed_stream never terminates");

    let total = MIN_DEFECT_COUNT + (draw() * (MAX_DEFECT_COUNT - MIN_DEFECT_COUNT) as f64) as u32;

    let mut instances = Vec::with_capacity(total as usize);
    for id in 0..total {
        // ~85% Dust, ~15% Scratch.
        let is_scratch = draw() >= 0.85;
        let center_x = (0.04 + draw() * (0.96 - 0.04)) as f32;
        let center_y = (0.04 + draw() * (0.96 - 0.04)) as f32;
        let severity =
            (DEFECT_SEVERITY_FLOOR as f64 + draw() * (1.0 - DEFECT_SEVERITY_FLOOR as f64)) as f32;
        let classification = classify_defect_severity(severity);

        let (kind, radius, end_x, end_y) = if is_scratch {
            let half_width = (0.002 + draw() * (0.005 - 0.002)) as f32;
            let angle = draw() * std::f64::consts::TAU;
            let length = 0.05 + draw() * (0.22 - 0.05);
            let end_x = (center_x as f64 + length * angle.cos()).clamp(0.0, 1.0) as f32;
            let end_y = (center_y as f64 + length * angle.sin()).clamp(0.0, 1.0) as f32;
            (
                domain::DefectKind::Scratch,
                half_width,
                Some(end_x),
                Some(end_y),
            )
        } else {
            let radius = (0.006 + draw() * (0.018 - 0.006)) as f32;
            (domain::DefectKind::Dust, radius, None, None)
        };

        instances.push(domain::DefectInstance {
            id,
            kind,
            severity,
            classification,
            center_x,
            center_y,
            radius,
            end_x,
            end_y,
        });
    }

    instances
}

// ---------------------------------------------------------------------
// Real (IR-derived) defect clustering (PROC-02)
// ---------------------------------------------------------------------

/// Threshold for classifying a connected component as a scratch rather than
/// dust: a component whose bounding-box long edge is at least this many
/// times its short edge is treated as an elongated defect trace.
const SCRATCH_ASPECT_RATIO_THRESHOLD: f32 = 3.0;
/// Minimum long-edge pixel length for the scratch classification above to
/// apply. A tiny blob with a coincidentally high aspect ratio still reads as
/// dust.
const SCRATCH_MIN_LENGTH_PX: u32 = 6;
/// Normalized-radius sanity floor. Prevents a degenerate single-pixel
/// component from reporting a zero radius.
const DEFECT_INSTANCE_RADIUS_MIN: f32 = 0.001;
/// Normalized-radius sanity ceiling. Prevents an edge-spanning component
/// from reporting an absurd radius.
const DEFECT_INSTANCE_RADIUS_MAX: f32 = 0.25;

/// Clusters a real `processing::ice::DefectMap` (frozen — called not
/// modified) into the same `Vec<domain::DefectInstance>` shape that
/// `generate_synthetic_defects` produces. This is the real-data counterpart
/// to the synthetic generator above: identical wire shape, but the pixels
/// come from actual IR-derived defect scoring rather than seeded synthesis.
///
/// The function is pure and deterministic: any `score > 0.0` pixel is
/// treated as a confirmed defect pixel (the frozen `ice::detect_defects`
/// already applied its own neighborhood confirmation before writing a
/// nonzero score), and components are discovered in raster order.
pub fn cluster_defect_map(map: &ice::DefectMap) -> Vec<domain::DefectInstance> {
    let components = find_defect_components(map);
    components
        .into_iter()
        .enumerate()
        .map(|(id, pixels)| defect_instance_from_component(id as u32, &pixels, map))
        .collect()
}

fn find_defect_components(map: &ice::DefectMap) -> Vec<Vec<(u32, u32)>> {
    if map.width == 0 || map.height == 0 {
        return Vec::new();
    }

    let width = map.width as usize;
    let height = map.height as usize;
    let mut visited = vec![false; width * height];
    let mut components = Vec::new();

    for y in 0..height {
        for x in 0..width {
            let idx = y * width + x;
            if visited[idx] || map.score[idx] <= 0.0 {
                continue;
            }

            let mut pixels = Vec::new();
            let mut queue = std::collections::VecDeque::new();
            queue.push_back((x, y));
            visited[idx] = true;

            while let Some((cx, cy)) = queue.pop_front() {
                pixels.push((cx as u32, cy as u32));
                for dy in -1..=1 {
                    for dx in -1..=1 {
                        if dy == 0 && dx == 0 {
                            continue;
                        }
                        let nx = cx as i64 + dx;
                        let ny = cy as i64 + dy;
                        if nx < 0 || nx >= width as i64 || ny < 0 || ny >= height as i64 {
                            continue;
                        }
                        let nidx = ny as usize * width + nx as usize;
                        if !visited[nidx] && map.score[nidx] > 0.0 {
                            visited[nidx] = true;
                            queue.push_back((nx as usize, ny as usize));
                        }
                    }
                }
            }

            components.push(pixels);
        }
    }

    components
}

fn defect_instance_from_component(
    id: u32,
    pixels: &[(u32, u32)],
    map: &ice::DefectMap,
) -> domain::DefectInstance {
    debug_assert!(
        !pixels.is_empty(),
        "component must contain at least one pixel"
    );

    let width = map.width;
    let height = map.height;

    let mut severity = 0.0_f32;
    let mut min_x = u32::MAX;
    let mut max_x = u32::MIN;
    let mut min_y = u32::MAX;
    let mut max_y = u32::MIN;
    let mut sum_x = 0.0_f64;
    let mut sum_y = 0.0_f64;

    for &(x, y) in pixels {
        let idx = y as usize * width as usize + x as usize;
        let score = map.score[idx];
        if score > severity {
            severity = score;
        }
        if x < min_x {
            min_x = x;
        }
        if x > max_x {
            max_x = x;
        }
        if y < min_y {
            min_y = y;
        }
        if y > max_y {
            max_y = y;
        }
        sum_x += x as f64;
        sum_y += y as f64;
    }

    let classification = classify_defect_severity(severity);
    let mean_x = sum_x / pixels.len() as f64;
    let mean_y = sum_y / pixels.len() as f64;

    let bbox_w = max_x - min_x + 1;
    let bbox_h = max_y - min_y + 1;
    let long_extent = bbox_w.max(bbox_h);
    let short_extent = bbox_w.min(bbox_h).max(1);
    let is_scratch = (long_extent as f32 / short_extent as f32) >= SCRATCH_ASPECT_RATIO_THRESHOLD
        && long_extent >= SCRATCH_MIN_LENGTH_PX;

    let normalize_x = |value: f64| (value / width as f64).clamp(0.0, 1.0) as f32;
    let normalize_y = |value: f64| (value / height as f64).clamp(0.0, 1.0) as f32;
    let clamp_radius =
        |value: f32| value.clamp(DEFECT_INSTANCE_RADIUS_MIN, DEFECT_INSTANCE_RADIUS_MAX);

    if !is_scratch {
        let center_x = normalize_x(mean_x);
        let center_y = normalize_y(mean_y);
        let pixel_radius = (pixels.len() as f32 / std::f32::consts::PI).sqrt();
        let radius = clamp_radius(pixel_radius / width as f32);

        return domain::DefectInstance {
            id,
            kind: domain::DefectKind::Dust,
            severity,
            classification,
            center_x,
            center_y,
            radius,
            end_x: None,
            end_y: None,
        };
    }

    // Scratch: principal-axis end points.
    let mut cov_xx = 0.0_f64;
    let mut cov_yy = 0.0_f64;
    let mut cov_xy = 0.0_f64;
    for &(x, y) in pixels {
        let dx = x as f64 - mean_x;
        let dy = y as f64 - mean_y;
        cov_xx += dx * dx;
        cov_yy += dy * dy;
        cov_xy += dx * dy;
    }
    let n = pixels.len() as f64;
    cov_xx /= n;
    cov_yy /= n;
    cov_xy /= n;

    let theta = 0.5 * (2.0 * cov_xy).atan2(cov_xx - cov_yy);
    let dir = (theta.cos(), theta.sin());

    let mut min_proj = f64::INFINITY;
    let mut max_proj = f64::NEG_INFINITY;
    let mut endpoint_a = pixels[0];
    let mut endpoint_b = pixels[0];
    for &(x, y) in pixels {
        let proj = (x as f64 - mean_x) * dir.0 + (y as f64 - mean_y) * dir.1;
        if proj < min_proj {
            min_proj = proj;
            endpoint_a = (x, y);
        }
        if proj > max_proj {
            max_proj = proj;
            endpoint_b = (x, y);
        }
    }

    let center_x = normalize_x(endpoint_a.0 as f64);
    let center_y = normalize_y(endpoint_a.1 as f64);
    let end_x = Some(normalize_x(endpoint_b.0 as f64));
    let end_y = Some(normalize_y(endpoint_b.1 as f64));

    let length_px = ((endpoint_b.0 as f64 - endpoint_a.0 as f64).powi(2)
        + (endpoint_b.1 as f64 - endpoint_a.1 as f64).powi(2))
    .sqrt()
    .max(1.0);
    let radius = clamp_radius((pixels.len() as f32 / (2.0 * length_px as f32)) / width as f32);

    domain::DefectInstance {
        id,
        kind: domain::DefectKind::Scratch,
        severity,
        classification,
        center_x,
        center_y,
        radius,
        end_x,
        end_y,
    }
}

/// Loads a real archive RGB+IR capture pair from disk, runs the frozen
/// `ice::detect_defects` algorithm on it, and clusters the resulting defect
/// map into `domain::DefectInstance`s. Mirrors
/// `generate_synthetic_defects`'s ICE-off contract: when
/// `processing.digital_ice_enabled` is false, no filesystem I/O is performed
/// and an empty `Vec` is returned immediately.
pub fn real_frame_defects(
    rgb_path: &std::path::Path,
    ir_path: &std::path::Path,
    processing: &domain::ProcessingRecipe,
) -> Result<Vec<domain::DefectInstance>, domain::EngineError> {
    if !processing.digital_ice_enabled {
        return Ok(Vec::new());
    }

    let rgb_image = image_io::read_rgb16(rgb_path).map_err(|err| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to read RGB archive at {}: {err}",
                rgb_path.display()
            ),
        )
    })?;
    let ir_image = image_io::read_gray16(ir_path).map_err(|err| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("failed to read IR archive at {}: {err}", ir_path.display()),
        )
    })?;

    if rgb_image.width != ir_image.width || rgb_image.height != ir_image.height {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "RGB/IR dimension mismatch — rgb {}x{}, ir {}x{}",
                rgb_image.width, rgb_image.height, ir_image.width, ir_image.height
            ),
        ));
    }

    let frame = ice::IceInputFrame {
        width: rgb_image.width,
        height: rgb_image.height,
        rgb: rgb_image.pixels,
        ir: ir_image.pixels,
    };
    let params = ice::IceParameters::for_main_scan(&frame);
    let map = ice::detect_defects(&frame, &params);
    Ok(cluster_defect_map(&map))
}

/// Honestly-synthetic deterministic frame data: a cheap wave field, not a
/// photographic simulation, sized to whatever `width`/`height` the caller
/// passes. Reuses `sim::fnv1a64`/`sim::thumbnail_for` so the same
/// device/frame always reproduces byte-identical pixels.
pub fn generate_sim_frame(
    device_id: &str,
    frame_index: u32,
    width: u32,
    height: u32,
) -> Vec<[f64; 3]> {
    let base = crate::sim::thumbnail_for(device_id, frame_index);
    let base_brightness = base
        .brightness
        .expect("sim::thumbnail_for always sets brightness");
    let base_tint = base.tint.expect("sim::thumbnail_for always sets tint");
    let seed = crate::sim::fnv1a64(&format!("{device_id}:{frame_index}"));

    let mut pixels = Vec::with_capacity(width as usize * height as usize);
    for y in 0..height {
        let fy = y as f64 / height.max(1) as f64;
        for x in 0..width {
            let fx = x as f64 / width.max(1) as f64;
            let mut pixel = [0.0_f64; 3];
            for (c, sample) in pixel.iter_mut().enumerate() {
                let phase = ((seed >> (c * 8)) & 0xFF) as f64 / 255.0;
                let wave =
                    ((fx * 6.0 + fy * 4.0 + phase * std::f64::consts::TAU).sin() + 1.0) / 2.0;
                *sample = (base_brightness + base_tint * (c as f64 - 1.0) * 0.3 + wave * 0.15)
                    .clamp(0.0, 1.0);
            }
            pixels.push(pixel);
        }
    }
    pixels
}

// ---------------------------------------------------------------------
// Filename/path resolution
// ---------------------------------------------------------------------

/// A job-local marker produced only when the default single-`#` template is
/// reserved for a concrete output number. It never reaches a project
/// manifest: the editable recipe remains `ScanStudio#`, while every backend
/// receives an exact per-frame filename for this one job.
const RESERVED_SEQUENCE_PREFIX: &str = domain::OutputRecipe::RESERVED_FILENAME_MARKER_PREFIX;
const RESERVED_SEQUENCE_SUFFIX: &str = ")";

/// A single hash is the new auto-number token. Multi-hash runs remain the
/// established frame-number convention (`####` -> the scanner slot), so
/// existing custom templates keep their exact behavior.
fn is_auto_sequence_template(template: &str) -> bool {
    template.chars().filter(|character| *character == '#').count() == 1
}

pub(crate) fn is_reserved_sequence_template(template: &str) -> bool {
    template.contains(RESERVED_SEQUENCE_PREFIX)
}

/// Returns the user-facing recipe suitable for durable receipts. Sequence
/// reservation is an engine-only dispatch detail: exact bridge names use the
/// private marker, while manifests and receipts retain the editable `#` token.
pub(crate) fn receipt_output_recipe(output: &domain::OutputRecipe) -> domain::OutputRecipe {
    let mut receipt_output = output.clone();
    for template in [
        &mut receipt_output.archive.filename_template,
        &mut receipt_output.positive.filename_template,
        &mut receipt_output.preview.filename_template,
        &mut receipt_output.raw_export.filename_template,
    ] {
        *template = restore_reserved_sequence_template(template);
    }
    receipt_output
}

fn restore_reserved_sequence_template(template: &str) -> String {
    let Some(start) = template.find(RESERVED_SEQUENCE_PREFIX) else {
        return template.to_string();
    };
    let number_start = start + RESERVED_SEQUENCE_PREFIX.len();
    let Some(number_end_offset) = template[number_start..].find(RESERVED_SEQUENCE_SUFFIX) else {
        return template.to_string();
    };
    let number_end = number_start + number_end_offset;
    if template[number_start..number_end]
        .parse::<u32>()
        .ok()
        .filter(|number| *number > 0)
        .is_none()
        || template[number_end + RESERVED_SEQUENCE_SUFFIX.len()..]
            .contains(RESERVED_SEQUENCE_PREFIX)
    {
        return template.to_string();
    }
    format!(
        "{}#{}",
        &template[..start],
        &template[number_end + RESERVED_SEQUENCE_SUFFIX.len()..]
    )
}

fn reserve_sequence_template(template: &str, number: u32) -> String {
    debug_assert!(is_auto_sequence_template(template));
    template.replacen(
        '#',
        &format!("{RESERVED_SEQUENCE_PREFIX}{number}{RESERVED_SEQUENCE_SUFFIX}"),
        1,
    )
}

fn resolve_reserved_sequence_template(template: &str) -> Option<String> {
    let start = template.find(RESERVED_SEQUENCE_PREFIX)?;
    let number_start = start + RESERVED_SEQUENCE_PREFIX.len();
    let number_end = template[number_start..].find(RESERVED_SEQUENCE_SUFFIX)? + number_start;
    let number = template[number_start..number_end]
        .parse::<u32>()
        .ok()
        .filter(|number| *number > 0)?;
    let marker_end = number_end + RESERVED_SEQUENCE_SUFFIX.len();
    if template[marker_end..].contains(RESERVED_SEQUENCE_PREFIX) {
        return None;
    }
    Some(format!(
        "{}{}{}",
        &template[..start],
        number,
        &template[marker_end..]
    ))
}

/// Splices `frame_index`, zero-padded to the run length of the first `#`
/// run in `template`, in place of that run. A template with no marker gets
/// the same stable four-digit suffix as an implicit `"_####"` marker.
pub fn resolve_filename(template: &str, frame_index: u32) -> String {
    if let Some(filename) = resolve_reserved_sequence_template(template) {
        return filename;
    }
    match template.find('#') {
        Some(start) => {
            let run_len = template[start..].chars().take_while(|&c| c == '#').count();
            let end = start + run_len;
            let replacement = format!("{:0width$}", frame_index, width = run_len);
            format!("{}{}{}", &template[..start], replacement, &template[end..])
        }
        None => {
            let path = std::path::Path::new(template);
            let recognized_output_extension = path
                .extension()
                .and_then(|value| value.to_str())
                .is_some_and(|value| {
                    OutputNameKind::Tiff.recognizes_extension(value)
                        || OutputNameKind::Jpeg.recognizes_extension(value)
                        || OutputNameKind::Dng.recognizes_extension(value)
                });
            if recognized_output_extension {
                let stem = path
                    .file_stem()
                    .and_then(|value| value.to_str())
                    .unwrap_or(template);
                format!(
                    "{stem}_{frame_index:04}.{}",
                    path.extension()
                        .and_then(|value| value.to_str())
                        .expect("recognized extension is UTF-8")
                )
            } else {
                format!("{template}_{frame_index:04}")
            }
        }
    }
}

fn reserve_auto_sequence_templates(recipes: &mut domain::OutputRecipe, number: u32) {
    let mut templates = Vec::new();
    if recipes.archive.enabled {
        templates.push(&mut recipes.archive.filename_template);
    }
    if recipes.positive.enabled {
        templates.push(&mut recipes.positive.filename_template);
    }
    if recipes.preview.enabled {
        templates.push(&mut recipes.preview.filename_template);
    }
    if recipes.raw_export.enabled {
        templates.push(&mut recipes.raw_export.filename_template);
    }
    for template in templates {
        if is_auto_sequence_template(template) {
            *template = reserve_sequence_template(template, number);
        }
    }
}

fn has_auto_sequence_template(recipes: &domain::OutputRecipe) -> bool {
    (recipes.archive.enabled && is_auto_sequence_template(&recipes.archive.filename_template))
        || (recipes.positive.enabled && is_auto_sequence_template(&recipes.positive.filename_template))
        || (recipes.preview.enabled && is_auto_sequence_template(&recipes.preview.filename_template))
        || (recipes.raw_export.enabled
            && is_auto_sequence_template(&recipes.raw_export.filename_template))
}

/// Returns the planned auto-numbered names, including archive sidecars. The
/// caller passes a recipe where its single-`#` tokens have already been
/// replaced with a job-local reserved-number marker.
fn reserved_sequence_paths(
    recipes: &domain::OutputRecipe,
    include_ir_sidecar: bool,
    include_meter_sidecar: bool,
) -> Result<Vec<std::path::PathBuf>, domain::EngineError> {
    let mut paths = Vec::new();
    if recipes.archive.enabled && is_reserved_sequence_template(&recipes.archive.filename_template) {
        let archive = resolve_archive_output_path(recipes, 0);
        paths.push(archive.clone());
        if include_ir_sidecar {
            paths.push(archive_sidecar_path(&archive, "IR")?);
        }
        if include_meter_sidecar {
            paths.push(archive_sidecar_path(&archive, "METER")?);
        }
    }
    if recipes.positive.enabled && is_reserved_sequence_template(&recipes.positive.filename_template) {
        paths.push(resolve_output_path(
            &recipes.positive.destination,
            &recipes.positive.filename_template,
            0,
            recipes.positive.file_format,
        ));
    }
    if recipes.preview.enabled && is_reserved_sequence_template(&recipes.preview.filename_template) {
        paths.push(resolve_output_path(
            &recipes.preview.destination,
            &recipes.preview.filename_template,
            0,
            recipes.preview.file_format,
        ));
    }
    if recipes.raw_export.enabled
        && is_reserved_sequence_template(&recipes.raw_export.filename_template)
    {
        let raw = resolve_raw_export_output_path(recipes, 0);
        paths.push(raw.clone());
        if include_ir_sidecar
            && recipes.raw_export.tiff_infrared == domain::RawTiffInfrared::Sidecar
        {
            paths.push(raw_export_ir_sidecar_path(&raw));
        }
    }
    Ok(paths)
}

/// Treat an existing `Stem.*` in the selected destination as a consumed
/// sequence number, even if its extension differs from the output currently
/// being made. That keeps TIFF/JPEG/sidecar exports from reusing a visible
/// ScanStudio number after settings change.
fn sequence_stem_exists(path: &std::path::Path) -> Result<bool, domain::EngineError> {
    let parent = path.parent().ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("sequence output has no destination folder: {}", path.display()),
        )
    })?;
    let expected_stem = path.file_stem().and_then(|value| value.to_str()).ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("sequence output has no usable file name: {}", path.display()),
        )
    })?;

    match std::fs::read_dir(parent) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry.map_err(|error| {
                    domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        format!("read output destination {}: {error}", parent.display()),
                    )
                })?;
                let name = entry.file_name();
                let stem = std::path::Path::new(&name)
                    .file_stem()
                    .and_then(|value| value.to_str());
                if stem.is_some_and(|value| value.eq_ignore_ascii_case(expected_stem)) {
                    return Ok(true);
                }
            }
            Ok(false)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("read output destination {}: {error}", parent.display()),
        )),
    }
}

/// Returns the largest positive number already used by this one single-`#`
/// template in its selected destination. The comparison is intentionally by
/// file stem, so `ScanStudio12.tif` and `ScanStudio12.jpg` are one consumed
/// visible sequence number while `ScanStudio12_IR.tif` is not mistaken for
/// the user-facing `ScanStudio12` output.
fn highest_existing_sequence_number(
    destination: &str,
    template: &str,
    format: domain::OutputFileFormat,
) -> Result<u32, domain::EngineError> {
    if !is_auto_sequence_template(template) {
        return Ok(0);
    }
    let normalized = normalize_output_filename_template(template, format);
    let stem_template = std::path::Path::new(&normalized)
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("sequence template has no usable file name: {template}"),
        ))?;
    let marker = stem_template.find('#').expect("single-hash template has marker");
    let prefix = stem_template[..marker].to_ascii_lowercase();
    let suffix = stem_template[marker + 1..].to_ascii_lowercase();
    let parent = std::path::Path::new(destination);
    match std::fs::read_dir(parent) {
        Ok(mut entries) => entries.try_fold(0_u32, |highest, entry| {
            let entry = entry.map_err(|error| domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("read output destination {}: {error}", parent.display()),
            ))?;
            let entry_path = entry.path();
            let stem = entry_path
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            let Some(number) = stem
                .strip_prefix(&prefix)
                .and_then(|remaining| remaining.strip_suffix(&suffix))
                .and_then(|digits| digits.parse::<u32>().ok())
                .filter(|number| *number > 0)
            else { return Ok(highest) };
            Ok(highest.max(number))
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("read output destination {}: {error}", parent.display()),
        )),
    }
}

fn highest_existing_raw_sequence_number(
    destination: &str,
    template: &str,
    format: domain::RawExportFormat,
) -> Result<u32, domain::EngineError> {
    if !is_auto_sequence_template(template) {
        return Ok(0);
    }
    let normalized = normalize_raw_export_filename_template(template, format);
    let stem_template = std::path::Path::new(&normalized)
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("sequence template has no usable file name: {template}"),
            )
        })?;
    let marker = stem_template.find('#').expect("single-hash template has marker");
    let prefix = stem_template[..marker].to_ascii_lowercase();
    let suffix = stem_template[marker + 1..].to_ascii_lowercase();
    let parent = std::path::Path::new(destination);
    match std::fs::read_dir(parent) {
        Ok(mut entries) => entries.try_fold(0_u32, |highest, entry| {
            let entry = entry.map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!("read output destination {}: {error}", parent.display()),
                )
            })?;
            let stem = entry
                .path()
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            let Some(number) = stem
                .strip_prefix(&prefix)
                .and_then(|remaining| remaining.strip_suffix(&suffix))
                .and_then(|digits| digits.parse::<u32>().ok())
                .filter(|number| *number > 0)
            else {
                return Ok(highest);
            };
            Ok(highest.max(number))
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("read output destination {}: {error}", parent.display()),
        )),
    }
}

fn highest_existing_sequence_for_recipe(
    recipes: &domain::OutputRecipe,
) -> Result<u32, domain::EngineError> {
    let mut highest = 0;
    if recipes.archive.enabled {
        highest = highest.max(highest_existing_sequence_number(
            &recipes.archive.destination,
            &recipes.archive.filename_template,
            domain::OutputFileFormat::Tiff,
        )?);
    }
    if recipes.positive.enabled {
        highest = highest.max(highest_existing_sequence_number(
            &recipes.positive.destination,
            &recipes.positive.filename_template,
            recipes.positive.file_format,
        )?);
    }
    if recipes.preview.enabled {
        highest = highest.max(highest_existing_sequence_number(
            &recipes.preview.destination,
            &recipes.preview.filename_template,
            recipes.preview.file_format,
        )?);
    }
    if recipes.raw_export.enabled {
        highest = highest.max(highest_existing_raw_sequence_number(
            &recipes.raw_export.destination,
            &recipes.raw_export.filename_template,
            recipes.raw_export.file_format,
        )?);
    }
    Ok(highest)
}

/// Converts the new single-`#` sequence token into exact, per-frame names
/// before either backend receives a job. It allocates consecutive positive
/// integers in request order and skips a number whenever *any* enabled
/// auto-named archive/IR/meter/positive/preview target already has that stem
/// in its own effective destination. Legacy multi-hash templates are never
/// touched.
pub fn reserve_auto_sequence_filenames(
    frames: &[u32],
    recipe: &domain::CaptureRecipe,
    processing: &domain::ProcessingRecipe,
    recipes: &domain::OutputRecipe,
    overrides: &mut std::collections::HashMap<u32, domain::FrameOverrides>,
) -> Result<(), domain::EngineError> {
    let base_recipe = recipe.effective_for_process(processing.film_process);
    let mut highest_existing = 0_u32;
    for frame_index in frames {
        let frame_output = overrides
            .get(frame_index)
            .and_then(|value| value.output.as_ref())
            .unwrap_or(recipes);
        highest_existing = highest_existing.max(highest_existing_sequence_for_recipe(frame_output)?);
    }
    let mut next_number = highest_existing.checked_add(1).ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            "no positive filename sequence number remains available",
        )
    })?;

    for frame_index in frames {
        let frame_values = overrides.get(frame_index);
        let frame_output = frame_values
            .and_then(|value| value.output.as_ref())
            .unwrap_or(recipes)
            .clone();
        if !has_auto_sequence_template(&frame_output) {
            continue;
        }
        let frame_processing = frame_values
            .and_then(|value| value.processing.as_ref())
            .unwrap_or(processing)
            .effective();
        let frame_recipe = frame_values
            .and_then(|value| value.capture.as_ref())
            .unwrap_or(recipe)
            .effective_for_process(frame_processing.film_process);
        let include_ir_sidecar = base_recipe.channels == domain::Channels::Rgbi
            || frame_recipe.channels == domain::Channels::Rgbi;

        loop {
            let mut candidate_output = frame_output.clone();
            reserve_auto_sequence_templates(&mut candidate_output, next_number);
            let occupied = reserved_sequence_paths(
                &candidate_output,
                include_ir_sidecar,
                true,
            )?
            .iter()
            .try_fold(false, |occupied, path| {
                Ok::<_, domain::EngineError>(occupied || sequence_stem_exists(path)?)
            })?;
            if !occupied {
                let frame_values = overrides.entry(*frame_index).or_default();
                frame_values.output = Some(candidate_output);
                next_number = next_number.checked_add(1).ok_or_else(|| {
                    domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        "no positive filename sequence number remains available",
                    )
                })?;
                break;
            }
            next_number = next_number.checked_add(1).ok_or_else(|| {
                domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    "no positive filename sequence number remains available",
                )
            })?;
        }
    }
    Ok(())
}

/// Output templates are file *names*, never paths. Validate before any
/// backend joins a template to its selected destination so simulator and
/// bridge jobs fail the same way rather than allowing `..` or an absolute
/// component to escape the operator's chosen folder.
pub fn validate_user_output_recipe_paths(
    recipes: &domain::OutputRecipe,
) -> Result<(), domain::EngineError> {
    debug_assert_eq!(
        recipes.contains_reserved_filename_marker(),
        [
            recipes.archive.filename_template.as_str(),
            recipes.positive.filename_template.as_str(),
            recipes.preview.filename_template.as_str(),
            recipes.raw_export.filename_template.as_str(),
        ]
        .into_iter()
        .any(is_reserved_sequence_template)
    );
    for (label, template) in [
        ("archive", recipes.archive.filename_template.as_str()),
        ("positive", recipes.positive.filename_template.as_str()),
        ("preview", recipes.preview.filename_template.as_str()),
        ("raw export", recipes.raw_export.filename_template.as_str()),
    ] {
        if is_reserved_sequence_template(template) {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "{label} filename template contains a reserved engine marker; use # for automatic numbering"
                ),
            ));
        }
    }
    validate_output_recipe_paths(recipes)
}

pub fn validate_output_recipe_paths(recipes: &domain::OutputRecipe) -> Result<(), domain::EngineError> {
    let mut outputs = Vec::new();
    if recipes.archive.enabled {
        outputs.push(("archive", recipes.archive.destination.as_str(), recipes.archive.filename_template.as_str()));
    }
    if recipes.positive.enabled {
        outputs.push(("positive", recipes.positive.destination.as_str(), recipes.positive.filename_template.as_str()));
    }
    if recipes.preview.enabled {
        outputs.push(("preview", recipes.preview.destination.as_str(), recipes.preview.filename_template.as_str()));
    }
    if recipes.raw_export.enabled {
        outputs.push((
            "raw export",
            recipes.raw_export.destination.as_str(),
            recipes.raw_export.filename_template.as_str(),
        ));
    }
    for (label, destination, template) in outputs {
        let path = std::path::Path::new(template);
        if destination.trim().is_empty()
            || template.trim().is_empty()
            || template.contains(['/', '\\', '\0'])
            || !matches!(
                (path.components().next(), path.components().count()),
                (Some(std::path::Component::Normal(_)), 1)
            )
        {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "{label} destination must be non-empty and its filename template must be one relative file name, without traversal"
                ),
            ));
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OutputNameKind {
    Tiff,
    Jpeg,
    Dng,
}

impl OutputNameKind {
    fn chosen_extension(self) -> &'static str {
        match self {
            Self::Tiff => "tif",
            Self::Jpeg => "jpg",
            Self::Dng => "dng",
        }
    }

    fn recognizes_extension(self, extension: &str) -> bool {
        match self {
            Self::Tiff => {
                extension.eq_ignore_ascii_case("tif")
                    || extension.eq_ignore_ascii_case("tiff")
            }
            Self::Jpeg => {
                extension.eq_ignore_ascii_case("jpg")
                    || extension.eq_ignore_ascii_case("jpeg")
            }
            Self::Dng => extension.eq_ignore_ascii_case("dng"),
        }
    }
}

fn output_name_kind(format: domain::OutputFileFormat) -> OutputNameKind {
    match format {
        domain::OutputFileFormat::Tiff => OutputNameKind::Tiff,
        domain::OutputFileFormat::Jpeg => OutputNameKind::Jpeg,
    }
}

/// The single extension policy used by server preflight, simulator writes,
/// real bridge slot maps, real derivative writes, and receipts. Only a
/// terminal extension belonging to the requested format is preserved.
/// Dotted metadata such as `EF50mmF1.8STM` therefore still receives `.tif`.
pub(crate) fn normalize_output_filename_template(
    filename_template: &str,
    format: domain::OutputFileFormat,
) -> String {
    let kind = output_name_kind(format);
    let recognized = std::path::Path::new(filename_template)
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| kind.recognizes_extension(value));
    if recognized {
        filename_template.to_string()
    } else {
        format!("{filename_template}.{}", kind.chosen_extension())
    }
}

pub(crate) fn normalize_raw_export_filename_template(
    filename_template: &str,
    format: domain::RawExportFormat,
) -> String {
    let kind = match format {
        domain::RawExportFormat::LinearDng => OutputNameKind::Dng,
        domain::RawExportFormat::LinearTiff => OutputNameKind::Tiff,
    };
    let path = std::path::Path::new(filename_template);
    let extension = path.extension().and_then(|value| value.to_str());
    if extension.is_some_and(|value| kind.recognizes_extension(value)) {
        return filename_template.to_string();
    }
    let is_known_output_extension = extension.is_some_and(|value| {
        OutputNameKind::Tiff.recognizes_extension(value)
            || OutputNameKind::Jpeg.recognizes_extension(value)
            || OutputNameKind::Dng.recognizes_extension(value)
    });
    if is_known_output_extension {
        let stem = path.file_stem().and_then(|value| value.to_str()).unwrap_or(filename_template);
        return format!("{stem}.{}", kind.chosen_extension());
    }
    format!("{filename_template}.{}", kind.chosen_extension())
}

pub(crate) fn resolve_output_path(
    destination: &str,
    filename_template: &str,
    frame_index: u32,
    format: domain::OutputFileFormat,
) -> std::path::PathBuf {
    let normalized = normalize_output_filename_template(filename_template, format);
    std::path::Path::new(destination).join(resolve_filename(&normalized, frame_index))
}

pub(crate) fn resolve_archive_output_path(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
) -> std::path::PathBuf {
    resolve_output_path(
        &recipes.archive.destination,
        &recipes.archive.filename_template,
        frame_index,
        domain::OutputFileFormat::Tiff,
    )
}

pub(crate) fn resolve_raw_export_output_path(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
) -> std::path::PathBuf {
    let normalized = normalize_raw_export_filename_template(
        &recipes.raw_export.filename_template,
        recipes.raw_export.file_format,
    );
    std::path::Path::new(&recipes.raw_export.destination)
        .join(resolve_filename(&normalized, frame_index))
}

pub(crate) fn raw_export_ir_sidecar_path(
    raw_export_path: &std::path::Path,
) -> std::path::PathBuf {
    let stem = raw_export_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("raw-negative");
    raw_export_path.with_file_name(format!("{stem}-ir.tif"))
}

pub(crate) fn archive_sidecar_path(
    archive_path: &std::path::Path,
    suffix: &str,
) -> Result<std::path::PathBuf, domain::EngineError> {
    let stem = archive_path
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "archive output has no usable file name: {}",
                    archive_path.display()
                ),
            )
        })?;
    Ok(archive_path.with_file_name(format!("{stem}_{suffix}.tif")))
}

#[derive(Debug, Clone)]
struct TargetCandidate {
    slot: u32,
    role: &'static str,
    path: std::path::PathBuf,
    create_only: bool,
}

#[derive(Debug)]
struct PhysicalTarget {
    key: String,
    handle: Option<same_file::Handle>,
    exists: bool,
}

fn lexical_absolute(path: &std::path::Path) -> Result<std::path::PathBuf, domain::EngineError> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("resolve current directory for output path: {error}"),
                )
            })?
            .join(path)
    };
    let mut normalized = std::path::PathBuf::new();
    for component in absolute.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    Ok(normalized)
}

/// Produces a conservative physical key without requiring the final role
/// folder to exist yet: lexical `.`/`..` are collapsed, the nearest
/// existing ancestor is canonicalized (resolving existing parent
/// symlinks), and the missing suffix is appended. Lower-casing makes
/// case-only aliases fail closed on both case-insensitive and
/// case-sensitive filesystems.
fn physical_target(path: &std::path::Path) -> Result<PhysicalTarget, domain::EngineError> {
    let normalized = lexical_absolute(path)?;
    let leaf = normalized
        .file_name()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("output target must end in a file name: {}", path.display()),
            )
        })?;
    let _ = leaf;

    let leaf_metadata = match std::fs::symlink_metadata(&normalized) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!(
                        "output target is an existing symlink and is refused: {}",
                        normalized.display()
                    ),
                ));
            }
            if !metadata.is_file() {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!(
                        "output target exists but is not a regular file: {}",
                        normalized.display()
                    ),
                ));
            }
            Some(metadata)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("inspect output target {}: {error}", normalized.display()),
            ))
        }
    };

    let mut ancestor = normalized.clone();
    let mut missing = Vec::<std::ffi::OsString>::new();
    let canonical_ancestor = loop {
        match std::fs::canonicalize(&ancestor) {
            Ok(value) => {
                let metadata = std::fs::metadata(&value).map_err(|error| {
                    domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        format!("inspect output ancestor {}: {error}", value.display()),
                    )
                })?;
                if !missing.is_empty() && !metadata.is_dir() {
                    return Err(domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        format!(
                            "output ancestor is not a directory: {}",
                            value.display()
                        ),
                    ));
                }
                break value;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let component = ancestor.file_name().ok_or_else(|| {
                    domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        format!(
                            "cannot resolve an existing ancestor for output target {}",
                            normalized.display()
                        ),
                    )
                })?;
                missing.push(component.to_os_string());
                if !ancestor.pop() {
                    return Err(domain::EngineError::new(
                        protocol::ErrorCode::InvalidParams,
                        format!(
                            "cannot resolve an existing ancestor for output target {}",
                            normalized.display()
                        ),
                    ));
                }
            }
            Err(error) => {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!(
                        "canonicalize output target ancestor {}: {error}",
                        ancestor.display()
                    ),
                ))
            }
        }
    };
    let mut physical = canonical_ancestor;
    for component in missing.iter().rev() {
        physical.push(component);
    }

    Ok(PhysicalTarget {
        key: physical.to_string_lossy().to_lowercase(),
        handle: if leaf_metadata.is_some() {
            same_file::Handle::from_path(&normalized).ok()
        } else {
            None
        },
        exists: leaf_metadata.is_some(),
    })
}

fn validate_target_candidates(
    candidates: &[TargetCandidate],
) -> Result<(), domain::EngineError> {
    let mut resolved: Vec<(&TargetCandidate, PhysicalTarget)> =
        Vec::with_capacity(candidates.len());
    for candidate in candidates {
        let physical = physical_target(&candidate.path)?;
        if candidate.create_only && physical.exists {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::ArchiveCollision,
                format!(
                    "{} output for frame {} already exists at {}; capture outputs are create-only",
                    candidate.role,
                    candidate.slot,
                    candidate.path.display()
                ),
            ));
        }
        for (other, other_physical) in &resolved {
            let same_path = physical.key == other_physical.key;
            let same_file =
                matches!((&physical.handle, &other_physical.handle), (Some(a), Some(b)) if a == b);
            if same_path || same_file {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    format!(
                        "enabled outputs must resolve to distinct physical files before capture: frame {} {} aliases frame {} {}",
                        candidate.slot, candidate.role, other.slot, other.role
                    ),
                ));
            }
        }
        resolved.push((candidate, physical));
    }
    Ok(())
}

fn frame_target_candidates(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
    include_ir_sidecar: bool,
    include_meter_sidecar: bool,
    include_raw_ir_sidecar: bool,
) -> Result<Vec<TargetCandidate>, domain::EngineError> {
    validate_output_recipe_paths(recipes)?;
    let archive = recipes.archive.enabled.then(|| resolve_archive_output_path(recipes, frame_index));
    let mut candidates = Vec::new();
    if let Some(archive) = archive.as_ref() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "archive RGB",
            path: archive.clone(),
            create_only: true,
        });
    }
    if include_ir_sidecar && archive.is_some() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "archive IR sidecar",
            path: archive_sidecar_path(archive.as_ref().expect("archive sidecar requires retained archive"), "IR")?,
            create_only: true,
        });
    }
    if include_meter_sidecar && archive.is_some() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "archive meter sidecar",
            path: archive_sidecar_path(archive.as_ref().expect("archive sidecar requires retained archive"), "METER")?,
            create_only: true,
        });
    }
    if recipes.positive.enabled {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "positive",
            path: resolve_output_path(
                &recipes.positive.destination,
                &recipes.positive.filename_template,
                frame_index,
                recipes.positive.file_format,
            ),
            create_only: is_reserved_sequence_template(&recipes.positive.filename_template),
        });
    }
    if recipes.preview.enabled {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "preview",
            path: resolve_output_path(
                &recipes.preview.destination,
                &recipes.preview.filename_template,
                frame_index,
                recipes.preview.file_format,
            ),
            create_only: is_reserved_sequence_template(&recipes.preview.filename_template),
        });
    }
    if recipes.raw_export.enabled {
        let raw = resolve_raw_export_output_path(recipes, frame_index);
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "raw negative",
            path: raw.clone(),
            create_only: true,
        });
        if include_raw_ir_sidecar
            && recipes.raw_export.tiff_infrared == domain::RawTiffInfrared::Sidecar
        {
            candidates.push(TargetCandidate {
                slot: frame_index,
                role: "raw infrared sidecar",
                path: raw_export_ir_sidecar_path(&raw),
                create_only: true,
            });
        }
    }
    Ok(candidates)
}

/// Validates every physical target for the complete requested batch in one
/// pass. Archive RGB, possible IR, and possible meter files participate
/// alongside both derivatives, including across different slots.
pub fn validate_batch_output_paths(
    frames: &[u32],
    recipe: &domain::CaptureRecipe,
    processing: &domain::ProcessingRecipe,
    recipes: &domain::OutputRecipe,
    overrides: &std::collections::HashMap<u32, domain::FrameOverrides>,
) -> Result<(), domain::EngineError> {
    let base_recipe = recipe.effective_for_process(processing.film_process);
    let mut candidates = Vec::new();
    for frame_index in frames {
        let frame_override = overrides.get(frame_index);
        let frame_recipes = frame_override
            .and_then(|value| value.output.as_ref())
            .unwrap_or(recipes);
        let frame_processing = frame_override
            .and_then(|value| value.processing.as_ref())
            .unwrap_or(processing)
            .effective();
        let frame_recipe = frame_override
            .and_then(|value| value.capture.as_ref())
            .unwrap_or(recipe)
            .effective_for_process(frame_processing.film_process);
        // The real backend currently uses the batch capture recipe even
        // when a legacy per-frame capture override exists. Include IR if
        // either route could create it; over-rejection is safer than
        // omitting a possible archive sidecar.
        let include_ir = base_recipe.channels == domain::Channels::Rgbi
            || frame_recipe.channels == domain::Channels::Rgbi;
        candidates.extend(frame_target_candidates(
            frame_recipes,
            *frame_index,
            include_ir,
            true,
            include_ir,
        )?);
    }
    validate_target_candidates(&candidates)
}

fn targets_match(
    expected: &std::path::Path,
    actual: &std::path::Path,
) -> Result<bool, domain::EngineError> {
    let expected = physical_target(expected)?;
    let actual = physical_target(actual)?;
    if !actual.exists {
        return Ok(false);
    }
    let same_path = expected.key == actual.key;
    let same_file =
        matches!((&expected.handle, &actual.handle), (Some(a), Some(b)) if a == b);
    Ok(same_path || same_file)
}

/// Checks a real bridge receipt against the same final-name resolver used
/// before dispatch. The receipt path remains the authority after it
/// matches; callers must render, persist, and package from that exact path.
#[cfg(test)]
pub(crate) fn validate_bridge_capture_receipt_paths(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
    channels: domain::Channels,
    rgb_path: &std::path::Path,
    ir_path: Option<&std::path::Path>,
    meter_path: Option<&std::path::Path>,
) -> Result<(), domain::EngineError> {
    validate_output_recipe_paths(recipes)?;
    let expected_rgb = resolve_archive_output_path(recipes, frame_index);
    validate_bridge_capture_receipt_paths_for_expected(
        &expected_rgb,
        frame_index,
        channels,
        rgb_path,
        ir_path,
        meter_path,
    )
}

/// Validates a real bridge receipt against an already-reserved exact
/// capture target. Used both for retained masters and the real backend's
/// private, job-owned working captures; neither path may be inferred from
/// a user-visible recipe after the bridge starts.
pub(crate) fn validate_bridge_capture_receipt_paths_for_expected(
    expected_rgb: &std::path::Path,
    frame_index: u32,
    channels: domain::Channels,
    rgb_path: &std::path::Path,
    ir_path: Option<&std::path::Path>,
    meter_path: Option<&std::path::Path>,
) -> Result<(), domain::EngineError> {
    if !targets_match(&expected_rgb, rgb_path)? {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "bridge RGB receipt path {} does not match the reserved frame {} capture target {}",
                rgb_path.display(),
                frame_index,
                expected_rgb.display()
            ),
        ));
    }

    let expected_ir = archive_sidecar_path(&expected_rgb, "IR")?;
    match (channels, ir_path) {
        (domain::Channels::Rgbi, Some(actual))
            if targets_match(&expected_ir, actual)? => {}
        (domain::Channels::Rgbi, Some(actual)) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                "bridge IR receipt path {} does not match the reserved frame {} capture sidecar {}",
                    actual.display(),
                    frame_index,
                    expected_ir.display()
                ),
            ))
        }
        (domain::Channels::Rgbi, None) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("bridge RGBI receipt omitted frame {frame_index}'s IR sidecar"),
            ))
        }
        (domain::Channels::Rgb, Some(actual)) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "bridge RGB-only receipt unexpectedly supplied IR path {} for frame {}",
                    actual.display(),
                    frame_index
                ),
            ))
        }
        (domain::Channels::Rgb, None) => {}
    }

    if let Some(actual) = meter_path {
        let expected_meter = archive_sidecar_path(&expected_rgb, "METER")?;
        if !targets_match(&expected_meter, actual)? {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "bridge meter receipt path {} does not match the reserved frame {} sidecar {}",
                    actual.display(),
                    frame_index,
                    expected_meter.display()
                ),
            ));
        }
    }
    Ok(())
}

pub(crate) fn validate_bridge_raw_export_receipt_path(
    expected: Option<&std::path::Path>,
    actual: Option<&std::path::Path>,
    frame_index: u32,
) -> Result<(), domain::EngineError> {
    match (expected, actual) {
        (Some(expected), Some(actual)) if targets_match(expected, actual)? => Ok(()),
        (Some(expected), Some(actual)) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "bridge raw export receipt path {} does not match the reserved frame {} output {}",
                actual.display(),
                frame_index,
                expected.display()
            ),
        )),
        (Some(expected), None) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "bridge receipt omitted frame {} raw export {}",
                frame_index,
                expected.display()
            ),
        )),
        (None, Some(actual)) => Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "bridge receipt unexpectedly supplied raw export {} for frame {}",
                actual.display(),
                frame_index
            ),
        )),
        (None, None) => Ok(()),
    }
}

pub fn validate_frame_output_paths(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
) -> Result<
    (
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
    ),
    domain::EngineError,
> {
    validate_frame_output_paths_with_raw_ir(recipes, frame_index, true)
}

fn validate_frame_output_paths_with_raw_ir(
    recipes: &domain::OutputRecipe,
    frame_index: u32,
    raw_ir_available: bool,
) -> Result<
    (
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
    ),
    domain::EngineError,
> {
    let candidates = frame_target_candidates(
        recipes,
        frame_index,
        false,
        false,
        raw_ir_available,
    )?;
    validate_target_candidates(&candidates)?;
    let archive = recipes.archive.enabled.then(|| resolve_archive_output_path(recipes, frame_index));
    let positive = recipes.positive.enabled.then(|| {
        resolve_output_path(
            &recipes.positive.destination,
            &recipes.positive.filename_template,
            frame_index,
            recipes.positive.file_format,
        )
    });
    let preview = recipes.preview.enabled.then(|| {
        resolve_output_path(
            &recipes.preview.destination,
            &recipes.preview.filename_template,
            frame_index,
            recipes.preview.file_format,
        )
    });
    let raw_export = recipes
        .raw_export
        .enabled
        .then(|| resolve_raw_export_output_path(recipes, frame_index));
    let raw_export_ir = raw_export.as_ref().and_then(|path| {
        (raw_ir_available
            && recipes.raw_export.tiff_infrared == domain::RawTiffInfrared::Sidecar)
            .then(|| raw_export_ir_sidecar_path(path))
    });
    Ok((archive, positive, preview, raw_export, raw_export_ir))
}

/// Resolves the roll-level naming tokens before a backend starts work. The
/// remaining `####` run is intentionally left intact for the established
/// simulator and bridge frame-number resolvers. This keeps old templates
/// such as `Archive_####` byte-for-byte compatible.
pub fn materialize_output_filename_tokens(
    recipes: &mut domain::OutputRecipe,
    metadata: &domain::MetadataSet,
) {
    for template in [
        &mut recipes.archive.filename_template,
        &mut recipes.positive.filename_template,
        &mut recipes.preview.filename_template,
        &mut recipes.raw_export.filename_template,
    ] {
        *template = materialize_filename_tokens(template, metadata);
    }
}

pub fn materialize_filename_tokens(template: &str, metadata: &domain::MetadataSet) -> String {
    let (year, month, day) = metadata_date_tokens(metadata.date.as_ref());
    let substitutions = [
        ("$FilmStock", filename_component(metadata.film_stock.as_deref().unwrap_or("UnknownFilm"))),
        ("$Camera", filename_component(metadata.camera.as_deref().unwrap_or("UnknownCamera"))),
        ("$Lens", filename_component(metadata.lens.as_deref().unwrap_or("UnknownLens"))),
        ("$Year", year),
        ("$Month", month),
        ("$Day", day),
        // `$Frame` is translated to the established hash-run convention so
        // both the simulator and the real bridge preserve their proven
        // frame-number substitution behavior.
        // The bridge's resolver intentionally recognizes the legacy
        // four-character run only. Keep that wire contract here: using a
        // shorter run would leave every real slot pointed at the literal
        // same `##` destination before the scanner moves.
        ("$Frame", "####".to_string()),
    ];
    substitutions.into_iter().fold(template.to_string(), |value, (token, replacement)| {
        value.replace(token, &replacement)
    })
}

fn filename_component(value: &str) -> String {
    let value = value.replace("f/", "F").replace("F/", "F");
    let mut output = String::with_capacity(value.len());
    let mut previous_separator = false;
    for character in value.chars() {
        let forbidden = matches!(character, '/' | '\\' | ':' | '\0' | '\n' | '\r');
        if character.is_whitespace() {
            continue;
        }
        if forbidden {
            if !previous_separator {
                previous_separator = true;
            }
        } else {
            output.push(character);
            previous_separator = false;
        }
    }
    let output = output.trim_matches(|c| c == '.' || c == '-');
    if output.is_empty() { "Unknown".to_string() } else { output.to_string() }
}

fn metadata_date_tokens(date: Option<&domain::PartialDate>) -> (String, String, String) {
    match date {
        Some(domain::PartialDate::Exact { date }) => {
            let parts: Vec<_> = date.split('-').collect();
            if parts.len() == 3 && parts.iter().all(|part| part.chars().all(|c| c.is_ascii_digit())) {
                (parts[0].to_string(), parts[1].to_string(), parts[2].to_string())
            } else {
                ("UnknownYear".into(), "UnknownMonth".into(), "UnknownDay".into())
            }
        }
        Some(domain::PartialDate::MonthOnly { year, month }) => (
            format!("{year:04}"), format!("{month:02}"), "UnknownDay".into(),
        ),
        Some(domain::PartialDate::YearOnly { year }) => (
            format!("{year:04}"), "UnknownMonth".into(), "UnknownDay".into(),
        ),
        Some(domain::PartialDate::Unknown) | None => (
            "UnknownYear".into(), "UnknownMonth".into(), "UnknownDay".into(),
        ),
    }
}

// ---------------------------------------------------------------------
// Positive rendering (nikonlook wiring)
// ---------------------------------------------------------------------

/// C-41 color-negative frames run through the real, parity-tested
/// nikonlook color pipeline (Phase 14). Positive/Kodachrome are already
/// positive and pass through unchanged. B&W negatives use a neutral RGB
/// average followed by inversion, while C-41 alone uses nikonlook because
/// its matrix+curves are dye-specific.
///
/// `width` is the decoded raster's width (`raw.len() / width` is its
/// height) — nikonlook v2's blind gain estimator samples on a 2D grid and
/// needs it; `exposure_10ns` is the frame's hardware exposure in 10ns
/// ticks when the caller has it (real backend only, env-gated — see
/// `real_backend.rs`), `None` otherwise (simulator, or the exposure path
/// opted out), which routes v2 to its blind fallback instead of the
/// hardware-exposure inverse.
///
/// Returns the rendered positive plus, for a C41 frame, the nikonlook
/// provenance (bundle version, which Layer-A path actually ran, the exact
/// gains applied) so a caller can surface it in the frame's receipt — see
/// `domain::NikonlookProvenance`. `None` for every non-C41 process, which
/// never touches nikonlook at all. `exposure_10ns.is_some()` alone is NOT
/// enough to determine which path ran: `estimate_gains` silently falls
/// back to blind on an unusable exposure value (Finding 5), so the actual
/// path is derived here via `nikonlook::exposure_is_usable` — the same
/// predicate `estimate_gains` itself gates on — rather than assumed from
/// the caller's input.
fn render_positive(
    film_process: domain::FilmProcess,
    raw: &[[f64; 3]],
    width: usize,
    exposure_10ns: Option<[f64; 3]>,
) -> Result<(Vec<[f64; 3]>, Option<domain::NikonlookProvenance>), domain::EngineError> {
    match film_process {
        domain::FilmProcess::C41ColorNegative => {
            let bundle = crate::processing::nikonlook::load_bundle().map_err(|err| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("nikonlook bundle failed to load: {err}"),
                )
            })?;
            let k = crate::processing::nikonlook::estimate_gains(raw, width, exposure_10ns, &bundle)
                .map_err(|err| {
                    domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        format!("nikonlook gain estimation failed: {err}"),
                    )
                })?;
            let positive = crate::processing::nikonlook::apply(raw, k, &bundle);
            let layer_a_path = if exposure_10ns.is_some_and(crate::processing::nikonlook::exposure_is_usable) {
                domain::NikonlookLayerAPath::HardwareExposure
            } else {
                domain::NikonlookLayerAPath::Blind
            };
            let provenance = domain::NikonlookProvenance {
                bundle_version: bundle.bundle_version.clone(),
                layer_a_path,
                gains: k,
            };
            Ok((positive, Some(provenance)))
        }
        domain::FilmProcess::BwNegative => Ok((
            raw.iter()
                .map(|pixel| {
                    let inverted = 1.0 - (pixel[0] + pixel[1] + pixel[2]) / 3.0;
                    [inverted, inverted, inverted]
                })
                .collect(),
            None,
        )),
        domain::FilmProcess::Positive | domain::FilmProcess::Kodachrome => Ok((raw.to_vec(), None)),
    }
}

/// Conservative RGB-only, classical-CV cleanup for isolated bright/dark B&W
/// dust impulses. Runs after B&W inversion on derivatives only; archive pixels
/// are never passed here. A low-variance 5×5 outer ring supplies the local
/// background estimate, which fails closed around edges and grain clusters.
pub fn software_dust_remove_bw(raw: &[[f64; 3]], width: u32, height: u32) -> Vec<[f64; 3]> {
    software_dust_remove_bw_owned(raw.to_vec(), width, height)
}

/// Owned-buffer variant used by rendering. It mutates the already-owned
/// positive derivative, avoiding a second full RGB f64 buffer; the only
/// frame-sized auxiliary allocation is the one-byte candidate mask.
pub fn software_dust_remove_bw_owned(mut raw: Vec<[f64; 3]>, width: u32, height: u32) -> Vec<[f64; 3]> {
    if width < 5 || height < 5 || raw.len() != (width as usize).saturating_mul(height as usize) {
        return raw;
    }
    // One byte/pixel candidate mask; no per-pixel RGB background cache.
    // At a full 3946×5959 frame this auxiliary buffer is ~23.5 MB.
    let luminance = |pixel: [f64; 3]| (pixel[0] + pixel[1] + pixel[2]) / 3.0;
    // `1` and `-1` retain each candidate's residual polarity. Components
    // and their conservative expansion must never merge a bright impulse
    // into an adjacent dark image detail (or the converse).
    let mut candidates = vec![0i8; raw.len()];
    // A 5x5 local ring gives a compact 1-3 pixel dust component a stable
    // background estimate while an edge's mixed ring fails closed.
    for y in 2..height - 2 {
        for x in 2..width - 2 {
            let index = (y * width + x) as usize;
            let mut count = 0.0;
            let mut min = f64::INFINITY;
            let mut max = f64::NEG_INFINITY;
            let mut sums = [0.0; 3];
            for dy in -2i32..=2 {
                for dx in -2i32..=2 {
                    if dx.abs() <= 1 && dy.abs() <= 1 { continue; }
                    let pixel = raw[((y as i32 + dy) as u32 * width + (x as i32 + dx) as u32) as usize];
                    let value = luminance(pixel);
                    min = min.min(value);
                    max = max.max(value);
                    sums[0] += pixel[0]; sums[1] += pixel[1]; sums[2] += pixel[2];
                    count += 1.0;
                }
            }
            let background = [sums[0] / count, sums[1] / count, sums[2] / count];
            let residual = luminance(raw[index]) - luminance(background);
            if max - min <= 0.06 && residual.abs() >= 0.22 {
                candidates[index] = if residual.is_sign_positive() { 1 } else { -1 };
            }
        }
    }
    let mut visited = vec![false; raw.len()];
    for start in 0..raw.len() {
        if visited[start] || candidates[start] == 0 { continue; }
        let candidate_sign = candidates[start];
        let mut stack = vec![start];
        let mut component = Vec::new();
        visited[start] = true;
        while let Some(index) = stack.pop() {
            component.push(index);
            let x = index % width as usize;
            let y = index / width as usize;
            for dy in y.saturating_sub(1)..=(y + 1).min(height as usize - 1) {
                for dx in x.saturating_sub(1)..=(x + 1).min(width as usize - 1) {
                    let neighbor = dy * width as usize + dx;
                    if !visited[neighbor] && candidates[neighbor] == candidate_sign {
                        visited[neighbor] = true;
                        stack.push(neighbor);
                    }
                }
            }
        }
        if component.len() <= 9 {
            let seed = component[0];
            let sx = seed % width as usize;
            let sy = seed / width as usize;
            let mut sums = [0.0; 3];
            let mut count = 0.0;
            for dy in sy - 2..=sy + 2 {
                for dx in sx - 2..=sx + 2 {
                    if (dx as isize - sx as isize).abs() <= 1 && (dy as isize - sy as isize).abs() <= 1 { continue; }
                    let pixel = raw[dy * width as usize + dx];
                    sums[0] += pixel[0]; sums[1] += pixel[1]; sums[2] += pixel[2]; count += 1.0;
                }
            }
            let replacement = [sums[0] / count, sums[1] / count, sums[2] / count];
            let seed_residual = luminance(raw[seed]) - luminance(replacement);
            // Expand a conservative accepted seed across an adjacent compact
            // same-polarity blob. This catches 3x3 dust whose corner ring is
            // contaminated by its own component, without treating a mixed
            // edge as dust (mixed edges never produced the seed).
            let mut cursor = 0;
            while cursor < component.len() && component.len() < 9 {
                let index = component[cursor];
                let x = index % width as usize;
                let y = index / width as usize;
                for dy in y.saturating_sub(1)..=(y + 1).min(height as usize - 1) {
                    for dx in x.saturating_sub(1)..=(x + 1).min(width as usize - 1) {
                        let neighbor = dy * width as usize + dx;
                        let residual = luminance(raw[neighbor]) - luminance(replacement);
                        if !component.contains(&neighbor)
                            && residual.abs() >= 0.22
                            && residual.signum() == seed_residual.signum()
                        {
                            component.push(neighbor);
                            if component.len() == 9 { break; }
                        }
                    }
                    if component.len() == 9 { break; }
                }
                cursor += 1;
            }
            for index in component { raw[index] = replacement; }
        }
    }
    raw
}

// ---------------------------------------------------------------------
// Real-archive derivative rendering
// ---------------------------------------------------------------------

/// The live ScanStudio/CoolscanPy storage transform whose stored RGB raster
/// is already in Nikon-render-parity orientation.
pub const STORAGE_TRANSFORM_SWAPAXES01: &str =
    "swapaxes01-scanner-native-to-nikon-render-parity-v2";

fn validate_real_derivative_output_paths(
    archive_rgb_path: &std::path::Path,
    frame_index: u32,
    recipes: &domain::OutputRecipe,
) -> Result<
    (
        Option<std::path::PathBuf>,
        Option<std::path::PathBuf>,
    ),
    domain::EngineError,
> {
    validate_output_recipe_paths(recipes)?;
    let mut candidates = vec![
        TargetCandidate {
            slot: frame_index,
            role: "actual archive RGB source",
            path: archive_rgb_path.to_path_buf(),
            create_only: false,
        },
        TargetCandidate {
            slot: frame_index,
            role: "actual archive IR sidecar",
            path: archive_sidecar_path(archive_rgb_path, "IR")?,
            create_only: false,
        },
        TargetCandidate {
            slot: frame_index,
            role: "actual archive meter sidecar",
            path: archive_sidecar_path(archive_rgb_path, "METER")?,
            create_only: false,
        },
    ];
    let positive = recipes.positive.enabled.then(|| {
        resolve_output_path(
            &recipes.positive.destination,
            &recipes.positive.filename_template,
            frame_index,
            recipes.positive.file_format,
        )
    });
    let preview = recipes.preview.enabled.then(|| {
        resolve_output_path(
            &recipes.preview.destination,
            &recipes.preview.filename_template,
            frame_index,
            recipes.preview.file_format,
        )
    });
    if let Some(path) = positive.as_ref() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "positive",
            path: path.clone(),
            create_only: false,
        });
    }
    if let Some(path) = preview.as_ref() {
        candidates.push(TargetCandidate {
            slot: frame_index,
            role: "preview",
            path: path.clone(),
            create_only: false,
        });
    }
    validate_target_candidates(&candidates)?;
    Ok((positive, preview))
}

/// Renders requested derivatives from an existing real-hardware RGB archive.
///
/// The archive is opened read-only and never rewritten. Unknown orientation,
/// unsupported color-profile requests, and approved crops without a detected
/// boundary are refused rather than guessed or silently ignored.
pub fn render_derivative_from_archive(
    archive_rgb_path: &std::path::Path,
    frame_index: u32,
    film_process: domain::FilmProcess,
    recipes: &domain::OutputRecipe,
    storage_transform: Option<&str>,
    storage_transform_override: Option<&str>,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
    resolution_dpi: u32,
) -> Result<WrittenPaths, domain::EngineError> {
    let processing = domain::ProcessingRecipe { film_process, ..domain::ProcessingRecipe::default() };
    render_derivative_from_archive_with_processing(
        archive_rgb_path, frame_index, &processing, recipes, storage_transform,
        storage_transform_override, detected_boundary, alignment,
        // This convenience wrapper has no hardware-exposure metadata to
        // pass through — callers that have it use the _with_processing
        // form directly (see real_backend.rs).
        None,
        resolution_dpi,
    )
}

/// Processing-aware real derivative path. The RGB archive is only read and
/// never rewritten; optional B&W dust cleanup is applied after inversion to
/// the regenerable positive/preview buffers. `exposure_10ns` is the frame's
/// hardware exposure (10ns ticks, RGB order) when the caller has it and has
/// opted into the exposure path — see `render_positive` and
/// `real_backend.rs`.
///
/// `resolution_dpi` is the capture recipe's DPI (`CaptureRecipe.resolution_dpi`)
/// and is embedded into TIFF derivatives as their XResolution/YResolution so
/// the output carries the same scale as the capture that produced it.
pub fn render_derivative_from_archive_with_processing(
    archive_rgb_path: &std::path::Path,
    frame_index: u32,
    processing: &domain::ProcessingRecipe,
    recipes: &domain::OutputRecipe,
    storage_transform: Option<&str>,
    storage_transform_override: Option<&str>,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
    exposure_10ns: Option<[f64; 3]>,
    resolution_dpi: u32,
) -> Result<WrittenPaths, domain::EngineError> {
    let derivative_transform = alignment
        .map(|value| value.derivative_transform)
        .unwrap_or_default();
    validate_derivative_transform(derivative_transform)?;
    if !recipes.positive.enabled && !recipes.preview.enabled {
        return Ok(WrittenPaths {
            archive_path: recipes.archive.enabled.then(|| archive_rgb_path.to_path_buf()),
            positive_path: None,
            preview_path: None,
            raw_negative_path: None,
            raw_negative_ir_path: None,
            nikonlook: None,
            auto_crop: None,
            derivative_transform,
        });
    }

    // Validate against the bridge receipt's actual archive authority before
    // opening that source or creating any derivative. A recipe-predicted
    // archive path is not evidence of where hardware really wrote.
    let (preflight_positive_path, preflight_preview_path) =
        validate_real_derivative_output_paths(archive_rgb_path, frame_index, recipes)?;

    if recipes.positive.color_profile != domain::OutputColorProfile::AdobeRgb1998 {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "positive color setting {:?} is unsupported: nikonlook writes values in the Adobe RGB (1998) color space and no alternate profile-conversion path exists",
                recipes.positive.color_profile
            ),
        ));
    }

    match storage_transform_override.or(storage_transform) {
        Some(STORAGE_TRANSFORM_SWAPAXES01) => {}
        Some(other) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!(
                    "unsupported storageTransform {other:?}: expected {STORAGE_TRANSFORM_SWAPAXES01:?}; refusing to guess an orientation"
                ),
            ));
        }
        None => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                "missing storageTransform: cannot determine archive raster orientation; refusing to guess"
                    .to_string(),
            ));
        }
    }

    if alignment.is_some_and(|value| value.approved) && detected_boundary.is_none() {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            "approved frame alignment has no detected boundary on this real archive; refusing to silently drop the crop"
                .to_string(),
        ));
    }

    let raw_image = image_io::read_rgb16(archive_rgb_path).map_err(|err| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to read RGB archive at {}: {err}",
                archive_rgb_path.display()
            ),
        )
    })?;
    let width = raw_image.width;
    let height = raw_image.height;
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
    drop(raw_image);

    // Detection reads the raw archive domain. An approved manual alignment
    // owns the crop, so detection is skipped rather than merely ignored.
    let alignment_owns_crop = alignment.is_some_and(|value| value.approved);
    let auto_crop_outcome = if recipes.auto_crop {
        if alignment_owns_crop {
            Some(auto_crop_deferred_to_alignment(width, height))
        } else {
            Some(detect_auto_crop(&raw_linear, width, height))
        }
    } else {
        None
    };

    let (positive_full, nikonlook) =
        render_positive(processing.film_process, &raw_linear, width as usize, exposure_10ns)?;
    drop(raw_linear);
    let positive_full = if processing.film_process == domain::FilmProcess::BwNegative
        && processing.software_dust_removal_bw
    {
        software_dust_remove_bw_owned(positive_full, width, height)
    } else {
        positive_full
    };

    let (mut positive_raw, mut positive_width, mut positive_height) = match alignment {
        Some(value) if value.approved => {
            apply_alignment_crop(&positive_full, width, height, detected_boundary, Some(value))
        }
        _ => match &auto_crop_outcome {
            Some(outcome) if outcome.applied => {
                let roi = outcome.roi.as_ref().expect("applied auto-crop outcome carries its ROI");
                crop_to_roi(&positive_full, width, roi)
            }
            _ => (positive_full, width, height),
        },
    };
    (positive_width, positive_height) = apply_derivative_transform_in_place(
        &mut positive_raw,
        positive_width,
        positive_height,
        derivative_transform,
    )?;

    let archive_path = recipes.archive.enabled.then(|| archive_rgb_path.to_path_buf());
    let mut positive_path = None;
    let mut preview_path = None;

    // The color-profile contract (ICC) and physical scale (DPI) differ per
    // output: the full-resolution positive is at `resolution_dpi`; the
    // downsampled preview must not claim that DPI. ICC attaches only for C41.
    let positive_metadata =
        DerivativeMetadata::positive(processing.film_process, resolution_dpi);
    let preview_metadata = DerivativeMetadata::preview(processing.film_process);

    if recipes.positive.enabled {
        let path = preflight_positive_path
            .clone()
            .expect("enabled positive has preflight path");
        write_derivative(
            &path,
            &positive_raw,
            positive_width,
            positive_height,
            recipes.positive.file_format,
            is_reserved_sequence_template(&recipes.positive.filename_template),
            &positive_metadata,
        )?;
        positive_path = Some(path);
    }

    if recipes.preview.enabled {
        let (preview_width, preview_height) = downsample_dimensions(
            positive_width,
            positive_height,
            recipes.preview.max_long_edge_px,
        );
        let preview_raw = downsample_nearest(
            &positive_raw,
            positive_width,
            positive_height,
            preview_width,
            preview_height,
        );
        let path = preflight_preview_path
            .clone()
            .expect("enabled preview has preflight path");
        write_derivative(
            &path,
            &preview_raw,
            preview_width,
            preview_height,
            recipes.preview.file_format,
            is_reserved_sequence_template(&recipes.preview.filename_template),
            &preview_metadata,
        )?;
        preview_path = Some(path);
    }

    Ok(WrittenPaths {
        archive_path,
        positive_path,
        preview_path,
        raw_negative_path: None,
        raw_negative_ir_path: None,
        nikonlook,
        auto_crop: auto_crop_outcome,
        derivative_transform,
    })
}

fn validate_derivative_transform(
    transform: domain::DerivativeTransform,
) -> Result<(), domain::EngineError> {
    if transform.is_supported() {
        Ok(())
    } else {
        Err(domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!(
                "unsupported derivative rotation {}: expected 0, 90, 180, or 270 degrees",
                transform.rotation_degrees
            ),
        ))
    }
}

/// Applies mirror(s) in the source axes followed by a clockwise quarter-turn.
/// The permutation is performed in place with one bit per pixel of cycle
/// bookkeeping, avoiding a second full-size floating-point frame buffer.
fn apply_derivative_transform_in_place(
    raw: &mut [[f64; 3]],
    width: u32,
    height: u32,
    transform: domain::DerivativeTransform,
) -> Result<(u32, u32), domain::EngineError> {
    validate_derivative_transform(transform)?;
    let expected_len = width as usize * height as usize;
    if raw.len() != expected_len {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            "derivative transform pixel buffer size does not match width*height".to_string(),
        ));
    }
    if expected_len <= 1 || transform == domain::DerivativeTransform::default() {
        return Ok((width, height));
    }

    let destination_index = |source_index: usize| -> usize {
        let x = source_index as u32 % width;
        let y = source_index as u32 / width;
        let mirrored_x = if transform.horizontal_mirror {
            width - 1 - x
        } else {
            x
        };
        let mirrored_y = if transform.vertical_mirror {
            height - 1 - y
        } else {
            y
        };
        let (destination_x, destination_y, destination_width) =
            match transform.rotation_degrees {
                0 => (mirrored_x, mirrored_y, width),
                90 => (height - 1 - mirrored_y, mirrored_x, height),
                180 => (width - 1 - mirrored_x, height - 1 - mirrored_y, width),
                270 => (mirrored_y, width - 1 - mirrored_x, height),
                _ => unreachable!("validated quarter-turn"),
            };
        (destination_y * destination_width + destination_x) as usize
    };

    let mut visited = vec![false; expected_len];
    for start in 0..expected_len {
        if visited[start] {
            continue;
        }
        let mut source = start;
        let mut carried = raw[source];
        loop {
            visited[source] = true;
            let destination = destination_index(source);
            std::mem::swap(&mut carried, &mut raw[destination]);
            source = destination;
            if source == start {
                break;
            }
        }
    }

    Ok(match transform.rotation_degrees {
        90 | 270 => (height, width),
        _ => (width, height),
    })
}

// ---------------------------------------------------------------------
// Preview downsampling
// ---------------------------------------------------------------------

fn downsample_dimensions(width: u32, height: u32, max_long_edge_px: u32) -> (u32, u32) {
    let long_edge = width.max(height);
    if long_edge <= max_long_edge_px || max_long_edge_px == 0 {
        return (width, height);
    }
    let scale = max_long_edge_px as f64 / long_edge as f64;
    (
        (width as f64 * scale).round().max(1.0) as u32,
        (height as f64 * scale).round().max(1.0) as u32,
    )
}

/// Nearest-neighbor resample using integer ratio math to avoid drift.
fn downsample_nearest(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    new_width: u32,
    new_height: u32,
) -> Vec<[f64; 3]> {
    let mut out = Vec::with_capacity(new_width as usize * new_height as usize);
    for ny in 0..new_height {
        let sy = ((ny as u64 * height as u64) / new_height.max(1) as u64) as u32;
        let sy = sy.min(height.saturating_sub(1));
        for nx in 0..new_width {
            let sx = ((nx as u64 * width as u64) / new_width.max(1) as u64) as u32;
            let sx = sx.min(width.saturating_sub(1));
            out.push(raw[(sy * width + sx) as usize]);
        }
    }
    out
}

// ---------------------------------------------------------------------
// Quantization
// ---------------------------------------------------------------------

/// Round-half-up quantization from a `[0,1]` float to a full-scale `u16`
/// sample -- mirrors `parity::candidates::quantize_u16`'s formula exactly.
fn quantize_u16(value: f64) -> u16 {
    (value * 65535.0 + 0.5).clamp(0.0, 65535.0) as u16
}

/// Same convention as `quantize_u16`, scaled for 8-bit output.
fn quantize_u8(value: f64) -> u8 {
    (value * 255.0 + 0.5).clamp(0.0, 255.0) as u8
}

fn to_u16_samples(raw: &[[f64; 3]]) -> Vec<u16> {
    raw.iter()
        .flat_map(|px| px.iter().copied().map(quantize_u16))
        .collect()
}

fn to_u8_samples(raw: &[[f64; 3]]) -> Vec<u8> {
    raw.iter()
        .flat_map(|px| px.iter().copied().map(quantize_u8))
        .collect()
}

// ---------------------------------------------------------------------
// File writers
// ---------------------------------------------------------------------

/// Builds the in-memory `image::DynamicImage` for a raw `[0,1]`-float pixel
/// buffer at the given bit depth: `bit_depth == 8` selects the 8-bit/`Rgb8`
/// branch, anything else (in practice only `16`) selects the 16-bit/`Rgb16`
/// branch. Shared by both `write_tiff_create_only` (archive, driven by the
/// capture's own `bit_depth`) and `write_derivative` (derivatives, which
/// always force `16` for Tiff or `8` for Jpeg -- see its own doc comment).
fn build_dynamic_image(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    bit_depth: u32,
) -> Result<image::DynamicImage, domain::EngineError> {
    if bit_depth == 8 {
        let buffer =
            image::ImageBuffer::<image::Rgb<u8>, _>::from_raw(width, height, to_u8_samples(raw))
                .ok_or_else(|| {
                    domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        "8-bit pixel buffer size does not match width*height*3".to_string(),
                    )
                })?;
        Ok(image::DynamicImage::ImageRgb8(buffer))
    } else {
        let buffer =
            image::ImageBuffer::<image::Rgb<u16>, _>::from_raw(width, height, to_u16_samples(raw))
                .ok_or_else(|| {
                    domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        "16-bit pixel buffer size does not match width*height*3".to_string(),
                    )
                })?;
        Ok(image::DynamicImage::ImageRgb16(buffer))
    }
}

/// Strict create-only write: the OS refuses the open if `path` already
/// exists (T-03-03) -- the archive can never be silently replaced.
fn write_tiff_create_only(
    path: &std::path::Path,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    bit_depth: u32,
) -> Result<(), domain::EngineError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|err| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to create archive directory {}: {err}",
                    parent.display()
                ),
            )
        })?;
    }

    let file = match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
    {
        Ok(file) => file,
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::ArchiveCollision,
                format!(
                    "archive file already exists at {}: archive writes are create-only and never overwrite the master",
                    path.display()
                ),
            ));
        }
        Err(err) => {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to create archive file at {}: {err}", path.display()),
            ));
        }
    };

    let mut writer = std::io::BufWriter::new(file);
    let image = build_dynamic_image(raw, width, height, bit_depth)?;
    image
        .write_to(&mut writer, image::ImageFormat::Tiff)
        .map_err(|err| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to encode archive TIFF at {}: {err}", path.display()),
            )
        })?;
    writer.flush().map_err(|err| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("failed to flush archive TIFF at {}: {err}", path.display()),
        )
    })?;
    Ok(())
}

const RAW_IR_TAG: u16 = 65_001;
const RAW_IR_MARKER: &[u8] = b"scanstudio.infrared.linear.uint16.v1\0";

#[derive(Debug, Clone)]
struct RawTiffEntry {
    tag: u16,
    field_type: u16,
    count: u32,
    value: Vec<u8>,
}

impl RawTiffEntry {
    fn byte(tag: u16, values: &[u8]) -> Self {
        Self { tag, field_type: 1, count: values.len() as u32, value: values.to_vec() }
    }

    fn ascii(tag: u16, value: &str) -> Self {
        let mut bytes = value.as_bytes().to_vec();
        if !bytes.ends_with(&[0]) {
            bytes.push(0);
        }
        Self { tag, field_type: 2, count: bytes.len() as u32, value: bytes }
    }

    fn short(tag: u16, values: &[u16]) -> Self {
        Self {
            tag,
            field_type: 3,
            count: values.len() as u32,
            value: values.iter().flat_map(|value| value.to_le_bytes()).collect(),
        }
    }

    fn long(tag: u16, values: &[u32]) -> Self {
        Self {
            tag,
            field_type: 4,
            count: values.len() as u32,
            value: values.iter().flat_map(|value| value.to_le_bytes()).collect(),
        }
    }

    fn rational(tag: u16, values: &[(u32, u32)]) -> Self {
        let value = values
            .iter()
            .flat_map(|(numerator, denominator)| {
                numerator.to_le_bytes().into_iter().chain(denominator.to_le_bytes())
            })
            .collect();
        Self { tag, field_type: 5, count: values.len() as u32, value }
    }

    fn signed_rational(tag: u16, values: &[(i32, i32)]) -> Self {
        let value = values
            .iter()
            .flat_map(|(numerator, denominator)| {
                numerator.to_le_bytes().into_iter().chain(denominator.to_le_bytes())
            })
            .collect();
        Self { tag, field_type: 10, count: values.len() as u32, value }
    }
}

fn align_four(value: usize) -> usize {
    (value + 3) & !3
}

fn raw_ifd_storage_len(entries: &[RawTiffEntry], ifd_offset: usize) -> usize {
    let fixed_len = 2 + entries.len() * 12 + 4;
    let mut cursor = ifd_offset + fixed_len;
    for entry in entries {
        if entry.value.len() > 4 {
            cursor = align_four(cursor);
            cursor += entry.value.len();
        }
    }
    cursor - ifd_offset
}

fn serialize_raw_ifd(entries: &[RawTiffEntry], ifd_offset: usize) -> Vec<u8> {
    let mut entries = entries.to_vec();
    entries.sort_by_key(|entry| entry.tag);
    let fixed_len = 2 + entries.len() * 12 + 4;
    let mut bytes = vec![0_u8; fixed_len];
    bytes[0..2].copy_from_slice(&(entries.len() as u16).to_le_bytes());

    for (index, entry) in entries.iter().enumerate() {
        let base = 2 + index * 12;
        bytes[base..base + 2].copy_from_slice(&entry.tag.to_le_bytes());
        bytes[base + 2..base + 4].copy_from_slice(&entry.field_type.to_le_bytes());
        bytes[base + 4..base + 8].copy_from_slice(&entry.count.to_le_bytes());
        if entry.value.len() <= 4 {
            bytes[base + 8..base + 8 + entry.value.len()].copy_from_slice(&entry.value);
        } else {
            let aligned = align_four(ifd_offset + bytes.len());
            bytes.resize(aligned - ifd_offset, 0);
            bytes[base + 8..base + 12].copy_from_slice(&(aligned as u32).to_le_bytes());
            bytes.extend_from_slice(&entry.value);
        }
    }
    bytes
}

fn raw_baseline_entries(
    width: u32,
    height: u32,
    dpi: u32,
    samples_per_pixel: u16,
    photometric: u16,
    strip_offset: u32,
    strip_byte_count: u32,
) -> Vec<RawTiffEntry> {
    vec![
        RawTiffEntry::long(254, &[0]),
        RawTiffEntry::long(256, &[width]),
        RawTiffEntry::long(257, &[height]),
        RawTiffEntry::short(258, &vec![16; samples_per_pixel as usize]),
        RawTiffEntry::short(259, &[1]),
        RawTiffEntry::short(262, &[photometric]),
        RawTiffEntry::long(273, &[strip_offset]),
        RawTiffEntry::short(274, &[1]),
        RawTiffEntry::short(277, &[samples_per_pixel]),
        RawTiffEntry::long(278, &[height]),
        RawTiffEntry::long(279, &[strip_byte_count]),
        RawTiffEntry::rational(282, &[(dpi, 1)]),
        RawTiffEntry::rational(283, &[(dpi, 1)]),
        RawTiffEntry::short(284, &[1]),
        RawTiffEntry::short(296, &[2]),
        RawTiffEntry::ascii(305, "ScanStudio"),
    ]
}

fn dng_main_entries(
    width: u32,
    height: u32,
    dpi: u32,
    strip_offset: u32,
    strip_byte_count: u32,
    infrared_ifd_offset: Option<u32>,
) -> Vec<RawTiffEntry> {
    let mut entries = raw_baseline_entries(
        width,
        height,
        dpi,
        3,
        34_892,
        strip_offset,
        strip_byte_count,
    );
    entries.extend([
        RawTiffEntry::ascii(271, "Nikon"),
        RawTiffEntry::ascii(272, "Nikon Coolscan Simulator"),
    ]);
    if let Some(infrared_ifd_offset) = infrared_ifd_offset {
        entries.push(RawTiffEntry::long(330, &[infrared_ifd_offset]));
    }
    entries.extend([
        RawTiffEntry::byte(50_706, &[1, 4, 0, 0]),
        RawTiffEntry::byte(50_707, &[1, 1, 0, 0]),
        RawTiffEntry::ascii(50_708, "Nikon Coolscan Simulator"),
        RawTiffEntry::rational(50_714, &[(0, 1), (0, 1), (0, 1)]),
        RawTiffEntry::long(50_717, &[65_535, 65_535, 65_535]),
        RawTiffEntry::rational(50_718, &[(1, 1), (1, 1)]),
        RawTiffEntry::long(50_719, &[0, 0]),
        RawTiffEntry::long(50_720, &[width, height]),
        RawTiffEntry::signed_rational(
            50_721,
            &[
                (1, 1), (0, 1), (0, 1),
                (0, 1), (1, 1), (0, 1),
                (0, 1), (0, 1), (1, 1),
            ],
        ),
        RawTiffEntry::rational(50_728, &[(1, 1), (1, 1), (1, 1)]),
        RawTiffEntry::short(50_778, &[0]),
        RawTiffEntry::long(50_829, &[0, 0, height, width]),
    ]);
    entries
}

fn dng_infrared_entries(
    width: u32,
    height: u32,
    dpi: u32,
    strip_offset: u32,
    strip_byte_count: u32,
) -> Vec<RawTiffEntry> {
    let mut entries = raw_baseline_entries(
        width,
        height,
        dpi,
        1,
        1,
        strip_offset,
        strip_byte_count,
    );
    entries.extend([
        RawTiffEntry::ascii(270, "Untouched Nikon Coolscan infrared plane"),
        RawTiffEntry::ascii(RAW_IR_TAG, std::str::from_utf8(RAW_IR_MARKER).expect("marker is ASCII")),
    ]);
    entries
}

fn encoded_simulated_raw(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    dpi: u32,
    recipe: &domain::RawExportRecipe,
    ir_available: bool,
) -> Result<Vec<u8>, domain::EngineError> {
    let pixel_count = (width as usize).checked_mul(height as usize).ok_or_else(|| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw export dimensions overflow")
    })?;
    if raw.len() != pixel_count {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            "raw export pixel buffer does not match its dimensions",
        ));
    }
    let rgb_byte_count = u32::try_from(pixel_count.checked_mul(6).ok_or_else(|| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw RGB byte count overflow")
    })?)
    .map_err(|_| domain::EngineError::new(protocol::ErrorCode::Internal, "raw RGB exceeds classic TIFF"))?;
    let ir_byte_count = u32::try_from(pixel_count.checked_mul(2).ok_or_else(|| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw IR byte count overflow")
    })?)
    .map_err(|_| domain::EngineError::new(protocol::ErrorCode::Internal, "raw IR exceeds classic TIFF"))?;

    let mut bytes = b"II*\0\x08\0\0\0".to_vec();
    match recipe.file_format {
        domain::RawExportFormat::LinearDng => {
            let embed_infrared = ir_available
                && recipe.tiff_infrared != domain::RawTiffInfrared::Sidecar;
            let main_dummy = dng_main_entries(
                width,
                height,
                dpi,
                0,
                rgb_byte_count,
                embed_infrared.then_some(0),
            );
            let main_end = align_four(8 + raw_ifd_storage_len(&main_dummy, 8));
            let (infrared_ifd_offset, rgb_offset, infrared_offset) = if embed_infrared {
                let infrared_ifd_offset = main_end;
                let infrared_dummy =
                    dng_infrared_entries(width, height, dpi, 0, ir_byte_count);
                let rgb_offset = align_four(
                    infrared_ifd_offset
                        + raw_ifd_storage_len(&infrared_dummy, infrared_ifd_offset),
                );
                let infrared_offset = rgb_offset
                    .checked_add(rgb_byte_count as usize)
                    .ok_or_else(|| {
                        domain::EngineError::new(
                            protocol::ErrorCode::Internal,
                            "DNG offset overflow",
                        )
                    })?;
                (Some(infrared_ifd_offset), rgb_offset, Some(infrared_offset))
            } else {
                (None, main_end, None)
            };
            let main = dng_main_entries(
                width,
                height,
                dpi,
                rgb_offset as u32,
                rgb_byte_count,
                infrared_ifd_offset.map(|value| value as u32),
            );
            bytes.extend_from_slice(&serialize_raw_ifd(&main, 8));
            if let (Some(infrared_ifd_offset), Some(infrared_offset)) =
                (infrared_ifd_offset, infrared_offset)
            {
                bytes.resize(infrared_ifd_offset, 0);
                let infrared = dng_infrared_entries(
                    width,
                    height,
                    dpi,
                    infrared_offset as u32,
                    ir_byte_count,
                );
                bytes.extend_from_slice(&serialize_raw_ifd(&infrared, infrared_ifd_offset));
            }
            bytes.resize(rgb_offset, 0);
            for pixel in raw {
                for sample in pixel {
                    bytes.extend_from_slice(&quantize_u16(*sample).to_le_bytes());
                }
            }
            if embed_infrared {
                for pixel in raw {
                    let infrared = quantize_u16((pixel[0] + pixel[1] + pixel[2]) / 3.0);
                    bytes.extend_from_slice(&infrared.to_le_bytes());
                }
            }
        }
        domain::RawExportFormat::LinearTiff => {
            if !ir_available
                && recipe.tiff_infrared == domain::RawTiffInfrared::FourthChannel
            {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::InvalidParams,
                    "fourth-channel linear TIFF requires an infrared capture plane",
                ));
            }
            let include_infrared =
                recipe.tiff_infrared == domain::RawTiffInfrared::FourthChannel;
            let samples_per_pixel = if include_infrared { 4 } else { 3 };
            let strip_byte_count = if include_infrared {
                rgb_byte_count.checked_add(ir_byte_count).ok_or_else(|| {
                    domain::EngineError::new(protocol::ErrorCode::Internal, "raw TIFF byte count overflow")
                })?
            } else {
                rgb_byte_count
            };
            let mut dummy = raw_baseline_entries(
                width,
                height,
                dpi,
                samples_per_pixel,
                2,
                0,
                strip_byte_count,
            );
            if include_infrared {
                dummy.push(RawTiffEntry::short(338, &[0]));
                dummy.push(RawTiffEntry::ascii(
                    RAW_IR_TAG,
                    std::str::from_utf8(RAW_IR_MARKER).expect("marker is ASCII"),
                ));
            }
            let strip_offset = align_four(8 + raw_ifd_storage_len(&dummy, 8));
            let mut entries = raw_baseline_entries(
                width,
                height,
                dpi,
                samples_per_pixel,
                2,
                strip_offset as u32,
                strip_byte_count,
            );
            if include_infrared {
                entries.push(RawTiffEntry::short(338, &[0]));
                entries.push(RawTiffEntry::ascii(
                    RAW_IR_TAG,
                    std::str::from_utf8(RAW_IR_MARKER).expect("marker is ASCII"),
                ));
            }
            bytes.extend_from_slice(&serialize_raw_ifd(&entries, 8));
            bytes.resize(strip_offset, 0);
            for pixel in raw {
                for sample in pixel {
                    bytes.extend_from_slice(&quantize_u16(*sample).to_le_bytes());
                }
                if include_infrared {
                    let infrared = quantize_u16((pixel[0] + pixel[1] + pixel[2]) / 3.0);
                    bytes.extend_from_slice(&infrared.to_le_bytes());
                }
            }
        }
    }
    Ok(bytes)
}

fn encoded_simulated_raw_ir(
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    dpi: u32,
) -> Result<Vec<u8>, domain::EngineError> {
    let pixel_count = (width as usize).checked_mul(height as usize).ok_or_else(|| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw IR dimensions overflow")
    })?;
    let strip_byte_count = u32::try_from(pixel_count.checked_mul(2).ok_or_else(|| {
        domain::EngineError::new(protocol::ErrorCode::Internal, "raw IR byte count overflow")
    })?)
    .map_err(|_| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            "raw IR exceeds classic TIFF",
        )
    })?;
    let dummy = dng_infrared_entries(width, height, dpi, 0, strip_byte_count);
    let strip_offset = align_four(8 + raw_ifd_storage_len(&dummy, 8));
    let entries = dng_infrared_entries(
        width,
        height,
        dpi,
        strip_offset as u32,
        strip_byte_count,
    );
    let mut bytes = b"II*\0\x08\0\0\0".to_vec();
    bytes.extend_from_slice(&serialize_raw_ifd(&entries, 8));
    bytes.resize(strip_offset, 0);
    for pixel in raw {
        let infrared = quantize_u16((pixel[0] + pixel[1] + pixel[2]) / 3.0);
        bytes.extend_from_slice(&infrared.to_le_bytes());
    }
    Ok(bytes)
}

fn write_raw_export_create_only(
    path: &std::path::Path,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    dpi: u32,
    recipe: &domain::RawExportRecipe,
    ir_available: bool,
) -> Result<Option<std::path::PathBuf>, domain::EngineError> {
    let parent = path.parent().ok_or_else(|| {
        domain::EngineError::new(protocol::ErrorCode::InvalidParams, "raw export has no parent directory")
    })?;
    std::fs::create_dir_all(parent).map_err(|error| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!("failed to create raw export directory {}: {error}", parent.display()),
        )
    })?;
    let sidecar_path = (ir_available
        && recipe.tiff_infrared == domain::RawTiffInfrared::Sidecar)
        .then(|| raw_export_ir_sidecar_path(path));
    if path.exists() || sidecar_path.as_ref().is_some_and(|sidecar| sidecar.exists()) {
        return Err(domain::EngineError::new(
            protocol::ErrorCode::ArchiveCollision,
            format!(
                "raw export pair already exists at {}",
                sidecar_path.as_deref().unwrap_or(path).display()
            ),
        ));
    }
    let encoded = encoded_simulated_raw(raw, width, height, dpi, recipe, ir_available)?;
    static TEMP_COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let write_temporary = |target: &std::path::Path,
                           encoded: &[u8]|
     -> Result<std::path::PathBuf, domain::EngineError> {
        let counter = TEMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let temporary = parent.join(format!(
            ".{}.{}.{}.partial",
            target
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("raw-export"),
            std::process::id(),
            counter,
        ));
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("failed to create raw export temporary file: {error}"),
                )
            })?;
        let mut writer = std::io::BufWriter::new(file);
        writer.write_all(&encoded).map_err(|error| {
            domain::EngineError::new(protocol::ErrorCode::Internal, format!("failed to write raw export: {error}"))
        })?;
        writer.flush().map_err(|error| {
            domain::EngineError::new(protocol::ErrorCode::Internal, format!("failed to flush raw export: {error}"))
        })?;
        writer.get_ref().sync_all().map_err(|error| {
            domain::EngineError::new(protocol::ErrorCode::Internal, format!("failed to sync raw export: {error}"))
        })?;
        Ok(temporary)
    };
    let publish = |temporary: &std::path::Path,
                   target: &std::path::Path|
     -> Result<(), domain::EngineError> {
        std::fs::hard_link(temporary, target).map_err(|error| {
            let code = if error.kind() == std::io::ErrorKind::AlreadyExists {
                protocol::ErrorCode::ArchiveCollision
            } else {
                protocol::ErrorCode::Internal
            };
            domain::EngineError::new(
                code,
                format!("failed to publish raw export {}: {error}", target.display()),
            )
        })
    };

    let main_temporary = write_temporary(path, &encoded)?;
    let result = if let Some(sidecar_path) = sidecar_path.as_ref() {
        let sidecar_encoded = encoded_simulated_raw_ir(raw, width, height, dpi)?;
        let sidecar_temporary = match write_temporary(sidecar_path, &sidecar_encoded) {
            Ok(value) => value,
            Err(error) => {
                let _ = std::fs::remove_file(&main_temporary);
                return Err(error);
            }
        };
        let result = publish_raw_pair_with_hook(
            &main_temporary,
            path,
            &sidecar_temporary,
            sidecar_path,
            &publish,
            || Ok(()),
        );
        let _ = std::fs::remove_file(&sidecar_temporary);
        result
    } else {
        publish(&main_temporary, path)
    };
    let _ = std::fs::remove_file(&main_temporary);
    result.map(|()| sidecar_path)
}

fn publish_raw_pair_with_hook<Publish, Hook>(
    main_temporary: &std::path::Path,
    main_path: &std::path::Path,
    sidecar_temporary: &std::path::Path,
    sidecar_path: &std::path::Path,
    publish: Publish,
    before_sidecar_publish: Hook,
) -> Result<(), domain::EngineError>
where
    Publish: Fn(&std::path::Path, &std::path::Path) -> Result<(), domain::EngineError>,
    Hook: FnOnce() -> Result<(), domain::EngineError>,
{
    let mut main_published = false;
    let mut sidecar_published = false;
    let result = (|| {
        publish(main_temporary, main_path)?;
        main_published = true;
        before_sidecar_publish()?;
        publish(sidecar_temporary, sidecar_path)?;
        sidecar_published = true;
        if let Some(parent) = main_path.parent() {
            std::fs::File::open(parent)
                .and_then(|directory| directory.sync_all())
                .map_err(|error| {
                    domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        format!("failed to sync raw export pair directory: {error}"),
                    )
                })?;
        }
        Ok(())
    })();
    if result.is_err() {
        if sidecar_published {
            let _ = std::fs::remove_file(sidecar_path);
        }
        if main_published {
            let _ = std::fs::remove_file(main_path);
        }
    }
    result
}

/// Color/metadata to attach to a rendered derivative. It distinguishes two
/// independent guarantees:
///
/// * the color-profile contract — only a C41 color-negative render actually
///   produces Adobe RGB-family encoded values (see `render_positive`); the
///   positive-film/Kodachrome passthrough and the B&W inversion are not
///   Adobe RGB-encoded and must not be falsely labeled with that profile;
/// * the physical DPI scale — only the full-resolution positive is at the
///   capture recipe's DPI; the downsampled preview is not, so it must never
///   claim the capture DPI as its own.
#[derive(Debug, Clone, Copy)]
struct DerivativeMetadata {
    /// Capture recipe's DPI, written as the Positive TIFF's
    /// XResolution/YResolution in pixels/inch. `None` for the downsampled
    /// preview (and for any JPEG, which has no such resolution tags here).
    resolution_dpi: Option<u32>,
    /// Whether to embed ScanStudio's Adobe RGB (1998)-compatible ICC profile.
    attach_icc: bool,
}

impl DerivativeMetadata {
    /// Only the C41 color-negative path (nikonlook) produces the Adobe
    /// RGB-family encoding the profile labels; all other processes leave the
    /// buffer passthrough or grayscale and must stay unprofiled.
    fn attach_icc(film_process: domain::FilmProcess) -> bool {
        film_process == domain::FilmProcess::C41ColorNegative
    }

    /// Full-resolution positive output at the capture recipe's DPI.
    fn positive(film_process: domain::FilmProcess, resolution_dpi: u32) -> Self {
        Self {
            resolution_dpi: Some(resolution_dpi),
            attach_icc: Self::attach_icc(film_process),
        }
    }

    /// Downsampled preview output: same color contract as the positive, but
    /// never tagged at the capture DPI it was scaled down from.
    fn preview(film_process: domain::FilmProcess) -> Self {
        Self {
            resolution_dpi: None,
            attach_icc: Self::attach_icc(film_process),
        }
    }
}

/// Encodes a TIFF derivative directly with the `tiff` crate so the metadata
/// the `image` crate's higher-level TiffEncoder omits (resolution tags and
/// the ICC profile) can be written in the same pass. `bit_depth` is 8 or 16
/// (derivatives always force 16 for TIFF / 8 for JPEG -- see
/// `write_derivative`). The ICC profile is embedded only when the render is
/// actually Adobe RGB-encoded (C41), and the DPI resolution tags only when
/// the derivative is at the capture's physical scale (the full-resolution
/// positive), never the downsampled preview.
fn write_tiff_with_metadata<W: std::io::Write + std::io::Seek>(
    writer: W,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    bit_depth: u32,
    metadata: &DerivativeMetadata,
) -> Result<(), domain::EngineError> {
    use tiff::encoder::colortype::RGB16;
    use tiff::encoder::colortype::RGB8;
    use tiff::encoder::TiffEncoder;

    if bit_depth == 8 {
        let samples = to_u8_samples(raw);
        let mut encoder = TiffEncoder::new(writer).map_err(metadata_encode_error)?;
        let mut image = encoder
            .new_image::<RGB8>(width, height)
            .map_err(metadata_encode_error)?;
        emit_tiff_metadata(image.encoder(), metadata)?;
        image.write_data(&samples).map_err(metadata_encode_error)
    } else {
        let samples = to_u16_samples(raw);
        let mut encoder = TiffEncoder::new(writer).map_err(metadata_encode_error)?;
        let mut image = encoder
            .new_image::<RGB16>(width, height)
            .map_err(metadata_encode_error)?;
        emit_tiff_metadata(image.encoder(), metadata)?;
        image.write_data(&samples).map_err(metadata_encode_error)
    }
}

/// TIFF/EP requires the ICC profile tag (34675) to use field type UNDEFINED,
/// not BYTE. A bare `&[u8]` implements `TiffValue` as BYTE, which is readable
/// by tolerant software but non-conforming and rejected by strict validators.
struct IccProfileValue<'a>(&'a [u8]);

impl tiff::encoder::TiffValue for IccProfileValue<'_> {
    const BYTE_LEN: u8 = 1;
    const FIELD_TYPE: tiff::tags::Type = tiff::tags::Type::UNDEFINED;

    fn count(&self) -> usize {
        self.0.len()
    }

    fn data(&self) -> std::borrow::Cow<'_, [u8]> {
        std::borrow::Cow::Borrowed(self.0)
    }
}

/// Writes the metadata selected by `metadata` onto a TIFF directory encoder
/// before its pixel data:
///
/// * the ScanStudio RGB compatible ICC profile, iff `metadata.attach_icc` (C41);
/// * `XResolution`/`YResolution`/`ResolutionUnit` = pixels/inch at
///   `metadata.resolution_dpi`, iff it is `Some` (the full-resolution
///   positive only).
///
/// Every metadata write must succeed or the derivative is rejected
/// (fail-closed) rather than silently unlabeled. A zero DPI is untruthful
/// and refused rather than emitting an undefined resolution unit.
fn emit_tiff_metadata<W: std::io::Write + std::io::Seek>(
    ifd: &mut tiff::encoder::DirectoryEncoder<'_, W, tiff::encoder::TiffKindStandard>,
    metadata: &DerivativeMetadata,
) -> Result<(), domain::EngineError> {
    use tiff::encoder::Rational;
    use tiff::tags::ResolutionUnit;
    use tiff::tags::Tag;

    if metadata.attach_icc {
        let profile = crate::icc::scanstudio_rgb_icc_profile()?;
        ifd.write_tag(Tag::IccProfile, IccProfileValue(&profile[..]))
            .map_err(metadata_encode_error)?;
    }
    if let Some(resolution_dpi) = metadata.resolution_dpi {
        if resolution_dpi == 0 {
            return Err(domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("cannot embed a truthful DPI metadata tag for a {resolution_dpi} DPI capture recipe"),
            ));
        }
        ifd.write_tag(Tag::XResolution, Rational { n: resolution_dpi, d: 1 })
            .map_err(metadata_encode_error)?;
        ifd.write_tag(Tag::YResolution, Rational { n: resolution_dpi, d: 1 })
            .map_err(metadata_encode_error)?;
        ifd.write_tag(Tag::ResolutionUnit, ResolutionUnit::Inch)
            .map_err(metadata_encode_error)?;
    }
    Ok(())
}

fn metadata_encode_error(error: tiff::TiffError) -> domain::EngineError {
    domain::EngineError::new(
        protocol::ErrorCode::Internal,
        format!("failed to encode derivative TIFF metadata: {error}"),
    )
}

/// Encodes a JPEG derivative with the `image`-crate JPEG encoder, embedding
/// the ScanStudio RGB compatible ICC profile when the render is Adobe RGB-encoded
/// (C41). JPEG carries no resolution tags here, so DPI is never written for
/// JPEG even for the full-resolution positive. The default quality equals the
/// historical `DynamicImage::write_to(ImageFormat::Jpeg)` path, preserving
/// the 8-bit sample encoding.
fn write_jpeg_with_metadata<W: std::io::Write>(
    writer: W,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    metadata: &DerivativeMetadata,
) -> Result<(), domain::EngineError> {
    use image::codecs::jpeg::JpegEncoder;
    use image::{ExtendedColorType, ImageEncoder};

    let samples = to_u8_samples(raw);
    let mut encoder = JpegEncoder::new(writer);
    if metadata.attach_icc {
        let profile = crate::icc::scanstudio_rgb_icc_profile()?;
        encoder.set_icc_profile(profile).map_err(|error| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!("failed to attach derivative JPEG ICC profile: {error}"),
            )
        })?;
    }
    encoder
        .encode(&samples, width, height, ExtendedColorType::Rgb8)
        .map_err(jpeg_encode_error)
}

fn jpeg_encode_error(error: image::ImageError) -> domain::EngineError {
    domain::EngineError::new(
        protocol::ErrorCode::Internal,
        format!("failed to encode derivative JPEG: {error}"),
    )
}

/// Publishes a completely encoded and synced private sibling at the final
/// leaf. Auto-sequenced outputs use an atomic same-directory hard link, so
/// publishing is create-only even if another process creates the leaf after
/// preflight. Custom outputs retain their established atomic-replace policy.
/// Neither mode follows or truncates a symlink/hardlink leaf during encoding.
/// TIFF derivatives always encode at 16-bit
/// (derivatives carry no bit-depth choice of their own the way the archive's
/// `CaptureRecipe.bit_depth` does -- 16-bit is the max fidelity a `[0,1]`
/// float sample can be quantized to); JPEG has no 16-bit mode, so it always
/// encodes at 8-bit regardless of the capture's own bit depth.
///
/// `metadata` carries the color-profile contract (ICC only for C41) and the
/// physical DPI scale (only the full-resolution positive), so the right
/// metadata is attached per derivative: TIFF carries ICC and optionally DPI;
/// JPEG carries ICC only (it has no resolution tags in this encoder).
fn write_derivative(
    path: &std::path::Path,
    raw: &[[f64; 3]],
    width: u32,
    height: u32,
    format: domain::OutputFileFormat,
    create_only: bool,
    metadata: &DerivativeMetadata,
) -> Result<(), domain::EngineError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|err| {
            domain::EngineError::new(
                protocol::ErrorCode::Internal,
                format!(
                    "failed to create derivative directory {}: {err}",
                    parent.display()
                ),
            )
        })?;
    }

    // TIFF derivatives are written by the direct `tiff`-crate encoder (ICC +
    // optional DPI); JPEG is written by the `image`-crate JPEG encoder with
    // an optional ICC profile. Both preserve the quantized sample values.

    static TEMP_COUNTER: std::sync::atomic::AtomicU64 =
        std::sync::atomic::AtomicU64::new(0);
    let parent = path.parent().ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::InvalidParams,
            format!("derivative path has no parent: {}", path.display()),
        )
    })?;
    let final_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            domain::EngineError::new(
                protocol::ErrorCode::InvalidParams,
                format!("derivative path has no file name: {}", path.display()),
            )
        })?;
    let mut reserved = None;
    for _ in 0..128 {
        let counter = TEMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let candidate = parent.join(format!(
            ".{final_name}.scanstudio-{}-{counter}.tmp",
            std::process::id()
        ));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => {
                reserved = Some((candidate, file));
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!(
                        "failed to reserve derivative sibling beside {}: {error}",
                        path.display()
                    ),
                ))
            }
        }
    }
    let (temporary_path, file) = reserved.ok_or_else(|| {
        domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to reserve a unique derivative sibling beside {}",
                path.display()
            ),
        )
    })?;
    let mut writer = std::io::BufWriter::new(file);

    // TIFF derivatives carry ICC and optional resolution tags. JPEG carries
    // the same ICC contract when applicable, but no physical-resolution tag.
    let write_result = match format {
        domain::OutputFileFormat::Jpeg => {
            write_jpeg_with_metadata(&mut writer, raw, width, height, metadata)
        }
        domain::OutputFileFormat::Tiff => {
            write_tiff_with_metadata(&mut writer, raw, width, height, 16, metadata)
        }
    }
    .and_then(|_| {
            writer.flush().map_err(|err| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("failed to flush derivative at {}: {err}", path.display()),
                )
            })
        })
        .and_then(|_| {
            writer.get_ref().sync_all().map_err(|err| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("failed to sync derivative at {}: {err}", path.display()),
                )
            })
        });
    drop(writer);
    if let Err(error) = write_result {
        let _ = std::fs::remove_file(&temporary_path);
        return Err(error);
    }
    if create_only {
        match std::fs::hard_link(&temporary_path, path) {
            Ok(()) => {
                std::fs::remove_file(&temporary_path).map_err(|error| {
                    domain::EngineError::new(
                        protocol::ErrorCode::Internal,
                        format!(
                            "created auto-sequenced derivative at {} but failed to remove its private sibling {}: {error}",
                            path.display(),
                            temporary_path.display()
                        ),
                    )
                })?;
            }
            Err(error) => {
                let _ = std::fs::remove_file(&temporary_path);
                let code = if error.kind() == std::io::ErrorKind::AlreadyExists {
                    protocol::ErrorCode::ArchiveCollision
                } else {
                    protocol::ErrorCode::Internal
                };
                return Err(domain::EngineError::new(
                    code,
                    format!(
                        "failed to publish create-only auto-sequenced derivative at {}: {error}",
                        path.display()
                    ),
                ));
            }
        }
    } else if let Err(error) = std::fs::rename(&temporary_path, path) {
        let _ = std::fs::remove_file(&temporary_path);
        return Err(domain::EngineError::new(
            protocol::ErrorCode::Internal,
            format!(
                "failed to atomically replace derivative at {}: {error}",
                path.display()
            ),
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------

/// Where a completed frame's files actually landed on this call.
#[derive(Debug, Clone, PartialEq)]
pub struct WrittenPaths {
    /// Retained user-visible master only. A real backend's private working
    /// capture is intentionally never represented here when master
    /// retention is disabled.
    pub archive_path: Option<std::path::PathBuf>,
    pub positive_path: Option<std::path::PathBuf>,
    pub preview_path: Option<std::path::PathBuf>,
    pub raw_negative_path: Option<std::path::PathBuf>,
    pub raw_negative_ir_path: Option<std::path::PathBuf>,
    /// See `render_positive`'s own doc comment. `None` whenever no
    /// positive/preview was rendered this call, or the rendered frame
    /// wasn't C41.
    pub nikonlook: Option<domain::NikonlookProvenance>,
    /// Scan-time non-destructive auto-crop decision. `None` when the recipe
    /// did not request auto-crop or no derivative rendered.
    pub auto_crop: Option<domain::AutoCropOutcome>,
    pub derivative_transform: domain::DerivativeTransform,
}

/// Renders one frame's deterministic simulated pixel data and writes the
/// optional retained archive (create-only) plus the positive/preview derivatives
/// (each only if their recipe is `enabled`, overwrite-ok). Refuses to write
/// a derivative whose resolved path aliases the archive's (T-03-04).
///
/// A retained archive receives the full, uncropped capture. An approved
/// `alignment` is applied only to the derived outputs, using
/// `detected_boundary` as the base frame edge. This keeps a retained archive
/// master byte-identical regardless of any crop setting.
pub fn render_and_write_frame(
    device_id: &str,
    frame_index: u32,
    film_process: domain::FilmProcess,
    width: u32,
    height: u32,
    bit_depth: u32,
    recipes: &domain::OutputRecipe,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
) -> Result<WrittenPaths, domain::EngineError> {
    let processing = domain::ProcessingRecipe { film_process, ..domain::ProcessingRecipe::default() };
    render_and_write_frame_with_processing(
        device_id, frame_index, &processing, width, height, bit_depth,
        domain::CaptureRecipe::default().resolution_dpi, true, recipes,
        detected_boundary, alignment,
    )
}

/// Processing-aware simulated derivative path. `software_dust_removal_bw`
/// is opt-in and affects derivative buffers only.
pub fn render_and_write_frame_with_processing(
    device_id: &str,
    frame_index: u32,
    processing: &domain::ProcessingRecipe,
    width: u32,
    height: u32,
    bit_depth: u32,
    resolution_dpi: u32,
    raw_ir_available: bool,
    recipes: &domain::OutputRecipe,
    detected_boundary: Option<(u32, u32)>,
    alignment: Option<&domain::FrameAlignment>,
) -> Result<WrittenPaths, domain::EngineError> {
    let derivative_transform = alignment
        .map(|value| value.derivative_transform)
        .unwrap_or_default();
    validate_derivative_transform(derivative_transform)?;
    validate_output_recipe_paths(recipes)?;
    let (
        archive_path,
        preflight_positive_path,
        preflight_preview_path,
        preflight_raw_path,
        preflight_raw_ir_path,
    ) = validate_frame_output_paths_with_raw_ir(recipes, frame_index, raw_ir_available)?;
    let raw = generate_sim_frame(device_id, frame_index, width, height);
    if let Some(archive_path) = archive_path.as_ref() {
        write_tiff_create_only(archive_path, &raw, width, height, bit_depth)?;
    }
    let (raw_negative_path, raw_negative_ir_path) = if let Some(path) = preflight_raw_path {
        let written_ir_path = write_raw_export_create_only(
            path.as_path(),
            &raw,
            width,
            height,
            resolution_dpi,
            &recipes.raw_export,
            raw_ir_available,
        )?;
        debug_assert_eq!(written_ir_path, preflight_raw_ir_path);
        (Some(path), written_ir_path)
    } else {
        (None, None)
    };

    let mut positive_path: Option<std::path::PathBuf> = None;
    let mut preview_path: Option<std::path::PathBuf> = None;
    let mut nikonlook_provenance: Option<domain::NikonlookProvenance> = None;
    let mut auto_crop_outcome: Option<domain::AutoCropOutcome> = None;

    if recipes.positive.enabled || recipes.preview.enabled {
        if recipes.auto_crop {
            auto_crop_outcome = Some(if alignment.is_some_and(|value| value.approved) {
                auto_crop_deferred_to_alignment(width, height)
            } else {
                detect_auto_crop(&raw, width, height)
            });
        }
        // Computed once -- both derivatives share it rather than each
        // calling render_positive (and thus reloading/re-estimating
        // nikonlook) independently. The simulator has no hardware exposure
        // to report, so nikonlook v2 always uses its blind fallback here.
        let (positive_raw_full, provenance) =
            render_positive(processing.film_process, &raw, width as usize, None)?;
        nikonlook_provenance = provenance;
        let positive_raw_full = if processing.film_process == domain::FilmProcess::BwNegative
            && processing.software_dust_removal_bw
        {
            software_dust_remove_bw_owned(positive_raw_full, width, height)
        } else {
            positive_raw_full
        };
        let (mut positive_raw, mut positive_width, mut positive_height) = match &auto_crop_outcome {
            Some(outcome) if outcome.applied => {
                let roi = outcome.roi.as_ref().expect("applied auto-crop outcome carries its ROI");
                crop_to_roi(&positive_raw_full, width, roi)
            }
            _ => apply_alignment_crop(&positive_raw_full, width, height, detected_boundary, alignment),
        };
        (positive_width, positive_height) = apply_derivative_transform_in_place(
            &mut positive_raw,
            positive_width,
            positive_height,
            derivative_transform,
        )?;

        let positive_metadata =
            DerivativeMetadata::positive(processing.film_process, resolution_dpi);
        let preview_metadata = DerivativeMetadata::preview(processing.film_process);

        if recipes.positive.enabled {
            let path = preflight_positive_path.clone().expect("enabled positive has preflight path");
            write_derivative(
                &path,
                &positive_raw,
                positive_width,
                positive_height,
                recipes.positive.file_format,
                is_reserved_sequence_template(&recipes.positive.filename_template),
                &positive_metadata,
            )?;
            positive_path = Some(path);
        }

        if recipes.preview.enabled {
            let (preview_width, preview_height) =
                downsample_dimensions(positive_width, positive_height, recipes.preview.max_long_edge_px);
            let preview_raw =
                downsample_nearest(&positive_raw, positive_width, positive_height, preview_width, preview_height);
            let path = preflight_preview_path.clone().expect("enabled preview has preflight path");
            write_derivative(
                &path,
                &preview_raw,
                preview_width,
                preview_height,
                recipes.preview.file_format,
                is_reserved_sequence_template(&recipes.preview.filename_template),
                &preview_metadata,
            )?;
            preview_path = Some(path);
        }
    }

    Ok(WrittenPaths {
        archive_path,
        positive_path,
        preview_path,
        raw_negative_path,
        raw_negative_ir_path,
        nikonlook: nikonlook_provenance,
        auto_crop: auto_crop_outcome,
        derivative_transform,
    })
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn software_bw_dust_removal_corrects_isolated_bright_and_dark_specks_but_preserves_edges() {
        let mut pixels = vec![[0.5; 3]; 121];
        pixels[24] = [1.0; 3];
        pixels[96] = [0.0; 3];
        // A high-contrast edge has unlike neighbours and must fail closed.
        pixels[110] = [1.0; 3];
        let cleaned = software_dust_remove_bw(&pixels, 11, 11);
        assert_eq!(cleaned[24], [0.5; 3]);
        assert_eq!(cleaned[96], [0.5; 3]);
        assert_eq!(cleaned[110], [1.0; 3]);
        assert_eq!(cleaned, software_dust_remove_bw(&pixels, 11, 11));
    }

    #[test]
    fn software_bw_dust_removal_inpaints_compact_two_by_two_bright_and_dark_blobs() {
        let mut bright = vec![[0.5; 3]; 225];
        for index in [112, 113, 127, 128] { bright[index] = [1.0; 3]; }
        let cleaned_bright = software_dust_remove_bw(&bright, 15, 15);
        for index in [112, 113, 127, 128] { assert_eq!(cleaned_bright[index], [0.5; 3]); }

        let mut dark = vec![[0.5; 3]; 225];
        for index in [112, 113, 127, 128] { dark[index] = [0.0; 3]; }
        let cleaned_dark = software_dust_remove_bw(&dark, 15, 15);
        for index in [112, 113, 127, 128] { assert_eq!(cleaned_dark[index], [0.5; 3]); }
    }

    #[test]
    fn software_bw_dust_removal_inpaints_three_by_three_without_touching_interior_edge_detail() {
        let mut dust = vec![[0.5; 3]; 225];
        for y in 6..=8 { for x in 6..=8 { dust[y * 15 + x] = [1.0; 3]; } }
        let cleaned = software_dust_remove_bw(&dust, 15, 15);
        for y in 6..=8 { for x in 6..=8 { assert_eq!(cleaned[y * 15 + x], [0.5; 3]); } }

        let mut edge = vec![[0.1; 3]; 225];
        for y in 2..13 { for x in 8..13 { edge[y * 15 + x] = [0.9; 3]; } }
        edge[7 * 15 + 7] = [0.9; 3]; // one-pixel legitimate line/detail beside the step
        let preserved = software_dust_remove_bw(&edge, 15, 15);
        assert_eq!(preserved, edge, "interior edge/detail must fail closed");
    }

    #[test]
    fn software_bw_dust_removal_does_not_absorb_an_adjacent_opposite_polarity_detail() {
        let mut pixels = vec![[0.5; 3]; 225];
        // Only the lower-right bright pixel is a clean seed: the other
        // three bright pixels contaminate the dark detail's ring, making
        // that legitimate dark pixel non-candidate. Older absolute-residual
        // expansion nevertheless swallowed it from the bright seed.
        for (x, y) in [(6, 6), (7, 6), (6, 7), (7, 7)] {
            pixels[y * 15 + x] = [1.0; 3];
        }
        let dark_detail = 7 * 15 + 8;
        pixels[dark_detail] = [0.0; 3];

        let cleaned = software_dust_remove_bw(&pixels, 15, 15);
        assert_eq!(cleaned[7 * 15 + 7], [0.5; 3], "the bright dust seed is repaired");
        assert_eq!(cleaned[dark_detail], [0.0; 3], "opposite-polarity detail is preserved");
    }

    fn unique_test_dir() -> std::path::PathBuf {
        static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "scanstudio-render-test-{}-{n}",
            crate::manifest::generate_project_id(),
        ))
    }

    fn write_small_rgb16_tiff(path: &std::path::Path, width: u32, height: u32) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("create fixture directory");
        }
        let pixels = (0..width * height)
            .map(|index| {
                [
                    ((index * 701) % 65536) as u16,
                    ((index * 1301) % 65536) as u16,
                    ((index * 2903) % 65536) as u16,
                ]
            })
            .collect();
        image_io::write_rgb16(
            path,
            &image_io::Rgb16Image {
                width,
                height,
                pixels,
            },
        )
        .expect("write RGB16 TIFF fixture");
    }

    fn classic_tiff_field_type(bytes: &[u8], wanted_tag: u16) -> Option<u16> {
        let little_endian = match bytes.get(0..2)? {
            b"II" => true,
            b"MM" => false,
            _ => return None,
        };
        let read_u16 = |slice: &[u8]| -> Option<u16> {
            let value: [u8; 2] = slice.try_into().ok()?;
            Some(if little_endian {
                u16::from_le_bytes(value)
            } else {
                u16::from_be_bytes(value)
            })
        };
        let read_u32 = |slice: &[u8]| -> Option<u32> {
            let value: [u8; 4] = slice.try_into().ok()?;
            Some(if little_endian {
                u32::from_le_bytes(value)
            } else {
                u32::from_be_bytes(value)
            })
        };
        if read_u16(bytes.get(2..4)?)? != 42 {
            return None;
        }
        let ifd_offset = read_u32(bytes.get(4..8)?)? as usize;
        let entry_count = read_u16(bytes.get(ifd_offset..ifd_offset.checked_add(2)?)?)? as usize;
        for index in 0..entry_count {
            let start = ifd_offset.checked_add(2)?.checked_add(index.checked_mul(12)?)?;
            let entry = bytes.get(start..start.checked_add(12)?)?;
            if read_u16(&entry[0..2])? == wanted_tag {
                return read_u16(&entry[2..4]);
            }
        }
        None
    }

    fn classic_tiff_entry(
        bytes: &[u8],
        ifd_offset: usize,
        wanted_tag: u16,
    ) -> Option<(u16, u32, [u8; 4])> {
        let entry_count = u16::from_le_bytes(bytes.get(ifd_offset..ifd_offset + 2)?.try_into().ok()?)
            as usize;
        for index in 0..entry_count {
            let start = ifd_offset + 2 + index * 12;
            if u16::from_le_bytes(bytes.get(start..start + 2)?.try_into().ok()?) == wanted_tag {
                return Some((
                    u16::from_le_bytes(bytes.get(start + 2..start + 4)?.try_into().ok()?),
                    u32::from_le_bytes(bytes.get(start + 4..start + 8)?.try_into().ok()?),
                    bytes.get(start + 8..start + 12)?.try_into().ok()?,
                ));
            }
        }
        None
    }

    fn classic_tiff_value(bytes: &[u8], ifd_offset: usize, tag: u16) -> Option<Vec<u8>> {
        let (field_type, count, inline) = classic_tiff_entry(bytes, ifd_offset, tag)?;
        let unit = match field_type {
            1 | 2 => 1,
            3 => 2,
            4 => 4,
            5 | 10 => 8,
            _ => return None,
        };
        let len = usize::try_from(count).ok()?.checked_mul(unit)?;
        if len <= 4 {
            Some(inline[..len].to_vec())
        } else {
            let offset = u32::from_le_bytes(inline) as usize;
            Some(bytes.get(offset..offset.checked_add(len)?)?.to_vec())
        }
    }

    fn classic_tiff_short(bytes: &[u8], ifd_offset: usize, tag: u16) -> Option<u16> {
        Some(u16::from_le_bytes(
            classic_tiff_value(bytes, ifd_offset, tag)?.get(0..2)?.try_into().ok()?,
        ))
    }

    fn classic_tiff_long(bytes: &[u8], ifd_offset: usize, tag: u16) -> Option<u32> {
        Some(u32::from_le_bytes(
            classic_tiff_value(bytes, ifd_offset, tag)?.get(0..4)?.try_into().ok()?,
        ))
    }

    fn u16_samples(bytes: &[u8]) -> Vec<u16> {
        bytes
            .chunks_exact(2)
            .map(|sample| u16::from_le_bytes(sample.try_into().unwrap()))
            .collect()
    }

    #[test]
    fn simulated_linear_dng_has_rgb_linear_raw_main_ifd_and_exact_ir_sub_ifd() {
        let raw = vec![[0.0, 0.5, 1.0], [0.25, 0.75, 0.125]];
        let recipe = domain::RawExportRecipe::default();
        let bytes = encoded_simulated_raw(&raw, 2, 1, 4_000, &recipe, true).unwrap();
        let main_ifd = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;

        assert_eq!(classic_tiff_short(&bytes, main_ifd, 262), Some(34_892));
        assert_eq!(classic_tiff_short(&bytes, main_ifd, 277), Some(3));
        assert!(classic_tiff_entry(&bytes, main_ifd, 338).is_none());
        assert_eq!(classic_tiff_value(&bytes, main_ifd, 50_706).unwrap(), [1, 4, 0, 0]);
        assert_eq!(classic_tiff_value(&bytes, main_ifd, 282).unwrap(), 4_000_u32.to_le_bytes().into_iter().chain(1_u32.to_le_bytes()).collect::<Vec<_>>());
        assert_eq!(classic_tiff_short(&bytes, main_ifd, 296), Some(2));
        let infrared_ifd = classic_tiff_long(&bytes, main_ifd, 330).unwrap() as usize;
        assert_eq!(classic_tiff_short(&bytes, infrared_ifd, 262), Some(1));
        assert_eq!(classic_tiff_short(&bytes, infrared_ifd, 277), Some(1));
        assert_eq!(
            classic_tiff_value(&bytes, infrared_ifd, RAW_IR_TAG).unwrap(),
            RAW_IR_MARKER
        );

        let rgb_offset = classic_tiff_long(&bytes, main_ifd, 273).unwrap() as usize;
        let rgb_len = classic_tiff_long(&bytes, main_ifd, 279).unwrap() as usize;
        assert_eq!(
            u16_samples(&bytes[rgb_offset..rgb_offset + rgb_len]),
            [0, 32_768, 65_535, 16_384, 49_151, 8_192]
        );
        let ir_offset = classic_tiff_long(&bytes, infrared_ifd, 273).unwrap() as usize;
        let ir_len = classic_tiff_long(&bytes, infrared_ifd, 279).unwrap() as usize;
        assert_eq!(
            u16_samples(&bytes[ir_offset..ir_offset + ir_len]),
            [32_768, 24_576]
        );
    }

    #[test]
    fn simulated_linear_tiff_fourth_channel_and_omitted_modes_are_unambiguous() {
        let raw = vec![[0.0, 0.5, 1.0], [0.25, 0.75, 0.125]];
        for (infrared, expected_spp, expected_samples) in [
            (
                domain::RawTiffInfrared::FourthChannel,
                4,
                vec![0, 32_768, 65_535, 32_768, 16_384, 49_151, 8_192, 24_576],
            ),
            (
                domain::RawTiffInfrared::Omitted,
                3,
                vec![0, 32_768, 65_535, 16_384, 49_151, 8_192],
            ),
        ] {
            let recipe = domain::RawExportRecipe {
                enabled: true,
                file_format: domain::RawExportFormat::LinearTiff,
                tiff_infrared: infrared,
                ..domain::RawExportRecipe::default()
            };
            let bytes = encoded_simulated_raw(&raw, 2, 1, 4_000, &recipe, true).unwrap();
            let ifd = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
            assert_eq!(classic_tiff_short(&bytes, ifd, 262), Some(2));
            assert_eq!(classic_tiff_short(&bytes, ifd, 277), Some(expected_spp));
            assert_eq!(classic_tiff_entry(&bytes, ifd, 338).is_some(), expected_spp == 4);
            assert_eq!(classic_tiff_entry(&bytes, ifd, RAW_IR_TAG).is_some(), expected_spp == 4);
            let offset = classic_tiff_long(&bytes, ifd, 273).unwrap() as usize;
            let len = classic_tiff_long(&bytes, ifd, 279).unwrap() as usize;
            assert_eq!(u16_samples(&bytes[offset..offset + len]), expected_samples);
        }
    }

    #[test]
    fn simulated_sidecar_modes_keep_rgb_main_and_round_trip_grayscale_ir_tags() {
        let raw = vec![[0.0, 0.5, 1.0], [0.25, 0.75, 0.125]];
        for format in [
            domain::RawExportFormat::LinearDng,
            domain::RawExportFormat::LinearTiff,
        ] {
            let recipe = domain::RawExportRecipe {
                enabled: true,
                file_format: format,
                tiff_infrared: domain::RawTiffInfrared::Sidecar,
                ..domain::RawExportRecipe::default()
            };
            let main = encoded_simulated_raw(&raw, 2, 1, 4_000, &recipe, true).unwrap();
            let main_ifd = u32::from_le_bytes(main[4..8].try_into().unwrap()) as usize;
            assert_eq!(classic_tiff_short(&main, main_ifd, 277), Some(3));
            assert!(classic_tiff_entry(&main, main_ifd, 330).is_none());
            assert!(classic_tiff_entry(&main, main_ifd, RAW_IR_TAG).is_none());
            let main_offset = classic_tiff_long(&main, main_ifd, 273).unwrap() as usize;
            let main_len = classic_tiff_long(&main, main_ifd, 279).unwrap() as usize;
            assert_eq!(
                u16_samples(&main[main_offset..main_offset + main_len]),
                [0, 32_768, 65_535, 16_384, 49_151, 8_192]
            );

            let sidecar = encoded_simulated_raw_ir(&raw, 2, 1, 4_000).unwrap();
            let sidecar_ifd =
                u32::from_le_bytes(sidecar[4..8].try_into().unwrap()) as usize;
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 258), Some(16));
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 262), Some(1));
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 277), Some(1));
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 274), Some(1));
            assert_eq!(classic_tiff_short(&sidecar, sidecar_ifd, 296), Some(2));
            assert_eq!(
                classic_tiff_value(&sidecar, sidecar_ifd, 282).unwrap(),
                4_000_u32
                    .to_le_bytes()
                    .into_iter()
                    .chain(1_u32.to_le_bytes())
                    .collect::<Vec<_>>()
            );
            assert_eq!(
                classic_tiff_value(&sidecar, sidecar_ifd, RAW_IR_TAG).unwrap(),
                RAW_IR_MARKER
            );
            let ir_offset =
                classic_tiff_long(&sidecar, sidecar_ifd, 273).unwrap() as usize;
            let ir_len = classic_tiff_long(&sidecar, sidecar_ifd, 279).unwrap() as usize;
            assert_eq!(
                u16_samples(&sidecar[ir_offset..ir_offset + ir_len]),
                [32_768, 24_576]
            );
        }
    }

    #[test]
    fn simulated_sidecar_without_ir_matches_single_rgb_sibling() {
        let raw = vec![[0.0, 0.5, 1.0], [0.25, 0.75, 0.125]];
        for format in [
            domain::RawExportFormat::LinearDng,
            domain::RawExportFormat::LinearTiff,
        ] {
            let recipe = domain::RawExportRecipe {
                file_format: format,
                tiff_infrared: domain::RawTiffInfrared::Sidecar,
                ..domain::RawExportRecipe::default()
            };
            let main = encoded_simulated_raw(&raw, 2, 1, 4_000, &recipe, false).unwrap();
            let ifd = u32::from_le_bytes(main[4..8].try_into().unwrap()) as usize;
            assert_eq!(classic_tiff_short(&main, ifd, 277), Some(3));
            assert!(classic_tiff_entry(&main, ifd, 330).is_none());
            assert!(classic_tiff_entry(&main, ifd, RAW_IR_TAG).is_none());
        }
    }

    #[test]
    fn simulated_pair_failure_after_main_publication_removes_both_finals() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let main_temporary = dir.join("main.partial");
        let sidecar_temporary = dir.join("sidecar.partial");
        let main = dir.join("negative.dng");
        let sidecar = dir.join("negative-ir.tif");
        std::fs::write(&main_temporary, b"complete main").unwrap();
        std::fs::write(&sidecar_temporary, b"complete sidecar").unwrap();
        let publish = |source: &std::path::Path, target: &std::path::Path| {
            std::fs::hard_link(source, target).map_err(|error| {
                domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    format!("test publish failure: {error}"),
                )
            })
        };

        let error = publish_raw_pair_with_hook(
            &main_temporary,
            &main,
            &sidecar_temporary,
            &sidecar,
            publish,
            || {
                assert!(main.exists(), "main publication must precede injected failure");
                Err(domain::EngineError::new(
                    protocol::ErrorCode::Internal,
                    "simulated sidecar publication failure",
                ))
            },
        )
        .unwrap_err();

        assert!(error.message.contains("simulated sidecar publication failure"));
        assert!(!main.exists());
        assert!(!sidecar.exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn frame_dimensions_matches_scan_size_estimator_constants() {
        assert_eq!(
            frame_dimensions(domain::MediaCarrier::Roll36, 4000),
            (3946, 5959)
        );
        assert_eq!(
            frame_dimensions(domain::MediaCarrier::Mounted, 4000),
            (3946, 5782)
        );
        assert_eq!(
            frame_dimensions(domain::MediaCarrier::Roll36, 2000),
            (1973, 2980)
        );
    }

    #[test]
    fn generate_sim_frame_is_deterministic_and_bounded() {
        let a = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        let b = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        assert_eq!(a, b, "same arguments must reproduce byte-identical pixels");
        assert_eq!(a.len(), 8 * 6, "one triple per pixel, row-major");
        for px in &a {
            for &v in px {
                assert!((0.0..=1.0).contains(&v), "channel value {v} out of bounds");
            }
        }
    }

    #[test]
    fn resolve_filename_zero_pads_to_the_hash_run_length() {
        assert_eq!(resolve_filename("Roll_001_####", 5), "Roll_001_0005");
    }

    #[test]
    fn resolve_filename_uses_a_four_digit_suffix_when_no_hash_present() {
        assert_eq!(resolve_filename("Roll_001", 5), "Roll_001_0005");
        assert_eq!(resolve_filename("Roll.v1.tif", 5), "Roll.v1_0005.tif");
        assert_eq!(resolve_filename("Roll.v1.TiFf", 5), "Roll.v1_0005.TiFf");
    }

    #[test]
    fn single_hash_reserves_the_next_available_number_across_enabled_outputs() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("ScanStudio1.jpg"), b"existing").unwrap();
        std::fs::write(dir.join("ScanStudio2.tif"), b"existing").unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "ScanStudio#".into();
        recipes.raw_export.enabled = true;
        recipes.raw_export.destination = dir.display().to_string();
        recipes.raw_export.filename_template = "ScanStudio#".into();
        recipes.positive.destination = dir.display().to_string();
        recipes.positive.filename_template = "ScanStudio#".into();
        recipes.preview.destination = dir.display().to_string();
        recipes.preview.filename_template = "ScanStudio#".into();
        let mut overrides = std::collections::HashMap::new();

        reserve_auto_sequence_filenames(
            &[1],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &recipes,
            &mut overrides,
        )
        .expect("the next unused sequence number should be reserved");

        let output = &overrides.get(&1).unwrap().output.as_ref().unwrap();
        assert_eq!(
            resolve_archive_output_path(output, 1),
            dir.join("ScanStudio3.tif")
        );
        assert_eq!(
            resolve_output_path(
                &output.positive.destination,
                &output.positive.filename_template,
                1,
                output.positive.file_format,
            ),
            dir.join("ScanStudio3.tif")
        );
        assert_eq!(
            resolve_output_path(
                &output.preview.destination,
                &output.preview.filename_template,
                1,
                output.preview.file_format,
            ),
            dir.join("ScanStudio3.jpg")
        );
        assert_eq!(
            resolve_raw_export_output_path(output, 1),
            dir.join("ScanStudio3.dng")
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn receipt_recipe_restores_job_local_sequence_markers_to_the_user_template() {
        let mut output = domain::OutputRecipe::default();
        output.archive.filename_template = "Master$ScanStudioSequence(12)".into();
        output.raw_export.filename_template = "Raw$ScanStudioSequence(12).dng".into();
        output.positive.filename_template = "Positive$ScanStudioSequence(12).tif".into();
        output.preview.filename_template = "Preview$ScanStudioSequence(12).jpg".into();

        let receipt_output = receipt_output_recipe(&output);

        assert_eq!(receipt_output.archive.filename_template, "Master#");
        assert_eq!(receipt_output.raw_export.filename_template, "Raw#.dng");
        assert_eq!(receipt_output.positive.filename_template, "Positive#.tif");
        assert_eq!(receipt_output.preview.filename_template, "Preview#.jpg");
        assert!(
            !serde_json::to_string(&receipt_output)
                .expect("output recipe must serialize")
                .contains("ScanStudioSequence"),
            "receipt recipes must never persist the private sequence marker"
        );
    }

    #[test]
    fn user_output_recipes_reject_the_engine_reserved_sequence_marker() {
        let mut output = domain::OutputRecipe::default();
        output.archive.filename_template = "ScanStudio$ScanStudioSequence(7)".into();

        let error = validate_user_output_recipe_paths(&output).unwrap_err();

        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(error.message.contains("reserved"));

        let mut metadata_injected = domain::OutputRecipe::default();
        metadata_injected.archive.filename_template = "$FilmStock-#".into();
        materialize_output_filename_tokens(
            &mut metadata_injected,
            &domain::MetadataSet {
                film_stock: Some("$ScanStudioSequence(88)".into()),
                ..Default::default()
            },
        );
        assert_eq!(
            validate_user_output_recipe_paths(&metadata_injected).unwrap_err().code,
            protocol::ErrorCode::InvalidParams,
            "metadata expansion cannot smuggle an engine-only marker"
        );
    }

    #[test]
    fn single_hash_allocates_consecutive_numbers_for_arbitrary_frame_slots_and_sidecars() {
        let dir = unique_test_dir();
        let archive_dir = dir.join("archive");
        let positive_dir = dir.join("positive");
        let preview_dir = dir.join("preview");
        for directory in [&archive_dir, &positive_dir, &preview_dir] {
            std::fs::create_dir_all(directory).unwrap();
        }
        std::fs::write(positive_dir.join("ScanStudio1.jpeg"), b"existing").unwrap();
        std::fs::write(archive_dir.join("ScanStudio2.tiff"), b"existing").unwrap();
        std::fs::write(archive_dir.join("ScanStudio3_IR.tif"), b"existing").unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = archive_dir.display().to_string();
        recipes.archive.filename_template = "ScanStudio#".into();
        recipes.positive.destination = positive_dir.display().to_string();
        recipes.positive.filename_template = "ScanStudio#".into();
        recipes.preview.destination = preview_dir.display().to_string();
        recipes.preview.filename_template = "ScanStudio#".into();
        let mut overrides = std::collections::HashMap::new();
        let mut capture = domain::CaptureRecipe::default();
        capture.channels = domain::Channels::Rgbi;

        reserve_auto_sequence_filenames(
            &[7, 39],
            &capture,
            &domain::ProcessingRecipe::default(),
            &recipes,
            &mut overrides,
        )
        .expect("sidecar and all output folders must participate in allocation");

        for (frame, expected) in [(7, "ScanStudio4.tif"), (39, "ScanStudio5.tif")] {
            let output = &overrides.get(&frame).unwrap().output.as_ref().unwrap();
            assert_eq!(resolve_archive_output_path(output, frame), archive_dir.join(expected));
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn sequence_discovery_is_case_insensitive_and_starts_after_the_highest_matching_stem() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("roll-2-final.tiff"), b"gap below maximum").unwrap();
        std::fs::write(dir.join("rOlL-42-fInAl.TIF"), b"highest mixed-case match").unwrap();
        std::fs::write(dir.join("roll-99-other.tif"), b"wrong suffix").unwrap();
        std::fs::write(dir.join("other-100-final.tif"), b"wrong prefix").unwrap();

        assert_eq!(
            highest_existing_sequence_number(
                &dir.display().to_string(),
                "Roll-#-Final.TIFF",
                domain::OutputFileFormat::Tiff,
            )
            .unwrap(),
            42,
            "case-only prefix/suffix/extension differences count and gaps are never filled"
        );

        let default_dir = dir.join("default");
        std::fs::create_dir_all(&default_dir).unwrap();
        std::fs::write(default_dir.join("scanstudio42.TIF"), b"existing").unwrap();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = default_dir.display().to_string();
        recipes.positive.enabled = false;
        recipes.preview.enabled = false;
        let mut overrides = std::collections::HashMap::new();
        reserve_auto_sequence_filenames(
            &[39],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &recipes,
            &mut overrides,
        )
        .unwrap();
        let reserved = &overrides.get(&39).unwrap().output.as_ref().unwrap().archive;
        assert_eq!(
            resolve_output_path(
                &reserved.destination,
                &reserved.filename_template,
                39,
                domain::OutputFileFormat::Tiff,
            ),
            default_dir.join("ScanStudio43.tif")
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn archive_off_sequence_uses_only_retained_output_destinations_and_starts_after_highest() {
        let dir = unique_test_dir();
        let archive_dir = dir.join("disabled-archive");
        let positive_dir = dir.join("positive");
        let preview_dir = dir.join("preview");
        for directory in [&archive_dir, &positive_dir, &preview_dir] {
            std::fs::create_dir_all(directory).unwrap();
        }
        std::fs::write(archive_dir.join("ScanStudio99.tif"), b"must be ignored").unwrap();
        std::fs::write(positive_dir.join("ScanStudio1.tif"), b"existing").unwrap();
        std::fs::write(positive_dir.join("ScanStudio3.jpg"), b"existing").unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.enabled = false;
        recipes.archive.destination = archive_dir.display().to_string();
        recipes.archive.filename_template = "ScanStudio#".into();
        recipes.positive.destination = positive_dir.display().to_string();
        recipes.positive.filename_template = "ScanStudio#".into();
        recipes.preview.destination = preview_dir.display().to_string();
        recipes.preview.filename_template = "ScanStudio#".into();
        let mut overrides = std::collections::HashMap::new();

        reserve_auto_sequence_filenames(
            &[17, 18],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &recipes,
            &mut overrides,
        )
        .expect("retained outputs reserve sequence names");

        for (slot, expected) in [(17, "ScanStudio4.tif"), (18, "ScanStudio5.tif")] {
            let output = overrides[&slot].output.as_ref().unwrap();
            assert_eq!(
                resolve_output_path(
                    &output.positive.destination,
                    &output.positive.filename_template,
                    slot,
                    output.positive.file_format,
                ),
                positive_dir.join(expected),
            );
            assert!(
                is_auto_sequence_template(&output.archive.filename_template),
                "disabled archive must remain out of the job-local reservation plan"
            );
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn materialize_filename_tokens_sanitizes_metadata_and_keeps_legacy_hash_runs() {
        let metadata = domain::MetadataSet {
            camera: Some("Canon 7E".into()),
            lens: Some("EF 50mm f/1.8".into()),
            film_stock: Some("Kodak Gold 200".into()),
            date: Some(domain::PartialDate::Exact { date: "2026-07-27".into() }),
            ..Default::default()
        };
        assert_eq!(
            materialize_filename_tokens(
                "$FilmStock-$Camera-$Lens-$Month-$Day-$Year-$Frame",
                &metadata
            ),
            "KodakGold200-Canon7E-EF50mmF1.8-07-27-2026-####"
        );
        assert_eq!(materialize_filename_tokens("Archive_####", &metadata), "Archive_####");
    }

    #[test]
    fn output_templates_reject_absolute_and_traversal_paths_before_any_write() {
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.filename_template = "../../outside".into();
        assert!(validate_output_recipe_paths(&recipes).is_err());
        recipes.archive.filename_template = "/tmp/outside".into();
        assert!(validate_output_recipe_paths(&recipes).is_err());
        recipes.archive.filename_template = "safe-name".into();
        assert!(validate_output_recipe_paths(&recipes).is_ok());
    }

    #[test]
    fn pairwise_alias_preflight_leaves_no_archive_on_repeat_attempts() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.positive.destination = dir.display().to_string();
        recipes.archive.filename_template = "same_####".into();
        recipes.positive.filename_template = "same_####".into();
        recipes.positive.enabled = true;
        recipes.preview.enabled = false;
        for _ in 0..2 {
            let error = render_and_write_frame("sim", 1, domain::FilmProcess::C41ColorNegative, 2, 2, 16, &recipes, None, None).unwrap_err();
            assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
            assert!(!dir.join("same_0001.tif").exists());
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn no_hash_batch_preflight_and_simulator_write_distinct_four_digit_archives() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "Roll.v1.tiff".into();
        recipes.positive.enabled = false;
        recipes.preview.enabled = false;

        validate_batch_output_paths(
            &[1, 2],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &recipes,
            &std::collections::HashMap::new(),
        )
        .expect("no-marker frames must preflight as distinct physical targets");

        let first = render_and_write_frame(
            "sim",
            1,
            domain::FilmProcess::C41ColorNegative,
            2,
            2,
            16,
            &recipes,
            None,
            None,
        )
        .expect("write first simulator archive");
        let second = render_and_write_frame(
            "sim",
            2,
            domain::FilmProcess::C41ColorNegative,
            2,
            2,
            16,
            &recipes,
            None,
            None,
        )
        .expect("write second simulator archive");
        assert_eq!(first.archive_path, Some(dir.join("Roll.v1_0001.tiff")));
        assert_eq!(second.archive_path, Some(dir.join("Roll.v1_0002.tiff")));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn final_name_resolver_preserves_only_extensions_owned_by_the_format() {
        for (template, expected) in [
            ("Archive_####", "Archive_####.tif"),
            ("Archive_####.tif", "Archive_####.tif"),
            ("Archive_####.tiff", "Archive_####.tiff"),
            ("Archive_####.TiF", "Archive_####.TiF"),
            (
                "KodakGold200-EF50mmF1.8STM-####",
                "KodakGold200-EF50mmF1.8STM-####.tif",
            ),
            ("wrong.jpg", "wrong.jpg.tif"),
        ] {
            assert_eq!(
                normalize_output_filename_template(
                    template,
                    domain::OutputFileFormat::Tiff
                ),
                expected
            );
        }
        for (template, expected) in [
            ("Preview_####", "Preview_####.jpg"),
            ("Preview_####.jpg", "Preview_####.jpg"),
            ("Preview_####.jpeg", "Preview_####.jpeg"),
            ("Preview_####.JpEg", "Preview_####.JpEg"),
            ("wrong.tif", "wrong.tif.jpg"),
        ] {
            assert_eq!(
                normalize_output_filename_template(
                    template,
                    domain::OutputFileFormat::Jpeg
                ),
                expected
            );
        }
    }

    #[test]
    fn batch_preflight_rejects_cross_frame_template_collisions() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let mut output = domain::OutputRecipe::default();
        output.archive.destination = dir.display().to_string();
        output.positive.enabled = false;
        output.preview.enabled = false;
        let mut first = output.clone();
        first.archive.filename_template = "x_#_2".into();
        let mut second = output.clone();
        second.archive.filename_template = "x_1_#".into();
        let overrides = std::collections::HashMap::from([
            (
                1,
                domain::FrameOverrides {
                    output: Some(first),
                    ..Default::default()
                },
            ),
            (
                2,
                domain::FrameOverrides {
                    output: Some(second),
                    ..Default::default()
                },
            ),
        ]);
        let error = validate_batch_output_paths(
            &[1, 2],
            &domain::CaptureRecipe::default(),
            &domain::ProcessingRecipe::default(),
            &output,
            &overrides,
        )
        .unwrap_err();
        assert_eq!(error.code, protocol::ErrorCode::InvalidParams);
        assert!(!dir.join("x_1_2.tif").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn physical_preflight_rejects_lexical_case_and_sidecar_aliases() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(dir.join("a")).unwrap();
        let mut lexical = domain::OutputRecipe::default();
        lexical.archive.destination = dir.join("a/..").display().to_string();
        lexical.archive.filename_template = "same_####".into();
        lexical.positive.destination = dir.display().to_string();
        lexical.positive.filename_template = "same_####".into();
        lexical.preview.enabled = false;
        assert_eq!(
            validate_frame_output_paths(&lexical, 1).unwrap_err().code,
            protocol::ErrorCode::InvalidParams
        );

        let mut case_only = lexical.clone();
        case_only.archive.destination = dir.display().to_string();
        case_only.archive.filename_template = "Output_####".into();
        case_only.positive.filename_template = "output_####".into();
        assert_eq!(
            validate_frame_output_paths(&case_only, 1)
                .unwrap_err()
                .code,
            protocol::ErrorCode::InvalidParams
        );

        let mut sidecar = domain::OutputRecipe::default();
        sidecar.archive.destination = dir.display().to_string();
        sidecar.archive.filename_template = "Frame_####".into();
        sidecar.positive.destination = dir.display().to_string();
        sidecar.positive.filename_template = "Frame_####_IR".into();
        sidecar.positive.file_format = domain::OutputFileFormat::Tiff;
        sidecar.preview.enabled = false;
        assert_eq!(
            validate_batch_output_paths(
                &[1],
                &domain::CaptureRecipe::default(),
                &domain::ProcessingRecipe::default(),
                &sidecar,
                &std::collections::HashMap::new(),
            )
            .unwrap_err()
            .code,
            protocol::ErrorCode::InvalidParams
        );

        let mut raw_alias = domain::OutputRecipe::default();
        raw_alias.archive.destination = dir.display().to_string();
        raw_alias.archive.filename_template = "Raw_####.tif".into();
        raw_alias.raw_export.enabled = true;
        raw_alias.raw_export.file_format = domain::RawExportFormat::LinearTiff;
        raw_alias.raw_export.destination = dir.display().to_string();
        raw_alias.raw_export.filename_template = "Raw_####.tif".into();
        raw_alias.positive.enabled = false;
        raw_alias.preview.enabled = false;
        assert_eq!(
            validate_frame_output_paths(&raw_alias, 1).unwrap_err().code,
            protocol::ErrorCode::InvalidParams
        );

        let mut raw_sidecar_alias = domain::OutputRecipe::default();
        raw_sidecar_alias.archive.enabled = false;
        raw_sidecar_alias.raw_export.enabled = true;
        raw_sidecar_alias.raw_export.file_format = domain::RawExportFormat::LinearDng;
        raw_sidecar_alias.raw_export.tiff_infrared = domain::RawTiffInfrared::Sidecar;
        raw_sidecar_alias.raw_export.destination = dir.display().to_string();
        raw_sidecar_alias.raw_export.filename_template = "Negative_####.dng".into();
        raw_sidecar_alias.positive.destination = dir.display().to_string();
        raw_sidecar_alias.positive.filename_template = "Negative_####-ir.tif".into();
        raw_sidecar_alias.preview.enabled = false;
        assert_eq!(
            validate_frame_output_paths(&raw_sidecar_alias, 1)
                .unwrap_err()
                .code,
            protocol::ErrorCode::InvalidParams
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn physical_preflight_resolves_parent_symlinks_and_rejects_leaf_symlinks() {
        use std::os::unix::fs::symlink;
        let dir = unique_test_dir();
        let real = dir.join("real");
        let alias = dir.join("alias");
        std::fs::create_dir_all(&real).unwrap();
        symlink(&real, &alias).unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = real.display().to_string();
        recipes.archive.filename_template = "same_####".into();
        recipes.positive.destination = alias.display().to_string();
        recipes.positive.filename_template = "same_####".into();
        recipes.preview.enabled = false;
        assert_eq!(
            validate_frame_output_paths(&recipes, 1)
                .unwrap_err()
                .code,
            protocol::ErrorCode::InvalidParams
        );

        recipes.positive.enabled = false;
        let victim = dir.join("victim.tif");
        std::fs::write(&victim, b"victim").unwrap();
        let archive_leaf = real.join("same_0001.tif");
        symlink(&victim, &archive_leaf).unwrap();
        assert_eq!(
            validate_frame_output_paths(&recipes, 1)
                .unwrap_err()
                .code,
            protocol::ErrorCode::InvalidParams
        );
        assert_eq!(std::fs::read(&victim).unwrap(), b"victim");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn bridge_receipt_paths_must_match_the_reserved_archive_and_sidecars() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "frame-####".into();
        let rgb = dir.join("frame-0001.tif");
        let ir = dir.join("frame-0001_IR.tif");
        let meter = dir.join("frame-0001_METER.tif");
        for path in [&rgb, &ir, &meter] {
            std::fs::write(path, b"fixture").unwrap();
        }
        validate_bridge_capture_receipt_paths(
            &recipes,
            1,
            domain::Channels::Rgbi,
            &rgb,
            Some(&ir),
            Some(&meter),
        )
        .unwrap();
        let wrong = dir.join("wrong.tif");
        std::fs::write(&wrong, b"fixture").unwrap();
        assert_eq!(
            validate_bridge_capture_receipt_paths(
                &recipes,
                1,
                domain::Channels::Rgbi,
                &wrong,
                Some(&ir),
                Some(&meter),
            )
            .unwrap_err()
            .code,
            protocol::ErrorCode::InvalidParams
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn bridge_raw_receipt_path_must_match_the_reserved_output() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let expected = dir.join("frame-0001.dng");
        let wrong = dir.join("other.dng");
        std::fs::write(&expected, b"fixture").unwrap();
        std::fs::write(&wrong, b"fixture").unwrap();
        validate_bridge_raw_export_receipt_path(Some(&expected), Some(&expected), 1).unwrap();
        assert_eq!(
            validate_bridge_raw_export_receipt_path(Some(&expected), Some(&wrong), 1)
                .unwrap_err()
                .code,
            protocol::ErrorCode::InvalidParams
        );
        assert!(validate_bridge_raw_export_receipt_path(Some(&expected), None, 1).is_err());
        assert!(validate_bridge_raw_export_receipt_path(None, Some(&wrong), 1).is_err());
        validate_bridge_raw_export_receipt_path(None, None, 1).unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn atomic_derivative_write_replaces_a_raced_symlink_without_touching_target() {
        use std::os::unix::fs::symlink;
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let protected = dir.join("protected.bin");
        let derivative = dir.join("positive.tif");
        std::fs::write(&protected, b"do-not-touch").unwrap();
        symlink(&protected, &derivative).unwrap();
        let raw = generate_sim_frame("sim", 1, 4, 3);
        write_derivative(
            &derivative,
            &raw,
            4,
            3,
            domain::OutputFileFormat::Tiff,
            false,
            &DerivativeMetadata::positive(domain::FilmProcess::C41ColorNegative, 4000),
        )
        .unwrap();
        assert_eq!(std::fs::read(&protected).unwrap(), b"do-not-touch");
        assert!(
            !std::fs::symlink_metadata(&derivative)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(windows)]
    #[test]
    fn physical_preflight_rejects_an_existing_create_only_leaf_on_windows() {
        let dir = unique_test_dir();
        let real = dir.join("real");
        std::fs::create_dir_all(&real).unwrap();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = real.display().to_string();
        recipes.archive.filename_template = "same_####".into();
        recipes.positive.enabled = false;
        recipes.preview.enabled = false;
        let victim = dir.join("victim.tif");
        std::fs::write(&victim, b"victim").unwrap();
        let archive_leaf = real.join("same_0001.tif");
        std::fs::copy(&victim, &archive_leaf).unwrap();
        assert_eq!(
            validate_frame_output_paths(&recipes, 1)
                .unwrap_err()
                .code,
            protocol::ErrorCode::ArchiveCollision
        );
        assert_eq!(std::fs::read(&victim).unwrap(), b"victim");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(windows)]
    #[test]
    fn atomic_derivative_write_replaces_an_existing_file_without_touching_a_neighbor_on_windows() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let protected = dir.join("protected.bin");
        let derivative = dir.join("positive.tif");
        std::fs::write(&protected, b"do-not-touch").unwrap();
        std::fs::copy(&protected, &derivative).unwrap();
        let raw = generate_sim_frame("sim", 1, 4, 3);
        write_derivative(
            &derivative,
            &raw,
            4,
            3,
            domain::OutputFileFormat::Tiff,
            false,
        )
        .unwrap();
        assert_eq!(std::fs::read(&protected).unwrap(), b"do-not-touch");
        assert!(
            !std::fs::symlink_metadata(&derivative)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn auto_sequence_tiff_derivative_is_create_only_if_final_appears_after_preflight() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let derivative = dir.join("ScanStudio9.tif");
        std::fs::write(&derivative, b"raced-final").unwrap();
        let raw = generate_sim_frame("sim", 1, 4, 3);

        let error = write_derivative(
            &derivative,
            &raw,
            4,
            3,
            domain::OutputFileFormat::Tiff,
            true,
            &DerivativeMetadata::positive(domain::FilmProcess::C41ColorNegative, 4000),
        )
        .unwrap_err();

        assert_eq!(error.code, protocol::ErrorCode::ArchiveCollision);
        assert_eq!(std::fs::read(&derivative).unwrap(), b"raced-final");
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1, "temporary sibling must be cleaned");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn auto_sequence_jpeg_derivative_is_create_only_if_final_appears_after_preflight() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let derivative = dir.join("ScanStudio10.jpg");
        std::fs::write(&derivative, b"raced-jpeg-final").unwrap();
        let raw = generate_sim_frame("sim", 1, 4, 3);

        let error = write_derivative(
            &derivative,
            &raw,
            4,
            3,
            domain::OutputFileFormat::Jpeg,
            true,
            &DerivativeMetadata::positive(domain::FilmProcess::C41ColorNegative, 4000),
        )
        .unwrap_err();

        assert_eq!(error.code, protocol::ErrorCode::ArchiveCollision);
        assert_eq!(std::fs::read(&derivative).unwrap(), b"raced-jpeg-final");
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1, "temporary sibling must be cleaned");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn render_positive_actually_transforms_c41_color_negative() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        let (out, provenance) = render_positive(domain::FilmProcess::C41ColorNegative, &raw, 8, None)
            .expect("nikonlook bundle must load and apply");
        assert_ne!(out, raw, "nikonlook must actually transform the data");

        // Finding 2: a C41 render must surface its nikonlook provenance --
        // no exposure metadata supplied, so the blind path must have run.
        let provenance = provenance.expect("a C41 render must report nikonlook provenance");
        assert_eq!(provenance.bundle_version, "nikonlook-v2");
        assert_eq!(provenance.layer_a_path, domain::NikonlookLayerAPath::Blind);
        assert!(
            provenance.gains.iter().all(|value| value.is_finite() && *value > 0.0),
            "reported gains must be the real, finite, positive values estimate_gains returned: {:?}",
            provenance.gains
        );

        // The reported gains must be exactly what produced `out`, not a
        // separately-computed or stale value: re-applying them from scratch
        // against a freshly loaded bundle must reproduce the actual render.
        let bundle = crate::processing::nikonlook::load_bundle().expect("real v2 bundle must load");
        let reapplied = crate::processing::nikonlook::apply(&raw, provenance.gains, &bundle);
        assert_eq!(
            reapplied, out,
            "apply()'d output using the reported gains must equal the actual render"
        );
    }

    /// Same literal as `processing::nikonlook`'s own Group J/N tests and
    /// `tests/nikonlook_v2_fixture.rs`'s `EXPOSURE_10NS_FRAME5` -- a real,
    /// usable exposure triple.
    const USABLE_EXPOSURE_10NS: [f64; 3] = [127992.0, 312892.0, 259345.0];

    #[test]
    fn render_positive_c41_with_usable_exposure_labels_hardware_exposure() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        let (out, provenance) = render_positive(
            domain::FilmProcess::C41ColorNegative,
            &raw,
            8,
            Some(USABLE_EXPOSURE_10NS),
        )
        .expect("nikonlook bundle must load and apply");

        let provenance = provenance.expect("a C41 render must report nikonlook provenance");
        assert_eq!(provenance.bundle_version, "nikonlook-v2");
        assert_eq!(
            provenance.layer_a_path,
            domain::NikonlookLayerAPath::HardwareExposure,
            "a usable exposure_10ns must route to the hardware-exposure path, not fall back to blind"
        );

        let bundle = crate::processing::nikonlook::load_bundle().expect("real v2 bundle must load");
        let expected_gains =
            crate::processing::nikonlook::estimate_gains(&raw, 8, Some(USABLE_EXPOSURE_10NS), &bundle)
                .expect("exposure path never fails");
        assert_eq!(
            provenance.gains, expected_gains,
            "reported gains must equal estimate_gains' own output for this exposure"
        );
        let reapplied = crate::processing::nikonlook::apply(&raw, provenance.gains, &bundle);
        assert_eq!(reapplied, out, "apply()'d output using the reported gains must equal the actual render");
    }

    #[test]
    fn render_positive_c41_with_malformed_exposure_falls_back_to_blind() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        // Non-finite, zero, and negative components are all "unusable" --
        // see processing::nikonlook::exposure_is_usable. One representative
        // case here; that predicate's own exhaustive cases are covered by
        // Group P in processing/nikonlook.rs.
        let malformed = [f64::NAN, 312892.0, 259345.0];

        let (_, provenance) =
            render_positive(domain::FilmProcess::C41ColorNegative, &raw, 8, Some(malformed))
                .expect("a malformed exposure must fall back to blind, never fail");

        let provenance = provenance.expect("a C41 render must report nikonlook provenance");
        assert_eq!(
            provenance.layer_a_path,
            domain::NikonlookLayerAPath::Blind,
            "a malformed exposure_10ns must be treated like None, not silently divided into a gain"
        );
    }

    #[test]
    fn render_positive_passthroughs_positive_kodachrome_and_neutral_inverts_bw_negative() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        for process in [domain::FilmProcess::Positive, domain::FilmProcess::Kodachrome] {
            let (out, provenance) = render_positive(process, &raw, 8, None).expect("passthrough never fails");
            assert_eq!(out, raw, "{process:?} must be an exact passthrough");
            assert!(provenance.is_none(), "{process:?} never runs nikonlook, so provenance must be None");
        }
        let (bw, bw_provenance) = render_positive(domain::FilmProcess::BwNegative, &raw, 8, None).unwrap();
        assert!(bw_provenance.is_none(), "BwNegative never runs nikonlook, so provenance must be None");
        for (source, rendered) in raw.iter().zip(bw) {
            let expected = 1.0 - (source[0] + source[1] + source[2]) / 3.0;
            assert_eq!(rendered, [expected; 3]);
        }
    }

    #[test]
    fn archive_write_is_create_only_and_never_overwrites() {
        let dir = unique_test_dir();
        std::fs::create_dir_all(&dir).expect("create test dir");
        let path = dir.join("archive.tiff");
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);

        write_tiff_create_only(&path, &raw, 8, 6, 16).expect("first write succeeds");
        let original_bytes = std::fs::read(&path).expect("read back first write");

        let raw2 = generate_sim_frame("sim-ls5000-0", 2, 8, 6);
        let err = write_tiff_create_only(&path, &raw2, 8, 6, 16).unwrap_err();
        assert_eq!(err.code, protocol::ErrorCode::ArchiveCollision);

        let bytes_after = std::fs::read(&path).expect("read back after failed second write");
        assert_eq!(
            original_bytes, bytes_after,
            "archive bytes must be unchanged after a failed second write"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_archive_derivatives_write_requested_files_without_mutating_archive() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        write_small_rgb16_tiff(&archive_path, 8, 6);
        let archive_before = std::fs::read(&archive_path).expect("read archive before");

        let mut recipes = domain::OutputRecipe::default();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.destination = dir.join("Preview").display().to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Jpeg;
        recipes.preview.max_long_edge_px = 4;

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            3200,
        )
        .expect("render real derivatives");

        assert_eq!(std::fs::read(&archive_path).unwrap(), archive_before);
        assert_eq!(written.archive_path, Some(archive_path));
        assert!(written.positive_path.as_ref().is_some_and(|path| path.is_file()));
        assert!(written.preview_path.as_ref().is_some_and(|path| path.is_file()));
        let positive = image_io::read_rgb16(written.positive_path.as_ref().unwrap())
            .expect("positive is a readable RGB16 TIFF");
        assert_eq!((positive.width, positive.height), (8, 6));

        assert_eq!(
            <IccProfileValue<'static> as tiff::encoder::TiffValue>::FIELD_TYPE,
            tiff::tags::Type::UNDEFINED
        );
        let positive_bytes = std::fs::read(written.positive_path.as_ref().unwrap()).unwrap();
        assert_eq!(
            classic_tiff_field_type(&positive_bytes, 34675),
            Some(7),
            "TIFF ICC_Profile must use field type UNDEFINED (7), not BYTE (1)"
        );

        let positive_file = std::fs::File::open(written.positive_path.as_ref().unwrap()).unwrap();
        let mut positive_decoder = tiff::decoder::Decoder::new(positive_file).unwrap();
        assert!(matches!(
            positive_decoder.get_tag(tiff::tags::Tag::XResolution).unwrap(),
            tiff::decoder::ifd::Value::Rational(3200, 1)
        ));
        assert!(matches!(
            positive_decoder.get_tag(tiff::tags::Tag::YResolution).unwrap(),
            tiff::decoder::ifd::Value::Rational(3200, 1)
        ));
        assert_eq!(
            positive_decoder.get_tag_u32(tiff::tags::Tag::ResolutionUnit).unwrap(),
            2
        );
        let positive_icc = positive_decoder
            .get_tag_u8_vec(tiff::tags::Tag::IccProfile)
            .expect("C41 Positive TIFF carries ICC");
        moxcms::ColorProfile::new_from_slice(&positive_icc)
            .expect("Positive TIFF ICC parses");

        use image::ImageDecoder as _;
        let preview_file = std::fs::File::open(written.preview_path.as_ref().unwrap()).unwrap();
        let mut preview_decoder =
            image::codecs::jpeg::JpegDecoder::new(std::io::BufReader::new(preview_file)).unwrap();
        let preview_icc = preview_decoder
            .icc_profile()
            .unwrap()
            .expect("C41 Preview JPEG carries ICC");
        assert_eq!(preview_icc, positive_icc, "C41 color contract is format-independent");

        // This is the exact function real_backend.rs's `run_real_scan_job_inner`
        // calls (`render_derivative_from_archive` is a thin exposure_10ns=None
        // wrapper around `render_derivative_from_archive_with_processing`) --
        // its `WrittenPaths.nikonlook` is copied verbatim into
        // `ScanReceipt.nikonlook` there (`receipt.nikonlook = written.nikonlook;`).
        // Proving it here, written for a real archive file on disk, is the
        // closest feasible proof of that patch-in short of standing up a
        // fake bridge subprocess to drive `run_real_scan_job_inner` itself.
        let provenance = written.nikonlook.expect("a C41 archive render must report nikonlook provenance");
        assert_eq!(provenance.bundle_version, "nikonlook-v2");
        assert_eq!(
            provenance.layer_a_path,
            domain::NikonlookLayerAPath::Blind,
            "render_derivative_from_archive supplies no exposure_10ns, so blind must have run"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_archive_derivative_transform_rotates_and_flips_both_outputs_without_mutating_master() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        std::fs::create_dir_all(archive_path.parent().unwrap()).unwrap();
        let source_pixels = vec![
            [1_000, 1_000, 1_000],
            [2_000, 2_000, 2_000],
            [3_000, 3_000, 3_000],
            [4_000, 4_000, 4_000],
            [5_000, 5_000, 5_000],
            [6_000, 6_000, 6_000],
        ];
        image_io::write_rgb16(
            &archive_path,
            &image_io::Rgb16Image {
                width: 3,
                height: 2,
                pixels: source_pixels,
            },
        )
        .unwrap();
        let archive_before = std::fs::read(&archive_path).unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.destination = dir.join("Preview").display().to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.max_long_edge_px = 100;
        let alignment = domain::FrameAlignment {
            offset_rows: 0,
            approved: false,
            derivative_transform: domain::DerivativeTransform {
                rotation_degrees: 90,
                horizontal_mirror: true,
                vertical_mirror: false,
            },
        };

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::Positive,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            Some(&alignment),
            4000,
        )
        .expect("render transformed derivatives");

        assert_eq!(std::fs::read(&archive_path).unwrap(), archive_before);
        assert_eq!(written.derivative_transform, domain::DerivativeTransform {
            rotation_degrees: 90,
            horizontal_mirror: true,
            vertical_mirror: false,
        });
        let positive_path = written.positive_path.clone().unwrap();
        for path in [&written.positive_path, &written.preview_path] {
            let image = image_io::read_rgb16(path.as_ref().unwrap()).unwrap();
            assert_eq!((image.width, image.height), (2, 3));
            assert_eq!(
                image.pixels,
                vec![
                    [6_000, 6_000, 6_000],
                    [3_000, 3_000, 3_000],
                    [5_000, 5_000, 5_000],
                    [2_000, 2_000, 2_000],
                    [4_000, 4_000, 4_000],
                    [1_000, 1_000, 1_000],
                ]
            );
        }

        let mut decoder = tiff::decoder::Decoder::new(std::fs::File::open(positive_path).unwrap())
            .unwrap();
        assert!(
            decoder.get_tag(tiff::tags::Tag::IccProfile).is_err(),
            "positive-film passthrough must not be falsely labeled as ScanStudio RGB"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn derivative_transform_permutation_is_exact_for_every_rotation_and_mirror_combination() {
        let cases: &[(u16, bool, bool, (u32, u32), &[u16])] = &[
            (0, false, false, (3, 2), &[1, 2, 3, 4, 5, 6]),
            (0, true, false, (3, 2), &[3, 2, 1, 6, 5, 4]),
            (0, false, true, (3, 2), &[4, 5, 6, 1, 2, 3]),
            (0, true, true, (3, 2), &[6, 5, 4, 3, 2, 1]),
            (90, false, false, (2, 3), &[4, 1, 5, 2, 6, 3]),
            (90, true, false, (2, 3), &[6, 3, 5, 2, 4, 1]),
            (90, false, true, (2, 3), &[1, 4, 2, 5, 3, 6]),
            (90, true, true, (2, 3), &[3, 6, 2, 5, 1, 4]),
            (180, false, false, (3, 2), &[6, 5, 4, 3, 2, 1]),
            (180, true, false, (3, 2), &[4, 5, 6, 1, 2, 3]),
            (180, false, true, (3, 2), &[3, 2, 1, 6, 5, 4]),
            (180, true, true, (3, 2), &[1, 2, 3, 4, 5, 6]),
            (270, false, false, (2, 3), &[3, 6, 2, 5, 1, 4]),
            (270, true, false, (2, 3), &[1, 4, 2, 5, 3, 6]),
            (270, false, true, (2, 3), &[6, 3, 5, 2, 4, 1]),
            (270, true, true, (2, 3), &[4, 1, 5, 2, 6, 3]),
        ];

        for &(rotation_degrees, horizontal_mirror, vertical_mirror, dimensions, expected) in cases {
            let mut raw: Vec<[f64; 3]> = (1..=6)
                .map(|value| [value as f64; 3])
                .collect();
            let actual_dimensions = apply_derivative_transform_in_place(
                &mut raw,
                3,
                2,
                domain::DerivativeTransform {
                    rotation_degrees,
                    horizontal_mirror,
                    vertical_mirror,
                },
            )
            .unwrap();
            assert_eq!(actual_dimensions, dimensions);
            assert_eq!(
                raw.iter().map(|pixel| pixel[0] as u16).collect::<Vec<_>>(),
                expected,
                "rotation={rotation_degrees}, horizontalMirror={horizontal_mirror}, verticalMirror={vertical_mirror}"
            );
        }
    }

    #[test]
    fn real_archive_derivative_nikonlook_provenance_tracks_exposure_usability() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        write_small_rgb16_tiff(&archive_path, 8, 6);

        let mut recipes = domain::OutputRecipe::default();
        recipes.preview.enabled = false;
        let processing = domain::ProcessingRecipe {
            film_process: domain::FilmProcess::C41ColorNegative,
            ..domain::ProcessingRecipe::default()
        };

        // A usable exposure -- the real_backend.rs path opted into it and
        // the bridge supplied a finite, positive triple.
        recipes.positive.destination = dir.join("Hardware").display().to_string();
        let written_hardware = render_derivative_from_archive_with_processing(
            &archive_path, 1, &processing, &recipes, Some(STORAGE_TRANSFORM_SWAPAXES01),
            None, None, None, Some(USABLE_EXPOSURE_10NS),
            4000,
        )
        .expect("render real derivatives");
        let hardware_provenance = written_hardware
            .nikonlook
            .expect("a C41 archive render must report nikonlook provenance");
        assert_eq!(hardware_provenance.layer_a_path, domain::NikonlookLayerAPath::HardwareExposure);

        // A malformed exposure -- must fall back to blind, never fail or
        // silently divide a meaningless ratio into the gain.
        recipes.positive.destination = dir.join("Malformed").display().to_string();
        let written_malformed = render_derivative_from_archive_with_processing(
            &archive_path, 1, &processing, &recipes, Some(STORAGE_TRANSFORM_SWAPAXES01),
            None, None, None, Some([f64::NAN, 312892.0, 259345.0]),
            4000,
        )
        .expect("a malformed exposure must fall back to blind, never fail");
        let malformed_provenance = written_malformed
            .nikonlook
            .expect("a C41 archive render must report nikonlook provenance");
        assert_eq!(malformed_provenance.layer_a_path, domain::NikonlookLayerAPath::Blind);

        let _ = std::fs::remove_dir_all(&dir);
    }

    fn write_autocrop_pattern_archive(path: &std::path::Path) -> (u32, u32) {
        let width = 480u32;
        let height = 320u32;
        let mut raw = vec![[0.95f64; 3]; (width * height) as usize];
        for y in 40..280u32 {
            for x in 40..440u32 {
                raw[(y * width + x) as usize] = [0.55; 3];
            }
        }
        for y in 58..262u32 {
            for x in 58..422u32 {
                let base = 0.15
                    + 0.20 * ((x - 58) as f64 / (422 - 58) as f64)
                    + 0.025 * ((y as f64) * 0.3).sin()
                    + 0.05;
                raw[(y * width + x) as usize] = [base * 0.8, base * 0.9, base];
            }
        }
        write_tiff_create_only(path, &raw, width, height, 16).expect("write autocrop archive");
        (width, height)
    }

    #[test]
    fn real_auto_crop_crops_derivatives_reports_roi_and_preserves_archive() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        let (width, height) = write_autocrop_pattern_archive(&archive_path);
        let archive_before = std::fs::read(&archive_path).unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.auto_crop = true;
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.destination = dir.join("Preview").display().to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.max_long_edge_px = 100;

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::Positive,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            4000,
        )
        .expect("auto-cropped derivatives render");

        assert_eq!(std::fs::read(&archive_path).unwrap(), archive_before);
        let outcome = written.auto_crop.expect("auto-crop outcome");
        assert!(outcome.applied);
        assert_eq!((outcome.source_width, outcome.source_height), (width, height));
        let roi = outcome.roi.expect("applied outcome carries ROI");
        assert!(roi.y1 > 0 && roi.x1 > 0 && roi.y2 < height && roi.x2 < width);

        let positive = image_io::read_rgb16(written.positive_path.as_ref().unwrap()).unwrap();
        assert_eq!((positive.width, positive.height), (roi.x2 - roi.x1, roi.y2 - roi.y1));
        let preview = image_io::read_rgb16(written.preview_path.as_ref().unwrap()).unwrap();
        assert_eq!(
            (preview.width, preview.height),
            downsample_dimensions(roi.x2 - roi.x1, roi.y2 - roi.y1, 100)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_auto_crop_off_keeps_full_frame_and_reports_nothing() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        let (width, height) = write_autocrop_pattern_archive(&archive_path);
        let mut recipes = domain::OutputRecipe::default();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::Positive,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            4000,
        )
        .unwrap();
        assert!(written.auto_crop.is_none());
        let positive = image_io::read_rgb16(written.positive_path.as_ref().unwrap()).unwrap();
        assert_eq!((positive.width, positive.height), (width, height));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_auto_crop_defers_to_approved_alignment() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        let (width, _) = write_autocrop_pattern_archive(&archive_path);
        let mut recipes = domain::OutputRecipe::default();
        recipes.auto_crop = true;
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;
        let alignment = domain::FrameAlignment {
            offset_rows: 0,
            approved: true,
            derivative_transform: domain::DerivativeTransform::default(),
        };

        let written = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::Positive,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            Some((40, 280)),
            Some(&alignment),
            4000,
        )
        .unwrap();
        let outcome = written.auto_crop.expect("deferred outcome");
        assert!(!outcome.applied);
        assert!(outcome.reason.as_deref().is_some_and(|reason| reason.contains("alignment")));
        let positive = image_io::read_rgb16(written.positive_path.as_ref().unwrap()).unwrap();
        assert_eq!((positive.width, positive.height), (width, 241));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn output_recipe_auto_crop_defaults_false_and_round_trips_camel_case() {
        let parsed: domain::OutputRecipe = serde_json::from_str("{}").unwrap();
        assert!(!parsed.auto_crop);
        let mut recipes = domain::OutputRecipe::default();
        recipes.auto_crop = true;
        let json = serde_json::to_string(&recipes).unwrap();
        assert!(json.contains("\"autoCrop\":true"));
        assert!(serde_json::from_str::<domain::OutputRecipe>(&json).unwrap().auto_crop);
    }

    #[test]
    fn real_bw_dust_option_changes_only_derivatives_and_default_off_matches_explicit_false() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive").join("Archive_0001.tif");
        let mut raw = vec![[0.5; 3]; 225];
        for index in [112, 113, 127, 128] { raw[index] = [0.0; 3]; }
        write_tiff_create_only(&archive_path, &raw, 15, 15, 16).unwrap();
        let archive_before = std::fs::read(&archive_path).unwrap();

        let mut recipes = domain::OutputRecipe::default();
        recipes.preview.enabled = false;
        recipes.positive.destination = dir.join("Off").display().to_string();
        let default_off = domain::ProcessingRecipe { film_process: domain::FilmProcess::BwNegative, ..domain::ProcessingRecipe::default() };
        let written_off = render_derivative_from_archive_with_processing(&archive_path, 1, &default_off, &recipes, Some(STORAGE_TRANSFORM_SWAPAXES01), None, None, None, None, 4000).unwrap();
        let off_bytes = std::fs::read(written_off.positive_path.unwrap()).unwrap();

        recipes.positive.destination = dir.join("ExplicitFalse").display().to_string();
        let explicit_false = domain::ProcessingRecipe { film_process: domain::FilmProcess::BwNegative, software_dust_removal_bw: false, ..domain::ProcessingRecipe::default() };
        let written_false = render_derivative_from_archive_with_processing(&archive_path, 1, &explicit_false, &recipes, Some(STORAGE_TRANSFORM_SWAPAXES01), None, None, None, None, 4000).unwrap();
        assert_eq!(off_bytes, std::fs::read(written_false.positive_path.unwrap()).unwrap());

        recipes.positive.destination = dir.join("On").display().to_string();
        let enabled = domain::ProcessingRecipe { film_process: domain::FilmProcess::BwNegative, software_dust_removal_bw: true, ..domain::ProcessingRecipe::default() };
        let written_on = render_derivative_from_archive_with_processing(&archive_path, 1, &enabled, &recipes, Some(STORAGE_TRANSFORM_SWAPAXES01), None, None, None, None, 4000).unwrap();
        assert_ne!(off_bytes, std::fs::read(written_on.positive_path.unwrap()).unwrap());
        assert_eq!(std::fs::read(&archive_path).unwrap(), archive_before);

        let c41 = domain::ProcessingRecipe { film_process: domain::FilmProcess::C41ColorNegative, software_dust_removal_bw: true, ..domain::ProcessingRecipe::default() }.effective();
        assert!(!c41.software_dust_removal_bw);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn real_archive_derivatives_disabled_need_no_file_or_transform() {
        let mut recipes = domain::OutputRecipe::default();
        recipes.positive.enabled = false;
        recipes.preview.enabled = false;

        let missing = unique_test_dir().join("missing.tif");
        let written = render_derivative_from_archive(
            &missing,
            7,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            None,
            None,
            None,
            None,
            4000,
        )
        .expect("disabled derivatives are a no-op");
        assert_eq!(written.archive_path, Some(missing));
        assert!(written.positive_path.is_none());
        assert!(written.preview_path.is_none());
    }

    #[test]
    fn real_archive_derivatives_refuse_unknown_orientation_profile_and_crop() {
        let dir = unique_test_dir();
        let archive_path = dir.join("Archive_0001.tif");
        write_small_rgb16_tiff(&archive_path, 8, 6);
        let mut recipes = domain::OutputRecipe::default();
        recipes.preview.enabled = false;

        let missing_transform = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            None,
            None,
            None,
            None,
            4000,
        )
        .unwrap_err();
        assert_eq!(missing_transform.code, protocol::ErrorCode::InvalidParams);

        let wrong_transform = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            Some("rot90k1-scanner-native-to-storage-v1"),
            None,
            None,
            None,
            4000,
        )
        .unwrap_err();
        assert_eq!(wrong_transform.code, protocol::ErrorCode::InvalidParams);

        recipes.positive.color_profile = domain::OutputColorProfile::SRgb;
        let unsupported_profile = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            None,
            4000,
        )
        .unwrap_err();
        assert_eq!(unsupported_profile.code, protocol::ErrorCode::InvalidParams);

        recipes.positive.color_profile = domain::OutputColorProfile::AdobeRgb1998;
        let missing_boundary = render_derivative_from_archive(
            &archive_path,
            1,
            domain::FilmProcess::C41ColorNegative,
            &recipes,
            Some(STORAGE_TRANSFORM_SWAPAXES01),
            None,
            None,
            Some(&domain::FrameAlignment::approved(0)),
            4000,
        )
        .unwrap_err();
        assert_eq!(missing_boundary.code, protocol::ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn render_and_write_frame_refuses_a_positive_path_aliasing_the_archive() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "Frame_####".to_string();
        recipes.positive.destination = dir.display().to_string();
        recipes.positive.filename_template = "Frame_####".to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;

        let err = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes,
            None,
            None,
        )
        .unwrap_err();
        assert_eq!(err.code, protocol::ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn render_and_write_frame_refuses_a_preview_path_aliasing_the_archive() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.display().to_string();
        recipes.archive.filename_template = "Frame_####".to_string();
        recipes.positive.enabled = false;
        recipes.preview.destination = dir.display().to_string();
        recipes.preview.filename_template = "Frame_####".to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Tiff;

        let err = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes,
            None,
            None,
        )
        .unwrap_err();
        assert_eq!(err.code, protocol::ErrorCode::InvalidParams);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn render_and_write_frame_writes_all_three_real_files_when_enabled() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.join("Archive").display().to_string();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.destination = dir.join("Preview").display().to_string();
        recipes.preview.file_format = domain::OutputFileFormat::Jpeg;
        recipes.preview.max_long_edge_px = 4;

        let written = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::C41ColorNegative,
            8,
            6,
            16,
            &recipes,
            None,
            None,
        )
        .expect("all three outputs must write successfully");

        assert!(
            written.archive_path.as_ref().is_some_and(|path| path.is_file()),
            "archive file must exist on disk"
        );
        let positive_path = written.positive_path.expect("positive enabled by default");
        assert!(positive_path.is_file(), "positive file must exist on disk");
        let preview_path = written.preview_path.expect("preview enabled by default");
        assert!(preview_path.is_file(), "preview file must exist on disk");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn simulator_derivative_only_outputs_create_no_archive_file_or_directory() {
        let dir = unique_test_dir();
        let archive = dir.join("master-must-not-exist");
        let positive = dir.join("positive");
        let preview = dir.join("preview");
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.enabled = false;
        recipes.archive.destination = archive.display().to_string();
        recipes.positive.enabled = true;
        recipes.positive.destination = positive.display().to_string();
        recipes.preview.enabled = true;
        recipes.preview.destination = preview.display().to_string();

        let written = render_and_write_frame_with_processing(
            "sim-ls5000-0",
            1,
            &domain::ProcessingRecipe::default(),
            16,
            12,
            16,
            4000,
            true,
            &recipes,
            None,
            None,
        )
        .expect("derivative-only simulator scan succeeds");

        assert_eq!(written.archive_path, None);
        assert!(!archive.exists(), "disabled master must not create even its folder");
        assert!(written.positive_path.as_ref().is_some_and(|path| path.is_file()));
        assert!(written.preview_path.as_ref().is_some_and(|path| path.is_file()));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn archive_bytes_are_identical_with_and_without_an_approved_crop() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.join("Archive").display().to_string();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;

        let boundary = (1, 4);
        let alignment = domain::FrameAlignment::approved(1);

        let written_no_crop = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes,
            Some(boundary),
            None,
        )
        .expect("no-crop render must succeed");
        let archive_bytes_no_crop = std::fs::read(written_no_crop.archive_path.as_ref().expect("archive retained"))
            .expect("read archive without crop");

        // Use a fresh destination so the create-only archive write does not
        // collide; we are testing that the archive bytes stay identical, not
        // that a collision occurs.
        let mut recipes_cropped = recipes.clone();
        recipes_cropped.archive.destination = dir.join("ArchiveCropped").display().to_string();
        recipes_cropped.positive.destination = dir.join("PositiveCropped").display().to_string();
        let written_cropped = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes_cropped,
            Some(boundary),
            Some(&alignment),
        )
        .expect("cropped render must succeed");
        let archive_bytes_cropped = std::fs::read(written_cropped.archive_path.as_ref().expect("archive retained"))
            .expect("read archive with crop");

        assert_eq!(
            archive_bytes_no_crop, archive_bytes_cropped,
            "archive master must be byte-identical whether or not a crop is set"
        );

        // Sanity: the derived positive did actually get cropped.
        let positive_no_crop_len = std::fs::metadata(&written_no_crop.positive_path.unwrap())
            .map(|m| m.len())
            .unwrap_or(0);
        let positive_cropped_len = std::fs::metadata(&written_cropped.positive_path.unwrap())
            .map(|m| m.len())
            .unwrap_or(0);
        assert_ne!(
            positive_no_crop_len, positive_cropped_len,
            "cropped derivative must differ from uncropped derivative"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn derived_output_changes_when_crop_changes_without_rescan() {
        let dir = unique_test_dir();
        let mut recipes = domain::OutputRecipe::default();
        recipes.archive.destination = dir.join("Archive").display().to_string();
        recipes.positive.destination = dir.join("Positive").display().to_string();
        recipes.positive.file_format = domain::OutputFileFormat::Tiff;
        recipes.preview.enabled = false;

        let boundary = (1, 4);

        let mut recipes_a = recipes.clone();
        recipes_a.positive.destination = dir.join("PositiveA").display().to_string();
        let written_a = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes_a,
            Some(boundary),
            Some(&domain::FrameAlignment::approved(0)),
        )
        .expect("crop A");

        let mut recipes_b = recipes.clone();
        recipes_b.archive.destination = dir.join("ArchiveB").display().to_string();
        recipes_b.positive.destination = dir.join("PositiveB").display().to_string();
        let written_b = render_and_write_frame(
            "sim-ls5000-0",
            1,
            domain::FilmProcess::Positive,
            8,
            6,
            16,
            &recipes_b,
            Some(boundary),
            Some(&domain::FrameAlignment::approved(1)),
        )
        .expect("crop B");

        let bytes_a = std::fs::read(&written_a.positive_path.unwrap()).expect("read positive A");
        let bytes_b = std::fs::read(&written_b.positive_path.unwrap()).expect("read positive B");
        assert_ne!(
            bytes_a, bytes_b,
            "a different relative offset must produce different derived output"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn relative_offset_survives_a_different_absolute_detected_row() {
        // The core relative-intent property: the stored offset is relative to
        // the detected boundary, so when detection finds a different absolute
        // row, the same offset shifts the new boundary by the same amount.
        let offset_rows: i64 = 2;
        let boundary_a = (10, 20);
        let boundary_b = (15, 25);
        let (_, _, height_a) = resolve_aligned_crop(boundary_a.0, boundary_a.1, offset_rows, 30);
        let (top_b, _, height_b) = resolve_aligned_crop(boundary_b.0, boundary_b.1, offset_rows, 30);

        assert_eq!(top_b, boundary_b.0 + offset_rows as u32);
        assert_eq!(height_a, height_b, "same relative offset must preserve crop height");
    }

    #[test]
    fn unapproved_alignment_is_inert_for_derivatives() {
        let raw = generate_sim_frame("sim-ls5000-0", 1, 8, 6);
        let (out, w, h) = apply_alignment_crop(
            &raw,
            8,
            6,
            Some((1, 4)),
            Some(&domain::FrameAlignment::draft(2)),
        );
        assert_eq!(out, raw);
        assert_eq!(w, 8);
        assert_eq!(h, 6);
    }

    #[test]
    fn generate_synthetic_defects_is_deterministic_for_identical_arguments() {
        let capture = domain::CaptureRecipe::default();
        let processing = domain::ProcessingRecipe::default();
        let a = generate_synthetic_defects(5, &capture, &processing);
        let b = generate_synthetic_defects(5, &capture, &processing);
        assert_eq!(
            a, b,
            "identical arguments must reproduce a byte-identical Vec"
        );
        assert!(
            !a.is_empty(),
            "digital ICE is enabled by default; the generator must actually produce instances"
        );
    }

    #[test]
    fn generate_synthetic_defects_varies_with_frame_index() {
        let capture = domain::CaptureRecipe::default();
        let processing = domain::ProcessingRecipe::default();
        let one = generate_synthetic_defects(1, &capture, &processing);
        let two = generate_synthetic_defects(2, &capture, &processing);
        assert_ne!(
            one, two,
            "different frame indices must vary the generated defects"
        );
    }

    #[test]
    fn generate_synthetic_defects_is_empty_when_digital_ice_disabled() {
        let capture = domain::CaptureRecipe::default();
        let processing = domain::ProcessingRecipe {
            digital_ice_enabled: false,
            ..domain::ProcessingRecipe::default()
        };
        for frame_index in 1..=5 {
            let defects = generate_synthetic_defects(frame_index, &capture, &processing);
            assert!(
                defects.is_empty(),
                "frame {frame_index}: digital ICE off must never fabricate detections"
            );
        }
    }

    #[test]
    fn generate_synthetic_defects_stays_within_documented_bounds_across_many_frames() {
        let capture = domain::CaptureRecipe::default();
        let processing = domain::ProcessingRecipe::default();
        for frame_index in 1..=36 {
            let defects = generate_synthetic_defects(frame_index, &capture, &processing);
            let count = defects.len() as u32;
            assert!(
                (MIN_DEFECT_COUNT..=MAX_DEFECT_COUNT).contains(&count),
                "frame {frame_index}: defect count {count} out of [{MIN_DEFECT_COUNT}, {MAX_DEFECT_COUNT}]"
            );
            for instance in &defects {
                assert!(
                    (DEFECT_SEVERITY_FLOOR..=1.0).contains(&instance.severity),
                    "frame {frame_index}: severity {} out of bounds",
                    instance.severity
                );
                assert!(
                    (0.0..=1.0).contains(&instance.center_x)
                        && (0.0..=1.0).contains(&instance.center_y),
                    "frame {frame_index}: center ({}, {}) outside the unit square",
                    instance.center_x,
                    instance.center_y
                );
                assert_eq!(
                    instance.classification,
                    classify_defect_severity(instance.severity),
                    "frame {frame_index}: classification must agree with classify_defect_severity(severity)"
                );
                match &instance.kind {
                    domain::DefectKind::Scratch => {
                        let end_x = instance
                            .end_x
                            .expect("scratch instance must populate end_x");
                        let end_y = instance
                            .end_y
                            .expect("scratch instance must populate end_y");
                        assert!(
                            (0.0..=1.0).contains(&end_x),
                            "frame {frame_index}: end_x {end_x} out of bounds"
                        );
                        assert!(
                            (0.0..=1.0).contains(&end_y),
                            "frame {frame_index}: end_y {end_y} out of bounds"
                        );
                    }
                    domain::DefectKind::Dust => {
                        assert!(
                            instance.end_x.is_none(),
                            "frame {frame_index}: dust must omit end_x"
                        );
                        assert!(
                            instance.end_y.is_none(),
                            "frame {frame_index}: dust must omit end_y"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn classify_defect_severity_respects_threshold_boundary() {
        assert_eq!(
            classify_defect_severity(DEFECT_CLASSIFICATION_THRESHOLD - 0.01),
            domain::DefectClassification::WillCorrect
        );
        assert_eq!(
            classify_defect_severity(DEFECT_CLASSIFICATION_THRESHOLD),
            domain::DefectClassification::Uncertain
        );
        assert_eq!(
            classify_defect_severity(1.0),
            domain::DefectClassification::Uncertain
        );
        assert_eq!(
            classify_defect_severity(DEFECT_SEVERITY_FLOOR),
            domain::DefectClassification::WillCorrect
        );
    }

    // -----------------------------------------------------------------
    // Real defect-map clustering tests
    // -----------------------------------------------------------------

    fn map_from_grid(
        width: u32,
        height: u32,
        on_pixels: &[(u32, u32)],
        score: f32,
    ) -> ice::DefectMap {
        let mut scores = vec![0.0_f32; width as usize * height as usize];
        for &(x, y) in on_pixels {
            scores[y as usize * width as usize + x as usize] = score;
        }
        ice::DefectMap {
            width,
            height,
            score: scores,
        }
    }

    #[test]
    fn cluster_defect_map_all_zero_returns_empty() {
        let map = map_from_grid(30, 30, &[], 0.5);
        assert!(
            cluster_defect_map(&map).is_empty(),
            "all-zero map must yield no instances"
        );

        let empty = ice::DefectMap {
            width: 0,
            height: 0,
            score: Vec::new(),
        };
        assert!(
            cluster_defect_map(&empty).is_empty(),
            "0x0 map must yield no instances"
        );
    }

    #[test]
    fn cluster_defect_map_single_compact_block_returns_one_dust() {
        let mut pixels = Vec::new();
        for y in 10..13 {
            for x in 10..13 {
                pixels.push((x, y));
            }
        }
        let map = map_from_grid(30, 30, &pixels, 0.6);
        let instances = cluster_defect_map(&map);
        assert_eq!(
            instances.len(),
            1,
            "compact block must cluster into one instance"
        );

        let instance = &instances[0];
        assert_eq!(instance.id, 0);
        assert_eq!(instance.kind, domain::DefectKind::Dust);
        assert_eq!(
            instance.classification,
            domain::DefectClassification::WillCorrect
        );
        assert!(instance.end_x.is_none(), "dust must omit end_x");
        assert!(instance.end_y.is_none(), "dust must omit end_y");
        assert!(instance.center_x >= 10.0 / 30.0 && instance.center_x <= 12.0 / 30.0);
        assert!(instance.center_y >= 10.0 / 30.0 && instance.center_y <= 12.0 / 30.0);
        assert!(instance.radius > 0.0, "dust radius must be positive");
    }

    #[test]
    fn cluster_defect_map_single_diagonal_run_returns_one_scratch() {
        // A steep 1-pixel-wide diagonal run: ~15 pixels tall, ~5 pixels wide,
        // giving a bounding-box aspect ratio >= 3 so it classifies as Scratch.
        let mut pixels = Vec::new();
        for y in 0..15 {
            let x = y / 3;
            pixels.push((x, y));
        }
        let map = map_from_grid(30, 30, &pixels, 0.85);
        let instances = cluster_defect_map(&map);
        assert_eq!(
            instances.len(),
            1,
            "elongated run must cluster into one instance"
        );

        let instance = &instances[0];
        assert_eq!(instance.id, 0);
        assert_eq!(instance.kind, domain::DefectKind::Scratch);
        assert_eq!(
            instance.classification,
            domain::DefectClassification::Uncertain
        );
        assert!(instance.end_x.is_some(), "scratch must populate end_x");
        assert!(instance.end_y.is_some(), "scratch must populate end_y");
        assert!((0.0..=1.0).contains(&instance.center_x));
        assert!((0.0..=1.0).contains(&instance.center_y));
        assert!(instance.radius > 0.0, "scratch radius must be positive");
    }

    #[test]
    fn cluster_defect_map_two_disjoint_components_return_two_instances() {
        let mut dust_pixels = Vec::new();
        for y in 5..8 {
            for x in 5..8 {
                dust_pixels.push((x, y));
            }
        }
        let mut scratch_pixels = Vec::new();
        for x in 20..35 {
            scratch_pixels.push((x, 25));
        }

        let mut all_pixels = dust_pixels.clone();
        all_pixels.extend(&scratch_pixels);
        let map = map_from_grid(40, 40, &all_pixels, 0.7);
        let instances = cluster_defect_map(&map);
        assert_eq!(
            instances.len(),
            2,
            "disjoint components must stay separated"
        );
        assert_eq!(instances[0].id, 0);
        assert_eq!(instances[1].id, 1);

        let dust = instances
            .iter()
            .find(|i| i.kind == domain::DefectKind::Dust)
            .expect("dust component must be present");
        let scratch = instances
            .iter()
            .find(|i| i.kind == domain::DefectKind::Scratch)
            .expect("scratch component must be present");
        assert!(dust.end_x.is_none() && dust.end_y.is_none());
        assert!(scratch.end_x.is_some() && scratch.end_y.is_some());
    }

    #[test]
    fn cluster_defect_map_edge_component_is_clamped_to_unit_square() {
        let mut pixels = Vec::new();
        for y in 0..3 {
            for x in 0..3 {
                pixels.push((x, y));
            }
        }
        let map = map_from_grid(10, 10, &pixels, 0.5);
        let instances = cluster_defect_map(&map);
        assert_eq!(instances.len(), 1);
        let instance = &instances[0];
        assert!(
            (0.0..=1.0).contains(&instance.center_x),
            "center_x must be clamped"
        );
        assert!(
            (0.0..=1.0).contains(&instance.center_y),
            "center_y must be clamped"
        );
        assert!(
            instance.radius >= DEFECT_INSTANCE_RADIUS_MIN
                && instance.radius <= DEFECT_INSTANCE_RADIUS_MAX
        );
    }

    #[test]
    fn cluster_defect_map_is_deterministic_for_identical_inputs() {
        let mut pixels = Vec::new();
        for y in 5..8 {
            for x in 5..8 {
                pixels.push((x, y));
            }
        }
        let map = map_from_grid(20, 20, &pixels, 0.55);
        let a = cluster_defect_map(&map);
        let b = cluster_defect_map(&map);
        assert_eq!(a, b, "identical inputs must produce byte-identical output");
    }

    #[test]
    fn real_frame_defects_short_circuits_on_digital_ice_disabled_without_touching_disk() {
        let processing = domain::ProcessingRecipe {
            digital_ice_enabled: false,
            ..domain::ProcessingRecipe::default()
        };
        let result = real_frame_defects(
            std::path::Path::new("/nonexistent/does-not-exist-rgb.tif"),
            std::path::Path::new("/nonexistent/does-not-exist-ir.tif"),
            &processing,
        );
        assert_eq!(
            result,
            Ok(Vec::new()),
            "ICE off must short-circuit before disk I/O"
        );
    }
}
