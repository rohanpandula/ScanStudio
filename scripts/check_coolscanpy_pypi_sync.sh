#!/usr/bin/env bash
# Release gate: the driver inside this release must already be published on
# PyPI, so a standalone `pip install coolscanpy` user and a ScanStudio app
# user always run the same driver generation. A version delta between the
# two produces incomparable field reports for the same film -- the exact
# debugging confusion the instrumented-refusal work exists to prevent
# (owner policy, 2026-08-08: "keep them in sync so there's no delta").
#
# Mechanics: download the exact authenticated coolscanpy 0.7.11 sdist and compare its
# src/coolscanpy tree byte-for-byte against this repo's vendored
# coolscanpy/src/coolscanpy. Version strings are NOT trusted as the primary
# signal (an unbumped version with changed code is precisely the failure
# mode this gate exists to catch); the pyproject version is checked second,
# as bump discipline.
#
# The vendored tree deliberately diverges from the published package in a
# small, documented set of files (ScanStudio-specific behavior that must
# not ship to standalone users). Each exemption is pinned to the sha256 of
# BOTH sides, so an exempt file cannot quietly drift on either side: any
# change to it fails this gate until the divergence is re-reviewed and the
# pin updated (crossing checklist:
# ScanStudioCloseout/MULTIBATCH-CROSSING-20260807.md).
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VENDORED_DIR="coolscanpy/src/coolscanpy"
# relpath|vendored-sha256|published-sha256 -- one entry per deliberate
# divergence, with WHY it diverges. Paths are exact, relative to the
# src/coolscanpy root; anything not listed must match byte-for-byte.
# Re-pin: shasum -a 256 <both files>, update the entry in the same change
# that alters the file.
KNOWN_VENDORED_DIVERGENCE=(
  # required scanner_identity + capture-timing feature; re-pinned for 0.7.11
  # (held metering and exact-slot refusal continuation landed upstream)
  "protocol/ls5000_single_pass/worker.py|e8bd899f166042ca7d6cc2678df7f585a47d2e7ac38d131f3c65f9ffdeec502c|d638aaff349895352a086343581b86cfc1bff3d266d23ef9e8104c8b41876bd5"
  # LeadingFrameClippedError + confident-clear-film gate; re-pinned for 0.7.11
  # (held metering and exact-slot refusal continuation landed upstream)
  "protocol/ls5000_single_pass/roll_index.py|c99c54a434d0d53e94e51ed503f0289709b5f20365e16606f365264a617c8b17|38013a1e942c3d1d1798ca0e718fb7ccdc3bc605277ca729e9891fa53bcde311"
  # its export surface for the class above
  "protocol/ls5000_single_pass/__init__.py|ce8aa97b707f5ef83f96128b378722191f7280bd41c1f3acbb04c75e3ea7523e|1f0f324034a95e2c8ca772ce52a78a800b0bf215d3ae4ec77422b08b1376856c"
  # pins differ because the two files above differ; re-pinned for 0.7.11
  "protocol/ls5000_single_pass/bundle.py|d75c7393d14b7fe824ccdda201edeac7c144dbe30ff5dd4ac8ca3d9bc8864e71|8cd00cfaaf96d2034e9bae03226a484732ef4a2dfc55f6543fe5ddbbd5ef8d1d"
  # packaged-app libusb resolution (app bundles its own signed binary)
  "protocol/ls5000_single_pass/usb_backend.py|afb5b3cbb57404b758f4f8d8795f4307c07c8f6d01bbeccb3ced38026787fd62|666a476ce706a4a854aac50116575e7143f5a1a7c1b1085125347696d89348d1"
  # capture-timing receipt fields (started_at/duration); re-pinned for 0.7.11
  "_roll.py|884c8e3702081d72234e98a483413eb334bb34c8e906fc271548594f95a3ffc4|d9a83c6e2d01815844cbecb302a3bb0092de8c71e8394d69c1801e6011ef39fd"
  "capture/single_pass_workflow.py|acf15f49722e6cdaba733b7f69f1193532b83fd85880d6f31efcdb6a109ed4ef|fe62a5f40fb82e5f4b6a1a2584f33390d0cd90b9c528f7feb9d91d1d0a92765f"
  "types.py|487603c8de4a43d8f28ac6ec358c442b66e6c6a80e554308b301f46d33ce6c7d|812efed1f289e6b086269fa50a2fdf49228570eab8f3f06d0d66db2d3489747d"
)

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "fetching authenticated coolscanpy 0.7.11 source from PyPI..."
published_root="$(python3 -I -S -B scripts/fetch_pinned_coolscanpy_sdist.py \
  --destination "$workdir/published")"
published_src="$published_root/src/coolscanpy"
test -d "$published_src"
pypi_version="0.7.11"

printf '%s\n' "${KNOWN_VENDORED_DIVERGENCE[@]}" > "$workdir/exemptions"
if PUBLISHED_SRC="$published_src" VENDORED_DIR="$VENDORED_DIR" \
  python3 - "$workdir/exemptions" <<'PY'
import hashlib, os, sys

published = os.environ["PUBLISHED_SRC"]
vendored = os.environ["VENDORED_DIR"]
exemptions = {}
with open(sys.argv[1]) as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        rel, v_sha, p_sha = line.split("|")
        exemptions[rel] = (v_sha, p_sha)

def tree(root):
    found = set()
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for name in files:
            if name.endswith(".pyc"):
                continue
            found.add(os.path.relpath(os.path.join(base, name), root))
    return found

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()

fail = False
def error(message):
    global fail
    print(f"::error::{message}")
    fail = True

for rel in sorted(tree(published) | tree(vendored) | set(exemptions)):
    v_path = os.path.join(vendored, rel)
    p_path = os.path.join(published, rel)
    v_exists = os.path.isfile(v_path)
    p_exists = os.path.isfile(p_path)
    if rel in exemptions:
        v_pin, p_pin = exemptions[rel]
        if not v_exists or not p_exists:
            error(f"exempt driver file {rel} is missing on one side "
                  f"(vendored: {v_exists}, published: {p_exists})")
            continue
        v_now, p_now = sha256(v_path), sha256(p_path)
        if v_now != v_pin or p_now != p_pin:
            error(f"exempt driver file {rel} changed since its divergence "
                  f"was last reviewed (vendored {v_now[:12]} vs pinned "
                  f"{v_pin[:12]}, published {p_now[:12]} vs pinned "
                  f"{p_pin[:12]}); re-review the divergence and re-pin it "
                  f"in scripts/check_coolscanpy_pypi_sync.sh")
    elif not v_exists:
        error(f"driver file {rel} is on PyPI but missing from the vendored tree")
    elif not p_exists:
        error(f"driver file {rel} is vendored but missing from the published PyPI package")
    else:
        with open(v_path, "rb") as v_handle, open(p_path, "rb") as p_handle:
            if v_handle.read() != p_handle.read():
                error(f"driver file {rel} differs from the published PyPI package")

sys.exit(1 if fail else 0)
PY
then
  fail=0
else
  fail=1
fi

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
  echo "exempt, sha256-pinned, and listed in this script."
  exit 1
fi

echo "OK: vendored driver matches PyPI coolscanpy $pypi_version (exempt files pinned)"
