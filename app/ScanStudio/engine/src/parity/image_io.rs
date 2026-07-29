//! 16-bit-safe TIFF read/write and normalized-mask (TIFF or PNG, any source
//! bit depth) read, backed by the `image` crate's `tiff`/`png` codecs. Every
//! function here returns `Result<_, ParityError>` and never panics on
//! malformed external file bytes (T-13-01).

use std::path::Path;

use image::{ImageBuffer, Luma, Rgb};

use crate::parity::types::ParityError;

/// A decoded (or to-be-encoded) 16-bit, 3-channel RGB image: one `[R, G, B]`
/// triple per pixel, row-major.
#[derive(Debug, Clone, PartialEq)]
pub struct Rgb16Image {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<[u16; 3]>,
}

/// A decoded (or to-be-encoded) 16-bit, single-channel grayscale image.
#[derive(Debug, Clone, PartialEq)]
pub struct Gray16Image {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u16>,
}

/// A mask normalized to `[0.0, 1.0]` regardless of the source image's real
/// bit depth (8-bit PNG or 16-bit TIFF alike) — see `read_mask_normalized`.
#[derive(Debug, Clone, PartialEq)]
pub struct NormalizedMask {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<f32>,
}

/// Reads a 16-bit, 3-sample RGB TIFF (or any format the `image` crate can
/// decode and upconvert to 16-bit RGB).
pub fn read_rgb16(path: &Path) -> Result<Rgb16Image, ParityError> {
    let decoded = image::open(path)?.into_rgb16();
    let width = decoded.width();
    let height = decoded.height();
    let raw = decoded.into_raw();
    let pixels = raw
        .chunks_exact(3)
        .map(|chunk| [chunk[0], chunk[1], chunk[2]])
        .collect();
    Ok(Rgb16Image {
        width,
        height,
        pixels,
    })
}

/// Writes a 16-bit, 3-sample RGB TIFF. Output format is inferred from
/// `path`'s extension (`.tif`/`.tiff`) via the `tiff` feature.
pub fn write_rgb16(path: &Path, image: &Rgb16Image) -> Result<(), ParityError> {
    let flat: Vec<u16> = image
        .pixels
        .iter()
        .flat_map(|pixel| pixel.iter().copied())
        .collect();
    let buffer = ImageBuffer::<Rgb<u16>, _>::from_raw(image.width, image.height, flat)
        .ok_or_else(|| {
            ParityError::Decode(
                "write_rgb16: pixel buffer size does not match width*height*3".to_string(),
            )
        })?;
    buffer.save(path)?;
    Ok(())
}

/// Reads a 16-bit, single-sample grayscale TIFF (or any format the `image`
/// crate can decode and upconvert to 16-bit luma).
pub fn read_gray16(path: &Path) -> Result<Gray16Image, ParityError> {
    let decoded = image::open(path)?.into_luma16();
    let width = decoded.width();
    let height = decoded.height();
    let pixels = decoded.into_raw();
    Ok(Gray16Image {
        width,
        height,
        pixels,
    })
}

/// Writes a 16-bit, single-sample grayscale TIFF. Output format is inferred
/// from `path`'s extension via the `tiff` feature.
pub fn write_gray16(path: &Path, image: &Gray16Image) -> Result<(), ParityError> {
    let buffer =
        ImageBuffer::<Luma<u16>, _>::from_raw(image.width, image.height, image.pixels.clone())
            .ok_or_else(|| {
                ParityError::Decode(
                    "write_gray16: pixel buffer size does not match width*height".to_string(),
                )
            })?;
    buffer.save(path)?;
    Ok(())
}

/// Reads a mask (the ICE disclosure mask is a PNG; other masks may be TIFF)
/// and normalizes every sample to `[0.0, 1.0]`. Decoding via `into_luma16`
/// upconverts an 8-bit-sourced PNG to 16-bit using the crate's own
/// `v -> v * 257` rule, so this single code path is correct regardless of
/// the mask's real source bit depth — no manual bit-depth detection needed.
pub fn read_mask_normalized(path: &Path) -> Result<NormalizedMask, ParityError> {
    let decoded = image::open(path)?.into_luma16();
    let width = decoded.width();
    let height = decoded.height();
    let pixels = decoded
        .into_raw()
        .iter()
        .map(|&value| value as f32 / 65535.0)
        .collect();
    Ok(NormalizedMask {
        width,
        height,
        pixels,
    })
}
