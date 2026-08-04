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

Release packaging copies the complete bridge and CoolScanPy corresponding
source into each installer. `packaging/lib/common.sh` records the containing
release commit and a deterministic SHA-256 digest of each vendored GPL source
tree in the package's `provenance.json`.

The scanner-facing CoolScanPy bundle is separately sealed by component hashes
in `coolscanpy/protocol/ls5000_single_pass/bundle.py`; its integrity check must
pass before release.
