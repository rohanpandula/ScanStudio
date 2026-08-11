# ScanStudio cross-platform previews

This directory contains the Windows and Linux port of ScanStudio. It shares
the current scanner engine, CoolScanPy capture layer, bridge, file formats,
receipts, and non-destructive archive format with the macOS app.

## Release status

| Build | Status | Hardware validation |
| --- | --- | --- |
| macOS Apple Silicon | **Beta** | Nikon LS-5000 real-film workflow validated |
| macOS Intel | **Preview** | Native build and package checks only |
| Windows x86-64 | **Preview** | Native installer and bundled bridge resources checked; live WSL2 scanner validation pending |
| Linux x86-64 | **Preview** | Package and clean Linux runtime verified; live scanner validation pending |

The Tauri macOS build in this directory is a packaging proof. Mac users should
download one of the native macOS DMGs from the main
[ScanStudio releases page](https://github.com/rohanpandula/ScanStudio/releases).

## Install

### Windows preview

1. On a clean system, download and run the Windows x86-64 preview installer;
   it supplies the WebView2 bootstrapper. The portable zip is for systems that
   already have Microsoft Edge WebView2: extract it, keep all files together,
   and run `scanstudio-app.exe`.
2. Install WSL2 with Ubuntu 24.04 if it is not already installed.
3. Follow `packaging/windows/README.md` to install the included offline scanner
   bridge inside WSL2 and attach the scanner's USB device.
4. Open ordinary ScanStudio and use its setup checker before loading film.
   This launch is unarmed. For the later owner-attended live runbook, fully
   quit it and use the separately named **ScanStudio Hardware Session**
   launcher (or the portable folder's matching `.cmd` launcher), which asks
   for the explicit junk/test media name and cleans up its owned latch when
   that app process exits.

The Windows application itself is native. Scanner access currently crosses a
pinned Ubuntu 24.04 WSL2 lane; both packages carry their own CPython runtime,
CoolScanPy and bridge source, and dependency wheelhouse. These avoid Python
package downloads, but a fresh Ubuntu setup still needs network access for
its system packages.

### Linux preview

1. Install your distribution's SANE and libusb runtime packages.
2. Download the x86-64 AppImage, make it executable, and open it. Alternatively,
   extract the portable tarball and run `./ScanStudio-*/AppRun`.
3. Follow `packaging/linux/README.md` for runtime prerequisites and scanner
   permissions.

The AppImage includes ScanStudio's Python runtime, CoolScanPy, bridge, and
`python-sane`. The host still supplies the system SANE/libusb libraries and
scanner permissions.

## What is included

- Real scanner acquisition plus an explicitly labelled simulator.
- Strip or roll previews, frame selection, and batch scanning.
- Untouched 16-bit archive masters, positive TIFFs, and JPEGs in one run.
- Optional archive packages containing RGB, infrared and meter layers,
  settings, receipts, and checksums.
- C41 inversion and Nikon-style color rendering.
- Rotation and horizontal or vertical mirroring applied to saved derivatives.

The archive master is never rewritten when presentation settings change, so a
scan can be rendered again later without rescanning the film.

## Build and verify

Prerequisites are Node.js, Rust, and platform-specific Tauri build tools.

```sh
./verify-app.sh
```

Windows and Linux packaging scripts live under `packaging/`. They use only the
vendored engine, CoolScanPy, bridge, and frozen protocol contracts in this
tree. Live scanner steps are intentionally kept in the operator runbooks.

## Licenses

The desktop port is MIT licensed. The bundled scanner bridge and CoolScanPy
are GPL-3.0-only; complete corresponding source and license notices ship with
each package. See `THIRD_PARTY_NOTICES.md` and `packaging/license-manifest.json`.
