# Scan Studio Control Channel Protocol v1

Contract for the local control channel that lets a CLI, a script, or an agent drive a running ScanStudio app the same way the GUI does. Every command maps onto exactly one existing `SessionModel` workflow method — the same method the GUI calls — so the GUI and the control channel can never disagree about what is allowed. This file is canonical; Swift types live in `ScanStudioKit/ControlWireProtocol.swift`.

## Transport

- The wire grammar is line-framed NDJSON with the same envelope shapes as `PROTOCOL.md`'s engine protocol:
  - **Request** (caller → dispatcher): `{"id": <u64>, "method": "<name>", "params": {…}}`.
  - **Response** (dispatcher → caller): `{"id": <u64>, "result": {…}}` or `{"id": <u64>, "error": {"code": "<CODE>", "message": "<human text>", "recoverable": <bool>, "guidance": "<text>", "gate": "<name>"}}`. Every request gets exactly one response.
  - **Event** (dispatcher → caller, unsolicited): `{"event": "<name>", "payload": {…}}`. Events may interleave with responses.
- In Phase 1 the dispatcher is in-process and transport-agnostic by construction (D-06): it accepts a decoded request value and returns an encodable response value, so Phase 2's socket server and any in-process test harness call the same API.
- JSON field names are camelCase on the wire, matching `ControlWireProtocol.swift`'s property names one-to-one.
- **Socket path.** The default is `~/.scanstudio/control.sock` (`ControlSocketPath.defaultPath()`); `scanstudio-cli --socket <path>` overrides it for any command.
- **Permissions are asserted, never trusted to `umask`.** The containing directory (`~/.scanstudio/`) is `chmod`'d to `0700` on every server start, and the socket itself is `chmod`'d to `0600` immediately after `bind` — both re-asserted every start, even if the directory already existed with some other mode.
- **`sun_path` bound.** A path that would not fit in the platform's `sockaddr_un.sun_path` in under 104 bytes including the NUL terminator is refused before any socket call.
- **Symlink refusal.** A path that `lstat` reports as an existing symlink is refused rather than bound through — a pre-placed symlink at the socket path is attacker-influenceable state, and following it would bind somewhere other than the intended path.
- **Probe-then-reclaim, in this exact order,** on every `start(path:)`: validate the path → prepare (and `chmod`) its directory → acquire the bind-time lock (below) → **probe** by dialing the path (`connect(2)`) → if the probe succeeds, refuse to start (another host already owns the path) → only once the probe fails with `ENOENT` or `ECONNREFUSED` — proof nothing live owns the path — does the server `unlink` it → `socket`/`bind`/`chmod`/`listen` → release the lock. A stale socket left behind by a crash is therefore detected by a **failed connect**, never by `stat`: a crashed process's socket file is still present on disk and would satisfy any existence check, but only dialing it proves whether anything is actually listening.
- **Bind-time lock, not a liveness signal (WR-02).** The probe-then-reclaim sequence above has no atomicity of its own: two processes racing `start(path:)` in the same narrow window could both see the probe fail, both `unlink`, and both `bind` — the second's `unlink` could delete the first's just-bound socket file, and the second's own `bind()` then succeeds too, silently violating "a live probe refuses start" for the pair. `start(path:)` therefore holds an exclusive, non-blocking advisory `flock(LOCK_EX | LOCK_NB)` on `<socket path>.lock` (`0600`, created beside the socket, never `unlink`ed — only released) across the entire probe → unlink → bind critical section. Two concurrent starters at the same path can never both end up bound: whichever loses the lock is refused immediately with the same `EADDRINUSE`-shaped error a live-probe refusal uses. The lock is held only for the duration of `start(path:)` itself, never for the server's running lifetime — it says nothing about whether the bound socket is still alive later. **Liveness is, and remains, connect+hello only**: a process holding no lock at all (because it already finished `start(path:)` and is simply running) is exactly as live as ever; this lock only ever protects the moment of claiming the path.
- **Per-connection line bound.** A request line exceeding 1 MiB before a newline is refused with `INVALID_PARAMS`, and the connection is closed immediately after that refusal is written — never kept open past an oversized line.
- **Bounded outbound queue.** Each connection's outbound queue (responses and events not yet written) holds at most 256 entries. When no event can be dropped to stay within the bound, the slow connection is closed. While connected, only event lines (`control.snapshot`/`control.changed`) may be, drop-oldest, if a slow subscriber falls behind. A drop is never silent: the next event line on that connection is preceded by a `control.dropped` event naming how many were lost since the last notice. CLI-side handling of `control.dropped` (surfacing it to the operator, re-fetching a snapshot) is not built in Phase 2 — see OPS-10.

Every success and error response also carries top-level `hardwareVerification`:
`verified`, `unverified`, or `notConnected`. It reflects the live connected
session when the response is emitted, including refusals, and is independent of
host mode. Disconnected/unknown state must not be presented as verified hardware.

`scanner.connect.allowUnverifiedHardware` defaults to `false`, including omitted
legacy fields. CLI connect and roll-run paths explicitly pass their flag value;
a saved GUI opt-in does not authorize them. The opt-in admits only recognized
candidates, and changes no motion/attendance/recipe gates. Status and new receipts
reuse the model/tier fields defined in `PROTOCOL.md`.

## Trust model

Filesystem permissions are the entire authentication boundary. Any process running as the same local user that owns `~/.scanstudio/control.sock` can open it and drive the scanner — the channel has no login, no token, and no per-caller identity beyond "same UID as the app." This is an accepted, deliberate consequence of a local-only, single-user design (PROJECT.md: "the channel is local-only; remote control adds an auth surface the app does not need for its purpose"). The socket's `0700`/`0600` modes keep a different local user out; they say nothing about which process owned by *this* user is asking, and that is intentional — a fresh agent, a script, and the GUI's own owner are all meant to be able to reach it.

`getpeereid()` — reading the connecting peer's UID/GID off the accepted socket and refusing anything that does not match the server's own UID — is available hardening on macOS that Phase 2 deliberately did not add. It would not change the trust model for the scenario this milestone is built for (multiple agents or scripts all running as the same local user); Phase 2's threat register treats same-user-any-process as the accepted baseline, not a gap left open by omission. A later phase could add it as defence in depth against a same-user sandboxed or lower-privilege process that should not reach the socket.

## Versioning

- The first request on any connection must be `hello`, carrying `schemaVersion` in its params.
- The current schema version is **1** (`ControlSchema.version`).
- A `hello` whose `schemaVersion` does not match the current version is refused with `SCHEMA_VERSION_MISMATCH` before any other command can run on that connection.
- Any request arriving before a successful `hello` is refused with `HELLO_REQUIRED`.

## Error codes

| Code | Emitted when |
|------|--------------|
| `SCHEMA_VERSION_MISMATCH` | The connection's `hello` carried a `schemaVersion` this app does not support. |
| `HELLO_REQUIRED` | A request arrived before that connection completed a successful `hello`. |
| `UNKNOWN_COMMAND` | The request's `method` does not match any command this channel implements. |
| `INVALID_PARAMS` | The request's `params` failed to decode into the shape its `method` requires. |
| `CONTROLLER_BUSY` | A mutating or motion-capable command arrived while another such operation was already in flight; the message names the in-flight operation. |
| `CONFIRMATION_REQUIRED` | A motion-capable command arrived without the explicit confirmation flag its params require (for example `motionConfirmed` or `filmLoadedConfirmed`). |
| `GATE_REFUSED` | A physical-readiness gate (hardware motion, scan readiness, refeed, or a pending manual review) refused the command. |
| `JOB_NOT_FOUND` | `job.get`/`status --job` named a `jobId` this host process never tracked -- neither the live job nor one of the last `SessionModel.maximumTerminalJobHistory` (8) archived jobs (D-19/HEAD-12). |
| `HOST_ALREADY_RUNNING` | `host` found a live control socket already owned by another host. |

