# Linux Live-Hardware Validation Runbook (HW-01)

This runbook is the Linux lane's live-hardware validation procedure: from VM
and USB passthrough setup, through the environment probe, Phase 9 bundle
install, a clearly STOP-gated live sequence, and an evidence checklist. No
step here is executed by any automated process — every instruction, including
everything past the STOP banner, is phrased as something the owner does at the
machine. A wrong or invented claim in this document would be a safety defect,
not a documentation nitpick, so every statement about what the scanner or
bridge does is either a verbatim copy of a BRIDGE.md contract sentence (cited
by section) or phrased as "record what you observe".

## Scheduling and Safety Preconditions

Before anything else, the owner reads and accepts two preconditions:

1. Exactly one LS-5000 exists and is currently attached to, and mid-campaign
   on, the owner's macOS setup. This runbook's live section cannot begin until
   that campaign frees the scanner and the owner physically moves/reattaches it
   to the Ubuntu VM's USB passthrough. Do not schedule assuming concurrent
   access — there is one scanner, and live work serializes behind the current
   macOS campaign.
2. Once a strip is loaded for the live sequence, a loaded strip may auto-eject
   after an unknown idle interval. This document intentionally states no
   specific auto-eject timeout, because no such number is known to be true. If
   the strip ejects mid-runbook, treat the roll's prior preview/approval state
   as lost and restart from the preview step after physically refeeding the
   strip.

Both preconditions apply before any live step below.

## [a] VM and USB Passthrough Setup

- Reuse the same hypervisor VM + USB-controller-passthrough pattern already
  used for the owner's existing scanner-attached VM(s) on the same host: pass
  the LS-5000's USB controller/device through to the Ubuntu VM via the
  hypervisor's VM management USB/PCI passthrough settings.
- Exact menu labels vary by hypervisor version, so mirror your existing
  passthrough setup rather than following a fixed click path invented here.
- Once passthrough is active, the Ubuntu VM must see the device at VID:PID
  `04b0:4002`; that visibility is confirmed by the probe in section [b], not
  assumed here.

## [b] Environment Probe

The owner runs Phase 2's probe script at the absolute path
`vendor/scanstudio-bridge/scripts/probe-linux-env.py` inside
the Ubuntu VM, re-running it after applying any printed fix command, until
every check reports OK.

This runbook does not hardcode fix commands — apply whatever fix command the
probe script itself prints for each FAIL, then re-run the probe.

The script performs six checks, each printed as its own `[OK]`/`[FAIL]` line.
Each is a numbered sub-step named with the exact identifier the script prints:

1. `sane-backends` — the sane-backends installation is present (found via
   `sane-config` or `pkg-config sane-backends`).
2. `scanimage` — the `scanimage` tool from `sane-utils` is available on PATH.
3. `libusb` — `libusb-1.0` is visible to the dynamic linker
   (`ctypes.util.find_library`).
4. `lsusb-device` — the LS-5000 at USB ID `04b0:4002` is visible on the bus
   via `lsusb`; this is the passthrough confirmation from section [a].
5. `udev-rules` — a coolscan/sane udev rule is installed.
6. `usb-permission` — the current user is in the `scanner` group (the USB
   permission heuristic).

For every check that prints FAIL, apply the copy-paste fix command the probe
itself prints, then re-run the probe until all six report OK. Keep the probe's
output for the evidence checklist: a FAIL that persists even after the printed
fix is itself evidence worth recording.

## [c] Install the Linux Bundle

- Install Phase 9's Linux bundle on the Ubuntu VM: the AppImage and/or the
  plain tarball artifact, together with the staged resource tree they carry.
- Verify the bundle with the Phase 9 verification script at
  `packaging/linux/verify-bundle.sh` against the assembled bundle root.
- Ubuntu 24.04 / Debian 13 FUSE landmine: AppImages need `libfuse2t64` (not
  `libfuse2`), and it is not installed by default. Install it, for example with
  `sudo apt-get install -y libfuse2t64`, before relying on the AppImage path.
