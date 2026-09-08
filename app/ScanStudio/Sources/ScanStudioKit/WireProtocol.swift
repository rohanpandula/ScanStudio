// Codable mirror of the Scan Studio engine wire protocol.
//
// Canonical source: `protocol/PROTOCOL.md`. JSON field names on the wire are
// camelCase and already match these types' Swift property names one-to-one,
// so no `CodingKeys` are needed anywhere in this file.
//
// Everything here is `public` because both the `ScanStudio` executable
// (device bar, session sidebar, thumbnail grid, scan panel) and
// `ScanStudioKitTests` need to read these types across the module boundary;
// `ScanStudioKitTests` also uses `@testable import`, which would work
// without `public`, but the executable target does a plain `import` and
// requires it. Everything is also `Sendable`: `EngineClient` is an actor, so
// every `Params`/`Result`/event-payload value that crosses into or out of it
// crosses an isolation boundary.

import Foundation

// MARK: - Wire envelope

/// Additive transport tracing carried by request envelopes. It identifies
/// one CLI request across the control, engine, and bridge boundaries without
/// changing any operation or domain identifier.
public struct RequestMetadata: Codable, Equatable, Sendable {
    public let correlationToken: String?
    public let idempotencyKey: String?

    public init(correlationToken: String? = nil, idempotencyKey: String? = nil) {
        self.correlationToken = correlationToken
        self.idempotencyKey = idempotencyKey
    }
}

/// The dispatcher scopes metadata to the exact request task. Child tasks
/// created while an asynchronous operation is admitted inherit the value;
/// unrelated concurrent requests cannot overwrite it.
public enum RequestCorrelationContext {
    @TaskLocal public static var token: String?
}

/// Inbound shape (app -> engine): `{"id": .., "method": .., "params": ..}`.
/// Used by `EngineClient` to serialize outgoing requests. `Encodable`-only
/// (matching `EngineClient.request`'s `Params: Encodable` constraint) —
/// see `DecodedRequestEnvelope` for the decode direction.
public struct RequestEnvelope<Params: Encodable>: Encodable {
    public let id: UInt64
    public let method: String
    public let params: Params
    public let metadata: RequestMetadata?

    public init(id: UInt64, method: String, params: Params, metadata: RequestMetadata? = nil) {
        self.id = id
        self.method = method
        self.params = params
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey { case id, method, params, metadata }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// The same `{"id", "method", "params"}` shape, `Decodable`-only. Used by
/// `FixtureDecodingTests` to decode the request fixtures (01/04/07/10) into
/// their matching typed `Params` shape.
public struct DecodedRequestEnvelope<Params: Decodable>: Decodable {
    public let id: UInt64
    public let method: String
    public let params: Params
    public let metadata: RequestMetadata?
}

/// Outbound success shape (engine -> app): `{"id": .., "result": ..}`.
public struct ResponseEnvelope<Result: Decodable>: Decodable {
    public let id: UInt64
    public let result: Result
}

/// Outbound error shape (engine -> app): `{"id": .., "error": {..}}`.
public struct ResponseErrorEnvelope: Decodable, Sendable {
    public let id: UInt64
    public let error: ErrorPayload
}

/// Machine-readable failure discriminators the native client is allowed to
/// branch on. Human-readable messages remain display/diagnostic text only.
public enum ScanFailureCode {
    public static let attendedBindingRequired = "ATTENDED_BINDING_REQUIRED"
}

public struct MeterControllerRefusalReason: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let channel: String?
    public let validRawSamples: Int?
    public let requiredRawSamples: Int?
    public let validAggregateSamples: Int?
    public let requiredAggregateSamples: Int?
}

public struct MeterControllerRefusalDetails: Codable, Equatable, Sendable {
    public let pass: Int
    public let reasons: [MeterControllerRefusalReason]
}

public struct ErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let recoverable: Bool
    public let details: MeterControllerRefusalDetails?
    public let evidence: DiagnosticEvidenceReference?
    public let diagnosticEvidence: DiagnosticEvidenceArtifact?
    public let diagnosticEvidenceUnavailableReason: String?

    public init(
        code: String,
        message: String,
        recoverable: Bool,
        details: MeterControllerRefusalDetails? = nil,
        evidence: DiagnosticEvidenceReference? = nil,
        diagnosticEvidence: DiagnosticEvidenceArtifact? = nil,
        diagnosticEvidenceUnavailableReason: String? = nil
    ) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
        self.details = details
        self.evidence = evidence
        self.diagnosticEvidence = diagnosticEvidence
        self.diagnosticEvidenceUnavailableReason =
            diagnosticEvidenceUnavailableReason
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case recoverable
        case details
        case evidence
        case diagnosticEvidence
        case diagnosticEvidenceUnavailableReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        recoverable = try container.decode(Bool.self, forKey: .recoverable)
        details = try? container.decodeIfPresent(
            MeterControllerRefusalDetails.self,
            forKey: .details
        )
        evidence = try container.decodeIfPresent(
            DiagnosticEvidenceReference.self,
            forKey: .evidence
        )
        let suppliedReason = try container.decodeIfPresent(
            String.self,
            forKey: .diagnosticEvidenceUnavailableReason
        )
        do {
            diagnosticEvidence = try container.decodeIfPresent(
                DiagnosticEvidenceArtifact.self,
                forKey: .diagnosticEvidence
            )
            diagnosticEvidenceUnavailableReason = suppliedReason
        } catch {
            // Evidence is additive. A future/malformed witness must never
            // erase the typed terminal failure carrying it.
            diagnosticEvidence = nil
            diagnosticEvidenceUnavailableReason =
                "bounded diagnostic evidence could not be decoded by this client"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(recoverable, forKey: .recoverable)
        try container.encodeIfPresent(details, forKey: .details)
        try container.encodeIfPresent(evidence, forKey: .evidence)
        try container.encodeIfPresent(
            diagnosticEvidence,
            forKey: .diagnosticEvidence
        )
        try container.encodeIfPresent(
            diagnosticEvidenceUnavailableReason,
            forKey: .diagnosticEvidenceUnavailableReason
        )
    }
}

/// A cheap, partial decode used only to classify an incoming NDJSON line
/// before the full typed decode: presence of `event` means it's an Event;
/// otherwise presence of `id` means it's a Response (success or error).
public struct WireSniff: Decodable, Sendable {
    public let id: UInt64?
    public let event: String?
}

/// Outbound event shape (engine -> app, unsolicited):
/// `{"event": .., "payload": ..}`. Events may interleave with responses.
public struct EventEnvelope<Payload: Decodable>: Decodable {
    public let event: String
    public let payload: Payload
}

/// The `Encodable` direction of the same `{"event": .., "payload": ..}`
/// shape -- used only for `EngineClient`'s own synthetic events (D-24/
/// HEAD-12's `engine.request.timeout`), which it constructs itself rather
/// than receiving over a wire.
struct EncodableEventEnvelope<Payload: Encodable>: Encodable {
    let event: String
    let payload: Payload
}

/// D-24/HEAD-12 (CF-14): `EngineClient.timeoutRequest`'s own synthetic
/// event payload -- the method name, request id, and elapsed seconds only,
/// never this request's own `params` (T-03-52: a project path or
/// caller-supplied directory could be in scope there).
struct EngineRequestTimeoutPayload: Codable, Sendable {
    let method: String
    let id: UInt64
    let elapsedSeconds: Double
}

/// Typed error thrown out of `EngineClient.request` for both engine-reported
/// errors (`{"id", "error": {...}}`) and local failures (e.g. the engine
/// process exiting unexpectedly).
public struct EngineRequestError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let recoverable: Bool
    public let details: MeterControllerRefusalDetails?
    public let evidence: DiagnosticEvidenceReference?
    public let diagnosticEvidence: DiagnosticEvidenceArtifact?
    public let diagnosticEvidenceUnavailableReason: String?

    public init(
        code: String,
        message: String,
        recoverable: Bool,
        details: MeterControllerRefusalDetails? = nil,
        evidence: DiagnosticEvidenceReference? = nil,
        diagnosticEvidence: DiagnosticEvidenceArtifact? = nil,
        diagnosticEvidenceUnavailableReason: String? = nil
    ) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
        self.details = details
        self.evidence = evidence
        self.diagnosticEvidence = diagnosticEvidence
        self.diagnosticEvidenceUnavailableReason =
            diagnosticEvidenceUnavailableReason
    }
}

/// Thrown when an engine answers `engine.hello` but is not an engine this
/// client can safely speak to. Keeping this distinct from a request failure
/// lets the UI explain that updating either side is required.
public struct EngineCompatibilityError: Error, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// Params shape with no fields, for methods that take `{}` (or an omitted
/// `params` entirely, which the synthesized `Encodable` still writes here as
/// `{}` since there's nothing to omit).
public struct EmptyParams: Codable, Sendable {
    public init() {}
}

/// Result shape with no fields, for methods that return `{}`.
public struct EmptyResult: Decodable, Sendable {}

// MARK: - engine.hello

public struct HelloParams: Codable, Sendable {
    public let clientName: String
    public let protocolVersion: Int
    public let clientBuild: String?

    public init(
        clientName: String,
        protocolVersion: Int,
        clientBuild: String? = nil
    ) {
        self.clientName = clientName
        self.protocolVersion = protocolVersion
        self.clientBuild = clientBuild
    }
}

public struct HelloResult: Decodable, Sendable {
    public let engineName: String
    public let engineVersion: String
    public let protocolVersion: Int
    public let capabilities: [String]
}

public struct EngineSessionEvidenceAuthority: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let path: String
    public let allowedRoot: String
}

public struct EngineSessionEvidenceFileAuthority: Decodable, Equatable, Sendable {
    public let entryName: String
    public let path: String
    public let allowedRoot: String
    public let sha256: String
}

