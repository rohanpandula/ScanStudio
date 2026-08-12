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

"$packaging_dir/prepare-pinned-openssl.sh" --validate-lock
good_bottle="$workdir/good-openssl-bottle.tar.gz"
bad_bottle="$workdir/bad-openssl-bottle.tar.gz"
python3 -I -S - "$good_bottle" "$bad_bottle" <<'PY'
import io
from pathlib import Path
import sys
import tarfile

good, bad = map(Path, sys.argv[1:])
with tarfile.open(good, "w:gz") as archive:
    root = tarfile.TarInfo("openssl@3/3.6.3")
    root.type = tarfile.DIRTYPE
    root.mode = 0o755
    archive.addfile(root)
    payload = b"reviewed executable bytes"
    binary = tarfile.TarInfo("openssl@3/3.6.3/bin/openssl")
    binary.size = len(payload)
    binary.mode = 0o755
    archive.addfile(binary, io.BytesIO(payload))
with tarfile.open(bad, "w:gz") as archive:
    payload = b"escape"
    member = tarfile.TarInfo("openssl@3/3.6.3/../../outside")
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
"$packaging_dir/prepare-pinned-openssl.sh" \
    --validate-archive "$good_bottle" 3.6.3
if "$packaging_dir/prepare-pinned-openssl.sh" \
    --validate-archive "$bad_bottle" 3.6.3 >/dev/null 2>&1; then
    printf 'OpenSSL bottle path escape unexpectedly passed validation\n' >&2
    exit 1
fi

python3 -I -S - \
    "$repo_root/.github/workflows/release.yml" \
    "$packaging_dir/package-runtime.sh" \
    "$packaging_dir/sign-runtime.sh" \
    "$packaging_dir/prepare-pinned-openssl.sh" <<'PY'
from pathlib import Path
import re
import sys

workflow = Path(sys.argv[1]).read_text()
assembler_script = Path(sys.argv[2]).read_text()
signer_script = Path(sys.argv[3]).read_text()
pinned_openssl_script = Path(sys.argv[4]).read_text()

assemble_start = workflow.index("  web-runtime-assemble:\n")
release_start = workflow.index("  release:\n")
signer_start = workflow.index("  web-runtime:\n", assemble_start)
signer_end = workflow.index("  windows-resources:\n", signer_start)
publish_start = workflow.index("  publish:\n", signer_end)
release_job = workflow[release_start:assemble_start]
assemble_job = workflow[assemble_start:signer_start]
signer_job = workflow[signer_start:signer_end]
publish_job = workflow[publish_start:]

external_uses = re.findall(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)", workflow, re.MULTILINE)
assert external_uses
for action in external_uses:
    if not action.startswith(("./", "docker://")):
        assert re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", action), action

assert "${{ secrets." not in assemble_job
assert "npm ci && npm run build:web" in assemble_job
assert "uv sync --locked" in assemble_job
assert "needs: web-runtime-assemble" in signer_job
assert "npm ci" not in signer_job
assert "uv sync" not in signer_job
assert "brew install openssl@3" not in release_job
assert "brew install" not in signer_job
assert "brew install" not in publish_job
assert "prepare-pinned-openssl.sh" in release_job
assert "prepare-pinned-openssl.sh" in signer_job
assert "prepare-pinned-openssl.sh" in publish_job
assert 'jq --exit-status --arg tag "$GITHUB_REF_NAME"' in publish_job
assert '--jq "first(' not in publish_job
for job in (signer_job, publish_job):
    for line in job.splitlines():
        if line.lstrip().startswith("python3 "):
            assert line.lstrip().startswith("python3 -I -S "), line
assert "WEB_RUNTIME_KEYCHAIN_PASSWORD" not in workflow
assert signer_job.index("--prepare-assembly") < signer_job.index("${{ secrets.")
assert signer_job.index("trap finish EXIT") < signer_job.index("sign-runtime.sh")
assert signer_job.index("Sign, notarize, manifest-sign, verify, and remove credentials") < signer_job.index("Upload ${{ matrix.arch }} web runtime assets")
assert "needs: [release, windows, linux, web-runtime]" in workflow

assert "bundled_python/bin/python3.13" in assembler_script
for forbidden in ("bundled_python", ".venv", "npm ci", "uv sync", "import fastapi"):
    assert forbidden not in signer_script, forbidden

assert pinned_openssl_script.index("actual_archive_sha=") < pinned_openssl_script.index("tar -xzf")
assert pinned_openssl_script.index("Pinned OpenSSL file digest mismatch") < pinned_openssl_script.index("printf '%s\\n' \"$openssl_bin\"")

for path in (
    "sign-runtime.sh", "inspect-runtime-dmg.sh", "emit-integrity.sh",
    "verify-integrity.sh", "verify-runtime-release.sh", "payload-tree-hash.sh",
):
    source = (Path(sys.argv[3]).parent / path).read_text()
    for line in source.splitlines():
        if line.lstrip().startswith("python3 "):
            assert line.lstrip().startswith("python3 -I -S "), (path, line)
PY

printf 'web runtime secret-boundary and receipt checks passed\n'
