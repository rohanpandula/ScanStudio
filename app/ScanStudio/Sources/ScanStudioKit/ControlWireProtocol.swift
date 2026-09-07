// Codable mirror of the ScanStudio control channel wire protocol.
//
// Canonical source: `protocol/CONTROL.md`. JSON field names on the wire are
// camelCase and already match these types' Swift property names one-to-one,
// so no `CodingKeys` are needed anywhere in this file.
//
// D-01: this file adds only new leaf `Params`/`Result`/event-payload/
// error-payload types beside the engine's existing generic envelopes.
// `DecodedRequestEnvelope`, `EmptyParams`, `CaptureRecipe`,
// `ProcessingRecipe`, `OutputRecipe`, `DeviceInfo`, `ScannerStatus`,
// `JobState`, `FilmProcess`, and `SimulatedFilmCarrier` are declared in
// `WireProtocol.swift` and reused verbatim here, never redeclared. Those
// four generic envelopes (`RequestEnvelope`, `ResponseEnvelope`,
// `EventEnvelope`, `WireSniff`) are all `Decodable`-only or `Encodable`-only
// by design, oriented for `EngineClient` acting as a *client*; the control
// dispatcher is a *server*, so this file declares the encode-direction
// twins the server side needs, mirroring `WireProtocol.swift`'s own
// existing `RequestEnvelope`/`DecodedRequestEnvelope` direction-mirror
// convention. The JSON grammar stays byte-identical to the engine's.
//
// Everything here is `public` because both the `ScanStudio` executable and
// `ScanStudioKitTests` need to read these types across the module boundary;
// everything is also `Sendable`, matching `WireProtocol.swift`'s own rule.

import Foundation

// MARK: - Schema version

/// D-02: the control channel's schema version. The first request on any
/// connection must be `hello` carrying this value; a mismatch is refused
/// with a typed schema-version error before any other command runs. Every
/// version check anywhere in the channel reads this constant — no literal
/// `1` is written elsewhere.
public enum ControlSchema {
    public static let version = 1
}

// MARK: - Error vocabulary

/// D-03: the fixed set of channel-level refusal codes. Anything not listed
/// here that reaches a control caller is an engine- or bridge-originated
/// code passed through verbatim in `ControlErrorPayload.code` (a free
/// `String`, not this enum).
public enum ControlErrorCode: String, Codable, Sendable {
    case schemaVersionMismatch = "SCHEMA_VERSION_MISMATCH"
    case helloRequired = "HELLO_REQUIRED"
    case unknownCommand = "UNKNOWN_COMMAND"
    case invalidParams = "INVALID_PARAMS"
    case controllerBusy = "CONTROLLER_BUSY"
    case confirmationRequired = "CONFIRMATION_REQUIRED"
    case gateRefused = "GATE_REFUSED"
}

/// D-03: the normalized gate identifier a gate-refusal error carries.
/// RESEARCH Pitfall 8 catalogues four differently-shaped existing refusal
/// sources (`ScanReadinessPolicy.Decision`, `HardwareMotionReadiness`, a
/// bare `refeedRequired` flag, and manual-review/attendance pending state);
/// this enum is the one normalized vocabulary `ControlErrorPayload.gate`
/// carries for all four, so that error body always names which gate
/// refused.
public enum ControlGate: String, Codable, Sendable {
    case hardwareMotion = "hardwareMotionReadiness"
    case scanReadiness = "scanReadiness"
    case refeedRequired = "refeedRequired"
    case manualReviewPending = "manualReviewPending"
}

/// D-03: a lean control-channel error body. Unlike the engine's
/// `ErrorPayload` (`WireProtocol.swift`), this declares only the five
/// fields below and no hardware-diagnostic payload of any kind — a pure
/// app-level channel refusal (busy controller, gate refusal) has nothing
/// like that to attach, and a policy refusal must leak no hardware
/// diagnostic detail (T-01-05). `code` is a free `String`, not
/// `ControlErrorCode`, precisely so an engine- or bridge-originated code
/// (`NOT_CONNECTED`, `FEED_JAM`, ...) and its `recoverable` flag pass
/// through verbatim (D-03). The synthesized `Codable` conformance is
/// correct here — there is no additive, forward-compatible-decode
/// requirement driving a hand-written one like `ErrorPayload`'s.
public struct ControlErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let recoverable: Bool
    public let guidance: String?
    public let gate: String?

    /// A channel-level refusal. Always non-recoverable — a busy or gated
    /// caller must act differently, never retry the identical request.
    public init(
        _ code: ControlErrorCode,
        message: String,
        guidance: String? = nil,
        gate: ControlGate? = nil
    ) {
        self.code = code.rawValue
        self.message = message
        self.recoverable = false
        self.guidance = guidance
        self.gate = gate?.rawValue
    }

    /// Pass-through for an engine- or bridge-originated failure: the raw
    /// code and its recoverable flag cross the channel exactly as reported
    /// (D-03), with no remapping.
    public init(
        code: String,
        message: String,
        recoverable: Bool,
        guidance: String? = nil,
        gate: String? = nil
    ) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
        self.guidance = guidance
        self.gate = gate
    }
}