- If FUSE is unavailable or locked down, do not fight it: use the tarball
  artifact, or run `./ScanStudio.AppImage --appimage-extract-and-run` instead.
- Note the launcher's bridge-resolution order documented in
  `packaging/linux/README.md` — the launcher only selects the bridge; it never
  arms motion.

## STOP — LIVE HARDWARE STEPS BELOW

Everything above this line is safe to prepare without moving film or arming the
motion latch. Everything below is for the owner only, physically present at the
machine. No step below this line is a task for an agent, a script, or any
automated process — every instruction below is phrased as something the owner
does.

## [e] Live Sequence (Owner Only)

The owner performs the following steps in order, at the machine, using a
junk/test roll (not archival material):

**e1. Arm the motion latch.** The owner sets the environment variable
`SCANSTUDIO_HW_MOTION` to exactly `1` and writes non-empty content naming the
loaded media (for example the string `junk-roll`) to
`~/.scanstudio/hw-motion-armed`. This mirrors the armed-latch contract:

> Armed latch. Re-checked live — never cached — on every motion-capable
> request: env `SCANSTUDIO_HW_MOTION` == "1" AND file
> `~/.scanstudio/hw-motion-armed` exists with non-empty stripped content (the
> content names the loaded media, e.g. `junk-roll`). Either condition failing
> is `HW_MOTION_NOT_ARMED`. There is no method literally named `feed` —
> `roll.preview` stands in for it, since a preview requires the same physical
> roll motion as a feed. (BRIDGE.md, SAFE-02 guardrails)

The owner also notes that a second process contending for the hardware lane
during this sequence gets `HARDWARE_LANE_BUSY`:

> Single hardware lane. An advisory lock file, `~/.scanstudio/hw-lane.lock`, is
> held for the duration of any motion-capable operation. A second process
> contending for it gets `HARDWARE_LANE_BUSY`. (BRIDGE.md, SAFE-02 guardrails)

**e2. Connect the real device.** The owner connects the real device from the
app's device list, which the app labels honestly as `real` (never `simulated`)
once selected. Record which label the app shows.

**e3. Preview a junk roll.** The owner runs a preview of a junk/test roll (not
archival material) via the app's preview action, and records the reported slot
count and the roll fingerprint once the preview completes. Record what you
observe — the slot count and fingerprint are whatever the app's preview result
and preview-complete display report.

**e4. Approve one frame.** The owner approves and/or adjusts the spacing
offset of exactly one previewed frame before capture: a frame flagged
`needsApproval` in its preview must be approved before it can be captured.
Record whether that frame's preview flag was `needsApproval: true` and what you
observed when approving or adjusting it.

**e5. Capture one frame.** The owner captures that one frame using the fixed
recipe, to a scratch output destination the owner chooses (not a permanent
archive location). The recipe is fixed, not client-configurable:

> The only wired `material: "colorNegative"` combination is fixed:
> `resolutionDpi: 4000`, `bitDepth: 16`, `multisamplePasses: 4`, `channels:
> "rgbi"`, `autofocus: true`, `autoExposure: true` — fixed by the LS-5000's
> single-pass protocol, not client-configurable. (BRIDGE.md, Recipe
> constraints)

**e6. Verify the artifacts.** The owner verifies the resulting artifacts exist
after the capture completes: the RGB TIFF plus, when capturing IR, the `_IR`
sidecar:

> `scan.start`'s `output.destination` and `output.filenameTemplate` (`####` ->
> zero-padded slot number) tell the bridge where to write each slot's RGB TIFF
> (16-bit, tagged at `recipe.resolutionDpi`), plus, when capturing IR, an `_IR`
> sidecar (`{stem}_IR.tif`, matching CoolscanPy's own internal naming).
> (BRIDGE.md, Image payloads)

a fresh telemetry JSONL line under `~/.scanstudio/hw-telemetry/`:

> Telemetry. Every hardware-bound call appends one JSONL line under
> `~/.scanstudio/hw-telemetry/` before the call and one line after the outcome
> is known. (BRIDGE.md, SAFE-02 guardrails)

and, if present, an `attempts_root` directory under
`~/.scanstudio/coolscanpy-attempts/`:

> a caller-owned `attempts_root` (a fresh UUID directory under
> `~/.scanstudio/coolscanpy-attempts/`, one per `Roll` ...) ... This keeps a
> failed attempt's journal/manifest/raster evidence on disk past device close,
> for post-mortem inspection. (BRIDGE.md, scan.start / Attempts-root
> persistence)

Record what you observe for each artifact (path and exists-or-not; a missing
`_IR` sidecar or `attempts_root` is itself a data point to keep).

**e7. Eject and record the outcome.** The owner ejects the strip and records
the exact outcome text the app shows — never paraphrased. The eject rule:

> {} means confirmed ejected, never anything less. A transport that reports the
> film did not come out, a capability-gated no-op, or any
> accepted-without-progress outcome surfaces as a typed error, never as {}.
> This rule exists because an LS-5000 can acknowledge an eject command while
> the parked mechanism does not actuate. (BRIDGE.md, device.eject)

## [f] Evidence Checklist

| Item | Where to find it | Keep for the record |
| --- | --- | --- |
| ScanReceipt fields (`reviewedFingerprintSha256`, `freshFingerprintSha256`, exposure vector, `artifacts.rgb.sha256`, `storageTransform`) | The app's display of the bridge's `scan.frameCompleted.receipt`; the exact on-disk location of a stored receipt is whatever the active project's manifest stores — this runbook does not invent it | The displayed receipt values |
| Telemetry JSONL lines | `~/.scanstudio/hw-telemetry/` | The captured frame's `enter`/`exit` lines |
| `attempts_root` directory (if present) | `~/.scanstudio/coolscanpy-attempts/<uuid>/` | Directory presence / name |
| App log / console output for the session | The app's own log/console | The session log for the live sequence |

### Known-good vs known-bad outcomes

Record which of these was observed, quoting the app's text exactly:

- Known-good eject outcome: the literal `{}` result — "{} means confirmed
  ejected, never anything less. A transport that reports the film did not come
  out, a capability-gated no-op, or any accepted-without-progress outcome
  surfaces as a typed error, never as {}. This rule exists because an LS-5000
  can acknowledge an eject command while the parked mechanism does not
  actuate." (BRIDGE.md, device.eject)
- Known-bad eject outcome: `EJECT_FAILED` — "EJECT_FAILED — the eject could not
  run or the transport reported not-ejected. On the current CoolscanPy pin a
  real eject needs the [scanner] extra plus SANE in the bridge's own
  environment, so on a rig without them every real device.eject is this error,
  with the message naming the missing dependency." (BRIDGE.md, device.eject)
- Known-bad eject outcome: `FEEDER_PARKED` — "FEEDER_PARKED — the typed stalled
  outcome: the driver's traced eject reported accepted-without-confirmed-clear
  (CoolscanPy FeederParked). The film state is unknown-but-likely-inside, the
  session is left untouched, and a power cycle is the only demonstrated
  recovery. A client must NEVER auto-retry this (or any) eject outcome — retry
  decisions belong to the operator at the machine." (BRIDGE.md, device.eject)
  The owner alone decides the recovery — never auto-retry an eject outcome.
- Known-bad scan-time outcome: a `hardware.anomaly` event — "Bounded retries.
  A scan.start slot whose fine-scan attempt raises CoolscanPy's transport-smear
  fault is retried up to 2 additional times (3 attempts total), with a
  scan.frameRetrying event before each retry. If the retry budget is
  exhausted, the bridge runs the anomaly halt below and the slot's terminal
  error is TRANSPORT_SMEAR_DETECTED." and "Anomaly halt. Triggered by:
  FeederParked, FingerprintRefused, BatchIntegrityError, GeometryValidationError,
  SplitAlignmentError, or a retry-exhausted transport smear. Sequence:
  best-effort eject ..., release the lane, write a telemetry entry, emit
  hardware.anomaly, fail the job." (BRIDGE.md, SAFE-02 guardrails)
