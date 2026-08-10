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
from pathlib import Path
from typing import Any

from adversarial_review_input import (
    GIT_TIMEOUT_SECONDS,
    MAX_SHARD_BYTES,
    MAX_SHARD_CHANGED_LINES,
    ReviewInputError,
    build_review_request,
    canonical_diff,
    explicit_shard_input,
    file_patches,
    full_diff_input,
    read_regular_file,
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
        re.compile(r"-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"),
        "private key",
    ),
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
    try:
        result = subprocess.run(
            ["git", *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=GIT_TIMEOUT_SECONDS,
            env={
                **os.environ,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_TERMINAL_PROMPT": "0",
            },
        )
    except subprocess.TimeoutExpired as exc:
        raise EvidenceError(
            f"Git command exceeded {GIT_TIMEOUT_SECONDS} seconds"
        ) from exc
    return result.stdout


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
    try:
        mode = candidate.stat().st_mode
    except OSError as exc:
        raise EvidenceError(f"{label} does not exist: {name}") from exc
    if not stat.S_ISREG(mode):
        raise EvidenceError(f"{label} must be a regular file: {name}")
    return candidate


def require_path_without_symlink_ancestors(
    path: Path, repository_root: Path, label: str
) -> Path:
    """Resolve a repository path only after rejecting every symlink component."""

    candidate = path if path.is_absolute() else repository_root / path
    try:
        relative = candidate.relative_to(repository_root)
    except ValueError as exc:
        raise EvidenceError(f"{label} is outside the candidate repository") from exc
    current = repository_root
    for part in relative.parts:
        current = current / part
        try:
            mode = os.lstat(current).st_mode
        except OSError as exc:
            raise EvidenceError(f"cannot inspect {label}: {exc}") from exc
        if stat.S_ISLNK(mode):
            raise EvidenceError(f"{label} must not contain symlink ancestors")
    return candidate.resolve()


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
    try:
        value = read_regular_file(path, label, MAX_ARTIFACT_BYTES)
    except (OSError, ReviewInputError) as exc:
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
) -> tuple[Path, bytes]:
    artifact = evidence_file(bundle, owner.get(kind), f"{label}.{kind}")
    if artifact in artifacts:
        raise EvidenceError(f"{label}.{kind} must name a distinct artifact")
    expected = require_sha256(owner.get(f"{kind}Sha256"), f"{label}.{kind}Sha256")
    contents = safe_artifact_bytes(artifact, f"{label}.{kind}")
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
    rendered = contents.decode("utf-8").strip()
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
    expected_request = build_review_request(trusted_prompts[role], expected_input)
    if require_sha256(
        item.get("requestSha256"), f"{label}.requestSha256"
    ) != sha256_bytes(expected_request):
        raise EvidenceError(f"{label}.requestSha256 does not match prompt plus input")

    prompt_path = evidence_file(bundle, item.get("prompt"), f"{label}.prompt")
    prompt_contents = safe_artifact_bytes(prompt_path, f"{label}.prompt")
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
        bundle, item, "report", label, artifacts
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
) -> str:
    item = require_object(reference, label)
    require_exact_keys(
        item,
        required={"receipt", "receiptSha256"},
        optional=set(),
        label=label,
    )
    _receipt_path, raw = validate_hashed_artifact(
        bundle, item, "receipt", label, artifacts
    )
    try:
        receipt = require_object(json.loads(raw.decode("utf-8")), f"{label}.receipt")
    except json.JSONDecodeError as exc:
        raise EvidenceError(f"{label}.receipt is not valid JSON") from exc
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
    if receipt.get("schemaVersion") != 1:
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
    request_hash = sha256_bytes(
        build_review_request(trusted_prompts[role], expected_input)
    )
    if (
        require_sha256(receipt.get("requestSha256"), f"{label}.receipt.requestSha256")
        != request_hash
    ):
        raise EvidenceError(f"{label}.receipt request hash mismatch")
    outcome = receipt.get("outcome")
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
            )
        )
    if not final_roles.issubset(attempt_roles):
        raise EvidenceError(
            f"{label} needs a same-role failed high attempt per low review"
        )