public struct EngineSessionInventoryResult: Decodable, Equatable, Sendable {
    public let bridgeTelemetry: EngineSessionEvidenceAuthority?
    public let attemptJournals: [EngineSessionEvidenceFileAuthority]?
    public let bridgeVersion: String?
}

// MARK: - scanner.list

public struct ScannerListResult: Decodable, Sendable {
    public let devices: [DeviceInfo]
}

public struct DeviceInfo: Codable, Equatable, Sendable {
    public let deviceId: String
    public let model: String
    public let kind: String
    public let firmware: String
    public let connection: String
    /// False when discovery recognized a Nikon Coolscan that is not the
    /// supported LS-5000 (Lane D, #14). An unsupported device is named in
    /// ``scanner.list`` but is never connectable.
    public let supported: Bool
    /// Device-sourced accepted set for `CaptureRecipe.multisamplePasses`
    /// (BRIDGE.md's `Capabilities.supportedMultisamplePasses`, always `[4]`
    /// for the LS-5000 today). The engine already derives this internally
    /// for a real backend (`real_backend.rs`'s
    /// `derive_supported_multisample_passes`, used to reject `scan.start`
    /// with `INVALID_PARAMS`) but does not yet forward it through
    /// `scanner.list`/`scanner.connect`'s `DeviceInfo` — PROTOCOL.md's own
    /// "Types" section documents this struct as exactly the five fields
    /// above, with no capabilities field. This property is therefore
    /// purely additive and forward-compatible: today every real engine
    /// response omits the key and this decodes as `nil` (Optional ->
    /// `decodeIfPresent`, no fixture or golden response needs updating),
    /// and the day the engine does start sending it, `MultisamplePassPolicy
    /// .supportedOptions(for:)` below picks it up with no further Swift
    /// change required. Never encoded by this app (`DeviceInfo` is only
    /// ever decoded, never constructed here to send outbound).
    public let supportedMultisamplePasses: [Int]?
    public let unverifiedAllowed: Bool
    public let hardwareVerification: String?

    public init(
        deviceId: String, model: String, kind: String, firmware: String,
        connection: String, supported: Bool, supportedMultisamplePasses: [Int]? = nil,
        unverifiedAllowed: Bool = false, hardwareVerification: String? = nil
    ) {
        self.deviceId = deviceId; self.model = model; self.kind = kind
        self.firmware = firmware; self.connection = connection; self.supported = supported
        self.supportedMultisamplePasses = supportedMultisamplePasses
        self.unverifiedAllowed = unverifiedAllowed; self.hardwareVerification = hardwareVerification
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, model, kind, firmware, connection, supported, supportedMultisamplePasses
        case unverifiedAllowed, hardwareVerification
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        model = try c.decode(String.self, forKey: .model)
        kind = try c.decode(String.self, forKey: .kind)
        firmware = try c.decode(String.self, forKey: .firmware)
        connection = try c.decode(String.self, forKey: .connection)
        supported = try c.decode(Bool.self, forKey: .supported)
        supportedMultisamplePasses = try c.decodeIfPresent([Int].self, forKey: .supportedMultisamplePasses)
        unverifiedAllowed = try c.decodeIfPresent(Bool.self, forKey: .unverifiedAllowed) ?? false
        hardwareVerification = try c.decodeIfPresent(String.self, forKey: .hardwareVerification)
    }
}

// MARK: - scanner.connect

public struct ConnectOptions: Codable, Equatable, Sendable {
    public let timeScale: Double
    public let faultInjection: String
    public let allowUnverifiedHardware: Bool

    public init(timeScale: Double, faultInjection: String, allowUnverifiedHardware: Bool = false) {
        self.timeScale = timeScale
        self.faultInjection = faultInjection
        self.allowUnverifiedHardware = allowUnverifiedHardware
    }

    private enum CodingKeys: String, CodingKey { case timeScale, faultInjection, allowUnverifiedHardware }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeScale = try c.decode(Double.self, forKey: .timeScale)
        faultInjection = try c.decode(String.self, forKey: .faultInjection)
        allowUnverifiedHardware = try c.decodeIfPresent(Bool.self, forKey: .allowUnverifiedHardware) ?? false
    }
}

public struct ConnectParams: Codable, Sendable {
    public let deviceId: String
    public let options: ConnectOptions

    public init(deviceId: String, options: ConnectOptions) {
        self.deviceId = deviceId
        self.options = options
    }
}

/// Mirrors PROTOCOL.md's `ScannerStatus`. `lamp`/`transport`/`carrier` are
/// plain strings on the Swift side per this plan's interfaces (the engine's
/// own `Lamp`/`Transport`/`MediaCarrier` Rust enums already serialize to
/// exactly these lowercase camelCase wire strings) — the app only displays
/// them, it never branches on them as a closed enum.
public struct ScannerStatus: Codable, Equatable, Sendable {
    public let connected: Bool
    public let adapter: String?
    public let mediaLoaded: Bool
    public let carrier: String?
    public let frameCount: Int?
    public let lamp: String
    public let transport: String
    public let activeJobId: String?
    /// Mirrors BRIDGE.md's `DeviceStatus.filmPresent` verbatim for a real
    /// backend: `bool | null | absent`. The simulator always omits this
    /// field (it has no bridge to source it from). Both `null` and an
    /// absent field mean "unknown," never "film absent."
    public let filmPresent: Bool?
    /// Live, read-only result of the bridge's two-part hardware-motion
    /// readiness check. Optional keeps older engine/status payloads
    /// decodable; `nil` means unknown/not checked, never ready.
    public let motionArmed: Bool?
    public let hardwareVerification: String?
    public let deviceModel: String?

    public init(
        connected: Bool,
        adapter: String?,
        mediaLoaded: Bool,
        carrier: String?,
        frameCount: Int?,
        lamp: String,
        transport: String,
        activeJobId: String?,
        filmPresent: Bool? = nil,
        motionArmed: Bool? = nil,
        hardwareVerification: String? = nil,
        deviceModel: String? = nil
    ) {
        self.connected = connected
        self.adapter = adapter
        self.mediaLoaded = mediaLoaded
        self.carrier = carrier
        self.frameCount = frameCount
        self.lamp = lamp
        self.transport = transport
        self.activeJobId = activeJobId
        self.filmPresent = filmPresent
        self.motionArmed = motionArmed
        self.hardwareVerification = hardwareVerification
        self.deviceModel = deviceModel
    }

    /// Reconciles a legacy/stale preview flag with the stronger live sensor
    /// verdict. Verified film absence retires preview-derived frame data;
    /// unknown presence leaves it untouched.
    public func invalidatingPreviewWhenFilmIsAbsent() -> ScannerStatus {
        guard filmPresent == false else { return self }
        return ScannerStatus(
            connected: connected,
            adapter: adapter,
            mediaLoaded: false,
            carrier: carrier,
            frameCount: nil,
            lamp: lamp,
            transport: transport,
            activeJobId: activeJobId,
            filmPresent: false,
            motionArmed: motionArmed,
            hardwareVerification: hardwareVerification,
            deviceModel: deviceModel
        )
    }
}

public struct ConnectResult: Decodable, Sendable {
    public let device: DeviceInfo
    public let status: ScannerStatus
    /// D-16: `true` only when the engine's same-device short circuit
    /// answered a re-issued connect without calling either backend's own
    /// `connect` -- device/status are then read from the already-active
    /// backend, never a fresh bridge round trip. A custom `init(from:)`
    /// defaults this to `false` so an older engine's payload (which never
    /// sent this key) still decodes.
    public let alreadyConnected: Bool

    private enum CodingKeys: String, CodingKey {
        case device, status, alreadyConnected
    }

    /// A default of `false` (not a second, forced-unwrap-avoiding branch)
    /// keeps every existing two-argument `ConnectResult(device:status:)`
    /// call site in this test suite compiling unchanged -- adding
    /// `init(from:)` below suppresses Swift's synthesized memberwise init,
    /// so this explicit one takes its place.
    public init(device: DeviceInfo, status: ScannerStatus, alreadyConnected: Bool = false) {
        self.device = device
        self.status = status
        self.alreadyConnected = alreadyConnected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(DeviceInfo.self, forKey: .device)
        status = try container.decode(ScannerStatus.self, forKey: .status)
        alreadyConnected = try container.decodeIfPresent(Bool.self, forKey: .alreadyConnected) ?? false
    }
}

// MARK: - sim.loadMedia

public struct LoadMediaParams: Codable, Sendable {
    public let carrier: String
    public let previewFixture: String?
    public let abortAtFrame: Int?
    public let abortCode: String?
    public let stallAtFrame: Int?

    public init(carrier: String, previewFixture: String? = nil, abortAtFrame: Int? = nil, abortCode: String? = nil, stallAtFrame: Int? = nil) {
        self.carrier = carrier
        self.previewFixture = previewFixture
        self.abortAtFrame = abortAtFrame
        self.abortCode = abortCode
        self.stallAtFrame = stallAtFrame
    }
}

// MARK: - scanner.acquireThumbnails

public struct AcquireThumbnailsParams: Codable, Sendable {
    // Swift's synthesized Encodable conformance calls `encodeIfPresent` for
    // Optional stored properties, so `frames == nil` omits the key entirely
    // (matching PROTOCOL.md: "frames? ... omitted = all loaded frames"),
    // rather than encoding a literal JSON `null`.
    public let frames: [Int]?
    /// Optional for wire compatibility with existing clients. New preview
    /// requests provide the operator's process so a pre-project real preview
    /// can select the correct scanner material.
    public let filmProcess: FilmProcess?
    /// Correlates every event emitted by this asynchronous preview worker.
    /// Optional only for additive wire compatibility; ScanStudio always sends
    /// the presentation token's UUID and fails closed on untagged events.
    public let operationId: String?

