#!/usr/bin/env bash
# Validate one explicit OpenSSL 3 executable with the exact Ed25519 operation
# used for optional runtime manifests. Never resolve `openssl` from PATH here.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: require-openssl3.sh </absolute/path/to/openssl>\n' >&2
    exit 64
fi

openssl_bin="$1"
if [[ "$openssl_bin" != /* || ! -f "$openssl_bin" || ! -x "$openssl_bin" ]]; then
    printf 'OPENSSL_BIN must be an absolute executable file: %s\n' "$openssl_bin" >&2
    exit 66
fi
version="$($openssl_bin version 2>/dev/null || true)"
if [[ "$version" != 'OpenSSL 3.'* ]]; then
    printf 'OpenSSL 3 is required; found %s.\n' "${version:-nothing}" >&2
    exit 66
fi

workdir="$(mktemp -d)"
cleanup() {
    rm -rf -- "$workdir"
}
trap cleanup EXIT
private_key="$workdir/private.pem"
public_key="$workdir/public.pem"
message="$workdir/message"
signature="$workdir/message.sig"
printf 'ScanStudio Ed25519 OpenSSL 3 capability probe\n' > "$message"
"$openssl_bin" genpkey -algorithm Ed25519 -out "$private_key" >/dev/null 2>&1
"$openssl_bin" pkey -in "$private_key" -pubout -out "$public_key" >/dev/null 2>&1
"$openssl_bin" pkeyutl -sign -rawin \
    -inkey "$private_key" -in "$message" -out "$signature"
if [[ "$(wc -c < "$signature" | tr -d ' ')" != 64 ]]; then
    printf 'OpenSSL 3 capability probe did not emit a raw 64-byte Ed25519 signature.\n' >&2
    exit 1
fi
"$openssl_bin" pkeyutl -verify -rawin -pubin \
    -inkey "$public_key" -in "$message" -sigfile "$signature" >/dev/null
printf 'Validated %s\n' "$version"
