#!/usr/bin/env python3

from pathlib import Path
import subprocess
import sys
import time


HERE = Path(__file__).resolve().parent
SMOKE = HERE.parent / "sidecar-smoke.py"
SILENT_ENGINE = HERE / "fixtures" / "silent_engine.py"

started = time.monotonic()
result = subprocess.run(
    [
        sys.executable,
        str(SMOKE),
        sys.executable,
        "--engine-arg",
        str(SILENT_ENGINE),
        "--response-timeout",
        "0.25",
        "--shutdown-timeout",
        "0.25",
    ],
    capture_output=True,
    text=True,
    timeout=2.0,
    check=False,
)
elapsed = time.monotonic() - started

assert result.returncode != 0, result.stdout + result.stderr
assert elapsed < 1.5, f"silent sidecar exceeded bound: {elapsed:.3f}s"
assert "timed out after 0.250s" in result.stderr, result.stderr
print(f"PASS  silent living sidecar failed in {elapsed:.3f}s")
