#!/usr/bin/env python3
"""Fail when a workflow executes an external action without a full SHA pin."""

from __future__ import annotations

from pathlib import Path
import re
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_ROOT = REPOSITORY_ROOT / ".github" / "workflows"
USES_RE = re.compile(r"^(?P<indent>\s*)(?:-\s*)?uses:\s*(?P<value>.+?)\s*$")
EXTERNAL_RE = re.compile(r"^[^\s@]+@(?P<ref>[0-9a-f]{40})$")


def _uses_value(raw: str) -> str:
    value = raw.split("#", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def check_workflows(
    workflow_paths: list[Path], *, repository_root: Path
) -> tuple[list[str], int]:
    violations: list[str] = []
    external_count = 0
    for path in workflow_paths:
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            match = USES_RE.match(line)
            if match is None:
                continue
            value = _uses_value(match.group("value"))
            if value.startswith("./") or value.startswith("docker://"):
                continue
            external_count += 1
            display_path = path.relative_to(repository_root)
            if EXTERNAL_RE.fullmatch(value) is None:
                violations.append(
                    f"{display_path}:{index + 1}: external action is not pinned "
                    f"to a full lowercase commit SHA: {value}"
                )
                continue

            if value.startswith("actions/checkout@"):
                uses_indent = len(match.group("indent"))
                step_indent = (
                    uses_indent
                    if line.lstrip().startswith("- uses:")
                    else max(0, uses_indent - 2)
                )
                persists_credentials = False
                for following in lines[index + 1 :]:
                    if not following.strip() or following.lstrip().startswith("#"):
                        continue
                    following_indent = len(following) - len(following.lstrip())
                    if following_indent <= step_indent:
                        break
                    if re.match(
                        r"^\s*persist-credentials:\s*false\s*(?:#.*)?$", following
                    ):
                        persists_credentials = True
                if not persists_credentials:
                    violations.append(
                        f"{display_path}:{index + 1}: actions/checkout must set "
                        "persist-credentials: false"
                    )
    return violations, external_count


def main() -> int:
    workflow_paths = sorted(WORKFLOW_ROOT.glob("*.yml")) + sorted(
        WORKFLOW_ROOT.glob("*.yaml")
    )
    violations, external_count = check_workflows(
        workflow_paths, repository_root=REPOSITORY_ROOT
    )
    if external_count == 0:
        violations.append("no external workflow actions were found")
    if violations:
        print("GitHub Actions pin policy failed:", file=sys.stderr)
        print("\n".join(f"  {violation}" for violation in violations), file=sys.stderr)
        return 1
    print(f"GitHub Actions pin policy passed: {external_count} external uses entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
