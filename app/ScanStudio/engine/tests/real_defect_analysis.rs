//! Tests for the real (IR-derived) defect-detection path (Phase 17, plan
//! 17-01): proves `render::real_frame_defects` against the real six-slot
//! parity corpus. Corpus-gated — normal `cargo test` runs never depend on
//! the real corpus.

use std::path::PathBuf;

use scanstudio_engine::domain::{DefectKind, ProcessingRecipe};
use scanstudio_engine::parity::corpus;
use scanstudio_engine::render::real_frame_defects;

fn corpus_root_or_skip() -> Option<PathBuf> {
    match std::env::var("SCANSTUDIO_PARITY_CORPUS") {
        Ok(value) if !value.is_empty() => Some(PathBuf::from(value)),
        _ => {
            eprintln!(
                "SCANSTUDIO_PARITY_CORPUS not set — skipping corpus-dependent test (expected in normal cargo test runs)"
            );
            None
        }
    }
}

#[test]
fn real_frame_defects_returns_plausible_real_instances_for_a_corpus_slot() {
    let Some(root) = corpus_root_or_skip() else {
        return;
    };

    let manifest = corpus::discover(&root).expect("corpus discover should succeed");
    let slot = manifest
        .slots
        .first()
        .expect("corpus must contain at least one slot");

    let instances = real_frame_defects(&slot.rgb_path, &slot.ir_path, &ProcessingRecipe::default())
        .expect("real_frame_defects should succeed against a real corpus slot");

    assert!(
        !instances.is_empty(),
        "a real scanned frame must produce at least one defect instance; an empty result indicates a real bug"
    );

    let dust_count = instances
        .iter()
        .filter(|i| i.kind == DefectKind::Dust)
        .count();
    let scratch_count = instances
        .iter()
        .filter(|i| i.kind == DefectKind::Scratch)
        .count();

    eprintln!(
        "real_defect_analysis: slot {} -> {} instances ({} dust, {} scratch)",
        slot.slot,
        instances.len(),
        dust_count,
        scratch_count
    );

    for instance in &instances {
        assert!(
            (0.0..=1.0).contains(&instance.severity),
            "severity must be normalized to [0.0, 1.0]"
        );
        assert!(
            (0.0..=1.0).contains(&instance.center_x),
            "center_x must be normalized to [0.0, 1.0]"
        );
        assert!(
            (0.0..=1.0).contains(&instance.center_y),
            "center_y must be normalized to [0.0, 1.0]"
        );
        assert!(instance.radius > 0.0, "radius must be positive");
        assert_eq!(
            instance.end_x.is_some(),
            instance.end_y.is_some(),
            "end_x and end_y must be mutually consistent"
        );
        assert_eq!(
            instance.end_x.is_some(),
            instance.kind == DefectKind::Scratch,
            "end points must be present exactly for scratch instances"
        );
    }
}
