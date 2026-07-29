use std::path::PathBuf;

use scanstudio_engine::domain::{FilmProcess, OutputFileFormat, OutputRecipe};
use scanstudio_engine::render::render_derivative_from_archive;

/// Explicit, ignored-by-default harness for regenerating a Positive TIFF
/// from an existing real archive without touching scanner hardware.
#[test]
#[ignore = "requires explicit real-archive environment variables"]
fn backfill_positive_from_real_archive_without_rescan() {
    let archive = PathBuf::from(
        std::env::var("SCANSTUDIO_ARCHIVE_RGB").expect("set SCANSTUDIO_ARCHIVE_RGB"),
    );
    let positive_dir =
        std::env::var("SCANSTUDIO_POSITIVE_DIR").expect("set SCANSTUDIO_POSITIVE_DIR");
    let frame: u32 = std::env::var("SCANSTUDIO_FRAME")
        .expect("set SCANSTUDIO_FRAME")
        .parse()
        .expect("SCANSTUDIO_FRAME must be an integer");
    let storage_transform = std::env::var("SCANSTUDIO_STORAGE_TRANSFORM")
        .expect("set SCANSTUDIO_STORAGE_TRANSFORM");

    let archive_before = std::fs::read(&archive).expect("archive must exist and be readable");
    let mut recipes = OutputRecipe::default();
    recipes.positive.destination = positive_dir;
    recipes.positive.file_format = OutputFileFormat::Tiff;
    recipes.preview.enabled = false;

    let written = render_derivative_from_archive(
        &archive,
        frame,
        FilmProcess::C41ColorNegative,
        &recipes,
        None,
        Some(storage_transform.as_str()),
        None,
        None,
    )
    .expect("positive derivative must render from the real archive");

    let archive_after = std::fs::read(&archive).expect("archive must remain readable");
    assert_eq!(
        archive_before, archive_after,
        "every archive byte must remain unchanged"
    );
    assert_eq!(written.archive_path, Some(archive));
    assert!(
        written
            .positive_path
            .as_ref()
            .is_some_and(|path| path.is_file()),
        "positive derivative must exist"
    );
    assert!(written.preview_path.is_none());
}