// MARK: - Encode-direction envelope mirrors

/// Encode-direction twin of `WireProtocol.swift`'s `ResponseEnvelope`
/// (`Decodable`-only there, built for `EngineClient` acting as a client).
/// The control dispatcher is the server end of this channel, so it must
/// *encode* the response it sends back.
public struct ControlResponseEnvelope<Result: Encodable>: Encodable {
    public let id: UInt64
    public let result: Result

    public init(id: UInt64, result: Result) {
        self.id = id
        self.result = result
    }
}

/// Encode-direction twin of `WireProtocol.swift`'s `ResponseErrorEnvelope`,
/// hard-wired to `ControlErrorPayload` instead of the engine's own
/// `ErrorPayload`.
public struct ControlResponseErrorEnvelope: Codable, Equatable, Sendable {
    public let id: UInt64
    public let error: ControlErrorPayload

    public init(id: UInt64, error: ControlErrorPayload) {
        self.id = id
        self.error = error
    }
}

/// Encode-direction twin of `WireProtocol.swift`'s `EventEnvelope`.
public struct ControlEventEnvelope<Payload: Encodable>: Encodable {
    public let event: String
    public let payload: Payload

    public init(event: String, payload: Payload) {
        self.event = event
        self.payload = payload
    }
}

/// Encode-direction twin of `WireProtocol.swift`'s `EmptyResult`
/// (`Decodable`-only there, since the app only ever receives it; the
/// dispatcher must construct and encode one).
public struct ControlEmptyResult: Codable, Equatable, Sendable {
    public init() {}
}

// MARK: - Request-side method sniff

/// Request-side counterpart to `WireProtocol.swift`'s `WireSniff`: a cheap,
/// partial decode used to classify an incoming request line by its
/// `method` before the full typed `params` decode (the dispatcher's
/// two-phase decode).
public struct ControlMethodSniff: Decodable, Sendable {
    public let id: UInt64
    public let method: String
}

// MARK: - hello

public struct ControlHelloParams: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let clientName: String
    public let clientBuild: String?

    public init(schemaVersion: Int, clientName: String, clientBuild: String? = nil) {
        self.schemaVersion = schemaVersion
        self.clientName = clientName
        self.clientBuild = clientBuild
    }
}

public struct ControlHelloResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let appName: String
    public let appVersion: String?

    public init(schemaVersion: Int, appName: String, appVersion: String? = nil) {
        self.schemaVersion = schemaVersion
        self.appName = appName
        self.appVersion = appVersion
    }
}

// MARK: - Confirmation-bearing params (D-08)
//
// D-08: a missing confirmation must be refused with a typed confirmation
// error, never treated as an invalid-params failure, and no field default
// may mean "confirmed". Declaring each flag as an optional satisfies both:
// an absent wire key decodes to `nil`, and the dispatcher treats anything
// other than an explicit `true` as unconfirmed. These five structs are
// decoded, never hand-constructed outside tests, so — like
// `WireProtocol.swift`'s own decode-only leaf types (`ProjectSummary`,
// `WireSniff`) — they declare no custom initializer; the compiler's own
// memberwise one (visible to `ScanStudioKitTests` via `@testable import`)
// is sufficient, and guarantees every field must be supplied explicitly
// rather than silently defaulting.

public struct ControlPreviewAcquireParams: Codable, Equatable, Sendable {
    public let filmLoadedConfirmed: Bool?
    /// `"initial"` | `"replaceFilmProcess"` | `"refreshSavedProject"`;
    /// an absent key means `"initial"`.
    public let intent: String?
    public let filmProcess: FilmProcess?
}

public struct ControlScanStartParams: Codable, Equatable, Sendable {
    public let motionConfirmed: Bool?
}

public struct ControlScanResumeParams: Codable, Equatable, Sendable {
    public let motionConfirmed: Bool?
}

public struct ControlScannerEjectParams: Codable, Equatable, Sendable {
    public let motionConfirmed: Bool?
}