def validate_manifest(path: Path, expected_base: str, expected_tip: str) -> bool:
    repository_root = Path.cwd().resolve()
    path = require_path_without_symlink_ancestors(path, repository_root, str(path))
    bundle = path.parent
    try:
        manifest_bytes = safe_artifact_bytes(path, str(path))
        manifest = require_object(json.loads(manifest_bytes.decode("utf-8")), str(path))
    except (EvidenceError, json.JSONDecodeError) as exc:
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
    if manifest.get("schemaVersion") != 2:
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
    if policy != {
        "maxDiffBytes": MAX_SHARD_BYTES,
        "maxChangedLines": MAX_SHARD_CHANGED_LINES,
        "fileBoundaryOnly": True,
    }:
        raise EvidenceError(f"{path}: shardPolicy does not match the trusted policy")

    trusted_prompts = trusted_prompt_bytes()
    _full, changed_file_patches = file_patches(base, reviewed)
    expected_paths = [item.path for item in changed_file_patches]
    shards = manifest.get("shards")
    if not isinstance(shards, list) or not shards:
        raise EvidenceError(f"{path}: shards must be a non-empty array")

    artifacts: set[Path] = {path.resolve()}
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
            if shard.get(field) != expected:
                raise EvidenceError(f"{label}.{field} does not match recomputed input")
        if metadata["oversizedSingleFile"] and (
            len(primary_paths) != 1 or context_paths
        ):
            raise EvidenceError(f"{label}: oversized shard is not one dedicated file")

        _input_path, input_contents = validate_hashed_artifact(
            bundle, shard, "input", label, artifacts
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
    synthesis_input, synthesis_metadata = full_diff_input(base, reviewed)
    if synthesis_item.get("byteLength") != synthesis_metadata["byteLength"]:
        raise EvidenceError("synthesis.byteLength does not match full-diff input")
    if (
        require_sha256(synthesis_item.get("inputSha256"), "synthesis.inputSha256")
        != synthesis_metadata["inputSha256"]
    ):
        raise EvidenceError("synthesis.inputSha256 does not match full-diff input")
    _input_path, synthesis_contents = validate_hashed_artifact(
        bundle, synthesis_item, "input", "synthesis", artifacts
    )
    if synthesis_contents != synthesis_input:
        raise EvidenceError("synthesis.input bytes are not reproducible")
    synthesis_reviews = synthesis_item.get("reviews")
    if not isinstance(synthesis_reviews, list) or not 1 <= len(synthesis_reviews) <= 2:
        raise EvidenceError(
            "synthesis.reviews must contain one or two independent reviews"
        )
    variants = {
        require_object(review, f"synthesis.reviews[{index}]").get("variant")
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
        )
    elif "fallback" in synthesis_item:
        raise EvidenceError("synthesis.fallback is allowed only for low variant")

    if len(tool_versions) != 1:
        raise EvidenceError(f"{path}: all review and receipt tool versions must match")
    if manifest.get("unresolvedBlockers") != 0:
        raise EvidenceError(f"{path}: unresolvedBlockers must be zero")

    dispositions_name = manifest.get("dispositions")
    dispositions_hash = manifest.get("dispositionsSha256")
    if (dispositions_name is None) != (dispositions_hash is None):
        raise EvidenceError(f"{path}: dispositions and hash must be declared together")
    if dispositions_name is not None:
        dispositions = evidence_file(bundle, dispositions_name, "dispositions")
        if dispositions in artifacts:
            raise EvidenceError("dispositions must name a distinct artifact")
        contents = safe_artifact_bytes(dispositions, f"{path}:dispositions")
        if not contents.strip():
            raise EvidenceError(f"{path}: dispositions must not be empty")
        if sha256_bytes(contents) != require_sha256(
            dispositions_hash, "dispositionsSha256"
        ):
            raise EvidenceError(f"{path}: dispositions hash mismatch")
        artifacts.add(dispositions)

    actual_files: set[Path] = set()
    for child in bundle.iterdir():
        if child.is_symlink():
            raise EvidenceError(
                f"{path}: evidence entries must not be symlinks: {child}"
            )
        if not stat.S_ISREG(child.stat().st_mode):
            raise EvidenceError(
                f"{path}: evidence entries must be regular files: {child}"
            )
        actual_files.add(child.resolve())
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
    try:
        declared_names = {
            item.relative_to(repository_root).as_posix() for item in artifacts
        }
    except ValueError as exc:
        raise EvidenceError(
            f"{path}: evidence artifacts escape the repository"
        ) from exc
    if set(committed_paths) != declared_names or len(committed_paths) != len(
        declared_names
    ):
        extras = sorted(set(committed_paths) - declared_names)
        missing = sorted(declared_names - set(committed_paths))
        raise EvidenceError(
            f"{path}: evidence tip must change exactly this bundle; "
            f"extras={extras}, missing={missing}"
        )
    try:
        manifest_name = path.relative_to(repository_root).as_posix()
    except ValueError as exc:
        raise EvidenceError(f"{path}: manifest escapes the repository") from exc
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
    except (EvidenceError, OSError, subprocess.CalledProcessError) as exc:
        print(f"error: invalid repository/base/tip: {exc}", file=sys.stderr)
        return 2

    try:
        dirty = git_bytes(
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--ignore-submodules=none",
        )
    except subprocess.CalledProcessError as exc:
        print(f"error: cannot inspect candidate worktree: {exc}", file=sys.stderr)
        return 1
    if dirty:
        print("error: candidate worktree and submodules must be clean", file=sys.stderr)
        return 1

    manifests = sorted(EVIDENCE_ROOT.glob("*/manifest.json"))
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
