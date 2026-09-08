# ScanStudio CLI

`scanstudio-cli` drives the local ScanStudio control channel. It is a macOS
Apple Silicon tool and uses the same session gates as the GUI.

## Installation and running

The signed application contains the executable at:

```text
/Applications/ScanStudio.app/Contents/MacOS/scanstudio-cli
```

Run that file in place. The executable resolves its sibling
`scanstudio-engine` and its bundle identity together, so copying or symlinking
the Mach-O out of the bundle is unsupported. A copy or symlink breaks sibling
engine lookup and the binary's Gatekeeper story. To put the command on `PATH`,
run the repository installer while releasing an app:

```sh
bash scripts/install_cli_shim.sh --app /Applications/ScanStudio.app
```

The installer accepts `--app PATH`, `--prefix DIR`, `--name NAME`, and
`--uninstall`. Its default prefix is the first existing `$HOME/.local/bin` or
`$HOME/bin`, otherwise it creates `$HOME/.local/bin`. It never needs `sudo`,
never creates a symlink, and writes a small `exec` shim that keeps the signed
CLI inside the app. A prefix outside `$HOME` must be supplied explicitly.

Global options may be placed on every command:

```text
--socket PATH   use a control socket other than ~/.scanstudio/control.sock
--attach        require an existing host; never start one
--headless      require or start a headless host
--human         print indented text instead of JSON
--quiet         suppress --wait progress lines on stderr
```

## Output contract

Without `--human`, each ordinary command writes exactly one JSON object. It has
`schemaVersion`, `command`, `mode`, and `hardwareVerification`, plus exactly one of `result`, `error`,
or `event`. The streaming `events --follow` command writes one event envelope
per event until the host closes the connection.
Successful commands may also carry `hostStarted`, `hostPid`, and `logPath`.
`mode` is `attach-gui`, `attach-headless`, or `unreached`. An error carries
`code`, `message`, `recoverable`, and optional `guidance` and `gate`.

`--wait` writes changed `scan.progress` lines to stderr and leaves the final
JSON object on stdout. `--quiet` suppresses those progress lines. The CLI
never mixes progress text into JSON.

The complete wire surface covered by this guide is: `hello`, `status`,
`scanner.list`, `scanner.rescan`, `scanner.refresh`, `scanner.connect`,
`scanner.disconnect`, `preview.acquire`, `frames.list`, `frames.select`,
`frames.place`, `frames.include`, `frames.exclude`, `review.approve`, `review.cancel`,
`settings.get`, `settings.set`, `outputs.get`, `outputs.set`, `roll.save`,
`roll.open`, `roll.list`, `roll.solveExposure`, `roll.verify`, `roll.collect`,
`scan.start`, `scan.stop`, `scan.resume`,
`scanner.eject`, `diagnostics.export`, `events.subscribe`, and `job.get`.

The following are retained Phase 4 simulator captures, before the additive
Phase 5 `hardwareVerification` field. New output includes that live field as
`verified`, `unverified`, or `notConnected`. These historical examples are exact captures; Paths, timestamps, and PIDs are
environment-specific; the field names and values show the wire shape.

```json
{"command":"status","hostPid":12596,"hostStarted":false,"mode":"attach-headless","result":{"hardwareMotionReadiness":"notApplicable","lastControlRefusal":{"code":"INVALID_PARAMS","command":"sim.loadMedia","sequence":2,"timestamp":"2026-09-08T02:52:31Z"},"motionAllowed":true,"motionGuidance":"","pendingFrames":[],"previewComplete":false,"refeedRequired":false,"scanReadiness":"scannerDisconnected","scanReadinessReason":"Connect the scanner to scan.","selectedFrames":[]},"schemaVersion":1}
```

## Command reference

Each method name below is the wire method in `CONTROL.md`. Exit numbers are
the process exit status; a refusal is also rendered as an `error` envelope.

### `connect`, `disconnect`, and `rescan`

```text
connect [--device ID] [--allow-unverified-hardware] → scanner.connect
disconnect                  → scanner.disconnect
rescan                      → scanner.rescan
```

