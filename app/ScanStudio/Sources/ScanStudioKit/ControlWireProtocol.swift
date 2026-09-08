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
    public let hardwareVerification: String

    public init(id: UInt64, result: Result, hardwareVerification: String = "notConnected") {
        self.id = id
        self.result = result
        self.hardwareVerification = hardwareVerification
    }
}

/// Encode-direction twin of `WireProtocol.swift`'s `ResponseErrorEnvelope`,
/// hard-wired to `ControlErrorPayload` instead of the engine's own
/// `ErrorPayload`.
public struct ControlResponseErrorEnvelope: Codable, Equatable, Sendable {
    public let id: UInt64
    public let error: ControlErrorPayload
    public let hardwareVerification: String

    public init(id: UInt64, error: ControlErrorPayload, hardwareVerification: String = "notConnected") {
        self.id = id
        self.error = error
        self.hardwareVerification = hardwareVerification
    }

    private enum CodingKeys: String, CodingKey { case id, error, hardwareVerification }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt64.self, forKey: .id)
        error = try c.decode(ControlErrorPayload.self, forKey: .error)
        hardwareVerification = try c.decodeIfPresent(String.self, forKey: .hardwareVerification) ?? "notConnected"
    }
}

/// Encode-direction twin of `WireProtocol.swift`'s `EventEnvelope`.
public struct ControlEventEnvelope<Payload: Encodable>: Encodable {
    public let event: String
    public let payload: Payload
    public let hardwareVerification: String

    public init(event: String, payload: Payload, hardwareVerification: String = "notConnected") {
        self.event = event
        self.payload = payload
        self.hardwareVerification = hardwareVerification
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

/// D-04: identifies which process owns a control socket.
public enum ControlHostKind: String, Codable, Sendable, Equatable {
    case gui
    case headless
}

public struct ControlHelloResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let appName: String
    public let appVersion: String?
    public let host: ControlHostKind
    public let hostPid: Int32

    public init(
        schemaVersion: Int,
        appName: String,
        appVersion: String? = nil,
        host: ControlHostKind = .gui,
        hostPid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.schemaVersion = schemaVersion
        self.appName = appName
        self.appVersion = appVersion
        self.host = host
        self.hostPid = hostPid
    }
}

// MARK: - Confirmation-bearing params (D-08)
//
// D-08: a missing confirmation must be refused with a typed confirmation
// error, never treated as an invalid-params failure, and no field default
// may mean "confirmed". Declaring each flag as an optional satisfies both:
// an absent wire key decodes to `nil`, and the dispatcher treats anything
// other than an explicit `true` as unconfirmed.
//
// WR-05: these five structs previously declared no custom initializer, on
// the theory that they are "decoded, never hand-constructed outside
// tests" -- relying on the compiler's own memberwise one, `internal` and
// therefore invisible outside `@testable import`. In practice the CLI
// target (a plain `import ScanStudioKit`, never `@testable`) does need to
// *construct* these to send requests, and hand-duplicated a private
// mirror struct per command in `Commands/*.swift` instead, matching field
// names by hand with no compile-time or test-level check that they stayed
// in sync with these canonical types (a future rename/add/remove here
// would compile cleanly on both sides independently). Each now has an
// explicit `public init`, so the CLI encodes these canonical types
// directly -- the mirrors are gone.

public struct ControlPreviewAcquireParams: Codable, Equatable, Sendable {
    public let filmLoadedConfirmed: Bool?
    /// `"initial"` | `"replaceFilmProcess"` | `"refreshSavedProject"`;
    /// an absent key means `"initial"`.
    public let intent: String?
    public let filmProcess: FilmProcess?

    public init(filmLoadedConfirmed: Bool?, intent: String? = nil, filmProcess: FilmProcess? = nil) {
        self.filmLoadedConfirmed = filmLoadedConfirmed
        self.intent = intent
        self.filmProcess = filmProcess
    }
}

public struct ControlScanStartParams: Codable, Equatable, Sendable {
    public let motionConfirmed: Bool?
    public let frames: [Int]?
    public let passToken: String?

