use std::collections::{hash_map::RandomState, HashMap, VecDeque};
use std::hash::{BuildHasher, Hash, Hasher};
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
// A session can produce replacement thumbnails while alignment is edited.
// Keep a generous but finite set so an engine cannot grow renderer-visible
// preview authority without bound.
const MAX_ISSUED_PREVIEWS: usize = 4096;

/// Session-local capability table for preview rasters. The engine is the
/// only issuer: before an engine response/event reaches the renderer, every
/// `imagePath` is replaced with an opaque identifier backed by this table.
/// Renderer IPC can therefore present an identifier it received, but cannot
/// turn an arbitrary home-directory path into a read request.
pub struct PreviewAccess {
    inner: Mutex<PreviewAccessInner>,
}

struct PreviewAccessInner {
    paths_by_id: HashMap<String, String>,
    ids_by_path: HashMap<String, String>,
    order: VecDeque<String>,
    next_id: u64,
    hash_a: RandomState,
    hash_b: RandomState,
}

impl Default for PreviewAccess {
    fn default() -> Self {
        Self {
            inner: Mutex::new(PreviewAccessInner {
                paths_by_id: HashMap::new(),
                ids_by_path: HashMap::new(),
                order: VecDeque::new(),
                next_id: 0,
                // RandomState seeds each app session from the platform RNG.
                // Two independently keyed hashes give a 128-bit opaque ID
                // without adding another dependency to the desktop shell.
                hash_a: RandomState::new(),
                hash_b: RandomState::new(),
            }),
        }
    }
}

impl PreviewAccess {
    fn keyed_hash<T: Hash>(state: &RandomState, value: &T) -> u64 {
        let mut hasher = state.build_hasher();
        value.hash(&mut hasher);
        hasher.finish()
    }

    /// Issue (or reuse) an opaque identifier for an engine-originated path.
    pub fn issue(&self, path: &str) -> String {
        let mut inner = self.inner.lock().unwrap();
        if let Some(existing) = inner.ids_by_path.get(path) {
            return existing.clone();
        }
        inner.next_id = inner.next_id.wrapping_add(1);
        let input = (inner.next_id, path);
        let first = Self::keyed_hash(&inner.hash_a, &input);
        let second = Self::keyed_hash(&inner.hash_b, &input);
        // Retain only a harmless, recognized extension so diagnostic bundles
        // can preserve the raster format without revealing its local path.
        let extension = Path::new(path)
            .extension()
            .and_then(|value| value.to_str())
            .map(str::to_ascii_lowercase)
            .filter(|value| matches!(value.as_str(), "tif" | "tiff" | "png" | "jpg" | "jpeg"))
            .map(|value| format!(".{value}"))
            .unwrap_or_default();
        let id = format!("{first:016x}{second:016x}{extension}");
        inner.paths_by_id.insert(id.clone(), path.to_string());
        inner.ids_by_path.insert(path.to_string(), id.clone());
        inner.order.push_back(id.clone());
        while inner.order.len() > MAX_ISSUED_PREVIEWS {
            if let Some(expired_id) = inner.order.pop_front() {
                if let Some(expired_path) = inner.paths_by_id.remove(&expired_id) {
                    inner.ids_by_path.remove(&expired_path);
                }
            }
        }
        id
    }

    /// Resolve only an identifier minted by `issue` in this app session.
    pub fn resolve(&self, id: &str) -> Option<String> {
        self.inner.lock().unwrap().paths_by_id.get(id).cloned()
    }
}

/// Rewrite engine-owned image paths before they cross into the webview.
/// Recursion covers both direct command results and nested event payloads.
pub(crate) fn replace_engine_image_paths(value: &mut serde_json::Value, access: &PreviewAccess) {
    match value {
        serde_json::Value::Object(fields) => {
            for (key, child) in fields {
                if key == "imagePath" {
                    if let Some(path) = child.as_str() {
                        *child = serde_json::Value::String(access.issue(path));
                    }
                } else {
                    replace_engine_image_paths(child, access);
                }
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                replace_engine_image_paths(item, access);
            }
        }
        _ => {}
    }
}

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
    let access = ctx.app_handle().state::<PreviewAccess>();
    let home = match ctx.app_handle().path().home_dir() {
        Ok(h) => h,
        Err(_) => return text_response(500, "could not resolve home directory"),
    };
    if cfg!(target_os = "windows") {
        let share = match wsl_distro_share_root(WSL_DISTRO) {
            Ok(path) => path,
            Err(_) => return text_response(500, "could not resolve pinned WSL preview share"),
        };
        handle_with_windows_wsl_share(home, &share, &access, &request)
    } else {
        handle_with_home(home, &access, &request)
    }
}

/// Tauri-independent core so unit tests can call it without constructing a
/// UriSchemeContext (see plan's Task 2).
pub fn handle_with_home(
    home: PathBuf,
    access: &PreviewAccess,
    request: &Request<Vec<u8>>,
) -> Response<Vec<u8>> {
    handle_with_roots(home, None, access, request)
}