When a failure originates in the engine or the bridge instead of the channel itself, the error body carries the engine's own `code` and `recoverable` flag verbatim rather than remapping them to one of the codes above — the same `NOT_CONNECTED`, `FEED_JAM`, or similar code the GUI would see reaches the caller unchanged.

A `GATE_REFUSED` body additionally carries `gate`, naming which gate refused (one of `hardwareMotionReadiness`, `scanReadiness`, `refeedRequired`, `manualReviewPending`), and `guidance`, the same operator-facing explanation the GUI would show next to a disabled action.

Every channel-level code above is `recoverable: false` — a refusal always requires the caller to change something (confirm, wait, resolve the gate) before retrying, never to retry the identical request unchanged; an engine- or bridge-originated code instead carries the engine's own `recoverable` flag verbatim, exactly as it does for `code` itself. Channel error bodies never carry hardware diagnostic detail; a policy refusal exposes only `code`, `message`, `recoverable`, `guidance`, and `gate`.

## Methods

Every entry below states `{params}` → `{result}` in inline code, the `SessionModel` action it performs and any event it causes, then a closing `Errors:` sentence listing only the codes that command's own dispatcher arm can actually return. Shared types (`DeviceInfo`, `ScannerStatus`, `CaptureRecipe`, `ProcessingRecipe`, `OutputRecipe` and its four sub-recipes, `JobState`) are declared once, verbatim, in `PROTOCOL.md`'s `## Types` section and reused unchanged here (D-01) — they are not redeclared. `hardwareMotionReadiness`/`scanReadiness` cross the wire as their Swift enum case name (`HardwareMotionReadiness`/`ScanReadinessPolicy.Decision` in `ScanStudioKit`), computed by the dispatcher, never the enum itself.

