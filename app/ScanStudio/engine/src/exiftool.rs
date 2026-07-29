//! ExifTool capability detection, target resolution, and argument-array
//! construction for META-03. Every function here is plain and
//! server-independent — no `server.rs`/NDJSON dependency, so Phase 6.1's
//! headless CLI can link this crate in-process and call
//! `detect_exiftool`/`build_exiftool_arguments` directly. This module never
//! mutates the archive file itself (`assert_no_archive_target` is the
//! structural guard that enforces this) and never shells out through
//! anything but `std::process::Command`'s argument-array form — no `sh -c`,
//! no string interpolation, anywhere in this file.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::domain::{EngineError, FilmProcess, MetadataSet, PartialDate, ProjectFrame, ScanProject};
use crate::protocol::ErrorCode;

// ---------------------------------------------------------------------
// Detection
// ---------------------------------------------------------------------

/// Result of probing for a usable ExifTool binary. `path`/`version` are
/// always present as explicit `null` when `available` is `false` (never
/// omitted), mirroring `protocol::ScannerStatus`'s own "always-present,
/// sometimes-null" convention for optional-but-meaningful fields.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ExifToolDetection {
    pub available: bool,
    pub path: Option<String>,
    pub version: Option<String>,
}

fn absent_detection() -> ExifToolDetection {
    ExifToolDetection {
        available: false,
        path: None,
        version: None,
    }
}

/// Overrides every other candidate when set to a non-empty (trimmed)
/// value — mirrors `server.rs`'s own `SCANSTUDIO_BRIDGE_CMD` convention
/// (unset AND set-but-empty both mean "not configured").
const EXIFTOOL_PATH_ENV_VAR: &str = "SCANSTUDIO_EXIFTOOL_PATH";

/// Detects whether ExifTool is installed and usable. Tries, in order:
/// `SCANSTUDIO_EXIFTOOL_PATH` (if set to a non-empty value, that exact path
/// only — no fallback if it fails), then the bare `"exiftool"` name resolved
/// by the child process's `PATH`. The first candidate that spawns
/// `<candidate> -ver` successfully (exit 0, stdout captured as the version
/// string) wins.
///
/// Every candidate is probed read-only (`-ver` only, never a write-capable
/// invocation). Total failure — ExifTool genuinely absent, or every
/// candidate unusable — degrades to `ExifToolDetection { available: false,
/// .. }`; this function never panics and never returns an `Err`, matching
/// META-03's "detection degrades gracefully" requirement.
pub fn detect_exiftool() -> ExifToolDetection {
    if let Ok(env_path) = std::env::var(EXIFTOOL_PATH_ENV_VAR) {
        if !env_path.trim().is_empty() {
            return probe_candidate(&env_path).unwrap_or_else(absent_detection);
        }
    }
    probe_candidate("exiftool").unwrap_or_else(absent_detection)
}

/// Spawns `<candidate> -ver` and returns `Some(..available: true..)` on a
/// clean exit; `None` on any spawn failure or non-zero exit. Never panics.
fn probe_candidate(candidate: &str) -> Option<ExifToolDetection> {
    let output = std::process::Command::new(candidate)
        .arg("-ver")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Some(ExifToolDetection {
        available: true,
        path: Some(candidate.to_string()),
        version: Some(version),
    })
}

// ---------------------------------------------------------------------
// Frame lookup, metadata resolution, target resolution
// ---------------------------------------------------------------------

/// Shared frame lookup: `InvalidParams` (mirroring `manifest::mutate_frame`'s
/// own error text) if no frame with this index exists in `project`.
fn find_frame(project: &ScanProject, frame_index: u32) -> Result<&ProjectFrame, EngineError> {
    project
        .frames
        .iter()
        .find(|f| f.index == frame_index)
        .ok_or_else(|| {
            EngineError::new(
                ErrorCode::InvalidParams,
                format!("frame index {frame_index} does not exist in this project"),
            )
        })
}

/// Resolves the metadata a write to `frame_index` should actually use: the
/// frame's own `metadata_override` if set, else the project's roll-wide
/// `roll_metadata` — the same override-then-roll-default resolution
/// `server.rs`'s other per-frame methods already apply.
pub fn resolve_effective_metadata(
    project: &ScanProject,
    frame_index: u32,
) -> Result<MetadataSet, EngineError> {
    let frame = find_frame(project, frame_index)?;
    Ok(frame
        .metadata_override
        .clone()
        .unwrap_or_else(|| project.roll_metadata.clone()))
}

