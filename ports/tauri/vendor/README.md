# Vendored runtime sources

The Windows and Linux previews are built only from the sources in this
directory. They do not depend on a maintainer's sibling checkout.

- `engine/` is the current ScanStudio Rust engine plus the cross-platform
  filesystem and Windows/WSL handoff layer. It is MIT licensed with the app.
- `protocol/` contains the frozen engine/bridge contracts and golden fixtures.
  A port bug is fixed in the implementation; these contracts are not rewritten
  to match a bug.
- `scanstudio-bridge/` is the GPL-3.0-only hardware bridge.
- `coolscanpy/` is the GPL-3.0-only scanner acquisition library.

## Canonical base and reviewed exceptions

The primary trees are the canonical merge base. A vendor refresh copies the
canonical implementation first, then reapplies only the reviewed platform
overlay. The exact exception set is enforced by
`scripts/check_ports_vendor_sync.sh`:

- `protocol/` has no exception and must remain byte-identical.
- `engine/` differs only in `Cargo.toml`, `Cargo.lock`, `src/lib.rs`,
  `src/manifest.rs`, `src/real_backend.rs`, `src/render.rs`,
  `src/evidence_package.rs`, and the vendor-only `src/wsl_io.rs`. These files
  provide the `same-file` dependency, the pinned Windows/WSL handoff, native
  Windows `%USERPROFILE%` fallback in the manifest layer, portable physical
  identity checks, and WSL evidence-path/provenance rebasing.
- `scanstudio-bridge/` has mirror-only `.github/`,
  `scripts/probe-linux-env.py`, `scripts/verify-bridge.sh`,
  `tests/test_probe_linux_env.py`, and
  `tests/test_stdout_byte_discipline.py`. Its reviewed differing files are
  `src/scanstudio_bridge/cli.py`, `safety.py`, `service.py`,
  `transport/output_reservation.py`, `tests/test_safety.py`,
  `tests/test_transport_mock.py`, and `uv.lock`. These preserve byte-exact
  Windows NDJSON, fail-closed bridge ownership, sealed run-from-source startup,
  and private WSL staging.
- `coolscanpy/` differs only in
  `src/coolscanpy/protocol/ls5000_single_pass/bundle.py`,
  `src/coolscanpy/protocol/ls5000_single_pass/usb_backend.py`,
  `tests/test_usb_backend.py`, and
  `tests/transport/test_scanner_eject.py`: the sealed bundle/Linux USB overlay
  and its USB/scanner-eject policy tests.

No differing filename is a blanket permission to change that file. Each
exception is a small platform overlay on the canonical source.

## Secure Windows/WSL capture flow

The Windows port does not let the WSL bridge publish into a user destination.
Before motion, the canonical renderer acquires and retains the project and
`JobOutputAuthorities` handles. The engine then creates an unpredictable,
held, collision-isolated private workspace and gives the bridge only a pinned
Ubuntu 24.04 staging route under
`/tmp/scanstudio-wsl-staging/<random-owner-token>`.

The bridge creates that staging directory privately and writes capture files
there. On receipt, the native engine validates the exact pinned distro and
route, rejects traversal, links, reparse points, non-regular or multiply linked
files, holds source and ancestor handles, and checks the bridge's artifact
evidence. It copies bounded exact bytes through already-open handles into
create-new files in the engine-private workspace, syncs that workspace, and
rewrites the receipt to those owned paths. Unsafe identity-by-path cleanup of
the WSL UNC staging namespace is deliberately refused; such staging is
recovery-held instead.

From that point the normal canonical pipeline is unchanged: stable held input
snapshots feed rendering, and only the retained no-follow
`JobOutputAuthorities` capabilities may publish archive, sidecar, raw, positive,
preview, or evidence outputs. WSL staging and the private workspace are sources,
never alternate publishers. An already-running malicious same-UID Unix process
remains the documented scratch-namespace boundary until the live bridge can use
transferred file descriptors or an equivalent sandbox.

## Dual drift guard

`scripts/check_ports_vendor_sync.sh` applies the same cache/build exclusions to
two independent checks for every canonical/vendor pair:

1. An exact `diff -rq` allowlist fixes which names may differ and rejects stale
   as well as newly added entries.
2. A deterministic divergence fingerprint fixes the relative path, side,
   entry type, repository executable bit, file byte length and SHA-256, or exact
   symlink target for every differing entry.

Consequently, changing bytes inside an already-allowlisted file still fails.
When a reviewed platform overlay changes, copy the latest canonical source,
reapply and review the minimal overlay, run the guard, inspect every reported
difference, and only then update the allowlist or checked digest printed by the
failure. A digest must never be refreshed merely to make the check pass.

Release packaging copies the complete bridge and CoolScanPy corresponding
source into each installer. `packaging/lib/common.sh` records the containing
release commit and a deterministic SHA-256 digest of each vendored GPL source
tree in the package's `provenance.json`.

The scanner-facing CoolScanPy bundle is separately sealed by component hashes
in `coolscanpy/protocol/ls5000_single_pass/bundle.py`; its integrity check must
pass before release.
