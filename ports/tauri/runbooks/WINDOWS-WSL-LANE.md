# Windows → WSL2 Device Lane: Operator Runbook

This runbook takes an operator from a bare Windows machine to a ScanStudio
setup-checker screen showing all five probes green. Every step names the
checker probe id (from `app/src-tauri/src/wsl/checker.rs`'s `PROBE_IDS`) it is
meant to turn green.

This document is executed by a human at the machine. It only describes the
steps, and no hardware-motion action appears anywhere here.

## Numbered steps

1. **Install WSL2 with the pinned Ubuntu-24.04 distro.** Run
   `wsl --install -d Ubuntu-24.04` in an admin PowerShell (never bare
   `wsl --install` / unversioned "Ubuntu" — the floating default has moved
   before and may move again). Verify with `wsl --status`: it should show
   Default Version 2 and Ubuntu-24.04 as the installed distro.
   *Turns green: `wsl_status`.*

2. **Install the bundled bridge lane inside WSL.** Find the Windows installer's
   resources directory containing `install-bridge-wsl.sh`, `BridgeRuntime/`,
   `Wheelhouse/`, and `CorrespondingSource/` (the portable zip uses the same
   layout). From an Ubuntu-24.04 WSL shell, run:
   `bash /path/to/install-bridge-wsl.sh --bundle-dir /path/to/bundle-root`.
   When the script itself is already in the bundle root, `--bundle-dir` may be
   omitted. It verifies the exact CPython 3.13.14 SHA-256 and the offline
   wheelhouse, installs the SANE/libusb/compiler system prerequisites, installs
   CoolscanPy first from the shipped source, then installs scanstudio-bridge
   from its shipped source, and exposes `/usr/local/bin/scanstudio-bridge`.
   It never uses the distro Python and never resolves a Python package from an
   index. On a fresh Ubuntu image, apt still needs network access to install
   the system prerequisites. Re-run with `--force` only when intentionally
   replacing an existing runtime; the old copy is retained for rollback.
   *Turns green: `bridge_which`, `bridge_version`.*

3. **Install usbipd-win on the Windows host (one-time):**
   `winget install --interactive --exact dorssel.usbipd-win`.

4. **Find and bind the LS-5000's bus id.** Run `usbipd list` and find the
   device with VID:PID `04b0:4002`. Bind it once with
   `usbipd bind --busid <busid>` (admin, persists across reboots), then attach
   it to WSL with
   `usbipd attach --wsl --busid <busid> --distribution Ubuntu-24.04`
   (no admin needed).
   *Turns green: `usbipd_attach`.*
   **This attach step is routine, not one-time** — repeat it after every
   Windows reboot, every scanner unplug/replug, and every usbipd service
   restart; a "the scanner just disappeared" symptom after any of those is
   expected, not a bug. While attached to WSL, the device is unavailable to
   Windows-side software (e.g. Nikon Scan / USBPcap); `usbipd detach` releases
   it back.

5. **Verify inside WSL:** `lsusb` shows a line containing `04b0:4002`.

6. **Run Phase 2's Linux environment probe VERBATIM and unchanged, inside the
   same WSL Ubuntu-24.04 shell:**
   `python3 /path/to/scanstudio-bridge/scripts/probe-linux-env.py`
   (installed alongside the bridge bundle) — repeatedly, until every line
   reports OK, following its own printed copy-paste fix commands for anything
   reporting FAIL. This step is identical to the one HW-01's Linux runbook
   runs — same script, same output format.

7. **Confirm the WebView2 Runtime is present.** Already true on most current
   Windows 11 machines, or bundled by the app installer's own bootstrapper.
   The portable zip does not carry that bootstrapper and requires WebView2 to
   be installed before `scanstudio-app.exe` can open.
   *Turns green: `webview2`.* If it reports FAIL, install from
   https://developer.microsoft.com/microsoft-edge/webview2/consumer/.

8. **Launch the ScanStudio app on Windows and open its setup checker screen.**
   Confirm all five probes — `wsl_status`, `bridge_which`, `bridge_version`,
   `usbipd_attach`, `webview2` — show green. Note the checker's max-single-read
   telemetry line too; it will read "no size data recorded" until a real
   capture has run.

9. **Recommended (not required): reduce Windows-side disk growth** from
   repeated large staged files by enabling sparse VHD — add `sparseVhd=true`
   under `[experimental]` in `%UserProfile%\.wslconfig`, then run
   `wsl --manage Ubuntu-24.04 --set-sparse true`; alternatively run
   `Optimize-VHD -Path <path-to-ext4.vhdx> -Mode full` periodically from an
   admin PowerShell with WSL shut down.

## Recovery

usbipd-win has known bugs (issues #504, #180, #581) where a device "works
once, then fails" until you run `usbipd detach --busid <busid>` followed by
`usbipd attach --wsl --busid <busid> --distribution Ubuntu-24.04` (a physical
replug also works). If the app quit abnormally and a bridge process seems stuck
holding the scanner (the checker's `bridge_which`/`bridge_version` probes still
report OK but nothing responds), the last-resort recovery is
`wsl.exe --terminate Ubuntu-24.04` followed by re-attaching per step 4.

---

**STOP.** Everything past this point is a live-hardware operation: arming the
motion latch, connecting the real scanner, previewing, capturing, and
ejecting. Those steps exist only in Phase 10's Windows live-validation runbook
(HW-02), executed by the owner at the machine, never by an agent. This document
ends here.