/// Resolves the target file list for `frame_index`: (1) the retained
/// archive's sibling XMP sidecar (when an archive path is known); (2) the
/// positive derivative, if the frame's latest receipt wrote one; (3) the
/// preview derivative, if the frame's latest receipt wrote one. "The
/// frame's latest receipt" is `frame.receipts.last()` — receipts are
/// pushed in chronological order by `manifest::persist_frame_receipt`, so
/// `.last()` is the most recent attempt's outputs.
///
/// A frame with no receipts at all (never successfully scanned), or whose
/// latest receipt has no recorded `outputs` (nothing was ever written),
/// has zero targets — `Ok(vec![])`, never an error. This is the correct
/// "nothing to tag yet" shape, not an anomaly.
pub fn resolve_targets(project: &ScanProject, frame_index: u32) -> Result<Vec<PathBuf>, EngineError> {
    let frame = find_frame(project, frame_index)?;
    let Some(latest_receipt) = frame.receipts.last() else {
        return Ok(Vec::new());
    };
    let Some(outputs) = latest_receipt.outputs.as_ref() else {
        return Ok(Vec::new());
    };

    let mut targets = outputs
        .archive_path
        .as_ref()
        .map(|archive_path| PathBuf::from(archive_path).with_extension("xmp"))
        .into_iter()
        .collect::<Vec<_>>();
    if let Some(positive_path) = &outputs.positive_path {
        targets.push(PathBuf::from(positive_path));
    }
    if let Some(preview_path) = &outputs.preview_path {
        targets.push(PathBuf::from(preview_path));
    }
    Ok(targets)
}

/// Structural guard: `Err` if `archive_path` appears literally among
/// `targets`. Called unconditionally before both the preview-building
/// method and the apply method do anything else with a target list — by
/// construction, `resolve_targets` above never includes the archive path
/// itself (only its `.xmp`-transformed sibling and derivative paths), so
/// this should never actually trip in normal operation; it exists as an
/// independently-testable invariant, not a convention trusted to hold on
/// its own.
pub fn assert_no_archive_target(targets: &[PathBuf], archive_path: &Path) -> Result<(), EngineError> {
    if targets.iter().any(|target| target == archive_path) {
        Err(EngineError::new(
            ErrorCode::Internal,
            "refusing to target the archive file",
        ))
    } else {
        Ok(())
    }
}

// ---------------------------------------------------------------------
// Argument-array construction
// ---------------------------------------------------------------------

/// Maps a `FilmProcess` to the exact display label this app's UI already
/// uses (`ProjectLauncherView.swift`'s `filmProcessLabel`) — kept
/// byte-for-byte identical so a written `-UserComment` never drifts from
/// what the app itself calls each process.
fn process_display_name(process: FilmProcess) -> &'static str {
    match process {
        FilmProcess::Positive => "Positive",
        FilmProcess::C41ColorNegative => "C-41 Color Negative",
        FilmProcess::BwNegative => "B&W Negative",
        FilmProcess::Kodachrome => "Kodachrome",
    }
}

/// Composes the `-UserComment` value from `film_stock`/`process`: both
/// populated -> `"{film_stock} ({process label})"`; exactly one populated
/// -> just that field's own value, undecorated; neither populated ->
/// `None` (the caller omits the argument entirely rather than writing an
/// empty comment).
fn compose_user_comment(film_stock: Option<&str>, process: Option<FilmProcess>) -> Option<String> {
    match (film_stock, process) {
        (Some(stock), Some(process)) => Some(format!("{stock} ({})", process_display_name(process))),
        (Some(stock), None) => Some(stock.to_string()),
        (None, Some(process)) => Some(process_display_name(process).to_string()),
        (None, None) => None,
    }
}

/// Builds the `-XMP-photoshop:DateCreated` argument per `PartialDate`'s
/// variant — the only date tag this module ever writes. The bare EXIF
/// `DateTimeOriginal`/`-DateCreated` tags reject a placeholder day/month
/// (verified against the real binary: `Day '00' out of range`, exit 1,
/// nothing written); `-XMP-photoshop:DateCreated` natively accepts
/// ISO-8601 partial precision. Never fabricates a day or month component:
/// `MonthOnly` writes `YYYY-MM` only, `YearOnly` writes `YYYY` only, and
/// `Unknown`/`None` produce no argument at all — not an empty string, not
/// a placeholder.
fn build_date_argument(date: Option<&PartialDate>) -> Option<String> {
    match date {
        Some(PartialDate::Exact { date }) => Some(format!("-XMP-photoshop:DateCreated={date}")),
        Some(PartialDate::MonthOnly { year, month }) => {
            Some(format!("-XMP-photoshop:DateCreated={year:04}-{month:02}"))
        }
        Some(PartialDate::YearOnly { year }) => {
            Some(format!("-XMP-photoshop:DateCreated={year:04}"))
        }
        Some(PartialDate::Unknown) | None => None,
    }
}

