"""Package-resource and provenance checks for the LS-5000 single-pass core.

Ported from NegPy's tests/scanners/test_ls5000_single_pass_packaging.py with
the distribution-shape checks rewritten rather than copied, per M1 §4: the
source tests validated *NegPy's* flat-layout pyproject.toml/PyInstaller
build, which has no equivalent here. Dropped entirely (not portable):
test_all_negpy_packages_and_plan_resource_are_declared_for_distribution and
test_built_wheel_contains_and_imports_representative_application_packages
(NegPy-specific distribution shape, superseded below by
test_pyproject_declares_data_for_distribution and
test_built_wheel_contains_and_imports_the_ls5000_single_pass_core), and
test_desktop_helper_dispatch_runs_worker_without_starting_the_ui (exercises
negpy.desktop.main, which does not exist in this package).
"""

import hashlib
import inspect
import os
import subprocess
import sys
import tomllib
import zipfile
from pathlib import Path

import pytest

from coolscanpy.protocol.ls5000_single_pass import (
    bundle as capture_bundle,
    density,
    meter,
    packed,
    roll_index,
)
from coolscanpy.protocol.ls5000_single_pass.bundle import (
    CAPTURE_BUNDLE_SHA256,
    CAPTURE_WORKER_SHA256,
    CaptureBundleIntegrityError,
    verify_capture_bundle,
)
from coolscanpy.protocol.ls5000_single_pass.plan import (
    CANONICAL_FINE_READ_BYTES,
    CANONICAL_FINE_READ_CDB,
    CANONICAL_FINE_READ_COUNT,
    CANONICAL_PLAN_LINE_COUNT,
    CANONICAL_PLAN_SHA256,
    CanonicalPlanError,
    canonical_plan_bytes,
    load_canonical_plan,
    verify_canonical_plan,
)


REPO = Path(__file__).resolve().parents[3]


def test_bundled_plan_has_exact_proven_hash_and_fine_read_contract() -> None:
    payload = canonical_plan_bytes()
    plan = load_canonical_plan()

    assert hashlib.sha256(payload).hexdigest() == CANONICAL_PLAN_SHA256
    assert len(plan) == CANONICAL_PLAN_LINE_COUNT
    assert plan[0]["name"] == "INQUIRY"
    assert plan[0]["expected_data_in"].endswith("312e3033")  # LS-5000 ED firmware 1.03
    assert plan[-1]["role"] == "fine-rgbi4-template"
    assert plan[-1]["cdb"] == CANONICAL_FINE_READ_CDB
    assert plan[-1]["request_len"] == CANONICAL_FINE_READ_BYTES
    assert plan[-1]["repeat"] == CANONICAL_FINE_READ_COUNT
    assert plan[-1]["capture"] is True


def test_plan_integrity_check_refuses_even_one_changed_byte() -> None:
    payload = bytearray(canonical_plan_bytes())
    payload[100] ^= 1
    with pytest.raises(CanonicalPlanError, match="sha256 mismatch"):
        verify_canonical_plan(payload)


def test_core_modules_have_no_usb_or_campaign_tree_imports() -> None:
    for module in (density, meter, packed, roll_index):
        source = inspect.getsource(module)
        assert "single-pass-wire" not in source
        assert "negfit/data/wire" not in source
        assert "import usb" not in source
        assert "import pyusb" not in source


def test_packaged_capture_bundle_sources_match_their_stable_identity() -> None:
    assert verify_capture_bundle(require_python_sources=True) == CAPTURE_BUNDLE_SHA256
    assert len(CAPTURE_WORKER_SHA256) == 64


