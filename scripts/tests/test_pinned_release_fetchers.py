from __future__ import annotations

import hashlib
import importlib.util
import io
from pathlib import Path
import sys
import tarfile
import tempfile
from types import ModuleType
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]


def load(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


COOLSCANPY = load(
    "test_pinned_coolscanpy_sdist",
    ROOT / "scripts" / "fetch_pinned_coolscanpy_sdist.py",
)
CARGO_ABOUT = load(
    "test_pinned_cargo_about",
    ROOT / "scripts" / "install_pinned_cargo_about.py",
)


class FakeResponse:
    def __init__(self, payload: bytes, url: str, length: str | None = None) -> None:
        self.payload = io.BytesIO(payload)
        self.url = url
        self.headers = {"Content-Length": length} if length is not None else {}

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def geturl(self) -> str:
        return self.url

    def read(self, size: int = -1) -> bytes:
        return self.payload.read(size)


def tar_payload(entries: list[tuple[str, bytes | None, bytes]]) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as bundle:
        for name, link, payload in entries:
            member = tarfile.TarInfo(name)
            if link is not None:
                member.type = link[:1]
                member.linkname = link[1:].decode()
            elif name.endswith("/"):
                member.type = tarfile.DIRTYPE
            else:
                member.type = tarfile.REGTYPE
                member.size = len(payload)
            bundle.addfile(member, io.BytesIO(payload) if member.isfile() else None)
    return output.getvalue()


class DownloadTests(unittest.TestCase):
    def test_coolscanpy_download_rejects_redirect_length_and_digest(self) -> None:
        payload = b"payload"
        cases = (
            FakeResponse(payload, "https://attacker.invalid/x", str(len(payload))),
            FakeResponse(payload, COOLSCANPY.URL, str(len(payload) + 1)),
            FakeResponse(payload, COOLSCANPY.URL, str(len(payload))),
        )
        with (
            mock.patch.object(COOLSCANPY, "SIZE", len(payload)),
            mock.patch.object(
                COOLSCANPY, "SHA256", hashlib.sha256(b"other").hexdigest()
            ),
        ):
            for response in cases:
                with self.subTest(url=response.url, headers=response.headers):
                    with tempfile.TemporaryDirectory() as temporary:
                        path = Path(temporary) / "archive"
                        with mock.patch.object(
                            COOLSCANPY.urllib.request, "urlopen", return_value=response
                        ):
                            with self.assertRaises(COOLSCANPY.FetchError):
                                COOLSCANPY.download(path)

    def test_cargo_about_download_accepts_only_exact_bytes(self) -> None:
        payload = b"authenticated crate"
        response = FakeResponse(payload, CARGO_ABOUT.ASSET_URL, str(len(payload)))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "crate"
            with (
                mock.patch.object(CARGO_ABOUT, "ASSET_SIZE", len(payload)),
                mock.patch.object(
                    CARGO_ABOUT, "ASSET_SHA256", hashlib.sha256(payload).hexdigest()
                ),
                mock.patch.object(
                    CARGO_ABOUT.urllib.request, "urlopen", return_value=response
                ),
            ):
                CARGO_ABOUT.download(path)
            self.assertEqual(path.read_bytes(), payload)


class ArchiveTests(unittest.TestCase):
    def test_member_paths_reject_escape_and_ambiguity(self) -> None:
        for module, function, root, error in (
            (
                COOLSCANPY,
                COOLSCANPY.member_path,
                COOLSCANPY.ROOT,
                COOLSCANPY.FetchError,
            ),
            (
                CARGO_ABOUT,
                CARGO_ABOUT.member_path,
                CARGO_ABOUT.ARCHIVE_ROOT,
                CARGO_ABOUT.InstallError,
            ),
        ):
            for name in ("", f"{root}/../outside", f"{root}\\outside", "/outside"):
                with self.subTest(module=module.__name__, name=name):
                    with self.assertRaises(error):
                        function(name)

    def test_coolscanpy_extract_rejects_links_before_writing_outside(self) -> None:
        payload = tar_payload(
            [
                (f"{COOLSCANPY.ROOT}/", None, b""),
                (
                    f"{COOLSCANPY.ROOT}/link",
                    tarfile.SYMTYPE + b"../../outside",
                    b"",
                ),
            ]
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.tar.gz"
            archive.write_bytes(payload)
            with (
                mock.patch.object(COOLSCANPY, "ENTRY_COUNT", 2),
                mock.patch.object(COOLSCANPY, "FILE_COUNT", 0),
                mock.patch.object(COOLSCANPY, "DIRECTORY_COUNT", 1),
                mock.patch.object(COOLSCANPY, "EXPANDED_FILE_BYTES", 0),
                self.assertRaisesRegex(COOLSCANPY.FetchError, "link or special"),
            ):
                COOLSCANPY.extract(archive, root / "extract")
            self.assertFalse((root / "outside").exists())

    def test_cargo_about_extract_rejects_link_or_special_entry(self) -> None:
        payload = tar_payload(
            [
                (f"{CARGO_ABOUT.ARCHIVE_ROOT}/", None, b""),
                (
                    f"{CARGO_ABOUT.ARCHIVE_ROOT}/link",
                    tarfile.SYMTYPE + b"outside",
                    b"",
                ),
            ]
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.crate"
            archive.write_bytes(payload)
            with (
                mock.patch.object(CARGO_ABOUT, "ARCHIVE_ENTRIES", 2),
                self.assertRaisesRegex(CARGO_ABOUT.InstallError, "link or special"),
            ):
                CARGO_ABOUT.extract(archive, root / "extract")


class WiringTests(unittest.TestCase):
    def test_release_workflow_uses_authenticated_cargo_about(self) -> None:
        for workflow in ("ports.yml", "release.yml"):
            text = (ROOT / ".github" / "workflows" / workflow).read_text()
            self.assertNotIn("cargo install --locked --version 0.9.1", text)
            self.assertIn("scripts/install_pinned_cargo_about.py", text)

    def test_coolscanpy_gate_uses_exact_fetcher_not_latest_metadata(self) -> None:
        text = (ROOT / "scripts" / "check_coolscanpy_pypi_sync.sh").read_text()
        self.assertIn("scripts/fetch_pinned_coolscanpy_sdist.py", text)
        self.assertNotIn("pypi/coolscanpy/json", text)
        self.assertNotIn("tar -xzf", text)


if __name__ == "__main__":
    unittest.main()
