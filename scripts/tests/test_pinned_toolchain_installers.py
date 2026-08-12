from __future__ import annotations

import hashlib
import importlib.util
import io
from pathlib import Path
import stat
import tarfile
import tempfile
from types import ModuleType
import unittest
from unittest import mock
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def load_installer(name: str) -> ModuleType:
    path = REPOSITORY_ROOT / "scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"test_{name}", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NODE = load_installer("install_pinned_node")
UV_PYTHON = load_installer("install_pinned_uv_python")
INSTALLERS = (("node", NODE), ("uv", UV_PYTHON))


class FakeResponse:
    def __init__(
        self,
        body: bytes,
        url: str,
        *,
        content_length: str | None = None,
        content_encoding: str | None = None,
    ) -> None:
        self._body = body
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
        if self._offset >= len(self._body):
            return b""
        if size < 0:
            end = len(self._body)
        else:
            end = min(self._offset + size, len(self._body))
        chunk = self._body[self._offset : end]
        self._offset = end
        return chunk


def add_tar_entry(
    bundle: tarfile.TarFile,
    name: str,
    *,
    kind: bytes = tarfile.REGTYPE,
    data: bytes = b"payload",
    linkname: str = "",
) -> None:
    member = tarfile.TarInfo(name)
    member.type = kind
    member.linkname = linkname
    if kind == tarfile.REGTYPE:
        member.size = len(data)
        bundle.addfile(member, io.BytesIO(data))
    else:
        bundle.addfile(member)


def make_tar(path: Path, entries: list[dict[str, object]]) -> None:
    with tarfile.open(path, mode="w:gz") as bundle:
        for entry in entries:
            add_tar_entry(bundle, **entry)


def make_zip(path: Path, entries: list[tuple[str, int, bytes]]) -> None:
    with zipfile.ZipFile(path, mode="w") as bundle:
        for name, mode, data in entries:
            member = zipfile.ZipInfo(name)
            member.create_system = 3
            member.external_attr = mode << 16
            bundle.writestr(member, data)


def fake_response_for(
    installer: ModuleType,
    url: str,
    body: bytes,
    *,
    content_length: str | None = None,
    content_encoding: str | None = None,
    final_url: str | None = None,
) -> FakeResponse:
    del installer
    return FakeResponse(
        body,
        final_url or url,
        content_length=content_length,
        content_encoding=content_encoding,
    )


def test_platform_details(
    installer: ModuleType,
    archive_sha256: str,
    executable_sha256: str,
) -> dict[str, str]:
    details = {
        "asset": "tool.tar.gz",
        "archive_sha256": archive_sha256,
        "executable": "tool/bin/tool",
        "executable_sha256": executable_sha256,
        "kind": "tar",
    }
    if installer is NODE:
        details.update(
            {
                "path": "tool/bin",
                "npm_cli": "tool/lib/npm-cli.js",
                "node_arch": "unit-test-arch",
            }
        )
    else:
        details["python_machine"] = "unit-test-arch"
    return details


