# Scan Studio Control Channel Protocol v1

Contract for the local control channel that lets a CLI, a script, or an agent drive a running ScanStudio app the same way the GUI does. Every command maps onto exactly one existing `SessionModel` workflow method — the same method the GUI calls — so the GUI and the control channel can never disagree about what is allowed. This file is canonical; Swift types live in `ScanStudioKit/ControlWireProtocol.swift`.

## Transport

- The wire grammar is line-framed NDJSON with the same envelope shapes as `PROTOCOL.md`'s engine protocol:
  - **Request** (caller → dispatcher): `{"id": <u64>, "method": "<name>", "params": {…}}`.
  - **Response** (dispatcher → caller): `{"id": <u64>, "result": {…}}` or `{"id": <u64>, "error": {"code": "<CODE>", "message": "<human text>", "recoverable": <bool>, "guidance": "<text>", "gate": "<name>"}}`. Every request gets exactly one response.
  - **Event** (dispatcher → caller, unsolicited): `{"event": "<name>", "payload": {…}}`. Events may interleave with responses.
- The concrete socket transport (Unix-domain socket path, permissions, stale-socket handling) is Phase 2's decision and is deliberately unspecified here.
- In Phase 1 the dispatcher is in-process and transport-agnostic by construction (D-06): it accepts a decoded request value and returns an encodable response value, so Phase 2's socket server and any in-process test harness call the same API.
- JSON field names are camelCase on the wire, matching `ControlWireProtocol.swift`'s property names one-to-one.

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

When a failure originates in the engine or the bridge instead of the channel itself, the error body carries the engine's own `code` and `recoverable` flag verbatim rather than remapping them to one of the codes above — the same `NOT_CONNECTED`, `FEED_JAM`, or similar code the GUI would see reaches the caller unchanged.

A `GATE_REFUSED` body additionally carries `gate`, naming which gate refused (one of `hardwareMotionReadiness`, `scanReadiness`, `refeedRequired`, `manualReviewPending`), and `guidance`, the same operator-facing explanation the GUI would show next to a disabled action.

Every channel-level code above is `recoverable: false` — a refusal always requires the caller to change something (confirm, wait, resolve the gate) before retrying, never to retry the identical request unchanged. Channel error bodies never carry hardware diagnostic detail; a policy refusal exposes only `code`, `message`, `recoverable`, `guidance`, and `gate`.

## Methods

_Command entries land in Plan 06 (see CTRL-07 for Phase 2's completion of this file)._
