"""BRDG-02 subprocess-level regression guard: the bridge's stdout must be
byte-exact NDJSON -- every line `\n`-terminated, zero `\r` bytes -- on every
OS (BRIDGE.md: "exactly one JSON object per line, UTF-8, `\n` terminated").

Distinct from test_cli.py's in-process StringIO tests: only a real
subprocess exercises the OS-level text-mode newline translation that this
guard exists for. Passes trivially on macOS/Linux (neither translates
`\n`), but is the real proof point once run in Windows CI, where text-mode
stdout would otherwise turn every `\n` into `\r\n` on the wire.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path


def test_bridge_stdout_is_byte_exact_ndjson(tmp_path: Path) -> None:
    request_lines = (
        b'{"id":1,"method":"bridge.hello",'
        b'"params":{"clientName":"byte-test","protocolVersion":1}}\n'
        b'{"id":2,"method":"bridge.shutdown"}\n'
    )
    bridge_root = Path(__file__).resolve().parent.parent
    env = dict(os.environ)
    env["SCANSTUDIO_BRIDGE_TRANSPORT"] = "mock"
    env["SCANSTUDIO_BRIDGE_BASE_DIR"] = str(tmp_path)

    result = subprocess.run(
        ["uv", "run", "scanstudio-bridge"],
        cwd=bridge_root,
        input=request_lines,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        timeout=30,
    )

    assert b"\r" not in result.stdout

    lines = [line for line in result.stdout.split(b"\n") if line]
    assert len(lines) >= 2
    for line in lines:
        json.loads(line.decode("utf-8"))
