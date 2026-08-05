from __future__ import annotations

import tomllib
from pathlib import Path

import coolscanpy


def test_runtime_version_matches_project_metadata() -> None:
    pyproject = Path(__file__).resolve().parents[1] / "pyproject.toml"
    project = tomllib.loads(pyproject.read_text(encoding="utf-8"))["project"]

    assert coolscanpy.__version__ == project["version"]
