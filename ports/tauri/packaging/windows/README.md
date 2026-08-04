# ScanStudio for Windows

This directory holds the Windows packaging scripts. The native Windows app
does not run Python. The hardware bridge runs inside WSL2 from a private,
bundle-owned Linux CPython 3.13.14 runtime. Its interpreter is pinned by exact
release URL and SHA-256, and its Python dependencies ship in a checksummed
offline wheelhouse. A clean machine does not need a system Python or network
access to PyPI. A fresh Ubuntu WSL installation still needs apt/network access
once for SANE, libusb, and compiler system prerequisites.

## 1. The installer is unsigned — SmartScreen will warn you (expected)

This milestone defers Windows code signing (v2 DIST-01), so the NSIS
installer is **not** digitally signed. On first run, Windows SmartScreen shows

> **Windows protected your PC** — "Microsoft Defender SmartScreen prevented an
> unrecognized app from starting..."

This is the expected behavior for an unsigned installer, **not** a sign of a
compromised download. To proceed, click **"More info"** and then **"Run
anyway"**.

Do not expect this to vanish on day one of future signing either: SmartScreen
builds reputation per-certificate from real install volume, and even a paid or
Azure Artifact-Signed certificate needs time (and occasionally new-install
volume) before messages to apply it stop being flagged. Budget for this
friction; it is documented here so it is never mistaken for a build defect.

## 2. The bridge runs inside WSL2, not natively on Windows

The Tauri app and engine talk to the bridge over the existing three-process
protocol, but the bridge itself runs as a Linux process inside WSL2 rather than
natively on Windows. Its source, private CPython runtime, and offline
dependencies are included so the bridge can be installed into WSL2.

After installing the app:

1. Install WSL2 Ubuntu-24.04 (pinned, not the floating default) plus the
   usbipd-win USB pass-through setup exactly as the Phase 8 runbook
   (`runbooks/WINDOWS-WSL-LANE.md`) documents.
2. Find the installed resources directory containing `install-bridge-wsl.sh`,
   `BridgeRuntime/`, `Wheelhouse/`, and `CorrespondingSource/`. The portable
   zip has the same layout. From an Ubuntu-24.04 WSL shell, run:

   ```
   bash /path/to/install-bridge-wsl.sh --bundle-dir /path/to/bundle-root
   ```

   When the script is run from the bundle root, `--bundle-dir` may be omitted.
   It installs the Ubuntu SANE/libusb/compiler prerequisites, verifies the
   pinned CPython archive and every wheelhouse checksum, and builds a private
   runtime under `${XDG_DATA_HOME:-$HOME/.local/share}/scanstudio/wsl-bridge`.
   It installs **CoolscanPy first**, then `scanstudio-bridge`, from the two
   shipped corresponding-source trees with dependency resolution disabled.
   All Python packages are installed with `--no-index`; no remote project can
   be selected accidentally. Confirm that the entrypoint imports, launches,
   and exits cleanly on stdin EOF with:

   ```
   scanstudio-bridge --version < /dev/null
   ```

   Re-running without flags refuses to overwrite an existing runtime. Use
   `--force` to replace it; the previous runtime is kept as a timestamped
   rollback copy.

The bundle also carries this README plus the setup and live-validation
runbooks under `Documentation/`. Its Python bridge sources and dependencies
are local; Ubuntu system prerequisites are not bundled.

Launching the same safety model as everywhere else applies: preview/scan once
the Phase 10 runbook's hardware gates are met; the motion latch is never armed
by this installer or this script.

### Owner-only launch for live motion

A normal Start-menu or Explorer launch is deliberately unarmed. For an
owner-attended live session, first close every running ScanStudio window, then
create the separate non-empty latch inside Ubuntu-24.04 exactly as the live
runbook describes. Launch the installed app from a fresh Windows PowerShell
with a process-scoped variable:

```powershell
$ScanStudioExe = "$env:LOCALAPPDATA\ScanStudio\scanstudio-app.exe"
$env:SCANSTUDIO_HW_MOTION = "1"
try {
    Start-Process -FilePath $ScanStudioExe
} finally {
    Remove-Item Env:\SCANSTUDIO_HW_MOTION -ErrorAction SilentlyContinue
}
```

For the portable archive, set `$ScanStudioExe` to that extracted copy of
`scanstudio-app.exe`. Do not use `setx` or create a persistent user/system
variable. The app forwards the exact value `1` into WSL only when it was
present in the newly launched Windows app process; it adds the required
`SCANSTUDIO_HW_MOTION/u` entry to that child's `WSLENV` while preserving any
unrelated existing entries. The app does not create the WSL latch, and the
bridge still checks both the variable and the non-empty latch on every
motion-capable request.

To disarm, fully quit that ScanStudio process and remove
`~/.scanstudio/hw-motion-armed` inside Ubuntu. A later normal app launch is
unarmed again.

## 3. A portable zip archive is also produced in CI

Some users prefer no installer at all. CI also produces a **portable zip
archive** of the verified installed tree, with no installer or registry
changes. It does not carry the NSIS installer's WebView2 bootstrapper. Use it
only where Microsoft Edge WebView2 is already installed; otherwise use the
preview `setup.exe`. Extract it, keep all files together, and run
`scanstudio-app.exe`. Windows may still apply Mark-of-the-Web or SmartScreen
checks to an unsigned downloaded executable. The extracted folder also
contains the resource root with `install-bridge-wsl.sh`, `BridgeRuntime/`,
`Wheelhouse/`, and `CorrespondingSource/` for the WSL2 setup described above.

CI verifies the portable archive's complete resource tree and engine sidecar.
It does not launch the Tauri GUI in a clean interactive Windows desktop.

## 4. Engine sidecar location before bundling

Tauri resolves a single `binaries/scanstudio-engine` `externalBin` entry to a
per-OS binary using the `<name>-<target-triple>[.exe]` convention. CI
cross-compiles the engine for Windows and places it at

```
app/src-tauri/binaries/scanstudio-engine-x86_64-pc-windows-msvc.exe
```

before running `tauri build` so the NSIS installer and the portable zip both
carry the Windows engine sidecar. `bundle.targets` for Windows is NSIS-only
(`app/src-tauri/tauri.windows.conf.json`); WiX/MSI is not targeted (requires
a separately-installed toolset plus a Windows feature not guaranteed on
current runner images).

## Verification

- `packaging/windows/assemble-staging.sh` assembles `packaging/.staging/windows/`
  locally on any host (no Windows machine needed).
- `packaging/windows/verify-bundle.sh <root>` is the macOS/Linux-runnable
  verifier; `packaging/windows/verify-bundle.ps1 -Root <path>` is the
  PowerShell twin CI runs on `windows-latest`. Both assert the same list from
  `packaging/license-manifest.json` and both fail closed on any leak of
  build-machine macOS home-directory paths.
