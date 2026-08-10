# ScanStudio

ScanStudio is a macOS alpha for scanning 35 mm film with a Nikon Coolscan
LS-5000. It keeps the scan workflow in one place: identify the film that is
loaded, preview the roll, select frames, choose the capture settings, scan,
and stop safely when needed.

Developer runs without a hardware bridge offer a clearly labeled
**SIMULATED** LS-5000 for exploring the interface safely. The release DMG
already includes the CoolscanPy bridge and its direct-USB runtime; source
builds can instead configure a separate compatible bridge. The app never
presents the simulator as hardware.

This is an alpha. It has been tested on one Mac and one LS-5000 setup. Treat
each real scan as a new operation: confirm the detected carrier and the
preview before starting capture. Real black-and-white fine scanning remains
blocked rather than pretending that infrared dust removal is available for
film where it is not appropriate.

## Use the app

1. **Choose a device.** Connect the simulator for a safe walkthrough, or
   connect the LS-5000 reported by the bridge.
2. **Preview the roll.** The app detects the loaded carrier when the scanner
   reports it, then obtains a preview and a contact sheet. The simulator uses
   generated previews and labels them accordingly.
3. **Select the frames to capture.** Choose one or more tiles, review their
   preview, and adjust orientation, mirroring, crop, or alignment where those
   controls are available. Rotation and mirroring are saved into the finished
   Positive/Preview files; the archival Master TIFF and its RGB, IR, and meter
   capture layers remain untouched. On an already-saved project, a new
   transform remains a session draft until the next scan starts; existing
   files are never silently rewritten.
4. **Set up the scan.** Choose negative or positive handling, film stock,
   recipe, output formats, naming, and destination. Keep the archival master
   TIFF, positive TIFF, positive JPEG, or any combination, but retain at
   least one output. Without a retained master, real capture uses a private
   temporary workspace only while derivatives render and keeps it only if
   recovery is needed.
5. **Scan or stop.** Start the selected frames and follow the in-app progress.
   The Stop button asks the current frame to finish safely, then prevents the
   next frame from starting. Eject stays unavailable during active capture.

When a master is retained, a Full Capture Package keeps the master image together with
the available capture context: per-frame effective settings, receipts,
checksums, and optional infrared or meter material. Attempt journals are
included only when the bridge supplies exact journal roots.

For a plain-language guide to the Nikon Scan, Noritsu Lab, and Flextight
color choices, see [COLOR.md](COLOR.md).

## Architecture

```
ScanStudio (SwiftUI app)  <-- NDJSON over stdin/stdout -->  scanstudio-engine (Rust subprocess)
```

- The SwiftUI app (`Sources/ScanStudio`) spawns `scanstudio-engine` as a
  child process and talks to it exclusively over stdin/stdout, one JSON object
  per line (NDJSON). It is a projection of the state and capabilities the
  engine reports.
- `ScanStudioKit` (`Sources/ScanStudioKit`) contains the wire protocol,
  engine location and client plumbing, and the observable session state used
  by the UI.
- The Rust engine (`engine/`) owns scanner/session state and is the sole
  implementation of the wire contract.
- The contract, fixtures, and state machines are documented in
  [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md). The bridge boundary is
  documented in [`protocol/BRIDGE.md`](protocol/BRIDGE.md).

## Prerequisites

- Xcode / Swift toolchain (Swift 6, macOS 14+ SDK)
- Rust via Homebrew (`brew install rust`), or any `cargo` on `PATH`

## Build, run, test

```sh
make run     # builds the engine (release) and launches the app
make test    # runs both suites: cargo test (engine) + swift test (app)
make smoke   # scripted end-to-end NDJSON session against the release binary
make app     # swift build only
make engine  # cargo build --release only
make clean   # removes build artifacts for both the engine and the app
```

`make run` sets `SCANSTUDIO_ENGINE_PATH` to the freshly built release binary.
Without that variable, `EngineLocator` searches the engine build locations
relative to the package root and reports a clear in-app error if it cannot
find one.

