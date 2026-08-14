from __future__ import annotations

import importlib
import importlib.metadata
import tomllib
from pathlib import Path

import coolscanpy
import pytest


def test_runtime_version_matches_project_metadata() -> None:
    pyproject = Path(__file__).resolve().parents[1] / "pyproject.toml"
    project = tomllib.loads(pyproject.read_text(encoding="utf-8"))["project"]

    assert coolscanpy.__version__ == project["version"]


def test_source_tree_fallback_reads_project_metadata(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def missing_distribution(_name: str) -> str:
        raise importlib.metadata.PackageNotFoundError

    with monkeypatch.context() as context:
        context.setattr(importlib.metadata, "version", missing_distribution)
        reloaded = importlib.reload(coolscanpy)
        assert reloaded.__version__ == "0.7.2"

    importlib.reload(coolscanpy)