    public init(
        frames: [Int]? = nil,
        filmProcess: FilmProcess? = nil,
        operationId: String? = nil
    ) {
        self.frames = frames
        self.filmProcess = filmProcess
        self.operationId = operationId
    }
}

public struct AcquireThumbnailsAck: Decodable, Sendable {
    public let accepted: Bool
    public let frames: [Int]
}

/// `brightness`/`tint` and `imagePath` are mutually exclusive per
/// PROTOCOL.md: exactly one of the `{brightness, tint}` pair or `imagePath`
/// is populated per instance, never both, never neither. The simulator
/// populates `brightness`/`tint` and omits `imagePath`; a real backend
/// populates `imagePath` (a bridge-written preview-tile file) and omits
/// `brightness`/`tint` rather than fabricating them. Callers must branch on
/// which is present, never assume both.
public struct Thumbnail: Codable, Equatable, Sendable {
    public let brightness: Double?
    public let tint: Double?
    public let imagePath: String?
    /// Real-bridge frame boundary in native scanner rows. Older engines and
    /// simulator thumbnails omit this transport evidence.
    public let boundaryRows: [Int]?
    /// Relative native-row adjustment applied to this preview registration.
    /// Older engines and simulator thumbnails omit it.
    public let spacingOffset: Int?
    /// Transport-bound preview evidence from a real bridge. The simulator and
    /// older engine events omit it, which decodes as `false`.
    public let needsApproval: Bool
    /// Human/diagnostic context for `needsApproval`; empty for normal frames
    /// and for simulator thumbnails.
    public let warnings: [String]
    /// Lane C/partial frame: `true` when >=90% of the frame's height is inside
    /// the preview but not all of it. Absent/`nil` for every full frame (the
    /// wire omits the key), so an old bridge with a new app (and vice versa)
    /// stays working -- the badge is a strict no-op when absent.
    public let partial: Bool?

    public init(
        brightness: Double?,
        tint: Double?,
        imagePath: String?,
        boundaryRows: [Int]? = nil,
        spacingOffset: Int? = nil,
        needsApproval: Bool = false,
        warnings: [String] = [],
        partial: Bool? = nil
    ) {
        self.brightness = brightness
        self.tint = tint
        self.imagePath = imagePath
        self.boundaryRows = boundaryRows
        self.spacingOffset = spacingOffset
        self.needsApproval = needsApproval
        self.warnings = warnings
        self.partial = partial
    }

    private enum CodingKeys: String, CodingKey {
        case brightness
        case tint
        case imagePath
        case boundaryRows
        case spacingOffset
        case needsApproval
        case warnings
        case partial
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness)
        tint = try container.decodeIfPresent(Double.self, forKey: .tint)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        boundaryRows = try container.decodeIfPresent([Int].self, forKey: .boundaryRows)
        spacingOffset = try container.decodeIfPresent(Int.self, forKey: .spacingOffset)
        needsApproval =
            try container.decodeIfPresent(Bool.self, forKey: .needsApproval) ?? false
        warnings =
            try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        partial = try container.decodeIfPresent(Bool.self, forKey: .partial)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(brightness, forKey: .brightness)
        try container.encodeIfPresent(tint, forKey: .tint)
        try container.encodeIfPresent(imagePath, forKey: .imagePath)
        try container.encodeIfPresent(boundaryRows, forKey: .boundaryRows)
        try container.encodeIfPresent(spacingOffset, forKey: .spacingOffset)
        if needsApproval {
            try container.encode(true, forKey: .needsApproval)
        }
        if !warnings.isEmpty {
            try container.encode(warnings, forKey: .warnings)
        }
        try container.encodeIfPresent(partial, forKey: .partial)
    }

    /// Affirmative simulator provenance: `true` only when this thumbnail
    /// carries the simulator's positively-populated fields (`brightness`/
    /// `tint`), per PROTOCOL.md's strict one-of contract ("exactly one of the
    /// {brightness, tint} pair or imagePath is populated... never both, never
    /// neither"). A real backend's thumbnail populates `imagePath` and omits
    /// `brightness`/`tint`, so this is `false` for it. Deliberately NOT
    /// `imagePath == nil`: that absence-based form would also read `true` for
    /// a malformed/unknown thumbnail with every field nil, showing bundled
    /// simulator art from the mere absence of a real image. Simulator art must
    /// follow affirmative simulator provenance, never absence — including while
    /// device identity is nil/connecting/unknown, which this thumbnail-shaped
    /// (device-independent) check is correct for by construction.
    public var isSimulatorShaped: Bool {
        brightness != nil || tint != nil
    }
}

// MARK: - roll.setSpacingOffset

/// Re-registers one frame relative to the boundary found by the exact
/// completed preview the operator is looking at.
public struct RollSetSpacingOffsetParams: Codable, Sendable {
    public let frameIndex: Int
    public let offsetRows: Int
    public let operationId: String

    public init(frameIndex: Int, offsetRows: Int, operationId: String) {
        self.frameIndex = frameIndex
        self.offsetRows = offsetRows
        self.operationId = operationId
    }
}

/// The bridge regenerates the adjusted tile, so callers replace the complete
/// thumbnail rather than trying to patch transport evidence locally.
public struct RollSetSpacingOffsetResult: Decodable, Sendable {
    public let thumbnail: Thumbnail
}

public struct RollSolveExposureParams: Codable, Sendable {
    public let frameIndex: Int
    public let operationId: String
    public let previewDerivedReference: Bool?

    public init(frameIndex: Int, operationId: String, previewDerivedReference: Bool = false) {
        self.frameIndex = frameIndex
        self.operationId = operationId
        self.previewDerivedReference = previewDerivedReference
    }
}

public struct RollSolveExposureAck: Decodable, Sendable {
    public let accepted: Bool
}

public struct RollExposureSolvedPayload: Codable, Sendable {
    public let operationId: String
    public let solution: RollExposureLock
    public let project: ScanProject
}

public struct RollExposureErrorPayload: Decodable, Sendable {
    public let operationId: String
    public let code: String
    public let message: String
    public let recoverable: Bool
    public let frameIndex: Int
    public let details: MeterControllerRefusalDetails?
}

// MARK: - roll.approve

/// Explicit operator approval for one preview boundary that the engine
/// refused before scanner motion. Approval is deliberately separate from
/// `scan.start`; callers must never infer or send it from an error message.
/// `operationId` binds the approval to the exact completed preview the
/// operator reviewed so a reconnect or replacement preview cannot reuse it.
public struct RollApproveParams: Codable, Sendable {
    public let frameIndex: Int
    public let operationId: String
    /// Attended binding (feed-detector round; issues #24/#16/#42). `nil`
    /// -- the default and every pre-existing caller -- is omitted from the
    /// encoded params entirely, so this request stays byte-identical to
    /// before the field existed. `true` accepts one frame of a roll whose
    /// lattice confidence is too low to bind unattended; the driver
    /// refuses it on any other roll shape.
    public let attended: Bool?

    public init(frameIndex: Int, operationId: String, attended: Bool? = nil) {
        self.frameIndex = frameIndex
        self.operationId = operationId
        self.attended = attended
    }

    private enum CodingKeys: String, CodingKey {
        case frameIndex
        case operationId
        case attended
    }

    // Written out rather than synthesized so the omission of `attended`
    // when nil is a property of this type, not of whatever the compiler
    // happens to synthesize for Optionals.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameIndex, forKey: .frameIndex)
        try container.encode(operationId, forKey: .operationId)
        try container.encodeIfPresent(attended, forKey: .attended)
    }
}

// MARK: - roll.manualFrames / roll.previewStrip

/// Rung 4 of the feeding UX ladder (additive, 2026-08-07). Re-slices the
/// last completed preview attempt's already-decoded raster at
/// operator-picked boundary rows, in place of automatic detection. Usable
/// any time a preview attempt exists -- including one that ended in
/// `scanner.thumbnailsFailed` (REFEED_REQUIRED) -- so, unlike
/// `RollApproveParams`/`RollSetSpacingOffsetParams`, this carries no
/// `operationId`: there is no "exact completed preview" to bind to yet.
/// `rows` must be at least 2 strictly increasing values in
/// `0..PreviewStripResult.rowCount-1` (N rows define N-1 frames).
public struct RollManualFramesParams: Codable, Sendable {
    public let rows: [Int]

    public init(rows: [Int]) {
        self.rows = rows
    }
}

/// One resulting slot from `roll.manualFrames`, paired with its frame
/// index -- mirrors `ThumbnailPayload`'s own frameIndex+thumbnail pairing
/// for the ordinary preview-event path.
public struct ManualFrameThumbnail: Decodable, Sendable {
    public let frameIndex: Int
    public let thumbnail: Thumbnail
}

/// One snap-assist adjustment `roll.manualFrames` applied to a picked
/// boundary row: a pick within a few rows of a clear-film run edge snapped
/// to it. `evidenceRun` is the `[start, end]` clear-film run that pick
/// snapped against.
public struct BoundarySnap: Decodable, Equatable, Sendable {
    public let boundaryIndex: Int
    public let requestedRow: Int
    public let snappedRow: Int
    public let evidenceRun: [Int]
}

public struct RollManualFramesResult: Decodable, Sendable {
    public let count: Int
    public let fingerprint: String
    /// Engine-minted, not client-supplied -- `roll.manualFrames` has no
    /// `operationId` param of its own (see this type's own doc comment).
    /// Bind subsequent `roll.approve`/`roll.setSpacingOffset` calls on the
    /// resulting frames to this id, exactly as a normal preview's own
    /// completion `operationId` is already used for.
    public let operationId: String
    public let thumbnails: [ManualFrameThumbnail]
    public let snaps: [BoundarySnap]
}

