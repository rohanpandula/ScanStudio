#!/usr/bin/env python3
"""Build deterministic, file-boundary inputs for adversarial review.

The module is intentionally stdlib-only because the protected-base workflow
imports it without installing candidate dependencies.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


FULL_COMMIT = re.compile(r"^[0-9a-f]{40}$")
MAX_SHARD_BYTES = 100 * 1024
MAX_SHARD_CHANGED_LINES = 2_000
INPUT_SCHEMA_VERSION = 2
MAX_SEMANTIC_PLAN_BYTES = 1 * 1024 * 1024
MAX_REQUEST_BYTES = 5 * 1024 * 1024
GIT_TIMEOUT_SECONDS = 30
GIT_KILL_REAP_SECONDS = 1
MAX_GIT_STDOUT_BYTES = 16 * 1024 * 1024
MAX_GIT_STDERR_BYTES = 1 * 1024 * 1024
REQUEST_BOUNDARY_PREFIX = b"SCANSTUDIO-FROZEN-REVIEW-INPUT-"
REQUEST_BEGIN = b"\n--- BEGIN "
REQUEST_END = b"\n--- END "
BINARY_DIFF_MARKERS = (b"\nGIT binary patch\n", b"\nBinary files ")


class ReviewInputError(ValueError):
    """The requested review input cannot be reproduced safely."""


def strict_json_loads(raw: bytes) -> Any:
    """Decode standards-compliant JSON while rejecting duplicate object keys."""

    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f"duplicate JSON key: {key}")
            value[key] = item
        return value

    def reject_constant(value: str) -> None:
        raise ValueError(f"non-standard JSON constant: {value}")

    return json.loads(
        raw,
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )


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


def read_fd_with_eintr_retry(
    descriptor: int, size: int, *, deadline: float | None = None
) -> bytes:
    while True:
        try:
            return os.read(descriptor, size)
        except InterruptedError:
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError from None
            continue


def git_bytes(*args: str) -> bytes:
    environment = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    environment.update(
        {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        }
    )
    # Local repository configuration is outside the reviewed commit. Disable
    # the only executable read-path setting used by these commands so a
    # hostile core.fsmonitor hook cannot run during preflight/status reads.
    command = ["git", "-c", "core.fsmonitor=false", *args]
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            start_new_session=True,
        )
    except OSError as exc:
        raise ReviewInputError(f"cannot start Git command: {exc}") from exc

    assert process.stdout is not None
    assert process.stderr is not None
    streams = {
        process.stdout: (bytearray(), MAX_GIT_STDOUT_BYTES, "stdout"),
        process.stderr: (bytearray(), MAX_GIT_STDERR_BYTES, "stderr"),
    }
    deadline = time.monotonic() + GIT_TIMEOUT_SECONDS
    selector: selectors.BaseSelector | None = None

    def poll_process(poll_deadline: float = deadline) -> int | None:
        retried_after_deadline = False
        while True:
            try:
                return process.poll()
            except InterruptedError:
                if time.monotonic() >= poll_deadline:
                    if retried_after_deadline:
                        return None
                    retried_after_deadline = True
                continue

    def wait_process(wait_deadline: float = deadline) -> int:
        while True:
            return_code = poll_process(wait_deadline)
            if return_code is not None:
                return return_code
            remaining = wait_deadline - time.monotonic()
            if remaining <= 0:
                # Resolve the exact-deadline race before declaring a timeout.
                return_code = poll_process(wait_deadline)
                if return_code is not None:
                    return return_code
                raise subprocess.TimeoutExpired(command, GIT_TIMEOUT_SECONDS)
            try:
                return process.wait(timeout=remaining)
            except InterruptedError:
                continue
            except subprocess.TimeoutExpired:
                return_code = poll_process(wait_deadline)
                if return_code is not None:
                    return return_code
                raise

    cleanup_started = False

    def stop_process() -> None:
        nonlocal cleanup_started
        if cleanup_started:
            return
        cleanup_started = True
        killed = False
        kill_deadline = time.monotonic() + GIT_KILL_REAP_SECONDS
        reap_deadline = kill_deadline
        # Git and any helpers inherit this dedicated process group. Kill the
        # group even when the direct child has already exited: a helper can
        # otherwise retain the captured pipe descriptors forever.
        while True:
            try:
                os.killpg(process.pid, signal.SIGKILL)
                killed = True
                break
            except InterruptedError:
                if time.monotonic() >= kill_deadline:
                    break
                continue
            except (ProcessLookupError, PermissionError):
                break
        if poll_process(kill_deadline) is None:
            try:
                process.kill()
                killed = True
            except (ProcessLookupError, PermissionError):
                pass
        if killed:
            # A killed child still needs a bounded reap even when its command
            # budget has just expired; otherwise it can leak a live Popen/zombie.
            reap_deadline = time.monotonic() + GIT_KILL_REAP_SECONDS
        try:
            wait_process(reap_deadline)
        except subprocess.TimeoutExpired:
            # Cleanup remains bounded even if the platform fails to reap SIGKILL.
            pass

    def timeout_error() -> ReviewInputError:
        stop_process()
        return ReviewInputError(f"Git command exceeded {GIT_TIMEOUT_SECONDS} seconds")

    def select_ready(timeout: float, select_deadline: float) -> list[Any]:
        assert selector is not None
        retried_after_deadline = False
        while True:
            try:
                return selector.select(timeout)
            except InterruptedError:
                if time.monotonic() >= select_deadline:
                    if retried_after_deadline:
                        return []
                    retried_after_deadline = True
                    timeout = 0
                elif timeout > 0:
                    timeout = max(0.0, select_deadline - time.monotonic())

    completed = False
    final_nonblocking_drain_passes = 0
    try:
        selector = selectors.DefaultSelector()
        for stream in streams:
            selector.register(stream, selectors.EVENT_READ)
        while selector.get_map():
            expired = time.monotonic() >= deadline
            if expired:
                if final_nonblocking_drain_passes >= 2:
                    raise timeout_error()
                # Permit two bounded nonblocking passes at the deadline: one
                # for a final small output chunk and one to observe its EOF. A
                # live writer still cannot use readiness to reset the budget.
                final_nonblocking_drain_passes += 1
            remaining = 0.0 if expired else max(0.0, deadline - time.monotonic())
            ready = select_ready(remaining, deadline)
            if not ready:
                # A descriptor can become ready at the same instant the timed
                # select expires. One nonblocking pass prevents rejecting EOF
                # or the last bounded output chunk at that boundary.
                ready = select_ready(0, time.monotonic())
                if not ready:
                    if time.monotonic() >= deadline:
                        raise timeout_error()
                    if poll_process(deadline) is not None:
                        continue
                    continue
            for key, _events in ready:
                stream = key.fileobj
                try:
                    chunk = read_fd_with_eintr_retry(
                        stream.fileno(), 64 * 1024, deadline=deadline
                    )
                except TimeoutError:
                    raise timeout_error() from None
                if not chunk:
                    selector.unregister(stream)
                    continue
                buffer, limit, name = streams[stream]
                buffer.extend(chunk)
                if len(buffer) > limit:
                    stop_process()
                    raise ReviewInputError(f"Git command {name} exceeds {limit} bytes")
        try:
            return_code = wait_process()
        except subprocess.TimeoutExpired as exc:
            raise timeout_error() from exc
        completed = True
    finally:
        if not completed:
            stop_process()
        if selector is not None:
            selector.close()
        process.stdout.close()
        process.stderr.close()

    stdout = bytes(streams[process.stdout][0])
    stderr = bytes(streams[process.stderr][0])
    if return_code:
        raise subprocess.CalledProcessError(
            return_code, command, output=stdout, stderr=stderr
        )
    return stdout


def read_regular_file(path: Path, label: str, max_bytes: int) -> bytes:
    """Read one bounded regular file without following a final symlink."""

    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    while True:
        try:
            descriptor = os.open(path, flags)
            break
        except InterruptedError:
            continue
        except OSError as exc:
            raise ReviewInputError(f"cannot open {label}: {exc}") from exc
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode):
            raise ReviewInputError(f"{label} must be a regular file")
        if details.st_size > max_bytes:
            raise ReviewInputError(f"{label} exceeds {max_bytes} bytes")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = read_fd_with_eintr_retry(
                descriptor, min(64 * 1024, max_bytes + 1 - total)
            )
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise ReviewInputError(f"{label} exceeds {max_bytes} bytes")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


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
    """Return the exact, raw-text user-message payload sent to OpenCode.

    The content-derived boundary is guaranteed not to occur in either payload,
    so a diff cannot forge the apparent end of its frozen-input frame. Both
    payloads remain verbatim so the outbound secret scanner sees their bytes.
    """

    if not prompt or not review_input:
        raise ReviewInputError("request prompt and review input must be non-empty")
    seed = hashlib.sha256(
        b"ScanStudio adversarial review request\0" + prompt + b"\0" + review_input
    ).digest()
    counter = 0
    while True:
        digest = hashlib.sha256(seed + counter.to_bytes(8, "big")).hexdigest()
        boundary = REQUEST_BOUNDARY_PREFIX + digest.encode("ascii")
        if boundary not in prompt and boundary not in review_input:
            break
        counter += 1
    metadata = (
        b"; bytes="
        + str(len(review_input)).encode("ascii")
        + b"; sha256="
        + sha256_bytes(review_input).encode("ascii")
    )
    request = (
        prompt
        + REQUEST_BEGIN
        + boundary
        + metadata
        + b" ---\n"
        + review_input
        + REQUEST_END
        + boundary
        + b" ---\n"
    )
    if len(request) > MAX_REQUEST_BYTES:
        raise ReviewInputError(
            f"complete review request exceeds {MAX_REQUEST_BYTES} bytes"
        )
    return request


def file_patches(base: str, reviewed: str) -> tuple[bytes, list[FilePatch]]:
    full = canonical_diff(base, reviewed)
    paths = changed_paths(base, reviewed)
    if not full:
        if paths:
            raise ReviewInputError(
                "changed paths exist but the canonical diff is empty"
            )
        return full, []
    if any(marker in full for marker in BINARY_DIFF_MARKERS):
        raise ReviewInputError(
            "binary changes are not reviewable by the text evidence gate; "
            "separate them into an explicitly reviewed asset step"
        )
    starts = [match.start() for match in re.finditer(rb"(?m)^diff --git ", full)]
    if not starts or starts[0] != 0:
        raise ReviewInputError("canonical diff has an unrecognized file boundary")
    starts.append(len(full))
    bodies = [
        full[starts[index] : starts[index + 1]] for index in range(len(starts) - 1)
    ]
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
    source_paths: Sequence[str],
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
        "sourcePaths": list(source_paths),
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
            len(primary_patches) == 1
            and not context_patches
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
    selected_context = (
        select_primary_paths(patches, context_paths) if context_paths else []
    )
    rendered, metadata = build_review_input(
        base,
        reviewed,
        full,
        [item.path for item in patches],
        selected,
        selected_context,
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
    selected_context = (
        select_primary_paths(patches, context_paths) if context_paths else []
    )
    rendered, metadata = build_review_input(
        base,
        reviewed,
        full,
        [item.path for item in patches],
        selected_primary,
        selected_context,
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
    raw = read_regular_file(path, "semantic plan", MAX_SEMANTIC_PLAN_BYTES)
    if not raw or len(raw) > MAX_SEMANTIC_PLAN_BYTES or b"\x00" in raw:
        raise ReviewInputError("semantic plan is empty, binary, or too large")
    try:
        value = strict_json_loads(raw)
    except (
        UnicodeDecodeError,
        ValueError,
        RecursionError,
        MemoryError,
        OverflowError,
    ) as exc:
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
        if not isinstance(primary, list) or not all(
            isinstance(path, str) for path in primary
        ):
            raise ReviewInputError(
                f"semantic plan shard {index} primaryPaths is invalid"
            )
        if not isinstance(context, list) or not all(
            isinstance(path, str) for path in context
        ):
            raise ReviewInputError(
                f"semantic plan shard {index} contextPaths is invalid"
            )
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
    duplicates = sorted(
        path for path in set(owned_paths) if owned_paths.count(path) > 1
    )
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
    rendered, metadata = build_review_input(
        base,
        reviewed,
        full,
        [item.path for item in patches],
        patches,
    )
    if len(rendered) > MAX_REQUEST_BYTES:
        raise ReviewInputError(
            f"full-diff synthesis input exceeds {MAX_REQUEST_BYTES} bytes"
        )
    metadata.update({"shardCount": 1, "shardIndex": 1, "synthesis": True})
    return rendered, metadata


def json_line(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in (
        "preflight",
        "plan",
        "describe",
        "emit",
        "describe-full",
        "emit-full",
    ):
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
            prompt = read_regular_file(args.prompt, "request prompt", MAX_REQUEST_BYTES)
            review_input = read_regular_file(
                args.input, "review input", MAX_REQUEST_BYTES
            )
            if not prompt or not review_input:
                raise ReviewInputError(
                    "request prompt and review input must be non-empty"
                )
            request = build_review_request(prompt, review_input)
            sys.stdout.buffer.write(request)
            return 0
        base = require_commit(args.base, "base")
        reviewed = require_commit(args.reviewed, "reviewed")
        git_bytes("cat-file", "-e", f"{base}^{{commit}}")
        git_bytes("cat-file", "-e", f"{reviewed}^{{commit}}")
        if base == reviewed:
            raise ReviewInputError("base and reviewed commits must differ")
        if args.command == "preflight":
            head = git_bytes("rev-parse", "HEAD").decode().strip()
            if head != reviewed:
                raise ReviewInputError(
                    "reviewed commit must equal the clean worktree HEAD"
                )
            git_bytes("merge-base", "--is-ancestor", base, reviewed)
            dirty = git_bytes(
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignore-submodules=none",
            )
            if dirty:
                raise ReviewInputError(
                    "review requires a clean worktree, including submodules"
                )
            print("review preflight passed")
            return 0
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
