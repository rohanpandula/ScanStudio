from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = ROOT / "scripts" / "verify_remote_release_tag.py"


def run(*args: str, cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1"},
    )


class ReleaseVerificationGateTests(unittest.TestCase):
    def test_workflow_has_same_run_required_gate_and_two_remote_tag_checks(
        self,
    ) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("workflow_call:", ci)
        self.assertIn("verification-gate:", ci)
        for family in (
            "app-and-engine",
            "bridge",
            "coolscanpy",
            "supply-chain-policy",
            "package",
            "package-macos-14",
            "updater-integration",
        ):
            self.assertIn('test "${{ needs.' + family + '.result }}" = success', ci)

        self.assertIn("uses: ./.github/workflows/ci.yml", release)
        self.assertIn("needs: [authorize, verify, verification-gate]", release)
        self.assertIn('test "$VERIFIED_SHA" = "$GITHUB_SHA"', release)
        self.assertEqual(release.count("scripts/verify_remote_release_tag.py"), 3)
        self.assertLess(
            release.index("scripts/verify_remote_release_tag.py"),
            release.index("gh release create"),
        )
        self.assertLess(
            release.rindex("scripts/verify_remote_release_tag.py"),
            release.index("gh release edit"),
        )

    def test_remote_tag_equality_accepts_exact_commit_and_rejects_movement(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            remote = base / "remote.git"
            work = base / "work"
            verifier = base / "verifier"
            run("git", "init", "--bare", str(remote), cwd=base)
            run("git", "init", str(work), cwd=base)
            run("git", "config", "user.name", "ScanStudio Test", cwd=work)
            run("git", "config", "user.email", "test@example.invalid", cwd=work)
            (work / "value").write_text("one\n", encoding="utf-8")
            run("git", "add", "value", cwd=work)
            run("git", "commit", "-m", "one", cwd=work)
            first = run("git", "rev-parse", "HEAD", cwd=work).stdout.strip()
            run("git", "tag", "v1.0.0", cwd=work)
            run("git", "remote", "add", "origin", str(remote), cwd=work)
            run("git", "push", "origin", "HEAD", "refs/tags/v1.0.0", cwd=work)
            run("git", "clone", str(remote), str(verifier), cwd=base)
            run("git", "checkout", first, cwd=verifier)

            command = (
                "python3",
                str(VERIFY_SCRIPT),
                "--tag",
                "v1.0.0",
                "--expected-commit",
                first,
                "--run-id",
                "1",
                "--run-attempt",
                "1",
                "--stage",
                "draft",
                "--remote",
                "origin",
            )
            run(*command, cwd=verifier)

            (work / "value").write_text("two\n", encoding="utf-8")
            run("git", "add", "value", cwd=work)
            run("git", "commit", "-m", "two", cwd=work)
            run("git", "tag", "-f", "v1.0.0", cwd=work)
            run("git", "push", "--force", "origin", "refs/tags/v1.0.0", cwd=work)

            moved = run(
                *command,
                cwd=verifier,
                check=False,
            )
            self.assertNotEqual(moved.returncode, 0)
            self.assertIn("expected", moved.stderr)


if __name__ == "__main__":
    unittest.main()
