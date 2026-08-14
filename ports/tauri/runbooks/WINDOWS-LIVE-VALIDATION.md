# Windows Live-Hardware Validation Runbook (HW-02)

This runbook extends Phase 8's Windows→WSL2 lane setup (runbooks/
WINDOWS-WSL-LANE.md) into the live-hardware validation procedure for the
Windows/WSL2/usbipd lane: the Phase 8 prerequisite, a checker pre-flight, the
identical STOP-gated live sequence as HW-01, three Windows-specific reliability
gates (9P throughput, staging sha256 verification, and the two-cycle usbipd
stability gate), and an evidence checklist. No step here is executed by any
automated process — every instruction, including everything past the STOP
banner, is phrased as something the owner does at the machine. Every statement
about what the scanner or bridge does is either a verbatim BRIDGE.md contract
sentence (cited by section) or phrased as "record what you observe".

## Prerequisite

Before starting this document, runbooks/WINDOWS-WSL-LANE.md (Phase 8) must
already be all-green in the app's setup checker screen. This runbook does not
repeat that setup — it assumes WSL2 with the pinned Ubuntu-24.04 distro, the
bridge bundle installed inside WSL, usbipd-win installed and bound, and the
WebView2 runtime present.

This runs on a Windows VM with the Nikon Scan toolchain already installed (or
a clone of one). Attaching the LS-5000 to WSL2 via `usbipd attach` takes the
device away from any Nikon Scan/USBPcap workflow running on that same VM for
as long as it stays attached; this is reversible at any time via `usbipd
detach --busid <busid>`. No driver is swapped or replaced by the WSL lane.

### Checker pre-flight

Confirm each row of the app's setup checker is green before continuing. The
five ids below are the literal id strings the checker rows carry, pinned in
`app/src-tauri/src/wsl/checker.rs`:

1. confirm the checker row `wsl-status` is green — it verifies
   `wsl.exe --status` reports WSL2 with the Ubuntu-24.04 default distro.
2. confirm the checker row `bridge-which` is green — it verifies the bridge
   entrypoint resolves on PATH inside WSL.
3. confirm the checker row `bridge-version` is green — it verifies the bridge
   entrypoint launches and exits cleanly (bridge presence/version).
4. confirm the checker row `bridge-identity` is green — the deployed
   bridge's own interpreter runs the driver's capture-bundle
   self-check over every pinned component of the copy it actually imports,
   and the imported pin table (`bundle.py`) must hash byte-identically to
   the installed payload's CorrespondingSource copy. The first live Windows
   validation found a stale bridge (inherited through a VM clone) that
   stayed green on the presence/startup probes for an entire session and
   then refused its first real capture on bundle identity; this row binds
   the deployed bridge to the installed ScanStudio version so that state is
   visible before any capture. Red here means: re-run
   `install-bridge-wsl.sh --force`. A dev or portable run without the
   packaged payload reports Unknown, not red.
5. confirm the checker row `usbipd-attach` is green — it verifies `usbipd
   list` shows the LS-5000 (VID:PID `04b0:4002`) attached to WSL.
6. confirm the checker row `webview2` is green — it verifies the WebView2
   runtime is present via the registry probe.

(The same six probe ids are declared in `app/src-tauri/src/wsl/checker.rs`
as the `PROBE_IDS` constant with underscore spellings — `wsl_status`,
`bridge_which`, `bridge_version`, `bridge_identity`, `usbipd_attach`,
`webview2` — while the checker rows themselves carry the hyphenated id
strings enumerated above.)

Engine log: the app tees engine diagnostics to
`scanstudio-engine.log` (one rotation to `scanstudio-engine.log.1`) in the
platform application-log directory — on Windows,
`%LOCALAPPDATA%\com.scanstudio.desktop\logs`. When a Start-menu launch
misbehaves with nothing on screen, read that file first.

Pre-flight re-attach check: `usbipd attach` does not survive a reboot, a
replug, or a usbipd service restart — only the one-time `usbipd bind` is
durable. The owner runs `usbipd list` to confirm the LS-5000 still shows
attached to the WSL distro before continuing, re-attaching if needed:

`usbipd attach --wsl Ubuntu-24.04 --busid=<busid>`

## Scheduling and Safety Preconditions

