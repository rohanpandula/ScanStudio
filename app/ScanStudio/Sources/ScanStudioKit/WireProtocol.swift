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

/// Inbound shape (app -> engine): `{"id": .., "method": .., "params": ..}`.
/// Used by `EngineClient` to serialize outgoing requests. `Encodable`-only
/// (matching `EngineClient.request`'s `Params: Encodable` constraint) —
/// see `DecodedRequestEnvelope` for the decode direction.
public struct RequestEnvelope<Params: Encodable>: Encodable {
    public let id: UInt64
    public let method: String
    public let params: Params

    public init(id: UInt64, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// The same `{"id", "method", "params"}` shape, `Decodable`-only. Used by
/// `FixtureDecodingTests` to decode the request fixtures (01/04/07/10) into
/// their matching typed `Params` shape.
public struct DecodedRequestEnvelope<Params: Decodable>: Decodable {
    public let id: UInt64
    public let method: String
    public let params: Params
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

public struct ErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let recoverable: Bool

    public init(code: String, message: String, recoverable: Bool) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
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

/// Typed error thrown out of `EngineClient.request` for both engine-reported
/// errors (`{"id", "error": {...}}`) and local failures (e.g. the engine
/// process exiting unexpectedly).
public struct EngineRequestError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let recoverable: Bool

    public init(code: String, message: String, recoverable: Bool) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
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

    public init(clientName: String, protocolVersion: Int) {
        self.clientName = clientName
        self.protocolVersion = protocolVersion
    }
}

public struct HelloResult: Decodable, Sendable {
    public let engineName: String
    public let engineVersion: String
    public let protocolVersion: Int
    public let capabilities: [String]
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
}

// MARK: - scanner.connect

public struct ConnectOptions: Codable, Equatable, Sendable {
    public let timeScale: Double
    public let faultInjection: String

    public init(timeScale: Double, faultInjection: String) {
        self.timeScale = timeScale
        self.faultInjection = faultInjection
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
        motionArmed: Bool? = nil
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
            motionArmed: motionArmed
        )
    }
}

public struct ConnectResult: Decodable, Sendable {
    public let device: DeviceInfo
    public let status: ScannerStatus
}

// MARK: - sim.loadMedia

public struct LoadMediaParams: Codable, Sendable {
    public let carrier: String

    public init(carrier: String) {
        self.carrier = carrier
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

// MARK: - roll.approve

/// Explicit operator approval for one preview boundary that the engine
/// refused before scanner motion. Approval is deliberately separate from
/// `scan.start`; callers must never infer or send it from an error message.
/// `operationId` binds the approval to the exact completed preview the
/// operator reviewed so a reconnect or replacement preview cannot reuse it.
public struct RollApproveParams: Codable, Sendable {
    public let frameIndex: Int
    public let operationId: String

    public init(frameIndex: Int, operationId: String) {
        self.frameIndex = frameIndex
        self.operationId = operationId
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

public struct CaptureRecipe: Codable, Equatable, Sendable {
    public let resolutionDpi: Int
    public let bitDepth: Int
    public let multisamplePasses: Int
    public let channels: String

    public init(resolutionDpi: Int, bitDepth: Int, multisamplePasses: Int, channels: String) {
        self.resolutionDpi = resolutionDpi
        self.bitDepth = bitDepth
        self.multisamplePasses = multisamplePasses
        self.channels = channels
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

public enum RawTiffInfrared: String, Codable, CaseIterable, Identifiable, Sendable {
    case fourthChannel
    case omitted
    case sidecar

    public var id: String { rawValue }
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

    public init(
        archive: ArchiveRecipe,
        rawExport: RawExportRecipe = RawExportRecipe(),
        positive: PositiveRecipe,
        preview: PreviewRecipe,
        autoCrop: Bool = false
    ) {
        self.archive = archive
        self.rawExport = rawExport
        self.positive = positive
        self.preview = preview
        self.autoCrop = autoCrop
    }

    private enum CodingKeys: String, CodingKey { case archive, rawExport, positive, preview, autoCrop }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        archive = try values.decode(ArchiveRecipe.self, forKey: .archive)
        rawExport = try values.decodeIfPresent(RawExportRecipe.self, forKey: .rawExport) ?? RawExportRecipe()
        positive = try values.decode(PositiveRecipe.self, forKey: .positive)
        preview = try values.decode(PreviewRecipe.self, forKey: .preview)
        autoCrop = try values.decodeIfPresent(Bool.self, forKey: .autoCrop) ?? false
    }
}

public struct ScanStartParams: Codable, Sendable {
    public let frames: [Int]
    public let recipe: CaptureRecipe
    public let processing: ProcessingRecipe?
    public let output: OutputRecipe?

    public init(
        frames: [Int],
        recipe: CaptureRecipe,
        processing: ProcessingRecipe? = nil,
        output: OutputRecipe? = nil
    ) {
        self.frames = frames
        self.recipe = recipe
        self.processing = processing
        self.output = output
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
}

// MARK: - ScanReceipt

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
    /// Exact presentation transform applied to positive/preview derivatives.
    /// The archive/IR/meter capture files are never transformed.
    public let derivativeTransform: DerivativeTransform

    public init(
        archivePath: String?,
        positivePath: String?,
        previewPath: String?,
        rawNegativePath: String? = nil,
        rawNegativeIrPath: String? = nil,
        derivativeTransform: DerivativeTransform = .identity
    ) {
        self.archivePath = archivePath
        self.positivePath = positivePath
        self.previewPath = previewPath
        self.rawNegativePath = rawNegativePath
        self.rawNegativeIrPath = rawNegativeIrPath
        self.derivativeTransform = derivativeTransform
    }

    private enum CodingKeys: String, CodingKey {
        case archivePath, positivePath, previewPath, rawNegativePath, rawNegativeIrPath, derivativeTransform
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        archivePath = try values.decodeIfPresent(String.self, forKey: .archivePath)
        positivePath = try values.decodeIfPresent(String.self, forKey: .positivePath)
        previewPath = try values.decodeIfPresent(String.self, forKey: .previewPath)
        rawNegativePath = try values.decodeIfPresent(String.self, forKey: .rawNegativePath)
        rawNegativeIrPath = try values.decodeIfPresent(String.self, forKey: .rawNegativeIrPath)
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
        self.createdAt = createdAt
        self.frames = frames
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

    public init(
        name: String,
        carrier: SimulatedFilmCarrier,
        frameCount: Int,
        filmProcess: FilmProcess,
        directory: String? = nil
    ) {
        self.name = name
        self.carrier = carrier
        self.frameCount = frameCount
        self.filmProcess = filmProcess
        self.directory = directory
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
}

public struct ApplyMetadataParams: Codable, Sendable {
    public let frameIndex: Int

    public init(frameIndex: Int) {
        self.frameIndex = frameIndex
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
    public let stopped: Bool
    public let evidencePackageStatus: String?

    public init(
        completed: [Int],
        failed: [Int],
        skipped: [Int],
        stopped: Bool,
        evidencePackageStatus: String? = nil
    ) {
        self.completed = completed
        self.failed = failed
        self.skipped = skipped
        self.stopped = stopped
        self.evidencePackageStatus = evidencePackageStatus
    }
}

public struct ScanCompletedPayload: Decodable, Sendable {
    public let jobId: String
    public let summary: ScanSummary
}
