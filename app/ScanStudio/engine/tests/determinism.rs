//! Asserts the golden thumbnail and settingsFingerprint values directly
//! against `sim.rs`'s public determinism functions — D-9c.

use scanstudio_engine::domain::{CaptureRecipe, Channels};
use scanstudio_engine::sim::{settings_fingerprint, thumbnail_for};

const DEVICE_ID: &str = "sim-ls5000-0";
const TOLERANCE: f64 = 1e-9;

#[test]
fn thumbnail_golden_frame_1() {
    let t = thumbnail_for(DEVICE_ID, 1);
    let brightness = t.brightness.expect("simulator always sets brightness");
    let tint = t.tint.expect("simulator always sets tint");
    assert!(
        (brightness - 0.573579766536965).abs() < TOLERANCE,
        "brightness: {brightness}"
    );
    assert!(
        (tint - 0.37058823529411766).abs() < TOLERANCE,
        "tint: {tint}"
    );
    assert!(t.image_path.is_none(), "simulator must never set image_path");
}

#[test]
fn thumbnail_golden_frame_13() {
    let t = thumbnail_for(DEVICE_ID, 13);
    let brightness = t.brightness.expect("simulator always sets brightness");
    let tint = t.tint.expect("simulator always sets tint");
    assert!(
        (brightness - 0.6080407415884641).abs() < TOLERANCE,
        "brightness: {brightness}"
    );
    assert!(
        (tint - (-0.3588235294117647)).abs() < TOLERANCE,
        "tint: {tint}"
    );
}

#[test]
fn thumbnail_golden_frame_36() {
    let t = thumbnail_for(DEVICE_ID, 36);
    let brightness = t.brightness.expect("simulator always sets brightness");
    let tint = t.tint.expect("simulator always sets tint");
    assert!(
        (brightness - 0.6227077134355687).abs() < TOLERANCE,
        "brightness: {brightness}"
    );
    assert!(
        (tint - (-0.3588235294117647)).abs() < TOLERANCE,
        "tint: {tint}"
    );
}

#[test]
fn thumbnail_values_stay_within_documented_ranges() {
    // PROTOCOL.md: brightness 0.25-0.85, tint -0.5-0.5 — spot check a wider
    // frame range than just the three golden indices.
    for frame_index in 1..=36u32 {
        let t = thumbnail_for(DEVICE_ID, frame_index);
        let brightness = t.brightness.expect("simulator always sets brightness");
        let tint = t.tint.expect("simulator always sets tint");
        assert!(
            (0.25..=0.85).contains(&brightness),
            "frame {frame_index} brightness out of range: {brightness}"
        );
        assert!(
            (-0.5..=0.5).contains(&tint),
            "frame {frame_index} tint out of range: {tint}"
        );
    }
}

#[test]
fn settings_fingerprint_golden() {
    let recipe = CaptureRecipe {
        resolution_dpi: 4000,
        bit_depth: 16,
        multisample_passes: 2,
        channels: Channels::Rgbi,
    };
    assert_eq!(settings_fingerprint(&recipe), "1a3d265e0b54bbd2");
}

#[test]
fn settings_fingerprint_changes_with_any_field() {
    let base = CaptureRecipe {
        resolution_dpi: 4000,
        bit_depth: 16,
        multisample_passes: 2,
        channels: Channels::Rgbi,
    };
    let base_fp = settings_fingerprint(&base);

    let variants = [
        CaptureRecipe {
            resolution_dpi: 2000,
            ..base.clone()
        },
        CaptureRecipe {
            bit_depth: 8,
            ..base.clone()
        },
        CaptureRecipe {
            multisample_passes: 4,
            ..base.clone()
        },
        CaptureRecipe {
            channels: Channels::Rgb,
            ..base.clone()
        },
    ];
    for variant in variants {
        assert_ne!(settings_fingerprint(&variant), base_fp);
    }
}
