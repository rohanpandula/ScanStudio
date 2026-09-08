#!/usr/bin/env python3
"""Keep the operator CLI guide aligned with the control-channel contract."""

from __future__ import annotations

from pathlib import Path
import re
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CONTROL_DOC = Path("app/ScanStudio/protocol/CONTROL.md")
CLI_DOC = Path("docs/CLI.md")
EXIT_SOURCE = Path("app/ScanStudio/Sources/ScanStudioKit/ControlCLISupport.swift")


class CLIDocsError(ValueError):
    """The CLI guide disagrees with the executable or protocol contract."""


def _section(text: str, heading: str) -> str:
    marker = f"## {heading}"
    start = text.find(marker)
    if start < 0:
        raise CLIDocsError(f"missing {marker}")
    end = text.find("\n## ", start + len(marker))
    return text[start:] if end < 0 else text[start:end]


def _table_rows(section: str) -> list[list[str]]:
    rows: list[list[str]] = []
    for line in section.splitlines():
        if not line.startswith("|") or line.startswith("|---") or line.startswith("| ---"):
            continue
        body = line.strip()[1:-1]
        cells = [cell.replace(r"\|", "|").strip() for cell in re.split(r"(?<!\\)\|", body)]
        if cells and cells[0].lower() not in {"exit", "subcommand"}:
            rows.append(cells)
    return rows


def parse_exit_codes(source: str) -> set[int]:
    """Read only case lines inside ControlCLIExitCode, ignoring comments."""
    start = source.find("public enum ControlCLIExitCode")
    if start < 0:
        raise CLIDocsError("ControlCLIExitCode enum is missing")
    end = source.find("/// Maps a wire-level", start)
    body = source[start:] if end < 0 else source[start:end]
    return {int(value) for line in body.splitlines() if not line.lstrip().startswith("//")
            for value in re.findall(r"^\s*case\s+\w+\s*=\s*(-?\d+)\s*$", line)}


def parse_command_paths(cell: str) -> set[str]:
    """Extract leading invocation paths from one mapping-table cell."""
    paths: set[str] = set()
    for form in re.findall(r"`([^`]+)`", cell):
        path = re.split(r"\s+(?:--|-{1,2})|\s*<|\||\s*\[", form, maxsplit=1)[0].strip()
        if path:
            paths.add(path)
    return paths


def parse_control(control: str) -> tuple[dict[int, str], set[str], set[str], str]:
    exits = {}
    for row in _table_rows(_section(control, "Exit codes")):
        if len(row) >= 2 and row[0].isdigit():
            exits[int(row[0])] = row[1]
    mapping = _section(control, "Command-line mapping")
    commands = {path for row in _table_rows(mapping) for path in parse_command_paths(row[0])}
    methods = set(re.findall(r"^### `([^`]+)`", _section(control, "Methods"), re.MULTILINE))
    return exits, commands, methods, _section(control, "Not yet implemented")


def parse_cli(cli: str) -> tuple[dict[int, str], str]:
    exits = {}
    for row in _table_rows(_section(cli, "Exit codes")):
        if len(row) >= 2 and row[0].isdigit():
            exits[int(row[0])] = row[1]
    return exits, cli


def verify_cli_docs(root: Path = REPOSITORY_ROOT) -> None:
    try:
        control = (root / CONTROL_DOC).read_text(encoding="utf-8")
        cli = (root / CLI_DOC).read_text(encoding="utf-8")
        source = (root / EXIT_SOURCE).read_text(encoding="utf-8")
    except OSError as error:
        raise CLIDocsError(f"cannot read CLI contract input: {error}") from error

    control_exits, commands, methods, not_implemented = parse_control(control)
    cli_exits, cli_text = parse_cli(cli)
    enum_exits = parse_exit_codes(source)
    if enum_exits != set(control_exits):
        raise CLIDocsError(f"exit-code enum {sorted(enum_exits)} disagrees with CONTROL.md {sorted(control_exits)}")
    if set(cli_exits) != enum_exits:
        missing = sorted(enum_exits - set(cli_exits))
        extra = sorted(set(cli_exits) - enum_exits)
        raise CLIDocsError(f"CLI.md exit codes disagree: missing {missing}, extra {extra}")
    normalise = lambda value: " ".join(value.casefold().split())
    for code, meaning in control_exits.items():
        if normalise(cli_exits[code]) != normalise(meaning):
            raise CLIDocsError(f"exit code {code} meaning disagrees between CLI.md and CONTROL.md")
    for path in sorted(commands):
        if not re.search(rf"(?<![\w-]){re.escape(path)}(?![\w-])", cli_text):
            raise CLIDocsError(f"CLI.md is missing command path {path}")
    for method in sorted(methods):
        if method not in cli_text and method not in not_implemented:
            raise CLIDocsError(f"CLI.md is missing wire method {method}")


def main() -> int:
    try:
        verify_cli_docs()
    except CLIDocsError as error:
        print(f"CLI documentation verification failed: {error}", file=sys.stderr)
        return 1
    print("CLI documentation verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
