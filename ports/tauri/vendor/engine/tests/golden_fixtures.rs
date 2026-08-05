//! Walks all 12 golden fixtures in `protocol/fixtures/`, decodes each into
//! its typed wire shape, re-serializes, and asserts parsed-JSON equality
//! (float tolerance 1e-9) against the original file — D-9a.

#[path = "common/mod.rs"]
mod common;

use std::fs;
use std::path::{Path, PathBuf};

use scanstudio_engine::protocol;

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../protocol/fixtures")
}

/// Decodes `raw` into the typed shape matching `file_name`'s wire kind,
/// re-serializes it, and returns the result for comparison against `raw`.
fn round_trip_typed(file_name: &str, raw: &serde_json::Value) -> serde_json::Value {
    match file_name {
        "01-hello-request.json"
        | "04-connect-request.json"
        | "07-scan-start-request.json"
        | "10-stop-request.json" => {
            let typed: protocol::Request = serde_json::from_value(raw.clone())
                .unwrap_or_else(|err| panic!("{file_name}: decode as Request failed: {err}"));
            serde_json::to_value(typed).unwrap()
        }
        "02-hello-response.json" => {
            let typed: protocol::Response<protocol::HelloResult> =
                serde_json::from_value(raw.clone()).unwrap_or_else(|err| {
                    panic!("{file_name}: decode as Response<HelloResult> failed: {err}")
                });
            serde_json::to_value(typed).unwrap()
        }
        "03-list-response.json" => {
            let typed: protocol::Response<protocol::ScannerListResult> =
                serde_json::from_value(raw.clone()).unwrap_or_else(|err| {
                    panic!("{file_name}: decode as Response<ScannerListResult> failed: {err}")
                });
            serde_json::to_value(typed).unwrap()
        }
        "05-status-event.json" => {
            let typed: protocol::Event<protocol::ScannerStatusPayload> =
                serde_json::from_value(raw.clone()).unwrap_or_else(|err| {
                    panic!("{file_name}: decode as Event<ScannerStatusPayload> failed: {err}")
                });
            serde_json::to_value(typed).unwrap()
        }
        "06-thumbnail-event.json" => {
            let typed: protocol::Event<protocol::ThumbnailPayload> =
                serde_json::from_value(raw.clone()).unwrap_or_else(|err| {
                    panic!("{file_name}: decode as Event<ThumbnailPayload> failed: {err}")
                });
            serde_json::to_value(typed).unwrap()
        }
        "08-progress-event.json" => {
            let typed: protocol::Event<protocol::ScanProgressPayload> =
                serde_json::from_value(raw.clone()).unwrap_or_else(|err| {
                    panic!("{file_name}: decode as Event<ScanProgressPayload> failed: {err}")
                });
            serde_json::to_value(typed).unwrap()
        }
        "09-frame-completed-event.json" => {
            let typed: protocol::Event<protocol::FrameCompletedPayload> =
                serde_json::from_value(raw.clone()).unwrap_or_else(|err| {
                    panic!("{file_name}: decode as Event<FrameCompletedPayload> failed: {err}")
                });
            serde_json::to_value(typed).unwrap()
        }
        "11-feed-jam-frame-state-event.json" => {
            let typed: protocol::Event<protocol::FrameStatePayload> =
                serde_json::from_value(raw.clone()).unwrap_or_else(|err| {
                    panic!("{file_name}: decode as Event<FrameStatePayload> failed: {err}")
                });
            serde_json::to_value(typed).unwrap()
        }
        "12-eject-busy-error.json" => {
            let typed: protocol::ErrorResponse = serde_json::from_value(raw.clone())
                .unwrap_or_else(|err| panic!("{file_name}: decode as ErrorResponse failed: {err}"));
            serde_json::to_value(typed).unwrap()
        }
        other => {
            panic!("no typed decode registered for fixture '{other}' — update round_trip_typed")
        }
    }
}

#[test]
fn all_twelve_fixtures_parse_and_round_trip() {
    let dir = fixtures_dir();
    let mut entries: Vec<PathBuf> = fs::read_dir(&dir)
        .unwrap_or_else(|err| panic!("failed to read fixtures dir {}: {err}", dir.display()))
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    entries.sort();

    assert_eq!(
        entries.len(),
        12,
        "expected exactly 12 golden fixtures in {}, found {} — fixture drift detected",
        dir.display(),
        entries.len()
    );

    for path in &entries {
        let file_name = path.file_name().unwrap().to_str().unwrap().to_string();
        let contents = fs::read_to_string(path)
            .unwrap_or_else(|err| panic!("failed to read {file_name}: {err}"));
        let raw: serde_json::Value = serde_json::from_str(&contents)
            .unwrap_or_else(|err| panic!("{file_name}: not valid JSON: {err}"));

        let re_encoded = round_trip_typed(&file_name, &raw);
        common::assert_json_close(&raw, &re_encoded, 1e-9);
    }
}

#[test]
fn fixture_09_settings_fingerprint_matches_receipt() {
    let path = fixtures_dir().join("09-frame-completed-event.json");
    let contents = fs::read_to_string(&path).expect("read fixture 09");
    let typed: protocol::Event<protocol::FrameCompletedPayload> =
        serde_json::from_str(&contents).expect("decode fixture 09");
    assert_eq!(
        typed.payload.receipt.settings_fingerprint,
        "1a3d265e0b54bbd2"
    );
    assert_eq!(
        typed.payload.receipt.engine_version,
        env!("CARGO_PKG_VERSION")
    );
}
