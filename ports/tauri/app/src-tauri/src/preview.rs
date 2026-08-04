use std::collections::HashMap;
use std::num::NonZeroUsize;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

use lru::LruCache;
use tauri::http::{Request, Response};
use tauri::{Manager, UriSchemeContext, Wry};

use crate::wsl::bridge_cmd::WSL_DISTRO;
use crate::wsl::pathmap::{wsl_distro_share_root, wsl_preview_paths_in_share};

type CacheKey = (PathBuf, SystemTime);

// Above the LS-5000's largest capture (~5700x3800 at 4000 dpi); bounds the
// decoded buffer so a scanner-sized or crafted TIFF cannot OOM the host.
const MAX_PIXELS: u64 = 24_000_000;
// Total retained encoded-PNG budget; the LRU entry count stays a secondary cap.
const MAX_CACHE_BYTES: usize = 64 * 1024 * 1024;

struct PreviewCache {
    entries: LruCache<CacheKey, Vec<u8>>,
    bytes: usize,
}

fn cache() -> &'static Mutex<PreviewCache> {
    static CACHE: OnceLock<Mutex<PreviewCache>> = OnceLock::new();
    CACHE.get_or_init(|| {
        Mutex::new(PreviewCache {
            entries: LruCache::new(NonZeroUsize::new(256).unwrap()),
            bytes: 0,
        })
    })
}

fn put_cached(cache: &mut PreviewCache, key: CacheKey, body: Vec<u8>, max_bytes: usize) {
    if body.len() > max_bytes {
        return;
    }
    let added = body.len();
    if let Some(previous) = cache.entries.put(key, body) {
        cache.bytes = cache.bytes.saturating_sub(previous.len());
    }
    cache.bytes += added;
    while cache.bytes > max_bytes {
        let Some((_, evicted)) = cache.entries.pop_lru() else {
            break;
        };
        cache.bytes = cache.bytes.saturating_sub(evicted.len());
    }
}

fn text_response(status: u16, body: &str) -> Response<Vec<u8>> {
    Response::builder()
        .status(status)
        .header("Content-Type", "text/plain")
        .body(body.as_bytes().to_vec())
        .unwrap()
}

pub fn handle_request(ctx: UriSchemeContext<'_, Wry>, request: Request<Vec<u8>>) -> Response<Vec<u8>> {
    let home = match ctx.app_handle().path().home_dir() {
        Ok(h) => h,
        Err(_) => return text_response(500, "could not resolve home directory"),
    };
    if cfg!(target_os = "windows") {
        let share = match wsl_distro_share_root(WSL_DISTRO) {
            Ok(path) => path,
            Err(_) => return text_response(500, "could not resolve pinned WSL preview share"),
        };
        handle_with_windows_wsl_share(home, &share, &request)
    } else {
        handle_with_home(home, &request)
    }
}

/// Tauri-independent core so unit tests can call it without constructing a
/// UriSchemeContext (see plan's Task 2).
pub fn handle_with_home(home: PathBuf, request: &Request<Vec<u8>>) -> Response<Vec<u8>> {
    handle_with_roots(home, None, request)
}

/// Windows core with an injectable root for the pinned WSL distro share.
/// Production supplies `\\wsl$\Ubuntu-24.04`; integration tests supply a
/// temporary directory with the same `home/<user>/.scanstudio/previews`
/// layout, exercising the complete URI parsing and authorization path without
/// starting WSL or touching hardware.
pub fn handle_with_windows_wsl_share(
    home: PathBuf,
    distro_share_root: &Path,
    request: &Request<Vec<u8>>,
) -> Response<Vec<u8>> {
    handle_with_roots(home, Some(distro_share_root), request)
}

fn canonical_path_in_scope(requested: &Path, allowed_root: &Path) -> Result<PathBuf, u16> {
    let canonical = std::fs::canonicalize(requested).map_err(|_| 404u16)?;
    let canonical_root = std::fs::canonicalize(allowed_root).map_err(|_| 404u16)?;
    if !canonical.starts_with(&canonical_root) {
        return Err(403);
    }
    Ok(canonical)
}