The connect opt-in is explicit for each CLI invocation; omitting it means false,
even when the GUI saved **Allow unverified scanners**. It permits only recognized
unverified candidates and does not authorize motion. The current driver pin is
0.7.7, which refuses that open with guidance to upgrade to 0.7.8 after its release.
See the [hardware matrix](HARDWARE-SUPPORT.md#testing-an-unverified-scanner).

These commands have no motion confirmation flag. They use exits `0, 65, 69,
70, 75`. `connect` may omit `--device`: it reuses the last selected device if still discovered, or requires one discovered device when no previous selection exists. It refuses if the previous device disappeared. `rescan` is the discovery operation.

```json
{"command":"scanner.rescan","hostPid":12596,"hostStarted":false,"mode":"attach-headless","result":{"devices":[{"connection":"USB (simulated)","deviceId":"sim-ls5000-0","firmware":"1.03-sim","kind":"simulated","model":"SUPER COOLSCAN 5000 ED","supported":true}]},"schemaVersion":1}
```

### `status`

```text
status [--refresh] [--job ID] → scanner.refresh, status, or job.get
```

Without `--refresh` this reads the in-memory `status` snapshot. `--refresh`
performs one live `scanner.refresh` first and moves nothing. `--job ID` uses
`job.get` and can query the live job or one of the last eight terminal jobs.
There is no confirmation flag. Exits are `0, 65, 69, 70, 75`.

### `preview`

```text
preview --film-loaded [--intent initial|replaceFilmProcess|refreshSavedProject]
        [--film-process positive|c41ColorNegative|bwNegative|kodachrome]
        → preview.acquire
```

`--film-loaded` is required. `--film-process` is required for
`replaceFilmProcess`. Exits are `0, 64, 65, 69, 70, 75, 77`.

```json
{"command":"preview.acquire","error":{"code":"CONFIRMATION_REQUIRED","guidance":"Confirm film is physically loaded in the scanner, then retry with --film-loaded.","message":"\"preview\" requires --film-loaded.","recoverable":false},"hostStarted":false,"mode":"unreached","schemaVersion":1}
```

### `frames`

```text
frames list                                      → frames.list
frames select RANGE|--all|--none                 → frames.select
frames select --skip-blank [--blank-threshold 0..1]
                                                  → frames.list, frames.select
frames place SLOT --row-offset ROWS               → frames.place
frames place --from placement.json                → frames.place
frames place --replay                             → frames.place
frames include RANGE                             → frames.include
frames exclude RANGE                             → frames.exclude
```

`RANGE` uses CUPS syntax such as `1-6,9`. `select` requires exactly one of a
range, `--all`, `--none`, or `--skip-blank`; `--blank-threshold` only applies
with `--skip-blank`. Include/exclude apply a range one index at a time and
report partial application; a range that stops at a refusal exits 65. These
commands have no motion flag. The normal exits are `0, 64, 65, 69, 70, 75`.

`frames place` requires an open project. `ROWS` is an absolute offset in native
preview rows: slot 1 accepts `0...144`; later slots accept `-144...144`.
`placement.json` has this shape; either `rows` or `placements` may be omitted:

```json
{
  "rows": [0, 100, 200],
  "placements": [
    {"slot": 2, "rowOffset": -4}
  ]
}
```

Boundary rows are nonnegative, unique, strictly increasing native preview-row
positions. They are sent through `roll.manualFrames` before offsets are applied.
Offsets then run sequentially in ascending slot order through
`roll.setSpacingOffset` and `project.setFrameAlignment`. `--replay` reapplies the
open project's saved nonzero offsets to the exact current completed preview; it
refuses a stale or partial preview before making a spacing request. Placement
stops on its first refusal and does not retry. It causes no scanner motion.

### `review`

```text
review approve --confirm-motion → review.approve
review cancel                   → review.cancel
```

`review approve` starts the pending reviewed scan and requires
`--confirm-motion`; `review cancel` clears the pending review without motion
and takes no flag. Approve exits `0, 65, 69, 70, 75, 77`; cancel exits
`0, 65, 69, 70, 75`.

### `settings` and `outputs`

```text
settings get                   → settings.get
settings set [recipe options]  → settings.set
outputs get                    → outputs.get
outputs set [recipe options]   → outputs.set
```

`settings set` and `outputs set` are read-modify-write operations. `settings
set` accepts `--from-json`, `--resolution`, `--bit-depth`, `--multisample`,
`--channels`, `--film-process`, `--autofocus`/`--no-autofocus`,
`--auto-exposure`/`--no-auto-exposure`, `--digital-ice`/`--no-digital-ice`,
and `--digital-ice-mode`. `outputs set` accepts `--from-json`,
`--master-enabled`/`--no-master-enabled`, `--master-destination`,
`--raw-enabled`/`--no-raw-enabled`, `--raw-destination`,
`--positive-enabled`/`--no-positive-enabled`, `--positive-destination`,
`--preview-enabled`/`--no-preview-enabled`, and `--preview-destination`.
They take no motion flag and exit `0, 65, 69, 70, 75`.

### `preset`

```text
preset save NAME    → settings.get, outputs.get, local JSON write
preset list          → local JSON read only
preset apply NAME    → settings.get, settings.set, outputs.set
scan --preset NAME   → preset apply, then scan.start
```

Presets are versioned JSON files in `~/.scanstudio/presets/`. They contain
the existing capture, processing, and output recipes; confirmations, scanner
identity, and unverified-hardware authorization are never stored. `save`
reads settings and outputs through the control socket but sends no scanner
request. `list` is entirely local. `apply` changes settings and outputs
without moving film. Applying a preset preserves the currently persisted
manual exposure lock; the preset cannot replace that authority. `scan
--preset` still requires `--confirm-motion` and applies the preset before the
existing scan readiness and motion workflow. The GUI Scan Settings panel
lists the same files and uses the same recipe application path. The two
existing set requests are sequential, so a later refusal can leave the first
recipe applied; the command reports that refusal and never starts a scan.

### `wait`

```text
wait --for film-present|film-absent|idle|job-done|registered [--timeout SECONDS]
```

`wait` subscribes once to the control event stream, evaluates the subscribe
snapshot, and then waits on later typed snapshots. It never polls, refreshes,
or starts a host for an observational command. A satisfied condition exits
`0`; an expired timeout emits `WAIT_TIMEOUT` and exits `124`; an established
host connection that reaches EOF emits the existing `control.hostExited`
terminal and exits `76`. Unknown status values never satisfy a condition.

### `link health` and `session export`

```text
link health [--minutes 15]
session export --to /existing/parent/new.zip
```

`link health` summarizes retained bridge telemetry from the session inventory
without probing the scanner; missing telemetry is reported as unknown. The
window is 1–1440 minutes and defaults to 15. `session export` writes a
create-only ZIP whose parent directory already exists, preserving source
hashes and explicit missing-source reasons; it refuses an existing archive.

### `roll`

```text
roll save --name NAME --carrier mounted|strip6|roll36 --frame-count N
           --film-process PROCESS --confirm-motion [--wait] [--auto-approve]
           → roll.save, status, review.approve, job.get
roll save --name NAME --carrier CARRIER --frame-count N
           --film-process PROCESS --no-scan → roll.save
roll open DIRECTORY          → roll.open
roll list                    → roll.list
```

`roll save` creates a project and starts scanning, so `--confirm-motion` is
required. With `--no-scan`, it only creates the project and returns
`outcome: "saved"`; no motion confirmation is needed. `--no-scan` cannot be
combined with `--wait` or `--auto-approve`.
`--auto-approve` independently requires that flag and approves a
paused review only when every flagged frame clears the confidence threshold.
`--wait` returns the terminal job result; `--no-wait` returns after start.
Save exits `0, 65, 69, 70, 75, 77`; open/list exit `0, 65, 69, 70, 75`.

### `host`

```text
host [--simulator] [--detach] [--engine PATH] [--log PATH]
                                               → resident headless host
host run [--detach] [--engine PATH] [--log PATH] → explicit resident form
host stop                                      → verified pidfile stop
```

`host` stays attached unless `--detach` is supplied. `--simulator` explicitly
bypasses the real hardware bootstrap, scrubs bridge/hardware state, and is the
only supported way to create an isolated simulator host. `--engine` is a
development/test override and `--log` chooses the detached log path. `host`
commands do not require motion flags. `host` exits `0, 65, 69, 70, 75`;
`host stop` exits `0, 69, 70, 75`.

### Calibration commands

```text
roll solve-exposure --frame N --confirm-motion → roll.solveExposure
roll verify [--pass TOKEN] [--exposure-identical] [--no-clipping] → roll.verify
roll collect --to NEW_DIRECTORY --stock STOCK --pass TOKEN --slot-map MAP.json
             [--operator NAME] → roll.collect
```

`solve-exposure` measures inside the current real held preview session and
waits for its terminal result. A successful measurement persists the RGB
exposure lock in the open project. Scans with auto exposure disabled reuse
that lock across separate CLI invocations; enabling auto exposure omits the
override and preserves the saved lock for later use. IR remains metered.
The simulator and older drivers without held metering refuse this command.

`verify` reads retained file bindings, lengths and SHA-256 hashes. Optional
exposure checks compare commanded RGB ticks within each pass; clipping checks
use receipt telemetry. Missing evidence is `unknown`, never a fabricated
pass. It prints the complete report and exits 65 for `fail` or `unknown`.

`collect` copies one exact pass into a fresh directory, preserving originals.
The slot map is a JSON object such as `{"1":1,"2":2}` with unique positive
slots and physical frame numbers. Raw-enabled receipts require RGB16 TIFF
and its tagged Gray16 IR sidecar; raw-disabled Pass B collects its available
positive, meter and receipt. The output includes `roll-metadata.json` and
`file-hashes.txt`. Missing or changed bound evidence and existing destinations
are refused. Collection requires project-relative capture bindings; older
receipts and independent raw destinations without those bindings cannot be
retroactively certified. Neither verification nor collection moves film.

### `roll run`

```text
roll run --name NAME --carrier mounted|strip6|roll36 [--frame-count N]
         --film-process PROCESS --film-loaded --confirm-motion
         [--skip-blank] [--auto-approve] [--wait|--no-wait]
         → scanner.refresh, status, preview.acquire, events.subscribe,
           frames.list, frames.select, roll.save, review.approve, job.get
```

This is the one-connection whole-roll walk: refresh/connect when needed,
preview, wait for `previewComplete`, select frames, save, resolve an optional
review, and wait for the job. Both `--film-loaded` and `--confirm-motion` are
required. It stops at the first refusal and never retries. Exits are `0, 64,
65, 69, 70, 75, 77`.

### `scan`, `stop`, `resume`, and `eject`

```text
scan --confirm-motion [--wait] [--frames RANGE] [--repeat COUNT] [--pass TOKEN]
     [--preset NAME]
                               → scan.start, job.get
scan --dry-run [--frames RANGE] → scan.preflight (no scan.start)
stop [--immediate]             → scan.stop
resume --confirm-motion [--wait] → scan.resume, job.get
resume --dry-run               → scan.preflight (no scan.resume)
eject --confirm-motion         → scanner.eject
```

The motion forms of `scan`, `resume`, and `eject` require `--confirm-motion`;
the two `--dry-run` forms are observational and do not open a motion request.
They report film, registration, readiness, writable destinations, and a
conservative space estimate (256 MiB per frame at 4000 dpi, scaled by
resolution, plus project/output headroom). A ready report exits `0`; a failed
gate report exits `65`. `scan --dry-run --preset NAME` is rejected locally;
apply the preset first, then inspect the effective settings. `stop` only stops
an existing job and starts no motion. Scan/resume/eject exit `0, 65, 69, 70,
75, 77`; stop exits `0, 65, 69, 70, 75`.

`--frames` accepts comma-separated indices and ranges, including previously
completed frames for an explicit rescan. `--repeat` accepts 1–100 and requires
`--pass` above 1. Repeats always wait: each starts only after the prior job
completed without frame errors. A refusal or stopped/failed job ends the
sequence without retrying it. Omitted frames use one snapshot of the initial
selection throughout the sequence.

A single pass keeps its token exactly. Repeats append a two-digit ordinal:
`--frames 20 --repeat 10 --pass Arep` produces `Arep01` through `Arep10`.
Receipts retain `passToken`; filename templates support `{stock}` and `{pass}`
(and `$Pass`). Existing `$Frame` keeps its four-digit width. All captures use
create-only output reservation and append receipts. Pass tokens allow 1–64
ASCII letters, digits, `.`, `_`, or `-`, excluding `.` and `..`. Invalid scan
ranges/repeat arguments exit 64 before connecting.

### `diagnostics`, `events`, and `sim`

```text
diagnostics export --to DIRECTORY → diagnostics.export
events --follow                   → events.subscribe
sim load-media [--carrier strip6|roll36] [--preview-fixture NAME]
                [--abort-at-frame N] [--abort-code CODE] → sim.loadMedia
```

Diagnostics requires an existing absolute directory with no `..` component.
`events` requires `--follow` and streams event envelopes until the host closes
the connection. `sim load-media` is simulator-only and never moves hardware.
Diagnostics exits `0, 64, 69, 70`; events exits `0, 64, 69, 70, 76`; simulator
setup uses `0, 65, 69, 70, 75`.

```json
{"command":"scanner.connect","hostPid":12596,"hostStarted":false,"mode":"attach-headless","result":{"alreadyConnected":false},"schemaVersion":1}
```

## Exit codes

| Exit | Meaning | Triggered by |
|------|---------|--------------|
| 0 | Success | |
| 64 | Usage / validation | ArgumentParser's own usage errors; channel `INVALID_PARAMS`; CLI-originated `INVALID_RANGE` (a malformed CUPS frame range, rejected before any connection opens) |
| 65 | Typed engine or gate error | `GATE_REFUSED`, `JOB_NOT_FOUND`, and every other engine- or bridge-passthrough code this repository does not individually enumerate — the documented default, not a fallback for an unhandled case; also a `--wait`ed job whose terminal state is `failed`; also `frames include`/`frames exclude <range>`'s own **partial-application rule (D-24/HEAD-12, additive)**: a range spanning more than one index that stops at a refused index always exits 65 regardless of that index's own code (for example an `INVALID_PARAMS` refusal, which alone would map to 64) — the caller's *range as a whole* did not apply, a different fact than what a single-request refusal of that code would normally mean |
| 69 | No host reachable | `HOST_UNREACHABLE` — the control socket could not be dialed at the given (or default) path |
| 70 | Internal error | Channel `UNKNOWN_COMMAND`; CLI-originated `INTERNAL` (an unexpected condition after a request already succeeded, for example a response that failed to decode) |
| 75 | Busy / conflict | `CONTROLLER_BUSY`, `HOST_ALREADY_RUNNING` |
| 76 | Established host connection closed | `control.hostExited` for streaming observers |
| 77 | Confirmation required | `CONFIRMATION_REQUIRED`, decided client-side at parse time — before any connection opens — for every motion-capable subcommand (D-11) |
| 78 | Schema / version mismatch | `SCHEMA_VERSION_MISMATCH`, `HELLO_REQUIRED` |
| 124 | Wait timeout | `WAIT_TIMEOUT` from `wait --for … --timeout …` |

`--wait` maps `completed` and `stopped` to 0 and a failed terminal job to 65.

## Confirmation and safety

The parse-time gates run before a socket opens and return 77: `preview` needs
`--film-loaded`; `review approve`, `roll save`, `scan`, `resume`, and `eject`
need `--confirm-motion`; `roll run` needs both flags. Each command repeats its
check in `run()` and the wire dispatcher checks the corresponding boolean too.
The CLI never retries, queues, ejects, power-cycles, or re-issues a physical
operation after a refusal.

## Attach, headless, and host lifecycle

Host selection uses a live socket connect followed by `hello`; it never treats
`stat` or a socket file's presence as proof of a host. The packaged default
host bootstrap reuses the GUI ScanStudioLauncher initialization and may reach
real hardware. The default is automatic: attach to a live GUI or headless host,
or start a detached headless host for a mutating command. `--attach` refuses
when no host answers. `--headless` refuses an existing GUI host and
starts/attaches only to a headless host. Use `host --simulator` with a private
socket for simulator work; do not use the default host bootstrap for that
purpose. Read-only
commands (`status`, `events`, `frames list`, settings/outputs get, `roll list`,
and `job.get`) never auto-start a host.

The envelope's `mode` names the host reached. `hostStarted` says this command
started it; `hostPid` is the hello-verified process ID; `logPath` is the
detached host log when one was started. `host --detach` starts a resident
headless host, and `host stop` reads `<socket>.pid`, verifies the live hello
reports the same headless PID, then signals it. The default files are
`~/.scanstudio/control.sock`, `~/.scanstudio/control.sock.pid`, and
`~/.scanstudio/logs/host.log`. Hardware scripts should attach this default
socket rather than starting a second private hardware host.

The host chmods the socket's containing directory to 0700 on every start and
the socket to 0600. Therefore `--socket` must point inside a directory
dedicated to this socket. Never point it at `/tmp` itself or a home directory;
the host will change that shared directory's permissions.

## Evidence locations

Each saved roll has a `manifest.json` in its project directory. `roll run`
writes a `cli-run-<timestamp>.json` receipt beside that manifest without
overwriting an existing receipt. `diagnostics export --to DIRECTORY` writes a
timestamped diagnostic bundle into the directory you provide. Host logs,
pidfiles, sockets, previews, and app diagnostics live under `~/.scanstudio/`.
Copy these files into a separate acceptance-evidence directory; never edit
receipts, manifests, journals, or image originals.

## Troubleshooting

- Exit 69 (`HOST_UNREACHABLE`): start ScanStudio or run `host --detach`,
  then retry with the same `--socket`; `--attach` intentionally never starts a
  host.
- Exit 75 (`CONTROLLER_BUSY`): read the error's `message` to see the operation
  holding arbitration. Wait for that operation or stop it deliberately; the
  CLI does not queue or retry the refused request.
- Exit 65 (`GATE_REFUSED` or a passthrough code): inspect `error.code`,
  `error.gate`, `error.guidance`, and `error.recoverable`; resolve the named
  readiness or review condition before a new request.
- Exit 77: supply the command's explicit motion flag. This is a local parse
  refusal and did not contact the host.
- Exit 78: the client and host schema versions disagree, or the connection
  did not complete `hello`; use the matching app and CLI bundle.
- After a crash, a stale socket is reclaimed only after a failed connect probe.
  The next host launch replaces the stale socket and writes a fresh pidfile;
  never remove a live host's socket by hand.
- `ENGINE_NOT_BUNDLED`: the executable is outside its signed bundle and cannot
  safely find the sibling engine. Run the CLI in place or install the supported
  `scripts/install_cli_shim.sh` exec shim; do not copy or symlink the Mach-O.
- `ENGINE_OVERRIDE_REFUSED`: a bundled CLI was given `--engine` or
  `SCANSTUDIO_ENGINE_PATH` that is not the signed sibling
  `Contents/MacOS/scanstudio-engine`. Remove the override and use the bundle.

The packaged acceptance gate runs the documented simulator sequence against
`sim-ls5000-0`; it does not establish a hardware or image-quality pass.
The runbook's `strip6` simulator fixture produces six preview frames, so its
bounded passing invocation uses `--frame-count 6`. `full_roll_cli.sh` preserves
an explicitly requested count; a count that does not match the selected
preview frames stops at `roll.save` and reports the failed receipt step.

Calibration scans can explicitly permit known blank slots with
`scan --on-frame-failure skip --allow-meter-refusal-slots RANGE`. The default
is stop. Only synchronized typed meter-controller refusals may be skipped;
other failures stop the job. Each skip is retained separately from capture
receipts and included by `roll collect`; an all-skipped pass has no measured
exposure/clipping result. Simulator scans refuse this hardware-only option.

`status --watch` emits an initial snapshot and subsequent film/registration
changes from one event subscription. It does not poll or refresh the scanner;
`--job` and `--refresh` cannot be combined with it. A new `previewOperationId`
distinguishes replacement previews. Both `status --watch` and `events --follow`
retain `control.dropped` notices. Established connection EOF emits one local
`control.hostExited` event and exits **76**. This means observation was lost;
it does not claim that an in-flight scan succeeded or failed. Ordinary local
shutdown after a finite command does not synthesize that event.

## Shell completion

The CLI's existing argument parser generates completion scripts; no plugin or
separate completion implementation is needed:

```sh
scanstudio-cli --generate-completion-script zsh > /tmp/_scanstudio-cli
scanstudio-cli --generate-completion-script fish > /tmp/scanstudio-cli.fish
```

Load the generated file through your shell's normal completion configuration.
Generation is offline and never connects to the scanner.

## Retained roll reports and host services

`roll report DIRECTORY --to /absolute/path/report.html` produces a self-contained
HTML contact sheet without connecting to a host. It verifies retained artifact
hashes, embeds available preview images, and refuses destination collisions.
Missing review evidence is labeled Unknown. Non-thumbnail files are verified
with streaming reads (1 GiB per artifact); embedded previews have a 32 MiB total
limit. The receipt hash describes the normalized decoded receipt, not the bytes
of the original manifest.

`host service generate --bundle /absolute/ScanStudio.app --to /absolute/host.plist`
only writes a new plist. `host service install --bundle /absolute/ScanStudio.app`
explicitly installs and bootstraps `com.scanstudio.headless` in the current
user's LaunchAgents directory; `host service remove` unloads and removes only
that marked service. Existing plists are never overwritten. Failed launchctl
operations retain the plist for inspection. The service starts the resident
host at login and uses private logs; it does not restart failed hosts or run a
scan job. Motion still requires an explicit CLI request and its confirmations.
