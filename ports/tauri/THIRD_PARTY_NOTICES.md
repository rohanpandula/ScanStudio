# Third-party notices

This file describes the licensing boundary for this repository and for any packaged binary release. It is a notice guide, not legal advice.

## Project-owned material

This repository's original ScanStudio application source — `app/`, `packaging/`, `vendor/engine/`, and `vendor/protocol/` — is offered under the [MIT License](LICENSE). That license does not grant rights to Nikon software, firmware, manuals, trademarks, private evidence, or third-party components.

The repository intentionally does not distribute Nikon executables, drivers, firmware, profiles, or manuals.

## Separate hardware bridge

Real LS-5000 access is provided through `scanstudio-bridge`, a separate executable that uses CoolscanPy. Both `vendor/scanstudio-bridge/` and `vendor/coolscanpy/` are GPL-3.0-only. A packaged Linux or Windows artifact therefore carries the bridge and CoolscanPy material, so it is a mixed-license distribution and is not covered by this repository's MIT license alone.

Do not label a bundle that includes the bridge as MIT-only. The exact required-path list that must be present in every bundle lives in `packaging/license-manifest.json`; it is asserted by `packaging/linux/verify-bundle.sh` and `packaging/windows/verify-bundle.ps1`/`.sh`. That path list is the single source of truth — it is deliberately not duplicated in this file. Packaging runs must satisfy it: GPL texts and complete corresponding-source trees under `CorrespondingSource/` for both `scanstudio-bridge` and `coolscanpy`, plus the CPython license and per-wheel license material where those are bundled.

## Rust and frontend dependencies

The packaged app includes two compiled Rust graphs: the native Tauri application and the engine sidecar. Unlike a hand-transcribed per-crate SPDX table (which goes stale on every `Cargo.lock` change), every packaging run uses pinned cargo-about 0.9.1 with `--locked --fail` to regenerate full-text reports. The exact inputs and outputs ship as `Licenses/Rust-App-Cargo.lock`, `Licenses/Rust-App-THIRD-PARTY.txt`, `Licenses/Rust-Engine-Cargo.lock`, and `Licenses/Rust-Engine-THIRD-PARTY.txt`.

The React frontend also bundles production JavaScript dependencies. Packaging installs the exact production closure from `app/package-lock.json` and regenerates `Licenses/npm-production/`, including the exact lock, an inventory, package metadata, upstream notices, and a hash-pinned reviewed full-text fallback for any SPDX-only package. `Licenses/dependency-notices-manifest.json` binds every file in the complete notice tree by SHA-256. The bundle verifiers recompute that manifest and prove the npm inventory still matches the bundled production lock closure after each installer/archive is extracted.

## Binary distribution checklist

Before distributing an installer, archive, or any other binary artifact:

1. Run the OS assemble script (`packaging/linux/` or `packaging/windows/`) to build the staged bundle.
2. Run that OS's verify script, which asserts the artifact against `packaging/license-manifest.json`.
3. Confirm the GPL texts and the complete corresponding-source trees for `scanstudio-bridge` and `coolscanpy` are present in the bundle.
4. Keep Nikon software and private evidence out of the release; the shared library's `assert_no_developer_paths` check enforces the machine-path rule.
5. Recheck this file and re-run the verify scripts after any dependency or packaging change.
