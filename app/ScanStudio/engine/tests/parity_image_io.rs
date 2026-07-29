//! Round-trips a synthetic 16-bit RGB image and a synthetic 16-bit
//! grayscale image through `image_io.rs`'s TIFF read/write, and checks that
//! `read_mask_normalized`'s u16->f32 normalization is correct — all with
//! zero corpus or network dependency (Task 2, plan 13-01).

use std::path::PathBuf;

use scanstudio_engine::parity::image_io::{
    read_gray16, read_mask_normalized, read_rgb16, write_gray16, write_rgb16, Gray16Image,
    Rgb16Image,
};

fn scratch_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name)
}

#[test]
fn rgb16_round_trip_preserves_every_pixel() {
    let width = 4u32;
    let height = 3u32;
    // Edge values (0 and 65535) deliberately land in different
    // channels/pixels so a channel swap or clipping bug would be caught.
    let pixels: Vec<[u16; 3]> = vec![
        [0, 0, 0],
        [65535, 0, 0],
        [0, 65535, 0],
        [0, 0, 65535],
        [65535, 65535, 65535],
        [12345, 54321, 1],
        [1, 2, 3],
        [65535, 32768, 0],
        [100, 200, 30000],
        [65535, 65535, 0],
        [0, 65535, 65535],
        [65535, 0, 65535],
    ];
    assert_eq!(pixels.len(), (width * height) as usize, "fixture size sanity check");
    let original = Rgb16Image {
        width,
        height,
        pixels,
    };

    let path = scratch_path("rgb16_round_trip.tif");
    write_rgb16(&path, &original).expect("write_rgb16 failed");
    let read_back = read_rgb16(&path).expect("read_rgb16 failed");

    assert_eq!(read_back.width, original.width);
    assert_eq!(read_back.height, original.height);
    assert_eq!(
        read_back.pixels, original.pixels,
        "round-tripped pixels must match exactly — no rounding, no channel swap, no clipping"
    );
}

#[test]
fn gray16_round_trip_preserves_every_pixel() {
    let width = 5u32;
    let height = 2u32;
    let pixels: Vec<u16> = vec![0, 65535, 12345, 1, 60000, 2, 32768, 100, 59999, 40000];
    assert_eq!(pixels.len(), (width * height) as usize, "fixture size sanity check");
    let original = Gray16Image {
        width,
        height,
        pixels,
    };

    let path = scratch_path("gray16_round_trip.tif");
    write_gray16(&path, &original).expect("write_gray16 failed");
    let read_back = read_gray16(&path).expect("read_gray16 failed");

    assert_eq!(read_back.width, original.width);
    assert_eq!(read_back.height, original.height);
    assert_eq!(read_back.pixels, original.pixels);
}

#[test]
fn read_mask_normalized_divides_by_65535() {
    let width = 5u32;
    let height = 2u32;
    let pixels: Vec<u16> = vec![0, 65535, 12345, 1, 60000, 2, 32768, 100, 59999, 40000];
    let original = Gray16Image {
        width,
        height,
        pixels: pixels.clone(),
    };

    let path = scratch_path("mask_normalized.tif");
    write_gray16(&path, &original).expect("write_gray16 failed");

    let mask = read_mask_normalized(&path).expect("read_mask_normalized failed");
    assert_eq!(mask.width, width);
    assert_eq!(mask.height, height);
    assert_eq!(mask.pixels.len(), pixels.len());
    for (normalized, raw) in mask.pixels.iter().zip(pixels.iter()) {
        let expected = *raw as f32 / 65535.0;
        assert!(
            (normalized - expected).abs() < 1e-6,
            "expected {expected}, got {normalized}"
        );
    }
}