/// Carries a confirmation flag because it routes to
/// `SessionModel.approvePendingManualReviewAndStart()`, which starts a
/// scan — the method name alone does not advertise the motion.
public struct ControlReviewApproveParams: Codable, Equatable, Sendable {
    public let motionConfirmed: Bool?
}

// MARK: - Remaining params

public struct ControlScannerConnectParams: Codable, Equatable, Sendable {
    public let deviceId: String?

    public init(deviceId: String? = nil) {
        self.deviceId = deviceId
    }
}

/// Shared by `frames.include` and `frames.exclude` — both act on exactly
/// one frame index.
public struct ControlFrameSelectionParams: Codable, Equatable, Sendable {
    public let frameIndex: Int

    public init(frameIndex: Int) {
        self.frameIndex = frameIndex
    }
}

/// `frames.select` (CR-02): bulk, pre-project frame selection, so a
/// socket-only caller can populate `SessionModel.selectedFrameIndices`
/// before any project exists -- unblocking `roll.save`'s own "select at
/// least one frame" precondition for a cold CLI/attach-mode session that
/// never drives a GUI. Exactly one of `indices`/`all`/`none` must be
/// present; the dispatcher refuses `INVALID_PARAMS` otherwise. Not a
/// motion command -- no confirmation field. Once a project exists, this
/// command is refused (`GATE_REFUSED`, no gate) in favor of
/// `frames.include`/`frames.exclude`'s per-frame refinement.
public struct ControlFramesSelectParams: Codable, Equatable, Sendable {
    public let indices: [Int]?
    public let all: Bool?
    public let none: Bool?

    public init(indices: [Int]? = nil, all: Bool? = nil, none: Bool? = nil) {
        self.indices = indices
        self.all = all
        self.none = none
    }
}

/// `mode` is `"afterCurrentFrame"` (the absent-key default) or
/// `"immediate"` — no other value is accepted.
public struct ControlScanStopParams: Codable, Equatable, Sendable {
    public let mode: String?

    public init(mode: String? = nil) {
        self.mode = mode
    }
}

/// D-08: carries a confirmation flag because `roll.save` routes to
/// `saveRollAndScanSelectedFrames(name:carrier:frameCount:filmProcess:)`,
/// which creates the project and immediately starts the scan of the
/// selected frames -- the method name alone does not advertise that. `nil`
/// and `false` both mean unconfirmed, exactly like `ControlScanStartParams`.
/// No custom initializer, matching the five confirmation-bearing params
/// above: the compiler's own memberwise one (visible to
/// `ScanStudioKitTests` via `@testable import`) is sufficient.
public struct ControlRollSaveParams: Codable, Equatable, Sendable {
    public let name: String
    public let carrier: SimulatedFilmCarrier
    public let frameCount: Int
    public let filmProcess: FilmProcess
    public let motionConfirmed: Bool?
}

public struct ControlRollOpenParams: Codable, Equatable, Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }
}

public struct ControlSettingsSetParams: Codable, Equatable, Sendable {
    public let capture: CaptureRecipe
    public let processing: ProcessingRecipe

    public init(capture: CaptureRecipe, processing: ProcessingRecipe) {
        self.capture = capture
        self.processing = processing
    }
}

public struct ControlOutputsSetParams: Codable, Equatable, Sendable {
    public let outputs: OutputRecipe

    public init(outputs: OutputRecipe) {
        self.outputs = outputs
    }
}

public struct ControlDiagnosticsExportParams: Codable, Equatable, Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }
}

// MARK: - Result mirror types
//
// `SessionModel.ScanProgress` and `WireProtocol.swift`'s `ProjectSummary`
// are each missing one direction this channel needs on the wire
// (`ScanProgress` is `Equatable, Sendable` only — no `Codable`;
// `ProjectSummary` is `Decodable` only — no `Encodable` or `Equatable`).
// Both are leaf, display-shaped data with no engine-private handles, so
// rather than retrofitting cross-module conformances onto types owned
// elsewhere, this file declares its own small mirrors — matching this same
// file's `ControlFrameSummary` precedent below, and D-01's own rule that a
// control-channel result is "built from SessionModel state," not a literal
// reuse of every existing type regardless of shape.

/// Mirrors `SessionModel.ScanProgress`'s fields for the wire.
public struct ControlScanProgress: Codable, Equatable, Sendable {
    public let jobId: String
    public let frameIndex: Int
    public let frameOrdinal: Int
    public let totalFrames: Int
    public let pass: Int
    public let totalPasses: Int
    public let framePercent: Double
    public let jobPercent: Double
    public let etaSeconds: Double

