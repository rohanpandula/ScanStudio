use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use scanstudio_app_lib::preview::{handle_with_windows_wsl_share, PreviewAccess};
use tauri::http::Request;

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(1);

struct FixtureGuard(PathBuf);

impl Drop for FixtureGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fixture_root() -> (PathBuf, FixtureGuard) {
    let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
    let root = std::env::temp_dir().join(format!(
        "scanstudio-windows-preview-{}-{sequence}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).expect("create integration fixture root");
    (root.clone(), FixtureGuard(root))
}

fn preview_file(share: &Path, user: &str, session: &str, filename: &str) -> PathBuf {
    share
        .join("home")
        .join(user)
        .join(".scanstudio")
        .join("previews")
        .join(session)
        .join(filename)
}

fn request_for_wsl_path(access: &PreviewAccess, path: &str) -> Request<Vec<u8>> {
    let mut query = url::form_urlencoded::Serializer::new(String::new());
    query.append_pair("id", &access.issue(path));
    Request::builder()
        .uri(format!(
            "scanstudio-preview://localhost/?{}",
            query.finish()
        ))
        .body(Vec::new())
        .unwrap()
}

fn save_tiff(path: &Path, color: [u8; 3]) {
    std::fs::create_dir_all(path.parent().unwrap()).expect("create preview directory");
    image::RgbImage::from_pixel(4, 4, image::Rgb(color))
        .save(path)
        .expect("save preview TIFF");
}

fn response_color(response: &tauri::http::Response<Vec<u8>>) -> [u8; 3] {
    let image = image::load_from_memory(response.body())
        .expect("preview response is a decodable image")
        .to_rgb8();
    image.get_pixel(0, 0).0
}

#[test]
fn windows_uri_serves_initial_and_spacing_adjusted_real_preview_tiles() {
    let (root, _guard) = fixture_root();
    let share = root.join("pinned-Ubuntu-24.04-share");
    let home = root.join("windows-home");
    std::fs::create_dir_all(&home).unwrap();

    let initial_session = "0123456789abcdef0123456789abcdef";
    let adjusted_session = "abcdef0123456789abcdef0123456789";
    let access = PreviewAccess::default();
    save_tiff(
        &preview_file(&share, "wsl-user", initial_session, "slot-0002.tif"),
        [12, 34, 56],
    );
    save_tiff(
        &preview_file(&share, "wsl-user", adjusted_session, "slot-0002.tif"),
        [210, 180, 90],
    );

    let initial = request_for_wsl_path(&access, &format!(
        "/home/wsl-user/.scanstudio/previews/{initial_session}/slot-0002.tif"
    ));
    let adjusted = request_for_wsl_path(&access, &format!(
        "/home/wsl-user/.scanstudio/previews/{adjusted_session}/slot-0002.tif"
    ));

    let initial_response = handle_with_windows_wsl_share(home.clone(), &share, &access, &initial);
    let adjusted_response = handle_with_windows_wsl_share(home, &share, &access, &adjusted);

    assert_eq!(initial_response.status(), 200);
    assert_eq!(adjusted_response.status(), 200);
    assert_eq!(initial_response.headers()["Content-Type"], "image/png");
    assert_eq!(adjusted_response.headers()["Content-Type"], "image/png");
    assert_eq!(response_color(&initial_response), [12, 34, 56]);
    assert_eq!(response_color(&adjusted_response), [210, 180, 90]);
}

#[test]
fn windows_uri_rejects_traversal_alternate_roots_and_arbitrary_files() {
    let (root, _guard) = fixture_root();
    let share = root.join("pinned-Ubuntu-24.04-share");
    let home = root.join("windows-home");
    let access = PreviewAccess::default();
    std::fs::create_dir_all(&home).unwrap();

    for attack in [
        "/home/wsl-user/.scanstudio/previews/0123456789abcdef0123456789abcdef/../slot-0001.tif",
        "/home/wsl-user/.scanstudio/previews/0123456789abcdef0123456789abcdef/nested/slot-0001.tif",
        "/home/wsl-user/.scanstudio/previews/0123456789abcdef0123456789abcdef/receipt.json",
        "/home/wsl-user/.scanstudio/hw-telemetry/0123456789abcdef0123456789abcdef/slot-0001.tif",
        "/tmp/scanstudio-preview/0123456789abcdef0123456789abcdef/slot-0001.tif",
        "/home/../wsl-user/.scanstudio/previews/0123456789abcdef0123456789abcdef/slot-0001.tif",
    ] {
        let response =
            handle_with_windows_wsl_share(
                home.clone(),
                &share,
                &access,
                &request_for_wsl_path(&access, attack),
            );
        assert_eq!(
            response.status(),
            403,
            "attack path should fail authorization: {attack:?}"
        );
    }
}

#[cfg(unix)]
#[test]
fn windows_uri_rejects_a_preview_leaf_symlink_that_escapes_the_allowed_root() {
    use std::os::unix::fs::symlink;

    let (root, _guard) = fixture_root();
    let share = root.join("pinned-Ubuntu-24.04-share");
    let home = root.join("windows-home");
    let access = PreviewAccess::default();
    std::fs::create_dir_all(&home).unwrap();

    let session = "0123456789abcdef0123456789abcdef";
    let leaf = preview_file(&share, "wsl-user", session, "slot-0001.tif");
    std::fs::create_dir_all(leaf.parent().unwrap()).unwrap();
    let outside = root.join("outside.tif");
    save_tiff(&outside, [1, 2, 3]);
    symlink(&outside, &leaf).expect("create escape symlink");

    let response = handle_with_windows_wsl_share(
        home,
        &share,
        &access,
        &request_for_wsl_path(&access, &format!(
            "/home/wsl-user/.scanstudio/previews/{session}/slot-0001.tif"
        )),
    );
    assert_eq!(response.status(), 403);
}
