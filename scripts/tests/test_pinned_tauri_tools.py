from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest import mock
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
INSTALLER_PATH = (
    REPOSITORY_ROOT / "ports" / "tauri" / "packaging" / "install_pinned_tauri_tools.py"
)


def load_installer() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "test_pinned_tauri_installer", INSTALLER_PATH
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


INSTALLER = load_installer()


class FakeResponse:
    def __init__(
        self,
        payload: bytes,
        url: str,
        *,
        content_length: str | None = None,
        content_encoding: str | None = None,
    ) -> None:
        self._payload = payload
        self._offset = 0
        self._url = url
        self.headers: dict[str, str] = {}
        if content_length is not None:
            self.headers["Content-Length"] = content_length
        if content_encoding is not None:
            self.headers["Content-Encoding"] = content_encoding

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def geturl(self) -> str:
        return self._url

    def read(self, size: int = -1) -> bytes:
        if self._offset >= len(self._payload):
            return b""
        end = len(self._payload) if size < 0 else self._offset + size
        chunk = self._payload[self._offset : end]
        self._offset += len(chunk)
        return chunk


def make_zip(entries: list[tuple[str, int, bytes]]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, mode="w") as bundle:
        for name, mode, payload in entries:
            member = zipfile.ZipInfo(name)
            member.create_system = 3
            member.external_attr = mode << 16
            bundle.writestr(member, payload)
    return output.getvalue()


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def write_exclusive(path: Path, payload: bytes) -> None:
    with path.open("xb") as output:
        output.write(payload)


