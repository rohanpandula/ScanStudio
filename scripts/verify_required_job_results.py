#!/usr/bin/env python3
"""Fail closed unless every required same-run release job succeeded."""

from __future__ import annotations

import json
import os
import sys
from typing import Any


REQUIRED_JOBS = (
    "verify",
    "authorize",
    "release",
    "windows-resources",
    "windows",
    "linux",
)
RESULTS_ENVIRONMENT_KEY = "SCANSTUDIO_REQUIRED_JOB_RESULTS"


class RequiredJobError(ValueError):
    """The GitHub Actions needs context is absent, malformed, or non-green."""


def verify_required_job_results(payload: Any) -> None:
    if not isinstance(payload, dict):
        raise RequiredJobError("required job results must be a JSON object")

    expected = set(REQUIRED_JOBS)
    actual = set(payload)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise RequiredJobError(
            f"required job result set changed: missing={missing} extra={extra}"
        )

    for job in REQUIRED_JOBS:
        entry = payload[job]
        if not isinstance(entry, dict):
            raise RequiredJobError(f"required job {job!r} has a malformed result")
        result = entry.get("result")
        if result != "success":
            raise RequiredJobError(
                f"required job {job!r} did not succeed: result={result!r}"
            )


def main() -> int:
    encoded = os.environ.get(RESULTS_ENVIRONMENT_KEY)
    if encoded is None:
        print(
            f"Release verification gate failed: {RESULTS_ENVIRONMENT_KEY} is absent",
            file=sys.stderr,
        )
        return 1
    try:
        payload = json.loads(encoded)
        verify_required_job_results(payload)
    except (json.JSONDecodeError, RequiredJobError) as error:
        print(f"Release verification gate failed: {error}", file=sys.stderr)
        return 1
    print("Release verification gate passed: every required same-run job succeeded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