    public init(motionConfirmed: Bool?, frames: [Int]? = nil, passToken: String? = nil) {
        self.motionConfirmed = motionConfirmed
        self.frames = frames
        self.passToken = passToken
    }
}

public struct ControlRollSolveExposureParams: Codable, Equatable, Sendable {
    public let frame: Int
    public let motionConfirmed: Bool?

    public init(frame: Int, motionConfirmed: Bool?) {
        self.frame = frame
        self.motionConfirmed = motionConfirmed
    }
}

public struct ControlScanResumeParams: Codable, Equatable, Sendable {
    public let motionConfirmed: Bool?

    public init(motionConfirmed: Bool?) {
        self.motionConfirmed = motionConfirmed
    }
}

public struct ControlScannerEjectParams: Codable, Equatable, Sendable {
    public let motionConfirmed: Bool?

    public init(motionConfirmed: Bool?) {
        self.motionConfirmed = motionConfirmed
    }
}

/// Carries a confirmation flag because it routes to
/// `SessionModel.approvePendingManualReviewAndStart()`, which starts a
/// scan — the method name alone does not advertise the motion.
public struct ControlReviewApproveParams: Codable, Equatable, Sendable {
    public let motionConfirmed: Bool?

    public init(motionConfirmed: Bool?) {
        self.motionConfirmed = motionConfirmed
    }
}

// MARK: - Remaining params

public struct ControlScannerConnectParams: Codable, Equatable, Sendable {
    public let deviceId: String?
    public let allowUnverifiedHardware: Bool

    public init(deviceId: String? = nil, allowUnverifiedHardware: Bool = false) {
        self.deviceId = deviceId
        self.allowUnverifiedHardware = allowUnverifiedHardware
    }

    private enum CodingKeys: String, CodingKey { case deviceId, allowUnverifiedHardware }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        allowUnverifiedHardware = try c.decodeIfPresent(Bool.self, forKey: .allowUnverifiedHardware) ?? false
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

/// One project frame's absolute placement in native preview rows. Slot 1
/// cannot move above the first preview row, so its accepted range is
/// `0...144`; later slots accept `-144...144`.
public struct ControlFramePlacement: Codable, Equatable, Sendable {
    public let slot: Int
    public let rowOffset: Int

    public init(slot: Int, rowOffset: Int) {
        self.slot = slot
        self.rowOffset = rowOffset
    }
}

/// `frames.place`: exactly one of `replay == true` or a placement payload
/// is accepted. `rows` are manual boundary rows for `roll.manualFrames`;
/// `placements` are then applied in ascending slot order through the
/// preview-bound spacing-offset and project-alignment paths.
public struct ControlFramesPlaceParams: Codable, Equatable, Sendable {
    public let rows: [Int]?
    public let placements: [ControlFramePlacement]?
    public let replay: Bool

    public init(
        rows: [Int]? = nil,
        placements: [ControlFramePlacement]? = nil,
        replay: Bool = false
    ) {
        self.rows = rows
        self.placements = placements
        self.replay = replay
    }

    private enum CodingKeys: String, CodingKey { case rows, placements, replay }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent([Int].self, forKey: .rows)
        placements = try container.decodeIfPresent(
            [ControlFramePlacement].self,
            forKey: .placements
        )
        replay = try container.decodeIfPresent(Bool.self, forKey: .replay) ?? false
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
/// WR-05: has an explicit `public init`, matching the five confirmation-
/// bearing params above, so the CLI can construct this canonical type
/// directly instead of hand-duplicating a private mirror struct.
public struct ControlRollSaveParams: Codable, Equatable, Sendable {
    public let name: String
    public let carrier: SimulatedFilmCarrier
    public let frameCount: Int
    public let filmProcess: FilmProcess
    public let motionConfirmed: Bool?