class DownloadBoundaryTests(unittest.TestCase):
    def test_exact_https_download_is_accepted(self) -> None:
        payload = b"exact pinned payload"
        asset = {
            "url": "https://example.invalid/tool",
            "size": len(payload),
            "sha256": sha256(payload),
        }
        response = FakeResponse(
            payload,
            str(asset["url"]),
            content_length=str(len(payload)),
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            destination = Path(temporary_directory).resolve() / "tool"
            with mock.patch.object(
                INSTALLER.urllib.request, "urlopen", return_value=response
            ):
                INSTALLER.download_asset(asset, destination)
            self.assertEqual(destination.read_bytes(), payload)

    def test_download_rejects_bad_length_encoding_redirect_and_digest(self) -> None:
        payload = b"payload"
        good_asset = {
            "url": "https://example.invalid/tool",
            "size": len(payload),
            "sha256": sha256(payload),
        }
        cases = (
            FakeResponse(payload, str(good_asset["url"])),
            FakeResponse(
                payload,
                str(good_asset["url"]),
                content_length=str(len(payload) + 1),
            ),
            FakeResponse(
                payload,
                str(good_asset["url"]),
                content_length=str(len(payload)),
                content_encoding="gzip",
            ),
            FakeResponse(
                payload,
                "http://example.invalid/tool",
                content_length=str(len(payload)),
            ),
        )
        for index, response in enumerate(cases):
            with (
                self.subTest(case=index),
                tempfile.TemporaryDirectory() as temporary_directory,
            ):
                destination = Path(temporary_directory).resolve() / "tool"
                with mock.patch.object(
                    INSTALLER.urllib.request, "urlopen", return_value=response
                ):
                    with self.assertRaises(INSTALLER.ToolError):
                        INSTALLER.download_asset(good_asset, destination)

        wrong_digest_asset = dict(good_asset, sha256="0" * 64)
        response = FakeResponse(
            payload,
            str(good_asset["url"]),
            content_length=str(len(payload)),
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            destination = Path(temporary_directory).resolve() / "tool"
            with mock.patch.object(
                INSTALLER.urllib.request, "urlopen", return_value=response
            ):
                with self.assertRaisesRegex(INSTALLER.ToolError, "digest mismatch"):
                    INSTALLER.download_asset(wrong_digest_asset, destination)


class ArchiveBoundaryTests(unittest.TestCase):
    def test_member_names_reject_traversal_and_windows_ambiguity(self) -> None:
        unsafe = (
            "",
            "nsis-3.11",
            "/nsis-3.11/file",
            "other/file",
            "nsis-3.11/../outside",
            "nsis-3.11\\file",
            "nsis-3.11/C:/file",
            "nsis-3.11/CON.txt",
            "nsis-3.11/trailing. ",
        )
        for name in unsafe:
            with self.subTest(name=name):
                with self.assertRaises(INSTALLER.ToolError):
                    INSTALLER.validated_zip_member(name, "nsis-3.11")

    def test_traversal_is_rejected_before_extraction(self) -> None:
        archive_payload = make_zip(
            [("nsis-3.11/../../outside", stat.S_IFREG | 0o600, b"outside")]
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            archive = root / "nsis.zip"
            archive.write_bytes(archive_payload)
            destination = root / "NSIS"
            with (
                mock.patch.object(INSTALLER, "NSIS_BASE_FILE_COUNT", 1),
                mock.patch.object(INSTALLER, "NSIS_BASE_EXPANDED_BYTES", 7),
                self.assertRaises(INSTALLER.ToolError),
            ):
                INSTALLER.extract_nsis_archive(archive, destination)
            self.assertFalse((root / "outside").exists())

    def test_links_special_files_and_case_collisions_are_rejected(self) -> None:
        cases = (
            [
                (
                    "nsis-3.11/link",
                    stat.S_IFLNK | 0o777,
                    b"../../outside",
                )
            ],
            [("nsis-3.11/device", stat.S_IFCHR | 0o600, b"device")],
            [
                ("nsis-3.11/File", stat.S_IFREG | 0o600, b"one"),
                ("nsis-3.11/file", stat.S_IFREG | 0o600, b"two"),
            ],
        )
        for index, entries in enumerate(cases):
            payload = make_zip(entries)
            expanded = sum(len(entry[2]) for entry in entries)
            with (
                self.subTest(case=index),
                tempfile.TemporaryDirectory() as temporary_directory,
            ):
                root = Path(temporary_directory).resolve()
                archive = root / "nsis.zip"
                archive.write_bytes(payload)
                with (
                    mock.patch.object(INSTALLER, "NSIS_BASE_FILE_COUNT", len(entries)),
                    mock.patch.object(INSTALLER, "NSIS_BASE_EXPANDED_BYTES", expanded),
                    self.assertRaises(INSTALLER.ToolError),
                ):
                    INSTALLER.extract_nsis_archive(archive, root / "NSIS")


class ToolTreeTests(unittest.TestCase):
    def test_held_hash_ignores_windows_synthetic_identity_metadata(self) -> None:
        payload = b"stable pinned bytes"
        original_fstat = INSTALLER.os.fstat
        call_count = 0

        def synthetic_fstat(descriptor: int) -> SimpleNamespace:
            nonlocal call_count
            actual = original_fstat(descriptor)
            call_count += 1
            return SimpleNamespace(
                st_mode=actual.st_mode,
                st_size=actual.st_size,
                st_nlink=actual.st_nlink,
                st_dev=10_000 + call_count,
                st_ino=20_000 + call_count,
                st_mtime_ns=30_000 + call_count,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            tool = Path(temporary_directory).resolve() / "tool"
            tool.write_bytes(payload)
            with mock.patch.object(INSTALLER.os, "fstat", side_effect=synthetic_fstat):
                self.assertEqual(
                    INSTALLER.hash_regular_file(tool, expected_size=len(payload)),
                    sha256(payload),
                )

    def test_held_hash_rejects_content_changed_between_reads(self) -> None:
        payload = b"stable pinned bytes"
        replacement = b"changed pinned byte"
        self.assertEqual(len(payload), len(replacement))
        original_read = INSTALLER.os.read
        first_pass_complete = False

        with tempfile.TemporaryDirectory() as temporary_directory:
            tool = Path(temporary_directory).resolve() / "tool"
            tool.write_bytes(payload)

            def mutate_after_first_pass(descriptor: int, size: int) -> bytes:
                nonlocal first_pass_complete
                chunk = original_read(descriptor, size)
                if not chunk and not first_pass_complete:
                    first_pass_complete = True
                    tool.write_bytes(replacement)
                return chunk

            with (
                mock.patch.object(
                    INSTALLER.os, "read", side_effect=mutate_after_first_pass
                ),
                self.assertRaisesRegex(INSTALLER.ToolError, "changed while hashing"),
            ):
                INSTALLER.hash_regular_file(tool, expected_size=len(payload))

    def test_linux_prepare_applies_exact_patch_and_rejects_tampering(self) -> None:
        source = b"0123456789abcdef"
        installed = source[:8] + b"\0\0\0" + source[11:]
        asset = {
            "name": "linuxdeploy-x86_64.AppImage",
            "url": "https://example.invalid/linuxdeploy",
            "size": len(source),
            "sha256": sha256(source),
            "installed_sha256": sha256(installed),
            "zero_range": (8, 11),
        }

        def fake_download(_asset: dict[str, object], destination: Path) -> None:
            write_exclusive(destination, source)

        with tempfile.TemporaryDirectory() as temporary_directory:
            tools_root = Path(temporary_directory).resolve() / ".tauri"
            tools_root.mkdir()
            with (
                mock.patch.object(INSTALLER, "LINUX_ASSETS", (asset,)),
                mock.patch.object(
                    INSTALLER, "download_asset", side_effect=fake_download
                ),
            ):
                INSTALLER.prepare_linux(tools_root)
                tool = tools_root / str(asset["name"])
                self.assertEqual(tool.read_bytes(), installed)
                INSTALLER.verify_linux(tools_root)
                tool.chmod(0o755)
                with self.assertRaisesRegex(INSTALLER.ToolError, "exactly 0700"):
                    INSTALLER.verify_linux(tools_root)
                tool.chmod(0o700)
                tool.write_bytes(b"X" * len(installed))
                with self.assertRaisesRegex(INSTALLER.ToolError, "digest mismatch"):
                    INSTALLER.verify_linux(tools_root)

    def test_windows_prepare_commits_full_tree_plugin_and_webview(self) -> None:
        base_entries = [
            ("nsis-3.11/makensis.exe", stat.S_IFREG | 0o600, b"compiler"),
            (
                "nsis-3.11/Plugins/x86-unicode/System.dll",
                stat.S_IFREG | 0o600,
                b"system-plugin",
            ),
        ]
        archive_payload = make_zip(base_entries)
        plugin_payload = b"tauri-plugin"
        webview_payload = b"signed-webview-fixture"
        archive_asset = {
            "name": "nsis.zip",
            "url": "https://example.invalid/nsis",
            "size": len(archive_payload),
            "sha256": sha256(archive_payload),
        }
        plugin_asset = {
            "name": "nsis_tauri_utils.dll",
            "url": "https://example.invalid/plugin",
            "size": len(plugin_payload),
            "sha256": sha256(plugin_payload),
        }
        webview_asset = {
            "name": "MicrosoftEdgeWebView2RuntimeInstallerX64.exe",
            "url": "https://example.invalid/webview",
            "size": len(webview_payload),
            "sha256": sha256(webview_payload),
        }
        payloads = {
            str(archive_asset["url"]): archive_payload,
            str(plugin_asset["url"]): plugin_payload,
            str(webview_asset["url"]): webview_payload,
        }

        def fake_download(asset: dict[str, object], destination: Path) -> None:
            write_exclusive(destination, payloads[str(asset["url"])])

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            expected_base = root / "expected-base"
            (expected_base / "Plugins" / "x86-unicode").mkdir(parents=True)
            (expected_base / "makensis.exe").write_bytes(b"compiler")
            (expected_base / "Plugins" / "x86-unicode" / "System.dll").write_bytes(
                b"system-plugin"
            )
            tree_sha, file_count, directory_count, expanded = INSTALLER._tree_commit(
                expected_base
            )
            tools_root = root / ".tauri"
            tools_root.mkdir()
            with (
                mock.patch.object(INSTALLER, "NSIS_ARCHIVE", archive_asset),
                mock.patch.object(INSTALLER, "NSIS_PLUGIN", plugin_asset),
                mock.patch.object(INSTALLER, "WEBVIEW2_ASSET", webview_asset),
                mock.patch.object(INSTALLER, "NSIS_BASE_TREE_SHA256", tree_sha),
                mock.patch.object(INSTALLER, "NSIS_BASE_FILE_COUNT", file_count),
                mock.patch.object(
                    INSTALLER, "NSIS_BASE_DIRECTORY_COUNT", directory_count
                ),
                mock.patch.object(INSTALLER, "NSIS_BASE_EXPANDED_BYTES", expanded),
                mock.patch.object(
                    INSTALLER, "download_asset", side_effect=fake_download
                ),
            ):
                INSTALLER.prepare_windows(tools_root)
                INSTALLER.verify_windows(tools_root)
                webview = (
                    tools_root
                    / "x64"
                    / INSTALLER.WEBVIEW2_GUID
                    / str(webview_asset["name"])
                )
                webview.write_bytes(b"X" * len(webview_payload))
                with self.assertRaisesRegex(INSTALLER.ToolError, "digest mismatch"):
                    INSTALLER.verify_windows(tools_root)

    def test_overrides_and_preexisting_cache_fail_before_download(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            target = Path(temporary_directory).resolve() / "target"
            with mock.patch.dict(os.environ, {"NSIS_PATH": "attacker"}, clear=True):
                with self.assertRaisesRegex(INSTALLER.ToolError, "overrides"):
                    INSTALLER.prepare("linux", target)
            self.assertFalse(target.exists())

            target.mkdir()
            tools_root = target / ".tauri"
            tools_root.mkdir()
            sentinel = tools_root / "sentinel"
            sentinel.write_text("preserve me")
            with mock.patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(INSTALLER.ToolError, "pre-existing"):
                    INSTALLER.prepare("linux", target)
            self.assertEqual(sentinel.read_text(), "preserve me")

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks unavailable")
    def test_verifier_rejects_symlinked_tool(self) -> None:
        payload = b"tool"
        asset = {
            "name": "tool",
            "url": "https://example.invalid/tool",
            "size": len(payload),
            "sha256": sha256(payload),
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            outside = root / "outside"
            outside.write_bytes(payload)
            tools_root = root / ".tauri"
            tools_root.mkdir()
            (tools_root / "tool").symlink_to(outside)
            with mock.patch.object(INSTALLER, "LINUX_ASSETS", (asset,)):
                with self.assertRaisesRegex(
                    INSTALLER.ToolError, "link or reparse point"
                ):
                    INSTALLER.verify_linux(tools_root)

    @unittest.skipUnless(hasattr(os, "link"), "hard links unavailable")
    def test_verifier_rejects_hard_linked_tool(self) -> None:
        payload = b"tool"
        asset = {
            "name": "tool",
            "url": "https://example.invalid/tool",
            "size": len(payload),
            "sha256": sha256(payload),
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            outside = root / "outside"
            outside.write_bytes(payload)
            tools_root = root / ".tauri"
            tools_root.mkdir()
            os.link(outside, tools_root / "tool")
            with mock.patch.object(INSTALLER, "LINUX_ASSETS", (asset,)):
                with self.assertRaisesRegex(INSTALLER.ToolError, "hard link"):
                    INSTALLER.verify_linux(tools_root)


class PackagingWiringTests(unittest.TestCase):
    def test_tauri_and_package_builds_use_the_private_pinned_tree(self) -> None:
        config = json.loads(
            (
                REPOSITORY_ROOT
                / "ports"
                / "tauri"
                / "app"
                / "src-tauri"
                / "tauri.conf.json"
            ).read_text()
        )
        self.assertIs(config["bundle"]["useLocalToolsDir"], True)

        linux = (
            REPOSITORY_ROOT
            / "ports"
            / "tauri"
            / "packaging"
            / "linux"
            / "build-and-verify.sh"
        ).read_text()
        self.assertIn("prepare linux --target-directory", linux)
        self.assertGreaterEqual(linux.count("verify linux --target-directory"), 2)
        self.assertIn("tauri-cli 2.11.4", linux)
        self.assertLess(linux.index("prepare linux"), linux.index("npm run tauri"))

        windows = (
            REPOSITORY_ROOT
            / "ports"
            / "tauri"
            / "packaging"
            / "windows"
            / "build-and-verify.ps1"
        ).read_text()
        for required in (
            "Invoke-PinnedTauriToolCheck -Operation prepare",
            "Invoke-PinnedTauriToolCheck -Operation verify",
            "Get-AuthenticodeSignature",
            "WEBVIEW2INSTALLERPATH",
            "FileShare]::Read",
            "Assert-GeneratedNsisUsesPinnedWebView",
            "tauri-cli 2.11.4",
        ):
            self.assertIn(required, windows)
        self.assertLess(
            windows.rindex("Assert-GeneratedNsisUsesPinnedWebView"),
            windows.rindex("Publish-VerifiedOutputs"),
        )


if __name__ == "__main__":
    unittest.main()
