//! `make render-geometry-candidates` CLI entry point: renders each corpus
//! slot's raw RGB capture into autocrop-ROI and fine-deskew geometry
//! candidates via the pure-Rust `processing::geometry` port, writing to
//! `{candidate_dir}/autocrop/acceptance_slotNN.json` and
//! `{candidate_dir}/deskew/acceptance_slotNN.tif` — the exact paths
//! `bin/parity.rs`'s `score_autocrop()`/`score_deskew()` already look for.
//! Guards against a candidate directory that resolves inside the read-only
//! corpus before any corpus discovery or file I/O happens (T-14-03/T-15-03,
//! archive-immutability guard reused unchanged from Phase 14).

use std::path::PathBuf;

use scanstudio_engine::parity::candidate_dir_conflicts_with_corpus;
use scanstudio_engine::parity::corpus;
use scanstudio_engine::parity::image_io;
use scanstudio_engine::parity::{render_autocrop_candidate, render_deskew_candidate};

struct Args {
    corpus: Option<PathBuf>,
    candidate_dir: Option<PathBuf>,
}

fn parse_args() -> Args {
    let mut corpus = None;
    let mut candidate_dir = None;
    let mut raw_args = std::env::args().skip(1);
    while let Some(arg) = raw_args.next() {
        match arg.as_str() {
            "--corpus" => corpus = raw_args.next().map(PathBuf::from),
            "--candidate-dir" => candidate_dir = raw_args.next().map(PathBuf::from),
            _ => {} // no other flags needed
        }
    }

    if corpus.is_none() {
        if let Ok(value) = std::env::var("SCANSTUDIO_PARITY_CORPUS") {
            if !value.is_empty() {
                corpus = Some(PathBuf::from(value));
            }
        }
    }
    if candidate_dir.is_none() {
        if let Ok(value) = std::env::var("SCANSTUDIO_PARITY_CANDIDATES") {
            if !value.is_empty() {
                candidate_dir = Some(PathBuf::from(value));
            }
        }
    }

    Args { corpus, candidate_dir }
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

    let Some(root) = args.corpus else {
        fatal(
            "no corpus path given — pass --corpus <path> or set SCANSTUDIO_PARITY_CORPUS (see app/ScanStudio/PARITY.md)",
        );
    };
    let Some(candidate_dir) = args.candidate_dir else {
        fatal(
            "no candidate directory given — pass --candidate-dir <path> or set SCANSTUDIO_PARITY_CANDIDATES",
        );
    };

    if candidate_dir_conflicts_with_corpus(&root, &candidate_dir) {
        fatal(&format!(
            "refusing to run: candidate directory {} is the corpus directory or resolves inside it ({}) — archive-immutability guard (T-14-03/T-15-03)",
            candidate_dir.display(),
            root.display()
        ));
    }

    let manifest = match corpus::discover(&root) {
        Ok(manifest) => manifest,
        Err(err) => fatal(&err.to_string()),
    };

    let autocrop_dir = candidate_dir.join("autocrop");
    let deskew_dir = candidate_dir.join("deskew");
    if let Err(err) = std::fs::create_dir_all(&autocrop_dir) {
        fatal(&format!("failed to create {}: {err}", autocrop_dir.display()));
    }
    if let Err(err) = std::fs::create_dir_all(&deskew_dir) {
        fatal(&format!("failed to create {}: {err}", deskew_dir.display()));
    }

    for slot in &manifest.slots {
        let (film_roi, image_roi) = match render_autocrop_candidate(slot) {
            Ok(rois) => rois,
            Err(err) => fatal(&format!(
                "failed to render autocrop candidate for slot {}: {err}",
                slot.slot
            )),
        };

        let autocrop_json = serde_json::json!({
            "film": {
                "y1": film_roi.y1,
                "y2": film_roi.y2,
                "x1": film_roi.x1,
                "x2": film_roi.x2,
            },
            "image": {
                "y1": image_roi.y1,
                "y2": image_roi.y2,
                "x1": image_roi.x1,
                "x2": image_roi.x2,
            },
        });
        let autocrop_path = autocrop_dir.join(format!("acceptance_slot{:02}.json", slot.slot));
        let serialized = match serde_json::to_string_pretty(&autocrop_json) {
            Ok(serialized) => serialized,
            Err(err) => fatal(&format!(
                "failed to serialize autocrop JSON for slot {}: {err}",
                slot.slot
            )),
        };
        if let Err(err) = std::fs::write(&autocrop_path, serialized) {
            fatal(&format!("failed to write {}: {err}", autocrop_path.display()));
        }
        println!("slot {:02}: wrote {}", slot.slot, autocrop_path.display());

        let deskew_candidate = match render_deskew_candidate(slot) {
            Ok(candidate) => candidate,
            Err(err) => fatal(&format!(
                "failed to render deskew candidate for slot {}: {err}",
                slot.slot
            )),
        };
        let deskew_path = deskew_dir.join(format!("acceptance_slot{:02}.tif", slot.slot));
        if let Err(err) = image_io::write_rgb16(&deskew_path, &deskew_candidate) {
            fatal(&format!("failed to write {}: {err}", deskew_path.display()));
        }
        println!("slot {:02}: wrote {}", slot.slot, deskew_path.display());
    }

    println!(
        "rendered {} autocrop + {} deskew candidate(s) to {}",
        manifest.slots.len(),
        manifest.slots.len(),
        candidate_dir.display()
    );
}