/// Pure, deterministic argument-array builder: every populated
/// `MetadataSet` field becomes exactly one `-Tag=value` argument
/// (`keywords` becomes one `-Subject+=value` per entry, the `+=` append
/// form); every `None`/empty field is simply absent from the returned
/// vector — never an empty-string argument, never a placeholder. Field
/// order is fixed (a sequence of explicit `if let Some(..)` pushes, never a
/// `HashMap`), so the same `MetadataSet` produces the byte-identical
/// `Vec<String>` on every call.
pub fn build_exiftool_arguments(metadata: &MetadataSet) -> Vec<String> {
    let mut arguments = Vec::new();

    if let Some(camera) = &metadata.camera {
        arguments.push(format!("-Model={camera}"));
    }
    if let Some(lens) = &metadata.lens {
        arguments.push(format!("-LensModel={lens}"));
    }
    if let Some(comment) = compose_user_comment(metadata.film_stock.as_deref(), metadata.process) {
        arguments.push(format!("-UserComment={comment}"));
    }
    if let Some(iso) = metadata.iso {
        arguments.push(format!("-ISO={iso}"));
    }
    if let Some(date_argument) = build_date_argument(metadata.date.as_ref()) {
        arguments.push(date_argument);
    }
    if let Some(location) = &metadata.location {
        arguments.push(format!("-Location={location}"));
    }
    if let Some(photographer) = &metadata.photographer {
        arguments.push(format!("-Artist={photographer}"));
    }
    if let Some(copyright) = &metadata.copyright {
        arguments.push(format!("-Copyright={copyright}"));
    }
    if let Some(roll_id) = &metadata.roll_id {
        arguments.push(format!("-Identifier={roll_id}"));
    }
    if let Some(frame_number) = metadata.frame_number {
        arguments.push(format!("-ImageNumber={frame_number}"));
    }
    if let Some(notes) = &metadata.notes {
        arguments.push(format!("-Description={notes}"));
    }
    for keyword in &metadata.keywords {
        arguments.push(format!("-Subject+={keyword}"));
    }

    arguments
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{MediaCarrier, OutputRecipe, ScanReceipt, WrittenOutputs};

    fn project_with_one_frame() -> ScanProject {
        ScanProject {
            schema_version: 4,
            id: "proj-exiftool-test".to_string(),
            name: "ExifTool Test".to_string(),
            carrier: MediaCarrier::Strip6,
            frame_count: 1,
            film_process: FilmProcess::Positive,
            recipes: OutputRecipe::default(),
            roll_metadata: MetadataSet::default(),
            created_at: "2026-07-24T00:00:00Z".to_string(),
            frames: vec![ProjectFrame {
                index: 1,
                excluded: false,
                capture_override: None,
                processing_override: None,
                output_override: None,
                alignment: None,
                metadata_override: None,
                receipts: vec![],
            }],
        }
    }

    // Test 1: every field populated produces the exact expected sequence.
    #[test]
    fn build_exiftool_arguments_with_every_field_populated_matches_the_verified_mapping() {
        let metadata = MetadataSet {
            camera: Some("Nikon F100".to_string()),
            lens: Some("50mm f/1.4".to_string()),
            film_stock: Some("Kodak Portra 400".to_string()),
            process: Some(FilmProcess::C41ColorNegative),
            iso: Some(400),
            date: Some(PartialDate::Exact {
                date: "2026-07-22".to_string(),
            }),
            location: Some("Home".to_string()),
            photographer: Some("Rohan".to_string()),
            copyright: Some("(c) 2026".to_string()),
            roll_id: Some("roll-1".to_string()),
            frame_number: Some(5),
            notes: Some("test notes".to_string()),
            keywords: vec!["family".to_string(), "vacation".to_string()],
        };

        let arguments = build_exiftool_arguments(&metadata);

        assert_eq!(
            arguments,
            vec![
                "-Model=Nikon F100".to_string(),
                "-LensModel=50mm f/1.4".to_string(),
                "-UserComment=Kodak Portra 400 (C-41 Color Negative)".to_string(),
                "-ISO=400".to_string(),
                "-XMP-photoshop:DateCreated=2026-07-22".to_string(),
                "-Location=Home".to_string(),
                "-Artist=Rohan".to_string(),
                "-Copyright=(c) 2026".to_string(),
                "-Identifier=roll-1".to_string(),
                "-ImageNumber=5".to_string(),
                "-Description=test notes".to_string(),
                "-Subject+=family".to_string(),
                "-Subject+=vacation".to_string(),
            ]
        );
    }

    // Test 2: month-only date has no day component anywhere.
    #[test]
    fn build_exiftool_arguments_month_only_date_has_no_day_component() {
        let metadata = MetadataSet {
            date: Some(PartialDate::MonthOnly { year: 2026, month: 7 }),
            ..MetadataSet::default()
        };
        let arguments = build_exiftool_arguments(&metadata);
        assert_eq!(
            arguments,
            vec!["-XMP-photoshop:DateCreated=2026-07".to_string()]
        );
    }

    // Test 3: year-only date has no month or day component anywhere.
    #[test]
    fn build_exiftool_arguments_year_only_date_has_no_month_or_day_component() {
        let metadata = MetadataSet {
            date: Some(PartialDate::YearOnly { year: 2026 }),
            ..MetadataSet::default()
        };
        let arguments = build_exiftool_arguments(&metadata);
        assert_eq!(
            arguments,
            vec!["-XMP-photoshop:DateCreated=2026".to_string()]
        );
    }

    // Test 4: None and Unknown both produce zero DateCreated-prefixed
    // arguments — not just an empty string.
    #[test]
    fn build_exiftool_arguments_omits_date_created_entirely_when_date_is_none_or_unknown() {
        let no_date = MetadataSet {
            date: None,
            ..MetadataSet::default()
        };
        let unknown_date = MetadataSet {
            date: Some(PartialDate::Unknown),
            ..MetadataSet::default()
        };
        for metadata in [no_date, unknown_date] {
            let arguments = build_exiftool_arguments(&metadata);
            assert!(
                arguments.iter().all(|arg| !arg.contains("DateCreated")),
                "no argument may reference DateCreated: {arguments:?}"
            );
        }
    }

    // Test 5: every field None/empty produces an empty Vec<String>.
    #[test]
    fn build_exiftool_arguments_with_every_field_absent_is_empty() {
        let arguments = build_exiftool_arguments(&MetadataSet::default());
        assert!(
            arguments.is_empty(),
            "expected no arguments, got {arguments:?}"
        );
    }

    // Test 6: assert_no_archive_target rejects a sneaked-in archive path
    // and accepts a clean target list.
    #[test]
    fn assert_no_archive_target_rejects_the_archive_path_and_accepts_a_clean_list() {
        let archive_path = PathBuf::from("/tmp/scanstudio-test/Archive/Archive_0001.tiff");
        let sneaked_in = vec![
            PathBuf::from("/tmp/scanstudio-test/Archive/Archive_0001.xmp"),
            archive_path.clone(),
        ];
        let err = assert_no_archive_target(&sneaked_in, &archive_path).unwrap_err();
        assert_eq!(err.code, ErrorCode::Internal);

        let clean = vec![PathBuf::from("/tmp/scanstudio-test/Archive/Archive_0001.xmp")];
        assert!(assert_no_archive_target(&clean, &archive_path).is_ok());
    }

    // Test 7: a frame with an empty receipts vec resolves to Ok(vec![]),
    // never an error.
    #[test]
    fn resolve_targets_on_a_frame_with_no_receipts_returns_an_empty_list_not_an_error() {
        let project = project_with_one_frame();
        let targets = resolve_targets(&project, 1).expect("a receiptless frame must not error");
        assert!(targets.is_empty());
    }

    #[test]
    fn derivative_only_receipt_targets_no_archive_xmp() {
        let mut project = project_with_one_frame();
        project.frames[0].receipts.push(ScanReceipt {
            job_id: "job-derivative-only".into(),
            frame_index: 1,
            started_at: "2026-07-27T00:00:00Z".into(),
            duration_ms: 0,
            passes: 1,
            resolution_dpi: 4000,
            bit_depth: 16,
            channels: "rgb".into(),
            engine_version: "test".into(),
            device_id: "test".into(),
            simulated: true,
            settings_fingerprint: "0000000000000000".into(),
            processing: None,
            output: None,
            outputs: Some(WrittenOutputs {
                archive_path: None,
                positive_path: Some("/Scans/Positive/ScanStudio1.tif".into()),
                preview_path: Some("/Scans/Preview/ScanStudio1.jpg".into()),
            }),
            rgb_path: None,
            ir_path: None,
            storage_transform: None,
            meter_rgbi_path: None,
            hardware_telemetry: None,
            nikonlook: None,
        });
        let targets = resolve_targets(&project, 1).expect("derivative-only receipt resolves");
        assert_eq!(targets, vec![
            PathBuf::from("/Scans/Positive/ScanStudio1.tif"),
            PathBuf::from("/Scans/Preview/ScanStudio1.jpg"),
        ]);
        assert!(targets.iter().all(|path| path.extension().is_none_or(|ext| ext != "xmp")));
    }

    // Test 8 (real-binary integration, gated): skips gracefully when
    // ExifTool is not installed on the machine running the test suite —
    // never hard-fails cargo test in an environment without it. Runs for
    // real (not mocked) whenever it is available.
    #[test]
    fn build_exiftool_arguments_round_trips_through_the_real_installed_binary() {
        let detection = detect_exiftool();
        if !detection.available {
            eprintln!(
                "exiftool not found on this machine (no candidate spawned -ver successfully) — skipping the real-binary integration test"
            );
            return;
        }
        let exiftool_path = detection.path.expect("available implies a resolved path");

        let temp_dir = std::env::temp_dir().join(format!(
            "scanstudio-exiftool-test-{}",
            crate::manifest::generate_project_id()
        ));
        std::fs::create_dir_all(&temp_dir).expect("create temp dir for exiftool integration test");

        // Exact date + keywords, written to a brand-new sidecar. ExifTool
        // can create a new .xmp file from nothing, so no existing file is
        // overwritten here and `-overwrite_original` is not needed.
        let exact_sidecar = temp_dir.join("exact.xmp");
        let exact_metadata = MetadataSet {
            date: Some(PartialDate::Exact {
                date: "2026-07-22".to_string(),
            }),
            keywords: vec!["family".to_string(), "vacation".to_string()],
            ..MetadataSet::default()
        };
        let write = std::process::Command::new(&exiftool_path)
            .args(build_exiftool_arguments(&exact_metadata))
            .arg(&exact_sidecar)
            .output()
            .expect("spawn exiftool to write the exact-date sidecar");
        assert!(
            write.status.success(),
            "exiftool exact-date write failed: {}",
            String::from_utf8_lossy(&write.stderr)
        );

        let read = std::process::Command::new(&exiftool_path)
            .arg("-j")
            .arg(&exact_sidecar)
            .output()
            .expect("spawn exiftool -j to read back the exact-date sidecar");
        assert!(read.status.success());
        let parsed: serde_json::Value =
            serde_json::from_slice(&read.stdout).expect("parse exiftool -j JSON output");
        // ExifTool normalizes the hyphenated input to its own
        // colon-separated convention on read-back (verified against the
        // real 13.55 binary) — the calendar date round-trips exactly, just
        // not byte-identical to the hyphenated argument that was written.
        assert_eq!(
            parsed[0]["DateCreated"],
            serde_json::json!("2026:07:22"),
            "exact date must round-trip to the same calendar date: {parsed}"
        );
        assert_eq!(
            parsed[0]["Subject"],
            serde_json::json!(["family", "vacation"]),
            "keywords must round-trip as a list: {parsed}"
        );

        // Month-only date, a second brand-new sidecar — the load-bearing
        // assertion for META-02: no day component anywhere in the
        // read-back.
        let month_only_sidecar = temp_dir.join("month-only.xmp");
        let month_only_metadata = MetadataSet {
            date: Some(PartialDate::MonthOnly { year: 2026, month: 7 }),
            ..MetadataSet::default()
        };
        let write = std::process::Command::new(&exiftool_path)
            .args(build_exiftool_arguments(&month_only_metadata))
            .arg(&month_only_sidecar)
            .output()
            .expect("spawn exiftool to write the month-only sidecar");
        assert!(
            write.status.success(),
            "exiftool month-only write failed: {}",
            String::from_utf8_lossy(&write.stderr)
        );

        let read = std::process::Command::new(&exiftool_path)
            .arg("-j")
            .arg(&month_only_sidecar)
            .output()
            .expect("spawn exiftool -j to read back the month-only sidecar");
        assert!(read.status.success());
        let parsed: serde_json::Value =
            serde_json::from_slice(&read.stdout).expect("parse exiftool -j JSON output");
        assert_eq!(
            parsed[0]["DateCreated"],
            serde_json::json!("2026:07"),
            "month-only date must round-trip with no day component: {parsed}"
        );

        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}