/// Windows core with an injectable root for the pinned WSL distro share.
/// Production supplies `\\wsl$\Ubuntu-24.04`; integration tests supply a
/// temporary directory with the same `home/<user>/.scanstudio/previews`
/// layout, exercising the complete URI parsing and authorization path without
/// starting WSL or touching hardware.
pub fn handle_with_windows_wsl_share(
    home: PathBuf,
    distro_share_root: &Path,
    access: &PreviewAccess,
    request: &Request<Vec<u8>>,
) -> Response<Vec<u8>> {
    handle_with_roots(home, Some(distro_share_root), access, request)
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
    access: &PreviewAccess,
    request: &Request<Vec<u8>>,
) -> Response<Vec<u8>> {
    let query = request.uri().query().unwrap_or("");
    let params: HashMap<String, String> = url::form_urlencoded::parse(query.as_bytes())
        .into_owned()
        .collect();
    let Some(preview_id) = params.get("id") else {
        return text_response(400, "missing required 'id' query parameter");
    };
    let Some(raw_path) = access.resolve(preview_id) else {
        return text_response(403, "preview identifier was not issued by the engine");
    };

    let canonical = if let Some(share) = windows_wsl_share.filter(|_| raw_path.starts_with('/')) {
        let (preview_root, requested) = match wsl_preview_paths_in_share(&raw_path, share) {
            Ok(paths) => paths,
            Err(_) => return text_response(403, "path outside allowed WSL preview scope"),
        };
        match canonical_path_in_scope(&requested, &preview_root) {
            Ok(path) => path,
            Err(403) => return text_response(403, "path outside allowed WSL preview scope"),
            Err(_) => return text_response(404, "path not found or inaccessible"),
        }
    } else {
        let requested = PathBuf::from(&raw_path);
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

    fn request_for_id(id: &str) -> Request<Vec<u8>> {
        let mut query = url::form_urlencoded::Serializer::new(String::new());
        query.append_pair("id", id);
        let uri = format!("scanstudio-preview://localhost/?{}", query.finish());
        Request::builder().uri(uri).body(Vec::new()).unwrap()
    }

    fn authorized_request(access: &PreviewAccess, path: &std::path::Path) -> Request<Vec<u8>> {
        request_for_id(&access.issue(&path.to_string_lossy()))
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

        let access = PreviewAccess::default();
        let response = handle_with_home(home_dir(), &access, &authorized_request(&access, &tif_path));

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

        let access = PreviewAccess::default();
        let response = handle_with_home(home_dir(), &access, &authorized_request(&access, &tif_path));

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
        // The outside fixture must live OUTSIDE $HOME on every host.
        // temp_dir() is genuinely outside home on POSIX (/tmp). On Windows
        // the temp dir is under the user profile (inside home), so use the
        // profile's parent instead. If the chosen parent is not writable in a
        // restricted CI account, skip rather than fail the lane.
        let home = home_dir();
        #[cfg(not(target_os = "windows"))]
        let outside = std::env::temp_dir().join("scanstudio-preview-403-test.txt");
        #[cfg(target_os = "windows")]
        let outside = home
            .parent()
            .unwrap_or_else(|| std::path::Path::new("C:\\"))
            .join("scanstudio-preview-403-test.txt");
        if std::fs::write(&outside, b"not a tiff").is_err() {
            eprintln!("skipping 403 fixture: cannot write {outside:?}");
            return;
        }
        let access = PreviewAccess::default();
        let request = authorized_request(&access, &outside);

        let response = handle_with_home(home, &access, &request);

        assert_eq!(response.status(), 403);
        let _ = std::fs::remove_file(&outside);
    }

    #[test]
    fn missing_path_returns_404() {
        let (dir, _guard) = setup_fixture("missing");
        let missing = dir.join("never-created.tif");

        let access = PreviewAccess::default();
        let response = handle_with_home(home_dir(), &access, &authorized_request(&access, &missing));

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

        let access = PreviewAccess::default();
        let response = handle_with_home(home_dir(), &access, &authorized_request(&access, &tif_path));

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

        let access = PreviewAccess::default();
        let request = authorized_request(&access, &tif_path);
        let first = handle_with_home(home_dir(), &access, &request);
        let second = handle_with_home(home_dir(), &access, &request);

        assert_eq!(first.status(), 200);
        assert_eq!(second.status(), 200);
        assert_eq!(first.body(), second.body());
    }

    #[test]
    fn arbitrary_home_image_without_an_engine_identifier_is_refused() {
        let (dir, _guard) = setup_fixture("unissued");
        let image_path = dir.join("private.png");
        image::RgbImage::new(2, 2)
            .save(&image_path)
            .expect("save arbitrary home image");
        let access = PreviewAccess::default();

        // Supplying the local path where an opaque identifier is required
        // must not recover or decode the file, even though it is under HOME.
        let response = handle_with_home(
            home_dir(),
            &access,
            &request_for_id(&image_path.to_string_lossy()),
        );

        assert_eq!(response.status(), 403);
        assert_eq!(
            response.body(),
            b"preview identifier was not issued by the engine"
        );
    }

    #[test]
    fn engine_paths_are_replaced_with_opaque_identifiers() {
        let access = PreviewAccess::default();
        let raw = "/Users/example/.scanstudio/previews/session/frame-0001.tif";
        let mut message = serde_json::json!({
            "event": "scanner.thumbnail",
            "payload": { "thumbnail": { "imagePath": raw } }
        });

        replace_engine_image_paths(&mut message, &access);

        let id = message["payload"]["thumbnail"]["imagePath"]
            .as_str()
            .expect("opaque image identifier");
        assert_ne!(id, raw);
        assert!(!id.contains("Users"));
        assert_eq!(access.resolve(id).as_deref(), Some(raw));
    }
}