fn handle_with_roots(
    home: PathBuf,
    windows_wsl_share: Option<&Path>,
    request: &Request<Vec<u8>>,
) -> Response<Vec<u8>> {
    let query = request.uri().query().unwrap_or("");
    let params: HashMap<String, String> = url::form_urlencoded::parse(query.as_bytes())
        .into_owned()
        .collect();
    let Some(raw_path) = params.get("path") else {
        return text_response(400, "missing required 'path' query parameter");
    };

    let canonical = if let Some(share) = windows_wsl_share.filter(|_| raw_path.starts_with('/')) {
        let (preview_root, requested) = match wsl_preview_paths_in_share(raw_path, share) {
            Ok(paths) => paths,
            Err(_) => return text_response(403, "path outside allowed WSL preview scope"),
        };
        match canonical_path_in_scope(&requested, &preview_root) {
            Ok(path) => path,
            Err(403) => return text_response(403, "path outside allowed WSL preview scope"),
            Err(_) => return text_response(404, "path not found or inaccessible"),
        }
    } else {
        let requested = PathBuf::from(raw_path);
        match canonical_path_in_scope(&requested, &home) {
            Ok(path) => path,
            Err(403) => return text_response(403, "path outside allowed scope"),
            Err(_) => return text_response(404, "path not found or inaccessible"),
        }
    };

    let mtime = match std::fs::metadata(&canonical).and_then(|m| m.modified()) {
        Ok(t) => t,
        Err(_) => return text_response(404, "path not found or inaccessible"),
    };
    let key: CacheKey = (canonical.clone(), mtime);

    if let Some(cached) = cache().lock().unwrap().entries.get(&key) {
        return Response::builder()
            .status(200)
            .header("Content-Type", "image/png")
            .body(cached.clone())
            .unwrap();
    }

    // Header-only dimension check before any pixel allocation.
    let reader = match image::ImageReader::open(&canonical) {
        Ok(r) => r,
        Err(e) => return text_response(500, &format!("decode failed: {e}")),
    };
    let dimensions = match reader.into_dimensions() {
        Ok(dims) => dims,
        Err(e) => return text_response(500, &format!("decode failed: {e}")),
    };
    if u64::from(dimensions.0) * u64::from(dimensions.1) > MAX_PIXELS {
        return text_response(413, "image exceeds maximum preview dimensions");
    }

    let decoded = match image::open(&canonical) {
        Ok(img) => img,
        Err(e) => return text_response(500, &format!("decode failed: {e}")),
    };
    // 8-bit passes through; 16-bit maps to 8-bit by linear scale via the
    // image crate's own channel conversion -- no fancy tone mapping.
    let rgb8 = decoded.to_rgb8();

    let mut png_bytes: Vec<u8> = Vec::new();
    {
        let mut cursor = std::io::Cursor::new(&mut png_bytes);
        if let Err(e) = rgb8.write_to(&mut cursor, image::ImageFormat::Png) {
            return text_response(500, &format!("encode failed: {e}"));
        }
    }

    put_cached(&mut cache().lock().unwrap(), key, png_bytes.clone(), MAX_CACHE_BYTES);

    Response::builder()
        .status(200)
        .header("Content-Type", "image/png")
        .body(png_bytes)
        .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE_ROOT: &str = ".scanstudio-preview-test-fixtures";

    struct FixtureGuard {
        dir: PathBuf,
    }

    impl Drop for FixtureGuard {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
            if let Some(parent) = self.dir.parent() {
                let _ = std::fs::remove_dir(parent);
            }
        }
    }

    fn home_dir() -> PathBuf {
        PathBuf::from(std::env::var("HOME").expect("HOME must be set for preview tests"))
    }

    fn setup_fixture(name: &str) -> (PathBuf, FixtureGuard) {
        let dir = home_dir().join(FIXTURE_ROOT).join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create fixture dir");
        (dir.clone(), FixtureGuard { dir })
    }

    fn request_for_path(path: &std::path::Path) -> Request<Vec<u8>> {
        let mut query = url::form_urlencoded::Serializer::new(String::new());
        query.append_pair("path", &path.to_string_lossy());
        let uri = format!("scanstudio-preview://localhost/?{}", query.finish());
        Request::builder().uri(uri).body(Vec::new()).unwrap()
    }

    #[test]
    fn eight_bit_tiff_passes_through_as_valid_png() {
        let (dir, _guard) = setup_fixture("eight-bit");
        let img: image::RgbImage = image::RgbImage::from_fn(4, 4, |x, y| {
            if x == 3 && y == 3 {
                image::Rgb([200, 100, 50])
            } else {
                image::Rgb([10, 20, 30])
            }
        });
        let tif_path = dir.join("fixture8.tif");
        img.save(&tif_path).expect("save 8-bit tiff fixture");

        let response = handle_with_home(home_dir(), &request_for_path(&tif_path));

        assert_eq!(response.status(), 200);
        assert_eq!(response.headers().get("Content-Type").unwrap(), "image/png");
        let body = response.body();
        assert_eq!(&body[..8], b"\x89PNG\r\n\x1a\n");
        let decoded = image::load_from_memory(body).expect("decode png body").to_rgb8();
        assert_eq!(decoded.get_pixel(3, 3), &image::Rgb([200, 100, 50]));
        assert_eq!(decoded.get_pixel(0, 0), &image::Rgb([10, 20, 30]));
    }

    #[test]
    fn sixteen_bit_tiff_scales_linearly_to_eight_bit() {
        let (dir, _guard) = setup_fixture("sixteen-bit");
        let img: image::ImageBuffer<image::Rgb<u16>, Vec<u16>> =
            image::ImageBuffer::from_fn(4, 4, |x, _y| match x {
                0 => image::Rgb([0u16, 0, 0]),
                1 => image::Rgb([65535u16, 65535, 65535]),
                2 => image::Rgb([32768u16, 32768, 32768]),
                _ => image::Rgb([0u16, 0, 0]),
            });
        let tif_path = dir.join("fixture16.tif");
        img.save(&tif_path).expect("save 16-bit tiff fixture");

        let response = handle_with_home(home_dir(), &request_for_path(&tif_path));

        assert_eq!(response.status(), 200);
        assert_eq!(response.headers().get("Content-Type").unwrap(), "image/png");
        let decoded = image::load_from_memory(response.body())
            .expect("decode png body")
            .to_rgb8();
        assert_eq!(decoded.get_pixel(0, 0), &image::Rgb([0, 0, 0]));
        assert_eq!(decoded.get_pixel(1, 0), &image::Rgb([255, 255, 255]));
        for channel in decoded.get_pixel(2, 0).0.iter() {
            let v = i32::from(*channel);
            assert!(
                (v - 128).abs() <= 2,
                "mid-range channel {v} not within +/-2 of 128"
            );
        }
    }

    #[test]
    fn path_outside_home_is_refused_with_403() {
        let outside = std::env::temp_dir().join("scanstudio-preview-403-test.txt");
        std::fs::write(&outside, b"not a tiff").expect("write outside file");
        let request = request_for_path(&outside);

        let response = handle_with_home(home_dir(), &request);

        assert_eq!(response.status(), 403);
        let _ = std::fs::remove_file(&outside);
    }

    #[test]
    fn missing_path_returns_404() {
        let (dir, _guard) = setup_fixture("missing");
        let missing = dir.join("never-created.tif");

        let response = handle_with_home(home_dir(), &request_for_path(&missing));

        assert_eq!(response.status(), 404);
    }

    #[test]
    fn oversized_image_is_refused_with_413() {
        let (dir, _guard) = setup_fixture("oversized");
        // Crafted classic-TIFF header: little-endian, 8000x6000 (48 MP > cap),
        // no pixel data -- the header check must reject before any decode.
        fn long_entry(tiff: &mut Vec<u8>, tag: u16, value: u32) {
            tiff.extend_from_slice(&tag.to_le_bytes());
            tiff.extend_from_slice(&4u16.to_le_bytes()); // LONG
            tiff.extend_from_slice(&1u32.to_le_bytes());
            tiff.extend_from_slice(&value.to_le_bytes());
        }
        let mut tiff = Vec::new();
        tiff.extend_from_slice(b"II\x2a\x00");
        tiff.extend_from_slice(&8u32.to_le_bytes()); // IFD offset
        tiff.extend_from_slice(&5u16.to_le_bytes()); // entry count
        long_entry(&mut tiff, 0x0100, 8000); // ImageWidth
        long_entry(&mut tiff, 0x0101, 6000); // ImageLength
        // PhotometricInterpretation = BlackIsZero (SHORT, required by decoder)
        tiff.extend_from_slice(&0x0106u16.to_le_bytes());
        tiff.extend_from_slice(&3u16.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
        tiff.extend_from_slice(&1u16.to_le_bytes());
        tiff.extend_from_slice(&0u16.to_le_bytes());
        long_entry(&mut tiff, 0x0111, 74); // StripOffsets (never read: rejected first)
        long_entry(&mut tiff, 0x0117, 100); // StripByteCounts
        tiff.extend_from_slice(&0u32.to_le_bytes()); // next IFD
        let tif_path = dir.join("huge.tif");
        std::fs::write(&tif_path, &tiff).expect("write crafted tiff header");

        let response = handle_with_home(home_dir(), &request_for_path(&tif_path));

        assert_eq!(response.status(), 413);
    }

    fn cache_key(n: u32) -> CacheKey {
        (PathBuf::from(format!("/tmp/fixture-{n}.tif")), SystemTime::UNIX_EPOCH)
    }

    #[test]
    fn cache_evicts_lru_entries_to_stay_within_byte_budget() {
        let mut cache = PreviewCache {
            entries: LruCache::new(NonZeroUsize::new(8).unwrap()),
            bytes: 0,
        };
        put_cached(&mut cache, cache_key(1), vec![1u8; 10], 25);
        put_cached(&mut cache, cache_key(2), vec![2u8; 10], 25);
        assert_eq!(cache.bytes, 20);

        put_cached(&mut cache, cache_key(3), vec![3u8; 10], 25);

        assert!(cache.entries.peek(&cache_key(1)).is_none(), "LRU entry should be evicted");
        assert!(cache.entries.peek(&cache_key(2)).is_some());
        assert!(cache.entries.peek(&cache_key(3)).is_some());
        assert_eq!(cache.bytes, 20);
    }

    #[test]
    fn single_entry_larger_than_budget_is_not_cached() {
        let mut cache = PreviewCache {
            entries: LruCache::new(NonZeroUsize::new(8).unwrap()),
            bytes: 0,
        };
        put_cached(&mut cache, cache_key(1), vec![1u8; 26], 25);
        assert!(cache.entries.is_empty());
        assert_eq!(cache.bytes, 0);
    }

    #[test]
    fn repeat_request_returns_byte_identical_cached_body() {
        let (dir, _guard) = setup_fixture("cache");
        let img: image::RgbImage =
            image::RgbImage::from_fn(4, 4, |x, y| image::Rgb([(x * 60) as u8, (y * 60) as u8, 5]));
        let tif_path = dir.join("cache.tif");
        img.save(&tif_path).expect("save cache fixture");

        let request = request_for_path(&tif_path);
        let first = handle_with_home(home_dir(), &request);
        let second = handle_with_home(home_dir(), &request);

        assert_eq!(first.status(), 200);
        assert_eq!(second.status(), 200);
        assert_eq!(first.body(), second.body());
    }
}
