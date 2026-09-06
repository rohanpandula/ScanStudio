# ScanStudio for macOS

ScanStudio is a SwiftUI film-scanning app for **Apple Silicon (M-series,
arm64), macOS 14 (Sonoma) or newer**. Its supported hardware workflow is
LS-5000 C-41 color-roll scanning in Beta. This guide covers source builds;
use the [install and scan guide](../../README.md) for the packaged app and
[GitHub Releases](https://github.com/rohanpandula/ScanStudio/releases) for
published downloads.

## Run from source

Use an Apple Silicon Mac with Swift 6 and the macOS SDK, plus Rust Cargo on
`PATH`. From the **repository root**:

```sh
make -C app/ScanStudio run
```

This builds the release engine, sets `SCANSTUDIO_ENGINE_PATH`, and launches
the SwiftUI app. Without a hardware bridge, choose the clearly labeled
**SIMULATED** LS-5000 for a software walkthrough. To shorten simulated delays:

```sh
SCANSTUDIO_TIMESCALE=0.05 make -C app/ScanStudio run
```

The default timescale is `1.0`. From **app/ScanStudio**, after building the
engine, the equivalent manual launch is:

```sh
SCANSTUDIO_ENGINE_PATH="$PWD/engine/target/release/scanstudio-engine" swift run ScanStudio
```

## Test and build scopes

Bridge and driver tests also need `uv` and Python 3.13+. All commands below
run from the **repository root**:

```sh
make test                       # Swift + Rust + bridge + CoolscanPy suites
make -C app/ScanStudio test      # Swift and Rust only
make -C app/ScanStudio smoke     # scripted simulator NDJSON session
make -C app/ScanStudio app       # Swift build only
make -C app/ScanStudio engine    # cargo build --release only
make bridge-test                # locked bridge sync, then pytest
make coolscanpy-test             # driver pytest
make -C app/ScanStudio launcher-check
```

There is no root `run` target. Root `make test` covers all four components,
but does not replace the packaging, macOS 14, policy, and updater release gates.
`make -C app/ScanStudio clean` removes both engine and Swift build artifacts.

## Connect real hardware in a source run

From the repository root:

```sh
make bridge-sync
SCANSTUDIO_BRIDGE_CMD="$PWD/bridge/.venv/bin/scanstudio-bridge" make -C app/ScanStudio run
```

Developer sessions must also satisfy the two-part hardware authorization in
[BRIDGE.md](protocol/BRIDGE.md) before motion. For the normal attended workflow,
use the packaged app and follow [Mac acceptance and recovery](../../docs/MAC-ACCEPTANCE.md).

The packaged launcher resolves the bridge in this order: `SCANSTUDIO_BRIDGE_CMD`,
`~/Library/Application Support/ScanStudio/bridge-command`, bundled helper,
then `PATH`. It prepares session authorization; launch itself does not move
film. Preview, Scan, and Eject are explicit operations with readiness and
approval checks. A working bridge offers real hardware and hides the simulator
when hardware is available. A broken bridge reports its startup error and
leaves the simulator labeled; failed hardware operations never become
simulated successes.

## Build a local app or DMG

Packaging requires native arm64 macOS; Intel/Rosetta and other architecture
requests are rejected. Match CI with Rust **1.97.1**, **uv 0.11.30**, and
relocatable managed **CPython 3.13.14, build 20260718**. See the
[pinned installer](../../scripts/install_pinned_uv_python.py) and its
[CI bootstrap sequence](../../.github/workflows/ci.yml). A Homebrew/framework
Python is not a relocatable package runtime.

With those tools available, run this **from the repository root**:

```sh
export UV_PYTHON=3.13.14
export UV_PYTHON_PREFERENCE=only-managed
export UV_PYTHON_CPYTHON_BUILD=20260718
(cd bridge && uv sync --locked --no-dev --no-install-package python-sane)
make -C app/ScanStudio package
```

This follows CI's dependency path. It creates
`app/ScanStudio/.build/ScanStudio.app` and runs the relocated bridge and
simulator acceptance checks. These commands rerun the existing app's gate or
build a version-stamped local DMG:

```sh
make -C app/ScanStudio package-check
SCANSTUDIO_RELEASE_VERSION=0.7.0-beta.16 make -C app/ScanStudio dmg
```

`dmg` rebuilds/checks the app, creates
`app/ScanStudio/.build/ScanStudio-0.7.0-beta.16-macOS-arm64.dmg`, mounts it
read-only, and checks the app inside. It refuses an existing DMG at that path.
Local builds default to an ad-hoc app signature; these commands do not notarize
or publish a release. The [release workflow](../../.github/workflows/release.yml)
signs, notarizes, and staples both app and DMG after its exact-tag, same-run
gates. See [release policy](../../docs/releases/README.md).

Root `make package` and `make dmg` first run `bridge-sync-scanner`, asking uv
to install the scanner extra. The app-directory path above instead lets the
packager compile locked python-sane 2.9.2 against a private, pinned SANE 1.4.0
link SDK, without host SANE as a build input. Neither that SDK nor a SANE
runtime ships. For standalone SDK inspection, use
`make -C app/ScanStudio sane-link-sdk` (create-only output).

The app bundles its own signed libusb. LS-5000 color-roll status, preview,
capture, and eject use direct USB; discovery/connection fall back to direct
USB without SANE. Only the legacy plain-scan path needs a compatible host SANE
backend. Eject confirms film absence without SANE or `scanimage`.

## Scan, inspect saved files, and recover

Create or open a roll, explicitly preview the film, review frame placement,
choose outputs and a writable destination, then scan. A saved project does not
establish physical registration. Recovered/manual boundaries need approval.

Scanner preview locates frames; capture reads them at scan resolution.
Positive TIFF/JPEG and generated Preview files are processed exports, separate
from the optional archival Master TIFF. Settings apply to **future scans**:
recipe, crop, color, and output changes do not rewrite saved files or update
scanner previews. Rotation/mirroring affect processed exports, leaving the
Master and its RGB/infrared/meter capture material untouched. Project edits
can remain drafts until the next scan starts.

Retain a Master TIFF, positive TIFF/JPEG, or both. With no retained master,
capture uses temporary storage during rendering and preserves it if recovery
is needed. Optional raw exports include Linear DNG and linear TIFF with
infrared options. A **Full Capture Package** adds available settings, receipts,
checksums, and evidence to the master; attempt journals require exact reported
roots. See [COLOR.md](COLOR.md) for rendering choices.

In **Saved roll**, use **Show Roll Folder in Finder** or **Frame N Saved Files**
to reveal recorded outputs. Missing files are reported explicitly. Completion
counts follow receipts; inspect saved images too.

For hardware, choose **Stop after frame**; in the simulator, **Pause after
frame**. Wait for the batch to stop and preserve files, receipts, and journals.
Early Stop remains latched through batch setup; eject is unavailable during
capture. Save failure details with **Save Diagnostic Bundle…**.

Reopen the same roll when safe, follow any refeed instruction, and obtain a
fresh preview after stopping. Resolve readiness/attendance prompts, then use
**Resume Batch (N remaining)**. It requires a successful current pending-frame
read and omits completed/excluded frames. Reconnection alone cannot restore
film position or authorize a stale selection. Follow the
[recovery procedure](../../docs/MAC-ACCEPTANCE.md) instead of restarting the
whole roll or deleting receipts.

Final attended full-roll hardware acceptance for beta.16 is **NOT RUN**. Simulator
acceptance covers stop, reopen, process interruption, destination refusal,
resume, and saved-file integrity; it cannot prove physical image quality or
transport. The [hardware matrix](../../docs/HARDWARE-SUPPORT.md) distinguishes
LS-5000 evidence from recognition/probing of unsupported models. Real B&W
fine scanning remains blocked; infrared ICE is unsuitable for silver B&W film.

## Contracts, platforms, and licenses

```text
SwiftUI app → scanstudio-engine (Rust) → scanstudio-bridge (Python) → CoolscanPy → scanner
```

The app/engine and engine/bridge each use a separate NDJSON stdin/stdout
connection. The engine owns scanner/session state; `Sources/ScanStudioKit`
contains app wire types, client plumbing, and observable state. See
[PROTOCOL.md](protocol/PROTOCOL.md) and [BRIDGE.md](protocol/BRIDGE.md).

Intel Macs, Windows, and Linux are retired. Consult [NegPy downloads](https://github.com/marcinz606/NegPy/releases)
and [upstream compatibility guidance](https://github.com/marcinz606/NegPy#readme)
for those platforms. nkscan is a documentation-only cleanroom reference;
no implementation code or profiles are copied.

The app/engine are MIT; the separate bridge and CoolscanPy are GPL-3.0-only.
Packaged apps are mixed-license distributions. Preserve
`Contents/Resources/Licenses` and `Contents/Resources/CorrespondingSource`,
including dependency notices and rebuild material. See
[third-party notices](../../THIRD_PARTY_NOTICES.md).