/// `roll.previewStrip`'s result: the whole captured preview raster
/// rendered to one image, in the same row coordinate space
/// `roll.manualFrames`'s `rows` are given in. `pixelsPerRow` is carried
/// explicitly so a future downsampled strip cannot silently break
/// row<->pixel math; it is always `1` today (native resolution).
public struct PreviewStripResult: Decodable, Sendable {
    public let imagePath: String
    public let rowCount: Int
    public let pixelsPerRow: Int
}

// MARK: - scan.start / scan.stop / scan.skipCurrentFrame

public struct PreviewExposureAdjustment: Codable, Equatable, Sendable {
    public let source: String
    public let referenceFrameIndex: Int
    public let referenceThumbnailMean: Double
    public let frameThumbnailMean: Double
    public let requestedPositiveEv: Double
    public let appliedPositiveEv: Double
    public let referenceRgbExposuresRaw10ns: [Int]
    public let appliedRgbExposuresRaw10ns: [Int]
    public let deviceBoundClampedChannels: [String]

    public init(
        source: String = "previewThumbnailMean",
        referenceFrameIndex: Int,
        referenceThumbnailMean: Double,
        frameThumbnailMean: Double,
        requestedPositiveEv: Double,
        appliedPositiveEv: Double,
        referenceRgbExposuresRaw10ns: [Int],
        appliedRgbExposuresRaw10ns: [Int],
        deviceBoundClampedChannels: [String] = []
    ) {
        self.source = source
        self.referenceFrameIndex = referenceFrameIndex
        self.referenceThumbnailMean = referenceThumbnailMean
        self.frameThumbnailMean = frameThumbnailMean
        self.requestedPositiveEv = requestedPositiveEv
        self.appliedPositiveEv = appliedPositiveEv
        self.referenceRgbExposuresRaw10ns = referenceRgbExposuresRaw10ns
        self.appliedRgbExposuresRaw10ns = appliedRgbExposuresRaw10ns
        self.deviceBoundClampedChannels = deviceBoundClampedChannels
    }
}

public struct CaptureRecipe: Codable, Equatable, Sendable {
    public let resolutionDpi: Int
    public let bitDepth: Int
    public let multisamplePasses: Int
    public let channels: String
    public let exposureOverride10ns: [Int]?
    public let previewExposureAdjustment: PreviewExposureAdjustment?

    public init(resolutionDpi: Int, bitDepth: Int, multisamplePasses: Int, channels: String, exposureOverride10ns: [Int]? = nil, previewExposureAdjustment: PreviewExposureAdjustment? = nil) {
        self.resolutionDpi = resolutionDpi
        self.bitDepth = bitDepth
        self.multisamplePasses = multisamplePasses
        self.channels = channels
        self.exposureOverride10ns = exposureOverride10ns
        self.previewExposureAdjustment = previewExposureAdjustment
    }
}

public enum FilmProcess: String, Codable, CaseIterable, Identifiable, Sendable {
    case positive
    case c41ColorNegative
    case bwNegative
    case kodachrome

    public var id: String { rawValue }
    public var isNegative: Bool { self == .c41ColorNegative || self == .bwNegative }
}

public enum DigitalIceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case legacy
    case hybrid

    public var id: String { rawValue }
}

public enum OutputFileFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case tiff
    case jpeg

    public var id: String { rawValue }
}

public enum OutputColorProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case adobeRgb1998
    case sRgb
    case proPhotoRgb

    public var id: String { rawValue }
}

public enum RawExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case linearDng
    case linearTiff

    public var id: String { rawValue }
}

/// Renderer for C-41 positive/preview derivatives. The archive master is
/// independent and always remains untouched scanner RGB.
public enum C41RenderTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case nikonlook
    case nikonOemReplay
    case noritsuLs600
    case flexcolorCleanroom

    public var id: String { rawValue }
}

public enum RawTiffInfrared: String, Codable, CaseIterable, Identifiable, Sendable {
    case fourthChannel
    case omitted
    case sidecar

    public var id: String { rawValue }
}

/// Operator-owned clean-room FlexColor inputs. Only paths are persisted; no
/// profile, LUT, or ICC bytes are copied into the project manifest.
public struct FlexColorInputs: Codable, Equatable, Sendable {
    public let imageSettingPath: String?
    public let lutTablePath: String?
    public let inputIccPath: String?

    public init(imageSettingPath: String? = nil, lutTablePath: String? = nil, inputIccPath: String? = nil) {
        self.imageSettingPath = imageSettingPath
        self.lutTablePath = lutTablePath
        self.inputIccPath = inputIccPath
    }
}

/// Local paths for the experimental Nikon Scan replay. The Cool Colors
/// checkout and per-frame builder LUTs remain outside the ScanStudio project.
public struct CoolColorsInputs: Codable, Equatable, Sendable {
    public let checkoutPath: String?
    public let builderRedPath: String?
    public let builderGreenPath: String?
    public let builderBluePath: String?

    public init(
        checkoutPath: String? = nil,
        builderRedPath: String? = nil,
        builderGreenPath: String? = nil,
        builderBluePath: String? = nil
    ) {
        self.checkoutPath = checkoutPath
        self.builderRedPath = builderRedPath
        self.builderGreenPath = builderGreenPath
        self.builderBluePath = builderBluePath
    }
}

public struct C41RenderRecipe: Codable, Equatable, Sendable {
    public let target: C41RenderTarget
    public let flexcolor: FlexColorInputs
    public let coolColors: CoolColorsInputs

    public init(
        target: C41RenderTarget = .nikonlook,
        flexcolor: FlexColorInputs = FlexColorInputs(),
        coolColors: CoolColorsInputs = CoolColorsInputs()
    ) {
        self.target = target
        self.flexcolor = flexcolor
        self.coolColors = coolColors
    }

    private enum CodingKeys: String, CodingKey { case target, flexcolor, coolColors }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decodeIfPresent(C41RenderTarget.self, forKey: .target) ?? .nikonlook
        flexcolor = try values.decodeIfPresent(FlexColorInputs.self, forKey: .flexcolor) ?? FlexColorInputs()
        coolColors = try values.decodeIfPresent(CoolColorsInputs.self, forKey: .coolColors) ?? CoolColorsInputs()
    }
}

public struct ProcessingRecipe: Codable, Equatable, Sendable {
    public let filmProcess: FilmProcess
    public let autofocusEachFrame: Bool
    public let autoExposureEachFrame: Bool
    public let digitalIceEnabled: Bool
    public let digitalIceMode: DigitalIceMode
    public let softwareDustRemovalBw: Bool

    public init(
        filmProcess: FilmProcess,
        autofocusEachFrame: Bool,
        autoExposureEachFrame: Bool,
        digitalIceEnabled: Bool,
        digitalIceMode: DigitalIceMode,
        softwareDustRemovalBw: Bool = false
    ) {
        self.filmProcess = filmProcess
        self.autofocusEachFrame = autofocusEachFrame
        self.autoExposureEachFrame = autoExposureEachFrame
        self.digitalIceEnabled = digitalIceEnabled
        self.digitalIceMode = digitalIceMode
        self.softwareDustRemovalBw = softwareDustRemovalBw
    }

    private enum CodingKeys: String, CodingKey {
        case filmProcess, autofocusEachFrame, autoExposureEachFrame, digitalIceEnabled, digitalIceMode, softwareDustRemovalBw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filmProcess = try container.decode(FilmProcess.self, forKey: .filmProcess)
        autofocusEachFrame = try container.decode(Bool.self, forKey: .autofocusEachFrame)
        autoExposureEachFrame = try container.decode(Bool.self, forKey: .autoExposureEachFrame)
        digitalIceEnabled = try container.decode(Bool.self, forKey: .digitalIceEnabled)
        digitalIceMode = try container.decode(DigitalIceMode.self, forKey: .digitalIceMode)
        softwareDustRemovalBw = try container.decodeIfPresent(Bool.self, forKey: .softwareDustRemovalBw) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filmProcess, forKey: .filmProcess)
        try container.encode(autofocusEachFrame, forKey: .autofocusEachFrame)
        try container.encode(autoExposureEachFrame, forKey: .autoExposureEachFrame)
        try container.encode(digitalIceEnabled, forKey: .digitalIceEnabled)
        try container.encode(digitalIceMode, forKey: .digitalIceMode)
        try container.encode(softwareDustRemovalBw, forKey: .softwareDustRemovalBw)
    }
}

/// An optional, never-touched capture master. When retained it has no
/// `fileFormat`/`colorProfile` field — it is always full-fidelity,
/// uncompressed, at the capture's own bit depth. Missing `enabled` keeps
/// older projects and clients on their historic retained-master behavior.
/// Mirrors `domain.rs::ArchiveRecipe`.
public struct ArchiveRecipe: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let filenameTemplate: String
    public let destination: String
    public let fullCapturePackage: Bool

    public init(enabled: Bool = true, filenameTemplate: String, destination: String, fullCapturePackage: Bool = true) {
        self.enabled = enabled
        self.filenameTemplate = filenameTemplate
        self.destination = destination
        self.fullCapturePackage = fullCapturePackage
    }

    private enum CodingKeys: String, CodingKey { case enabled, filenameTemplate, destination, fullCapturePackage }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        filenameTemplate = try values.decode(String.self, forKey: .filenameTemplate)
        destination = try values.decode(String.self, forKey: .destination)
        fullCapturePackage = try values.decodeIfPresent(Bool.self, forKey: .fullCapturePackage) ?? true
    }
}

/// An optional untouched 16-bit negative export. Available IR can be kept in
/// the main container or written as a paired grayscale TIFF. Missing recipes
/// decode disabled for old projects.
public struct RawExportRecipe: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let fileFormat: RawExportFormat
    public let tiffInfrared: RawTiffInfrared
    public let filenameTemplate: String
    public let destination: String

    public init(
        enabled: Bool = false,
        fileFormat: RawExportFormat = .linearDng,
        tiffInfrared: RawTiffInfrared = .fourthChannel,
        filenameTemplate: String = "ScanStudio#",
        destination: String = "\(NSHomeDirectory())/ScanStudio Projects/_Unfiled/Raw Negative"
    ) {
        self.enabled = enabled
        self.fileFormat = fileFormat
        self.tiffInfrared = tiffInfrared
        self.filenameTemplate = filenameTemplate
        self.destination = destination
    }
}

