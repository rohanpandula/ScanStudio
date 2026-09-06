from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import ModuleType
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "release.yml"


def load(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


RESULTS = load(
    "verify_required_job_results",
    ROOT / "scripts" / "verify_required_job_results.py",
)
PROVENANCE = load(
    "release_provenance",
    ROOT / "scripts" / "release_provenance.py",
)
REMOTE_TAG = load(
    "verify_remote_release_tag",
    ROOT / "scripts" / "verify_remote_release_tag.py",
)
WORKFLOW = load(
    "verify_release_workflow",
    ROOT / "scripts" / "verify_release_workflow.py",
)


COMMIT = "0123456789abcdef0123456789abcdef01234567"
TAG = "v0.8.0-beta.1"
REPOSITORY = "owner/ScanStudio"
RUN_ID = 123456
RUN_ATTEMPT = 2


class RequiredJobResultTests(unittest.TestCase):
    def successful_payload(self) -> dict[str, dict[str, object]]:
        return {
            job: {"result": "success", "outputs": {}} for job in RESULTS.REQUIRED_JOBS
        }

    def test_exact_complete_success_set_passes(self) -> None:
        RESULTS.verify_required_job_results(self.successful_payload())

    def test_every_non_success_state_fails_closed(self) -> None:
        for state in ("failure", "cancelled", "skipped", "timed_out", ""):
            with self.subTest(state=state):
                payload = self.successful_payload()
                payload[RESULTS.REQUIRED_JOBS[0]]["result"] = state
                with self.assertRaisesRegex(
                    RESULTS.RequiredJobError, "did not succeed"
                ):
                    RESULTS.verify_required_job_results(payload)

    def test_missing_extra_and_malformed_results_fail_closed(self) -> None:
        missing = self.successful_payload()
        missing.pop(RESULTS.REQUIRED_JOBS[0])
        extra = self.successful_payload()
        extra["unreviewed-job"] = {"result": "success", "outputs": {}}
        malformed = self.successful_payload()
        malformed[RESULTS.REQUIRED_JOBS[0]] = "success"

        for payload in (missing, extra, malformed, [], None):
            with self.subTest(payload=payload):
                with self.assertRaises(RESULTS.RequiredJobError):
                    RESULTS.verify_required_job_results(payload)


class ReleaseProvenanceTests(unittest.TestCase):
    def identity(self, **overrides: object):
        values = {
            "repository": REPOSITORY,
            "run_id": RUN_ID,
            "run_attempt": RUN_ATTEMPT,
            "commit_sha": COMMIT,
            "tag": TAG,
        }
        values.update(overrides)
        return PROVENANCE.ReleaseIdentity(**values)

    def test_receipt_binds_exact_run_commit_tag_and_artifact_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "one.bin"
            second = root / "two.bin"
            first.write_bytes(b"one")
            second.write_bytes(b"two")
            receipt = root / "release.provenance.json"

            PROVENANCE.emit_receipt(receipt, [second, first], self.identity())
            payload = json.loads(receipt.read_text(encoding="utf-8"))
            self.assertEqual(payload["commit_sha"], COMMIT)
            self.assertEqual(
                [item["name"] for item in payload["artifacts"]],
                ["one.bin", "two.bin"],
            )
            PROVENANCE.verify_receipt(receipt, root, self.identity())

    def test_identity_or_artifact_change_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / "artifact.bin"
            artifact.write_bytes(b"original")
            receipt = root / "release.provenance.json"
            PROVENANCE.emit_receipt(receipt, [artifact], self.identity())

            for identity in (
                self.identity(commit_sha="f" * 40),
                self.identity(run_id=RUN_ID + 1),
                self.identity(run_attempt=RUN_ATTEMPT + 1),
                self.identity(tag="v0.8.0-beta.2"),
                self.identity(repository="other/ScanStudio"),
            ):
                with self.subTest(identity=identity):
                    with self.assertRaises(PROVENANCE.ProvenanceError):
                        PROVENANCE.verify_receipt(receipt, root, identity)

            artifact.write_bytes(b"changed")
            with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "size|digest"):
                PROVENANCE.verify_receipt(receipt, root, self.identity())

    def test_missing_extra_duplicate_and_symlink_artifacts_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / "artifact.bin"
            artifact.write_bytes(b"original")
            receipt = root / "release.provenance.json"

            with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "duplicate"):
                PROVENANCE.emit_receipt(receipt, [artifact, artifact], self.identity())

            PROVENANCE.emit_receipt(receipt, [artifact], self.identity())
            extra = root / "extra.bin"
            extra.write_bytes(b"extra")
            with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "file set"):
                PROVENANCE.verify_receipt(receipt, root, self.identity())
            extra.unlink()

            artifact.unlink()
            with self.assertRaises(PROVENANCE.ProvenanceError):
                PROVENANCE.verify_receipt(receipt, root, self.identity())

            target = root.parent / f"{root.name}-target.bin"
            target.write_bytes(b"target")
            artifact.symlink_to(target)
            try:
                with self.assertRaisesRegex(PROVENANCE.ProvenanceError, "regular file"):
                    PROVENANCE.verify_receipt(receipt, root, self.identity())
            finally:
                target.unlink()