    public init(
        jobId: String,
        frameIndex: Int,
        frameOrdinal: Int,
        totalFrames: Int,
        pass: Int,
        totalPasses: Int,
        framePercent: Double,
        jobPercent: Double,
        etaSeconds: Double
    ) {
        self.jobId = jobId
        self.frameIndex = frameIndex
        self.frameOrdinal = frameOrdinal
        self.totalFrames = totalFrames
        self.pass = pass
        self.totalPasses = totalPasses
        self.framePercent = framePercent
        self.jobPercent = jobPercent
        self.etaSeconds = etaSeconds
    }
}

/// Mirrors `WireProtocol.swift`'s `ProjectSummary` fields for the wire.
public struct ControlProjectSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let carrier: SimulatedFilmCarrier
    public let frameCount: Int
    public let filmProcess: FilmProcess
    public let createdAt: String
    public let directory: String

    public init(
        id: String,
        name: String,
        carrier: SimulatedFilmCarrier,
        frameCount: Int,
        filmProcess: FilmProcess,
        createdAt: String,
        directory: String
    ) {
        self.id = id
        self.name = name
        self.carrier = carrier
        self.frameCount = frameCount
        self.filmProcess = filmProcess
        self.createdAt = createdAt
        self.directory = directory
    }
}

// MARK: - Results

/// SAFE-04 (Gap 2 fix): a single recorded wire-level refusal, carried on
/// `ControlStatusResult.lastControlRefusal` so it reaches every subscriber
/// on every connection via `control.snapshot`/`control.changed` -- not
/// only the requesting connection's own direct RPC response. `code` is a
/// free `String` (the exact `ControlErrorPayload.code`/engine-passthrough
/// code the refusal carried), `gate` mirrors `ControlErrorPayload.gate`
/// (`nil` for a non-gate refusal). `sequence` is a monotonically
/// increasing counter (never reset), so a follower can tell two refusals
/// with identical `command`/`code`/`gate` apart -- for example the same
/// command refused twice in a row for the same reason.
public struct ControlRefusalRecord: Codable, Equatable, Sendable {
    public let command: String?
    public let code: String
    public let gate: String?
    public let timestamp: String
    public let sequence: UInt64

    public init(command: String?, code: String, gate: String?, timestamp: String, sequence: UInt64) {
        self.command = command
        self.code = code
        self.gate = gate
        self.timestamp = timestamp
        self.sequence = sequence
    }
}

/// A full session snapshot built from `SessionModel` public state only.
/// `hardwareMotionReadiness` and `scanReadiness` carry their enum case
/// names as stable strings (computed by the dispatcher) so a caller can
/// branch on them without either enum leaking into the wire vocabulary.
public struct ControlStatusResult: Codable, Equatable, Sendable {
    public let device: DeviceInfo?
    public let scanner: ScannerStatus?
    public let projectName: String?
    public let projectDirectory: String?
    public let jobId: String?
    public let jobState: JobState?
    public let refeedRequired: Bool
    public let hardwareMotionReadiness: String
    public let motionAllowed: Bool
    public let motionGuidance: String?
    public let mutatingOperationInFlight: String?
    public let selectedFrames: [Int]
    public let scanReadiness: String
    public let scanReadinessReason: String?
    public let lastErrorMessage: String?
    public let lastControlRefusal: ControlRefusalRecord?

    public init(
        device: DeviceInfo? = nil,
        scanner: ScannerStatus? = nil,
        projectName: String? = nil,
        projectDirectory: String? = nil,
        jobId: String? = nil,
        jobState: JobState? = nil,
        refeedRequired: Bool,
        hardwareMotionReadiness: String,
        motionAllowed: Bool,
        motionGuidance: String? = nil,
        mutatingOperationInFlight: String? = nil,
        selectedFrames: [Int],
        scanReadiness: String,
        scanReadinessReason: String? = nil,
        lastErrorMessage: String? = nil,
        lastControlRefusal: ControlRefusalRecord? = nil
    ) {
        self.device = device
        self.scanner = scanner
        self.projectName = projectName
        self.projectDirectory = projectDirectory
        self.jobId = jobId
        self.jobState = jobState
        self.refeedRequired = refeedRequired
        self.hardwareMotionReadiness = hardwareMotionReadiness
        self.motionAllowed = motionAllowed
        self.motionGuidance = motionGuidance
        self.mutatingOperationInFlight = mutatingOperationInFlight
        self.selectedFrames = selectedFrames
        self.scanReadiness = scanReadiness
        self.scanReadinessReason = scanReadinessReason
        self.lastErrorMessage = lastErrorMessage
        self.lastControlRefusal = lastControlRefusal
    }
}