Before any live step, the owner reads and accepts the same two preconditions as
HW-01:

1. Exactly one LS-5000 exists and is currently attached to, and mid-campaign
   on, the owner's macOS setup. This runbook's live section cannot begin until
   that campaign frees the scanner and the owner makes the single LS-5000
   available to this lane. Do not schedule assuming concurrent access — there
   is one scanner, and live work serializes behind the current macOS campaign.
2. Once a strip is loaded for the live sequence, a loaded strip may auto-eject
   after an unknown idle interval. This document intentionally states no
   specific auto-eject timeout, because no such number is known to be true. If
   the strip ejects mid-runbook, treat the roll's prior preview/approval state
   as lost and restart from the preview step after physically refeeding the
   strip.

## STOP — LIVE HARDWARE STEPS BELOW

Everything above this line is safe to prepare without moving film or arming the
motion latch. Everything below is for the owner only, physically present at the
machine. No step below this line is a task for an agent, a script, or any
automated process — every instruction below is phrased as something the owner
does.

## Gate (i): 9P Throughput Measurement

Immediately after the banner, the owner takes a pre-flight measurement. This
step does not move film or arm the latch — it is a filesystem write test only.

From inside the same WSL2 Ubuntu-24.04 shell the bridge runs in, the owner
runs:

`dd if=/dev/zero of=/mnt/c/<Windows-user-profile>/ScanStudioTest/test.tiff bs=1M count=130 conv=fsync`

The owner times it and records the resulting MB/s in the evidence table below.
Note: ~12.5 MB/s for a 100MB file is the benchmarked reference point this
project designed around (9P is a correctness-first protocol, not a fast one). A
much slower number on the day is itself useful data, not a failure by itself —
record what you observe and keep the number.

## [e] Live Sequence (Owner Only)

The owner performs the following steps in order, at the machine, using a
junk/test roll (not archival material), and runs the preview→eject span twice
to exercise the usbipd stability gate.

### Cycle 1

**e1. Arm and launch one supervised owner session.** The owner first fully
quits every running ScanStudio process. From the Windows Start menu, the owner
opens the separately named **ScanStudio Hardware Session** shortcut. For a
portable build, the owner double-clicks
`Start-ScanStudio-Hardware-Session.cmd` beside the extracted
`scanstudio-app.exe`. The owner keeps the launcher console open and enters the
explicit name of the junk/test media actually loaded, for example `junk-roll`.

The owner does not run either launcher as administrator and does not create a
persistent user/system environment variable. The launcher pins
`Ubuntu-24.04`, refuses if a ScanStudio app/engine, WSL bridge, launcher lock,
or motion-latch object already exists, atomically creates a token-owned regular
latch containing the media name, and gives `SCANSTUDIO_HW_MOTION=1` only to the
new child app process. It strips inherited state/base-directory overrides and
their `WSLENV` entries, plus any `HOME` entry in `WSLENV`, so both launcher and
bridge use the same fixed `~/.scanstudio` lane.
The ordinary **ScanStudio** Start-menu shortcut and a direct Explorer launch
remain unarmed. The setup checker's **Check scanner** action refreshes status
only and cannot arm an already-running process.

The app preserves unrelated `WSLENV` entries and adds
`SCANSTUDIO_HW_MOTION/u` for its engine child; this carries the exact value
through `wsl.exe -d Ubuntu-24.04 -e scanstudio-bridge`. The launcher waits for
that exact app child and, when it exits, removes the WSL latch only if the
unique session token and media content are still an exact match. This mirrors
the armed-latch contract:

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

**e5. Capture one frame — Gate (ii): Staging-Mode Verification.** The owner
captures that one frame using the fixed recipe, to a scratch output destination
the owner chooses (not a permanent archive location). The recipe is fixed, not
client-configurable:

> The only wired `material: "colorNegative"` combination is fixed:
> `resolutionDpi: 4000`, `bitDepth: 16`, `multisamplePasses: 4`, `channels:
> "rgbi"`, `autofocus: true`, `autoExposure: true` — fixed by the LS-5000's
> single-pass protocol, not client-configurable. (BRIDGE.md, Recipe
> constraints)

