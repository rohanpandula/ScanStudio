# SessionStore — TS port of the macOS SessionModel (Phase 4)

The `SessionStore` is the TypeScript, platform-agnostic replacement for the
macOS SwiftUI `SessionModel`. It drives the existing Rust scan engine over
NDJSON-over-stdio through an `EngineTransport`, holds the full session state,
and enforces every safety policy the macOS app enforces today. It contains no
UI code and no engine code: it is a thin, policy-bearing client.

## Wire contract

- Requests: `sendRequest(method, params)` — methods come from
  `protocol/PROTOCOL.md` (`scanner.*`, `roll.*`, `project.*`, `scan.*`,
  `sim.*`, `engine.*`).
- Events: `subscribeEvents((raw) => void)` — `scanner.status`,
  `scanner.thumbnail`, `scanner.thumbnailsComplete`, `scanner.thumbnailsFailed`,
  `scan.jobState`, `scan.frameState`, `scan.frameCompleted`, `scan.completed`,
  `scan.stopped`, `scan.failed`.
- Errors: rejections are always `EngineError` — `{ code, message, recoverable }`.
  Wire-sourced errors reach the caller byte-for-byte; local pre-wire-call policy
  rejections (e.g. `INVALID_PARAMS`) use the identical shape.
- Two transports ship with the tests: `createScriptedTransport` (unit tests,
  deterministic) and `createSubprocessTransport` (real engine binary,
  env-gated on `SCANSTUDIO_ENGINE_PATH`).

## Public API

- `subscribe(listener)` / `getState()` — deeply cloned state snapshots
  (`structuredClone`; no shared references with internal state, so external
  mutation cannot corrupt the store); listeners fire on every state change.
- `onIntegrityError(callback)` — engine-badness escapes hatch (decode failures,
  state-machine violations) that never throws into the webview.
- `connect(deviceId, options?)` / `disconnect()` / `listDevices()` /
  `refreshStatus()` — device session. A new successful connect invalidates the
  preview-operation token.
- `loadMedia(carrier)` — loads `roll36` | `strip6` | `mounted`; success
  invalidates the preview-operation token.
- `acquireThumbnails(frames?, filmProcess?)` — one active preview at a time;
  each accepted preview gets a fresh `crypto.randomUUID()` operationId that all
  subsequent thumbnail events must echo.
- `approveFrame(frameIndex)` — records manual approval bound to the current
  completed preview's operationId; required for `needsApproval` tiles.
- `setSpacingOffset(frameIndex, offsetRows)` — bounds-checked (0..144 rows on
  frame 1, +/-144 on others); the server-returned replacement thumbnail is
  stored verbatim; changing an offset invalidates prior approval for that
  frame.
- `setFrameAlignmentDraft(frameIndex, offsetRows)` — UI draft; applied as a
  spacing offset automatically when the next preview completes (replayed on
  the post-preview status event).
- `createProject(name, directory?)` / `openProject(directory)` /
  `listProjects(directory?)` — project CRUD. A successful create/open resets
  the preview-operation token, approvals, thumbnail provenance, alignment
  drafts (rebuilt from the loaded project's frames), and the job id — nothing
  leaks across projects.
- `startScan(frames, capture, processing?, output?, frameAlignments?)` —
  validates and mirrors the recipe locally (bwNegative forces `channels: "rgb"`
  and disables ICE on the capture recipe; retained-output and
  processing-override rules), gates the whole batch on `needsApproval` (tiles
  must be bound to the current completed preview's operationId) and
  failed-replay recovery, then sends `scan.start`. Scan events are jobId-scoped:
  events for any other job are dropped, and events that arrive before the
  `scan.start` response are buffered and applied once the jobId is established.
- `stopJob(jobId, mode)` / `skipCurrentFrame(jobId)` / `resumeJob(jobId)` /
  `pendingFrames()` — job control.

## State model

`SessionState` exposes `connection`, `media`, `jobState`, `jobId`,
`frameStates`, `frameAttempts`, `frameErrors`, `jobErrors`, `thumbnails`,
`thumbnailOperationIds`, `activeOperationId`,
`latestCompletedPreviewOperationId`, `approvedFrames`,
`frameAlignmentDrafts`, `failedFrameAlignmentReplayIndices`, `projects`,
`previewOutcome`, `previewError`, `selectedFrameIndices`.
Frame/job transitions are enforced by `machines.ts`; violations are reported
through `onIntegrityError`, never silently absorbed.

- `previewOutcome: "active" | "succeeded" | "failed" | null` — mirrors the
  internal preview-correlation tracker so a failed preview is observable
  (without it, a failed preview is indistinguishable from "never previewed").
  `"active"` while an accepted preview is in flight, `"succeeded"` after a
  correlated `scanner.thumbnailsComplete`, `"failed"` after a correlated
  `scanner.thumbnailsFailed` (a zero-count completion keeps it `"failed"`),
  `null` before any preview, on wire rejection, and after `loadMedia` or a
  project change resets the session binding.
- `previewError: { code, message } | null` — the correlated
  `scanner.thumbnailsFailed`'s wire payload verbatim (null on any reset);
  views render the engine's own diagnosis, never invented copy.
- `selectedFrameIndices: number[]` — subscriber-only UI selection state
  (05-03): frames `1..status.frameCount` selected via
  `toggleFrameSelection`/`selectAll`/`clearSelection`. No wire call is
  attached; it survives unrelated store notifications and is reset only by
  the selection methods themselves.

## Metadata and defect operations

The store implements roll metadata, per-frame metadata overrides, ExifTool
detection, metadata-command preview and application, and frame-defect
analysis. Each method delegates to the corresponding wire command and keeps
the engine's result and error semantics intact.

## Out of scope

`setFrameOffsets` remains out of scope as a separate dedicated manual mode.
