#!/usr/bin/env python3
"""Build deterministic, file-boundary inputs for adversarial review.

The module is intentionally stdlib-only because the protected-base workflow
imports it without installing candidate dependencies.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


FULL_COMMIT = re.compile(r"^[0-9a-f]{40}$")
MAX_SHARD_BYTES = 100 * 1024
MAX_SHARD_CHANGED_LINES = 2_000
INPUT_SCHEMA_VERSION = 1
MAX_SEMANTIC_PLAN_BYTES = 1 * 1024 * 1024
REQUEST_BEGIN = b"\n--- BEGIN FROZEN REVIEW INPUT ---\n"
REQUEST_END = b"\n--- END FROZEN REVIEW INPUT ---\n"


class ReviewInputError(ValueError):
    """The requested review input cannot be reproduced safely."""


@dataclass(frozen=True)
class FilePatch:
    path: str
    body: bytes
    changed_lines: int


@dataclass(frozen=True)
class ShardPlan:
    index: int
    primary_paths: tuple[str, ...]
    diff: bytes
    changed_lines: int
    oversized_single_file: bool


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


def require_commit(value: str, label: str) -> str:
    if FULL_COMMIT.fullmatch(value) is None:
        raise ReviewInputError(f"{label} must be a full lowercase Git commit ID")
    return value


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
        "--ignore-submodules=none",
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


def changed_paths(base: str, reviewed: str) -> list[str]:
    raw = git_bytes(
        "diff",
        "--name-only",
        "--no-renames",
        "--ignore-submodules=none",
        "-z",
        base,
        reviewed,
    )
    encoded_paths = [item for item in raw.split(b"\0") if item]
    try:
        return [item.decode("utf-8") for item in encoded_paths]
    except UnicodeDecodeError as exc:
        raise ReviewInputError("changed paths must be valid UTF-8") from exc


def changed_line_count(patch: bytes) -> int:
    count = 0
    in_hunk = False
    for line in patch.splitlines():
        if line.startswith(b"diff --git "):
            in_hunk = False
            continue
        if line.startswith(b"@@ "):
            in_hunk = True
            continue
        if in_hunk and line.startswith((b"+", b"-")):
            count += 1
    return count


def build_review_request(prompt: bytes, review_input: bytes) -> bytes:
    """Return the exact single user-message payload sent to OpenCode."""

    return prompt + REQUEST_BEGIN + review_input + REQUEST_END


def file_patches(base: str, reviewed: str) -> tuple[bytes, list[FilePatch]]:
    full = canonical_diff(base, reviewed)
    paths = changed_paths(base, reviewed)
    if not full:
        if paths:
            raise ReviewInputError("changed paths exist but the canonical diff is empty")
        return full, []
    starts = [
        match.start()
        for match in re.finditer(br"(?m)^diff --git ", full)
    ]
    if not starts or starts[0] != 0:
        raise ReviewInputError("canonical diff has an unrecognized file boundary")
    starts.append(len(full))
    bodies = [full[starts[index] : starts[index + 1]] for index in range(len(starts) - 1)]
    if len(paths) != len(bodies):
        raise ReviewInputError(
            "canonical diff file count does not match the changed-path list"
        )
    patches = [
        FilePatch(path=path, body=body, changed_lines=changed_line_count(body))
        for path, body in zip(paths, bodies, strict=True)
    ]
    if b"".join(item.body for item in patches) != full:
        raise ReviewInputError("file-boundary split did not preserve canonical bytes")
    return full, patches


def plan_shards(
    base: str,
    reviewed: str,
    *,
    max_bytes: int = MAX_SHARD_BYTES,
    max_changed_lines: int = MAX_SHARD_CHANGED_LINES,
) -> tuple[bytes, list[ShardPlan]]:
    full, patches = file_patches(base, reviewed)
    if not patches:
        return full, []

    groups: list[list[FilePatch]] = []
    current: list[FilePatch] = []
    current_bytes = 0
    current_lines = 0
    for patch in patches:
        patch_oversized = (
            len(patch.body) > max_bytes or patch.changed_lines > max_changed_lines
        )
        if patch_oversized:
            if current:
                groups.append(current)
                current = []
                current_bytes = 0
                current_lines = 0
            groups.append([patch])
            continue

        would_exceed = current and (
            current_bytes + len(patch.body) > max_bytes
            or current_lines + patch.changed_lines > max_changed_lines
        )
        if would_exceed:
            groups.append(current)
            current = []
            current_bytes = 0
            current_lines = 0
        current.append(patch)
        current_bytes += len(patch.body)
        current_lines += patch.changed_lines
    if current:
        groups.append(current)

    shards: list[ShardPlan] = []
    for index, group in enumerate(groups, start=1):
        body = b"".join(item.body for item in group)
        lines = sum(item.changed_lines for item in group)
        oversized = len(body) > max_bytes or lines > max_changed_lines
        if oversized and len(group) != 1:
            raise ReviewInputError("an oversized shard must contain exactly one file")
        shards.append(
            ShardPlan(
                index=index,
                primary_paths=tuple(item.path for item in group),
                diff=body,
                changed_lines=lines,
                oversized_single_file=oversized,
            )
        )
    if b"".join(shard.diff for shard in shards) != full:
        raise ReviewInputError("shards do not reconstruct the canonical diff")
    return full, shards


def select_primary_paths(
    patches: Sequence[FilePatch], requested: Sequence[str]
) -> list[FilePatch]:
    if not requested:
        raise ReviewInputError("at least one primary path is required")
    if len(set(requested)) != len(requested):
        raise ReviewInputError("primary paths must be unique")
    by_path = {item.path: item for item in patches}
    unknown = [path for path in requested if path not in by_path]
    if unknown:
        raise ReviewInputError(f"primary paths are not changed: {unknown}")
    selected = [item for item in patches if item.path in set(requested)]
    if [item.path for item in selected] != list(requested):
        raise ReviewInputError("primary paths must follow canonical Git diff order")
    return selected


def build_review_input(
    base: str,
    reviewed: str,
    full_diff: bytes,
    primary_patches: Sequence[FilePatch],
    context_patches: Sequence[FilePatch] = (),
) -> tuple[bytes, dict[str, Any]]:
    primary_paths = [item.path for item in primary_patches]
    context_paths = [item.path for item in context_patches]
    if len(set(context_paths)) != len(context_paths):
        raise ReviewInputError("context paths must be unique")
    overlap = sorted(set(primary_paths).intersection(context_paths))
    if overlap:
        raise ReviewInputError(f"primary and context paths overlap: {overlap}")

    primary_diff = b"".join(item.body for item in primary_patches)
    context_diff = b"".join(item.body for item in context_patches)
    header = {
        "baseCommit": base,
        "contextPaths": context_paths,
        "inputSchemaVersion": INPUT_SCHEMA_VERSION,
        "primaryPaths": primary_paths,
        "reviewedCommit": reviewed,
        "sourceDiffSha256": sha256_bytes(full_diff),
    }
    chunks = [
        b"SCANSTUDIO-ADVERSARIAL-REVIEW-INPUT\n",
        json.dumps(header, sort_keys=True, separators=(",", ":")).encode("utf-8"),
        b"\n--- BEGIN CANONICAL PRIMARY DIFF ---\n",
        primary_diff,
        b"--- END CANONICAL PRIMARY DIFF ---\n",
        b"--- BEGIN CANONICAL CONTEXT DIFF ---\n",
        context_diff,
        b"--- END CANONICAL CONTEXT DIFF ---\n",
    ]
    rendered = b"".join(chunks)
    combined_diff = primary_diff + context_diff
    primary_lines = sum(item.changed_lines for item in primary_patches)
    context_lines = sum(item.changed_lines for item in context_patches)
    metadata: dict[str, Any] = {
        **header,
        "byteLength": len(rendered),
        "changedLines": primary_lines + context_lines,
        "contextChangedLines": context_lines,
        "contextDiffByteLength": len(context_diff),
        "contextDiffSha256": sha256_bytes(context_diff),
        "diffByteLength": len(combined_diff),
        "diffSha256": sha256_bytes(combined_diff),
        "inputSha256": sha256_bytes(rendered),
        "oversizedSingleFile": (
            len(primary_patches) == 1 and not context_patches
            and (
                len(primary_diff) > MAX_SHARD_BYTES
                or primary_lines > MAX_SHARD_CHANGED_LINES
            )
        ),
        "primaryChangedLines": primary_lines,
        "primaryDiffByteLength": len(primary_diff),
        "primaryDiffSha256": sha256_bytes(primary_diff),
    }
    return rendered, metadata


def automatic_shard_input(
    base: str,
    reviewed: str,
    shard_index: int,
    context_paths: Sequence[str] = (),
) -> tuple[bytes, dict[str, Any]]:
    full, shards = plan_shards(base, reviewed)
    if shard_index < 1 or shard_index > len(shards):
        raise ReviewInputError(
            f"shard index must be between 1 and {len(shards)}, got {shard_index}"
        )
    _, patches = file_patches(base, reviewed)
    chosen = shards[shard_index - 1]
    selected = select_primary_paths(patches, chosen.primary_paths)
    selected_context = select_primary_paths(patches, context_paths) if context_paths else []
    rendered, metadata = build_review_input(
        base, reviewed, full, selected, selected_context
    )
    metadata.update({"shardCount": len(shards), "shardIndex": shard_index})
    enforce_shard_limits(metadata, f"automatic shard {shard_index}")
    return rendered, metadata


def explicit_shard_input(
    base: str,
    reviewed: str,
    primary_paths: Sequence[str],
    context_paths: Sequence[str] = (),
) -> tuple[bytes, dict[str, Any]]:
    full, patches = file_patches(base, reviewed)
    selected_primary = select_primary_paths(patches, primary_paths)
    selected_context = select_primary_paths(patches, context_paths) if context_paths else []
    rendered, metadata = build_review_input(
        base, reviewed, full, selected_primary, selected_context
    )
    enforce_shard_limits(metadata, "explicit shard")
    return rendered, metadata


def enforce_shard_limits(metadata: dict[str, Any], label: str) -> None:
    if metadata["oversizedSingleFile"]:
        return
    if (
        metadata["diffByteLength"] > MAX_SHARD_BYTES
        or metadata["changedLines"] > MAX_SHARD_CHANGED_LINES
    ):
        raise ReviewInputError(
            f"{label} exceeds {MAX_SHARD_BYTES} diff bytes or "
            f"{MAX_SHARD_CHANGED_LINES} changed lines"
        )


def load_semantic_plan(path: Path) -> list[dict[str, Any]]:
    if path.is_symlink() or not path.is_file():
        raise ReviewInputError("semantic plan must be a regular non-symlink file")
    raw = path.read_bytes()
    if not raw or len(raw) > MAX_SEMANTIC_PLAN_BYTES or b"\x00" in raw:
        raise ReviewInputError("semantic plan is empty, binary, or too large")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReviewInputError("semantic plan must be valid UTF-8 JSON") from exc
    if not isinstance(value, dict) or set(value) != {"shards"}:
        raise ReviewInputError("semantic plan must contain only a shards array")
    shards = value.get("shards")
    if not isinstance(shards, list) or not shards:
        raise ReviewInputError("semantic plan shards must be a non-empty array")
    parsed: list[dict[str, Any]] = []
    for index, item in enumerate(shards, start=1):
        if not isinstance(item, dict) or set(item) != {"primaryPaths", "contextPaths"}:
            raise ReviewInputError(
                f"semantic plan shard {index} must contain primaryPaths and contextPaths"
            )
        primary = item.get("primaryPaths")
        context = item.get("contextPaths")
        if not isinstance(primary, list) or not all(isinstance(path, str) for path in primary):
            raise ReviewInputError(f"semantic plan shard {index} primaryPaths is invalid")
        if not isinstance(context, list) or not all(isinstance(path, str) for path in context):
            raise ReviewInputError(f"semantic plan shard {index} contextPaths is invalid")
        parsed.append({"primaryPaths": primary, "contextPaths": context})
    return parsed


def describe_semantic_plan(
    base: str, reviewed: str, path: Path
) -> tuple[list[dict[str, Any]], list[tuple[bytes, dict[str, Any]]]]:
    specs = load_semantic_plan(path)
    _full, patches = file_patches(base, reviewed)
    expected_paths = {item.path for item in patches}
    owned_paths: list[str] = []
    described: list[tuple[bytes, dict[str, Any]]] = []
    for index, spec in enumerate(specs, start=1):
        rendered, metadata = explicit_shard_input(
            base, reviewed, spec["primaryPaths"], spec["contextPaths"]
        )
        metadata.update({"shardCount": len(specs), "shardIndex": index})
        described.append((rendered, metadata))
        owned_paths.extend(spec["primaryPaths"])
    duplicates = sorted(path for path in set(owned_paths) if owned_paths.count(path) > 1)
    missing = sorted(expected_paths - set(owned_paths))
    extras = sorted(set(owned_paths) - expected_paths)
    if duplicates or missing or extras:
        raise ReviewInputError(
            "semantic plan primary ownership is not exact; "
            f"missing={missing}, duplicates={duplicates}, extras={extras}"
        )
    return specs, described


def full_diff_input(base: str, reviewed: str) -> tuple[bytes, dict[str, Any]]:
    full, patches = file_patches(base, reviewed)
    if not patches:
        raise ReviewInputError("canonical review diff is empty")
    rendered, metadata = build_review_input(base, reviewed, full, patches)
    metadata.update({"shardCount": 1, "shardIndex": 1, "synthesis": True})
    return rendered, metadata


def json_line(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("plan", "describe", "emit", "describe-full", "emit-full"):
        child = subparsers.add_parser(command)
        child.add_argument("base")
        child.add_argument("reviewed")
        if command == "plan":
            child.add_argument("--semantic-plan", type=Path)
        if command in ("describe", "emit"):
            selection = child.add_mutually_exclusive_group(required=True)
            selection.add_argument("--shard-index", type=int)
            selection.add_argument("--primary-path", action="append")
            selection.add_argument("--semantic-plan", type=Path)
            child.add_argument("--semantic-shard-index", type=int)
            child.add_argument("--context-path", action="append", default=[])
    request = subparsers.add_parser("request")
    request.add_argument("--prompt", type=Path, required=True)
    request.add_argument("--input", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "request":
            if args.prompt.is_symlink() or args.input.is_symlink():
                raise ReviewInputError("request inputs must not be symlinks")
            prompt = args.prompt.read_bytes()
            review_input = args.input.read_bytes()
            if not prompt or not review_input:
                raise ReviewInputError("request prompt and review input must be non-empty")
            sys.stdout.buffer.write(build_review_request(prompt, review_input))
            return 0
        base = require_commit(args.base, "base")
        reviewed = require_commit(args.reviewed, "reviewed")
        git_bytes("cat-file", "-e", f"{base}^{{commit}}")
        git_bytes("cat-file", "-e", f"{reviewed}^{{commit}}")
        if base == reviewed:
            raise ReviewInputError("base and reviewed commits must differ")
        if args.command == "plan":
            full, shards = plan_shards(base, reviewed)
            value = {
                "baseCommit": base,
                "limits": {
                    "maxChangedLines": MAX_SHARD_CHANGED_LINES,
                    "maxDiffBytes": MAX_SHARD_BYTES,
                },
                "reviewedCommit": reviewed,
                "shards": [],
                "sourceDiffSha256": sha256_bytes(full),
            }
            if args.semantic_plan is not None:
                _specs, described = describe_semantic_plan(
                    base, reviewed, args.semantic_plan
                )
                value["shards"] = [metadata for _rendered, metadata in described]
                value["planKind"] = "semantic"
            else:
                for shard in shards:
                    _rendered, metadata = automatic_shard_input(
                        base, reviewed, shard.index
                    )
                    value["shards"].append(metadata)
                value["planKind"] = "greedy-default"
            print(json.dumps(value, indent=2, sort_keys=True))
            return 0
        if args.command in ("describe-full", "emit-full"):
            rendered, metadata = full_diff_input(base, reviewed)
        else:
            if args.semantic_plan is not None:
                if args.semantic_shard_index is None:
                    raise ReviewInputError(
                        "--semantic-shard-index is required with --semantic-plan"
                    )
                if args.context_path:
                    raise ReviewInputError(
                        "--context-path is already declared by the semantic plan"
                    )
                _specs, described = describe_semantic_plan(
                    base, reviewed, args.semantic_plan
                )
                if not 1 <= args.semantic_shard_index <= len(described):
                    raise ReviewInputError("semantic shard index is out of range")
                rendered, metadata = described[args.semantic_shard_index - 1]
            elif args.shard_index is not None:
                if args.semantic_shard_index is not None:
                    raise ReviewInputError(
                        "--semantic-shard-index requires --semantic-plan"
                    )
                rendered, metadata = automatic_shard_input(
                    base, reviewed, args.shard_index, args.context_path
                )
            else:
                if args.semantic_shard_index is not None:
                    raise ReviewInputError(
                        "--semantic-shard-index requires --semantic-plan"
                    )
                rendered, metadata = explicit_shard_input(
                    base, reviewed, args.primary_path, args.context_path
                )
        if args.command.startswith("describe"):
            print(json.dumps(metadata, indent=2, sort_keys=True))
        else:
            sys.stdout.buffer.write(rendered)
        return 0
    except (ReviewInputError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
