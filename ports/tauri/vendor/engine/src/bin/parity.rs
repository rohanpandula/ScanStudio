//! `make parity` CLI entry point: discovers the corpus, scores every
//! module for every slot, and prints a human-readable table or `--json`
//! report. Hard-fails (nonzero exit) when `SCANSTUDIO_PARITY_CORPUS` is
//! unset or the corpus is empty — deliberately different from
//! `tests/parity_corpus.rs`'s clean-skip-with-message behavior under plain
//! `cargo test`, because this binary's whole purpose is running against
//! real data (Task 2, plan 13-02).

use std::path::{Path, PathBuf};

use scanstudio_engine::parity::candidates;
use scanstudio_engine::parity::corpus;
use scanstudio_engine::parity::image_io;
use scanstudio_engine::parity::scoring;
use scanstudio_engine::parity::{CorpusSlot, ModuleKind, ModuleScore, ModuleStatus, ParityReport};
use scanstudio_engine::processing::geometry;
use scanstudio_engine::processing::nikonlook;

struct Args {
    json: bool,
    candidate_dir: Option<PathBuf>,
}

fn parse_args() -> Args {
    let mut json = false;
    let mut candidate_dir = None;
    let mut raw_args = std::env::args().skip(1);
    while let Some(arg) = raw_args.next() {
        match arg.as_str() {
            "--json" => json = true,
            "--candidate-dir" => candidate_dir = raw_args.next().map(PathBuf::from),
            _ => {} // no other flags needed
        }
    }

    // Fall back to SCANSTUDIO_PARITY_CANDIDATES when --candidate-dir wasn't
    // passed explicitly — mirrors resolve_reference_path's colocated-then-
    // env-var fallback below, and is the only way `make parity` (whose
    // Makefile target does not forward a --candidate-dir flag) can ever see
    // real candidate files without hardcoding a path into the Makefile
    // (Phase 14, plan 14-02).
    if candidate_dir.is_none() {
        if let Ok(value) = std::env::var("SCANSTUDIO_PARITY_CANDIDATES") {
            if !value.is_empty() {
                candidate_dir = Some(PathBuf::from(value));
            }
        }
    }

    Args { json, candidate_dir }
}

/// Prints `message` to stderr and exits with code 1. Used for genuinely
/// unexpected failures (e.g. a reference/candidate file that exists but
/// fails to decode) — a controlled diagnostic exit, never a panic, per
/// T-13-01's "no panics on external file bytes" requirement.
fn fatal(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1);
}

fn main() {
    let args = parse_args();

    let root = match std::env::var("SCANSTUDIO_PARITY_CORPUS") {
        Ok(value) if !value.is_empty() => PathBuf::from(value),
        _ => {
            eprintln!(
                "SCANSTUDIO_PARITY_CORPUS is not set. Point it at the golden corpus directory (see app/ScanStudio/PARITY.md) and retry."
            );
            std::process::exit(1);
        }
    };

    let manifest = match corpus::discover(&root) {
        Ok(manifest) => manifest,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };

    if manifest.slots.is_empty() {
        eprintln!("Corpus at {} contained 0 slots — check the path.", root.display());
        std::process::exit(1);
    }

    // Load once: the color module's reference filename is derived from
    // whichever bundle version is actually loaded here, not hardcoded, so
    // this harness can never compare a candidate against a different
    // model's reference render (Finding 1 -- see score_color's own doc
    // comment). This is the exact same `load_bundle()` call
    // `render_color_candidates`/`parity::candidates::render_color_candidate`
    // use to render the candidates being scored.
    let bundle = match nikonlook::load_bundle() {
        Ok(bundle) => bundle,
        Err(err) => fatal(&format!("failed to load nikonlook bundle: {err}")),
    };

    let mut scores = Vec::new();
    for slot in &manifest.slots {
        scores.push(score_color(slot, &root, args.candidate_dir.as_deref(), &bundle.bundle_version));
        scores.push(score_ice(slot, &root, args.candidate_dir.as_deref()));
        scores.push(score_autocrop(slot, &root, args.candidate_dir.as_deref()));
        scores.push(score_deskew(slot, &root, args.candidate_dir.as_deref()));
    }

    let report = ParityReport {
        corpus_root: root,
        scores,
    };

    if args.json {
        match serde_json::to_string_pretty(&report) {
            Ok(json) => println!("{json}"),
            Err(err) => fatal(&format!("failed to serialize report as JSON: {err}")),
        }
    } else {
        print_human_table(&report);
    }

    std::process::exit(if report.has_any_failure() { 1 } else { 0 });
}

