#!/usr/bin/env bash
# Fetch one reviewed Homebrew OpenSSL 3 bottle without running Homebrew. The
# compressed artifact and every executable Mach-O used by the signer are
# checked against repository-owned digests before the binary can execute.
set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lock="$script_dir/openssl3-release-lock.json"
python_bin="/usr/bin/python3"

validate_lock() {
    "$python_bin" -I -S - "$lock" "${1:-}" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
selected = sys.argv[2]
value = json.loads(path.read_text(encoding="utf-8"))
top_keys = {
    "assets", "formulaSha256", "license", "provider", "schemaVersion",
    "sourceSha256", "sourceURL", "version",
}
if set(value) != top_keys or value["schemaVersion"] != 1:
    raise SystemExit("invalid OpenSSL release lock schema")
if value["provider"] != "homebrew/core" or value["license"] != "Apache-2.0":
    raise SystemExit("invalid OpenSSL release provenance")
if value["version"] != "3.6.3":
    raise SystemExit("unexpected OpenSSL release version")
if value["sourceURL"] != (
    "https://github.com/openssl/openssl/releases/download/openssl-3.6.3/"
    "openssl-3.6.3.tar.gz"
):
    raise SystemExit("unexpected OpenSSL source URL")
sha = re.compile(r"[0-9a-f]{64}")
for name in ("formulaSha256", "sourceSha256"):
    if not sha.fullmatch(value[name]):
        raise SystemExit(f"invalid {name}")
assets = value["assets"]
if set(assets) != {"arm64", "x86_64"}:
    raise SystemExit("OpenSSL release lock must cover both Mac architectures")
asset_keys = {
    "archiveBytes", "archiveSha256", "binarySha256", "bottleTag", "cellar",
    "libcryptoSha256", "libsslSha256", "url",
}
expected = {
    "arm64": ("arm64_sequoia", "/opt/homebrew/Cellar"),
    "x86_64": ("sequoia", "/usr/local/Cellar"),
}
for arch, asset in assets.items():
    if set(asset) != asset_keys:
        raise SystemExit(f"invalid OpenSSL asset schema for {arch}")
    if (asset["bottleTag"], asset["cellar"]) != expected[arch]:
        raise SystemExit(f"unexpected OpenSSL bottle target for {arch}")
    if (
        not isinstance(asset["archiveBytes"], int)
        or isinstance(asset["archiveBytes"], bool)
        or not 0 < asset["archiveBytes"] <= 64 * 1024 * 1024
    ):
        raise SystemExit(f"invalid OpenSSL bottle byte count for {arch}")
    for name in (
        "archiveSha256", "binarySha256", "libcryptoSha256", "libsslSha256"
    ):
        if not sha.fullmatch(asset[name]):
            raise SystemExit(f"invalid {name} for {arch}")
    expected_url = (
        "https://ghcr.io/v2/homebrew/core/openssl/3/blobs/sha256:"
        + asset["archiveSha256"]
    )
    if asset["url"] != expected_url:
        raise SystemExit(f"OpenSSL bottle URL is not content-addressed for {arch}")

if selected:
    if selected not in assets:
        raise SystemExit("architecture must be arm64 or x86_64")
    asset = assets[selected]
    fields = (
        value["version"], asset["url"], asset["archiveSha256"],
        str(asset["archiveBytes"]), asset["cellar"], asset["binarySha256"],
        asset["libsslSha256"],
        asset["libcryptoSha256"], value["formulaSha256"],
    )
    if any("\t" in field or "\n" in field for field in fields):
        raise SystemExit("unsafe OpenSSL lock value")
    print("\t".join(fields))
PY
}

validate_archive() {
    "$python_bin" -I -S - "$1" "$2" <<'PY'
import posixpath
import sys
import tarfile

archive, version = sys.argv[1:]
root = f"openssl@3/{version}"
prefix = root + "/"
with tarfile.open(archive, "r:gz") as value:
    members = value.getmembers()
    if not members or len(members) > 20_000:
        raise SystemExit("invalid OpenSSL bottle inventory")
    for member in members:
        name = member.name
        if (name != root and not name.startswith(prefix)) or name.startswith("/"):
            raise SystemExit("OpenSSL bottle path escaped the expected prefix")
        if any(part in {"", ".", ".."} for part in name.split("/")):
            raise SystemExit("OpenSSL bottle contains a non-canonical path")
        if not (member.isfile() or member.isdir() or member.issym()):
            raise SystemExit("OpenSSL bottle contains a forbidden object type")
        if member.issym():
            if member.linkname.startswith("/"):
                raise SystemExit("OpenSSL bottle contains an absolute symlink")
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(name), member.linkname)
            )
            if resolved != root and not resolved.startswith(prefix):
                raise SystemExit("OpenSSL bottle symlink escaped its payload")
PY
}