/// A regenerable derivative: format/profile choices here never touch
/// `ArchiveRecipe` — different Swift types, not just different UI labels.
/// Mirrors `domain.rs::PositiveRecipe`.
public struct PositiveRecipe: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let fileFormat: OutputFileFormat
    public let colorProfile: OutputColorProfile
    public let filenameTemplate: String
    public let destination: String

    public init(
        enabled: Bool,
        fileFormat: OutputFileFormat,
        colorProfile: OutputColorProfile,
        filenameTemplate: String,
        destination: String
    ) {
        self.enabled = enabled
        self.fileFormat = fileFormat
        self.colorProfile = colorProfile
        self.filenameTemplate = filenameTemplate
        self.destination = destination
    }
}

/// A regenerable derivative like `PositiveRecipe`, but defaults to the
/// small/fast format (`jpeg`) rather than positive's `tiff` default, and
/// carries its own long-edge cap instead of a color profile. Mirrors
/// `domain.rs::PreviewRecipe`.
public struct PreviewRecipe: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let fileFormat: OutputFileFormat
    public let maxLongEdgePx: Int
    public let filenameTemplate: String
    public let destination: String

    public init(
        enabled: Bool,
        fileFormat: OutputFileFormat,
        maxLongEdgePx: Int,
        filenameTemplate: String,
        destination: String
    ) {
        self.enabled = enabled
        self.fileFormat = fileFormat
        self.maxLongEdgePx = maxLongEdgePx
        self.filenameTemplate = filenameTemplate
        self.destination = destination
    }
}

/// Container holding the four independent recipes. Kept named
/// `OutputRecipe` (not renamed) to mirror `domain.rs::OutputRecipe`'s own
/// pre-existing name — only its internal shape nests.
public struct OutputRecipe: Codable, Equatable, Sendable {
    public let archive: ArchiveRecipe
    public let rawExport: RawExportRecipe
    public let positive: PositiveRecipe
    public let preview: PreviewRecipe
    /// Non-destructive scan-time auto-crop of derived outputs; the archive
    /// master and raw negative are never cropped. Missing key keeps older projects and engines
    /// on their historic uncropped behavior. Mirrors
    /// `domain.rs::OutputRecipe.auto_crop`.
    public let autoCrop: Bool
    public let c41Render: C41RenderRecipe

    public init(
        archive: ArchiveRecipe,
        rawExport: RawExportRecipe = RawExportRecipe(),
        positive: PositiveRecipe,
        preview: PreviewRecipe,
        autoCrop: Bool = false,
        c41Render: C41RenderRecipe = C41RenderRecipe()
    ) {
        self.archive = archive
        self.rawExport = rawExport
        self.positive = positive
        self.preview = preview
        self.autoCrop = autoCrop
        self.c41Render = c41Render
    }

    private enum CodingKeys: String, CodingKey {
        case archive, rawExport, positive, preview, autoCrop, c41Render
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        archive = try values.decode(ArchiveRecipe.self, forKey: .archive)
        rawExport = try values.decodeIfPresent(RawExportRecipe.self, forKey: .rawExport) ?? RawExportRecipe()
        positive = try values.decode(PositiveRecipe.self, forKey: .positive)
        preview = try values.decode(PreviewRecipe.self, forKey: .preview)
        autoCrop = try values.decodeIfPresent(Bool.self, forKey: .autoCrop) ?? false
        c41Render = try values.decodeIfPresent(C41RenderRecipe.self, forKey: .c41Render) ?? C41RenderRecipe()
    }
}

public enum ScanFrameFailurePolicy: String, Codable, Equatable, Sendable {
    case stop
    case skip
}

public struct ScanStartParams: Codable, Sendable {
    public let frames: [Int]
    public let onFrameFailure: ScanFrameFailurePolicy
    public let allowedMeterRefusalSlots: [Int]
    public let passToken: String?
    public let recipe: CaptureRecipe
    public let processing: ProcessingRecipe?
    public let output: OutputRecipe?

    public init(
        frames: [Int],
        onFrameFailure: ScanFrameFailurePolicy = .stop,
        allowedMeterRefusalSlots: [Int] = [],
        passToken: String? = nil,
        recipe: CaptureRecipe,
        processing: ProcessingRecipe? = nil,
        output: OutputRecipe? = nil
    ) {
        self.frames = frames
        self.onFrameFailure = onFrameFailure
        self.allowedMeterRefusalSlots = allowedMeterRefusalSlots
        self.passToken = passToken
        self.recipe = recipe
        self.processing = processing
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case frames, onFrameFailure, allowedMeterRefusalSlots, passToken, recipe, processing, output
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        frames = try values.decode([Int].self, forKey: .frames)
        onFrameFailure = try values.decodeIfPresent(ScanFrameFailurePolicy.self, forKey: .onFrameFailure) ?? .stop
        allowedMeterRefusalSlots = try values.decodeIfPresent([Int].self, forKey: .allowedMeterRefusalSlots) ?? []
        passToken = try values.decodeIfPresent(String.self, forKey: .passToken)
        recipe = try values.decode(CaptureRecipe.self, forKey: .recipe)
        processing = try values.decodeIfPresent(ProcessingRecipe.self, forKey: .processing)
        output = try values.decodeIfPresent(OutputRecipe.self, forKey: .output)
    }
}

public struct ScanStartResult: Decodable, Sendable {
    public let jobId: String
}

public struct ScanStopParams: Codable, Sendable {
    public let jobId: String
    public let mode: String

    public init(jobId: String, mode: String) {
        self.jobId = jobId
        self.mode = mode
    }
}

public struct ScanStopResult: Decodable, Sendable {
    public let acknowledged: Bool
    public let mode: String
}

/// Distinct from `scan.stop`: abandons only the job's currently-active
/// frame (marked `skipped`, no receipt written for it) and lets the batch
/// continue to its next frame rather than pausing/halting the whole job.
public struct ScanSkipCurrentFrameParams: Codable, Sendable {
    public let jobId: String

    public init(jobId: String) {
        self.jobId = jobId
    }
}

public struct ScanSkipCurrentFrameResult: Decodable, Sendable {
    public let acknowledged: Bool
}

// MARK: - JobState / FrameState
//
// String raw values are spelled to equal the exact PROTOCOL.md wire string
// for every case (Swift's implicit `String` raw value for an unadorned enum
// case is the case name itself), so no explicit `= "..."` assignments are
// needed — `JobState.stoppingAfterCurrentFrame.rawValue` is already
// `"stoppingAfterCurrentFrame"`.

public enum JobState: String, Codable, Equatable, Sendable {
    case queued
    case scanning
    case completed
    case failed
    case stoppingAfterCurrentFrame
    case stoppingImmediately
    case stopped

    /// Terminal states never transition further (mirrors the engine's
    /// `job_state_can_transition` table — Completed/Stopped/Failed have no
    /// outgoing edges).
    public var isTerminal: Bool {
        switch self {
        case .completed, .stopped, .failed:
            return true
        case .queued, .scanning, .stoppingAfterCurrentFrame, .stoppingImmediately:
            return false
        }
    }
}

public enum FrameState: String, Codable, Equatable, Sendable {
    case waiting
    case active
    case completed
    case failed
    case skipped
    /// D-20/HEAD-12: the batch never reached this frame. Reachable only
    /// from `waiting` (`SessionEventPolicy.allowsFrameTransition`).
    case notAttempted
}

// MARK: - ScanReceipt

public struct WrittenFileBinding: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String
    public let byteLength: UInt64
    public let volumeId: UInt64?
    public let fileId: UInt64?
}

public struct MetadataOutputBindings: Codable, Equatable, Sendable {
    public let archive: WrittenFileBinding?
    public let archiveXmp: WrittenFileBinding?
    public let positive: WrittenFileBinding?
    public let preview: WrittenFileBinding?

    public init(
        archive: WrittenFileBinding? = nil,
        archiveXmp: WrittenFileBinding? = nil,
        positive: WrittenFileBinding? = nil,
        preview: WrittenFileBinding? = nil
    ) {
        self.archive = archive
        self.archiveXmp = archiveXmp
        self.positive = positive
        self.preview = preview
    }
}

public struct CaptureOutputBindings: Codable, Equatable, Sendable {
    public let rawNegative: WrittenFileBinding?
    public let rawNegativeIr: WrittenFileBinding?
    public let meter: WrittenFileBinding?
}

/// Where a completed frame's files actually landed. Populated once Plan
/// 03-02's real file-writing lands on the engine side; every field is a
/// path that build actually wrote, never a template or destination
/// directory. Mirrors `domain.rs::WrittenOutputs`.
public struct WrittenOutputs: Codable, Equatable, Sendable {
    public let archivePath: String?
    public let positivePath: String?
    public let previewPath: String?
    public let rawNegativePath: String?
    public let rawNegativeIrPath: String?
    public let metadataBindings: MetadataOutputBindings?
    public let captureBindings: CaptureOutputBindings?
    /// Exact presentation transform applied to positive/preview derivatives.
    /// The archive/IR/meter capture files are never transformed.
    public let derivativeTransform: DerivativeTransform

    public init(
        archivePath: String?,
        positivePath: String?,
        previewPath: String?,
        rawNegativePath: String? = nil,
        rawNegativeIrPath: String? = nil,
        metadataBindings: MetadataOutputBindings? = nil,
        captureBindings: CaptureOutputBindings? = nil,
        derivativeTransform: DerivativeTransform = .identity
    ) {
        self.archivePath = archivePath
        self.positivePath = positivePath
        self.previewPath = previewPath
        self.rawNegativePath = rawNegativePath
        self.rawNegativeIrPath = rawNegativeIrPath
        self.metadataBindings = metadataBindings
        self.captureBindings = captureBindings
        self.derivativeTransform = derivativeTransform
    }