/// Color module: reference is
/// `{root}/acceptance_slot{NN}_reference_color_{bundle_version}.tif`, with a
/// fallback to
/// `$SCANSTUDIO_PARITY_REFS/acceptance_slot{NN}_reference_color_{bundle_version}.tif`
/// when the colocated file doesn't exist. `bundle_version` is
/// `main`'s own loaded `nikonlook::load_bundle().bundle_version` —
/// never hardcoded — because `render_color_candidates`/
/// `parity::candidates::render_color_candidate` render the candidate this
/// row scores with that exact same `load_bundle()` call. `COLOR_DELTA_E76_TOLERANCE`
/// (`scoring.rs`) is a port-fidelity tolerance: it exists to prove the Rust
/// port reproduces the Python reference of the SAME bundle, not to compare
/// two different models' output. Deriving the filename from the bundle
/// actually in use, instead of a fixed `nikonlook-v1` literal, is what
/// keeps that guarantee true after a bundle upgrade (e.g. `load_bundle()`
/// switching from `nikonlook-v1` to `nikonlook-v2`): a v2 candidate now
/// only ever looks for a v2 reference, and reports `no_reference` — not a
/// mismatched pass or fail — when that reference doesn't exist yet.
fn score_color(slot: &CorpusSlot, root: &Path, candidate_dir: Option<&Path>, bundle_version: &str) -> ModuleScore {
    let reference_filename = format!("acceptance_slot{:02}_reference_color_{bundle_version}.tif", slot.slot);
    let reference_path = resolve_reference_path(root, &reference_filename);

    let Some(reference_path) = reference_path else {
        return no_reference_score(
            ModuleKind::Color,
            slot.slot,
            "delta_e76",
            &format!(
                "no {bundle_version} reference render found (expected {reference_filename:?}, \
                 colocated with the corpus or under $SCANSTUDIO_PARITY_REFS); produce it with \
                 `bridge/tools/render_references.py --bundle <path-to-{bundle_version}-bundle> \
                 --corpus <corpus>` — see PARITY.md"
            ),
        );
    };

    let reference_provenance = Some(format!(
        "freshly rendered via render_references.py from nikonlook_core.py (bundle {bundle_version}) — see PARITY.md"
    ));

    let candidate_path = candidate_dir
        .map(|dir| dir.join("color").join(format!("acceptance_slot{:02}.tif", slot.slot)))
        .filter(|path| path.exists());

    let Some(candidate_path) = candidate_path else {
        return ModuleScore {
            module: ModuleKind::Color,
            slot: slot.slot,
            status: ModuleStatus::NoCandidate {
                reason: "reference exists; no Rust nikonlook port output found (Phase 14 not yet run)"
                    .to_string(),
            },
            metric_name: "delta_e76".to_string(),
            metric_value: None,
            threshold: None,
            reference_provenance,
        };
    };

    let reference_image = image_io::read_rgb16(&reference_path)
        .unwrap_or_else(|err| fatal(&format!("failed to read color reference {}: {err}", reference_path.display())));
    let candidate_image = image_io::read_rgb16(&candidate_path)
        .unwrap_or_else(|err| fatal(&format!("failed to read color candidate {}: {err}", candidate_path.display())));

    let color_score = scoring::score_color(&candidate_image, &reference_image)
        .unwrap_or_else(|err| fatal(&format!("score_color failed for slot {}: {err}", slot.slot)));

    let passes = color_score.max_channel_diff_u16 <= scoring::COLOR_PER_CHANNEL_TOLERANCE_U16
        && color_score.delta_e76 <= scoring::COLOR_DELTA_E76_TOLERANCE;

    ModuleScore {
        module: ModuleKind::Color,
        slot: slot.slot,
        status: if passes { ModuleStatus::Pass } else { ModuleStatus::Fail },
        metric_name: "delta_e76".to_string(),
        metric_value: Some(color_score.delta_e76),
        threshold: Some(scoring::COLOR_DELTA_E76_TOLERANCE),
        reference_provenance,
    }
}