class RemoteTagTests(unittest.TestCase):
    def git(self, cwd: Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        )
        return completed.stdout.strip()

    def make_remote(self, root: Path) -> tuple[Path, Path, str]:
        remote = root / "remote.git"
        source = root / "source"
        checkout = root / "checkout"
        self.git(root, "init", "--bare", str(remote))
        self.git(root, "init", str(source))
        self.git(source, "config", "user.name", "Release Test")
        self.git(source, "config", "user.email", "release@example.invalid")
        (source / "tracked.txt").write_text("one\n", encoding="utf-8")
        self.git(source, "add", "tracked.txt")
        self.git(source, "commit", "-m", "initial")
        commit = self.git(source, "rev-parse", "HEAD")
        self.git(source, "tag", TAG)
        self.git(source, "remote", "add", "origin", str(remote))
        self.git(source, "push", "origin", "HEAD:refs/heads/main", TAG)
        self.git(root, "clone", str(remote), str(checkout))
        self.git(checkout, "checkout", commit)
        return source, checkout, commit

    def test_remote_tag_is_pinned_and_replacement_or_movement_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, checkout, commit = self.make_remote(Path(temporary))
            first = REMOTE_TAG.verify_remote_release_tag(
                checkout,
                remote="origin",
                tag=TAG,
                expected_commit=commit,
                run_id=RUN_ID,
                run_attempt=RUN_ATTEMPT,
                stage="authorize",
            )
            self.assertEqual(first.commit_sha, commit)

            self.git(source, "tag", "-f", "-a", TAG, "-m", "replacement", commit)
            self.git(source, "push", "--force", "origin", TAG)
            with self.assertRaisesRegex(REMOTE_TAG.RemoteTagError, "object changed"):
                REMOTE_TAG.verify_remote_release_tag(
                    checkout,
                    remote="origin",
                    tag=TAG,
                    expected_commit=commit,
                    expected_object=first.object_sha,
                    run_id=RUN_ID,
                    run_attempt=RUN_ATTEMPT,
                    stage="draft",
                )

            (source / "tracked.txt").write_text("two\n", encoding="utf-8")
            self.git(source, "commit", "-am", "move")
            moved = self.git(source, "rev-parse", "HEAD")
            self.git(source, "tag", "-f", TAG, moved)
            self.git(source, "push", "--force", "origin", TAG)
            with self.assertRaisesRegex(REMOTE_TAG.RemoteTagError, "commit changed"):
                REMOTE_TAG.verify_remote_release_tag(
                    checkout,
                    remote="origin",
                    tag=TAG,
                    expected_commit=commit,
                    run_id=RUN_ID,
                    run_attempt=RUN_ATTEMPT,
                    stage="publish",
                )

    def test_deleted_remote_tag_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source, checkout, commit = self.make_remote(Path(temporary))
            self.git(source, "push", "origin", f":refs/tags/{TAG}")
            with self.assertRaisesRegex(REMOTE_TAG.RemoteTagError, "fetch"):
                REMOTE_TAG.verify_remote_release_tag(
                    checkout,
                    remote="origin",
                    tag=TAG,
                    expected_commit=commit,
                    run_id=RUN_ID,
                    run_attempt=RUN_ATTEMPT,
                    stage="draft",
                )


class WorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = WORKFLOW_PATH.read_text(encoding="utf-8")
        cls.verification_source = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

    def assert_rejected(self, source: str, expected: str) -> None:
        with self.assertRaisesRegex(WORKFLOW.ReleaseWorkflowError, expected):
            WORKFLOW.verify_release_workflow(source)

    def test_repository_release_workflow_passes_structural_policy(self) -> None:
        WORKFLOW.verify_release_workflow(self.source)

    def test_publish_download_must_supply_the_same_run_provenance_root(self) -> None:
        download = (
            "      - uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4.3.0\n"
            "        with:\n"
            "          name: ScanStudio-dmg-arm64\n"
            "          path: ${{ runner.temp }}/arm64\n"
        )
        self.assertIn(download, self.source)
        self.assert_rejected(self.source.replace(download, "", 1), "download")
        self.assert_rejected(
            self.source.replace(download, download.replace("/arm64", "/x86_64"), 1), "download"
        )

    def test_package_gates_cannot_restore_intel_or_tolerate_failure(self) -> None:
        self.assert_rejected(
            self.source.replace("runs-on: macos-15", "runs-on: macos-15-intel", 1),
            "Apple Silicon",
        )
        for original, replacement in (
            ("name: Self-contained package build (arm64)",
             "name: Self-contained package build (arm64)\n    strategy: {matrix: {arch: [arm64, x86_64]}}"),
            ("name: App and engine tests", "name: App and engine tests\n    continue-on-error: true"),
        ):
            with self.subTest(replacement=replacement), self.assertRaises(WORKFLOW.ReleaseWorkflowError):
                WORKFLOW.verify_release_workflow(
                    self.source, self.verification_source.replace(original, replacement, 1)
                )

    def test_called_verify_workflow_cannot_drop_a_family_or_policy_check(self) -> None:
        without_family = self.verification_source.replace(
            "      - updater-integration\n", "", 1
        )
        with self.assertRaisesRegex(
            WORKFLOW.ReleaseWorkflowError, "every required verification family"
        ):
            WORKFLOW.verify_release_workflow(self.source, without_family)

        without_policy = self.verification_source.replace(
            "python3 -I -S -B scripts/verify_release_workflow.py",
            "python3 -I -S -B scripts/ignored_release_workflow.py",
            1,
        )
        with self.assertRaisesRegex(
            WORKFLOW.ReleaseWorkflowError, "release workflow policy"
        ):
            WORKFLOW.verify_release_workflow(self.source, without_policy)

    def test_publication_cannot_bypass_or_soften_the_all_success_gate(self) -> None:
        self.assert_rejected(
            self.source.replace(
                "needs: [authorize, verify, verification-gate]",
                "needs: [release]",
                1,
            ),
            "publish needs",
        )
        self.assert_rejected(
            self.source.replace("if: ${{ always() }}", "if: ${{ success() }}", 1),
            "always",
        )
        self.assert_rejected(
            self.source.replace("      - release\n", "", 1),
            "verification-gate needs",
        )

    def test_exact_sha_checkout_provenance_and_tag_checks_are_required(self) -> None:
        self.assert_rejected(
            self.source.replace("          ref: ${{ github.sha }}\n", "", 1),
            "exact github.sha",
        )
        self.assert_rejected(
            self.source.replace(
                "python3 -I -S -B scripts/release_provenance.py verify",
                "python3 -I -S -B scripts/release_provenance.py ignored",
                1,
            ),
            "provenance",
        )
        self.assert_rejected(
            self.source.replace(
                "python3 -I -S -B scripts/verify_remote_release_tag.py",
                "python3 -I -S -B scripts/ignored_remote_tag.py",
                1,
            ),
            "remote tag",
        )
        self.assert_rejected(
            self.source.replace("            --verify-tag \\\n", "", 1),
            "verify-tag",
        )


class HistoricalClaimTests(unittest.TestCase):
    def test_beta12_record_discloses_the_failed_exact_commit_verify_runs(self) -> None:
        notes = (ROOT / "docs" / "releases" / "v0.7.0-beta.12.md").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("Full suites green on the release commit", notes)
        self.assertIn("exact-commit Verify runs failed", notes)
        self.assertIn("stale", notes)
        self.assertRegex(notes, r"not a\s+runtime package defect")


if __name__ == "__main__":
    unittest.main()
