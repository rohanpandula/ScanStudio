#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
packaging_dir="$(cd "$script_dir/.." && pwd)"
tool="$packaging_dir/python-build-standalone-evidence.py"
production_pin="$packaging_dir/python-build-standalone-lock.json"
workdir="$(mktemp -d)"
trap 'rm -rf -- "$workdir"' EXIT

python3 "$tool" validate-pin --pin "$production_pin"

distribution="$workdir/distribution"
runtime="$workdir/runtime"
mkdir -p \
    "$distribution/licenses" \
    "$distribution/supplemental-licenses" \
    "$distribution/install/bin" \
    "$runtime/lib/python3.13/lib-dynload"
printf 'CPython license\n' > "$distribution/licenses/LICENSE.cpython.txt"
printf 'OpenSSL license\n' > "$distribution/licenses/LICENSE.openssl.txt"
printf 'Tcl license\n' > "$distribution/licenses/LICENSE.tcl.txt"
printf 'zlib license\n' > "$distribution/licenses/LICENSE.zlib.txt"
printf 'mimalloc incorporated-code license\n' \
    > "$distribution/supplemental-licenses/CPython-3.13.14-Doc-license.rst"
cat > "$distribution/PYTHON.json" <<'JSON'
{"build_info":{"extensions":{"_ssl":[{"in_core":false,"license_paths":["licenses/LICENSE.openssl.txt"],"license_public_domain":false,"licenses":["Apache-2.0"],"links":[{"name":"ssl","path_static":"build/lib/libssl.a"}]}],"_tkinter":[{"in_core":false,"license_paths":["licenses/LICENSE.tcl.txt"],"license_public_domain":false,"licenses":["TCL"],"links":[{"name":"tcl","system":true}],"shared_lib":"install/lib/python3.13/lib-dynload/_tkinter.so"}],"zlib":[{"in_core":false,"license_paths":["licenses/LICENSE.zlib-ng.txt","licenses/LICENSE.zlib.txt"],"license_public_domain":false,"licenses":["Zlib"],"links":[{"name":"z","system":true}]}]}},"build_options":"pgo+lto","license_path":"licenses/LICENSE.cpython.txt","licenses":["Python-2.0"],"python_exe":"install/bin/python3.13","python_major_minor_version":"3.13","python_version":"3.13.14","target_triple":"aarch64-apple-darwin","version":"8"}
JSON

python3 - "$distribution" "$workdir/pin.json" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

distribution = Path(sys.argv[1])
output = Path(sys.argv[2])