    private enum CodingKeys: String, CodingKey {
        case archivePath, positivePath, previewPath, rawNegativePath, rawNegativeIrPath, metadataBindings, captureBindings, derivativeTransform
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        archivePath = try values.decodeIfPresent(String.self, forKey: .archivePath)
        positivePath = try values.decodeIfPresent(String.self, forKey: .positivePath)
        previewPath = try values.decodeIfPresent(String.self, forKey: .previewPath)
        rawNegativePath = try values.decodeIfPresent(String.self, forKey: .rawNegativePath)
        rawNegativeIrPath = try values.decodeIfPresent(String.self, forKey: .rawNegativeIrPath)
        metadataBindings = try values.decodeIfPresent(MetadataOutputBindings.self, forKey: .metadataBindings)
        captureBindings = try values.decodeIfPresent(CaptureOutputBindings.self, forKey: .captureBindings)
        derivativeTransform = try values.decodeIfPresent(
            DerivativeTransform.self,
            forKey: .derivativeTransform
        ) ?? .identity
    }
}

public struct ExposureVector: Codable, Equatable, Sendable {
    public let focusPosition: Int
    public let exposureMultiplier: Double
    public let redExposureUs: Double
    public let greenExposureUs: Double
    public let blueExposureUs: Double
}

public struct ClippingTelemetry: Codable, Equatable, Sendable {
    public let fractions: [Double]
    public let clipLevel: Double
    public let warningFraction: Double
    public let warning: Bool
}

public struct FocusDetailTelemetry: Codable, Equatable, Sendable {
    public let method: String
    public let verdict: String
    public let score: Double?
    public let textureSpan: Double
}

public struct TransportSmearAssessment: Codable, Equatable, Sendable {
    public let verdict: String
    public let startRow: UInt?
    public let suffixRows: UInt
    public let minimumMatches: UInt
    public let tailMedianRms: Double?
    public let tailMinCorr: Double?
    public let preTailMedianRms: Double?
    public let textureSpan: Double?
    public let reason: String
}

public struct HardwareTelemetry: Codable, Equatable, Sendable {
    public let exposure: ExposureVector
    public let clipping: ClippingTelemetry
    public let focusDetail: FocusDetailTelemetry
    public let transportSmear: TransportSmearAssessment
}

public struct ScanReceipt: Codable, Equatable, Identifiable, Sendable {
    public let jobId: String
    public let passToken: String?
    public let frameIndex: Int
    public let startedAt: String
    public let durationMs: Int
    public let passes: Int
    public let resolutionDpi: Int
    public let bitDepth: Int
    public let channels: String
    public let engineVersion: String
    public let deviceId: String
    public let simulated: Bool
    public let settingsFingerprint: String
    public let processing: ProcessingRecipe?
    public let output: OutputRecipe?
    public let outputs: WrittenOutputs?
    public let rgbPath: String?
    public let irPath: String?
    public let meterRgbiPath: String?
    public let hardwareTelemetry: HardwareTelemetry?
    public let deviceModel: String?
    public let hardwareVerification: String?
    public let previewExposureAdjustment: PreviewExposureAdjustment?

    public init(
        jobId: String, passToken: String? = nil, frameIndex: Int, startedAt: String, durationMs: Int, passes: Int,
        resolutionDpi: Int, bitDepth: Int, channels: String, engineVersion: String,
        deviceId: String, simulated: Bool, settingsFingerprint: String,
        processing: ProcessingRecipe?, output: OutputRecipe?, outputs: WrittenOutputs?,
        rgbPath: String?, irPath: String?, meterRgbiPath: String?, hardwareTelemetry: HardwareTelemetry?,
        deviceModel: String? = nil, hardwareVerification: String? = nil,
        previewExposureAdjustment: PreviewExposureAdjustment? = nil
    ) {
        self.jobId = jobId; self.passToken = passToken; self.frameIndex = frameIndex; self.startedAt = startedAt
        self.durationMs = durationMs; self.passes = passes; self.resolutionDpi = resolutionDpi
        self.bitDepth = bitDepth; self.channels = channels; self.engineVersion = engineVersion
        self.deviceId = deviceId; self.simulated = simulated; self.settingsFingerprint = settingsFingerprint
        self.processing = processing; self.output = output; self.outputs = outputs
        self.rgbPath = rgbPath; self.irPath = irPath; self.meterRgbiPath = meterRgbiPath
        self.hardwareTelemetry = hardwareTelemetry; self.deviceModel = deviceModel
        self.hardwareVerification = hardwareVerification
        self.previewExposureAdjustment = previewExposureAdjustment
    }

    public var id: String { "\(jobId)#\(frameIndex)@\(startedAt)" }
}

// MARK: - Metadata (META-01)

/// Mirrors `domain.rs::PartialDate` exactly: an internally-tagged enum
/// (`#[serde(tag = "kind")]`) rather than Swift's default externally-tagged
/// synthesis (`{"caseName": {...}}`), so `Codable` is hand-written here —
/// this is the first internally-tagged enum this codebase's Swift side has
/// needed to mirror. Case names are camelCase, matching the wire's `kind`
/// values exactly (`FilmProcess.c41ColorNegative`-style precedent). An
/// unrecognized `kind` decodes as a catchable `DecodingError` rather than
/// crashing (D-14's unknown-values tolerance) — never fabricate today's
/// date for a genuinely unknown one.
public enum PartialDate: Codable, Equatable, Sendable {
    case exact(date: String)
    case monthOnly(year: Int, month: Int)
    case yearOnly(year: Int)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case kind
        case date
        case year
        case month
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "exact":
            self = .exact(date: try container.decode(String.self, forKey: .date))
        case "monthOnly":
            self = .monthOnly(
                year: try container.decode(Int.self, forKey: .year),
                month: try container.decode(Int.self, forKey: .month)
            )
        case "yearOnly":
            self = .yearOnly(year: try container.decode(Int.self, forKey: .year))
        case "unknown":
            self = .unknown
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unrecognized PartialDate kind \"\(kind)\""
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exact(let date):
            try container.encode("exact", forKey: .kind)
            try container.encode(date, forKey: .date)
        case .monthOnly(let year, let month):
            try container.encode("monthOnly", forKey: .kind)
            try container.encode(year, forKey: .year)
            try container.encode(month, forKey: .month)
        case .yearOnly(let year):
            try container.encode("yearOnly", forKey: .kind)
            try container.encode(year, forKey: .year)
        case .unknown:
            try container.encode("unknown", forKey: .kind)
        }
    }
}

/// Mirrors `domain.rs::MetadataSet` field-for-field. A plain, always-safe
/// starting point: every field defaults to absent and `keywords` defaults
/// to empty, so `MetadataSet()` is already the correct "nothing entered
/// yet" value — the roll-metadata UI (Plan 06-05) never needs a separate
/// empty-state sentinel.
public struct MetadataSet: Codable, Equatable, Sendable {
    public let camera: String?
    public let lens: String?
    public let filmStock: String?
    public let process: FilmProcess?
    public let iso: Int?
    public let date: PartialDate?
    public let location: String?
    public let photographer: String?
    public let copyright: String?
    public let rollId: String?
    public let frameNumber: Int?
    public let notes: String?
    public let keywords: [String]

    public init(
        camera: String? = nil,
        lens: String? = nil,
        filmStock: String? = nil,
        process: FilmProcess? = nil,
        iso: Int? = nil,
        date: PartialDate? = nil,
        location: String? = nil,
        photographer: String? = nil,
        copyright: String? = nil,
        rollId: String? = nil,
        frameNumber: Int? = nil,
        notes: String? = nil,
        keywords: [String] = []
    ) {
        self.camera = camera
        self.lens = lens
        self.filmStock = filmStock
        self.process = process
        self.iso = iso
        self.date = date
        self.location = location
        self.photographer = photographer
        self.copyright = copyright
        self.rollId = rollId
        self.frameNumber = frameNumber
        self.notes = notes
        self.keywords = keywords
    }
}

// MARK: - project.create / project.open / project.list

/// Reproducible display geometry for finished Positive/Preview files.
/// Rotation is clockwise; horizontal/vertical mirrors are applied in the
/// unrotated source axes before the quarter-turn. Capture masters and raw
/// negatives remain byte-untouched.
public struct DerivativeTransform: Codable, Equatable, Sendable {
    public let rotationDegrees: Int
    public let horizontalMirror: Bool
    public let verticalMirror: Bool

    public static let identity = DerivativeTransform()

    public init(
        rotationDegrees: Int = 0,
        horizontalMirror: Bool = false,
        verticalMirror: Bool = false
    ) {
        self.rotationDegrees = rotationDegrees
        self.horizontalMirror = horizontalMirror
        self.verticalMirror = verticalMirror
    }
}

/// A project-persisted relative frame-boundary adjustment plus presentation
/// transform. Draft offsets are
/// deliberately retained with `approved == false` so reopening a project can
/// restore the operator's work without making it scan-authoritative.
public struct FrameAlignment: Codable, Equatable, Sendable {
    public let offsetRows: Int
    public let approved: Bool
    public let derivativeTransform: DerivativeTransform

    public init(
        offsetRows: Int,
        approved: Bool,
        derivativeTransform: DerivativeTransform = .identity
    ) {
        self.offsetRows = offsetRows
        self.approved = approved
        self.derivativeTransform = derivativeTransform
    }

    private enum CodingKeys: String, CodingKey {
        case offsetRows, approved, derivativeTransform
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        offsetRows = try values.decode(Int.self, forKey: .offsetRows)
        approved = try values.decode(Bool.self, forKey: .approved)
        derivativeTransform = try values.decodeIfPresent(
            DerivativeTransform.self,
            forKey: .derivativeTransform
        ) ?? .identity
    }
}