/// `errorCode` carries only `ErrorPayload.code`, never the whole payload
/// and never any hardware diagnostic detail (T-01-05).
public struct ControlFrameSummary: Codable, Equatable, Sendable {
    public let index: Int
    public let excluded: Bool
    public let selected: Bool
    public let hasThumbnail: Bool
    public let state: String?
    public let manualReviewDecision: String?
    public let errorCode: String?

    public init(
        index: Int,
        excluded: Bool,
        selected: Bool,
        hasThumbnail: Bool,
        state: String? = nil,
        manualReviewDecision: String? = nil,
        errorCode: String? = nil
    ) {
        self.index = index
        self.excluded = excluded
        self.selected = selected
        self.hasThumbnail = hasThumbnail
        self.state = state
        self.manualReviewDecision = manualReviewDecision
        self.errorCode = errorCode
    }
}

public struct ControlFramesListResult: Codable, Equatable, Sendable {
    public let frames: [ControlFrameSummary]
    public let selectedFrames: [Int]

    public init(frames: [ControlFrameSummary], selectedFrames: [Int]) {
        self.frames = frames
        self.selectedFrames = selectedFrames
    }
}

/// `frameErrorCodes` maps a stringified frame index to a bare
/// `ErrorPayload.code` string — codes only, never a full error payload.
public struct ControlJobResult: Codable, Equatable, Sendable {
    public let jobId: String?
    public let jobState: JobState?
    public let progress: ControlScanProgress?
    public let completedFrameCount: Int
    public let pendingFrameCount: Int
    public let receiptCount: Int
    public let frameErrorCodes: [String: String]

    public init(
        jobId: String? = nil,
        jobState: JobState? = nil,
        progress: ControlScanProgress? = nil,
        completedFrameCount: Int,
        pendingFrameCount: Int,
        receiptCount: Int,
        frameErrorCodes: [String: String] = [:]
    ) {
        self.jobId = jobId
        self.jobState = jobState
        self.progress = progress
        self.completedFrameCount = completedFrameCount
        self.pendingFrameCount = pendingFrameCount
        self.receiptCount = receiptCount
        self.frameErrorCodes = frameErrorCodes
    }
}

public struct ControlSettingsResult: Codable, Equatable, Sendable {
    public let capture: CaptureRecipe
    public let processing: ProcessingRecipe

    public init(capture: CaptureRecipe, processing: ProcessingRecipe) {
        self.capture = capture
        self.processing = processing
    }
}

public struct ControlOutputsResult: Codable, Equatable, Sendable {
    public let outputs: OutputRecipe

    public init(outputs: OutputRecipe) {
        self.outputs = outputs
    }
}

public struct ControlScannerListResult: Codable, Equatable, Sendable {
    public let devices: [DeviceInfo]

    public init(devices: [DeviceInfo]) {
        self.devices = devices
    }
}

public struct ControlRollListResult: Codable, Equatable, Sendable {
    public let projects: [ControlProjectSummary]

    public init(projects: [ControlProjectSummary]) {
        self.projects = projects
    }
}

public struct ControlRollSaveResult: Codable, Equatable, Sendable {
    public let saved: Bool
    public let projectName: String?
    public let projectDirectory: String?

    public init(saved: Bool, projectName: String? = nil, projectDirectory: String? = nil) {
        self.saved = saved
        self.projectName = projectName
        self.projectDirectory = projectDirectory
    }
}

/// `outcome` is the `PreviewRequestOutcome` case name (`"started"` |
/// `"rejected"` | `"failedToStart"`), computed by the dispatcher.
public struct ControlPreviewAcquireResult: Codable, Equatable, Sendable {
    public let outcome: String
    public let intentToken: String

    public init(outcome: String, intentToken: String) {
        self.outcome = outcome
        self.intentToken = intentToken
    }
}

public struct ControlDiagnosticsExportResult: Codable, Equatable, Sendable {
    public let path: String
    public let entries: [String]

    public init(path: String, entries: [String]) {
        self.path = path
        self.entries = entries
    }
}

public struct ControlEventsSubscribeResult: Codable, Equatable, Sendable {
    public let subscribed: Bool
    public let snapshot: ControlStatusResult

    public init(subscribed: Bool, snapshot: ControlStatusResult) {
        self.subscribed = subscribed
        self.snapshot = snapshot
    }
}