    public init(name: String, carrier: SimulatedFilmCarrier, frameCount: Int, filmProcess: FilmProcess, motionConfirmed: Bool?) {
        self.name = name
        self.carrier = carrier
        self.frameCount = frameCount
        self.filmProcess = filmProcess
        self.motionConfirmed = motionConfirmed
    }
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
    /// D-15: additive. `true` once the most recent preview operation has
    /// reached `scanner.thumbnailsComplete` (mirrors
    /// `SessionModel.latestCompletedPreviewOperationId != nil` verbatim).
    /// Before a project exists this is the **only** wire-visible proof a
    /// preview finished -- `scanReadiness` reports `projectRequired` at
    /// that point regardless, so it cannot stand in for this. Defaults to
    /// `false` so every existing construction site keeps compiling.
    public let previewComplete: Bool
    /// D-17: additive. `control.changed`'s snapshot previously carried
    /// `jobId`/`jobState` but not live progress, leaving `--wait`'s stderr
    /// progress sink with no way to observe it without an extra `job.get`
    /// poll (forbidden by SAFE-02's "exactly one subscribe, one final
    /// fetch" contract). Populating it here -- the same `mapScanProgress`
    /// `job.get`'s own result already uses -- makes it observable from
    /// bytes a subscriber already receives, at no new request cost. `nil`
    /// when no job is active; omitted from the wire entirely then
    /// (`encodeIfPresent`), so an older client parsing this envelope is
    /// unaffected.
    public let progress: ControlScanProgress?
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
    /// D-13/HEAD-07, additive: `nil` (and omitted from the wire) when
    /// nothing is pending. See `ControlManualReviewPending`'s own doc
    /// comment for why this reaches `status`/`control.snapshot`/
    /// `control.changed` from a single source.
    public let manualReviewPending: ControlManualReviewPending?
    /// D-22/HEAD-12: the engine's own authoritative resume set
    /// (`SessionModel.pendingFrames`, refreshed from `project.pendingFrames`)
    /// -- so a script can see what a `resume` would scan before asking for
    /// motion, and so excluding a frame after a failed batch is visible
    /// here immediately, without re-opening the roll.
    public let pendingFrames: [Int]

    public init(
        device: DeviceInfo? = nil,
        scanner: ScannerStatus? = nil,
        projectName: String? = nil,
        projectDirectory: String? = nil,
        jobId: String? = nil,
        jobState: JobState? = nil,
        previewComplete: Bool = false,
        progress: ControlScanProgress? = nil,
        refeedRequired: Bool,
        hardwareMotionReadiness: String,
        motionAllowed: Bool,
        motionGuidance: String? = nil,
        mutatingOperationInFlight: String? = nil,
        selectedFrames: [Int],
        scanReadiness: String,
        scanReadinessReason: String? = nil,
        lastErrorMessage: String? = nil,
        lastControlRefusal: ControlRefusalRecord? = nil,
        manualReviewPending: ControlManualReviewPending? = nil,
        pendingFrames: [Int] = []
    ) {
        self.device = device
        self.scanner = scanner
        self.projectName = projectName
        self.projectDirectory = projectDirectory
        self.jobId = jobId
        self.jobState = jobState
        self.previewComplete = previewComplete
        self.progress = progress
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
        self.manualReviewPending = manualReviewPending
        self.pendingFrames = pendingFrames
    }
}

/// `errorCode` carries only `ErrorPayload.code`, never the whole payload
/// and never any hardware diagnostic detail (T-01-05).
///
/// The five `Double?` hint fields (D-12/HEAD-06) are `BlankFrameHint.Score`,
/// reported as a **heuristic**, never a fact -- see
/// `app/ScanStudio/protocol/CONTROL.md`'s own "Blank-frame hint" section and
/// `BlankFrameHint`'s doc comment for the formula. They are `nil` **together**
/// whenever the frame's thumbnail carried no decodable raster (every
/// simulator frame, or a real frame whose tile failed to decode) -- never
/// individually populated, and never a fabricated number (T-03-31).
/// `needsApproval`/`reviewEvidence` mirror `Thumbnail.needsApproval`/
/// `.warnings` verbatim -- `reviewEvidence` *is* D-12's boundary evidence,
/// no separate field was needed.
public struct ControlFrameSummary: Codable, Equatable, Sendable {
    public let index: Int
    public let excluded: Bool
    public let selected: Bool
    public let hasThumbnail: Bool
    public let state: String?
    public let manualReviewDecision: String?
    public let errorCode: String?
    /// D-20/HEAD-12: the bridge's own message text for `errorCode`, codes
    /// and messages only -- never `details`/`evidence`/`diagnosticEvidence`
    /// (T-01-05 still holds).
    public let errorMessage: String?
    public let blankConfidence: Double?
    public let thumbnailStddev: Double?
    public let thumbnailMean: Double?
    public let endBonus: Double?
    public let runBonus: Double?
    public let needsApproval: Bool
    public let reviewEvidence: [String]

