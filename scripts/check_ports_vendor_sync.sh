#!/usr/bin/env bash
# Verifies ports/tauri/vendor/{coolscanpy,scanstudio-bridge,engine,protocol}
# against their canonical source trees (coolscanpy/, bridge/,
# app/ScanStudio/engine/, app/ScanStudio/protocol/).
#
# The canonical trees are always the merge base. The vendor copy may add only
# reviewed Linux/Windows/WSL overlays: the engine's WSL handoff and call sites,
# manifest.rs's native-Windows USERPROFILE fallback, bridge portability and
# sealed run-from-source support, CoolScanPy's Linux discovery behavior, and
# mirror-only packaging/validation tooling. These overlays do not make the
# vendor tree an independent implementation.
#
# Each pair has two independent guards:
#   1. an exact `diff -rq` allowlist freezes which relative names may differ;
#   2. a deterministic SHA-256 fingerprint freezes the bytes, entry type,
#      executable bit, and symlink target of every actual divergence.
# Changing content inside an already-allowlisted file therefore still fails.
# Exclusions are shared by both guards.
#
# When a deliberate canonical change is ported, start from the canonical file
# and reapply only the reviewed platform overlay. Then review every reported
# path and byte before updating either an allowlist line or expected digest.
# Never update a digest merely to make this check green.

set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAIL=0

EXCLUDE_PATTERNS=(
  .DS_Store
  __pycache__
  "*.pyc"
  .pytest_cache
  .ruff_cache
  .benchmarks
  "*.egg-info"
  .venv
  target
  build
  .claude
  dist
)
EXCLUDES=()
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDES+=(--exclude="$pattern")
done

VENDOR_SYNC_PYTHON_BIN="${VENDOR_SYNC_PYTHON_BIN:-}"
if [ -z "$VENDOR_SYNC_PYTHON_BIN" ]; then
  if command -v python3 >/dev/null 2>&1; then
    VENDOR_SYNC_PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then
    VENDOR_SYNC_PYTHON_BIN=python
  else
    echo "::error::vendor sync fingerprint requires Python 3"
    exit 1
  fi
fi
if ! "$VENDOR_SYNC_PYTHON_BIN" -I -S -B -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "::error::vendor sync fingerprint requires Python 3.9 or newer"
  exit 1
fi

# Hashes only entries whose two snapshots differ, so an identical canonical
# change applied to both trees does not churn the reviewed-overlay digest.
# File content is represented by its byte length and SHA-256. Repository file
# modes supply a stable executable bit across POSIX and Windows checkouts;
# untracked files fall back to their filesystem mode and will also fail the
# path allowlist. Git symlink placeholders on Windows are hashed as the exact
# link-target bytes recorded in the working tree.
divergence_fingerprint() {
  "$VENDOR_SYNC_PYTHON_BIN" -I -S -B - "$1" "$2" "${EXCLUDE_PATTERNS[@]}" <<'PY'
import fnmatch
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys


primary_root = Path(sys.argv[1])
mirror_root = Path(sys.argv[2])
exclude_patterns = sys.argv[3:]


def repository_modes(*roots: Path) -> dict[str, str]:
    command = ["git", "ls-files", "--stage", "-z", "--"]
    command.extend(root.as_posix() for root in roots)
    try:
        raw = subprocess.run(command, check=True, stdout=subprocess.PIPE).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError(f"read repository executable/symlink modes: {error}") from error
    modes: dict[str, str] = {}
    for record in raw.split(b"\0"):
        if not record:
            continue
        metadata, path = record.split(b"\t", 1)
        mode, _object_id, stage = metadata.split(b" ", 2)
        if stage != b"0":
            raise RuntimeError(
                "vendor sync fingerprint refuses an unmerged index entry at "
                + os.fsdecode(path)
            )
        modes[os.fsdecode(path).replace(os.sep, "/")] = mode.decode("ascii")
    return modes


index_modes = repository_modes(primary_root, mirror_root)


def is_excluded(name: str) -> bool:
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in exclude_patterns)


def encoded(value: str) -> bytes:
    return value.encode("utf-8", "surrogateescape")


def file_digest(path: Path) -> tuple[int, bytes]:
    digest = hashlib.sha256()
    length = 0
    with path.open("rb") as source:
        while True:
            block = source.read(1024 * 1024)
            if not block:
                break
            length += len(block)
            digest.update(block)
    return length, digest.digest()


