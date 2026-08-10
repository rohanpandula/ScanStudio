#!/usr/bin/env python3
"""Validate repository-safe, request-bound adversarial-review evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import unicodedata
from pathlib import Path
from typing import Any

from adversarial_review_input import (
    MAX_REQUEST_BYTES,
    MAX_SHARD_BYTES,
    MAX_SHARD_CHANGED_LINES,
    ReviewInputError,
    build_review_request,
    canonical_diff,
    explicit_shard_input,
    file_patches,
    full_diff_input,
    git_bytes,
    read_regular_file,
    strict_json_loads,
)


EVIDENCE_ROOT = Path("docs/adversarial-reviews")
SCRIPT_REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
TRUSTED_PROMPT_FILES = {
    "security-reliability": SCRIPT_REPOSITORY_ROOT
    / "docs/adversarial-review-prompts/security-reliability.txt",
    "cross-layer-correctness": SCRIPT_REPOSITORY_ROOT
    / "docs/adversarial-review-prompts/cross-layer-correctness.txt",
}
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
FULL_COMMIT = re.compile(r"^[0-9a-f]{40}$")
CONTEXT_ID = re.compile(r"^ses_[A-Za-z0-9]+$")
TOOL_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
REQUIRED_ROLES = set(TRUSTED_PROMPT_FILES)
REQUIRED_PROVIDER = "openrouter"
REQUIRED_MODEL = "deepseek-v4-flash-0731"
REQUIRED_VARIANT = "high"
MAX_ARTIFACT_BYTES = 5 * 1_024 * 1_024
MAX_TITLE_BYTES = 200
MIN_REPORT_BODY_BYTES = 160
MIN_REPORT_BODY_LINES = 3
FAILED_HIGH_FINISH = {
    "EMPTY_REPORT": "stop",
    "NO_FINAL_VERDICT": "stop",
    "OUTPUT_LIMIT": "length",
}
FORBIDDEN_ARTIFACT_PATTERNS = (
    (
        re.compile(
            r"-----BEGIN (?:(?:RSA |OPENSSH |EC |DSA |ENCRYPTED )?PRIVATE KEY|"
            r"PGP PRIVATE KEY BLOCK)-----"
        ),
        "private key",
    ),
    (re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"), "GitHub token"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), "Slack token"),
    (re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"), "API key"),
    (re.compile(r"/(?:Users|home)/[^\s`\"']+"), "personal absolute path"),
    (re.compile(r"^GIT binary patch$", re.MULTILINE), "Git binary patch"),
    (re.compile(r"^Binary files .* differ$", re.MULTILINE), "binary diff summary"),
)


class EvidenceError(ValueError):
    pass


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be an object")
    return value


def require_exact_keys(
    value: dict[str, Any], *, required: set[str], optional: set[str], label: str
) -> None:
    missing = sorted(required - set(value))
    unknown = sorted(set(value) - required - optional)
    if missing or unknown:
        raise EvidenceError(
            f"{label} keys mismatch; missing={missing}, unknown={unknown}"
        )


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or not value.strip():
        raise EvidenceError(f"{label} must be a non-whitespace string")
    return value


def require_int(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise EvidenceError(f"{label} must be a non-negative integer")
    return value


def require_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise EvidenceError(f"{label} must be a boolean")
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


def require_context_id(value: Any, label: str) -> str:
    rendered = require_string(value, label)
    if CONTEXT_ID.fullmatch(rendered) is None:
        raise EvidenceError(f"{label} must be an OpenCode ses_ context ID")
    return rendered


def require_tool_version(value: Any, label: str) -> str:
    rendered = require_string(value, label)
    if TOOL_VERSION.fullmatch(rendered) is None:
        raise EvidenceError(f"{label} must be a semver-like OpenCode version")
    return rendered


def require_path_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list):
        raise EvidenceError(f"{label} must be an array")
    paths: list[str] = []
    for index, item in enumerate(value):
        path = require_string(item, f"{label}[{index}]")
        candidate = Path(path)
        if (
            candidate.is_absolute()
            or candidate.as_posix() != path
            or any(part in ("", ".", "..") for part in candidate.parts)
        ):
            raise EvidenceError(
                f"{label}[{index}] must be a normalized repository path"
            )
        paths.append(path)
    if len(paths) != len(set(paths)):
        raise EvidenceError(f"{label} must not contain duplicates")
    return paths


def evidence_file(bundle: Path, value: Any, label: str) -> Path:
    name = require_string(value, label)
    if Path(name).name != name or name in {".", ".."}:
        raise EvidenceError(f"{label} must name a direct child of its evidence bundle")
    return bundle / name


def normalized_repository_path(
    path: Path, repository_root: Path, label: str
) -> tuple[Path, Path]:
    root = Path(os.path.abspath(repository_root))
    candidate = Path(os.path.abspath(path if path.is_absolute() else root / path))
    try:
        relative = candidate.relative_to(root)
    except ValueError as exc:
        raise EvidenceError(f"{label} is outside the candidate repository") from exc
    if not relative.parts or any(part in ("", ".", "..") for part in relative.parts):
        raise EvidenceError(f"{label} is not a normalized repository file")
    return candidate, relative


def open_directory_beneath(repository_root: Path, relative: Path, label: str) -> int:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(repository_root, flags)
    except OSError as exc:
        raise EvidenceError(f"cannot open repository root for {label}: {exc}") from exc
    try:
        for part in relative.parts:
            next_descriptor = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except OSError as exc:
        os.close(descriptor)
        raise EvidenceError(
            f"{label} must stay beneath non-symlink repository directories: {exc}"
        ) from exc


def open_regular_file_beneath(
    path: Path, repository_root: Path, label: str
) -> tuple[int, Path]:
    candidate, relative = normalized_repository_path(path, repository_root, label)
    directory = open_directory_beneath(repository_root, relative.parent, label)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(relative.name, flags, dir_fd=directory)
    except OSError as exc:
        raise EvidenceError(f"cannot open {label}: {exc}") from exc
    finally:
        os.close(directory)
    mode = os.fstat(descriptor).st_mode
    if not stat.S_ISREG(mode):
        os.close(descriptor)
        raise EvidenceError(f"{label} must be a regular non-symlink file")
    return descriptor, candidate


def read_regular_file_beneath(
    path: Path, repository_root: Path, label: str, max_bytes: int
) -> tuple[Path, bytes]:
    descriptor, candidate = open_regular_file_beneath(path, repository_root, label)
    try:
        size = os.fstat(descriptor).st_size
        if size > max_bytes:
            raise EvidenceError(f"{label} exceeds {max_bytes} bytes")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(64 * 1024, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise EvidenceError(f"{label} exceeds {max_bytes} bytes")
        return candidate, b"".join(chunks)
    finally:
        os.close(descriptor)


def regular_direct_children_beneath(
    bundle: Path, repository_root: Path, label: str
) -> set[Path]:
    candidate, relative = normalized_repository_path(bundle, repository_root, label)
    descriptor = open_directory_beneath(repository_root, relative, label)
    try:
        children: set[Path] = set()
        for name in os.listdir(descriptor):
            try:
                mode = os.stat(name, dir_fd=descriptor, follow_symlinks=False).st_mode
            except OSError as exc:
                raise EvidenceError(f"cannot inspect {label}/{name}: {exc}") from exc
            if not stat.S_ISREG(mode):
                raise EvidenceError(
                    f"{label} entries must be regular non-symlink files: {name}"
                )
            children.add(candidate / name)
        return children
    finally:
        os.close(descriptor)


def require_path_without_symlink_ancestors(
    path: Path, repository_root: Path, label: str
) -> Path:
    """Open a repository file through descriptor-relative, no-follow traversal."""

    descriptor, candidate = open_regular_file_beneath(path, repository_root, label)
    os.close(descriptor)
    return candidate


def git_tree_entries(treeish: str, label: str) -> list[tuple[str, str, str, bytes]]:
    """Return raw-name Git tree entries without invoking pathspec matching."""

    try:
        raw = git_bytes("ls-tree", "-z", treeish)
    except (ReviewInputError, subprocess.CalledProcessError) as exc:
        raise EvidenceError(f"cannot inspect {label} in Git: {exc}") from exc
    entries: list[tuple[str, str, str, bytes]] = []
    for encoded in (item for item in raw.split(b"\0") if item):
        try:
            metadata, name = encoded.split(b"\t", 1)
            mode_bytes, kind_bytes, object_bytes = metadata.split(b" ", 2)
            mode = mode_bytes.decode("ascii")
            kind = kind_bytes.decode("ascii")
            object_id = object_bytes.decode("ascii")
        except (ValueError, UnicodeDecodeError) as exc:
            raise EvidenceError(f"{label} has an invalid Git tree entry") from exc
        if FULL_COMMIT.fullmatch(object_id) is None:
            raise EvidenceError(f"{label} has an invalid Git object ID")
        entries.append((mode, kind, object_id, name))
    return entries


def committed_blob_bytes(
    commit: str,
    path: Path,
    label: str,
    max_bytes: int = MAX_ARTIFACT_BYTES,
) -> bytes:
    """Read one regular blob by object ID from an immutable commit tree."""

    if (
        path.is_absolute()
        or not path.parts
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise EvidenceError(f"{label} is not a normalized repository path")
    try:
        wanted_name = path.name.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise EvidenceError(f"{label} path is not valid UTF-8") from exc
    parent = path.parent
    treeish = commit if parent == Path(".") else f"{commit}:{parent.as_posix()}"
    matches = [
        entry for entry in git_tree_entries(treeish, label) if entry[3] == wanted_name
    ]
    if len(matches) != 1:
        raise EvidenceError(f"{label} is absent or ambiguous in expected-tip Git tree")
    mode, kind, object_id, _name = matches[0]
    if mode not in {"100644", "100755"} or kind != "blob":
        raise EvidenceError(f"{label} must be a regular file in expected-tip Git tree")
    try:
        size_raw = git_bytes("cat-file", "-s", object_id)
        size = int(size_raw.strip())
    except (ReviewInputError, subprocess.CalledProcessError, ValueError) as exc:
        raise EvidenceError(f"cannot size {label} Git blob: {exc}") from exc
    if size < 0 or size > max_bytes:
        raise EvidenceError(f"{label} exceeds {max_bytes} bytes")
    try:
        value = git_bytes("cat-file", "blob", object_id)
    except (ReviewInputError, subprocess.CalledProcessError) as exc:
        raise EvidenceError(f"cannot read {label} Git blob: {exc}") from exc
    if len(value) != size:
        raise EvidenceError(f"{label} Git blob length changed while reading")
    return value


def safe_committed_artifact_bytes(commit: str, path: Path, label: str) -> bytes:
    return require_safe_artifact(
        committed_blob_bytes(commit, path, label),
        label,
    )


def committed_regular_direct_children(
    commit: str, bundle: Path, label: str
) -> set[Path]:
    treeish = f"{commit}:{bundle.as_posix()}"
    children: set[Path] = set()
    for mode, kind, _object_id, raw_name in git_tree_entries(treeish, label):
        try:
            name = raw_name.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise EvidenceError(f"{label} contains a non-UTF-8 artifact name") from exc
        if not name or Path(name).name != name or name in {".", ".."}:
            raise EvidenceError(f"{label} contains an invalid direct-child name")
        if mode not in {"100644", "100755"} or kind != "blob":
            raise EvidenceError(
                f"{label} entries must be regular files in expected-tip Git tree: {name}"
            )
        children.add(bundle / name)
    return children


def committed_manifest_paths(commit: str) -> list[Path]:
    """Enumerate evidence manifests from the expected-tip tree, not the checkout."""

    bundles = git_tree_entries(f"{commit}:{EVIDENCE_ROOT.as_posix()}", "evidence root")
    manifests: list[Path] = []
    for mode, kind, _object_id, raw_name in bundles:
        if mode != "040000" or kind != "tree":
            continue
        try:
            name = raw_name.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise EvidenceError(
                "evidence root contains a non-UTF-8 bundle name"
            ) from exc
        if not name or Path(name).name != name or name in {".", ".."}:
            raise EvidenceError("evidence root contains an invalid bundle name")
        manifest = EVIDENCE_ROOT / name / "manifest.json"
        entries = git_tree_entries(
            f"{commit}:{manifest.parent.as_posix()}", f"evidence bundle {name}"
        )
        matching = [entry for entry in entries if entry[3] == b"manifest.json"]
        if matching:
            manifests.append(manifest)
    return sorted(manifests)


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


def require_safe_title(value: bytes, label: str) -> bytes:
    require_safe_artifact(value, label)
    if not value or len(value) > MAX_TITLE_BYTES:
        raise EvidenceError(f"{label} must contain 1-{MAX_TITLE_BYTES} UTF-8 bytes")
    rendered = value.decode("utf-8")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in rendered):
        raise EvidenceError(f"{label} contains control characters")
    return value


def safe_artifact_bytes(path: Path, label: str) -> bytes:
    repository_root = Path.cwd().resolve()
    try:
        _candidate, relative = normalized_repository_path(path, repository_root, label)
    except EvidenceError:
        relative = None
    try:
        if relative is None:
            value = read_regular_file(path, label, MAX_ARTIFACT_BYTES)
        else:
            _candidate, value = read_regular_file_beneath(
                path, repository_root, label, MAX_ARTIFACT_BYTES
            )
    except (OSError, ReviewInputError, EvidenceError) as exc:
        raise EvidenceError(f"cannot read {label}: {exc}") from exc
    return require_safe_artifact(value, label)


def trusted_prompt_bytes() -> dict[str, bytes]:
    prompts: dict[str, bytes] = {}
    for role, path in TRUSTED_PROMPT_FILES.items():
        if path.is_symlink():
            raise EvidenceError(f"trusted prompt for {role} must not be a symlink")
        try:
            contents = read_regular_file(
                path, f"trusted prompt for {role}", MAX_ARTIFACT_BYTES
            )
        except (OSError, ReviewInputError) as exc:
            raise EvidenceError(
                f"cannot read trusted prompt for {role}: {exc}"
            ) from exc
        require_safe_artifact(contents, f"trusted prompt for {role}")
        if not contents.strip():
            raise EvidenceError(f"trusted prompt for {role} must not be empty")
        prompts[role] = contents
    if len(set(prompts.values())) != len(prompts):
        raise EvidenceError("trusted role prompts must have distinct contents")
    return prompts


def validate_hashed_artifact(
    bundle: Path,
    owner: dict[str, Any],
    kind: str,
    label: str,
    artifacts: set[Path],
    expected_tip: str,
) -> tuple[Path, bytes]:
    artifact = evidence_file(bundle, owner.get(kind), f"{label}.{kind}")
    if artifact in artifacts:
        raise EvidenceError(f"{label}.{kind} must name a distinct artifact")
    expected = require_sha256(owner.get(f"{kind}Sha256"), f"{label}.{kind}Sha256")
    contents = safe_committed_artifact_bytes(expected_tip, artifact, f"{label}.{kind}")
    if not contents.strip():
        raise EvidenceError(f"{label}.{kind} must not be empty")
    actual = sha256_bytes(contents)
    if actual != expected:
        raise EvidenceError(
            f"{label}.{kind} hash mismatch: expected {expected}, got {actual}"
        )
    artifacts.add(artifact)
    return artifact, contents


def validate_report(contents: bytes, label: str) -> None:
    rendered = contents.decode("utf-8").replace("\r\n", "\n")
    for character in rendered:
        if character not in {"\n", "\t"} and unicodedata.category(character) in {
            "Cc",
            "Cf",
            "Cs",
            "Zl",
            "Zp",
        }:
            raise EvidenceError(
                f"{label} contains an ambiguous control or line separator"
            )
    rendered = rendered.strip()
    verdicts = re.findall(
        r"^VERDICT: (PASS|REQUEST_CHANGES|BLOCK)$", rendered, flags=re.MULTILINE
    )
    if not rendered or rendered.splitlines()[-1].strip() != "VERDICT: PASS":
        raise EvidenceError(f"{label} must end with VERDICT: PASS")
    if verdicts != ["PASS"]:
        raise EvidenceError(f"{label} must contain exactly one verdict")
    body = "\n".join(rendered.splitlines()[:-1]).strip()
    body_lines = [line for line in body.splitlines() if line.strip()]
    if (
        len(body.encode("utf-8")) < MIN_REPORT_BODY_BYTES
        or len(body_lines) < MIN_REPORT_BODY_LINES
    ):
        raise EvidenceError(
            f"{label} must contain a substantive review before its verdict"
        )


def validate_review(
    *,
    bundle: Path,
    review: Any,
    label: str,
    expected_input: bytes,
    required_variant: str,
    artifacts: set[Path],
    contexts: set[str],
    tool_versions: set[str],
    trusted_prompts: dict[str, bytes],
    prompt_artifact_by_role: dict[str, Path],
    report_contents: set[bytes],
    expected_tip: str,
) -> str:
    item = require_object(review, label)
    require_exact_keys(
        item,
        required={
            "role",
            "contextId",
            "tool",
            "toolVersion",
            "provider",
            "model",
            "variant",
            "finish",
            "independent",
            "sawOtherReport",
            "verdict",
            "inputSha256",
            "requestSha256",
            "prompt",
            "promptSha256",
            "report",
            "reportSha256",
        },
        optional=set(),
        label=label,
    )
    role = require_string(item.get("role"), f"{label}.role")
    if role not in REQUIRED_ROLES:
        raise EvidenceError(f"{label}.role is not a required reviewer role")
    context = require_context_id(item.get("contextId"), f"{label}.contextId")
    if context in contexts:
        raise EvidenceError(f"{label}.contextId must be globally unique")
    contexts.add(context)
    if item.get("tool") != "opencode":
        raise EvidenceError(f"{label}.tool must be opencode")
    tool_versions.add(
        require_tool_version(item.get("toolVersion"), f"{label}.toolVersion")
    )
    if item.get("provider") != REQUIRED_PROVIDER or item.get("model") != REQUIRED_MODEL:
        raise EvidenceError(f"{label} must use the pinned provider/model")
    if item.get("variant") != required_variant:
        raise EvidenceError(f"{label}.variant must be {required_variant}")
    if item.get("finish") != "stop":
        raise EvidenceError(f"{label}.finish must be stop")
    if item.get("independent") is not True or item.get("sawOtherReport") is not False:
        raise EvidenceError(f"{label} lacks the independence declaration")
    if item.get("verdict") != "PASS":
        raise EvidenceError(f"{label}.verdict must be PASS")
    input_hash = sha256_bytes(expected_input)
    if require_sha256(item.get("inputSha256"), f"{label}.inputSha256") != input_hash:
        raise EvidenceError(f"{label}.inputSha256 does not match its review input")
    try:
        expected_request = build_review_request(trusted_prompts[role], expected_input)
    except ReviewInputError as exc:
        raise EvidenceError(f"{label} request is not bounded: {exc}") from exc
    if len(expected_request) > MAX_REQUEST_BYTES:
        raise EvidenceError(f"{label} request exceeds {MAX_REQUEST_BYTES} bytes")
    if require_sha256(
        item.get("requestSha256"), f"{label}.requestSha256"
    ) != sha256_bytes(expected_request):
        raise EvidenceError(f"{label}.requestSha256 does not match prompt plus input")

    prompt_path = evidence_file(bundle, item.get("prompt"), f"{label}.prompt")
    prompt_contents = safe_committed_artifact_bytes(
        expected_tip, prompt_path, f"{label}.prompt"
    )
    if prompt_contents != trusted_prompts[role]:
        raise EvidenceError(f"{label}.prompt does not match trusted {role} prompt")
    if sha256_bytes(prompt_contents) != require_sha256(
        item.get("promptSha256"), f"{label}.promptSha256"
    ):
        raise EvidenceError(f"{label}.prompt hash mismatch")
    previous_prompt = prompt_artifact_by_role.get(role)
    if previous_prompt is None:
        if prompt_path in artifacts or prompt_path in prompt_artifact_by_role.values():
            raise EvidenceError(f"{label}.prompt collides with another artifact")
        prompt_artifact_by_role[role] = prompt_path
        artifacts.add(prompt_path)
    elif previous_prompt != prompt_path:
        raise EvidenceError(f"{label}.prompt must reuse the role's one artifact")

    _report_path, report = validate_hashed_artifact(
        bundle, item, "report", label, artifacts, expected_tip
    )
    validate_report(report, f"{label}.report")
    if report in report_contents:
        raise EvidenceError(f"{label}.report must be distinct from every other report")
    report_contents.add(report)
    return role


def validate_failure_receipt(
    *,
    bundle: Path,
    reference: Any,
    label: str,
    base: str,
    reviewed: str,
    expected_input: bytes,
    artifacts: set[Path],
    contexts: set[str],
    tool_versions: set[str],
    trusted_prompts: dict[str, bytes],
    expected_tip: str,
) -> str:
    item = require_object(reference, label)
    require_exact_keys(
        item,
        required={"receipt", "receiptSha256"},
        optional=set(),
        label=label,
    )
    _receipt_path, raw = validate_hashed_artifact(
        bundle, item, "receipt", label, artifacts, expected_tip
    )
    try:
        receipt = require_object(strict_json_loads(raw), f"{label}.receipt")
    except (
        UnicodeDecodeError,
        ValueError,
        RecursionError,
        MemoryError,
        OverflowError,
    ) as exc:
        raise EvidenceError(f"{label}.receipt is not safe valid JSON") from exc
    require_exact_keys(
        receipt,
        required={
            "schemaVersion",
            "baseCommit",
            "reviewedCommit",
            "role",
            "contextId",
            "tool",
            "toolVersion",
            "provider",
            "model",
            "variant",
            "finish",
            "inputSha256",
            "requestSha256",
            "outcome",
        },
        optional=set(),
        label=f"{label}.receipt",
    )
    canonical = (
        json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    )
    if raw != canonical:
        raise EvidenceError(f"{label}.receipt must use canonical JSON encoding")
    if require_int(receipt.get("schemaVersion"), f"{label}.receipt.schemaVersion") != 1:
        raise EvidenceError(f"{label}.receipt schemaVersion must be 1")
    if receipt.get("baseCommit") != base or receipt.get("reviewedCommit") != reviewed:
        raise EvidenceError(
            f"{label}.receipt must bind the same base and reviewed head"
        )
    role = require_string(receipt.get("role"), f"{label}.receipt.role")
    if role not in REQUIRED_ROLES:
        raise EvidenceError(f"{label}.receipt.role is invalid")
    context = require_context_id(receipt.get("contextId"), f"{label}.receipt.contextId")
    if context in contexts:
        raise EvidenceError(f"{label}.receipt.contextId must be globally unique")
    contexts.add(context)
    if receipt.get("tool") != "opencode":
        raise EvidenceError(f"{label}.receipt.tool must be opencode")
    tool_versions.add(
        require_tool_version(receipt.get("toolVersion"), f"{label}.receipt.toolVersion")
    )
    if (
        receipt.get("provider") != REQUIRED_PROVIDER
        or receipt.get("model") != REQUIRED_MODEL
    ):
        raise EvidenceError(f"{label}.receipt must use the pinned provider/model")
    if receipt.get("variant") != REQUIRED_VARIANT:
        raise EvidenceError(f"{label}.receipt.variant must be high")
    input_hash = sha256_bytes(expected_input)
    if (
        require_sha256(receipt.get("inputSha256"), f"{label}.receipt.inputSha256")
        != input_hash
    ):
        raise EvidenceError(f"{label}.receipt input hash mismatch")
    try:
        request = build_review_request(trusted_prompts[role], expected_input)
    except ReviewInputError as exc:
        raise EvidenceError(f"{label}.receipt request is not bounded: {exc}") from exc
    if len(request) > MAX_REQUEST_BYTES:
        raise EvidenceError(
            f"{label}.receipt request exceeds {MAX_REQUEST_BYTES} bytes"
        )
    request_hash = sha256_bytes(request)
    if (
        require_sha256(receipt.get("requestSha256"), f"{label}.receipt.requestSha256")
        != request_hash
    ):
        raise EvidenceError(f"{label}.receipt request hash mismatch")
    outcome = require_string(receipt.get("outcome"), f"{label}.receipt.outcome")
    if outcome not in FAILED_HIGH_FINISH:
        raise EvidenceError(f"{label}.receipt outcome is invalid")
    if receipt.get("finish") != FAILED_HIGH_FINISH[outcome]:
        raise EvidenceError(f"{label}.receipt outcome/finish mapping is invalid")
    return role


def validate_failed_high_attempts(
    value: Any,
    *,
    bundle: Path,
    base: str,
    reviewed: str,
    expected_input: bytes,
    final_roles: set[str],
    label: str,
    artifacts: set[Path],
    contexts: set[str],
    tool_versions: set[str],
    trusted_prompts: dict[str, bytes],
    expected_tip: str,
) -> None:
    fallback = require_object(value, label)
    require_exact_keys(
        fallback,
        required={"rationale", "failedHighAttempts"},
        optional=set(),
        label=label,
    )
    rationale = require_string(fallback.get("rationale"), f"{label}.rationale")
    if len(rationale) > 2_000:
        raise EvidenceError(f"{label}.rationale must be concise")
    attempts = fallback.get("failedHighAttempts")
    if not isinstance(attempts, list) or not attempts:
        raise EvidenceError(f"{label}.failedHighAttempts must be a non-empty array")
    attempt_roles: set[str] = set()
    for index, attempt in enumerate(attempts):
        attempt_roles.add(
            validate_failure_receipt(
                bundle=bundle,
                reference=attempt,
                label=f"{label}.failedHighAttempts[{index}]",
                base=base,
                reviewed=reviewed,
                expected_input=expected_input,
                artifacts=artifacts,
                contexts=contexts,
                tool_versions=tool_versions,
                trusted_prompts=trusted_prompts,
                expected_tip=expected_tip,
            )
        )
    if not final_roles.issubset(attempt_roles):
        raise EvidenceError(
            f"{label} needs a same-role failed high attempt per low review"
        )


def validate_manifest(path: Path, expected_base: str, expected_tip: str) -> bool:
    repository_root = Path.cwd().resolve()
    _candidate, path = normalized_repository_path(path, repository_root, str(path))
    if (
        len(path.parts) != 4
        or path.parts[:2] != EVIDENCE_ROOT.parts
        or path.name != "manifest.json"
    ):
        raise EvidenceError(f"{path}: manifest path is outside one evidence bundle")
    bundle = path.parent
    try:
        manifest_bytes = safe_committed_artifact_bytes(expected_tip, path, str(path))
        manifest = require_object(strict_json_loads(manifest_bytes), str(path))
    except (
        EvidenceError,
        UnicodeDecodeError,
        ValueError,
        RecursionError,
        MemoryError,
        OverflowError,
    ) as exc:
        raise EvidenceError(f"cannot read {path}: {exc}") from exc
    require_exact_keys(
        manifest,
        required={
            "schemaVersion",
            "baseCommit",
            "reviewedCommit",
            "sourceDiffSha256",
            "shardPolicy",
            "shards",
            "synthesis",
            "unresolvedBlockers",
        },
        optional={"dispositions", "dispositionsSha256"},
        label=str(path),
    )
    if require_int(manifest.get("schemaVersion"), f"{path}:schemaVersion") != 2:
        raise EvidenceError(f"{path}: unsupported schemaVersion; expected 2")

    base = require_commit(manifest.get("baseCommit"), "baseCommit")
    reviewed = require_commit(manifest.get("reviewedCommit"), "reviewedCommit")
    if base != expected_base:
        raise EvidenceError(
            f"{path}: baseCommit must equal trusted base {expected_base}"
        )
    if base == reviewed:
        raise EvidenceError(f"{path}: reviewedCommit must differ from baseCommit")
    git_bytes("cat-file", "-e", f"{base}^{{commit}}")
    git_bytes("cat-file", "-e", f"{reviewed}^{{commit}}")
    git_bytes("cat-file", "-e", f"{expected_tip}^{{commit}}")
    try:
        git_bytes("merge-base", "--is-ancestor", base, reviewed)
    except subprocess.CalledProcessError:
        raise EvidenceError(f"{path}: baseCommit is not an ancestor of reviewedCommit")

    parents = (
        git_bytes("rev-list", "--parents", "-n", "1", expected_tip).decode().split()
    )
    if parents != [expected_tip, reviewed]:
        raise EvidenceError(
            f"{path}: expected tip must be a single-parent direct child of reviewedCommit"
        )
    head_tree = git_bytes("rev-parse", "HEAD^{tree}").strip()
    expected_tree = git_bytes("rev-parse", f"{expected_tip}^{{tree}}").strip()
    if head_tree != expected_tree:
        raise EvidenceError(
            f"{path}: candidate checkout tree differs from expected tip"
        )

    reviewed_diff = require_safe_artifact(
        canonical_diff(base, reviewed), f"{path}:canonical source diff"
    )
    if not reviewed_diff:
        raise EvidenceError(f"{path}: canonical source diff must not be empty")
    expected_diff = require_sha256(manifest.get("sourceDiffSha256"), "sourceDiffSha256")
    if sha256_bytes(reviewed_diff) != expected_diff:
        raise EvidenceError(f"{path}: source diff hash mismatch")

    policy = require_object(manifest.get("shardPolicy"), "shardPolicy")
    require_exact_keys(
        policy,
        required={"maxDiffBytes", "maxChangedLines", "fileBoundaryOnly"},
        optional=set(),
        label="shardPolicy",
    )
    if (
        require_int(policy.get("maxDiffBytes"), "shardPolicy.maxDiffBytes")
        != MAX_SHARD_BYTES
        or require_int(policy.get("maxChangedLines"), "shardPolicy.maxChangedLines")
        != MAX_SHARD_CHANGED_LINES
        or require_bool(policy.get("fileBoundaryOnly"), "shardPolicy.fileBoundaryOnly")
        is not True
    ):
        raise EvidenceError(f"{path}: shardPolicy does not match the trusted policy")

    trusted_prompts = trusted_prompt_bytes()
    _full, changed_file_patches = file_patches(base, reviewed)
    expected_paths = [item.path for item in changed_file_patches]
    shards = manifest.get("shards")
    if not isinstance(shards, list) or not shards:
        raise EvidenceError(f"{path}: shards must be a non-empty array")

    artifacts: set[Path] = {path}
    contexts: set[str] = set()
    tool_versions: set[str] = set()
    prompt_artifact_by_role: dict[str, Path] = {}
    report_contents: set[bytes] = set()
    covered_paths: list[str] = []
    for offset, raw_shard in enumerate(shards):
        label = f"shards[{offset}]"
        shard = require_object(raw_shard, label)
        require_exact_keys(
            shard,
            required={
                "index",
                "primaryPaths",
                "contextPaths",
                "input",
                "inputSha256",
                "byteLength",
                "diffSha256",
                "diffByteLength",
                "changedLines",
                "primaryDiffSha256",
                "primaryDiffByteLength",
                "primaryChangedLines",
                "contextDiffSha256",
                "contextDiffByteLength",
                "contextChangedLines",
                "oversizedSingleFile",
                "reviews",
            },
            optional=set(),
            label=label,
        )
        index = require_int(shard.get("index"), f"{label}.index")
        if index != offset + 1:
            raise EvidenceError(f"{label}.index must be contiguous and one-based")
        primary_paths = require_path_list(
            shard.get("primaryPaths"), f"{label}.primaryPaths"
        )
        context_paths = require_path_list(
            shard.get("contextPaths"), f"{label}.contextPaths"
        )
        if set(primary_paths).intersection(context_paths):
            raise EvidenceError(f"{label} primary and context paths must not overlap")
        try:
            recomputed_input, metadata = explicit_shard_input(
                base, reviewed, primary_paths, context_paths
            )
        except ReviewInputError as exc:
            raise EvidenceError(f"{label} cannot be recomputed: {exc}") from exc
        covered_paths.extend(primary_paths)
        expected_fields = {
            "inputSha256": metadata["inputSha256"],
            "byteLength": metadata["byteLength"],
            "diffSha256": metadata["diffSha256"],
            "diffByteLength": metadata["diffByteLength"],
            "changedLines": metadata["changedLines"],
            "primaryDiffSha256": metadata["primaryDiffSha256"],
            "primaryDiffByteLength": metadata["primaryDiffByteLength"],
            "primaryChangedLines": metadata["primaryChangedLines"],
            "contextDiffSha256": metadata["contextDiffSha256"],
            "contextDiffByteLength": metadata["contextDiffByteLength"],
            "contextChangedLines": metadata["contextChangedLines"],
            "oversizedSingleFile": metadata["oversizedSingleFile"],
        }
        for field, expected in expected_fields.items():
            actual = shard.get(field)
            if isinstance(expected, bool):
                actual = require_bool(actual, f"{label}.{field}")
            elif isinstance(expected, int):
                actual = require_int(actual, f"{label}.{field}")
            if actual != expected:
                raise EvidenceError(f"{label}.{field} does not match recomputed input")
        if metadata["oversizedSingleFile"] and (
            len(primary_paths) != 1 or context_paths
        ):
            raise EvidenceError(f"{label}: oversized shard is not one dedicated file")

        _input_path, input_contents = validate_hashed_artifact(
            bundle, shard, "input", label, artifacts, expected_tip
        )
        if input_contents != recomputed_input:
            raise EvidenceError(f"{label}.input bytes are not reproducible")
        reviews = shard.get("reviews")
        if not isinstance(reviews, list) or len(reviews) != 2:
            raise EvidenceError(f"{label}.reviews must contain both required roles")
        roles: set[str] = set()
        for review_index, review in enumerate(reviews):
            role = validate_review(
                bundle=bundle,
                review=review,
                label=f"{label}.reviews[{review_index}]",
                expected_input=input_contents,
                required_variant=REQUIRED_VARIANT,
                artifacts=artifacts,
                contexts=contexts,
                tool_versions=tool_versions,
                trusted_prompts=trusted_prompts,
                prompt_artifact_by_role=prompt_artifact_by_role,
                report_contents=report_contents,
                expected_tip=expected_tip,
            )
            if role in roles:
                raise EvidenceError(f"{label}.reviews repeats role {role}")
            roles.add(role)
        if roles != REQUIRED_ROLES:
            raise EvidenceError(f"{label}.reviews must cover both required roles")

    if len(covered_paths) != len(set(covered_paths)) or set(covered_paths) != set(
        expected_paths
    ):
        missing = sorted(set(expected_paths) - set(covered_paths))
        repeated = sorted(
            item for item in set(covered_paths) if covered_paths.count(item) > 1
        )
        extras = sorted(set(covered_paths) - set(expected_paths))
        raise EvidenceError(
            f"{path}: primary ownership must cover every changed path exactly once; "
            f"missing={missing}, repeated={repeated}, extras={extras}"
        )
    if set(prompt_artifact_by_role) != REQUIRED_ROLES:
        raise EvidenceError(f"{path}: every role must bind one trusted prompt artifact")

    synthesis_item = require_object(manifest.get("synthesis"), "synthesis")
    require_exact_keys(
        synthesis_item,
        required={"rationale", "input", "inputSha256", "byteLength", "reviews"},
        optional={"fallback"},
        label="synthesis",
    )
    rationale = require_string(synthesis_item.get("rationale"), "synthesis.rationale")
    if len(rationale) > 2_000:
        raise EvidenceError("synthesis.rationale must be concise")
    try:
        synthesis_input, synthesis_metadata = full_diff_input(base, reviewed)
    except ReviewInputError as exc:
        raise EvidenceError(f"synthesis full-diff input is not bounded: {exc}") from exc
    if len(synthesis_input) > MAX_REQUEST_BYTES:
        raise EvidenceError(
            f"synthesis full-diff input exceeds {MAX_REQUEST_BYTES} bytes"
        )
    if (
        require_int(synthesis_item.get("byteLength"), "synthesis.byteLength")
        != synthesis_metadata["byteLength"]
    ):
        raise EvidenceError("synthesis.byteLength does not match full-diff input")
    if (
        require_sha256(synthesis_item.get("inputSha256"), "synthesis.inputSha256")
        != synthesis_metadata["inputSha256"]
    ):
        raise EvidenceError("synthesis.inputSha256 does not match full-diff input")
    _input_path, synthesis_contents = validate_hashed_artifact(
        bundle, synthesis_item, "input", "synthesis", artifacts, expected_tip
    )
    if synthesis_contents != synthesis_input:
        raise EvidenceError("synthesis.input bytes are not reproducible")
    synthesis_reviews = synthesis_item.get("reviews")
    if not isinstance(synthesis_reviews, list) or not 1 <= len(synthesis_reviews) <= 2:
        raise EvidenceError(
            "synthesis.reviews must contain one or two independent reviews"
        )
    variants = {
        require_string(
            require_object(review, f"synthesis.reviews[{index}]").get("variant"),
            f"synthesis.reviews[{index}].variant",
        )
        for index, review in enumerate(synthesis_reviews)
    }
    if len(variants) != 1 or next(iter(variants)) not in {"high", "low"}:
        raise EvidenceError("synthesis reviews must use one common high or low variant")
    synthesis_variant = next(iter(variants))
    synthesis_roles: set[str] = set()
    for index, review in enumerate(synthesis_reviews):
        role = validate_review(
            bundle=bundle,
            review=review,
            label=f"synthesis.reviews[{index}]",
            expected_input=synthesis_contents,
            required_variant=synthesis_variant,
            artifacts=artifacts,
            contexts=contexts,
            tool_versions=tool_versions,
            trusted_prompts=trusted_prompts,
            prompt_artifact_by_role=prompt_artifact_by_role,
            report_contents=report_contents,
            expected_tip=expected_tip,
        )
        if role in synthesis_roles:
            raise EvidenceError("synthesis.reviews must not repeat roles")
        synthesis_roles.add(role)
    if "cross-layer-correctness" not in synthesis_roles:
        raise EvidenceError("synthesis.reviews must include cross-layer-correctness")
    if synthesis_variant == "low":
        validate_failed_high_attempts(
            synthesis_item.get("fallback"),
            bundle=bundle,
            base=base,
            reviewed=reviewed,
            expected_input=synthesis_contents,
            final_roles=synthesis_roles,
            label="synthesis.fallback",
            artifacts=artifacts,
            contexts=contexts,
            tool_versions=tool_versions,
            trusted_prompts=trusted_prompts,
            expected_tip=expected_tip,
        )
    elif "fallback" in synthesis_item:
        raise EvidenceError("synthesis.fallback is allowed only for low variant")

    if len(tool_versions) != 1:
        raise EvidenceError(f"{path}: all review and receipt tool versions must match")
    if require_int(manifest.get("unresolvedBlockers"), "unresolvedBlockers") != 0:
        raise EvidenceError(f"{path}: unresolvedBlockers must be zero")

    dispositions_name = manifest.get("dispositions")
    dispositions_hash = manifest.get("dispositionsSha256")
    if (dispositions_name is None) != (dispositions_hash is None):
        raise EvidenceError(f"{path}: dispositions and hash must be declared together")
    if dispositions_name is not None:
        dispositions = evidence_file(bundle, dispositions_name, "dispositions")
        if dispositions in artifacts:
            raise EvidenceError("dispositions must name a distinct artifact")
        contents = safe_committed_artifact_bytes(
            expected_tip, dispositions, f"{path}:dispositions"
        )
        if not contents.strip():
            raise EvidenceError(f"{path}: dispositions must not be empty")
        if sha256_bytes(contents) != require_sha256(
            dispositions_hash, "dispositionsSha256"
        ):
            raise EvidenceError(f"{path}: dispositions hash mismatch")
        artifacts.add(dispositions)

    actual_files = committed_regular_direct_children(
        expected_tip, bundle, f"{path}:evidence bundle"
    )
    if actual_files != artifacts:
        extras = sorted(item.name for item in actual_files - artifacts)
        missing = sorted(item.name for item in artifacts - actual_files)
        raise EvidenceError(
            f"{path}: evidence declaration mismatch; extras={extras}, missing={missing}"
        )

    committed_paths = [
        item.decode("utf-8")
        for item in git_bytes(
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            "-z",
            "--no-renames",
            "--ignore-submodules=none",
            expected_tip,
        ).split(b"\0")
        if item
    ]
    declared_names = {item.as_posix() for item in artifacts}
    if set(committed_paths) != declared_names or len(committed_paths) != len(
        declared_names
    ):
        extras = sorted(set(committed_paths) - declared_names)
        missing = sorted(declared_names - set(committed_paths))
        raise EvidenceError(
            f"{path}: evidence tip must change exactly this bundle; "
            f"extras={extras}, missing={missing}"
        )
    manifest_name = path.as_posix()
    if manifest_name not in committed_paths:
        raise EvidenceError(f"{path}: manifest is absent from evidence tip")
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repository", type=Path, default=Path.cwd(), help="candidate Git worktree"
    )
    parser.add_argument("--expected-base", help="trusted full commit ID for PR base")
    parser.add_argument(
        "--expected-tip",
        help="trusted PR head/evidence commit; defaults to candidate HEAD",
    )
    parser.add_argument(
        "--scan-artifact",
        type=Path,
        help="scan one request/report for high-confidence unsafe content",
    )
    parser.add_argument(
        "--scan-title", type=Path, help="scan and bound one session title"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.scan_artifact is not None or args.scan_title is not None:
        if args.scan_artifact is not None and args.scan_title is not None:
            print("error: select only one scan mode", file=sys.stderr)
            return 2
        target = args.scan_artifact or args.scan_title
        assert target is not None
        try:
            if args.scan_title is not None:
                try:
                    title = read_regular_file(target, str(target), MAX_TITLE_BYTES)
                except ReviewInputError as exc:
                    raise EvidenceError(str(exc)) from exc
                require_safe_title(title, str(target))
            else:
                safe_artifact_bytes(target, str(target))
        except (EvidenceError, OSError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        print(f"review artifact safe to send: {target}")
        return 0

    if args.expected_base is None:
        print("error: --expected-base is required", file=sys.stderr)
        return 2
    try:
        expected_base = require_commit(args.expected_base, "--expected-base")
        os.chdir(args.repository)
        expected_tip = require_commit(
            args.expected_tip or git_bytes("rev-parse", "HEAD").decode().strip(),
            "--expected-tip",
        )
        git_bytes("cat-file", "-e", f"{expected_base}^{{commit}}")
        git_bytes("cat-file", "-e", f"{expected_tip}^{{commit}}")
    except (
        EvidenceError,
        OSError,
        ReviewInputError,
        subprocess.CalledProcessError,
    ) as exc:
        print(f"error: invalid repository/base/tip: {exc}", file=sys.stderr)
        return 2

    try:
        dirty = git_bytes(
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignore-submodules=none",
        )
    except (ReviewInputError, subprocess.CalledProcessError) as exc:
        print(f"error: cannot inspect candidate worktree: {exc}", file=sys.stderr)
        return 1
    if dirty:
        print("error: candidate worktree and submodules must be clean", file=sys.stderr)
        return 1

    try:
        manifests = committed_manifest_paths(expected_tip)
    except (EvidenceError, ReviewInputError, subprocess.CalledProcessError) as exc:
        print(
            f"error: cannot enumerate committed review evidence: {exc}", file=sys.stderr
        )
        return 1
    if not manifests:
        print(
            f"error: no adversarial-review manifest below {EVIDENCE_ROOT}",
            file=sys.stderr,
        )
        return 1
    errors: list[str] = []
    covering: list[Path] = []
    for manifest in manifests:
        try:
            if validate_manifest(manifest, expected_base, expected_tip):
                covering.append(manifest)
        except (EvidenceError, ReviewInputError, subprocess.CalledProcessError) as exc:
            errors.append(str(exc))
    if not covering:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        print("error: no valid review covers expected tip", file=sys.stderr)
        return 1
    print(f"adversarial review evidence valid: {covering[-1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
