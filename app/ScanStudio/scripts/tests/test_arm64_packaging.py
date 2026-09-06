"""Packaging policy checks; no downloads, native builds, or scanner access."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


class Arm64PackagingTests(unittest.TestCase):
    def test_build_entry_points_reject_unsupported_hosts_and_requests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            uname = root / "uname"
            uname.write_text('#!/bin/sh\nif [ "$1" = -s ]; then echo "$TEST_OS"; else echo "$TEST_ARCH"; fi\n')
            uname.chmod(0o755)
            for script in ("package_app.sh", "package_dmg.sh", "build_bundled_libusb.sh",
                           "build_sane_link_sdk.sh", "test_packaged_bridge.sh"):
                for system, host, requested in (("Darwin", "x86_64", "arm64"),
                                                 ("Darwin", "arm64", "x86_64"),
                                                 ("Linux", "arm64", "arm64")):
                    with self.subTest(script=script, system=system, host=host, requested=requested):
                        result = subprocess.run(
                            ["/bin/zsh", str(SCRIPTS / script), str(root / "output")],
                            env={**os.environ, "PATH": f"{root}:/usr/bin:/bin",
                                 "TEST_OS": system, "TEST_ARCH": host,
                                 "SCANSTUDIO_RELEASE_ARCH": requested},
                            capture_output=True, text=True)
                        self.assertEqual(result.returncode, 64, result.stderr)
                        self.assertIn("Apple Silicon", result.stderr)
                        self.assertFalse((root / "output").exists())

    def test_metadata_is_arm64_only_and_does_not_merge_retired_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            version = "1.2.3-beta.1"
            dmg = root / f"ScanStudio-{version}-macOS-arm64.dmg"
            dmg.write_bytes(b"signed DMG fixture")
            output = root / "metadata"
            command = ["/bin/zsh", str(SCRIPTS / "emit_release_assets.sh")]
            args = [str(dmg), version, str(output)]
            env = {**os.environ, "SCANSTUDIO_RELEASE_ARCH": "arm64"}

            def emit(arguments):
                return subprocess.run(command + arguments, env=env, capture_output=True, text=True)

            for arch in ("x86_64", "universal", "arm64 x86_64"):
                self.assertEqual(emit(args + [arch]).returncode, 64)
                self.assertFalse(output.exists())
            result = emit(args)
            self.assertEqual(result.returncode, 0, result.stderr)
            digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
            expected = {"version": version, "architectures": {"arm64": {
                "url": f"https://github.com/rohanpandula/ScanStudio/releases/download/v{version}/{dmg.name}",
                "sha256": digest}}}
            pointer = output / "latest.json"
            self.assertEqual(json.loads(pointer.read_text()), expected)
            self.assertEqual((output / "SHA256SUMS").read_text(), f"{digest}  {dmg.name}\n")
            self.assertEqual(emit(args).returncode, 73)
            pointer.write_text(json.dumps({"version": version, "architectures": {"x86_64": {}}}))
            self.assertEqual(emit(args).returncode, 73)
            self.assertEqual(emit(["-f"] + args).returncode, 0)
            self.assertEqual(json.loads(pointer.read_text()), expected)
            wrong = root / "ScanStudio-1.2.3-beta.1-macOS-x86_64.dmg"
            wrong.write_bytes(dmg.read_bytes())
            self.assertEqual(emit([str(wrong), version, str(root / "bad"), "arm64"]).returncode, 64)


if __name__ == "__main__":
    unittest.main()