def snapshot(root: Path) -> dict[str, tuple[object, ...]]:
    try:
        root_state = root.lstat()
    except OSError as error:
        raise RuntimeError(f"inspect fingerprint root {root}: {error}") from error
    if not stat.S_ISDIR(root_state.st_mode) or stat.S_ISLNK(root_state.st_mode):
        raise RuntimeError(f"fingerprint root must be a real directory: {root}")

    result: dict[str, tuple[object, ...]] = {}

    def visit(path: Path, relative: str) -> None:
        try:
            state = path.lstat()
        except OSError as error:
            raise RuntimeError(f"inspect fingerprint entry {path}: {error}") from error
        repository_path = path.as_posix()
        indexed_mode = index_modes.get(repository_path)

        if stat.S_ISLNK(state.st_mode) or indexed_mode == "120000":
            if stat.S_ISLNK(state.st_mode):
                target = encoded(os.readlink(path))
            elif stat.S_ISREG(state.st_mode):
                if state.st_size > 65536:
                    raise RuntimeError(
                        f"indexed symlink placeholder exceeds 65536 bytes: {path}"
                    )
                target = path.read_bytes()
            else:
                raise RuntimeError(f"indexed symlink has unsupported working-tree type: {path}")
            result[relative] = ("symlink", target)
            return
        if stat.S_ISREG(state.st_mode):
            executable = (
                indexed_mode == "100755"
                if indexed_mode in {"100644", "100755"}
                else bool(state.st_mode & 0o111)
            )
            length, content = file_digest(path)
            result[relative] = ("file", executable, length, content)
            return
        if stat.S_ISDIR(state.st_mode):
            if relative:
                result[relative] = ("directory",)
            try:
                children = sorted(path.iterdir(), key=lambda child: encoded(child.name))
            except OSError as error:
                raise RuntimeError(f"read fingerprint directory {path}: {error}") from error
            for child in children:
                if is_excluded(child.name):
                    continue
                child_relative = child.name if not relative else f"{relative}/{child.name}"
                visit(child, child_relative)
            return
        raise RuntimeError(f"unsupported filesystem entry in vendor sources: {path}")

    visit(root, "")
    return result


primary = snapshot(primary_root)
mirror = snapshot(mirror_root)
fingerprint = hashlib.sha256()


def frame(value: bytes) -> None:
    fingerprint.update(len(value).to_bytes(8, "big"))
    fingerprint.update(value)


frame(b"ScanStudio reviewed vendor divergence fingerprint v1")
for relative in sorted(set(primary) | set(mirror), key=encoded):
    primary_entry = primary.get(relative)
    mirror_entry = mirror.get(relative)
    if primary_entry == mirror_entry:
        continue
    frame(encoded(relative))
    for side, entry in ((b"canonical", primary_entry), (b"vendor", mirror_entry)):
        frame(side)
        if entry is None:
            frame(b"missing")
            continue
        kind = entry[0]
        frame(encoded(str(kind)))
        if kind == "file":
            frame(b"1" if entry[1] else b"0")
            frame(str(entry[2]).encode("ascii"))
            frame(entry[3])
        elif kind == "symlink":
            frame(entry[1])

print(fingerprint.hexdigest())
PY
}

if [ "${1:-}" = "--fingerprint-pair" ]; then
  if [ "$#" -ne 3 ]; then
    echo "usage: $0 --fingerprint-pair CANONICAL_DIR VENDOR_DIR" >&2
    exit 2
  fi
  divergence_fingerprint "$2" "$3"
  exit
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--fingerprint-pair CANONICAL_DIR VENDOR_DIR]" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# check_pair LABEL PRIMARY_DIR MIRROR_DIR EXPECTED_DIVERGENCE_SHA256
#
# Reads the pair's allowlist from stdin: one exact `diff -rq` output line per
# accepted difference (literal match, no path parsing). The allowlist must
# equal the current name-level difference set, and the digest must equal the
# byte/type/mode/target fingerprint for that set.
# ---------------------------------------------------------------------------
check_pair() {
  local label="$1" primary="$2" mirror="$3" expected_fingerprint="$4"
  local allowlist raw fingerprint line unexpected=0 stale=0

  allowlist="$(cat)"
  raw="$(diff -rq "${EXCLUDES[@]}" "$primary" "$mirror" 2>&1 || true)"
  if ! fingerprint="$(divergence_fingerprint "$primary" "$mirror")"; then
    echo "::error::$label: could not compute reviewed divergence fingerprint"
    FAIL=1
    return
  fi

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if printf '%s\n' "$allowlist" | grep -qxF -- "$line"; then
      continue
    fi
    echo "::error::$label: unexpected drift beyond the known baseline: $line"
    unexpected=1
  done <<EOF
$raw
EOF

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if ! printf '%s\n' "$raw" | grep -qxF -- "$line"; then
      echo "::error::$label: stale reviewed-difference allowlist entry: $line"
      stale=1
    fi
  done <<EOF
$allowlist
EOF

  if [ "$fingerprint" != "$expected_fingerprint" ]; then
    echo "::error::$label: reviewed divergence fingerprint changed: expected $expected_fingerprint, got $fingerprint"
    echo "::error::$label: review every changed path, byte, entry type, executable bit, and symlink target before updating the expected digest"
    unexpected=1
  fi

  if [ "$unexpected" = 1 ] || [ "$stale" = 1 ]; then
    FAIL=1
  elif [ -z "$raw" ]; then
    echo "OK   $label: byte-identical (fingerprint verified)"
  else
    echo "OK   $label: reviewed platform overlay only (allowlist and fingerprint verified)"
  fi
}

