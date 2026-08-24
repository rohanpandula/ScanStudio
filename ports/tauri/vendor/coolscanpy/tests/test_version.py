from __future__ import annotations

import importlib
import importlib.metadata
import tomllib
from pathlib import Path

import coolscanpy
import pytest


def project_version() -> str:
    pyproject = Path(__file__).resolve().parents[1] / "pyproject.toml"
    return tomllib.loads(pyproject.read_text(encoding="utf-8"))["project"]["version"]


def test_runtime_version_matches_project_metadata() -> None:
    assert coolscanpy.__version__ == project_version()


def test_source_tree_fallback_reads_project_metadata(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    expected = project_version()

    def missing_distribution(_name: str) -> str:
        raise importlib.metadata.PackageNotFoundError

    with monkeypatch.context() as context:
        context.setattr(importlib.metadata, "version", missing_distribution)
        reloaded = importlib.reload(coolscanpy)
        assert reloaded.__version__ == expected

    importlib.reload(coolscanpy)
