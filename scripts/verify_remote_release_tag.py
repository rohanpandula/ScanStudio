#!/usr/bin/env python3
"""Re-fetch and pin a remote release tag to its exact build commit and object."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys
from typing import Sequence


OBJECT_RE = re.compile(r"[0-9a-f]{40}")
TAG_RE = re.compile(r"v[A-Za-z0-9][A-Za-z0-9._-]{0,126}")
REMOTE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
STAGE_RE = re.compile(r"[a-z][a-z0-9-]{0,31}")


class RemoteTagError(ValueError):
    """The remote tag cannot be proven identical to the authorized tag."""


@dataclass(frozen=True)
class RemoteTag:
    object_sha: str
    commit_sha: str
    object_type: str


def _git(repository: Path, *arguments: str) -> str:
    try:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise RemoteTagError(f"cannot execute git: {error}") from error
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise RemoteTagError(
            f"git {' '.join(arguments[:2])} failed with "
            f"exit {completed.returncode}: {detail}"
        )
    return completed.stdout.strip()


def verify_remote_release_tag(
    repository: Path,
    *,
    remote: str,
    tag: str,
    expected_commit: str,
    run_id: int,
    run_attempt: int,
    stage: str,
    expected_object: str | None = None,
) -> RemoteTag:
    repository = Path(repository)
    if not repository.is_dir() or repository.is_symlink():
        raise RemoteTagError(
            f"repository must be a real, non-symlink directory: {repository}"
        )
    if REMOTE_RE.fullmatch(remote) is None:
        raise RemoteTagError(f"invalid git remote name: {remote!r}")
    if TAG_RE.fullmatch(tag) is None:
        raise RemoteTagError(f"invalid release tag: {tag!r}")
    if OBJECT_RE.fullmatch(expected_commit) is None:
        raise RemoteTagError("expected commit must be a lowercase full SHA")
    if expected_object is not None and OBJECT_RE.fullmatch(expected_object) is None:
        raise RemoteTagError("expected tag object must be a lowercase full SHA")
    if not isinstance(run_id, int) or run_id <= 0:
        raise RemoteTagError("run_id must be a positive integer")
    if not isinstance(run_attempt, int) or run_attempt <= 0:
        raise RemoteTagError("run_attempt must be a positive integer")
    if STAGE_RE.fullmatch(stage) is None:
        raise RemoteTagError(f"invalid verification stage: {stage!r}")

    head = _git(repository, "rev-parse", "HEAD")
    if head != expected_commit:
        raise RemoteTagError(
            f"checked-out commit changed: expected={expected_commit} actual={head}"
        )

    temporary_ref = (
        f"refs/scanstudio-release-verification/{run_id}/{run_attempt}/{stage}"
    )
    _git(repository, "update-ref", "-d", temporary_ref)
    source_ref = f"refs/tags/{tag}"
    try:
        _git(
            repository,
            "fetch",
            "--no-tags",
            "--force",
            "--no-write-fetch-head",
            remote,
            f"+{source_ref}:{temporary_ref}",
        )
    except RemoteTagError as error:
        raise RemoteTagError(
            f"remote tag fetch failed for {source_ref}: {error}"
        ) from error

    object_sha = _git(repository, "rev-parse", temporary_ref)
    commit_sha = _git(repository, "rev-parse", f"{temporary_ref}^{{commit}}")
    object_type = _git(repository, "cat-file", "-t", temporary_ref)
    if object_type not in {"commit", "tag"}:
        raise RemoteTagError(
            f"remote release ref has unsupported object type: {object_type!r}"
        )
    if commit_sha != expected_commit:
        raise RemoteTagError(
            f"remote tag commit changed: expected={expected_commit} actual={commit_sha}"
        )
    if expected_object is not None and object_sha != expected_object:
        raise RemoteTagError(
            f"remote tag object changed: expected={expected_object} actual={object_sha}"
        )
    return RemoteTag(
        object_sha=object_sha,
        commit_sha=commit_sha,
        object_type=object_type,
    )


def _append_github_output(path: Path, remote_tag: RemoteTag) -> None:
    try:
        with path.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(f"tag_object_sha={remote_tag.object_sha}\n")
            handle.write(f"tag_commit_sha={remote_tag.commit_sha}\n")
            handle.write(f"tag_object_type={remote_tag.object_type}\n")
    except OSError as error:
        raise RemoteTagError(f"cannot write GitHub outputs: {error}") from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--expected-object")
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--run-attempt", required=True, type=int)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--github-output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        remote_tag = verify_remote_release_tag(
            arguments.repository_root,
            remote=arguments.remote,
            tag=arguments.tag,
            expected_commit=arguments.expected_commit,
            expected_object=arguments.expected_object,
            run_id=arguments.run_id,
            run_attempt=arguments.run_attempt,
            stage=arguments.stage,
        )
        if arguments.github_output is not None:
            _append_github_output(arguments.github_output, remote_tag)
    except (OSError, RemoteTagError) as error:
        print(f"Remote release tag verification failed: {error}", file=sys.stderr)
        return 1
    print(
        "Remote release tag verified: "
        f"tag={arguments.tag} object={remote_tag.object_sha} "
        f"commit={remote_tag.commit_sha} type={remote_tag.object_type}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