    public init(
        index: Int,
        excluded: Bool,
        selected: Bool,
        hasThumbnail: Bool,
        state: String? = nil,
        manualReviewDecision: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        blankConfidence: Double? = nil,
        thumbnailStddev: Double? = nil,
        thumbnailMean: Double? = nil,
        endBonus: Double? = nil,
        runBonus: Double? = nil,
        needsApproval: Bool = false,
        reviewEvidence: [String] = []
    ) {
        self.index = index
        self.excluded = excluded
        self.selected = selected
        self.hasThumbnail = hasThumbnail
        self.state = state
        self.manualReviewDecision = manualReviewDecision
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.blankConfidence = blankConfidence
        self.thumbnailStddev = thumbnailStddev
        self.thumbnailMean = thumbnailMean
        self.endBonus = endBonus
        self.runBonus = runBonus
        self.needsApproval = needsApproval
        self.reviewEvidence = reviewEvidence
    }
}

/// One flagged frame within `ControlStatusResult.manualReviewPending`
/// (D-13/HEAD-07). `reason` is the frame's first `warnings` entry, or the
/// literal `"boundaryAmbiguous"` when there is none -- never an empty
/// string, never a fabricated sentence. `contentConfidence` is `1 -
/// blankConfidence` of the same `BlankFrameHint.Score` `frames.list` reports
/// for this index, or `nil` when no hint exists for it (T-03-31: a missing
/// hint stays missing, it is never defaulted to a plausible number).
public struct ControlManualReviewFrame: Codable, Equatable, Sendable {
    public let index: Int
    public let reason: String
    public let evidence: [String]
    public let contentConfidence: Double?

    public init(
        index: Int,
        reason: String,
        evidence: [String] = [],
        contentConfidence: Double? = nil
    ) {
        self.index = index
        self.reason = reason
        self.evidence = evidence
        self.contentConfidence = contentConfidence
    }
}

/// D-13/HEAD-07: built inside `buildStatusResult()`, the same aggregate
/// `events.subscribe` streams -- so a pending boundary review reaches
/// `status`, `control.snapshot`, and `control.changed` from one source, with
/// no separate event wiring (T-03-34).
public struct ControlManualReviewPending: Codable, Equatable, Sendable {
    public let frames: [ControlManualReviewFrame]