/// Resolve a reference filename by trying the `root` directory first, then
/// falling back to `$SCANSTUDIO_PARITY_REFS` (if set). Returns `None` when
/// neither location has the file.
fn resolve_reference_path(root: &Path, filename: &str) -> Option<PathBuf> {
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

/// Autocrop module: reference is
/// `{root or SCANSTUDIO_PARITY_REFS}/acceptance_slot{NN}_reference_autocrop_negpy-v1.json`
/// (via `resolve_reference_path`, reused unchanged), parsed for its
/// `"image"` field (y1,y2,x1,x2) — Image mode only (see PARITY.md's
/// autocrop-mode-scope note: `ModuleKind::Autocrop` is not extended to
/// separate Film/Image variants; Film mode gets its own real corpus-driven
/// proof via a corpus-gated `cargo test`, not this row). Candidate is
/// `{candidate_dir}/autocrop/acceptance_slot{NN}.json`, same `"image"`
/// field. Both are converted to `scoring::Rect` and compared via
/// `scoring::score_crop_iou`.
fn score_autocrop(slot: &CorpusSlot, root: &Path, candidate_dir: Option<&Path>) -> ModuleScore {
    let reference_path = resolve_reference_path(
        root,
        &format!("acceptance_slot{:02}_reference_autocrop_negpy-v1.json", slot.slot),
    );

    let Some(reference_path) = reference_path else {
        return no_reference_score(
            ModuleKind::Autocrop,
            slot.slot,
            "crop_iou",
            "no autocrop reference found; run render_geometry_references.py (see PARITY.md)",
        );
    };

    let reference_provenance = Some(
        "freshly rendered via render_geometry_references.py from negpy.features.geometry.logic.get_autocrop_coords (Image mode, AUTO_FRAME_EDGE — NegPy's own default); Film mode is proven separately via a corpus-gated cargo test, not this row — see PARITY.md"
            .to_string(),
    );

    let candidate_path = candidate_dir
        .map(|dir| dir.join("autocrop").join(format!("acceptance_slot{:02}.json", slot.slot)))
        .filter(|path| path.exists());

    let Some(candidate_path) = candidate_path else {
        return ModuleScore {
            module: ModuleKind::Autocrop,
            slot: slot.slot,
            status: ModuleStatus::NoCandidate {
                reason: "reference exists; no Rust geometry port output found (Phase 15 not yet run)"
                    .to_string(),
            },
            metric_name: "crop_iou".to_string(),
            metric_value: None,
            threshold: None,
            reference_provenance,
        };
    };

    let reference_rect = read_roi_field(&reference_path, "image")
        .unwrap_or_else(|err| fatal(&format!("failed to read autocrop reference {}: {err}", reference_path.display())));
    let candidate_rect = read_roi_field(&candidate_path, "image")
        .unwrap_or_else(|err| fatal(&format!("failed to read autocrop candidate {}: {err}", candidate_path.display())));

    let crop_iou = scoring::score_crop_iou(candidate_rect, reference_rect);
    let passes = crop_iou >= scoring::AUTOCROP_IOU_THRESHOLD;

    ModuleScore {
        module: ModuleKind::Autocrop,
        slot: slot.slot,
        status: if passes { ModuleStatus::Pass } else { ModuleStatus::Fail },
        metric_name: "crop_iou".to_string(),
        metric_value: Some(crop_iou),
        threshold: Some(scoring::AUTOCROP_IOU_THRESHOLD),
        reference_provenance,
    }
}

/// Parses one named ROI object (`"film"` or `"image"`) out of an
/// autocrop-reference-or-candidate-shaped JSON file
/// (`{"film":{"y1":..,"y2":..,"x1":..,"x2":..},"image":{...}}`) into a
/// `scoring::Rect`. Never panics on malformed JSON (T-13-01) — every
/// failure path returns a descriptive `Err(String)` for the caller to
/// `fatal()` on.
fn read_roi_field(path: &Path, field: &str) -> Result<scoring::Rect, String> {
    let contents = std::fs::read_to_string(path)
        .map_err(|err| format!("failed to read {}: {err}", path.display()))?;
    let value: serde_json::Value = serde_json::from_str(&contents)
        .map_err(|err| format!("failed to parse {} as JSON: {err}", path.display()))?;
    let roi = value
        .get(field)
        .ok_or_else(|| format!("{} missing top-level \"{field}\" field", path.display()))?;

    let get_u32 = |key: &str| -> Result<u32, String> {
        roi.get(key)
            .and_then(|v| v.as_u64())
            .map(|v| v as u32)
            .ok_or_else(|| format!("{} .{field}.{key} missing or not a non-negative integer", path.display()))
    };
    let y1 = get_u32("y1")?;
    let y2 = get_u32("y2")?;
    let x1 = get_u32("x1")?;
    let x2 = get_u32("x2")?;

    Ok(scoring::Rect {
        x: x1,
        y: y1,
        width: x2.saturating_sub(x1),
        height: y2.saturating_sub(y1),
    })
}

/// Deskew module: reference sidecar is
/// `{root or SCANSTUDIO_PARITY_REFS}/acceptance_slot{NN}_reference_deskew_negpy-v1.json`
/// (via `resolve_reference_path`), containing the real Python-captured
/// `rotation_matrix` (2x3) plus width/height — a real, non-fabricated
/// artifact captured via `cv2.getRotationMatrix2D` at the fixed test angle,
/// decomposed into `reference_degrees` via `atan2(m[0][1], m[0][0])`.
/// Candidate existence is checked at
/// `{candidate_dir}/deskew/acceptance_slot{NN}.tif` (mirrors color's
/// no_candidate gate); `candidate_degrees` comes from calling
/// `processing::geometry::rotation_matrix_2x3` directly at the same fixed
/// test angle and the candidate image's own dimensions — NOT from a
/// candidate-side JSON file (`render_geometry_candidates` never writes one;
/// this computation is pure/stateless and input-independent). This is a
/// rotation-matrix angle-provenance check (matrix-construction correctness:
/// sign convention, degrees-to-radians conversion, center-point formula),
/// not a full geometric-correctness proof of the bilinear-resample step —
/// see PARITY.md and plan 15-02's `<deskew_metric_design_rationale>`.
fn score_deskew(slot: &CorpusSlot, root: &Path, candidate_dir: Option<&Path>) -> ModuleScore {
    let reference_path = resolve_reference_path(
        root,
        &format!("acceptance_slot{:02}_reference_deskew_negpy-v1.json", slot.slot),
    );

    let Some(reference_path) = reference_path else {
        return no_reference_score(
            ModuleKind::Deskew,
            slot.slot,
            "deskew_angle_degrees",
            "no deskew reference found; run render_geometry_references.py (see PARITY.md)",
        );
    };

    let reference_provenance = Some(format!(
        "freshly rendered via render_geometry_references.py at the fixed, documented test angle ({} degrees) — measures rotation-matrix/detection-parity (matrix-construction correctness), not full geometric correctness of the resample step; see PARITY.md and plan 15-02's deskew_metric_design_rationale",
        candidates::GEOMETRY_TEST_ANGLE_DEGREES
    ));

    let candidate_path = candidate_dir
        .map(|dir| dir.join("deskew").join(format!("acceptance_slot{:02}.tif", slot.slot)))
        .filter(|path| path.exists());

    let Some(candidate_path) = candidate_path else {
        return ModuleScore {
            module: ModuleKind::Deskew,
            slot: slot.slot,
            status: ModuleStatus::NoCandidate {
                reason: "reference exists; no Rust geometry port output found (Phase 15 not yet run)"
                    .to_string(),
            },
            metric_name: "deskew_angle_degrees".to_string(),
            metric_value: None,
            threshold: None,
            reference_provenance,
        };
    };

    let reference_matrix = read_rotation_matrix_json(&reference_path)
        .unwrap_or_else(|err| fatal(&format!("failed to read deskew reference {}: {err}", reference_path.display())));
    let reference_degrees = reference_matrix[0][1].atan2(reference_matrix[0][0]).to_degrees();

    let candidate_image = image_io::read_rgb16(&candidate_path)
        .unwrap_or_else(|err| fatal(&format!("failed to read deskew candidate {}: {err}", candidate_path.display())));
    let candidate_matrix = geometry::rotation_matrix_2x3(
        candidates::GEOMETRY_TEST_ANGLE_DEGREES,
        candidate_image.width,
        candidate_image.height,
    );
    let candidate_degrees = candidate_matrix[0][1].atan2(candidate_matrix[0][0]).to_degrees();

    let angle_diff = scoring::score_deskew_angle(candidate_degrees, reference_degrees);
    let passes = angle_diff <= scoring::DESKEW_ANGLE_EPSILON_DEGREES;

    ModuleScore {
        module: ModuleKind::Deskew,
        slot: slot.slot,
        status: if passes { ModuleStatus::Pass } else { ModuleStatus::Fail },
        metric_name: "deskew_angle_degrees".to_string(),
        metric_value: Some(angle_diff),
        threshold: Some(scoring::DESKEW_ANGLE_EPSILON_DEGREES),
        reference_provenance,
    }
}

/// Parses `{"applied_angle_degrees":..,"width":..,"height":..,"rotation_matrix":[[..],[..]]}`
/// (the shape `render_geometry_references.py` writes) into a `[[f64; 3]; 2]`
/// matrix. Never panics on malformed JSON (T-13-01).
fn read_rotation_matrix_json(path: &Path) -> Result<[[f64; 3]; 2], String> {
    let contents = std::fs::read_to_string(path)
        .map_err(|err| format!("failed to read {}: {err}", path.display()))?;
    let value: serde_json::Value = serde_json::from_str(&contents)
        .map_err(|err| format!("failed to parse {} as JSON: {err}", path.display()))?;
    let matrix = value
        .get("rotation_matrix")
        .and_then(|v| v.as_array())
        .ok_or_else(|| format!("{} missing top-level \"rotation_matrix\" array", path.display()))?;
    if matrix.len() != 2 {
        return Err(format!("{} rotation_matrix must have exactly 2 rows", path.display()));
    }

    let mut out = [[0.0f64; 3]; 2];
    for (row_idx, row) in matrix.iter().enumerate() {
        let row_values = row
            .as_array()
            .ok_or_else(|| format!("{} rotation_matrix row {row_idx} is not an array", path.display()))?;
        if row_values.len() != 3 {
            return Err(format!(
                "{} rotation_matrix row {row_idx} must have exactly 3 values",
                path.display()
            ));
        }
        for (col_idx, value) in row_values.iter().enumerate() {
            out[row_idx][col_idx] = value.as_f64().ok_or_else(|| {
                format!("{} rotation_matrix[{row_idx}][{col_idx}] is not a number", path.display())
            })?;
        }
    }

    Ok(out)
}

/// ICE module: prefers a Legacy-only reference
/// (`acceptance_slot{NN}_reference_ice_legacy-v1.png`, resolved via
/// `resolve_reference_path` — colocated with the corpus, falling back to
/// `$SCANSTUDIO_PARITY_REFS` — mirroring `score_color`/`score_autocrop`/
/// `score_deskew`'s existing pattern exactly), falling back to the slot's
/// own `repaired_synth_mask_path` (the corpus-bundled HYBRID disclosure
/// mask, Phase 13) only when no Legacy-only reference exists yet.
///
/// Plan 16-03's own real, self-measured investigation
/// (`reference_mask_coverage_sanity_check` in `engine/tests/ice_candidates.rs`,
/// run against the real six-slot corpus) found the hybrid mask
/// structurally unrepresentative of this port's Legacy-only output: on
/// slot 1 the hybrid mask covers 7.604681% of the frame while the Legacy
/// port's own `DefectMap` covers 0.336715% (a ~22.6x size mismatch in the
/// OPPOSITE direction from this plan's original hypothesis), and the
/// measured Jaccard agreement between them is 0.000176 — roughly 250x
/// below even the best-case floor if the smaller mask were a perfect
/// spatial subset of the larger one, meaning the two masks disagree about
/// WHERE defects are, not just how many. `render_ice_references.py`
/// (external, mirrors `render_references.py`/`render_geometry_references.py`'s
/// exact shape — see PARITY.md §3) generates the missing Legacy-only
/// reference by invoking the real `portable_digital_ice` v0.3.1's own
/// detection primitives directly.
fn score_ice(slot: &CorpusSlot, root: &Path, candidate_dir: Option<&Path>) -> ModuleScore {
    let legacy_reference_path = resolve_reference_path(
        root,
        &format!("acceptance_slot{:02}_reference_ice_legacy-v1.png", slot.slot),
    );

    let (reference_path, reference_provenance) = if let Some(path) = legacy_reference_path {
        (
            Some(path),
            Some(
                "freshly rendered via render_ice_references.py, invoking the real portable_digital_ice v0.3.1's own response-LUT/auxiliary/continuous-score detection primitives directly (Legacy/classical mode only, single-acquisition base_primary substitute) — see PARITY.md §3 for the real measured evidence that motivated replacing the corpus-bundled hybrid disclosure mask"
                    .to_string(),
            ),
        )
    } else if let Some(path) = slot.repaired_synth_mask_path.clone() {
        (
            Some(path),
            Some(
                "corpus-bundled disclosure mask, HYBRID mode (digital-fauxice v0.3.0) — no Legacy-only reference found for this slot (run render_ice_references.py, see PARITY.md). Plan 16-03's own measurement found this hybrid mask structurally unrepresentative of Legacy-only output (Jaccard ~0.000176 against the Legacy port on slot 1) — treat a score against this fallback as informational only, not a real regression signal"
                    .to_string(),
            ),
        )
    } else {
        (None, None)
    };

    let Some(reference_path) = reference_path else {
        return no_reference_score(
            ModuleKind::Ice,
            slot.slot,
            "mask_jaccard",
            "no ICE reference found for this slot — neither a Legacy-only reference (render_ice_references.py) nor a corpus-bundled disclosure mask exists",
        );
    };

    let candidate_path = candidate_dir
        .map(|dir| dir.join("ice").join(format!("acceptance_slot{:02}.png", slot.slot)))
        .filter(|path| path.exists());

    let Some(candidate_path) = candidate_path else {
        return ModuleScore {
            module: ModuleKind::Ice,
            slot: slot.slot,
            status: ModuleStatus::NoCandidate {
                reason: "reference exists; no Rust Legacy ICE port output found (Phase 16 not yet run)"
                    .to_string(),
            },
            metric_name: "mask_jaccard".to_string(),
            metric_value: None,
            threshold: None,
            reference_provenance,
        };
    };

    let reference_mask = image_io::read_mask_normalized(&reference_path)
        .unwrap_or_else(|err| fatal(&format!("failed to read ICE reference mask {}: {err}", reference_path.display())));
    let candidate_mask = image_io::read_mask_normalized(&candidate_path)
        .unwrap_or_else(|err| fatal(&format!("failed to read ICE candidate mask {}: {err}", candidate_path.display())));

    let agreement = scoring::score_ice_mask_agreement(&candidate_mask, &reference_mask, 0.5)
        .unwrap_or_else(|err| fatal(&format!("score_ice_mask_agreement failed for slot {}: {err}", slot.slot)));

    let passes = agreement >= scoring::ICE_MASK_AGREEMENT_THRESHOLD;

    ModuleScore {
        module: ModuleKind::Ice,
        slot: slot.slot,
        status: if passes { ModuleStatus::Pass } else { ModuleStatus::Fail },
        metric_name: "mask_jaccard".to_string(),
        metric_value: Some(agreement),
        threshold: Some(scoring::ICE_MASK_AGREEMENT_THRESHOLD),
        reference_provenance,
    }
}

fn no_reference_score(module: ModuleKind, slot: u8, metric_name: &str, reason: &str) -> ModuleScore {
    ModuleScore {
        module,
        slot,
        status: ModuleStatus::NoReference {
            reason: reason.to_string(),
        },
        metric_name: metric_name.to_string(),
        metric_value: None,
        threshold: None,
        reference_provenance: None,
    }
}

fn print_human_table(report: &ParityReport) {
    println!("module\tslot\tstatus\tmetric_name\tmetric_value\tthreshold\treference_provenance");
    for score in &report.scores {
        let (status_str, reason) = match &score.status {
            ModuleStatus::Pass => ("pass", String::new()),
            ModuleStatus::Fail => ("fail", String::new()),
            ModuleStatus::NoReference { reason } => ("no_reference", reason.clone()),
            ModuleStatus::NoCandidate { reason } => ("no_candidate", reason.clone()),
        };
        let metric_value = score
            .metric_value
            .map(|value| format!("{value:.4}"))
            .unwrap_or_else(|| "-".to_string());
        let threshold = score
            .threshold
            .map(|value| format!("{value:.4}"))
            .unwrap_or_else(|| "-".to_string());
        // Prefer reference_provenance when present (a real reference
        // exists); fall back to the status's own reason so the table never
        // prints a blank note column.
        let note = score.reference_provenance.clone().unwrap_or(reason);
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}",
            score.module, score.slot, status_str, score.metric_name, metric_value, threshold, note
        );
    }

    // A per-row `no_reference`/`fail` in a long table is easy to scan past.
    // `report.has_any_failure()` is what actually decides this run's exit
    // code (see its own doc comment — `no_reference` counts), so the
    // summary below must count exactly the same statuses it does, or a
    // human reading this table could see "FAILED" without the row that
    // caused it, or see silence and miss a nonzero exit.
    if report.has_any_failure() {
        let fail_count = report
            .scores
            .iter()
            .filter(|score| matches!(score.status, ModuleStatus::Fail))
            .count();
        let no_reference_count = report
            .scores
            .iter()
            .filter(|score| matches!(score.status, ModuleStatus::NoReference { .. }))
            .count();
        println!(
            "\nFAILED: {fail_count} fail, {no_reference_count} no_reference (a module reporting \
             no_reference was never actually compared — see PARITY.md §3/§7 for how to render \
             the missing reference)"
        );
    }
}