def record(path):
    raw = path.read_bytes()
    return {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


metadata = record(distribution / "PYTHON.json")
supplemental = record(
    distribution / "supplemental-licenses" / "CPython-3.13.14-Doc-license.rst"
)
licenses = []
components = {
    "LICENSE.cpython.txt": "CPython",
    "LICENSE.openssl.txt": "OpenSSL",
    "LICENSE.tcl.txt": "Tcl/Tk",
    "LICENSE.zlib.txt": "zlib",
}
for name, component in sorted(components.items()):
    item = record(distribution / "licenses" / name)
    item.update({"component": component, "path": name})
    licenses.append(item)
pin = {
    "allowedMissingMetadataLicensePaths": ["licenses/LICENSE.zlib-ng.txt"],
    "assets": {
        "arm64": {
            "bytes": 1,
            "metadataSha256": metadata["sha256"],
            "name": "cpython-3.13.14+20260728-aarch64-apple-darwin-pgo+lto-full.tar.zst",
            "sha256": "a" * 64,
            "targetTriple": "aarch64-apple-darwin",
        },
        "x86_64": {
            "bytes": 1,
            "metadataSha256": "b" * 64,
            "name": "cpython-3.13.14+20260728-x86_64-apple-darwin-pgo+lto-full.tar.zst",
            "sha256": "c" * 64,
            "targetTriple": "x86_64-apple-darwin",
        },
    },
    "buildOptions": "pgo+lto",
    "licenseFiles": licenses,
    "metadataVersion": "8",
    "provider": "astral-sh/python-build-standalone",
    "pythonExecutableRelativePath": "install/bin/python3.13",
    "pythonVersion": "3.13.14",
    "release": "20260728",
    "requiredRuntimeComponents": ["CPython", "OpenSSL", "mimalloc", "zlib"],
    "schemaVersion": 1,
    "supplementalLicenseFiles": [
        {
            **supplemental,
            "componentLicenseExpressions": {"mimalloc": "MIT"},
            "components": ["mimalloc"],
            "path": "CPython-3.13.14-Doc-license.rst",
            "url": "https://raw.githubusercontent.com/python/cpython/v3.13.14/Doc/license.rst",
        }
    ],
}
output.write_text(json.dumps(pin, sort_keys=True, separators=(",", ":")) + "\n")
PY

evidence="$workdir/evidence"
python3 "$tool" collect \
    --pin "$workdir/pin.json" \
    --architecture arm64 \
    --distribution-root "$distribution" \
    --runtime-root "$runtime" \
    --output "$evidence"
python3 "$tool" verify-bundle \
    --pin "$workdir/pin.json" \
    --architecture arm64 \
    --runtime-root "$runtime" \
    --evidence-root "$evidence"

python3 - "$evidence/inventory.json" <<'PY'
import json
from pathlib import Path
import sys

inventory = json.loads(Path(sys.argv[1]).read_text())
mimalloc = next(
    component for component in inventory["components"]
    if component["name"] == "mimalloc"
)
if mimalloc["licenseExpressions"] != ["MIT"]:
    raise SystemExit("supplemental component license expression was not inventoried")
PY

cp -R "$evidence" "$workdir/missing-output"
rm "$workdir/missing-output/licenses/LICENSE.openssl.txt"
if python3 "$tool" verify-bundle \
    --pin "$workdir/pin.json" \
    --architecture arm64 \
    --runtime-root "$runtime" \
    --evidence-root "$workdir/missing-output" >/dev/null 2>&1; then
    printf 'evidence verifier accepted an omitted embedded OpenSSL license\n' >&2
    exit 1
fi

cp -R "$distribution" "$workdir/missing-source"
rm "$workdir/missing-source/licenses/LICENSE.zlib.txt"
if python3 "$tool" collect \
    --pin "$workdir/pin.json" \
    --architecture arm64 \
    --distribution-root "$workdir/missing-source" \
    --runtime-root "$runtime" \
    --output "$workdir/missing-source-output" >/dev/null 2>&1; then
    printf 'evidence collector accepted an omitted distribution zlib license\n' >&2
    exit 1
fi

cp -R "$evidence" "$workdir/stale-inventory"
python3 - "$workdir/stale-inventory/inventory.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text())
value["components"] = [item for item in value["components"] if item["name"] != "OpenSSL"]
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
if python3 "$tool" verify-bundle \
    --pin "$workdir/pin.json" \
    --architecture arm64 \
    --runtime-root "$runtime" \
    --evidence-root "$workdir/stale-inventory" >/dev/null 2>&1; then
    printf 'evidence verifier accepted a component omitted from the inventory\n' >&2
    exit 1
fi

cp "$workdir/pin.json" "$workdir/wrong-version-pin.json"
python3 - "$workdir/wrong-version-pin.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text())
value["pythonVersion"] = "3.13.15"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
if python3 "$tool" validate-pin --pin "$workdir/wrong-version-pin.json" >/dev/null 2>&1; then
    printf 'pin validator accepted a drifting interpreter version\n' >&2
    exit 1
fi

cp "$workdir/pin.json" "$workdir/missing-supplemental-expression-pin.json"
python3 - "$workdir/missing-supplemental-expression-pin.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = json.loads(path.read_text())
del value["supplementalLicenseFiles"][0]["componentLicenseExpressions"]["mimalloc"]
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
if python3 "$tool" validate-pin \
    --pin "$workdir/missing-supplemental-expression-pin.json" >/dev/null 2>&1; then
    printf 'pin validator accepted a supplemental component without an exact license expression\n' >&2
    exit 1
fi

printf 'python-build-standalone dependency/license evidence checks passed\n'