class ArchiveBoundaryTests(unittest.TestCase):
    def test_member_paths_reject_traversal_and_ambiguous_names(self) -> None:
        unsafe_names = (
            "",
            "/tool/bin/tool",
            "other/bin/tool",
            "tool/../escape",
            "../tool/bin/tool",
            "tool\\bin\\tool",
            "tool/bin/\x00tool",
        )
        for installer_name, installer in INSTALLERS:
            for name in unsafe_names:
                with self.subTest(installer=installer_name, name=name):
                    with self.assertRaises(installer.InstallError):
                        installer.validated_member_path(name, "tool")

    def test_node_link_targets_remain_inside_the_expected_root(self) -> None:
        member = NODE.validated_member_path("tool/lib/node", "tool")
        NODE.validated_link_target(member, "../bin/node", "tool")
        for target in ("", "/outside", "../../outside", "..\\..\\outside"):
            with self.subTest(target=target):
                with self.assertRaises(NODE.InstallError):
                    NODE.validated_link_target(member, target, "tool")

    def test_node_tar_extracts_its_contained_relative_npm_link(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "fixture.tar.gz"
            make_tar(
                archive,
                [
                    {
                        "name": "tool/lib/node_modules/npm/bin/npm-cli.js",
                        "data": b"console.log('10.9.8')\n",
                    },
                    {
                        "name": "tool/bin/npm",
                        "kind": tarfile.SYMTYPE,
                        "linkname": "../lib/node_modules/npm/bin/npm-cli.js",
                    },
                ],
            )
            destination = root / "destination"
            destination.mkdir()
            NODE.extract_tar(archive, destination, "tool")
            npm = destination / "tool/bin/npm"
            self.assertTrue(npm.is_symlink())
            self.assertEqual(
                npm.readlink().as_posix(), "../lib/node_modules/npm/bin/npm-cli.js"
            )
            self.assertEqual(npm.read_bytes(), b"console.log('10.9.8')\n")

    def test_tar_traversal_is_rejected_before_extraction(self) -> None:
        for installer_name, installer in INSTALLERS:
            with self.subTest(installer=installer_name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    archive = root / "fixture.tar.gz"
                    make_tar(archive, [{"name": "tool/../outside"}])
                    destination = root / "destination"
                    destination.mkdir()
                    with self.assertRaises(installer.InstallError):
                        installer.extract_tar(archive, destination, "tool")
                    self.assertFalse((root / "outside").exists())

    def test_zip_traversal_is_rejected_before_extraction(self) -> None:
        regular_mode = stat.S_IFREG | 0o600
        for installer_name, installer in INSTALLERS:
            with self.subTest(installer=installer_name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    archive = root / "fixture.zip"
                    make_zip(
                        archive,
                        [("tool/../outside", regular_mode, b"outside")],
                    )
                    destination = root / "destination"
                    destination.mkdir()
                    with self.assertRaises(installer.InstallError):
                        installer.extract_zip(archive, destination, "tool")
                    self.assertFalse((root / "outside").exists())

    def test_uv_zip_accepts_its_authenticated_windows_root_shape(self) -> None:
        regular_mode = stat.S_IFREG | 0o755
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "fixture.zip"
            make_zip(
                archive,
                [
                    ("uv.exe", regular_mode, b"uv"),
                    ("uvw.exe", regular_mode, b"uvw"),
                    ("uvx.exe", regular_mode, b"uvx"),
                ],
            )
            destination = root / "destination"
            destination.mkdir()
            UV_PYTHON.extract_zip(archive, destination, None)
            self.assertEqual((destination / "uv.exe").read_bytes(), b"uv")

            traversal = root / "traversal.zip"
            make_zip(traversal, [("../outside", regular_mode, b"outside")])
            with self.assertRaises(UV_PYTHON.InstallError):
                UV_PYTHON.extract_zip(traversal, destination, None)
            self.assertFalse((root / "outside").exists())

    def test_tar_case_collisions_are_rejected(self) -> None:
        entries = [{"name": "tool/File"}, {"name": "tool/file"}]
        for installer_name, installer in INSTALLERS:
            with self.subTest(installer=installer_name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    archive = root / "fixture.tar.gz"
                    make_tar(archive, entries)
                    destination = root / "destination"
                    destination.mkdir()
                    with self.assertRaisesRegex(
                        installer.InstallError, "duplicate/colliding"
                    ):
                        installer.extract_tar(archive, destination, "tool")

    def test_zip_case_collisions_are_rejected(self) -> None:
        regular_mode = stat.S_IFREG | 0o600
        entries = [
            ("tool/File", regular_mode, b"one"),
            ("tool/file", regular_mode, b"two"),
        ]
        for installer_name, installer in INSTALLERS:
            with self.subTest(installer=installer_name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    archive = root / "fixture.zip"
                    make_zip(archive, entries)
                    destination = root / "destination"
                    destination.mkdir()
                    with self.assertRaisesRegex(
                        installer.InstallError, "duplicate/colliding"
                    ):
                        installer.extract_zip(archive, destination, "tool")

    def test_tar_links_and_special_entries_are_rejected(self) -> None:
        cases = (
            (NODE, tarfile.SYMTYPE, "../../outside"),
            (NODE, tarfile.LNKTYPE, "tool/file"),
            (NODE, tarfile.CHRTYPE, ""),
            (UV_PYTHON, tarfile.SYMTYPE, "tool/file"),
            (UV_PYTHON, tarfile.LNKTYPE, "tool/file"),
            (UV_PYTHON, tarfile.CHRTYPE, ""),
        )
        for installer, kind, linkname in cases:
            with self.subTest(installer=installer.__name__, kind=kind):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    archive = root / "fixture.tar.gz"
                    make_tar(
                        archive,
                        [
                            {
                                "name": "tool/entry",
                                "kind": kind,
                                "linkname": linkname,
                            }
                        ],
                    )
                    destination = root / "destination"
                    destination.mkdir()
                    with self.assertRaises(installer.InstallError):
                        installer.extract_tar(archive, destination, "tool")

    def test_zip_links_and_special_entries_are_rejected(self) -> None:
        cases = (
            (stat.S_IFLNK | 0o777, b"tool/target"),
            (stat.S_IFIFO | 0o600, b""),
            (stat.S_IFCHR | 0o600, b""),
        )
        for installer_name, installer in INSTALLERS:
            for mode, data in cases:
                with self.subTest(installer=installer_name, mode=oct(mode)):
                    with tempfile.TemporaryDirectory() as temporary_directory:
                        root = Path(temporary_directory)
                        archive = root / "fixture.zip"
                        make_zip(archive, [("tool/entry", mode, data)])
                        destination = root / "destination"
                        destination.mkdir()
                        with self.assertRaises(installer.InstallError):
                            installer.extract_zip(archive, destination, "tool")


class DownloadBoundaryTests(unittest.TestCase):
    def run_download(
        self,
        installer: ModuleType,
        response: FakeResponse,
        destination: Path,
    ) -> None:
        with mock.patch.object(
            installer.urllib.request, "urlopen", return_value=response
        ):
            installer.download(response.geturl(), destination)

    def test_declared_length_overrun_and_truncation_are_rejected(self) -> None:
        for installer_name, installer in INSTALLERS:
            for body, declared_length, expected_message in (
                (b"four", "3", "declared length"),
                (b"two", "4", "length mismatch"),
            ):
                with self.subTest(
                    installer=installer_name,
                    body=body,
                    declared_length=declared_length,
                ):
                    with tempfile.TemporaryDirectory() as temporary_directory:
                        destination = Path(temporary_directory) / "archive"
                        url = "https://example.invalid/archive"
                        response = fake_response_for(
                            installer,
                            url,
                            body,
                            content_length=declared_length,
                        )
                        with self.assertRaisesRegex(
                            installer.InstallError, expected_message
                        ):
                            self.run_download(installer, response, destination)

    def test_invalid_or_out_of_bounds_lengths_are_rejected(self) -> None:
        for installer_name, installer in INSTALLERS:
            invalid_lengths = (None, "not-a-number", "0", "-1")
            for content_length in invalid_lengths:
                with self.subTest(
                    installer=installer_name, content_length=content_length
                ):
                    with tempfile.TemporaryDirectory() as temporary_directory:
                        destination = Path(temporary_directory) / "archive"
                        url = "https://example.invalid/archive"
                        response = fake_response_for(
                            installer,
                            url,
                            b"payload",
                            content_length=content_length,
                        )
                        with self.assertRaises(installer.InstallError):
                            self.run_download(installer, response, destination)

            with self.subTest(installer=installer_name, content_length="oversized"):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    destination = Path(temporary_directory) / "archive"
                    url = "https://example.invalid/archive"
                    response = fake_response_for(
                        installer,
                        url,
                        b"payload",
                        content_length=str(installer.MAX_ARCHIVE_BYTES + 1),
                    )
                    with self.assertRaisesRegex(
                        installer.InstallError, "outside the allowed bound"
                    ):
                        self.run_download(installer, response, destination)

    def test_total_deadline_is_enforced_before_writing_late_data(self) -> None:
        for installer_name, installer in INSTALLERS:
            with self.subTest(installer=installer_name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    destination = Path(temporary_directory) / "archive"
                    url = "https://example.invalid/archive"
                    response = fake_response_for(
                        installer,
                        url,
                        b"payload",
                        content_length="7",
                    )
                    with mock.patch.object(
                        installer.time, "monotonic", side_effect=(0.0, 181.0)
                    ):
                        with self.assertRaisesRegex(
                            installer.InstallError, "total deadline"
                        ):
                            self.run_download(installer, response, destination)
                    self.assertEqual(destination.read_bytes(), b"")

    def test_existing_archive_destination_is_never_replaced(self) -> None:
        for installer_name, installer in INSTALLERS:
            with self.subTest(installer=installer_name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    destination = Path(temporary_directory) / "archive"
                    destination.write_bytes(b"sentinel")
                    url = "https://example.invalid/archive"
                    response = fake_response_for(
                        installer,
                        url,
                        b"payload",
                        content_length="7",
                    )
                    with self.assertRaises(FileExistsError):
                        self.run_download(installer, response, destination)
                    self.assertEqual(destination.read_bytes(), b"sentinel")

    def test_compressed_transfer_and_insecure_final_url_are_rejected(self) -> None:
        for installer_name, installer in INSTALLERS:
            with self.subTest(installer=installer_name, boundary="encoding"):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    destination = Path(temporary_directory) / "archive"
                    url = "https://example.invalid/archive"
                    response = fake_response_for(
                        installer,
                        url,
                        b"payload",
                        content_length="7",
                        content_encoding="gzip",
                    )
                    with self.assertRaisesRegex(
                        installer.InstallError, "compressed HTTP transfer"
                    ):
                        self.run_download(installer, response, destination)

        with tempfile.TemporaryDirectory() as temporary_directory:
            destination = Path(temporary_directory) / "archive"
            url = "https://example.invalid/archive"
            response = fake_response_for(
                NODE,
                url,
                b"payload",
                content_length="7",
                final_url="https://cdn.example.invalid/archive",
            )
            with mock.patch.object(
                NODE.urllib.request, "urlopen", return_value=response
            ):
                with self.assertRaisesRegex(
                    NODE.InstallError, "unexpected Node download redirect"
                ):
                    NODE.download(url, destination)

        with tempfile.TemporaryDirectory() as temporary_directory:
            destination = Path(temporary_directory) / "archive"
            url = "https://example.invalid/archive"
            response = fake_response_for(
                UV_PYTHON,
                url,
                b"payload",
                content_length="7",
                final_url="http://example.invalid/archive",
            )
            with mock.patch.object(
                UV_PYTHON.urllib.request, "urlopen", return_value=response
            ):
                with self.assertRaisesRegex(UV_PYTHON.InstallError, "left HTTPS"):
                    UV_PYTHON.download(url, destination)


class InstallBoundaryTests(unittest.TestCase):
    def install_patches(
        self,
        installer: ModuleType,
        details: dict[str, str],
    ) -> tuple[object, object, object]:
        platform_key = ("UnitTestOS", "UnitTestMachine")
        return (
            mock.patch.object(installer, "PLATFORMS", {platform_key: details}),
            mock.patch.object(
                installer.platform, "system", return_value=platform_key[0]
            ),
            mock.patch.object(
                installer.platform, "machine", return_value=platform_key[1]
            ),
        )

    def test_existing_install_root_fails_before_download(self) -> None:
        for installer_name, installer in INSTALLERS:
            details = test_platform_details(installer, "0" * 64, "0" * 64)
            with self.subTest(installer=installer_name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    install_root = Path(temporary_directory) / "existing"
                    install_root.mkdir()
                    platform_table, system, machine = self.install_patches(
                        installer, details
                    )
                    with (
                        platform_table,
                        system,
                        machine,
                        mock.patch.object(installer, "download") as download,
                    ):
                        with self.assertRaisesRegex(
                            installer.InstallError, "install root already exists"
                        ):
                            installer.install(install_root, None, None)
                    download.assert_not_called()

    def test_archive_digest_mismatch_stops_before_extraction(self) -> None:
        archive_payload = b"tampered archive"
        for installer_name, installer in INSTALLERS:
            details = test_platform_details(installer, "0" * 64, "0" * 64)
            with self.subTest(installer=installer_name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    install_root = Path(temporary_directory) / "install"

                    def fake_download(_url: str, destination: Path) -> None:
                        destination.write_bytes(archive_payload)

                    platform_table, system, machine = self.install_patches(
                        installer, details
                    )
                    with (
                        platform_table,
                        system,
                        machine,
                        mock.patch.object(
                            installer, "download", side_effect=fake_download
                        ),
                        mock.patch.object(installer, "extract_tar") as extract,
                    ):
                        with self.assertRaisesRegex(
                            installer.InstallError, "archive digest mismatch"
                        ):
                            installer.install(install_root, None, None)
                    extract.assert_not_called()

    def test_executable_digest_mismatch_stops_before_execution(self) -> None:
        archive_payload = b"authenticated archive fixture"
        executable_payload = b"tampered executable"
        archive_sha256 = hashlib.sha256(archive_payload).hexdigest()
        for installer_name, installer in INSTALLERS:
            details = test_platform_details(installer, archive_sha256, "0" * 64)
            with self.subTest(installer=installer_name):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    install_root = Path(temporary_directory) / "install"

                    def fake_download(_url: str, destination: Path) -> None:
                        destination.write_bytes(archive_payload)

                    def fake_extract(
                        _archive: Path,
                        destination: Path,
                        _expected_root: str,
                    ) -> None:
                        executable = destination / str(details["executable"])
                        executable.parent.mkdir(parents=True)
                        executable.write_bytes(executable_payload)

                    platform_table, system, machine = self.install_patches(
                        installer, details
                    )
                    with (
                        platform_table,
                        system,
                        machine,
                        mock.patch.object(
                            installer, "download", side_effect=fake_download
                        ),
                        mock.patch.object(
                            installer, "extract_tar", side_effect=fake_extract
                        ),
                        mock.patch.object(installer.subprocess, "run") as run,
                    ):
                        with self.assertRaisesRegex(
                            installer.InstallError, "executable digest mismatch"
                        ):
                            installer.install(install_root, None, None)
                    run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
