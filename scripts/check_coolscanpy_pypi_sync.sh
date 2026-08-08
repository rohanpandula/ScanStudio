#!/usr/bin/env bash
# Release gate: the driver inside this release must already be published on
# PyPI, so a standalone `pip install coolscanpy` user and a ScanStudio app
# user always run the same driver generation. A version delta between the
# two produces incomparable field reports for the same film -- the exact
# debugging confusion the instrumented-refusal work exists to prevent
# (owner policy, 2026-08-08: "keep them in sync so there's no delta").
#
# Mechanics: download the latest published coolscanpy sdist and compare its
# src/coolscanpy tree byte-for-byte against this repo's vendored
# coolscanpy/src/coolscanpy. Version strings are NOT trusted as the primary
# signal (an unbumped version with changed code is precisely the failure
# mode this gate exists to catch); the pyproject version is checked second,
# as bump discipline.
#
# The vendored tree deliberately diverges from the published package in a
# small, documented set of files (ScanStudio-specific behavior that must
# not ship to standalone users). Those files are exempt from the byte
# comparison here; their drift is governed by the crossing checklist
# (see ScanStudioCloseout/MULTIBATCH-CROSSING-20260807.md) instead.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VENDORED_DIRS="coolscanpy/src/coolscanpy"
KNOWN_VENDORED_DIVERGENCE=(
  "protocol/ls5000_single_pass/worker.py"
  "protocol/ls5000_single_pass/roll_index.py"
  "protocol/ls5000_single_pass/bundle.py"
)

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "fetching latest published coolscanpy from PyPI..."
meta="$workdir/meta.json"
curl --fail --silent --show-error --location \
  https://pypi.org/pypi/coolscanpy/json > "$meta"

pypi_version="$(python3 -c "import json;print(json.load(open('$meta'))['info']['version'])")"
sdist_url="$(python3 - "$meta" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for f in data["urls"]:
    if f["packagetype"] == "sdist":
        print(f["url"]); break
else:
    raise SystemExit("no sdist on the latest PyPI release")
PY
)"

curl --fail --silent --show-error --location "$sdist_url" > "$workdir/sdist.tar.gz"
tar -xzf "$workdir/sdist.tar.gz" -C "$workdir"
published_src="$(find "$workdir" -type d -path '*/src/coolscanpy' | head -1)"
if [ -z "$published_src" ]; then
  echo "::error::coolscanpy PyPI sync gate: sdist layout unexpected (no src/coolscanpy)"
  exit 1
fi

fail=0
raw="$(diff -rq --exclude='__pycache__' --exclude='*.pyc' \
  "$published_src" "$VENDORED_DIRS" 2>&1 || true)"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  exempt=0
  for known in "${KNOWN_VENDORED_DIVERGENCE[@]}"; do
    case "$line" in *"$known"*) exempt=1 ;; esac
  done
  if [ "$exempt" = 0 ]; then
    echo "::error::driver differs from the published PyPI package: $line"
    fail=1
  fi
done <<EOF
$raw
EOF

vendored_version="$(python3 -c "
import tomllib
print(tomllib.load(open('coolscanpy/pyproject.toml','rb'))['project']['version'])")"
if [ "$vendored_version" != "$pypi_version" ]; then
  echo "::error::coolscanpy version mismatch: vendored $vendored_version vs PyPI $pypi_version"
  fail=1
fi

if [ "$fail" = 1 ]; then
  echo
  echo "coolscanpy PyPI sync gate FAILED: this release carries driver code"
  echo "that standalone PyPI users would not have. Publish the matching"
  echo "coolscanpy release from the canonical repo (rohanpandula/coolscanpy,"
  echo "port/cross-platform) FIRST -- same round, same generation, no delta"
  echo "-- then re-run this release. Deliberately ScanStudio-only files are"
  echo "exempt and listed in this script."
  exit 1
fi

echo "OK: vendored driver matches PyPI coolscanpy $pypi_version (exempt files aside)"
