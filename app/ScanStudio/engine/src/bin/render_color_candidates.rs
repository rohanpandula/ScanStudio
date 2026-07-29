//! `make render-color-candidates` CLI entry point: renders each corpus
//! slot's raw RGB capture into a nikonlook color candidate TIFF via the
//! pure-Rust `processing::nikonlook` port, writing to
//! `{candidate_dir}/color/acceptance_slotNN.tif` — the exact path
//! `bin/parity.rs`'s `score_color()` already looks for. Guards against a
//! candidate directory that resolves inside the read-only corpus before any
//! corpus discovery or file I/O happens (T-14-03, archive-immutability).

use std::path::PathBuf;

use scanstudio_engine::parity::candidate_dir_conflicts_with_corpus;
use scanstudio_engine::parity::corpus;
use scanstudio_engine::parity::image_io;
use scanstudio_engine::parity::render_color_candidate;
use scanstudio_engine::processing::nikonlook;

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
            "refusing to run: candidate directory {} is the corpus directory or resolves inside it ({}) — archive-immutability guard (T-14-03)",
            candidate_dir.display(),
            root.display()
        ));
    }

    let manifest = match corpus::discover(&root) {
        Ok(manifest) => manifest,
        Err(err) => fatal(&err.to_string()),
    };

    let bundle = match nikonlook::load_bundle() {
        Ok(bundle) => bundle,
        Err(err) => fatal(&format!("failed to load nikonlook bundle: {err}")),
    };

    let color_dir = candidate_dir.join("color");
    if let Err(err) = std::fs::create_dir_all(&color_dir) {
        fatal(&format!("failed to create {}: {err}", color_dir.display()));
    }

    for slot in &manifest.slots {
        let candidate = match render_color_candidate(slot, &bundle) {
            Ok(candidate) => candidate,
            Err(err) => fatal(&format!("failed to render color candidate for slot {}: {err}", slot.slot)),
        };

        let out_path = color_dir.join(format!("acceptance_slot{:02}.tif", slot.slot));
        if let Err(err) = image_io::write_rgb16(&out_path, &candidate) {
            fatal(&format!("failed to write {}: {err}", out_path.display()));
        }
        println!("slot {:02}: wrote {}", slot.slot, out_path.display());
    }

    println!(
        "rendered {} color candidate(s) to {}",
        manifest.slots.len(),
        color_dir.display()
    );
}
