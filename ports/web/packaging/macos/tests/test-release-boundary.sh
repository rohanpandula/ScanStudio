#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
packaging_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$packaging_dir/../../../.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT

version='1.2.3-beta.4'
arch='arm64'
stem="ScanStudio-WebRuntime-$version-macOS-$arch"
dmg="$workdir/$stem.unsigned.dmg"
tree="$workdir/tree.json"
receipt="$workdir/$stem.assembly.json"
printf 'unsigned runtime bytes\n' > "$dmg"
printf '%s\n' \
    '{"fileCount":2,"installedSize":24,"treeSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
    > "$tree"
python3 -I -S "$packaging_dir/runtime-assembly-receipt.py" emit \
    "$dmg" "$version" "$arch" "$tree" "$receipt"
python3 -I -S "$packaging_dir/runtime-assembly-receipt.py" verify \
    "$dmg" "$version" "$arch" "$tree" "$receipt"
printf 'tamper\n' >> "$dmg"
if python3 -I -S "$packaging_dir/runtime-assembly-receipt.py" verify \
    "$dmg" "$version" "$arch" "$tree" "$receipt" >/dev/null 2>&1; then
    printf 'tampered unsigned runtime unexpectedly matched its receipt\n' >&2
    exit 1
fi

scan_root="$workdir/private-path-scan"
mkdir "$scan_root"
printf 'portable payload\n' > "$scan_root/clean.txt"
"$packaging_dir/assert-no-private-paths.sh" "$scan_root"
printf '%s%s\n' '/Us' 'ers/release-builder/secret' > "$scan_root/private.txt"
if "$packaging_dir/assert-no-private-paths.sh" "$scan_root" >/dev/null 2>&1; then
    printf 'private build path unexpectedly passed scanning\n' >&2
    exit 1
fi
chmod 000 "$scan_root/private.txt"
if "$packaging_dir/assert-no-private-paths.sh" "$scan_root" >/dev/null 2>&1; then
    printf 'unreadable private-path input unexpectedly passed scanning\n' >&2
    exit 1
fi
chmod 600 "$scan_root/private.txt"

python3 -I -S - \
    "$repo_root/.github/workflows/release.yml" \
    "$packaging_dir/package-runtime.sh" \
    "$packaging_dir/sign-runtime.sh" <<'PY'
from pathlib import Path
import sys

workflow = Path(sys.argv[1]).read_text()
assembler_script = Path(sys.argv[2]).read_text()
signer_script = Path(sys.argv[3]).read_text()

assemble_start = workflow.index("  web-runtime-assemble:\n")
signer_start = workflow.index("  web-runtime:\n", assemble_start)
signer_end = workflow.index("  windows-resources:\n", signer_start)
assemble_job = workflow[assemble_start:signer_start]
signer_job = workflow[signer_start:signer_end]

assert "${{ secrets." not in assemble_job
assert "npm ci && npm run build:web" in assemble_job
assert "uv sync --locked" in assemble_job
assert "needs: web-runtime-assemble" in signer_job
assert "npm ci" not in signer_job
assert "uv sync" not in signer_job
assert "WEB_RUNTIME_KEYCHAIN_PASSWORD" not in workflow
assert signer_job.index("--prepare-assembly") < signer_job.index("${{ secrets.")
assert signer_job.index("trap finish EXIT") < signer_job.index("sign-runtime.sh")
assert signer_job.index("Sign, notarize, manifest-sign, verify, and remove credentials") < signer_job.index("Upload ${{ matrix.arch }} web runtime assets")
assert "needs: [release, windows, linux, web-runtime]" in workflow

assert "bundled_python/bin/python3.13" in assembler_script
for forbidden in ("bundled_python", ".venv", "npm ci", "uv sync", "import fastapi"):
    assert forbidden not in signer_script, forbidden
PY

printf 'web runtime secret-boundary and receipt checks passed\n'