if [[ $# -eq 1 && "$1" == "--validate-lock" ]]; then
    validate_lock
    printf 'Pinned OpenSSL release lock validated\n'
    exit 0
fi
if [[ $# -eq 3 && "$1" == "--validate-archive" ]]; then
    validate_archive "$2" "$3"
    printf 'Pinned OpenSSL bottle inventory validated\n'
    exit 0
fi
if [[ $# -ne 1 || ( "$1" != "arm64" && "$1" != "x86_64" ) ]]; then
    printf 'Usage: prepare-pinned-openssl.sh <arm64|x86_64>\n' >&2
    exit 64
fi
arch="$1"
if [[ "$(uname -m)" != "$arch" ]]; then
    printf 'OpenSSL bottle architecture %s does not match runner %s.\n' \
        "$arch" "$(uname -m)" >&2
    exit 66
fi

record="$(validate_lock "$arch")"
IFS=$'\t' read -r version url archive_sha archive_bytes cellar binary_sha libssl_sha \
    libcrypto_sha formula_sha <<< "$record"
for value in "$version" "$url" "$archive_sha" "$archive_bytes" "$cellar" "$binary_sha" \
    "$libssl_sha" "$libcrypto_sha" "$formula_sha"; do
    if [[ -z "$value" ]]; then
        printf 'The OpenSSL release lock emitted an incomplete record.\n' >&2
        exit 66
    fi
done

if [[ ! -d "$cellar" || -L "$cellar" || ! -O "$cellar" ]]; then
    printf 'Refusing an unowned or redirected Homebrew Cellar: %s\n' "$cellar" >&2
    exit 66
fi
formula_root="$cellar/openssl@3"
target="$formula_root/$version"
if [[ -e "$target" || -L "$target" ]]; then
    printf 'Refusing to reuse or overwrite an existing OpenSSL tree: %s\n' "$target" >&2
    exit 73
fi
if [[ -e "$formula_root" || -L "$formula_root" ]]; then
    if [[ ! -d "$formula_root" || -L "$formula_root" || ! -O "$formula_root" ]]; then
        printf 'Refusing an unowned or redirected OpenSSL formula root.\n' >&2
        exit 73
    fi
else
    mkdir -m 755 "$formula_root"
fi

runner_temp="${RUNNER_TEMP:?RUNNER_TEMP is required}"
workdir="$runner_temp/scanstudio-pinned-openssl-$arch"
if [[ -e "$workdir" || -L "$workdir" ]]; then
    printf 'Refusing to reuse an existing OpenSSL preparation directory.\n' >&2
    exit 73
fi
mkdir -m 700 "$workdir"
token_json="$workdir/ghcr-token.json"
archive="$workdir/openssl-$version-$arch.tar.gz"

/usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    'https://ghcr.io/token?scope=repository%3Ahomebrew%2Fcore%2Fopenssl%2F3%3Apull&service=ghcr.io' \
    --output "$token_json"
ghcr_token="$("$python_bin" -I -S - "$token_json" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if set(value) != {"token"} or not isinstance(value["token"], str):
    raise SystemExit("invalid GHCR token response")
token = value["token"]
if not 100 <= len(token) <= 8192 or any(ord(char) < 0x21 or ord(char) > 0x7e for char in token):
    raise SystemExit("invalid GHCR token")
print(token)
PY
)"

/usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 --max-filesize 67108864 \
    --header "Authorization: Bearer $ghcr_token" \
    "$url" --output "$archive"
unset ghcr_token
if [[ "$(/usr/bin/stat -f '%z' "$archive")" != "$archive_bytes" ]]; then
    printf 'Pinned OpenSSL bottle byte count mismatch.\n' >&2
    exit 65
fi
actual_archive_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
if [[ "$actual_archive_sha" != "$archive_sha" ]]; then
    printf 'Pinned OpenSSL bottle digest mismatch.\n' >&2
    exit 65
fi

# Only after the compressed artifact matches the reviewed digest may a parser
# inspect it. Reject path escapes and non-file archive object types.
validate_archive "$archive" "$version"
/usr/bin/tar -xzf "$archive" -C "$cellar"

openssl_bin="$target/bin/openssl"
libssl="$target/lib/libssl.3.dylib"
libcrypto="$target/lib/libcrypto.3.dylib"
formula="$target/.brew/openssl@3.rb"
while IFS=$'\t' read -r path expected; do
    if [[ ! -f "$path" || -L "$path" || ! -O "$path" ]]; then
        printf 'Pinned OpenSSL file is missing, redirected, or unowned: %s\n' "$path" >&2
        exit 66
    fi
    actual="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Pinned OpenSSL file digest mismatch: %s\n' "$path" >&2
        exit 65
    fi
done <<EOF
$openssl_bin	$binary_sha
$libssl	$libssl_sha
$libcrypto	$libcrypto_sha
$formula	$formula_sha
EOF

if ! /usr/bin/file "$openssl_bin" | /usr/bin/grep -F \
    "Mach-O 64-bit executable $arch" >/dev/null; then
    printf 'Pinned OpenSSL executable has the wrong architecture.\n' >&2
    exit 66
fi
printf '%s\n' "$openssl_bin"