def test_capture_bundle_pins_the_continuation_parser_and_wire_resource(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setitem(
        capture_bundle.CAPTURE_BUNDLE_COMPONENT_SHA256,
        "continuation_plan.py",
        "0" * 64,
    )
    with pytest.raises(CaptureBundleIntegrityError, match="continuation_plan.py"):
        verify_capture_bundle(require_python_sources=True)

    monkeypatch.undo()
    canonical = capture_bundle.canonical_continuation_plan_bytes()
    monkeypatch.setattr(
        capture_bundle,
        "canonical_continuation_plan_bytes",
        lambda: canonical + b"changed",
    )
    with pytest.raises(CaptureBundleIntegrityError, match="continuation plan"):
        verify_capture_bundle(require_python_sources=False)


def test_real_packaged_worker_dry_run_does_not_touch_the_scanner() -> None:
    completed = subprocess.run(
        [
            sys.executable,
            "-I",
            "-m",
            "coolscanpy.protocol.ls5000_single_pass.worker",
            "--frame",
            "18",
            "--boundary-offset-rows",
            "0",
            "--confirm-full-capture",
        ],
        cwd=REPO,
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "619458560 bytes" in completed.stdout
    assert "dry run only; scanner was not accessed" in completed.stdout


def test_pyproject_declares_data_for_distribution() -> None:
    pyproject = tomllib.loads((REPO / "pyproject.toml").read_text(encoding="utf-8"))
    data_package = "coolscanpy.protocol.ls5000_single_pass.data"

    assert pyproject["tool"]["setuptools"]["packages"]["find"]["where"] == ["src"]
    assert pyproject["tool"]["setuptools"]["package-data"][data_package] == [
        "*.json",
        "*.jsonl",
    ]
    assert (
        REPO / "src" / "coolscanpy" / "protocol" / "ls5000_single_pass" / "data"
    ).is_dir()


def test_built_wheel_contains_and_imports_the_ls5000_single_pass_core(
    tmp_path: Path,
) -> None:
    wheel_dir = tmp_path / "wheel"
    wheel_dir.mkdir()

    build = subprocess.run(
        [
            sys.executable,
            "-c",
            "from setuptools.build_meta import build_wheel; import sys; build_wheel(sys.argv[1])",
            str(wheel_dir),
        ],
        cwd=REPO,
        check=True,
        capture_output=True,
        text=True,
    )
    wheels = list(wheel_dir.glob("*.whl"))
    assert len(wheels) == 1, build.stdout + build.stderr
    wheel = wheels[0]
    expected_members = {
        "coolscanpy/session/backend.py",
        "coolscanpy/receipts/writer.py",
        "coolscanpy/receipts/outputs.py",
        "coolscanpy/roll/preview_session.py",
        "coolscanpy/capture/sane_rgb_geometry.py",
        "coolscanpy/capture/single_pass_workflow.py",
        "coolscanpy/roll/controls.py",
        "coolscanpy/protocol/ls5000_single_pass/packed.py",
        "coolscanpy/protocol/ls5000_single_pass/density.py",
        "coolscanpy/protocol/ls5000_single_pass/meter.py",
        "coolscanpy/protocol/ls5000_single_pass/roll_index.py",
        "coolscanpy/protocol/ls5000_single_pass/plan.py",
        "coolscanpy/protocol/ls5000_single_pass/bundle.py",
        "coolscanpy/protocol/ls5000_single_pass/capture_process.py",
        "coolscanpy/protocol/ls5000_single_pass/continuation_plan.py",
        "coolscanpy/protocol/ls5000_single_pass/window.py",
        "coolscanpy/protocol/ls5000_single_pass/worker.py",
        "coolscanpy/protocol/ls5000_single_pass/data/replay-first-rgbi4-plan.jsonl",
        "coolscanpy/protocol/ls5000_single_pass/data/replay-first-rgbi4-manifest.json",
        "coolscanpy/protocol/ls5000_single_pass/data/replay-next-rgbi4-plan.json",
    }
    installed = tmp_path / "installed-wheel"
    with zipfile.ZipFile(wheel) as archive:
        assert expected_members <= set(archive.namelist())
        archive.extractall(installed)

    script = (
        "import hashlib, importlib, sys\n"
        "modules = [\n"
        "    'coolscanpy.session.backend',\n"
        "    'coolscanpy.receipts.writer',\n"
        "    'coolscanpy.protocol.ls5000_single_pass',\n"
        "]\n"
        "for name in modules:\n"
        "    module = importlib.import_module(name)\n"
        "    assert module.__file__.startswith(sys.argv[1]), (name, module.__file__)\n"
        "from coolscanpy.protocol.ls5000_single_pass.plan import (\n"
        "    CANONICAL_PLAN_SHA256,\n"
        "    canonical_plan_bytes,\n"
        ")\n"
        "assert hashlib.sha256(canonical_plan_bytes()).hexdigest() == CANONICAL_PLAN_SHA256\n"
        "from coolscanpy.protocol.ls5000_single_pass.continuation_plan import (\n"
        "    CANONICAL_CONTINUATION_PLAN_SHA256,\n"
        "    canonical_continuation_plan_bytes,\n"
        ")\n"
        "assert hashlib.sha256(canonical_continuation_plan_bytes()).hexdigest() == CANONICAL_CONTINUATION_PLAN_SHA256\n"
        "from coolscanpy.protocol.ls5000_single_pass.bundle import (\n"
        "    CAPTURE_BUNDLE_SHA256,\n"
        "    verify_capture_bundle,\n"
        ")\n"
        "assert verify_capture_bundle(require_python_sources=True) == CAPTURE_BUNDLE_SHA256\n"
    )
    env = os.environ.copy()
    env["PYTHONPATH"] = str(installed)
    imported = subprocess.run(
        [sys.executable, "-c", script, str(installed)],
        cwd=tmp_path,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    assert imported.returncode == 0, imported.stdout + imported.stderr

    dry_run = subprocess.run(
        [
            sys.executable,
            "-m",
            "coolscanpy.protocol.ls5000_single_pass.worker",
            "--frame",
            "18",
            "--confirm-full-capture",
        ],
        cwd=tmp_path,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    assert dry_run.returncode == 0, dry_run.stdout + dry_run.stderr
    assert "dry run only; scanner was not accessed" in dry_run.stdout
