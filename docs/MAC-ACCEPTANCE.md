# Mac acceptance and recovery

Current acceptance targets **Apple Silicon (M-series, arm64) only**, macOS 14
(Sonoma) or newer. Intel Macs, Windows, and Linux are retired platforms; consult
[upstream NegPy compatibility guidance](https://github.com/marcinz606/NegPy#readme)
without assuming scanner compatibility. Historical release assets and notes
remain historical evidence. See [hardware support](HARDWARE-SUPPORT.md) for the
separate package, discovery, preview, and capture evidence.

## Executable software gate

From the repository root, against the exact packaged app being evaluated:

```sh
app="/absolute/path/to/ScanStudio.app"
"$app/Contents/Resources/BridgeRuntime/python/bin/python3.13" -I -B \
  scripts/verify_mac_acceptance.py "$app" \
  --report "/absolute/path/to/new-mac-acceptance.json"
```

The report's parent directory must exist and its filename must be new. Omit
`--report` to emit JSON only to stdout. Exit 0 means all software checks passed;
nonzero is a failed gate. The command performs no build or installation. It runs
the packaged engine and uses the same app's isolated Python/OpenCV runtime to
fully decode images, with no host Python imaging dependency.

The central `app/ScanStudio/scripts/test_packaged_bridge.sh` gate invokes this
script with its relocated app and bundled runtime, before the final codesign
verification. Thus `make package` (root or app directory),
`make -C app/ScanStudio package-check`, packaged CI, the macOS 14 floor check,
and signed-package verification automatically include acceptance. DMG packaging
also calls that gate against the mounted app, so the same test covers the DMG
contents. Separate workflow invocations are unnecessary. Retain the JSON stdout
in the gate logs, or use the standalone command's `--report` for a separate
record alongside that run's artifact hashes, provenance and updater evidence.
This test and its packaged CLI leg do not replace signature,
notarization, supported-OS binary load-command, same-run provenance, exact-tag,
or updater verification. It checks the declared macOS floor is 14.0 and the app,
engine, and Python executables are arm64 only; a pass on newer macOS does not
establish execution on macOS 14.

The gate creates a disposable roll under a unique path containing spaces and
`#`. HOME, TMPDIR, and child environment are isolated. No bridge command or
hardware-arming settings are inherited; only `sim-ls5000-0` is selected. It never
launches the native app or commands scanner movement.

1. Create a three-frame C-41 project and explicitly request preview for frames
   1–3. Validate correlated thumbnail/completion events and idle transport.
   Simulator thumbnails are brightness/tint descriptors, not real film images.
   Explicitly request and fully decode the synthetic whole-strip PNG (810×96).
2. Start a three-frame batch at 100 DPI, 16-bit RGB, one pass. While frame 1 is
   active, request **stop after current frame**. Require exactly frame 1 complete
   and the batch stopped, with no failed frames.
3. Check the persisted receipt and fully decode its archive TIFF, positive TIFF,
   and preview JPEG. Dimensions must be 99×149; TIFFs must decode to 16-bit RGB,
   and the JPEG to 8-bit RGB. These are simulator geometry/format contracts,
   not image-quality thresholds.
4. Shut down, start a fresh engine, reopen the same project, and require pending
   frames `[2, 3]`. Start those frames and SIGKILL only this simulator engine
   after observing frame 2 active, before its completion.
5. Start another engine, reopen, and require frame 1's receipt/output unchanged
   and frames `[2, 3]` still pending. This verifies a real interrupted process,
   not a fabricated manifest or a graceful shutdown masquerading as a crash.
6. Place a sentinel regular file where an output directory's parent is needed.
   Require scan dispatch refusal, sentinel preservation, and unchanged pending
   frames. This exercises a deterministic unusable destination even under
   elevated permissions; it does not simulate full disk, unplugged volumes,
   network failures, or a disk failure midway through publication.
7. Resume only engine-reported pending frames and require all three complete.
   Fully decode all nine outputs. Every receipt must match the output's SHA-256,
   byte length, inode, and volume identity. Frame 1 must retain its original
   receipt, hashes, sizes, inode, and nanosecond modification times; each frame
   must have exactly one receipt. Identical-byte rewrites cannot silently pass.
8. Run the packaged `Contents/MacOS/scanstudio-cli` with `host --simulator`
   against a short gate-created private socket and detached headless host. The
   simulator host bypasses the real hardware bootstrap and scrubs bridge state.
   The CLI performs the same
   simulator discovery, connect, preview, selection, save, scan, receipt, and
   decode checks through `roll run`; its CLI envelope, run receipt, and decoded
   outputs are checked alongside the engine leg. The simulator device is
   `sim-ls5000-0`; this step does not move a scanner.

Only three small completed captures are produced; archive capture-package copies
are disabled. Each output is capped by a 2 MB verification check. The process has
30-second RPC/decoder deadlines and a 180-second overall budget, with child
termination and temporary-directory cleanup on failure. Normal execution takes
seconds. The JSON records engine/runtime hashes, OS, version, project identity,
relative output names and measured file evidence; the temporary images are
removed. `hardwareAcceptance` is always `NOT RUN`.

Run the independent verifier regression tests with:

```sh
python3 -m unittest discover -s scripts/tests -p test_verify_mac_acceptance.py -v
```

Those tests check failure handling and need no package or native rebuild. The
existing `scripts/smoke_project_persistence.py` remains the smaller
create/mutate/reopen/overwrite-refusal smoke; the acceptance gate uses the same
NDJSON seam with asynchronous event handling, as the canonical engine's
`tests/end_to_end_sim.rs` does. No Swift or Rust rebuild is needed.

## Optional offline real-frame evidence

The narrowly inspected protocol fixtures are JSON wire examples; the engine's
`resources/nikonlook-v2` contains model/provenance JSON, not a real scan corpus.
`app/ScanStudio/engine/tests/nikonlook_v2_fixture.rs` already provides an ignored,
external-fixture comparison against a registered Nikon reference. It requires
explicit archive/reference paths, decoded-content hashes and registration
parameters. No external photo folders were searched and that real-frame test
was not run for this gate. If known fixtures are supplied later, reuse that test
and its existing measured criteria; retain originals and record the exact input
hashes. Offline rendering cannot prove current scanner focus or film transport.

## Attended hardware protocol

Use the supported LS-5000 color-roll workflow, a known expendable test roll,
and the normal app controls with an operator present. The user may explicitly
authorize the assistant to operate the final run, including preview, capture
and resume, once the scanner is connected. Before motion, satisfy the current
app readiness/attendance gates and obtain the operator's confirmation of the
physical state. Monitoring alone does not authorize motion. Do not infer a
hardware pass from simulator output, a detected device, or a previous release.
Record each boundary and stop on a refusal or uncertain physical state; follow
the app's explicit recovery instructions before any further physical operation.
Do not repeat the automated SIGKILL experiment on real hardware as part of this
protocol.

Before starting, record the exact DMG hash, app version, Apple Silicon model,
macOS version, scanner/firmware, adapter/holder, film stock/process and frame IDs.
Choose and identify the reference scans or prints and the viewing application,
display/profile, zoom and intended output. Agree the intended-use acceptance
criteria with the reviewer before inspection; no universal subjective score or
invented numerical threshold is implied here.

| Boundary / inspection | What the operator records |
| --- | --- |
| Install and launch | Signed DMG identity; launch result; permission/error text; app shown as the intended version. |
| Connect and explicit preview | Selected scanner and holder; requested frame range; preview count/order; warnings and any operator approvals. Loading a project alone must not be counted as preview evidence. |
| Frame boundaries | Compare preview with retained captures, checking first/middle/last frames and varied spacing; missing/duplicate frames, overlaps, clipping, orientation, crop and scene-edge loss. Preserve uncropped originals and identify any manual adjustment. |
| Focus | Inspect grain and fine scene detail at a recorded zoom in the center and corners; compare identified reference regions; record softness, focus inconsistency and frame IDs. Do not use the tiny simulator images to assess focus. |
| Color and tone | Review the positive in a color-managed viewer against the identified reference; record neutral/skin-tone behavior where present, casts, highlight/shadow clipping and scene-dependent differences. Record film process and render/profile settings. |
| Dust / IR treatment | Inspect known dust/scratch regions and fine real detail; record residual dust, halos, texture loss or mistaken removal. Compare preserved master/reference and derivative; record whether IR/ICE was used and supported for the material. |
| Saved evidence | Open actual retained files, record pixel dimensions/bit depth, receipt identity and hashes; distinguish untouched archive from cropped/processed derivatives. |
| Attended stop and reopen | Use the app's stop-after-current-frame control. Record last completed frame and pending list, then reopen when the app reports it safe. Verify retained files/receipts are unchanged. |
| Resume | Review the app's recovery/approval guidance and physical state before the user or explicitly authorized assistant invokes app resume. Record pending-only completion, no completed-file overwrite, any refeed instruction and the resulting evidence. |
| Unexpected interruption | If encountered naturally, retain diagnostics and last completed receipts; record displayed recovery instructions and operator action. A safe refusal is a recorded outcome, not an invitation to bypass a gate. |

## Full-roll final step: after the scanner is connected

**Not started.** Finish package/release verification first. When the user plugs
in the scanner and says they are ready, use one attended full-roll run as the
last acceptance step. The assistant can then continuously read the existing
local evidence during the active task and report progress or diagnose a stall.
No background monitor, scanner command, or automatic scan retry is armed by
this checklist.

### Ready and run (operator, with authorized assistant help)

1. Open the verified ScanStudio app on the Apple Silicon Mac. Connect the
   LS-5000 and the correct roll-capable adapter; let the app identify the holder.
   Do not force a strip holder into a full-roll workflow. Keep the Mac powered
   and awake and the output drive connected throughout the run.
2. Choose the intended film process and a new, clearly named roll/output folder.
   Tell the assistant that folder's location. Keep **Master TIFF** enabled for
   recovery; **Full Capture Package** is optional extra evidence and uses more
   disk space. Check free space against the selected resolution, frame count
   and retained formats; the tiny simulator gate is not a full-roll size estimate.
3. Load the known test roll yourself following the scanner/app instructions.
   Explicitly request preview once, then check the detected count, order and
   first/middle/last boundaries. Resolve the app's review/alignment prompts;
   opening an old project does not establish a fresh hardware preview.
4. Select the intended frames, review the output settings, and start capture
   once. Stay nearby. Use the app's progress display for current frame/pass and
   ETA; the assistant watches the files below and reports new completed
   receipts, typed errors, transport anomalies or an unresolved call. A quiet
   log or slow frame alone is not permission to retry, eject or power-cycle.
5. At completion, compare completed/excluded/failed frames with the intended
   roll, then perform the focus/frame/color/dust checks above. Save the hardware
   record and any diagnostic bundle. A finished batch is not itself a visual
   image-quality pass.

### CLI-driven variant

When an operator chooses shell control, run `scripts/full_roll_cli.sh` after
the same readiness and physical-state checks. It records the app identity,
adapter, scanner status, command JSON, `roll run` receipt, manifest copy,
diagnostics export, and `SHA256SUMS` under `~/ScanStudio-QA/<UTC timestamp>/`.
With `--simulator`, the script starts `host --simulator` on a short private
socket with isolated HOME/bridge state and stops that owned host on exit. A
hardware run attaches the existing default GUI/headless host and selects a
discovered non-simulator device, so it never starts a competing hardware host.
The operator must supply `--film-loaded` and `--confirm-motion` themselves;
the script forwards those flags and never retries or performs an automatic
stop/eject/recovery action. The runbook has been exercised against the
stop/eject/recovery action. The simulator's `strip6` fixture produces six
preview frames, so the bounded passing invocation uses `--frame-count 6`; an
explicit mismatched count is preserved and fails at `roll.save` with the
receipt step details. The runbook has been exercised against the simulator
only. No attended hardware full-roll run has been performed through
`scripts/full_roll_cli.sh`; hardware acceptance remains **NOT RUN**.

### Existing evidence the assistant can watch (read-only)

These are production defaults, not new log paths. In Finder, **Go → Go to
Folder…** accepts `~/.scanstudio/`. Match files to this run's start time and
session/job identifiers; do not mix earlier sessions into the result.

| Location | Use and limitation |
| --- | --- |
| `<chosen roll folder>/manifest.json` | Durable per-frame `receipts`, output paths and available hash bindings; count complete frames and identify non-excluded frames without receipts. Re-read the file by name because persistence is atomic. A file appearing without a completed receipt is not proof of successful capture. |
| `~/.scanstudio/hw-telemetry/<bridge-session-id>.jsonl` | Append-only, flushed bridge records: `roll.preview`, `scan.start`, `scan.call`/`scan.phase` enter/exit, outcomes and anomalies. Follow the exact session file with `tail -F` or incremental reads; look for new sessions after reconnect. Correlate timestamps and `job_id` with the roll. Flushing is not a power-loss durability guarantee. |
| `~/.scanstudio/diagnostics/<app-session-id>.jsonl` | Recent app connection, preview and failure context. Defaults to **40 entries per session and 20 log files**; atomically rewritten, not append-only. Re-read snapshots by filename rather than relying on `tail -f` or a persistent file descriptor. |
| `~/.scanstudio/coolscanpy-attempts/<uuid>/` | Existing preview/capture attempt journals. Prefer the exact `attemptsRoot` reported in available receipt/telemetry evidence; preserve it on failure, never infer that the newest unrelated directory belongs to this roll. |
| `~/.scanstudio/previews/<uuid>/slot-0001.tif` (and other slots) | Existing hardware preview tiles, useful for boundary inspection; they are not finished scan outputs. |
| Operator-selected `ScanStudio-Diagnostics-<timestamp>.zip` | In the error/details panel, choose **Save Diagnostic Bundle…**. Contains `diagnostics.jsonl`, `report.txt`, `manifest.txt`, and available bounded evidence. The save dialog chooses its location; there is no automatic ZIP directory. Film content is excluded unless the operator explicitly includes the offered preview. |

The assistant should preserve small, timestamped copies of the manifest and
current logs in a separate acceptance-evidence folder at start, a stop/failure
and completion. Read each newly completed output once to verify its receipt
hash/readability as appropriate; do not repeatedly hash all full-resolution
images while capture is busy. Never edit the live manifest, receipts, journals
or image originals. Do not launch a second engine/bridge or invoke scanner RPCs
just to obtain status; the app owns that connection.

**Monitoring limitation:** there is no durable full-roll copy of every engine
progress/ETA event in the app diagnostic timeline. `scan.progress` updates
in-memory UI state; engine stderr is inherited by the app, with no dedicated
`engine.log` file established by `EngineClient`. Existing telemetry plus
manifest receipts suffice for this attended run's call/completion monitoring
and recovery diagnosis, but cannot reconstruct every UI percentage or recover
already-pruned app events. Capture small log snapshots during the run; do not
claim a complete raw event trace. No custom monitoring architecture is needed
for this acceptance scope.

### Stop or recover (operator and assistant)

- For an intentional pause, press **Stop** once and wait for the current frame
  to finish and the app to report the stopped batch. Keep completed outputs,
  receipts and attempt journals. The assistant records the last completed
  frame, remaining list and file hashes before any resume.
- If the app reports a failure or loses the scanner, save/copy its technical
  details and diagnostic bundle first. The assistant reads the matching logs
  and explains the typed failure. Follow the app's specific reconnect/refeed
  guidance; do not force quit or repeat physical scans to gather more evidence.
- Reopen the **same** saved roll after the app indicates it is safe. Complete
  any required fresh preview and operator approvals, then use **Resume Batch
  (N remaining)** when enabled. This action refreshes pending frames from the
  persisted project and omits completed/excluded frames. After the current
  readiness/attendance gates pass and the operator confirms physical state,
  either the user or the explicitly authorized assistant may invoke this app
  action. Reconnection alone
  does not restore physical film position or authorize resume. If the button
  stays disabled, resolve its displayed reason instead of starting the whole
  roll again.
- After resume, compare the original completed receipts and hashes with the
  preserved snapshots. Record failures or missing outputs for investigation;
  do not delete receipts to trick the app into re-scanning. No blind automatic
  retries or unbounded rescans. Crash/power-loss recovery may use explicitly
  authorized assistant operation after the same readiness/attendance gates and
  operator confirmation; the simulator SIGKILL test does not establish safe
  hardware repositioning.

Implementation references: [timeline retention](../app/ScanStudio/Sources/ScanStudioKit/SessionDiagnosticTimeline.swift),
[app progress and resume](../app/ScanStudio/Sources/ScanStudioKit/SessionModel.swift),
[engine stderr interface](../app/ScanStudio/Sources/ScanStudioKit/EngineClient.swift),
[bridge telemetry](../bridge/src/scanstudio_bridge/safety.py),
[attempt/preview locations](../bridge/src/scanstudio_bridge/transport/coolscanpy_transport.py),
and [persisted pending-frame contract](../app/ScanStudio/protocol/PROTOCOL.md#projectpendingframes).

## Hardware acceptance record template

Copy this template to a new evidence record. Keep original images immutable;
place comparisons, crops, annotated screenshots and reports in a separate
folder. Record failures and untested cases as such.

```text
Status: NOT RUN / PASS / FAIL / BLOCKED (choose after inspection)
Date/time and operator:
Reviewer and intended use:
DMG filename + SHA-256:
App version/build + software-gate report reference:
Apple Silicon model / macOS:
Scanner model / firmware / adapter / holder:
Film stock / process / roll ID / frame IDs:
Capture settings / render mode / profile / IR treatment:
Reference source, frame mapping and hashes:
Viewer / display / color profile / zoom:
Agreed intended-use criteria:

Install/launch: NOT RUN — evidence:
Connect/explicit preview: NOT RUN — evidence:
Frame count/order/boundaries: NOT RUN — evidence:
Focus center/corners: NOT RUN — regions + observations:
Color/tone: NOT RUN — regions + observations:
Dust/detail preservation: NOT RUN — regions + observations:
Saved dimensions/bit depth/receipt hashes: NOT RUN — evidence:
Stop/reopen/pending list: NOT RUN — evidence:
Attended resume/completed-output preservation: NOT RUN — evidence:
Unexpected interruption (if encountered): NOT OBSERVED — evidence:

Original capture/receipt locations and hashes:
Comparison/diagnostic record locations:
Failures, limitations, untested media or frames:
Recovery instructions shown and operator actions:
Reviewer decision, rationale, date and name:
```
