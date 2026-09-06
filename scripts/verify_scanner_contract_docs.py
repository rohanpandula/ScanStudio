#!/usr/bin/env python3
"""Verify current scanner contracts and operator copy describe shipped policy."""

from __future__ import annotations

from pathlib import Path
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CURRENT_DOCS = (
    Path("README.md"),
    Path("app/ScanStudio/README.md"),
    Path("app/ScanStudio/protocol/PROTOCOL.md"),
    Path("app/ScanStudio/protocol/BRIDGE.md"),
    Path("coolscanpy/README.md"),
)
FORBIDDEN = (
    "do not re-read the manifest before writing",
    "silently overwrite receipts",
    "real eject needs the [scanner] extra plus SANE",
    "delegated to SANE (`coolscanpy[scanner]` extra)",
    "software-eject paths",
)


class ScannerContractDocsError(ValueError):
    """Current scanner documentation contradicts the implemented contract."""


def verify_scanner_contract_docs(root: Path = REPOSITORY_ROOT) -> None:
    loaded: dict[Path, str] = {}
    for relative_path in CURRENT_DOCS:
        try:
            loaded[relative_path] = (root / relative_path).read_text(encoding="utf-8")
        except OSError as error:
            raise ScannerContractDocsError(f"cannot read {relative_path}: {error}") from error

    for relative_path, text in loaded.items():
        folded = text.casefold()
        for phrase in FORBIDDEN:
            if phrase.casefold() in folded:
                raise ScannerContractDocsError(
                    f"{relative_path} contains obsolete contract text {phrase!r}"
                )

    protocol = " ".join(
        loaded[Path("app/ScanStudio/protocol/PROTOCOL.md")].split()
    )
    for phrase in (
        "re-reads the fresh manifest while holding the project lock",
        "refuses rather than publish if fresh-disk receipt coverage would be lost",
    ):
        if phrase not in protocol:
            raise ScannerContractDocsError(
                f"PROTOCOL.md is missing receipt-preservation contract {phrase!r}"
            )

    bridge = " ".join(
        loaded[Path("app/ScanStudio/protocol/BRIDGE.md")].split()
    )
    for phrase in (
        "leading and trailing edges are intentionally asymmetric",
        "exactly one preview row",
        "trailing frame with at least 90%",
        "Eject does not require SANE or `scanimage`",
        "legacy plain-scan path",
    ):
        if phrase not in bridge:
            raise ScannerContractDocsError(
                f"BRIDGE.md is missing scanner contract {phrase!r}"
            )


def main() -> int:
    try:
        verify_scanner_contract_docs()
    except ScannerContractDocsError as error:
        print(f"Scanner-contract documentation verification failed: {error}", file=sys.stderr)
        return 1
    print("Scanner-contract documentation verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