    public init(frames: [ControlManualReviewFrame]) {
        self.frames = frames
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

public struct ControlFramesPlaceResult: Codable, Equatable, Sendable {
    public let operationId: String
    public let placements: [ControlFramePlacement]
    public let replayed: Bool

    public init(
        operationId: String,
        placements: [ControlFramePlacement],
        replayed: Bool
    ) {
        self.operationId = operationId
        self.placements = placements
        self.replayed = replayed
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
    /// D-20/HEAD-12: mirrors `frameErrorCodes`, keyed the same way -- the
    /// bridge's own message text, codes and messages only (T-03-46: never
    /// `details`/`evidence`/`diagnosticEvidence`).
    public let frameErrorMessages: [String: String]
    /// D-19/HEAD-12: ISO-8601, `nil` for a still-live job -- when this job
    /// finished, from the archived `TerminalJobRecord` (or the live job's
    /// own values once it reaches a terminal `jobState`, via the same
    /// `buildJobResult()` path a still-running job uses).
    public let finishedAt: String?
    /// D-20/HEAD-12: 1-based indices the batch never reached -- `[]` for a
    /// still-live job.
    public let notAttemptedFrames: [Int]

    public init(
        jobId: String? = nil,
        jobState: JobState? = nil,
        progress: ControlScanProgress? = nil,
        completedFrameCount: Int,
        pendingFrameCount: Int,
        receiptCount: Int,
        frameErrorCodes: [String: String] = [:],
        frameErrorMessages: [String: String] = [:],
        finishedAt: String? = nil,
        notAttemptedFrames: [Int] = []
    ) {
        self.jobId = jobId
        self.jobState = jobState
        self.progress = progress
        self.completedFrameCount = completedFrameCount
        self.pendingFrameCount = pendingFrameCount
        self.receiptCount = receiptCount
        self.frameErrorCodes = frameErrorCodes
        self.frameErrorMessages = frameErrorMessages
        self.finishedAt = finishedAt
        self.notAttemptedFrames = notAttemptedFrames
    }
}

/// D-19/HEAD-12: `job.get`'s optional filter -- an absent/`null` `jobId`
/// keeps the historical "the job this session is currently tracking"
/// behavior byte-for-byte; a supplied `jobId` asks for that specific job
/// (the live one, or one of the last `SessionModel.maximumTerminalJobHistory`
/// terminal jobs), refusing `JOB_NOT_FOUND` for any other id.
public struct ControlJobGetParams: Codable, Equatable, Sendable {
    public let jobId: String?

    public init(jobId: String? = nil) {
        self.jobId = jobId
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

/// `scanner.refresh`'s result (D-11). `scanner` is optional, not forced:
/// `refreshScannerStatus()` legitimately leaves `SessionModel.status` `nil`
/// when the live refresh discovers the session was lost -- reporting `null`
/// is the honest answer for that case, not a decode failure.
public struct ControlScannerRefreshResult: Codable, Equatable, Sendable {
    public let scanner: ScannerStatus?

    public init(scanner: ScannerStatus?) {
        self.scanner = scanner
    }
}

/// `scanner.connect`'s CLI-visible idempotency signal (D-16). `true` only
/// when the engine's same-device short circuit answered without calling
/// either backend's own `connect` -- mirrors `SessionModel
/// .lastConnectAlreadyConnected`, itself sourced from `WireProtocol.swift`'s
/// `ConnectResult.alreadyConnected`.
public struct ControlScannerConnectResult: Codable, Equatable, Sendable {
    public let alreadyConnected: Bool

    public init(alreadyConnected: Bool) {
        self.alreadyConnected = alreadyConnected
    }
}

public struct ControlRollListResult: Codable, Equatable, Sendable {
    public let projects: [ControlProjectSummary]

    public init(projects: [ControlProjectSummary]) {
        self.projects = projects
    }
}

/// `outcome` (D-13/HEAD-07) names which of three things actually happened,
/// since a `true` `saved` alone cannot distinguish them --
/// `SessionModel.saveRollAndScanSelectedFrames`'s own `return started ||
/// pendingManualReviewScan?.frames == requestedFrames` line is exactly why:
/// `"started"` (the scan began), `"manualReviewPending"` (the project was
/// created but a flagged frame paused it at the boundary-review gate,
/// visible in `status.manualReviewPending`), or `"failed"` (the save itself
/// succeeded -- the project exists -- but starting the scan did not, a case
/// distinct from an outright refusal, which never reaches this result type
/// at all). The CLI exits 0 for `"started"`/`"manualReviewPending"` alike
/// (T-03-34) -- only `"failed"` is a caller-visible problem.
public struct ControlRollSaveResult: Codable, Equatable, Sendable {
    public let saved: Bool
    public let projectName: String?
    public let projectDirectory: String?
    public let outcome: String

    public init(
        saved: Bool,
        projectName: String? = nil,
        projectDirectory: String? = nil,
        outcome: String = "started"
    ) {
        self.saved = saved
        self.projectName = projectName
        self.projectDirectory = projectDirectory
        self.outcome = outcome
    }
}

public struct ControlRollSolveExposureResult: Codable, Equatable, Sendable {
    public let solution: RollExposureLock

    public init(solution: RollExposureLock) {
        self.solution = solution
    }
}

/// D-23/HEAD-12: `scan.start`/`scan.resume`'s own result, matching
/// `ControlRollSaveResult.outcome`'s vocabulary (`"started"` |
/// `"manualReviewPending"`) so a paused resume is never reported as a bare
/// success indistinguishable from "the scan actually started" (the
/// 2026-09-07 case: `resume` printed the previous job's stale failed
/// snapshot with exit 0). Never `"failed"` here -- a failure is a
/// `.failure` response, not a success carrying a failure string.
public struct ControlScanOutcomeResult: Codable, Equatable, Sendable {
    public let outcome: String

    public init(outcome: String) {
        self.outcome = outcome
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