Every code below is channel-level (D-03) unless marked "passthrough", meaning the engine's or bridge's own code and `recoverable` flag cross the channel verbatim (for example `NOT_CONNECTED`, `EJECT_FAILED`, `FEEDER_PARKED` — see `PROTOCOL.md`'s Error codes section for the full engine vocabulary). A channel-level code is always `recoverable: false`.

### `hello`
`{schemaVersion: number, clientName: string, clientBuild?: string}` → `{schemaVersion: number, appName: string, appVersion?: string, host: "gui" | "headless", hostPid: number}`. Must be the first request on any connection; every other command sent first is refused with `HELLO_REQUIRED`. A second `hello` on an already-greeted connection is idempotent — it re-validates and returns the same shape, rather than being refused. `host` identifies whether the GUI or resident headless process owns the socket, and `hostPid` is that process's pid. Both fields are additive at schema version 1, so clients may ignore them; they let callers distinguish hosts and cross-check a pidfile before signalling. Errors: `SCHEMA_VERSION_MISMATCH`.

### `status`
`{}` → `{device?: DeviceInfo, scanner?: ScannerStatus, projectName?: string, projectDirectory?: string, jobId?: string, jobState?: JobState, previewComplete: boolean, progress?: {jobId: string, frameIndex: number, frameOrdinal: number, totalFrames: number, pass: number, totalPasses: number, framePercent: number, jobPercent: number, etaSeconds: number}, refeedRequired: boolean, hardwareMotionReadiness: string, motionAllowed: boolean, motionGuidance?: string, mutatingOperationInFlight?: string, selectedFrames: [number], pendingFrames: [number], scanReadiness: string, scanReadinessReason?: string, lastErrorMessage?: string, lastControlRefusal?: {command?: string, code: string, gate?: string, timestamp: string, sequence: number}, manualReviewPending?: {frames: [{index: number, reason: string, evidence: [string], contentConfidence?: number}]}}`. A full session snapshot built from `SessionModel` public state only — no `await`, no engine request. `mutatingOperationInFlight` is the D-07 arbitration signal, `nil` when idle. `progress` (D-17, additive) is `nil`, and omitted from the wire entirely, when no job is active; it is the same shape and the same measured `etaSeconds` `job.get` reports, present here so a subscriber sees it without a second request. `pendingFrames` (D-22/HEAD-12, additive) is the engine's own authoritative resume set (`SessionModel.pendingFrames`, refreshed from `project.pendingFrames`) — a script can see what `scan.resume` would scan before asking for motion, and excluding a frame after a failed batch is visible here immediately, without re-opening the roll. This is also the exact snapshot shape `events.subscribe` streams. Errors: none.

`previewComplete` (D-15, additive) is `true` once the most recent preview operation has reached `scanner.thumbnailsComplete` (`SessionModel.latestCompletedPreviewOperationId != nil`), `false` otherwise. Before a project exists, this is the **only** wire-visible proof a preview finished — `scanReadiness` reports `projectRequired` at that point regardless of whether a preview ever ran, so it cannot stand in for this field. `roll run` (Command-line mapping, below) waits for it directly off the event stream it already subscribed to, rather than polling `status`.

`manualReviewPending` (D-13/HEAD-07, additive) is `nil`, and omitted from the wire, when nothing is paused at the boundary-review gate; otherwise one entry per flagged frame from `pendingManualReviewScan`. `reason` is the frame's first boundary-evidence string (`evidence[0]`), or the literal `"boundaryAmbiguous"` when there is none — never an empty string, never an invented sentence. `contentConfidence` is `1 - blankConfidence` of the same blank-frame hint (see "Blank-frame hint" below) `frames.list` would report for that index, or absent entirely when no hint exists for it — a missing hint stays missing, it is never defaulted to a plausible number. Because this field is built inside the exact same aggregate `events.subscribe` streams, a pending review reaches `status`, `control.snapshot`, and `control.changed` from one source, with no separate event wiring (T-03-34).

`lastControlRefusal` (SAFE-04) is the most recent wire-level refusal any connection triggered — `command` is the refused method name (`nil` only for a request too malformed to identify one, for example an oversized line), `code`/`gate` mirror the refusal's own `ControlErrorPayload.code`/`.gate`, and `sequence` is a monotonically increasing counter so two otherwise-identical refusals (same command/code/gate) are still distinguishable as separate occurrences. Every dispatcher-level refusal is recorded here — `CONFIRMATION_REQUIRED`, `GATE_REFUSED`, `CONTROLLER_BUSY`, `INVALID_PARAMS`, `UNKNOWN_COMMAND`, `SCHEMA_VERSION_MISMATCH`, `HELLO_REQUIRED` — regardless of which connection triggered it, so an `events.subscribe` follower on a *different* connection observes it too, on the very next `control.changed`. **Parse-time CLI refusals never reach the socket, by design (D-11)** — `scanstudio-cli`'s own `--confirm-motion`/`--film-loaded` gate and `frames select`/`include`/`exclude`'s CUPS range shape check both decide before any connection opens, so neither ever produces a `lastControlRefusal` for any subscriber to see; that class of refusal is recorded only by the CLI's own exit code and JSON error body on the process that hit it (a transcript covering it end-to-end is Phase 5's job, not this channel's).

### `scanner.list`
`{}` → `{devices: [DeviceInfo]}`. Routes to `refreshAvailableDevices(rescan: false)`. Errors: `CONTROLLER_BUSY`; passthrough (for example a recoverable `INTERNAL` with a `BRIDGE_STARTUP_FAILED:` prefix).

### `scanner.rescan`
`{}` → `{devices: [DeviceInfo]}`. Routes to `refreshAvailableDevices(rescan: true)` — one deliberate re-attempt of the real backend's startup. Errors: `CONTROLLER_BUSY`; passthrough (`ALREADY_CONNECTED`).

### `scanner.refresh`
`{}` → `{scanner?: ScannerStatus}`. `scanner.refresh` routes to `refreshScannerStatus()` — the same method `HardwareMotionReadinessView`'s own refresh button calls, and the same live re-read `status --refresh` (see Command-line mapping) issues before reporting a snapshot. Non-motion: it re-reads live scanner state over the existing `scanner.status` request; it never moves film, and it carries no confirmation flag because there is nothing to confirm. `scanner` is `nil` only when the refresh discovers the session was lost — `refreshScannerStatus()`'s existing `invalidateConnection` path already clears `device`/`status` on `connected: false` (D-16), and that is reported through the model's own subsequent state, not synthesized by this command. Errors: `CONTROLLER_BUSY`; passthrough.

### `scanner.connect`
`{deviceId?: string, allowUnverifiedHardware?: bool}` → `{alreadyConnected: boolean}`. Routes to `connect(deviceId:)`. An absent `deviceId` reuses the last successfully selected device while it remains discovered; if that device disappeared, it refuses rather than selecting a different scanner. With no previous selection, `DeviceSelectionPolicy` requires exactly one discovered device. This also supplies the one permitted `status --refresh` reconnection. Emits `scanner.status`. Poll `status` afterward for the connected `device`. **D-16: re-connecting the device that is already connected is a success**, not `ALREADY_CONNECTED` — it reports `alreadyConnected: true` and reaches no backend at all (no bridge round trip, so no `ConnectOptions` such as `faultInjection`/`timeScale` is ever re-applied to the already-open session). `alreadyConnected` is `false` for a fresh connect. A *different* device id while one is already connected is still refused. Errors: `CONTROLLER_BUSY`; `GATE_REFUSED` with no `gate` (an unknown device id — an app-level precondition, not a physical gate); passthrough (`UNKNOWN_DEVICE`, `ALREADY_CONNECTED` for a different device).

### `scanner.disconnect`
`{}` → `{}`. Routes to `disconnect()`. Emits `scanner.status` with `connected: false`. Errors: `CONTROLLER_BUSY`; passthrough (`NOT_CONNECTED`, `SCANNER_BUSY`).

### `preview.acquire`
`{filmLoadedConfirmed: boolean, intent?: "initial"|"replaceFilmProcess"|"refreshSavedProject", filmProcess?: FilmProcess}` (absent `intent` = `"initial"`) → `{outcome: "started"|"rejected"|"failedToStart", intentToken: string}`. **Requires `filmLoadedConfirmed: true`.** Pre-checks `hardwareMotionReadiness.allowsMotion` (the motion component of `ScanPanelView.canAcquireThumbnails`'s own `.disabled` binding), then routes to `requestPreview(_:)`, which emits `scanner.thumbnail` per frame and `scanner.thumbnailsComplete`. A `"rejected"`/`"failedToStart"` `outcome` is still a *success* response — the request was accepted and answered definitively; this is the one D-05 command where a non-`"started"` outcome is not itself a failure. Errors: `CONFIRMATION_REQUIRED` (missing `filmLoadedConfirmed`); `GATE_REFUSED`, gate `hardwareMotionReadiness`; `INVALID_PARAMS` (`intent` is `"replaceFilmProcess"` with no `filmProcess`, or an unrecognized `intent` string); `CONTROLLER_BUSY`.

### `frames.list`
`{}` → `{frames: [{index: number, excluded: boolean, selected: boolean, hasThumbnail: boolean, state?: string, manualReviewDecision?: "useFrameAnyway"|"dontScan", errorCode?: string, errorMessage?: string, blankConfidence?: number, thumbnailStddev?: number, thumbnailMean?: number, endBonus?: number, runBonus?: number, needsApproval: boolean, reviewEvidence: [string]}], selectedFrames: [number]}`. Built from `SessionModel` state only — no engine request. `errorCode`/`errorMessage` (D-20/HEAD-12, additive) carry only the bare failure code string and the bridge's own message text, never a full error payload or any hardware-diagnostic detail (T-01-05: no `details`/`evidence`/`diagnosticEvidence`). `state: "notAttempted"` (D-20/HEAD-12) names a frame the batch never reached during a failed batch — it always carries `errorCode: null`/`errorMessage: null`, never a fabricated cause. Errors: none.

**Pre-project source (D-12/HEAD-06).** With no project open, `frames` is no longer empty by default: it lists every **previewed thumbnail** index, sorted ascending, with `hasThumbnail: true`, `selected` from the current selection, `excluded: false` (nothing can be excluded before a project exists — there is no manifest to hold an exclusion, so this is a fact about the state, not a third state), and `state`/`manualReviewDecision`/`errorCode` from the same per-index tracking the post-project branch reads. Once a project exists, `frames` reverts to one entry per `project.frames` member exactly as before.

`needsApproval`/`reviewEvidence` mirror the frame's own `Thumbnail.needsApproval`/`.warnings` verbatim, pre- and post-project alike — `reviewEvidence` *is* the boundary evidence D-12 asked for, no separate field was needed. The five `blankConfidence`/`thumbnailStddev`/`thumbnailMean`/`endBonus`/`runBonus` fields are a **heuristic** (see "Blank-frame hint" below) — see that section for the formula, and for the `null`-together rule that applies when a frame's thumbnail carried no decodable raster.

### `frames.select`
`{indices?: [number], all?: boolean, none?: boolean}` → `{}`. **Exactly one of `indices`/`all`/`none` must be present** — any other combination is refused with `INVALID_PARAMS` before any `SessionModel` call. Not a motion command — no confirmation flag. Routes to `setFrameSelection(_:)` (the `indices` arm), `selectAllFrames()`/a project-mode `--all` equivalent, or `clearFrameSelection()` (the `none` arm). While a job is active or a resume is in flight this is refused with `CONTROLLER_BUSY`, mirroring `settings.set`/`outputs.set`'s identical rule — none of the three have a busy flag of their own.

**Pre-project (CR-02):** the `indices` arm is validated against the *previewed* frame count (`status.frameCount` — there is no project yet to validate membership against). Exists so a pure CLI/attach-mode caller (no GUI ever driven) can populate `selectedFrameIndices` — `roll.save`'s own "select at least one frame" precondition — from a cold session, closing the gap `roll.save`'s own refusal message otherwise leaves unsatisfiable through any documented command.

**Project mode (D-23/HEAD-12 CF-12, additive — the 2026-09-07 batch abort):** once a project exists, `frames.select` is now allowed rather than refused outright. `indices` is validated against the project's own frame indices (`project.frames.map(index)`); any index that is out of range, currently excluded, or already carries a completed receipt is refused `INVALID_PARAMS` naming every offending index, and the selection is not applied at all (never partial). `--all` in project mode means every project frame that is neither excluded nor already completed — re-selecting durable work or an operator-excluded frame into the next scan is never what `--all` means. `ScanReadinessPolicy`'s own scan-time check remains an independent second layer refusing any target set that still contains an excluded frame; neither layer substitutes for the other. This is the fix for the 2026-09-07 case where excluding the frames that finished a boundary review left the operator with `targetRequired` and no documented way to reselect a frame in project mode short of re-opening the roll.

Errors: `INVALID_PARAMS` (not exactly one of `indices`/`all`/`none`; pre-project: an `indices` entry outside the previewed frame range, or no preview has completed yet; project mode: an `indices` entry out of range, excluded, or already completed, naming every offending index); `CONTROLLER_BUSY`.

### `frames.place`
`{rows?: [number], placements?: [{slot: number, rowOffset: number}], replay?: boolean}` → `{operationId: string, placements: [{slot: number, rowOffset: number}], replayed: boolean}`. Exactly one mode is accepted: `replay: true`, or a payload containing manual boundary `rows`, `placements`, or both. An open project is required. This is not a motion command and carries no confirmation flag.

`rows` are absolute boundary positions in the native preview-row coordinate space used by `roll.manualFrames`: at least two nonnegative, unique, strictly increasing values, with every adjacent span within the existing 56...145-row physical band. When both fields are present, `roll.manualFrames` establishes the new preview registration first, then `placements` are applied in ascending slot order. `rowOffset` is an absolute native-row offset, not a delta: slot 1 accepts `0...144`, later slots accept `-144...144`. Each offset uses the exact current preview operation ID for `roll.setSpacingOffset`, then persists through `project.setFrameAlignment`. Processing stops at the first refusal and never retries.

`replay: true` reads the open project's nonzero saved alignments and reapplies unresolved ones sequentially in slot order against the exact current completed preview. Placements already confirmed on that preview are returned without a duplicate bridge request. Saved values remain intent until each replacement thumbnail confirms its offset. A missing, partial, or replaced preview is refused before any spacing request; a failed restore leaves the remaining saved slots as scan-readiness blockers. Errors: `INVALID_PARAMS`; `GATE_REFUSED`; `CONTROLLER_BUSY`; passthrough.

### `frames.include`
`{frameIndex: number}` → `{}`. Validates `frameIndex` against the open project's actual frame indices, then routes to `setFrameExcluded(_:excluded: false)`. Errors: `INVALID_PARAMS` (no project open, or `frameIndex` is not one of the project's frame indices); `CONTROLLER_BUSY`; passthrough.

### `frames.exclude`
`{frameIndex: number}` → `{}`. The same validation and the same `setFrameExcluded(_:excluded:)` method as `frames.include` — only the flag differs (`true` here). Errors: `INVALID_PARAMS`; `CONTROLLER_BUSY`; passthrough.

### `review.approve`
`{motionConfirmed: boolean}` → `{}`. **Requires `motionConfirmed: true`** — this command starts a scan (`approvePendingManualReviewAndStart()`), even though its name does not say so; this is a Phase 1 tightening beyond the GUI's own literal confirmation-flag enumeration, per PROJECT.md's standing "no scanner motion without an explicit confirmation flag" constraint. Refused with `GATE_REFUSED` when no manual review is currently pending, so "approved" can never be confused with "there was nothing to approve." Emits `roll.approve` per flagged frame, then `scan.start`, on success. Attended-scan-recovery approval (`approveEveryFrameAndScan()`) is a different action with different confirmation semantics and is not reachable through this command — see Not yet implemented. See `review.cancel` below for dismissing a pending review without approving it. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `manualReviewPending`; `CONTROLLER_BUSY`; passthrough.

### `review.cancel`
`{}` → `{}` (D-23/HEAD-12 CF-10/CF-11, additive — the 2026-09-07 batch abort). Dismisses a pending manual review **without starting motion, without approving anything, and without clearing `selectedFrameIndices`**. Not a motion command — no confirmation flag, because it authorizes no motion; `motionConfirmed` has no meaning here and is never accepted. Routes to `cancelPendingManualReviewScan()`, the same method the GUI's own "Cancel" button on the review sheet calls — that method's own guard (`pendingManualReviewApproval == nil`) means an approval already in flight owns the boundary and the cancel is a no-op then, never a race with `review.approve`. Refused with `GATE_REFUSED` when no manual review is currently pending, mirroring `review.approve`'s identical silent-no-op-to-typed-refusal translation. This is the fix for the 2026-09-07 case where dismissing the review sheet through the only available path silently cleared the operator's frame selection, forcing a costly re-selection. Errors: `GATE_REFUSED`, gate `manualReviewPending`; `CONTROLLER_BUSY`.

### `settings.get`
`{}` → `{capture: CaptureRecipe, processing: ProcessingRecipe}`. Built from `SessionModel` state only. `processing.digitalIceEnabled` reports the *effective* value: it is gated off unless `capture.channels == "rgbi"` and `processing.filmProcess != "bwNegative"`, even if a prior `settings.set` asked for it on — this asymmetry is `SessionModel`'s existing behavior, not a channel-specific rule. Errors: none.

### `settings.set`
`{capture: CaptureRecipe, processing: ProcessingRecipe}` → `{}`. Routes to `applySettingsRecipes(capture:processing:)` — the one `SessionModel` entry point for this command; the dispatcher never writes an individual settings field itself. Refused with `CONTROLLER_BUSY` while a job is active or a batch resume is in flight, mirroring `BatchInspectorView`'s own rule that the settings editors are not rendered during a job and are disabled during a resume — `applySettingsRecipes` is synchronous and holds no busy flag of its own, so this is an explicit dispatcher-level check, not the generic D-07 arbitration signal. Errors: `CONTROLLER_BUSY`.

### `outputs.get`
`{}` → `{outputs: OutputRecipe}`. Built from `SessionModel` state only. Errors: none.

### `outputs.set`
`{outputs: OutputRecipe}` → `{}`. Routes to `applyOutputRecipe(_:)`, which delegates to the same private path `roll.open` already uses to seed a project's recipes. Same `isJobActive`/`isResumingBatch` busy rule as `settings.set`. Errors: `CONTROLLER_BUSY`.

### `roll.save`
`{name: string, carrier: SimulatedFilmCarrier, frameCount: number, filmProcess: FilmProcess, motionConfirmed: boolean}` → `{saved: boolean, projectName?: string, projectDirectory?: string, outcome: "started"|"manualReviewPending"|"failed"}`. **Requires `motionConfirmed: true`** — it creates the project and immediately starts the scan of the selected frames, even though its name does not say so. Routes to `saveRollAndScanSelectedFrames(name:carrier:frameCount:filmProcess:)`, which creates the project from the current preview and starts (or pauses for manual review) the currently selected frames in one step. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED` with no `gate` (a project is already open, or no frames are selected — both app-level preconditions); `CONTROLLER_BUSY`; passthrough.

`outcome` (D-13/HEAD-07) names which of the three things actually happened, since `saved: true` alone cannot distinguish them: `"started"` (the scan began), `"manualReviewPending"` (the project was created but a flagged frame paused it at the boundary-review gate — see `status.manualReviewPending`), or `"failed"` (the save itself succeeded but starting the scan did not, distinct from an outright refusal, which never reaches this result type). **The CLI's exit code stays 0 for both `"started"` and `"manualReviewPending"`** — a paused review is a legitimate reported state, not a failure.

**Exclusions persisted at creation (D-21/HEAD-12, additive — the 2026-09-07 batch abort).** Every previewed frame the operator did not select is created `excluded: true` on the new project's manifest, in the same `project.create` call that creates it — never a second, separate exclusion call afterward. This is what keeps `project.pendingFrames`, `status.pendingFrames`, and the GUI's own "Resume Batch (n remaining)" consistent with what the operator actually chose from the moment the project exists, and it is why `scan.resume` can never scan a frame the operator left unselected before saving.

### `roll.open`
`{directory: string}` → `{}`. Routes to `openProject(directory:)`. Errors: `GATE_REFUSED` with no `gate` (another project action, scan, or frame-alignment change is already in progress); `CONTROLLER_BUSY`; passthrough (`PROJECT_NOT_FOUND`, `MANIFEST_INVALID`).

### `roll.list`
`{}` → `{projects: [{id: string, name: string, carrier: SimulatedFilmCarrier, frameCount: number, filmProcess: FilmProcess, createdAt: string, directory: string}]}`. Routes to `refreshRecentProjects()`, refreshing `SessionModel.recentProjects` from the engine's default projects root. An empty list on success is a valid, displayable state. Errors: `CONTROLLER_BUSY`; passthrough.

### `roll.solveExposure`
`{frame: number, motionConfirmed: true}` → `{solution: RollExposureLock}`.
Requires an open project, completed preview registration and the same motion
readiness gate as capture. Waits for the engine's correlated terminal event.
The successful solution is persisted roll-wide; AE-off scan calls reuse its
RGB ticks, while AE-on calls omit the override without clearing the lock.
IR remains metered. Simulator/unsupported drivers refuse measured exposure.
Errors: `CONFIRMATION_REQUIRED`, `CONTROLLER_BUSY`, `GATE_REFUSED`, typed engine errors.

### `roll.verify`
`{pass?: string, exposureIdentical: boolean, noClipping: boolean}` →
`{status: "pass"|"fail"|"unknown", exposureIdentical, noClipping, checkedReceipts, issues: [{status, jobId?, frameIndex?, field, detail}]}`.
Reads the durable project and checks selected capture file bindings, lengths
and hashes. Exposure comparisons are grouped by pass. Missing evidence is
unknown. No scanner request or project mutation is made.

### `roll.collect`
`{to: string, metadata: {stock: string, pass: string, slotMap: {slot: physicalFrame}, operator?: string, firmware?: string, adapter?: string, host?: string}}` →
`{destination, files: [{path, byteLength, sha256}], metadataPath, hashesPath}`.
Copies one exact receipt pass into a fresh destination using held source and
destination handles, then verifies its file identities and hashes. Raw-enabled
receipts require raw RGB and tagged IR; raw-disabled receipts retain their
available positives, meter and receipt. No original is modified and no scanner
operation is invoked. Missing/changed evidence or an existing destination is
refused. The project exposure lock takes precedence over supplied metadata.

### `scan.start`
`{motionConfirmed: boolean, frames?: number[], passToken?: string}` → `{outcome: "started"|"manualReviewPending"}`. **Requires `motionConfirmed: true`.** Pre-checks `scanReadiness(for: requestedFrames)` — verbatim the expression `ScanPanelView`'s Scan button binds its `.disabled` state to — then routes to `startMockScan(frames:passToken:)`, the one entry point for both real and simulated devices. `CONTROLLER_BUSY` also covers the window while the GUI-only attended-scan-recovery approval (`approveEveryFrameAndScan()` — see Not yet implemented) is in flight: that approval now participates in the same D-07 busy indicator as every other mutating action, so `scan.start` can never report a typed success for a request that approval silently absorbed instead. Emits `scan.jobState`/`scan.progress`/`scan.frameState` as the job proceeds. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `scanReadiness`; `CONTROLLER_BUSY`; passthrough.

`outcome` (D-23/HEAD-12, additive — the 2026-09-07 batch abort) matches `roll.save`'s own vocabulary: `"started"` (the scan actually began) or `"manualReviewPending"` (a flagged boundary paused it at the review gate instead, from the exact frames this call requested — see `status.manualReviewPending`). Never `"failed"` here: a failure is the `.failure` response above, not a success carrying a failure string. This closes the 2026-09-07 gap where a paused start was indistinguishable, on the wire, from an outright started job.

Optional `frames` is an explicit, unique positive frame set; omission uses the current selection. It follows the same readiness and manual-review gates, including explicit rescans. Optional `passToken` is 1–64 ASCII letters/digits/`.`/`_`/`-`, excluding `.` and `..`; it is preserved in each receipt and materialized in `{pass}`/`$Pass` filename tokens. CLI repeats send separate sequential starts after terminal success; the control method itself starts exactly one job.

### `scan.stop`
`{mode?: "afterCurrentFrame"|"immediate"}` (absent `mode` = `"afterCurrentFrame"`) → `{}`. Routes to `stopAfterCurrentFrame()` or `stopImmediately()`. Refused with `GATE_REFUSED` when no job is active, rather than silently reporting success for nothing having happened. Errors: `INVALID_PARAMS` (unrecognized `mode`); `GATE_REFUSED` with no `gate` (no active job); `CONTROLLER_BUSY`; passthrough.

### `scan.resume`
`{motionConfirmed: boolean}` → `{outcome: "started"|"manualReviewPending"}`. **Requires `motionConfirmed: true`.** **D-22/HEAD-12 (CF-12/CF-13, additive — the 2026-09-07 batch abort): refreshes `pendingFrames` from the engine (`project.pendingFrames`) before evaluating readiness**, not the dispatcher's own cached copy — excluding a frame after a failed batch must never brick `resume` until something else happens to refresh the cache, and re-opening the roll is never required to recover. Pre-checks `scanReadiness(for: pendingFrames)` — verbatim the expression `ScanPanelView`'s Resume Batch button binds its `.disabled` state to, now against the freshly-read set — then routes to `resumeBatch()`, whose own guard additionally refuses with `GATE_REFUSED` (no `gate`) rather than a silent success when a resume is already in flight, a scan is already starting, or an attended-scan-recovery or manual-review approval is in progress — reasons the dispatcher's own pre-check cannot see directly. `resumeBatch()` performs its own second refresh and re-verification internally; the dispatcher's pre-check exists to give the caller a typed refusal, not to be the gate. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `scanReadiness`; `GATE_REFUSED` with no `gate` (resume already in flight, a scan already starting, or an approval in progress); `CONTROLLER_BUSY`; passthrough.

`outcome` (D-23/HEAD-12, additive) is identical in shape and meaning to `scan.start`'s own `outcome` above — this is the fix for the 2026-09-07 case where a `resume` that actually paused for review printed the *previous* job's stale failed snapshot with exit 0, giving no indication a review was pending at all.

### `scanner.eject`
`{motionConfirmed: boolean}` → `{}`. **Requires `motionConfirmed: true`.** Pre-checks `hardwareMotionReadiness.allowsMotion`, then `DeviceBarEjectPolicy.canOffer` — the identical function `DeviceBarView`'s Eject button gates its own visibility on, fed connected/transport-idle/no-active-job/media/film state — then routes to `eject()`, which re-checks both gates internally as defence in depth. Accepts a device that has never completed a preview (D-10/D-11 — the 2026-09-07 incident this phase fixes: a scanner reporting `filmPresent: true, mediaLoaded: false` must still be able to eject). A disconnected, mid-job, or mid-transport-activity caller is refused rather than reaching the engine — states the GUI's own Eject button is never even rendered for. Emits `scanner.status` with `filmPresent`/`mediaLoaded` cleared. Errors: `CONFIRMATION_REQUIRED`; `GATE_REFUSED`, gate `hardwareMotionReadiness`; `GATE_REFUSED` with no `gate` (disconnected, transport not idle, a job is active, or no film to release); `CONTROLLER_BUSY`; passthrough (`HW_MOTION_NOT_ARMED`, `EJECT_FAILED`, `FEEDER_PARKED`).

### `diagnostics.export`
`{directory: string}` → `{path: string, entries: [string]}`. Validates `directory` before any write — it must be an absolute path, must contain no `..` path component, and must be an existing directory — then composes `SessionModel.diagnosticBundleEntryNames(previewConsent:)`, `makeDiagnosticBundleData(previewConsent:)`, and `DiagnosticBundleFileWriter.write(_:to:)`, the same three calls the GUI's own Save Diagnostic Bundle action makes. `previewConsent` is always `nil`: film bytes require exact per-export consent, and the control channel has no consent affordance in Phase 1 (T-01-05). The filename is always generated by the dispatcher from the current timestamp, never taken from the request — the directory is the only caller-controlled part of the write destination (T-01-20). Errors: `INVALID_PARAMS` (`directory` is relative, contains `..`, does not exist, or the write itself failed).

### `events.subscribe`
`{}` → `{subscribed: boolean, snapshot: <the same shape `status` returns>}`, then a `control.snapshot` event carrying that same snapshot immediately, and one `control.changed` event carrying a fresh snapshot after every subsequent `SessionModel` mutation. Never reads the engine client's own event stream directly — `SessionModel` already owns that stream's one consumer. Errors: none.

### `job.get`
`{jobId?: string}` → `{jobId?: string, jobState?: JobState, progress?: {jobId: string, frameIndex: number, frameOrdinal: number, totalFrames: number, pass: number, totalPasses: number, framePercent: number, jobPercent: number, etaSeconds: number}, completedFrameCount: number, pendingFrameCount: number, receiptCount: number, frameErrorCodes: {[frameIndex: string]: string}, frameErrorMessages: {[frameIndex: string]: string}, finishedAt?: string, notAttemptedFrames: [number]}`. Built from `SessionModel` state only. `receiptCount` rather than the receipts themselves — this is a status call, not an export. **`progress.etaSeconds` (D-17) is measured, never fabricated:** the engine's real backend computes it as the mean of this job's own completed frame durations times the number of frames remaining, using only `Instant`s the engine itself stamped on arriving bridge events. It is `0` only before this job's first frame has resolved — never a client-side estimate, never extrapolated from another job's timing. (The simulator's own `eta_seconds` remains its existing, documented model-based estimate — deliberately unchanged by D-17.)

**Optional `jobId` and terminal-job retention (D-19/HEAD-12, additive — the 2026-09-07 batch abort).** An absent/`null` `jobId` keeps the historical behavior byte-for-byte: the one job this session is currently tracking (`progress`/`finishedAt`/`notAttemptedFrames` all reflect a live, still-running job when one exists — `finishedAt` is `null` and `notAttemptedFrames` is `[]`). A supplied `jobId` matching the live job answers identically. A supplied `jobId` matching one of the **last 8** jobs this host process has seen finish (`SessionModel.maximumTerminalJobHistory`, oldest evicted first) answers from that archived aggregate instead — a job that finished seconds ago is never `JOB_NOT_FOUND`, closing the exact 2026-09-07 gap where the finished job became unqueryable almost immediately. Only a `jobId` genuinely never tracked by this process (neither live nor in the ring) is refused. The terminal-job ring is process-scoped: it survives both disconnect and a project change (deliberately **not** cleared by the reset those two call), and is bounded only by its own 8-entry eviction.

`frameErrorCodes`/`frameErrorMessages` (the latter additive, D-20/HEAD-12) map a stringified frame index to the bare failure code and the bridge's own message text — codes and messages only, never `details`/`evidence`/`diagnosticEvidence`/`diagnosticEvidenceUnavailableReason` (T-01-05, extended here to messages). `finishedAt` (additive) is an ISO-8601 timestamp for a terminal job, `null` for a live one. `notAttemptedFrames` (additive) lists 1-based indices a batch abort never reached — distinct from a failed frame, which is named in `frameErrorCodes`/`frameErrorMessages` instead.

Errors: `JOB_NOT_FOUND` (a supplied `jobId` this host process never tracked).

## Read-only commands

`status`, `frames.list`, `settings.get`, `outputs.get`, and `job.get` are answered entirely from in-memory `SessionModel` state and issue no engine request (CTRL-03). Repeating any of them never reconnects, never re-arms discovery, and never changes scanner or engine state — a caller can poll them freely.

**`scanner.refresh` is deliberately excluded from this list.** OUT-04 forbids a read-only command from probing hardware, and `scanner.refresh` is exactly that probe: it issues a live `scanner.status` request to the engine. It exists as a separately named, opt-in command precisely so that exclusion holds — `status` alone, with or without `--job`, never probes; a caller must ask for `scanner.refresh` (or `status --refresh`) by name to get one.

## Blank-frame hint

`blankConfidence`/`thumbnailStddev`/`thumbnailMean`/`endBonus`/`runBonus` (D-12/HEAD-06, `frames.list`) are a **heuristic**, never a fact — a reported number a caller can act on, never a decision this channel makes on its own. Calibrated against a real attended hardware run; the source table lives in `.planning/phases/SSCLI-03-headless-mode-parity/03-BLANK-HINT.md`.

Formula: decode the frame's own preview thumbnail to 8-bit luminance, crop to the central 80% (drop 10% off every side so sprocket/edge bleed never counts), and compute the population mean/stddev of what remains. `flatness = clamp((16 − stddev) / 12, 0, 1)` — 1.0 at stddev ≤ 4, 0.0 at stddev ≥ 16. A positional prior is then applied multiplicatively: `endBonus = 0.2` when the frame sits in the last 10% or first 5% of the previewed roll (leader lives at the ends), `runBonus = 0.2` when a numerically adjacent frame is itself flat (`flatness ≥ 0.5`; leader comes in runs). `blankConfidence = min(1, flatness × (1 + endBonus + runBonus))`. Because the combination is multiplicative, a textured frame (`flatness == 0`) can never be promoted to blank by position alone.

All five constants — the 16/12 flatness window, the two 0.2 bonuses, and the 0.8 default `frames select --skip-blank` threshold — live in exactly one place, `BlankFrameHint` (`ScanStudioKit/BlankFrameHint.swift`), so a later roll's own calibration data can re-tune them without hunting through call sites.

The hint never excludes anything by itself — no command acts on it implicitly. The five fields are `null` **together** whenever the frame's thumbnail carried no decodable raster (every simulator frame, or a real frame whose tile failed to decode) — never individually populated, and never defaulted to a plausible number.

**`frames select --skip-blank [--blank-threshold <0..1>]`** (default threshold `0.8`) sends `frames.list`, then `frames.select` with every previewed index whose `blankConfidence` is below the threshold, on the same connection. A frame with no `blankConfidence` at all is always **kept** — an unscored frame is never skipped on the strength of a hint that does not exist. Before selecting, it prints exactly which indices it is skipping and their scores (T-03-30). If every previewed frame would be skipped, or no preview has completed at all, it refuses with a CLI-originated `INVALID_RANGE`-class payload (exit 64) naming the threshold and the highest score seen, rather than silently selecting nothing.

**`roll save --auto-approve`** (still requires `--confirm-motion`, checked independently of the `--auto-approve` flag itself) approves a `roll.save` that pauses at `outcome: "manualReviewPending"` only when the flagged-frame list is non-empty and **every** frame's `contentConfidence` (`status.manualReviewPending`) is non-`null` and at or above the same `0.8` bar, by sending exactly one `review.approve` — the identical action the GUI's own "Confirm & Scan" takes. A single `null` or a single lower score refuses the whole batch (T-03-29): no approval is sent, the review stays pending, and the result names which frame refused it (`autoApproveRefusedBecause`). Either way the result carries `autoApproved: [index]` (empty when nothing was approved) merged alongside `roll.save`'s own body.

## Arbitration

Exactly one mutating operation runs at a time (D-07). A second mutating or motion-capable command arriving while one is already in flight is refused with `CONTROLLER_BUSY`, naming the in-flight operation. The channel never queues a refused request, never retries it automatically, and never re-issues a physical operation on its own (D-09) — a refusal is returned once, and the caller decides whether to try again.

## Progress output

`--wait` on `scan`, `resume`, `roll save`, and `roll run` prints one line per changed `scan.progress` (D-17) to **stderr**, in the shape `frame <frameOrdinal>/<totalFrames> pass <pass>/<totalPasses> eta <duration>` (for example `frame 3/36 pass 1/4 eta 1h52m`) — `<duration>` is `<h>h<mm>m` at or above an hour, `<m>m<ss>s` at or above a minute, `<s>s` below a minute, and the literal `unknown` before the job's first frame has resolved (never a fabricated number). `--quiet` (a global flag, every subcommand carries it) suppresses these lines entirely. **stdout is unaffected either way — it stays exactly one JSON object**, the same terminal `job.get`-shaped result `--wait` has always printed; progress lines are never interleaved into it. No progress line is ever derived from a client-side clock: every value comes from `scan.progress`/`job.get`'s own `etaSeconds`, itself measured by the engine (see `job.get`'s entry above).

## Run receipt

`roll run` (D-15/HEAD-09, Command-line mapping below) is a CLI-side composition of six already-documented commands into one unattended walk on a single connection — it adds no wire command and no `SessionModel` method of its own. Its only new artifact is the receipt it prints and, once a project exists, writes to disk.

Shape: one JSON object, `{steps: [{step: string, command: string, exitCode: number, outcome: "ok"|"refused", startedAt: string, endedAt: string}], project?: {name?: string, directory?: string}, jobId?: string, jobState?: string, frames: {selected: [number], skipped: [number], autoApproved: [number]}, receiptPath?: string}`. `steps` names every request the walk actually sent, in order, each with its own D-10 exit code and outcome — `"ok"` or `"refused"`, never anything else. `startedAt`/`endedAt` are ISO-8601 UTC with fractional seconds. `frames.selected`/`.skipped` are populated only when `--skip-blank` ran the selection through `frames.list`; `frames.autoApproved` is populated only when `--auto-approve` resolved a paused manual review.

**Output.** Printed on stdout through the same `ControlCLIOutput.renderResult` path every other command's success uses — **never `renderError`, even when a step refused**: the refusal is named inside `steps`, not by switching envelopes. The run's own success or failure is the process exit code alone (see Exit codes, below), decided once, after the receipt has already been rendered.

**On disk (SAFE-03).** Once `roll.save` has run and a project directory exists, the same receipt is additionally written to `<projectDirectory>/cli-run-<yyyyMMdd'T'HHmmss'Z'>.json` — a brand-new file beside `manifest.json`, **never inside it**, and the written path is echoed back as `receiptPath` in the printed receipt. The write refuses rather than overwrites if a file already exists at that exact name (an `O_EXCL`-backed refusal, not a `stat`-then-write race); a failed write is reported as a warning line on stderr only and never changes the run's own exit code — losing the on-disk copy must never be mistaken for a failed scan.

**Stopping.** One attempt per step; the first refused step stops the walk (SAFE-02) — nothing after it is ever attempted, and no step is ever retried. A `roll.save` that pauses at `manualReviewPending` with `--auto-approve` absent, or whose flagged frames do not clear the bar, is a legitimate stop at exit 0, not a refusal — the review is left pending for an operator to decide.

## Host process

`scanstudio-cli host` (equivalently `host run`) runs the resident headless host in the foreground until `SIGTERM` or `SIGINT`. It serves `~/.scanstudio/control.sock` by default; `--socket <path>` overrides it. `host --detach` starts a child, redirects its output to `~/.scanstudio/logs/host.log` (or `--log <path>`), and reports success only after that exact child answers `hello` as a headless host. The pidfile is `<socket>.pid` with mode `0600`; its parent directory is mode `0700`.

The resident host probes the socket before constructing an engine. A live owner produces `HOST_ALREADY_RUNNING` and exit 75, so a second engine is never spawned. `host stop` signals a pidfile only after a live hello reports the same `hostPid`; an unanswered socket, mismatched pid, or GUI hello refuses to signal. Startup teardown stops the server first, terminates the engine second, then removes the pidfile and socket.

`--engine <path>` is a development and test override that bypasses `EngineLocator`. Phase 4 must decide how a packaged, signed build constrains this override. Immediately after host startup, discovery may still be in flight; a first mutating command can therefore receive the expected `CONTROLLER_BUSY` refusal while `scanner.list` settles.

## Exit codes

`scanstudio-cli` follows `sysexits.h`-style conventions (D-10). Exactly one function, `ControlCLIExitCode.forErrorCode(_:)`, decides a process exit value from an error `code` string; no command computes one inline except the parse-time `--confirm-motion`/`--film-loaded` gates below, whose value is fixed by D-11 rather than looked up.

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

`--wait`'s own exit code is decided the same way, from the job's final aggregate rather than a second table: `completed` and `stopped` both exit 0 (the job reached a terminal state without error — a caller who asked to stop gets a clean exit, not a failure), `failed` exits 65.

## Command-line mapping

One row per `scanstudio-cli` subcommand group (the full D-08 tree, sixteen groups). "Confirmation flag" is the CLI's own parse-time gate (D-11); "—" means the subcommand carries no motion and needs none. Every row additionally carries the read-only baseline (`0, 65, 69, 70, 75`) or the confirmation-gated baseline (`0, 65, 69, 70, 75, 77`); a "+" column notes any exit code a row can reach beyond that baseline. `--socket <path>` and `--human` (and, since D-17, `--quiet` -- see Progress output above) are global flags every row in this table carries implicitly; they are not repeated per row.

| Subcommand | Channel method(s) | Confirmation flag | Exit codes |
|---|---|---|---|
| `roll solve-exposure --frame N --confirm-motion` | `roll.solveExposure` | `--confirm-motion` | 0, 65, 69, 70, 75, 77 |
| `roll verify [--pass TOKEN] [--exposure-identical] [--no-clipping]` | `roll.verify` | — | 0, 65, 69, 70, 75 |
| `roll collect --to PATH --stock STOCK --pass TOKEN --slot-map MAP.json [--operator NAME]` | `roll.collect` | — | 0, 64, 65, 69, 70, 75 |
| `connect [--device <id>]` | `scanner.connect` | — | 0, 65, 69, 70, 75 |
| `disconnect` | `scanner.disconnect` | — | 0, 65, 69, 70, 75 |
| `rescan` | `scanner.rescan` | — | 0, 65, 69, 70, 75 |
| `status [--refresh] [--job <id>]` | `scanner.refresh` first when `--refresh` is given, then `status`, or `job.get {jobId}` when `--job` is given | — | 0, 65 (the host's own `JOB_NOT_FOUND` when `--job` names an id neither live nor in the last 8 archived jobs — D-19/HEAD-12), 69, 70, 75 |
| `preview --film-loaded [--intent …] [--film-process …]` | `preview.acquire` | `--film-loaded` | 0, 64 (`--intent replaceFilmProcess` with no `--film-process`, an unrecognized `--intent`, or an unrecognized `--film-process` value — refused client-side at parse time since WR-05, matching `roll save --film-process`'s own validation, rather than round-tripping to the host for the same 64), 65, 69, 70, 75, 77 |
| `frames list` / `frames select <range>\|--all\|--none\|--skip-blank [--blank-threshold <0..1>]` / `frames place <slot> --row-offset <rows>\|--from <file>\|--replay` / `frames include <range>` / `frames exclude <range>` | `frames.list` / `frames.select` (`--skip-blank` also sends a `frames.list` first, same connection) / `frames.place` / `frames.include` / `frames.exclude` | — | 0, 64 (invalid selection or placement syntax/values), 65 (also `include`/`exclude`'s documented partial-application rule), 69, 70, 75 |
| `review approve --confirm-motion` / `review cancel` | `review.approve` / `review.cancel` | `--confirm-motion` (`approve` only; `cancel` authorizes no motion and takes none) | 0, 65, 69, 70, 75, 77 (`approve` only) |
| `settings get` / `settings set […]` | `settings.get` / `settings.set` | — | 0, 65, 69, 70, 75 |
| `outputs get` / `outputs set […]` | `outputs.get` / `outputs.set` | — | 0, 65, 69, 70, 75 |
| `roll save --name … --carrier … --frame-count … --film-process … --confirm-motion [--wait] [--auto-approve]` / `roll open <directory>` / `roll list` | `roll.save`, then (only when its `outcome` is `manualReviewPending` and `--auto-approve` was given) `status` and, only if every flagged frame clears the bar, `review.approve` — all on the same connection / `roll.open` / `roll.list` | `--confirm-motion` (`save` only; `--auto-approve` requires it too, checked independently) | 0, 65, 69, 70, 75, 77 (`save`, also a `--wait`ed `failed` terminal state); 0, 65, 69, 70, 75 (`open`/`list`) |
| `roll run --name … --carrier … [--frame-count …] --film-process … --film-loaded --confirm-motion [--skip-blank] [--auto-approve] [--wait\|--no-wait]` (D-15/HEAD-09; see Run receipt, above) | `scanner.refresh`+`status` (with D-16's one permitted non-motion reconnect on `NOT_CONNECTED`) → `preview.acquire` → a bounded wait for `status.previewComplete` off the already-subscribed event stream → `frames.list`+`frames.select` → `roll.save` → (only when its `outcome` is `manualReviewPending`) `status` and, only when `--auto-approve` resolves it, `review.approve` → (when `--wait`, the default, and a job actually started) a wait for the job's terminal state — one connection throughout, stopping dead at the first refused step | `--film-loaded` **and** `--confirm-motion` (two independent parse-time gates) | 0, 64 (`--skip-blank` would select nothing, or no previewed frames exist), 65 (also a missing `--frame-count` with no scanner-reported default, and a `--wait`ed `failed` terminal state), 69 (also the event stream ending mid-wait), 70 (also a preview that never signals completion within the bound), 75, 77 |
| `scan --confirm-motion [--wait]` | `scan.start` | `--confirm-motion` | 0, 65 (also a `--wait`ed `failed` terminal state), 69, 70, 75, 77 |
| `stop [--immediate]` | `scan.stop` | — (stopping never starts motion) | 0, 65 (`GATE_REFUSED` when no job is active), 69, 70, 75 |
| `resume --confirm-motion [--wait]` | `scan.resume` | `--confirm-motion` | 0, 65 (also a `--wait`ed `failed` terminal state), 69, 70, 75, 77 |
| `eject --confirm-motion` | `scanner.eject` | `--confirm-motion` | 0, 65, 69, 70, 75, 77 |
| `diagnostics export --to <dir>` | `diagnostics.export` | — | 0, 64 (`directory` is relative, contains `..`, or does not exist), 69, 70 |
| `events --follow` | `events.subscribe`, then every subsequent event on that connection | — | 0, 64 (`--follow` omitted), 69, 70 |
| `host` / `host run` / `host stop` | Resident headless host lifecycle, or pidfile-verified stop | — | 0, 69, 70, 75 |

Two facts about this table a reader will otherwise get wrong:

- **`scanner.list` has no subcommand in Phase 2.** Device discovery is `rescan` (`scanner.rescan`); the currently connected device, if any, is reported by `status`, not by a listing command. A caller that wants "what's out there" calls `rescan`; a caller that wants "what am I connected to" calls `status`.
- **`roll save` is motion-confirmed at both layers, and the two layers are independent, not redundant.** The wire's own `roll.save` params carry `motionConfirmed`, refused with `CONFIRMATION_REQUIRED` before any `SessionModel` call if it is absent or `false` — closed at the wire by plan 02-01 Task 3 (`ControlRollSaveParams.motionConfirmed`). Threat register entry **T-02-27 is closed**: this wire-level gate plus the CLI's own layer below are the closing mitigation, not an open, standing risk. The CLI *additionally* requires `--confirm-motion` at parse time, before any connection opens — a tightening beyond D-08's literal `roll save --name` tree added by plan 02-05, mirroring `review.approve`'s identical precedent from Phase 1. The residual asymmetry, recorded here as a decision rather than a discovered surprise: `motionConfirmed` is a caller-supplied boolean like any other field, so a raw-socket caller bypassing the CLI entirely still decides its own value — the wire gate proves the field was sent as `true`, not that a human confirmed anything. The CLI's `--confirm-motion` flag is a second, independent gate at the layer a human or script most often touches; neither layer substitutes for the other.

## Not yet implemented

Recorded here so both gaps stay visible in the spec, not only in a plan:

- **Attended-scan-recovery approval** (`SessionModel.approveEveryFrameAndScan()`, the path behind `ContentView.swift`'s attended-retry banner) has no channel command yet. It approves every frame in the roll against a different confirmation contract than `review.approve`'s single-boundary approval and needs its own command; D-08's command tree does not include it, so this work is carried past Phase 2 to a later phase.

### Calibration project bootstrap

`roll.save` accepts optional `startScan: false` to create the project without
starting a preview or capture. This form does not require `motionConfirmed`;
it refuses an already saved roll or an active job and returns the normal save
result with `outcome: "saved"`. An omitted or true `startScan` preserves the
existing save-and-scan behavior and confirmation requirement.

### Observer EOF

`ControlChannelClient` synthesizes one `control.hostExited` event when an
established host connection reaches EOF. Payload: `{reason: "peerEOF",
hostPid: number}`. Ordinary local client shutdown emits no host-loss event.
CLI streaming observers report exit 76 after forwarding this event; finite
commands retain their actual response semantics. Status snapshots include
nullable `previewOperationId` for registration change detection.
