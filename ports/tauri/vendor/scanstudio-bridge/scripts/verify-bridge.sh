#!/usr/bin/env bash
# One-command local verification for the bridge port (Phase 2, CONTEXT
# decision 5). Three tiers, each printed with a header:
#   Tier 1 (required): frozen uv sync + full pytest suite
#   Tier 2 (required): the NDJSON byte-discipline test, run explicitly and
#                      separately from the full suite (BRDG-02's guard)
#   Tier 3 (optional): Linux python:3.13 Docker run, best-effort only --
#                      runs when `docker info` succeeds, never blocks the
#                      exit code either way (matches the project's
#                      verification-tier rule: Docker when available).
# Mirrors scripts/smoke_bridge.sh's conventions: set -euo pipefail,
# SCRIPT_DIR-relative path resolution, never touches the real ~/.scanstudio.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# The CoolScanPy sibling that [tool.uv.sources] resolves against. Only these
# two source directories are ever bind-mounted into Docker.
COOLSCANPY_DIR="$(cd "$BRIDGE_DIR/../coolscanpy" && pwd)"

cd "$BRIDGE_DIR"

echo "[verify-bridge] tier 1 (required): frozen uv sync + full pytest suite"
uv sync --frozen
uv run pytest -q
echo "[verify-bridge] tier 1 PASSED"

echo "[verify-bridge] tier 2 (required): NDJSON byte-discipline test"
uv run pytest tests/test_stdout_byte_discipline.py -q
echo "[verify-bridge] tier 2 PASSED"

echo "[verify-bridge] tier 3 (optional): Linux python:3.13 Docker run"
if docker info >/dev/null 2>&1; then
  docker run --rm \
    -v "$BRIDGE_DIR:/workspace/scanstudio-bridge:ro" \
    -v "$COOLSCANPY_DIR:/workspace/coolscanpy:ro" \
    -w /workspace/scanstudio-bridge \
    -e UV_PROJECT_ENVIRONMENT=/opt/bridge-venv \
    python:3.13 \
    bash -c "apt-get update -qq && apt-get install -y -qq libsane-dev libusb-1.0-0-dev libusb-1.0-0 pkg-config >/dev/null 2>&1 && pip install -q uv && uv sync --frozen && uv run pytest -q" \
    && echo "[verify-bridge] tier 3 PASSED" \
    || echo "[verify-bridge] tier 3 SKIPPED OR FAILED -- optional, not a gate"
else
  echo "[verify-bridge] tier 3 SKIPPED -- docker not available, skipping optional tier 3"
fi

echo "[verify-bridge] required tiers PASSED"
