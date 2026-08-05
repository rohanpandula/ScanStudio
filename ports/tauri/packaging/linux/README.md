# ScanStudio for Linux

This directory holds the Linux packaging scripts (`assemble-staging.sh`,
`verify-bundle.sh`) and the staged resource tree they build. Tauri embeds the
assembled `packaging/.staging/linux/` resources in the AppImage via
`app/src-tauri/tauri.linux.conf.json`. The portable tarball is made from that
verified AppImage's extracted AppDir, so it contains the same app executable,
engine sidecar, runtime, and resources rather than a separate package layout.

## Runtime prerequisites — not bundled

ScanStudio bundles the Python `python-sane` binding, compiled for its private
CPython 3.13 runtime. It does **not** bundle the system SANE/libusb libraries or
scanner backend. Real hardware needs those system packages from your
distribution. The FUSE package needed to run the AppImage differs by release,
so install the matching line only:

- **Ubuntu 24.04 / Debian 13**
  `sudo apt-get install -y libfuse2t64 libsane1 sane-utils libusb-1.0-0`

- **Ubuntu 22.04 / Debian 12** (package is named `libfuse2`, not `libfuse2t64`)
  `sudo apt-get install -y libfuse2 libsane1 sane-utils libusb-1.0-0`

## FUSE-less fallback

On systems where FUSE is unavailable or locked down, run the AppImage
without mounting it:

```
./ScanStudio.AppImage --appimage-extract-and-run
```

## Bridge resolution order

The launcher selects the hardware bridge in exactly this order (it only
selects; it never arms motion):

1. `SCANSTUDIO_BRIDGE_CMD` environment variable.
2. A one-line user config file — put the bridge command on one line at
   `~/.config/scanstudio/bridge-command`. The line is a literal command (path
   plus optional arguments), not shell code, and is passed to the engine
   unchanged.
3. The bundled helper `scanstudio-bridge` next to the launcher (its directory
   is added to `PATH`; the bare command name is used so moving the install
   directory never breaks resolution).
4. `PATH` via `command -v scanstudio-bridge`.

If none resolve, the app launches simulator-only and prints guidance naming
all four options.

## AppImage and extracted-tar launch behavior

To use the portable tarball, extract it and launch its AppDir entrypoint:

```
tar -xzf ScanStudio-*-Linux-x86_64-preview-portable.tar.gz
./ScanStudio-*-Linux-x86_64-preview/AppRun
```

The Tauri entrypoint resolves the bridge before starting its engine sidecar,
using the same order listed above. In particular, it passes the absolute path
of the bundled `scanstudio-bridge` resource to the engine when no environment
or user-config override exists. This applies both to a mounted AppImage and to
the extracted tar tree; neither path depends on a login shell or a user-level
bridge installation. `scanstudio-launcher.sh` remains available for portable
tree integrations and uses the same bundled helper fallback.

Linux release builders also need `libsane-dev` and `build-essential` so the
strict bundle can compile python-sane for its bundled CPython. Those are build
dependencies only; users need the runtime packages shown above.

## Cross-compiled engine sidecar

CI places the cross-compiled engine sidecar at
`app/src-tauri/binaries/scanstudio-engine-x86_64-unknown-linux-gnu` before
bundling, following Tauri's `externalBin` per-platform naming convention
(resolved from the single `binaries/scanstudio-engine` entry in
`tauri.conf.json`).
