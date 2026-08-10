#!/usr/bin/env bash
# Download and extract the exact Python build whose metadata/license corpus is
# embedded in the separately released ScanStudio Web Runtime.
set -euo pipefail

usage() {
    printf 'Usage: prepare-pinned-python.sh <arm64|x86_64> <destination>\n' >&2
}

if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

arch="$1"
destination="$2"
if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
    printf 'Bad architecture: %s\n' "$arch" >&2
    exit 64
fi
if [[ -e "$destination" || -L "$destination" ]]; then
    printf 'Refusing to overwrite a pinned Python destination: %s\n' "$destination" >&2
    exit 73
fi

for command in curl python3 shasum tar zstd; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Pinned Python preparation tool is unavailable: %s\n' "$command" >&2
        exit 127
    fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pin="$script_dir/python-build-standalone-lock.json"
evidence_tool="$script_dir/python-build-standalone-evidence.py"
python3 "$evidence_tool" validate-pin --pin "$pin"

asset_record="$(python3 - "$pin" "$arch" <<'PY'
import json
from pathlib import Path
import sys

pin = json.loads(Path(sys.argv[1]).read_text())
asset = pin["assets"][sys.argv[2]]
print("\t".join((pin["release"], asset["name"], asset["sha256"], str(asset["bytes"]))))
PY
)"
IFS=$'\t' read -r release asset_name expected_sha expected_bytes <<< "$asset_record"
encoded_asset="$(python3 - "$asset_name" <<'PY'
from urllib.parse import quote
import sys

print(quote(sys.argv[1], safe="-._~"))
PY
)"
url="https://github.com/astral-sh/python-build-standalone/releases/download/$release/$encoded_asset"

destination_parent="$(dirname "$destination")"
mkdir -p "$destination_parent"
destination_parent="$(cd "$destination_parent" && pwd)"
destination="$destination_parent/$(basename "$destination")"
staging_root="$(mktemp -d "$destination_parent/.scanstudio-pbs.XXXXXX")"
archive="$staging_root/$asset_name"
cleanup() {
    rm -rf -- "$staging_root"
}
trap cleanup EXIT

curl --fail --location --proto '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 300 --retry 3 \
    --output "$archive" "$url"
actual_bytes="$(wc -c < "$archive" | tr -d ' ')"
actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_bytes" != "$expected_bytes" || "$actual_sha" != "$expected_sha" ]]; then
    printf 'Pinned Python archive identity mismatch.\n' >&2
    exit 1
fi

mkdir "$staging_root/extracted"
zstd -dc -- "$archive" \
    | tar -xf - -C "$staging_root/extracted" \
        python/PYTHON.json python/licenses python/install
distribution_root="$staging_root/extracted/python"
mkdir "$distribution_root/supplemental-licenses"
while IFS=$'\t' read -r supplemental_url supplemental_name supplemental_sha supplemental_bytes; do
    supplemental_path="$distribution_root/supplemental-licenses/$supplemental_name"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --connect-timeout 20 --max-time 120 --retry 3 \
        --output "$supplemental_path" "$supplemental_url"
    actual_supplemental_bytes="$(wc -c < "$supplemental_path" | tr -d ' ')"
    actual_supplemental_sha="$(shasum -a 256 "$supplemental_path" | awk '{print $1}')"
    if [[ "$actual_supplemental_bytes" != "$supplemental_bytes" \
          || "$actual_supplemental_sha" != "$supplemental_sha" ]]; then
        printf 'Supplemental CPython license identity mismatch: %s\n' "$supplemental_name" >&2
        exit 1
    fi
done < <(python3 - "$pin" <<'PY'
import json
from pathlib import Path
import sys

pin = json.loads(Path(sys.argv[1]).read_text())
for entry in pin["supplementalLicenseFiles"]:
    print("\t".join((entry["url"], entry["path"], entry["sha256"], str(entry["bytes"]))))
PY
)
python3 "$evidence_tool" validate-distribution \
    --pin "$pin" \
    --architecture "$arch" \
    --distribution-root "$distribution_root" \
    --run-interpreter

python3 - "$distribution_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve(strict=True)
for candidate in root.rglob("*"):
    if not candidate.is_symlink():
        continue
    try:
        candidate.resolve(strict=True).relative_to(root)
    except (FileNotFoundError, ValueError) as error:
        raise SystemExit(f"pinned Python symlink escapes or dangles: {candidate}") from error
PY

mv "$distribution_root" "$destination"
printf 'Prepared pinned Python distribution at %s\n' "$destination"
