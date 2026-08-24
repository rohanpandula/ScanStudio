from __future__ import annotations

import re
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def _read(relative: str) -> str:
    return (REPOSITORY_ROOT / relative).read_text(encoding="utf-8")


def _jobs(workflow_text: str) -> dict[str, list[str]]:
    """Map each top-level job name to its raw body lines (indent-2 keys)."""

    lines = workflow_text.splitlines()
    jobs_start = next(index for index, line in enumerate(lines) if line == "jobs:")
    lines = lines[jobs_start + 1 :]
    starts = [
        (index, match.group(1))
        for index, line in enumerate(lines)
        if (match := re.match(r"^ {2}([a-z0-9-]+):\s*$", line))
    ]
    jobs: dict[str, list[str]] = {}
    for position, (index, name) in enumerate(starts):
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        jobs[name] = lines[index + 1 : end]
    return jobs


def _needs(job_lines: list[str]) -> list[str]:
    for index, line in enumerate(job_lines):
        if re.match(r"^\s+needs:", line):
            inline = line.split(":", 1)[1].strip()
            if inline:
                return [
                    item.strip()
                    for item in inline.strip("[]").split(",")
                    if item.strip()
                ]
            needed: list[str] = []
            for following in job_lines[index + 1 :]:
                match = re.match(r"^\s+-\s+(\S+)\s*$", following)
                if not match:
                    break
                needed.append(match.group(1))
            return needed
    return []


class ReleaseGateStructure(unittest.TestCase):
    """#104: publication cannot bypass same-run verification of the tag.

    A release may be drafted or published only after the complete required
    verification set succeeds for the exact tagged commit, as a direct
    same-run dependency of the Release workflow itself.
    """

    def setUp(self) -> None:
        self.ci_text = _read(".github/workflows/ci.yml")
        self.release_text = _read(".github/workflows/release.yml")
        self.jobs = _jobs(self.release_text)

    def test_verify_workflow_is_reusable_by_the_release_workflow(self) -> None:
        self.assertIn("workflow_call:", self.ci_text.split("jobs:", 1)[0])

    def test_release_invokes_the_verification_workflow_in_run(self) -> None:
        self.assertIn("verify", self.jobs)
        verify_body = "\n".join(self.jobs["verify"])
        self.assertIn("uses: ./.github/workflows/ci.yml", verify_body)

    def test_every_artifact_producing_entry_point_depends_on_verify(self) -> None:
        def reaches_verify(name: str, seen: frozenset[str] = frozenset()) -> bool:
            if name in seen or name not in self.jobs:
                return False
            body = self.jobs[name]
            if "uses: ./.github/workflows/ci.yml" in "\n".join(body):
                return True
            return any(
                reaches_verify(dep, seen | {name}) for dep in _needs(body)
            )

        for name, body in self.jobs.items():
            if name in ("verify", "authorize"):
                continue
            with self.subTest(job=name):
                needed = _needs(body)
                self.assertTrue(
                    needed,
                    f"{name!r} has no needs:; it could run unverified (#104)",
                )
                self.assertTrue(
                    "verify" in needed or reaches_verify(name),
                    f"{name!r} does not transitively depend on the same-run "
                    "verify job (#104)",
                )

    def test_authorize_keeps_proving_the_tag_resolves_to_the_built_sha(
        self,
    ) -> None:
        body = "\n".join(self.jobs["authorize"])
        self.assertIn('refs/tags/$GITHUB_REF_NAME^{commit}"', body)
        self.assertIn("$GITHUB_SHA", body)

    def test_publish_reproves_tag_integrity_before_draft_and_before_publication(
        self,
    ) -> None:
        occurrences = "\n".join(self.jobs["publish"]).count(
            'test "$RESOLVED" = "$GITHUB_SHA"'
        )
        self.assertGreaterEqual(
            occurrences,
            2,
            "publish must re-prove remote tag integrity immediately before "
            f"draft creation AND again before publication (#104); found {occurrences}",
        )


if __name__ == "__main__":
    unittest.main()