public struct ProjectFrame: Codable, Equatable, Sendable {
    public let index: Int
    public let excluded: Bool
    /// Per-frame capture override slot. Read/written by
    /// `SessionModel.setFrameCaptureOverride(_:to:)`. Mirrors
    /// `domain.rs::ProjectFrame.capture_override`.
    public let captureOverride: CaptureRecipe?
    /// Per-frame processing override slot. Read/written by
    /// `SessionModel.setFrameProcessingOverride(_:to:)`. Mirrors
    /// `domain.rs::ProjectFrame.processing_override`.
    public let processingOverride: ProcessingRecipe?
    /// Per-frame output override slot. Read/written by
    /// `SessionModel.setFrameOutputOverride(_:to:)`. Mirrors
    /// `domain.rs::ProjectFrame.output_override`.
    public let outputOverride: OutputRecipe?
    /// Draft or approved relative boundary adjustment for this frame.
    public let alignment: FrameAlignment?
    /// Per-frame metadata override slot. Read/written by
    /// `SessionModel.setFrameMetadataOverride(_:to:)`; when non-nil it
    /// entirely replaces the roll-wide `ScanProject.rollMetadata` for this
    /// frame, with no per-field merge. Mirrors
    /// `domain.rs::ProjectFrame.metadata_override`.
    public let metadataOverride: MetadataSet?
    public let receipts: [ScanReceipt]

    public init(
        index: Int,
        excluded: Bool,
        captureOverride: CaptureRecipe? = nil,
        processingOverride: ProcessingRecipe? = nil,
        outputOverride: OutputRecipe? = nil,
        alignment: FrameAlignment? = nil,
        metadataOverride: MetadataSet? = nil,
        receipts: [ScanReceipt]
    ) {
        self.index = index
        self.excluded = excluded
        self.captureOverride = captureOverride
        self.processingOverride = processingOverride
        self.outputOverride = outputOverride
        self.alignment = alignment
        self.metadataOverride = metadataOverride
        self.receipts = receipts
    }
}

public struct ScanProject: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let carrier: SimulatedFilmCarrier
    public let frameCount: Int
    public let filmProcess: FilmProcess
    public let recipes: OutputRecipe
    /// Roll-wide default metadata. Read/written by
    /// `SessionModel.setRollMetadata(_:)`; every frame without its own
    /// `metadataOverride` inherits this set. Always present, never omitted
    /// on the wire, even when every field inside it is nil/empty. Mirrors
    /// `domain.rs::ScanProject.roll_metadata`.
    public let rollMetadata: MetadataSet
    public let rollExposureLock: RollExposureLock?
    public let createdAt: String
    public let frames: [ProjectFrame]

    public init(
        schemaVersion: Int,
        id: String,
        name: String,
        carrier: SimulatedFilmCarrier,
        frameCount: Int,
        filmProcess: FilmProcess,
        recipes: OutputRecipe,
        rollMetadata: MetadataSet,
        rollExposureLock: RollExposureLock? = nil,
        createdAt: String,
        frames: [ProjectFrame]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.carrier = carrier
        self.frameCount = frameCount
        self.filmProcess = filmProcess
        self.recipes = recipes
        self.rollMetadata = rollMetadata
        self.rollExposureLock = rollExposureLock
        self.createdAt = createdAt
        self.frames = frames
    }
}

public struct RollExposureLock: Codable, Equatable, Sendable {
    public let slot: Int
    public let rgbExposuresRaw10ns: [Int]
    public let irMeteredExposureRaw10ns: Int
    public let meterEvidencePath: String
    public let meterEvidenceSha256: String
    public let journalPath: String
    public let journalSha256: String
    public let source: String?

    public init(
        slot: Int,
        rgbExposuresRaw10ns: [Int],
        irMeteredExposureRaw10ns: Int,
        meterEvidencePath: String,
        meterEvidenceSha256: String,
        journalPath: String,
        journalSha256: String,
        source: String? = nil
    ) {
        self.slot = slot
        self.rgbExposuresRaw10ns = rgbExposuresRaw10ns
        self.irMeteredExposureRaw10ns = irMeteredExposureRaw10ns
        self.meterEvidencePath = meterEvidencePath
        self.meterEvidenceSha256 = meterEvidenceSha256
        self.journalPath = journalPath
        self.journalSha256 = journalSha256
        self.source = source
    }
}

/// Lightweight listing shape for `project.list` — everything in
/// `ScanProject` except `frames`, plus the resolved `directory` it was read
/// from. Only ever decoded (never manually constructed), so — like
/// `ScanReceipt` — no custom `init` is needed; `Identifiable` is satisfied
/// automatically by the existing `id` stored property.
public struct ProjectSummary: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let carrier: SimulatedFilmCarrier
    public let frameCount: Int
    public let filmProcess: FilmProcess
    public let createdAt: String
    public let directory: String
}

public struct ProjectCreateParams: Codable, Sendable {
    public let name: String
    public let carrier: SimulatedFilmCarrier
    public let frameCount: Int
    public let filmProcess: FilmProcess
    // Swift's synthesized Encodable conformance calls `encodeIfPresent` for
    // Optional stored properties, so `directory == nil` omits the key
    // entirely (matching `AcquireThumbnailsParams.frames`'s established
    // omit-on-nil behavior), rather than encoding a literal JSON `null`.
    public let directory: String?
    /// D-21/HEAD-12: 1-based frame indices to create excluded --
    /// `SessionModel.createProject`'s own previewed-indices-minus-
    /// selection computation, sent once at create time. `nil` omits the
    /// key, creating every frame unexcluded (today's behavior unchanged).
    public let excludedFrames: [Int]?

    public init(
        name: String,
        carrier: SimulatedFilmCarrier,
        frameCount: Int,
        filmProcess: FilmProcess,
        directory: String? = nil,
        excludedFrames: [Int]? = nil
    ) {
        self.name = name
        self.carrier = carrier
        self.frameCount = frameCount
        self.filmProcess = filmProcess
        self.directory = directory
        self.excludedFrames = excludedFrames
    }
}

public struct ProjectCreateResult: Decodable, Sendable {
    public let project: ScanProject
    public let directory: String
}

public struct ProjectOpenParams: Codable, Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }
}

public struct ProjectOpenResult: Decodable, Sendable {
    public let project: ScanProject
    public let directory: String
}

public struct ProjectListParams: Codable, Sendable {
    public let directory: String?

    public init(directory: String? = nil) {
        self.directory = directory
    }
}

public struct ProjectListResult: Decodable, Sendable {
    public let projects: [ProjectSummary]
}

// MARK: - project.setFrameExcluded / setFrameCaptureOverride /
// setFrameProcessingOverride / setFrameOutputOverride / setFrameAlignment /
// setRollMetadata / setFrameMetadataOverride (SHEET-02/SHEET-03,
// META-01/META-02)

public struct SetFrameExcludedParams: Codable, Sendable {
    public let frameIndex: Int
    public let excluded: Bool

    public init(frameIndex: Int, excluded: Bool) {
        self.frameIndex = frameIndex
        self.excluded = excluded
    }
}

/// `capture`/`processing`/`output` (here and on the two sibling override
/// Params types below) are deliberately plain Optionals, not
/// `= nil`-defaulted-and-omittable in the sense `ProjectCreateParams.directory`
/// is: every call always states its intent explicitly (populated = set,
/// `nil` = clear/revert to roll-wide inheritance), there is no third "leave
/// unchanged" state. Swift's synthesized `Encodable` still omits the wire
/// key entirely on `nil` (`encodeIfPresent`) rather than sending a literal
/// JSON `null`; this requires no special handling because the engine's own
/// plain `Option<T>` (no `#[serde(default)]`) decodes a missing key
/// identically to an explicit `null` — both become `None`.
public struct SetFrameCaptureOverrideParams: Codable, Sendable {
    public let frameIndex: Int
    public let capture: CaptureRecipe?

    public init(frameIndex: Int, capture: CaptureRecipe?) {
        self.frameIndex = frameIndex
        self.capture = capture
    }
}

public struct SetFrameProcessingOverrideParams: Codable, Sendable {
    public let frameIndex: Int
    public let processing: ProcessingRecipe?

    public init(frameIndex: Int, processing: ProcessingRecipe?) {
        self.frameIndex = frameIndex
        self.processing = processing
    }
}

public struct SetFrameOutputOverrideParams: Codable, Sendable {
    public let frameIndex: Int
    public let output: OutputRecipe?

    public init(frameIndex: Int, output: OutputRecipe?) {
        self.frameIndex = frameIndex
        self.output = output
    }
}

/// Persists or clears one frame's relative boundary adjustment.
public struct SetFrameAlignmentParams: Codable, Sendable {
    public let frameIndex: Int
    public let alignment: FrameAlignment?

    public init(frameIndex: Int, alignment: FrameAlignment?) {
        self.frameIndex = frameIndex
        self.alignment = alignment
    }
}

/// Sets the roll-wide default metadata every frame without its own
/// `metadataOverride` inherits. Mirrors `protocol.rs::SetRollMetadataParams`.
public struct SetRollMetadataParams: Codable, Sendable {
    public let metadata: MetadataSet

    public init(metadata: MetadataSet) {
        self.metadata = metadata
    }
}

/// Sets (`metadata` populated) or clears (`metadata: nil`, reverting to
/// roll-wide inheritance) one frame's independent metadata override — same
/// "always explicit, no third leave-unchanged state" convention as
/// `SetFrameCaptureOverrideParams` above. Mirrors
/// `protocol.rs::SetFrameMetadataOverrideParams`.
public struct SetFrameMetadataOverrideParams: Codable, Sendable {
    public let frameIndex: Int
    public let metadata: MetadataSet?

