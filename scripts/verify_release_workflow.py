#!/usr/bin/env python3
"""Enforce ScanStudio's fail-closed, exact-SHA release workflow structure."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
from types import ModuleType
from typing import Iterable


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "release.yml"
VERIFICATION_WORKFLOW_PATH = REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"


class ReleaseWorkflowError(ValueError):
    """The release workflow can bypass required same-run verification."""


def _load(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ReleaseWorkflowError(f"cannot load release verifier dependency: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


_YAML = _load(
    "scanstudio_github_action_policy",
    REPOSITORY_ROOT / "scripts" / "check_github_action_pins.py",
)
_RESULTS = _load(
    "scanstudio_required_release_jobs",
    REPOSITORY_ROOT / "scripts" / "verify_required_job_results.py",
)

REQUIRED_RELEASE_JOBS = tuple(_RESULTS.REQUIRED_JOBS)
EXPECTED_RELEASE_JOBS = set(REQUIRED_RELEASE_JOBS) | {"verification-gate", "publish"}
REQUIRED_VERIFICATION_FAMILIES = (
    "app-and-engine",
    "bridge",
    "coolscanpy",
    "ports-vendor-sync",
    "package",
    "package-macos-14",
    "updater-integration",
)
EXPECTED_VERIFICATION_JOBS = set(REQUIRED_VERIFICATION_FAMILIES) | {"verification-gate"}
CHECKOUT_ACTION = "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
EXACT_SHA_EXPRESSION = "${{ github.sha }}"

EXPECTED_RELEASE_NEEDS = {
    "verify": {"authorize"},
    "authorize": set(),
    "release": {"verify"},
    "windows-resources": {"verify"},
    "windows": {"windows-resources"},
    "linux": {"verify"},
    "verification-gate": set(REQUIRED_RELEASE_JOBS),
    "publish": {"authorize", "verify", "verification-gate"},
}


def _mapping(node: object, role: str) -> dict[str, object]:
    try:
        return _YAML._map(node, role)
    except _YAML.PolicyError as error:
        raise ReleaseWorkflowError(f"{role}: {error.message}") from error


def _scalar(node: object, role: str) -> str:
    try:
        return _YAML._scalar(node, role)
    except _YAML.PolicyError as error:
        raise ReleaseWorkflowError(f"{role}: {error.message}") from error


def _sequence_values(node: object, role: str) -> list[str]:
    if node.kind == "scalar":
        return [_scalar(node, role)]
    if node.kind != "list":
        raise ReleaseWorkflowError(f"{role} must be a scalar or sequence")
    return [_scalar(item, role) for item in node.value]


def _parse(source: str, role: str) -> tuple[dict[str, object], dict[str, object]]:
    try:
        root = _YAML._Parser(_YAML._logical_lines(source)).parse()
    except _YAML.PolicyError as error:
        raise ReleaseWorkflowError(
            f"{role} YAML is outside the canonical subset: {error.message}"
        ) from error
    root_map = _mapping(root, role)
    jobs_node = root_map.get("jobs")
    if jobs_node is None:
        raise ReleaseWorkflowError(f"{role} has no jobs")
    return root_map, _mapping(jobs_node, f"{role} jobs")


def _job_source(source: str, jobs: dict[str, object], job_name: str) -> str:
    ordered = sorted((node.line, name) for name, node in jobs.items())
    start = jobs[job_name].line - 1
    following = [line - 1 for line, _name in ordered if line - 1 > start]
    end = min(following) if following else len(source.splitlines())
    return "\n".join(source.splitlines()[start:end]) + "\n"


def _step_source(job_source: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = job_source.find(marker)
    if start < 0:
        raise ReleaseWorkflowError(f"required release step is missing: {name}")
    following = job_source.find("\n      - ", start + len(marker))
    return job_source[start : following if following >= 0 else len(job_source)]


def _require(source: str, marker: str, role: str) -> None:
    if marker not in source:
        raise ReleaseWorkflowError(f"{role} is missing or changed")


def _require_all(source: str, markers: Iterable[tuple[str, str]]) -> None:
    for marker, role in markers:
        _require(source, marker, role)


def _needs(job: dict[str, object], role: str) -> set[str]:
    node = job.get("needs")
    return set(_sequence_values(node, role)) if node is not None else set()


def _verify_checkout(job_name: str, job: dict[str, object]) -> None:
    steps = job.get("steps")
    if steps is None or steps.kind != "list":
        raise ReleaseWorkflowError(f"{job_name} must have a steps sequence")
    checkout_steps: list[dict[str, object]] = []
    for node in steps.value:
        step = _mapping(node, f"{job_name} step")
        uses = step.get("uses")
        if uses is not None and _scalar(uses, f"{job_name} uses") == CHECKOUT_ACTION:
            checkout_steps.append(step)
    if len(checkout_steps) != 1:
        raise ReleaseWorkflowError(
            f"{job_name} must have exactly one pinned checkout step"
        )
    inputs_node = checkout_steps[0].get("with")
    if inputs_node is None:
        raise ReleaseWorkflowError(f"{job_name} checkout requires exact inputs")
    inputs = _mapping(inputs_node, f"{job_name} checkout inputs")
    ref = inputs.get("ref")
    persisted = inputs.get("persist-credentials")
    if ref is None or _scalar(ref, f"{job_name} checkout ref") != EXACT_SHA_EXPRESSION:
        raise ReleaseWorkflowError(f"{job_name} checkout must use the exact github.sha")
    if (
        persisted is None
        or _scalar(persisted, f"{job_name} checkout persist-credentials") != "false"
    ):
        raise ReleaseWorkflowError(
            f"{job_name} checkout must disable persisted credentials"
        )


def _verify_called_workflow(
    source: str, root: dict[str, object], jobs: dict[str, object]
) -> None:
    on = _mapping(root["on"], "verification workflow triggers")
    workflow_call = on.get("workflow_call")
    if workflow_call is None:
        raise ReleaseWorkflowError("verification workflow must expose workflow_call")
    call = _mapping(workflow_call, "verification workflow_call")
    outputs = _mapping(call["outputs"], "verification workflow outputs")
    verified = _mapping(outputs["verified_sha"], "verified_sha output")
    if _scalar(verified["value"], "verified_sha value") != (
        "${{ jobs.verification-gate.outputs.verified_sha }}"
    ):
        raise ReleaseWorkflowError("verified_sha must come from verification-gate")

    if set(jobs) != EXPECTED_VERIFICATION_JOBS:
        raise ReleaseWorkflowError(
            "verification family set changed: "
            f"missing={sorted(EXPECTED_VERIFICATION_JOBS - set(jobs))} "
            f"extra={sorted(set(jobs) - EXPECTED_VERIFICATION_JOBS)}"
        )
    gate = _mapping(jobs["verification-gate"], "called verification-gate")
    if _needs(gate, "called verification-gate needs") != set(
        REQUIRED_VERIFICATION_FAMILIES
    ):
        raise ReleaseWorkflowError(
            "called verification-gate needs every required verification family"
        )
    gate_if = gate.get("if")
    if gate_if is None or _scalar(gate_if, "called verification-gate if") != (
        "${{ always() }}"
    ):
        raise ReleaseWorkflowError("called verification-gate must run with always()")
    gate_source = _job_source(source, jobs, "verification-gate")
    for family in REQUIRED_VERIFICATION_FAMILIES:
        _require(
            gate_source,
            'test "${{ needs.' + family + '.result }}" = success',
            f"explicit success proof for {family}",
        )
    _require(
        gate_source,
        'echo "verified_sha=$GITHUB_SHA" >> "$GITHUB_OUTPUT"',
        "exact verified SHA output",
    )
    ports_source = _job_source(source, jobs, "ports-vendor-sync")
    _require(
        ports_source,
        "python3 -I -S -B scripts/verify_release_workflow.py",
        "direct release workflow policy invocation",
    )


def _verify_release_graph(jobs: dict[str, object]) -> None:
    if set(jobs) != EXPECTED_RELEASE_JOBS:
        raise ReleaseWorkflowError(
            "release job set changed: "
            f"missing={sorted(EXPECTED_RELEASE_JOBS - set(jobs))} "
            f"extra={sorted(set(jobs) - EXPECTED_RELEASE_JOBS)}"
        )
    for name, expected in EXPECTED_RELEASE_NEEDS.items():
        job = _mapping(jobs[name], f"release job {name}")
        actual = _needs(job, f"{name} needs")
        if actual != expected:
            raise ReleaseWorkflowError(
                f"{name} needs changed: expected={sorted(expected)} "
                f"actual={sorted(actual)}"
            )
        if name != "verify":
            _verify_checkout(name, job)

    verify = _mapping(jobs["verify"], "reusable verification job")
    if set(verify) != {"name", "needs", "permissions", "uses"}:
        raise ReleaseWorkflowError(
            "reusable verification job may only declare name needs permissions and uses"
        )
    if _scalar(verify["uses"], "reusable verification workflow") != (
        "./.github/workflows/ci.yml"
    ):
        raise ReleaseWorkflowError(
            "release verification must directly call the repository Verify workflow"
        )
    permissions = _mapping(verify["permissions"], "reusable verification permissions")
    if (
        set(permissions) != {"contents"}
        or _scalar(permissions["contents"], "reusable verification contents permission")
        != "read"
    ):
        raise ReleaseWorkflowError(
            "reusable verification job must have contents read permission only"
        )

    gate = _mapping(jobs["verification-gate"], "release verification-gate")
    gate_if = gate.get("if")
    if gate_if is None or _scalar(gate_if, "release verification-gate if") != (
        "${{ always() }}"
    ):
        raise ReleaseWorkflowError("release verification-gate must run with always()")

    release = _mapping(jobs["release"], "release package matrix")
    strategy = _mapping(release["strategy"], "release strategy")
    if _scalar(strategy["fail-fast"], "release fail-fast") != "true":
        raise ReleaseWorkflowError("release matrix must keep fail-fast enabled")
    matrix = _mapping(strategy["matrix"], "release matrix")
    if _sequence_values(matrix["arch"], "release matrix architectures") != [
        "arm64",
        "x86_64",
    ]:
        raise ReleaseWorkflowError(
            "release native package matrix must be exactly arm64 and x86_64"
        )


def _verify_release_commands(source: str, jobs: dict[str, object]) -> None:
    job_sources = {name: _job_source(source, jobs, name) for name in jobs}

    authorize = job_sources["authorize"]
    _require_all(
        authorize,
        (
            ("id: remote-tag", "authorize remote-tag output step"),
            ("scripts/verify_remote_release_tag.py", "authorize remote tag check"),
            ("--stage authorize", "authorize tag-check stage"),
            ("tag_object_sha:", "authorized tag-object output"),
            (
                "python3 -I -S -B scripts/verify_release_workflow.py",
                "authorize release workflow policy",
            ),
        ),
    )

    for name in ("release", "windows", "linux"):
        _require(
            job_sources[name],
            "scripts/release_provenance.py emit",
            f"{name} artifact provenance emission",
        )
    publish = job_sources["publish"]
    provenance_step = _step_source(publish, "Verify all exact-run artifact provenance")
    if provenance_step.count("scripts/release_provenance.py verify") != 4:
        raise ReleaseWorkflowError(
            "publish provenance must verify exactly four platform receipts"
        )

    gate = job_sources["verification-gate"]
    _require_all(
        gate,
        (
            (
                "SCANSTUDIO_REQUIRED_JOB_RESULTS: ${{ toJSON(needs) }}",
                "all-success needs context",
            ),
            (
                "python3 -I -S -B scripts/verify_required_job_results.py",
                "all-success result verifier",
            ),
            (
                "VERIFIED_SHA: ${{ needs.verify.outputs.verified_sha }}",
                "verified SHA input",
            ),
            ('test "$VERIFIED_SHA" = "$GITHUB_SHA"', "verified SHA equality"),
        ),
    )

    create = _step_source(publish, "Create and verify a draft GitHub prerelease")
    checker = "python3 -I -S -B scripts/verify_remote_release_tag.py"
    creator = 'gh release create "$GITHUB_REF_NAME"'
    if checker not in create or creator not in create:
        raise ReleaseWorkflowError(
            "draft remote tag check or creation command is missing"
        )
    if create.index(checker) > create.index(creator):
        raise ReleaseWorkflowError(
            "remote tag must be checked immediately before draft"
        )
    _require(create, "--stage draft", "draft remote tag stage")
    _require(create, "--expected-object", "draft tag-object pin")
    _require(create, "--verify-tag", "existing verify-tag protection")

    publication = _step_source(publish, "Publish and re-verify the prerelease")
    editor = 'gh release edit "$GITHUB_REF_NAME"'
    if checker not in publication or editor not in publication:
        raise ReleaseWorkflowError(
            "publication remote tag check or edit command is missing"
        )
    if publication.index(checker) > publication.index(editor):
        raise ReleaseWorkflowError(
            "remote tag must be checked immediately before publication"
        )
    _require(publication, "--stage publication", "publication remote tag stage")
    _require(publication, "--expected-object", "publication tag-object pin")

    for job_name, job_source in job_sources.items():
        if job_name == "publish":
            continue
        if "gh release create" in job_source or "gh release edit" in job_source:
            raise ReleaseWorkflowError(
                f"release mutation must exist only in publish, found in {job_name}"
            )


def verify_release_workflow(
    source: str, verification_source: str | None = None
) -> None:
    if "workflow_run" in source:
        raise ReleaseWorkflowError(
            "independent workflow_run verification cannot satisfy same-run policy"
        )
    if verification_source is None:
        verification_source = VERIFICATION_WORKFLOW_PATH.read_text(encoding="utf-8")
    verification_root, verification_jobs = _parse(
        verification_source, "verification workflow"
    )
    _verify_called_workflow(verification_source, verification_root, verification_jobs)
    _release_root, release_jobs = _parse(source, "release workflow")
    _verify_release_graph(release_jobs)
    _verify_release_commands(source, release_jobs)


def main() -> int:
    try:
        source = _YAML._read_workflow(WORKFLOW_PATH)
        verification_source = _YAML._read_workflow(VERIFICATION_WORKFLOW_PATH)
        verify_release_workflow(source, verification_source)
    except (OSError, ReleaseWorkflowError, _YAML.PolicyError) as error:
        print(f"Release workflow verification failed: {error}", file=sys.stderr)
        return 1
    print(
        "Release workflow verification passed: publication is gated on exact-SHA "
        "same-run verification"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