After the capture completes, the owner confirms the TIFF has landed at the
Windows destination and its sha256 matches the receipt's `artifacts.rgb.sha256`
field (ArtifactEvidence.sha256) before treating the capture as done. Record the
two hash values and the pass/fail result in the evidence table below.

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

### Cycle 2 — Gate (iii): usbipd Two-Cycle Stability Gate

The owner repeats e3 through e7 (preview through eject) a second time with no
`usbipd detach`/`usbipd attach` and no physical replug in between.

- Pass condition: both cycles complete without a detach/reattach or physical
  replug being needed.
- Fail condition: a mid-cycle-2 failure matching the "works once then fails"
  signature (see Known Windows-Lane Risks below).

A Gate (iii) failure is a documented lane failure with a discussed fallback —
never an improvised retry loop.

**After Cycle 2**, the owner records the checker's telemetry max-read line
verbatim into the evidence table. On the current CoolscanPy pin the expected
reading is the checker's honest "no size data recorded..." message — record
whatever it actually says. ONLY IF Gate (iii) failed, the owner additionally
collects the bridge stderr and any `CountedBulkReadError` text (those carry
transferred byte counts) as the failure evidence.

After banking the evidence, the owner fully quits the armed ScanStudio process
and waits for the launcher console to report `Hardware session disarmed.` The
owner confirms `~/.scanstudio/hw-motion-armed` is absent inside Ubuntu before
pressing a key to close that paused console. A subsequent normal app launch is
unarmed. If the latch is still present, the owner stops: the launcher
deliberately will not overwrite a changed or foreign latch. The owner inspects
it and removes it only after confirming no owner session or orphan bridge is
running and the physical scanner state is known.

## Known Windows-Lane Risks (carry verbatim)

In the owner's own words, but without softening the facts, the two usbipd-win
risk items this lane is designed around:

- usbipd-win issue #504: bulk reads over ~4MB (specifically, over ~4,194,304
  bytes) can fail. The failure surfaces as a libusb "insufficient memory"
  error originating on the usbipd/WSL side before the request reaches the
  Windows USB stack.
- usbipd-win issues #581 and #180: a device can work once, then need a
  `usbipd detach --busid <busid>` + re-attach, or a physical replug, before it
  works again.

A Gate (iii) failure matching this works-once signature is a documented lane
failure with a fallback discussion — the v2 native-Windows-USB lane, tracked as
DIST-01/DIST-03 in REQUIREMENTS.md — never an improvised retry loop.

Process-tree note: killing `wsl.exe` does not reliably kill the Linux-side
bridge. The hardware-session launcher checks `/proc/*/cmdline` for the exact
installed bridge entrypoint before and after latch acquisition. The setup
checker's `bridge-which`/`bridge-version` probes prove installation and startup,
not orphan absence. If the launcher console closes abnormally, its Windows job
terminates the Windows descendants and its detached guardian attempts an
ownership-matched latch release; neither action proves an in-flight Linux
operation stopped. The owner stops and inspects the physical scanner state. If
the bridge or latch survived, `wsl.exe --terminate Ubuntu-24.04` is the
last-resort orphan recovery. The owner then starts one clean Ubuntu-24.04 shell
before any ScanStudio app or bridge, verifies no bridge process exists,
inspects and removes only the known stale
`~/.scanstudio/.hw-motion-launcher-operation-lock` directory or latch, leaves
that shell, and re-attaches per Phase 8. A stale lock is never removed merely
because it is old; terminating the old distro instance first is the proof that
no old helper still holds it.

## [f] Evidence Checklist

| Item | Where to find it | Keep for the record |
| --- | --- | --- |
| ScanReceipt fields (`reviewedFingerprintSha256`, `freshFingerprintSha256`, exposure vector, `artifacts.rgb.sha256`, `storageTransform`) | The app's display of the bridge's `scan.frameCompleted.receipt`; the exact on-disk location of a stored receipt is whatever the active project's manifest stores — this runbook does not invent it | The displayed receipt values |
| Gate (i) 9P throughput | the timed `dd` run | the measured MB/s |
| Gate (ii) sha256-match result | the landed Windows TIFF vs the receipt's `artifacts.rgb.sha256` | pass/fail plus the two hash values |
| Gate (iii) outcome | the two completed cycles | pass / documented lane failure, plus the recorded max-single-read size |
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
