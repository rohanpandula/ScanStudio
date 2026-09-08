#!/usr/bin/env python3
"""Compare CLI behavior while retaining substantive payloads and exit codes."""
import difflib
import json
import re
import sys
from pathlib import Path

# Process/session identity and timestamps change on every run.
VOLATILE = {
    "jobId", "sessionId", "hostPid", "hostStarted", "mode", "timestamp",
    "sequence", "startedAt", "completedAt", "createdAt", "operationId",
    "previewOperationId", "intentToken", "id",
    # Status samples occur while the simulated scan is advancing.
    "etaSeconds", "framePercent", "jobPercent",
}


def normalize(value):
    if isinstance(value, dict):
        return {key: "<volatile>" if key in VOLATILE else normalize(item)
                for key, item in value.items()}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, str):
        if re.match(r"^(?:/private)?/tmp/", value):
            return "<TMP>"
    return value


def read(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line]
    if not rows:
        raise ValueError(f"empty transcript: {path}")
    return json.dumps(normalize(rows), indent=2, sort_keys=True).splitlines(keepends=True)


def main():
    # This counterexample must survive normalization: parity cannot be vacuous.
    assert normalize({"selectedFrames": [1]}) != normalize({"selectedFrames": [2]})
    assert normalize({"exit": 0}) != normalize({"exit": 65})
    left, right = map(read, sys.argv[1:])
    difference = list(difflib.unified_diff(left, right, fromfile="in-process", tofile="headless"))
    if difference:
        sys.stdout.writelines(difference)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
