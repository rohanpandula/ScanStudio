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