check_pair "protocol" "app/ScanStudio/protocol" "ports/tauri/vendor/protocol" "55577442d8b6a23ddcd3cc191ebf41a8258004047bc075511a241fa72adb0b65" <<'EOF'
EOF

check_pair "engine" "app/ScanStudio/engine" "ports/tauri/vendor/engine" "d2b316b2c05e360b3df063033559f244fb93b9a6181bd55169924571a40d2a93" <<'EOF'
Files app/ScanStudio/engine/Cargo.lock and ports/tauri/vendor/engine/Cargo.lock differ
Files app/ScanStudio/engine/Cargo.toml and ports/tauri/vendor/engine/Cargo.toml differ
Files app/ScanStudio/engine/src/evidence_package.rs and ports/tauri/vendor/engine/src/evidence_package.rs differ
Files app/ScanStudio/engine/src/lib.rs and ports/tauri/vendor/engine/src/lib.rs differ
Files app/ScanStudio/engine/src/manifest.rs and ports/tauri/vendor/engine/src/manifest.rs differ
Files app/ScanStudio/engine/src/real_backend.rs and ports/tauri/vendor/engine/src/real_backend.rs differ
Files app/ScanStudio/engine/src/render.rs and ports/tauri/vendor/engine/src/render.rs differ
Only in ports/tauri/vendor/engine/src: wsl_io.rs
EOF

check_pair "bridge" "bridge" "ports/tauri/vendor/scanstudio-bridge" "cb2105eaf2d62d7dfa49889d755e0ba6cdcb4ea8a2a5d9f480eac0d0a5df1682" <<'EOF'
Only in ports/tauri/vendor/scanstudio-bridge: .github
Only in ports/tauri/vendor/scanstudio-bridge/scripts: probe-linux-env.py
Only in ports/tauri/vendor/scanstudio-bridge/scripts: verify-bridge.sh
Files bridge/src/scanstudio_bridge/cli.py and ports/tauri/vendor/scanstudio-bridge/src/scanstudio_bridge/cli.py differ
Files bridge/src/scanstudio_bridge/safety.py and ports/tauri/vendor/scanstudio-bridge/src/scanstudio_bridge/safety.py differ
Files bridge/src/scanstudio_bridge/service.py and ports/tauri/vendor/scanstudio-bridge/src/scanstudio_bridge/service.py differ
Files bridge/src/scanstudio_bridge/transport/output_reservation.py and ports/tauri/vendor/scanstudio-bridge/src/scanstudio_bridge/transport/output_reservation.py differ
Only in ports/tauri/vendor/scanstudio-bridge/tests: test_probe_linux_env.py
Files bridge/tests/test_safety.py and ports/tauri/vendor/scanstudio-bridge/tests/test_safety.py differ
Only in ports/tauri/vendor/scanstudio-bridge/tests: test_stdout_byte_discipline.py
Files bridge/tests/test_transport_mock.py and ports/tauri/vendor/scanstudio-bridge/tests/test_transport_mock.py differ
Files bridge/uv.lock and ports/tauri/vendor/scanstudio-bridge/uv.lock differ
EOF

check_pair "coolscanpy" "coolscanpy" "ports/tauri/vendor/coolscanpy" "4d2911476eb3e2a1831aa4b588ccb76b580b456914d65eb685b1c20789733629" <<'EOF'
Files coolscanpy/src/coolscanpy/protocol/ls5000_single_pass/bundle.py and ports/tauri/vendor/coolscanpy/src/coolscanpy/protocol/ls5000_single_pass/bundle.py differ
Files coolscanpy/src/coolscanpy/protocol/ls5000_single_pass/usb_backend.py and ports/tauri/vendor/coolscanpy/src/coolscanpy/protocol/ls5000_single_pass/usb_backend.py differ
Files coolscanpy/tests/test_usb_backend.py and ports/tauri/vendor/coolscanpy/tests/test_usb_backend.py differ
Files coolscanpy/tests/transport/test_scanner_eject.py and ports/tauri/vendor/coolscanpy/tests/transport/test_scanner_eject.py differ
EOF

if [ "$FAIL" = 1 ]; then
  echo
  echo "ports/tauri/vendor drift check FAILED: a reviewed overlay changed."
  echo "Start from the canonical source and reapply only the intended platform"
  echo "overlay. Review every reported path and byte. Only after that review"
  echo "may you update an exact 'diff -rq' allowlist line or the expected"
  echo "fingerprint printed above; otherwise restore the canonical content."
  exit 1
fi

echo
echo "ports/tauri/vendor drift check passed (reviewed overlays only)."
