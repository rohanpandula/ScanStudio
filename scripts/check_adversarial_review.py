#!/usr/bin/env python3
"""Validate repository-safe adversarial-review evidence for a trusted base."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


EVIDENCE_ROOT = Path("docs/adversarial-reviews")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
FULL_COMMIT = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_ROLES = {"security-reliability", "cross-layer-correctness"}
REQUIRED_MODEL = "deepseek-v4-flash-0731"
REQUIRED_VARIANT = "high"
MAX_ARTIFACT_BYTES = 5 * 1_024 * 1_024
FORBIDDEN_ARTIFACT_PATTERNS = (
    (re.compile(r"-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"), "private key"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"), "GitHub token"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), "Slack token"),
    (re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"), "API key"),
    (re.compile(r"/(?:Users|home)/[^\s`\"']+"), "personal absolute path"),
    (re.compile(r"^GIT binary patch$", re.MULTILINE), "Git binary patch"),
    (re.compile(r"^Binary files .* differ$", re.MULTILINE), "binary diff summary"),
)


class EvidenceError(ValueError):
    pass


def git_bytes(*args: str) -> bytes:
    result = subprocess.run(
        ["git", *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise EvidenceError(f"{label} must be a non-empty string")
    return value


def require_sha256(value: Any, label: str) -> str:
    rendered = require_string(value, label)
    if HEX_SHA256.fullmatch(rendered) is None:
        raise EvidenceError(f"{label} must be a lowercase SHA-256 digest")
    return rendered


def require_commit(value: Any, label: str) -> str:
    rendered = require_string(value, label)
    if FULL_COMMIT.fullmatch(rendered) is None:
        raise EvidenceError(f"{label} must be a full lowercase Git commit ID")
    return rendered


def evidence_file(bundle: Path, value: Any, label: str) -> Path:
    name = require_string(value, label)
    if Path(name).name != name:
        raise EvidenceError(f"{label} must name a direct child of its evidence bundle")
    unresolved = bundle / name
    if unresolved.is_symlink():
        raise EvidenceError(f"{label} must not be a symlink")
    candidate = unresolved.resolve()
    try:
        candidate.relative_to(bundle.resolve())
    except ValueError as exc:
        raise EvidenceError(f"{label} escapes its evidence bundle") from exc
    if not candidate.is_file():
        raise EvidenceError(f"{label} does not exist: {name}")
    return candidate


def require_safe_artifact(value: bytes, label: str) -> bytes:
    if len(value) > MAX_ARTIFACT_BYTES:
        raise EvidenceError(f"{label} exceeds {MAX_ARTIFACT_BYTES} bytes")
    if b"\x00" in value:
        raise EvidenceError(f"{label} contains binary data")
    try:
        rendered = value.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise EvidenceError(f"{label} is not UTF-8 text") from exc
    for pattern, description in FORBIDDEN_ARTIFACT_PATTERNS:
        if pattern.search(rendered):
            raise EvidenceError(f"{label} contains a forbidden {description}")
    return value


def safe_artifact_bytes(path: Path, label: str) -> bytes:
    try:
        value = path.read_bytes()
    except OSError as exc:
        raise EvidenceError(f"cannot read {label}: {exc}") from exc
    return require_safe_artifact(value, label)


def canonical_diff(base: str, reviewed: str) -> bytes:
    return git_bytes(
        "-c",
        "core.quotePath=true",
        "--no-pager",
        "diff",
        "--binary",
        "--full-index",
        "--no-renames",
        "--no-ext-diff",
        "--no-textconv",
        "--no-color",
        "--diff-algorithm=histogram",
        "--indent-heuristic",
        "--inter-hunk-context=0",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--output-indicator-new=+",
        "--output-indicator-old=-",
        "--output-indicator-context= ",
        "--unified=3",
        base,
        reviewed,
    )


def validate_manifest(path: Path, expected_base: str) -> bool:
    bundle = path.parent
    try:
        manifest_bytes = safe_artifact_bytes(path, str(path))
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except (EvidenceError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"cannot read {path}: {exc}") from exc
    if not isinstance(manifest, dict):
        raise EvidenceError(f"{path} must contain a JSON object")
    if manifest.get("schemaVersion") != 1:
        raise EvidenceError(f"{path}: unsupported schemaVersion")

    base = require_commit(manifest.get("baseCommit"), "baseCommit")
    reviewed = require_commit(manifest.get("reviewedCommit"), "reviewedCommit")
    if base != expected_base:
        raise EvidenceError(
            f"{path}: baseCommit must equal the trusted review base {expected_base}"
        )
    if base == reviewed:
        raise EvidenceError(f"{path}: reviewedCommit must differ from baseCommit")
    git_bytes("cat-file", "-e", f"{base}^{{commit}}")
    git_bytes("cat-file", "-e", f"{reviewed}^{{commit}}")
    if subprocess.run(
        ["git", "merge-base", "--is-ancestor", base, reviewed],
        check=False,
    ).returncode != 0:
        raise EvidenceError(f"{path}: baseCommit is not an ancestor of reviewedCommit")
    if subprocess.run(
        ["git", "merge-base", "--is-ancestor", reviewed, "HEAD"],
        check=False,
    ).returncode != 0:
        raise EvidenceError(f"{path}: reviewedCommit is not an ancestor of HEAD")

    reviewed_diff = require_safe_artifact(
        canonical_diff(base, reviewed), f"{path}:canonical source diff"
    )
    if not reviewed_diff:
        raise EvidenceError(f"{path}: canonical source diff must not be empty")
    expected_diff = require_sha256(
        manifest.get("sourceDiffSha256"), "sourceDiffSha256"
    )
    actual_diff = sha256_bytes(reviewed_diff)
    if actual_diff != expected_diff:
        raise EvidenceError(
            f"{path}: source diff hash mismatch: expected {expected_diff}, got {actual_diff}"
        )

    reviewers = manifest.get("reviewers")
    if not isinstance(reviewers, list) or len(reviewers) != 2:
        raise EvidenceError(f"{path}: exactly two final reviewers are required")
    roles: set[str] = set()
    contexts: set[str] = set()
    artifacts: set[Path] = set()
    prompt_contents: set[bytes] = set()
    report_contents: set[bytes] = set()
    for index, reviewer in enumerate(reviewers):
        label = f"reviewers[{index}]"
        if not isinstance(reviewer, dict):
            raise EvidenceError(f"{path}: {label} must be an object")
        role = require_string(reviewer.get("role"), f"{label}.role")
        roles.add(role)
        context = require_string(reviewer.get("contextId"), f"{label}.contextId")
        contexts.add(context)
        if require_string(reviewer.get("tool"), f"{label}.tool") != "opencode":
            raise EvidenceError(f"{path}: {label}.tool must be opencode")
        require_string(reviewer.get("toolVersion"), f"{label}.toolVersion")
        require_string(reviewer.get("provider"), f"{label}.provider")
        if require_string(reviewer.get("model"), f"{label}.model") != REQUIRED_MODEL:
            raise EvidenceError(f"{path}: {label}.model must be {REQUIRED_MODEL}")
        if require_string(reviewer.get("variant"), f"{label}.variant") != REQUIRED_VARIANT:
            raise EvidenceError(f"{path}: {label}.variant must be {REQUIRED_VARIANT}")
        if reviewer.get("independent") is not True or reviewer.get("sawOtherReport") is not False:
            raise EvidenceError(f"{path}: {label} lacks the independence declaration")
        if reviewer.get("verdict") != "PASS":
            raise EvidenceError(f"{path}: {label}.verdict must be PASS")
        reviewer_input = require_sha256(
            reviewer.get("inputSha256"), f"{label}.inputSha256"
        )
        if reviewer_input != expected_diff:
            raise EvidenceError(
                f"{path}: {label}.inputSha256 must match sourceDiffSha256"
            )

        for kind in ("prompt", "report"):
            artifact = evidence_file(bundle, reviewer.get(kind), f"{label}.{kind}")
            artifacts.add(artifact)
            expected = require_sha256(
                reviewer.get(f"{kind}Sha256"), f"{label}.{kind}Sha256"
            )
            contents = safe_artifact_bytes(artifact, f"{path}:{label}.{kind}")
            if not contents.strip():
                raise EvidenceError(f"{path}: {label}.{kind} must not be empty")
            actual = sha256_bytes(contents)
            if actual != expected:
                raise EvidenceError(
                    f"{path}: {label}.{kind} hash mismatch: expected {expected}, got {actual}"
                )
            if kind == "prompt":
                prompt_contents.add(contents)
            else:
                rendered_report = contents.decode("utf-8").strip()
                final_line = rendered_report.splitlines()[-1].strip()
                verdicts = re.findall(
                    r"^VERDICT: (PASS|REQUEST_CHANGES|BLOCK)$",
                    rendered_report,
                    flags=re.MULTILINE,
                )
                if final_line != "VERDICT: PASS" or verdicts != ["PASS"]:
                    raise EvidenceError(
                        f"{path}: {label}.report must contain exactly one verdict, "
                        "VERDICT: PASS at EOF"
                    )
                report_contents.add(contents)

    if roles != REQUIRED_ROLES:
        raise EvidenceError(f"{path}: reviewer roles must be {sorted(REQUIRED_ROLES)}")
    if len(contexts) != 2:
        raise EvidenceError(f"{path}: reviewers must use distinct fresh contexts")
    if len(artifacts) != 4:
        raise EvidenceError(f"{path}: prompts and reports must be four distinct files")
    if len(prompt_contents) != 2:
        raise EvidenceError(f"{path}: reviewer prompts must be distinct")
    if len(report_contents) != 2:
        raise EvidenceError(f"{path}: reviewer reports must be distinct")
    if manifest.get("unresolvedBlockers") != 0:
        raise EvidenceError(f"{path}: unresolvedBlockers must be zero")

    declared_files = {path.resolve(), *artifacts}
    dispositions_name = manifest.get("dispositions")
    dispositions_hash = manifest.get("dispositionsSha256")
    if dispositions_name is not None or dispositions_hash is not None:
        dispositions = evidence_file(bundle, dispositions_name, "dispositions")
        dispositions_contents = safe_artifact_bytes(
            dispositions, f"{path}:dispositions"
        )
        if not dispositions_contents.strip():
            raise EvidenceError(f"{path}: dispositions must not be empty")
        actual_dispositions_hash = sha256_bytes(dispositions_contents)
        expected_dispositions_hash = require_sha256(
            dispositions_hash, "dispositionsSha256"
        )
        if actual_dispositions_hash != expected_dispositions_hash:
            raise EvidenceError(
                f"{path}: dispositions hash mismatch: expected "
                f"{expected_dispositions_hash}, got {actual_dispositions_hash}"
            )
        declared_files.add(dispositions)

    actual_files: set[Path] = set()
    for child in bundle.iterdir():
        if child.is_symlink() or not child.is_file():
            raise EvidenceError(f"{path}: evidence entries must be regular files: {child}")
        actual_files.add(child.resolve())
    if actual_files != declared_files:
        extras = sorted(str(item.name) for item in actual_files - declared_files)
        missing = sorted(str(item.name) for item in declared_files - actual_files)
        raise EvidenceError(
            f"{path}: evidence file declaration mismatch; extras={extras}, missing={missing}"
        )

    trailing = git_bytes(
        "diff", "--name-only", "--no-renames", "-z", reviewed, "HEAD"
    ).split(b"\0")
    trailing = [name.decode("utf-8") for name in trailing if name]
    if not trailing:
        raise EvidenceError(f"{path}: evidence must be committed after reviewedCommit")
    if path.as_posix() not in trailing:
        raise EvidenceError(f"{path}: its manifest must postdate reviewedCommit")
    repository_root = Path.cwd().resolve()
    declared_names = {
        item.relative_to(repository_root).as_posix() for item in declared_files
    }
    if set(trailing) != declared_names:
        extras = sorted(set(trailing) - declared_names)
        missing = sorted(declared_names - set(trailing))
        raise EvidenceError(
            f"{path}: post-review commit must contain exactly this bundle; "
            f"extras={extras}, missing={missing}"
        )
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repository",
        type=Path,
        default=Path.cwd(),
        help="candidate Git worktree to validate",
    )
    parser.add_argument(
        "--expected-base",
        help="trusted full commit ID for the PR/review base",
    )
    parser.add_argument(
        "--scan-artifact",
        type=Path,
        help="scan one prompt/diff/report for high-confidence unsafe content",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.scan_artifact is not None:
        try:
            safe_artifact_bytes(args.scan_artifact, str(args.scan_artifact))
        except EvidenceError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        print(f"review artifact safe to send: {args.scan_artifact}")
        return 0

    if args.expected_base is None:
        print("error: --expected-base is required", file=sys.stderr)
        return 2
    try:
        expected_base = require_commit(args.expected_base, "--expected-base")
        os.chdir(args.repository)
        git_bytes("cat-file", "-e", f"{expected_base}^{{commit}}")
    except (EvidenceError, OSError, subprocess.CalledProcessError) as exc:
        print(f"error: invalid repository or expected base: {exc}", file=sys.stderr)
        return 2

    try:
        dirty = git_bytes("status", "--porcelain=v1", "-z", "--untracked-files=all")
    except subprocess.CalledProcessError as exc:
        print(f"error: cannot inspect candidate worktree: {exc}", file=sys.stderr)
        return 1
    if dirty:
        print(
            "error: candidate worktree must be clean and fully committed",
            file=sys.stderr,
        )
        return 1

    manifests = sorted(EVIDENCE_ROOT.glob("*/manifest.json"))
    if not manifests:
        print(f"error: no adversarial-review manifest below {EVIDENCE_ROOT}", file=sys.stderr)
        return 1

    errors: list[str] = []
    covering: list[Path] = []
    for manifest in manifests:
        try:
            if validate_manifest(manifest, expected_base):
                covering.append(manifest)
        except (EvidenceError, subprocess.CalledProcessError) as exc:
            errors.append(str(exc))

    if not covering:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        print(
            "error: no valid review covers HEAD; non-evidence changes require a fresh review",
            file=sys.stderr,
        )
        return 1

    print(f"adversarial review evidence valid: {covering[-1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
