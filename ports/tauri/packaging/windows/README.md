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
by the installer or bridge installer. Only the separate, attended
hardware-session launcher below owns it.

### Owner-only launch for live motion

A normal **ScanStudio** Start-menu or Explorer launch is deliberately unarmed.
The setup checker's **Check scanner** action only refreshes status; it does not
authorize motion or repair the gates for an already-running process.

For an owner-attended session, first fully quit every ScanStudio window. Use
the separately named **ScanStudio Hardware Session** Start-menu shortcut and
keep its console window open. In a portable extraction, double-click
`Start-ScanStudio-Hardware-Session.cmd` beside `scanstudio-app.exe`. The
launcher prompts for the explicit name of the junk/test media currently
loaded. A scripted operator may supply it directly without changing policy:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
    "$env:LOCALAPPDATA\ScanStudio\Start-ScanStudio-Hardware-Session.ps1" `
    -MediaName "junk-roll"
```

This deliberately starts a fresh PowerShell process; wait for it to finish and
check its exit code. Do not invoke the PS1 inside an existing operator shell,
because the launcher supervises and exits its own PowerShell host.

No administrator launch is needed. The launcher uses the pinned
`Ubuntu-24.04` distro and fails before opening ScanStudio if another app
process, engine process, WSL bridge process, launcher-operation lock, or WSL
motion-latch object already exists. It checks for a WSL bridge both before and
immediately after acquiring the latch. It atomically publishes a regular,
non-symlink, mode-0600 latch under the fixed, shared, mode-0700
`~/.scanstudio` directory. The complete latch is valid UTF-8, at most 4096
bytes, and contains both a unique session token and the supplied media name.

Only the new child `scanstudio-app.exe` receives
`SCANSTUDIO_HW_MOTION=1`; the launcher does not create a persistent user or
system variable. The app forwards the exact value through `WSLENV` for its
engine/bridge child, and the bridge still re-checks both the variable and the
non-empty latch on every motion-capable request. The launcher waits for that
exact Windows child. It removes any inherited `SCANSTUDIO_STATE_DIR` and
`SCANSTUDIO_BRIDGE_BASE_DIR` values and their `WSLENV` entries, plus any
`HOME` entry in `WSLENV`, so neither the helper nor bridge can be redirected
away from the shared authorization lane.
When the child exits, the launcher checks its token and media content while
holding the launcher-operation lock, then removes the matching latch. The CMD
window pauses after cleanup so the owner can read and verify the result. A later
normal app launch is unarmed again.

Do not force-close the launcher console. The launcher joins a kill-on-close
Windows job before it starts the GUI, so its later Windows descendants are
terminated if the launcher dies. A detached cleanup guardian separately waits
for that exact launcher process and asks Ubuntu-24.04 to remove only the
matching token/media latch. This covers the ordinary console-close failure,
but it does **not** prove that a Linux-side bridge or an already-running scanner
operation stopped: killing `wsl.exe` alone is not that oracle. Power loss, WSL
failure, or external same-user latch mutation can also defeat automatic
cleanup.

After any abnormal close, stop and inspect the physical scanner state. Confirm
the Windows app/engine are gone and that `~/.scanstudio/hw-motion-armed` is
absent. If a latch, the exact operation-lock directory
`~/.scanstudio/.hw-motion-launcher-operation-lock`, or a bridge process
remains, do not overwrite or delete it while the orphan/helper can still be
running. Use the live runbook's last-resort
`wsl.exe --terminate Ubuntu-24.04` recovery first. After termination, start one
clean Ubuntu-24.04 shell before any ScanStudio app or bridge, verify no bridge
process exists, inspect and remove only the known stale latch/launcher lock,
then leave that shell and re-attach/re-run the preflight. Termination proves the
old helper cannot still hold the lock; it is not itself a place from which to
run `rm`. The next hardware launcher refuses leftovers rather than guessing.

## 3. A portable zip archive is also produced in CI

Some users prefer no installer at all. CI also produces a **portable zip
archive** of the verified installed tree, with no installer or registry
changes. It does not carry the NSIS installer's WebView2 bootstrapper. Use it
only where Microsoft Edge WebView2 is already installed; otherwise use the
preview `setup.exe`. Extract it, keep all files together, and run
`scanstudio-app.exe` for an unarmed setup/status session, or use the separate
`Start-ScanStudio-Hardware-Session.cmd` only for an attended live session.
Windows may still apply Mark-of-the-Web or SmartScreen checks to an unsigned
downloaded executable. The extracted folder also
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

- `packaging/windows/tests/test-hardware-session-launcher.sh` runs the
  macOS/Linux-safe adversarial launcher suite, including concurrent owners,
  hostile latch object types, invalid labels, and packaging-wiring checks.
- `packaging/windows/tests/test-hardware-session-launcher.ps1` is run under
  Windows PowerShell 5.1 with fake `wsl.exe` and `scanstudio-app.exe`
  processes. It verifies child-only environment scope, exact pinned WSL
  arguments, failures/exit codes, cleanup, and force-kill job/guardian
  behavior without opening WSL or touching scanner hardware. The Windows
  packager runs it against source, installed, and portable launcher layouts.
- `packaging/windows/assemble-staging.sh` assembles `packaging/.staging/windows/`
  locally on any host (no Windows machine needed).
- `packaging/windows/build-and-verify.ps1` performs a temporary current-user
  NSIS install/uninstall, so it must run in a clean Windows account or VM. It
  refuses to start when it detects an existing or running ScanStudio copy,
  shortcut, autostart value, or user/machine uninstall registration rather
  than overwriting real user state. After its temporary uninstall, it removes
  only the product key that still names its exact temporary install path and
  verifies that all temporary current-user state is gone.
- `packaging/windows/verify-bundle.sh <root>` is the macOS/Linux-runnable
  verifier; `packaging/windows/verify-bundle.ps1 -Root <path>` is the
  PowerShell twin CI runs on `windows-latest`. Both assert the same list from
  `packaging/license-manifest.json` and both fail closed on any leak of
  build-machine macOS home-directory paths.