    public init(frameIndex: Int, metadata: MetadataSet?) {
        self.frameIndex = frameIndex
        self.metadata = metadata
    }
}

/// Shared result shape for all seven `project.setFrame*`/`setRollMetadata`
/// methods — each mutates-and-returns-the-whole-project identically, so seven
/// near-identical result types would be pure duplication. Mirrors
/// `protocol.rs::SetFrameResult`.
public struct SetFrameResult: Decodable, Sendable {
    public let project: ScanProject
}

// MARK: - project.analyzeFrameDefects (DEF-01/DEF-02)

public enum DefectKind: String, Codable, Equatable, Sendable {
    case dust
    case scratch
}

public enum DefectClassification: String, Codable, Equatable, Sendable {
    case willCorrect
    case uncertain
}

/// Mirrors `domain.rs::DefectInstance` field-for-field. `endX`/`endY` are
/// `nil` for `kind == .dust`, populated for `kind == .scratch` -- see that
/// Rust type's own doc comment for the full rationale (mirrors
/// `processing::ice::DefectMap`'s severity convention without depending on
/// it; Phase 17 will populate this same shape from real data).
public struct DefectInstance: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let kind: DefectKind
    public let severity: Double
    public let classification: DefectClassification
    public let centerX: Double
    public let centerY: Double
    public let radius: Double
    public let endX: Double?
    public let endY: Double?
}

public struct AnalyzeFrameDefectsParams: Codable, Sendable {
    public let frameIndex: Int
    public let capture: CaptureRecipe
    public let processing: ProcessingRecipe

    public init(frameIndex: Int, capture: CaptureRecipe, processing: ProcessingRecipe) {
        self.frameIndex = frameIndex
        self.capture = capture
        self.processing = processing
    }
}

/// Engine response for `project.analyzeFrameDefects`. Carries the defect
/// list plus provenance signals: `simulated` distinguishes synthetic from
/// real data; `digitalIceEnabled` disambiguates an empty `defects` array
/// (ICE off vs. genuinely clean); `transportSmearFlagged` and
/// `transportSmearReason` surface hardware telemetry that affects repair
/// confidence.
public struct AnalyzeFrameDefectsResult: Decodable, Sendable {
    public let frameIndex: Int
    public let defects: [DefectInstance]
    public let simulated: Bool
    public let digitalIceEnabled: Bool
    public let transportSmearFlagged: Bool
    public let transportSmearReason: String?
}

// MARK: - Metadata (META-01/02) + ExifTool (META-03) + project.pendingFrames (PERSIST-02)

/// Result of probing the engine's host for a usable ExifTool binary.
/// `path`/`version` are always present as explicit `nil` when `available`
/// is `false` (never a separate "unknown" case), mirroring
/// `ScannerStatus`'s own always-present-sometimes-null convention. Mirrors
/// `exiftool.rs::ExifToolDetection`.
public struct ExifToolDetection: Decodable, Equatable, Sendable {
    public let available: Bool
    public let path: String?
    public let version: String?
}

public struct PreviewMetadataCommandParams: Codable, Sendable {
    public let frameIndex: Int

    public init(frameIndex: Int) {
        self.frameIndex = frameIndex
    }
}

/// A dry-run preview of the ExifTool invocation `project.applyMetadata`
/// would actually run for this frame — never executed itself. Mirrors
/// `protocol.rs::PreviewMetadataCommandResult`.
public struct PreviewMetadataCommandResult: Decodable, Sendable {
    public let available: Bool
    public let exiftoolPath: String?
    public let targets: [String]
    public let arguments: [String]
    /// Engine-minted digest binding the exact argument vector (including
    /// resolved output targets) displayed by the preview. The client must
    /// return this value unchanged on `project.applyMetadata`.
    public let fingerprint: String
}

public struct ApplyMetadataParams: Codable, Sendable {
    public let frameIndex: Int
    public let previewFingerprint: String

    public init(frameIndex: Int, previewFingerprint: String) {
        self.frameIndex = frameIndex
        self.previewFingerprint = previewFingerprint
    }
}

/// Mirrors `protocol.rs::ApplyMetadataResult`. The engine rebuilds every
/// argument and target server-side from the active project's own resolved
/// metadata and receipts — this result reports what actually ran, never
/// what the client asked to run.
public struct ApplyMetadataResult: Decodable, Sendable {
    public let success: Bool
    public let exitCode: Int
    public let stdout: String
    public let stderr: String
    public let targets: [String]
    /// The exact argument vector rebuilt and executed by the engine.
    public let arguments: [String]
    /// The engine's digest of `arguments`, echoed so the client can verify
    /// that the reported execution still matches the displayed preview.
    public let fingerprint: String
}

/// Result for `project.pendingFrames`: the exact set of frame indices that
/// are neither excluded nor already carrying a receipt, plus summary counts
/// so the client can display progress without re-deriving them. Mirrors
/// `protocol.rs::PendingFramesResult`.
public struct PendingFramesResult: Decodable, Sendable {
    public let frames: [Int]
    public let totalFrames: Int
    public let completedCount: Int
    public let excludedCount: Int
}

// MARK: - Event payloads
//
// One payload type per PROTOCOL.md "Events" entry. `EngineEvent` (in
// EngineClient.swift) carries the raw line `Data`; each consumer decodes
// `EventEnvelope<SpecificPayload>` from it directly for the event names it
// recognizes.

public struct ScannerStatusPayload: Decodable, Sendable {
    public let status: ScannerStatus
    public let operationId: String?
}

public struct ThumbnailPayload: Decodable, Sendable {
    public let frameIndex: Int
    public let thumbnail: Thumbnail
    public let operationId: String?
}

public struct ThumbnailsCompletePayload: Decodable, Sendable {
    public let count: Int
    public let operationId: String?
}

/// `scanner.thumbnailsFailed` — the engine's typed report that a preview
/// acquisition failed after acceptance (real backend: the bridge's
/// `roll.previewError`, forwarded with its BRIDGE.md error code verbatim)
/// or that thumbnail events were dropped. `code` keeps the bridge's own
/// vocabulary (e.g. `REFEED_REQUIRED`, `FEEDER_PARKED`) — the app branches
/// on the codes it knows and displays the rest.
public struct ThumbnailsFailedPayload: Decodable, Sendable {
    public let code: String
    public let message: String
    public let operationId: String?
    public let evidence: DiagnosticEvidenceReference?
    public let diagnosticEvidence: DiagnosticEvidenceArtifact?
    public let diagnosticEvidenceUnavailableReason: String?

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case operationId
        case evidence
        case diagnosticEvidence
        case diagnosticEvidenceUnavailableReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        operationId = try container.decodeIfPresent(
            String.self,
            forKey: .operationId
        )
        evidence = try container.decodeIfPresent(
            DiagnosticEvidenceReference.self,
            forKey: .evidence
        )
        let suppliedReason = try container.decodeIfPresent(
            String.self,
            forKey: .diagnosticEvidenceUnavailableReason
        )
        do {
            diagnosticEvidence = try container.decodeIfPresent(
                DiagnosticEvidenceArtifact.self,
                forKey: .diagnosticEvidence
            )
            diagnosticEvidenceUnavailableReason = suppliedReason
        } catch {
            diagnosticEvidence = nil
            diagnosticEvidenceUnavailableReason =
                "bounded diagnostic evidence could not be decoded by this client"
        }
    }
}

public struct JobStatePayload: Decodable, Sendable {
    public let jobId: String
    public let state: JobState
}

public struct ScanProgressPayload: Decodable, Sendable {
    public let jobId: String
    public let frameIndex: Int
    public let frameOrdinal: Int
    public let totalFrames: Int
    public let pass: Int
    public let totalPasses: Int
    public let framePercent: Double
    public let jobPercent: Double
    public let etaSeconds: Double
}

public struct FrameStatePayload: Decodable, Sendable {
    public let jobId: String
    public let frameIndex: Int
    public let state: FrameState
    public let attempt: Int
    public let error: ErrorPayload?
}

public struct FrameCompletedPayload: Decodable, Sendable {
    public let jobId: String
    public let frameIndex: Int
    public let receipt: ScanReceipt
}

public struct ScanSummary: Decodable, Equatable, Sendable {
    public let completed: [Int]
    public let failed: [Int]
    public let skipped: [Int]
    /// D-20/HEAD-12: frames the batch never reached -- distinct from
    /// `failed`, which names only the frame(s) the engine actually
    /// attributed a typed failure to. A custom `init(from:)` defaults this
    /// to `[]` so an older engine's summary (which never sent this key)
    /// still decodes.
    public let notAttempted: [Int]
    public let stopped: Bool
    public let evidencePackageStatus: String?

    private enum CodingKeys: String, CodingKey {
        case completed, failed, skipped, notAttempted, stopped, evidencePackageStatus
    }

    public init(
        completed: [Int],
        failed: [Int],
        skipped: [Int],
        notAttempted: [Int] = [],
        stopped: Bool,
        evidencePackageStatus: String? = nil
    ) {
        self.completed = completed
        self.failed = failed
        self.skipped = skipped
        self.notAttempted = notAttempted
        self.stopped = stopped
        self.evidencePackageStatus = evidencePackageStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completed = try container.decode([Int].self, forKey: .completed)
        failed = try container.decode([Int].self, forKey: .failed)
        skipped = try container.decode([Int].self, forKey: .skipped)
        notAttempted = try container.decodeIfPresent([Int].self, forKey: .notAttempted) ?? []
        stopped = try container.decode(Bool.self, forKey: .stopped)
        evidencePackageStatus = try container.decodeIfPresent(String.self, forKey: .evidencePackageStatus)
    }
}

public struct ScanCompletedPayload: Decodable, Sendable {
    public let jobId: String
    public let summary: ScanSummary
}
