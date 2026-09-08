#!/usr/bin/env python3
"""Fail when live hardware guidance drifts behind the canonical matrix."""

from __future__ import annotations

import ast
from pathlib import Path
import re
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CANONICAL_MATRIX = Path("docs/HARDWARE-SUPPORT.md")
LIVE_GUIDES = (Path("README.md"), Path("app/ScanStudio/README.md"))
OBSOLETE_LIVE_PHRASES = (
    "v0.3.0-beta.1",
    "v0.3.0-beta.2",
    "macOS packages are ad-hoc-signed",
    "macOS builds are ad-hoc signed",
)
REQUIRED_COLUMNS = (
    "Package built",
    "Device enumerated",
    "Preview exercised",
    "One-frame capture validated",
)


class HardwareSupportDocsError(ValueError):
    """The live hardware guidance is stale or internally inconsistent."""


def _driver_model_names(root: Path) -> tuple[set[str], str]:
    path = root / "coolscanpy/src/coolscanpy/_device.py"
    try:
        module = ast.parse(path.read_text(encoding="utf-8"))
        values = {}
        for statement in module.body:
            if isinstance(statement, ast.Assign) and len(statement.targets) == 1:
                target = statement.targets[0]
            elif isinstance(statement, ast.AnnAssign):
                target = statement.target
            else:
                continue
            if isinstance(target, ast.Name):
                values[target.id] = statement.value
        required = ("_NIKON_COOLSCAN_USB_MODELS", "_SANE_COOLSCAN_MODEL_MARKERS")

        class Constants(ast.NodeTransformer):
            def visit_Name(self, node):
                replacement = values.get(node.id)
                if not isinstance(replacement, ast.Constant):
                    raise ValueError(f"unresolved constant {node.id}")
                return replacement

        tables = []
        for name in required:
            tables.append(ast.literal_eval(Constants().visit(values[name])))
        usb, sane = tables
        models = {model for products in usb.values() for model in products.values()}
        models.update(model for _, model in sane)
        verified = ast.literal_eval(values["_CANONICAL_LS5000_MODEL"])
        if not all(isinstance(model, str) for model in models) or verified not in models:
            raise ValueError("invalid model names")
        return models, verified
    except (OSError, SyntaxError, ValueError, TypeError, KeyError, AttributeError) as error:
        raise HardwareSupportDocsError(
            f"driver identity tables missing or no longer a literal structure: {error}"
        ) from error


def _verify_model_table(root: Path, matrix: str) -> None:
    for heading in ("## Model compatibility", "## Testing an unverified scanner"):
        if heading not in matrix:
            raise HardwareSupportDocsError(f"missing {heading}")
    section = matrix.split("## Model compatibility", 1)[1].split("\n## ", 1)[0]
    rows = {}
    for line in section.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) == 5 and cells[0] not in ("Model", "---"):
            rows[cells[0]] = cells[-1].replace("**", "")
    models, verified = _driver_model_names(root)
    if set(rows) != models:
        raise HardwareSupportDocsError(f"model table differs from driver: {sorted(set(rows) ^ models)}")
    for model, status in rows.items():
        valid = status.startswith("Verified") if model == verified else (
            "unverified" in status or status.startswith("Recognized by name only")
        )
        if not valid:
            raise HardwareSupportDocsError(f"incorrect verification claim for {model}: {status}")


def _latest_release_note(root: Path) -> str:
    candidates: list[tuple[tuple[int, int, int, int], str]] = []
    pattern = re.compile(r"v(\d+)\.(\d+)\.(\d+)-beta\.(\d+)\.md")
    for path in (root / "docs" / "releases").glob("v*.md"):
        match = pattern.fullmatch(path.name)
        if match:
            candidates.append((tuple(int(part) for part in match.groups()), path.stem))
    if not candidates:
        raise HardwareSupportDocsError("no versioned release notes were found")
    return max(candidates)[1]


def verify_hardware_support_docs(root: Path = REPOSITORY_ROOT) -> None:
    matrix_path = root / CANONICAL_MATRIX
    try:
        matrix = matrix_path.read_text(encoding="utf-8")
    except OSError as error:
        raise HardwareSupportDocsError(f"cannot read {CANONICAL_MATRIX}: {error}") from error

    latest = _latest_release_note(root)
    if f"Latest release notes: [{latest}]" not in matrix:
        raise HardwareSupportDocsError(
            f"{CANONICAL_MATRIX} does not name the newest documented release {latest}"
        )
    for column in REQUIRED_COLUMNS:
        if column not in matrix:
            raise HardwareSupportDocsError(
                f"{CANONICAL_MATRIX} is missing evidence column {column!r}"
            )
    for issue in (24, 26):
        marker = f"closed evidence #{issue}"
        if marker not in matrix:
            raise HardwareSupportDocsError(
                f"closed validation issue #{issue} must be labelled as closed evidence"
            )
    if "issues/101" not in matrix or "issues/104" not in matrix:
        raise HardwareSupportDocsError(
            "the canonical matrix must link the meter and release-verification follow-ups"
        )

    _verify_model_table(root, matrix)

    for relative_path in LIVE_GUIDES:
        try:
            text = (root / relative_path).read_text(encoding="utf-8")
        except OSError as error:
            raise HardwareSupportDocsError(f"cannot read {relative_path}: {error}") from error
        if "docs/HARDWARE-SUPPORT.md" not in text and "HARDWARE-SUPPORT.md" not in text:
            raise HardwareSupportDocsError(
                f"{relative_path} does not point to the canonical hardware matrix"
            )
        for phrase in OBSOLETE_LIVE_PHRASES:
            if phrase.casefold() in text.casefold():
                raise HardwareSupportDocsError(
                    f"{relative_path} contains obsolete live guidance {phrase!r}"
                )


def main() -> int:
    try:
        verify_hardware_support_docs()
    except HardwareSupportDocsError as error:
        print(f"Hardware-support documentation verification failed: {error}", file=sys.stderr)
        return 1
    print("Hardware-support documentation verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