### Manual run

```sh
SCANSTUDIO_ENGINE_PATH="$(pwd)/engine/target/release/scanstudio-engine" swift run ScanStudio
```

### Speeding up the simulator for demos

Set `SCANSTUDIO_TIMESCALE` (default `1.0`) to multiply simulated delays. For
example, `SCANSTUDIO_TIMESCALE=0.05 make run` provides a fast walkthrough.

### Browser preview toggle (development)

Scan Studio's Settings window can start a loopback-only, simulator-only
browser preview for the current app session. Prepare the existing web runtime
and frontend first:

```sh
cd ../../ports/web && uv sync --locked --extra test
cd ../tauri/app && npm ci && npm run build:web
```

When the engine comes from this checkout, the app discovers
`ports/web/.venv/bin/scanstudio-web` and `ports/tauri/app/dist`. A custom
development layout can set the exact paths with
`SCANSTUDIO_WEB_COMMAND_PATH` and `SCANSTUDIO_WEB_STATIC_DIR`.

The release packaging scripts deliberately never bundle these Python/frontend
artifacts in `ScanStudio.app` or its DMG. An optional exact-version runtime may
instead be delivered as a separate Developer-ID-signed/notarized GitHub asset;
the app authenticates its detached manifest, caches the verified external
bundle, and reuses this app's exact engine. Default/dev builds without the
stamped public key and Team ID continue to report the missing trusted runtime
honestly and leave the toggle off. See
[`docs/WEB-RUNTIME-DISTRIBUTION.md`](../../docs/WEB-RUNTIME-DISTRIBUTION.md).

## Real hardware: LS-5000 through the CoolscanPy bridge

The real-device backend speaks the NDJSON contract in
[`protocol/BRIDGE.md`](protocol/BRIDGE.md) to `scanstudio-bridge`, the
GPL-3.0-only CoolscanPy helper. `make package` includes that helper, a
relocatable CPython 3.13 runtime, production Python dependencies (including
`python-sane`), a signed app-owned libusb built from pinned source for the
app's macOS 14 deployment target, and visible license/source material inside
`ScanStudio.app`. It does not include Nikon software or an operating-system
SANE backend.

The package launcher resolves a bridge in this order: `SCANSTUDIO_BRIDGE_CMD`,
the user bridge-command file, the bundled helper, then `PATH`. Set
`SCANSTUDIO_BRIDGE_CMD` to use a different compatible bridge:

```sh
SCANSTUDIO_BRIDGE_CMD=/path/to/scanstudio-bridge make run
```

- **Unset or empty:** only the labeled simulator is available.
- **Working bridge:** the real scanner is offered for connection; while real
  hardware is available, the simulator is hidden from device choice.
- **Broken or incompatible bridge:** the engine reports the startup problem
  and remains simulator-only; it does not create a half-connected device.

When the packaged launcher selects any working bridge, it automatically
prepares that app session for film movement. Launch itself performs no scanner
operation; only explicit Preview, Scan, and Eject actions can move film. Direct
bridge and developer launches still need to provide the two-part authorization
described in `protocol/BRIDGE.md`.

The supported color-roll path does not require SANE. On a clean Mac, device
discovery and connection fall back to the app-owned direct-USB route;
film-status checks, whole-roll preview, and color fine scanning use direct USB
and the exact signed libusb copy inside the app. A recipient does not need
Homebrew, SANE, or a Nikon driver for that workflow. If a working host SANE
installation already exists, discovery may use it, but capture remains direct
USB. The bridge still includes `python-sane` for its separate plain-scan and
software-eject paths; those optional actions need a compatible system SANE
backend (`brew install sane-backends` on the tested Apple Silicon setup). If
an unavailable optional path is requested, it fails rather than pretending it
succeeded; it does not turn a real scanner into the simulator.

The device bar identifies a connected real device as `real` and the simulator
as `simulated`. Selecting a device is separate from confirming that film is
present and previewed.
