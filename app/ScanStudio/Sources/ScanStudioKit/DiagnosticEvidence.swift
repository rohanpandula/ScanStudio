import Foundation

public struct DiagnosticEvidenceReference: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let evidenceId: String
    public let operationId: String
    public let sessionEpoch: String

    public init(
        schemaVersion: Int,
        evidenceId: String,
        operationId: String,
        sessionEpoch: String
    ) {
        self.schemaVersion = schemaVersion
        self.evidenceId = evidenceId
        self.operationId = operationId
        self.sessionEpoch = sessionEpoch
    }
}

/// A bounded, share-safe witness that lets a diagnostic bundle reproduce the
/// exact structural decision behind a terminal refusal without exporting film
/// pixels, raw scanner records, or local filesystem paths.
public struct DiagnosticEvidenceArtifact: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let evidenceId: String
    public let operationId: String
    public let sessionEpoch: String
    public let operationKind: String
    public let builds: DiagnosticEvidenceBuilds
    public let device: DiagnosticEvidenceDevice
    public let witness: DiagnosticEvidenceWitness

    public init(
        schemaVersion: Int,
        evidenceId: String,
        operationId: String,
        sessionEpoch: String,
        operationKind: String,
        builds: DiagnosticEvidenceBuilds,
        device: DiagnosticEvidenceDevice,
        witness: DiagnosticEvidenceWitness
    ) {
        self.schemaVersion = schemaVersion
        self.evidenceId = evidenceId
        self.operationId = operationId
        self.sessionEpoch = sessionEpoch
        self.operationKind = operationKind
        self.builds = builds
        self.device = device
        self.witness = witness
    }

    public var appBuild: String { builds.app }
    public var engineBuild: String { builds.engine }
    public var bridgeBuild: String { builds.bridge }
    public var reference: DiagnosticEvidenceReference {
        .init(
            schemaVersion: schemaVersion,
            evidenceId: evidenceId,
            operationId: operationId,
            sessionEpoch: sessionEpoch
        )
    }

    public init(
        schemaVersion: Int,
        evidenceId: String,
        operationId: String,
        sessionEpoch: String,
        operationKind: String,
        appBuild: String,
        engineBuild: String,
        bridgeBuild: String,
        device: DiagnosticEvidenceDevice,
        witness: DiagnosticEvidenceWitness
    ) {
        self.init(
            schemaVersion: schemaVersion,
            evidenceId: evidenceId,
            operationId: operationId,
            sessionEpoch: sessionEpoch,
            operationKind: operationKind,
            builds: .init(app: appBuild, engine: engineBuild, bridge: bridgeBuild),
            device: device,
            witness: witness
        )
    }
}

public struct DiagnosticEvidenceBuilds: Codable, Equatable, Sendable {
    public let app: String
    public let engine: String
    public let bridge: String

    public init(app: String, engine: String, bridge: String) {
        self.app = app
        self.engine = engine
        self.bridge = bridge
    }
}

public struct DiagnosticEvidenceDevice: Codable, Equatable, Sendable {
    public let model: String
    public let adapter: String
    public let holder: String

    public init(model: String, adapter: String, holder: String) {
        self.model = model
        self.adapter = adapter
        self.holder = holder
    }
}

public struct DiagnosticAffineAnchor: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let inputRow: Double
    public let observedRow: Double
    public let fittedRow: Double
    public let residualRows: Double

    public init(
        ordinal: Int,
        inputRow: Double,
        observedRow: Double,
        fittedRow: Double,
        residualRows: Double
    ) {
        self.ordinal = ordinal
        self.inputRow = inputRow
        self.observedRow = observedRow
        self.fittedRow = fittedRow
        self.residualRows = residualRows
    }
}

public struct DiagnosticAffineTransform: Codable, Equatable, Sendable {
    public let slope: Double
    public let intercept: Double

    public init(slope: Double, intercept: Double) {
        self.slope = slope
        self.intercept = intercept
    }
}

public struct DiagnosticAffineThresholds: Codable, Equatable, Sendable {
    public let maximumMeanAbsoluteResidualRows: Double
    public let maximumResidualRows: Double

    public init(
        maximumMeanAbsoluteResidualRows: Double,
        maximumResidualRows: Double
    ) {
        self.maximumMeanAbsoluteResidualRows = maximumMeanAbsoluteResidualRows
        self.maximumResidualRows = maximumResidualRows
    }
}

public struct DiagnosticAffineWitness: Codable, Equatable, Sendable {
    public let holderCapacity: Int
    public let anchors: [DiagnosticAffineAnchor]
    public let transform: DiagnosticAffineTransform
    public let thresholds: DiagnosticAffineThresholds
    public let meanAbsoluteResidualRows: Double
    public let maximumResidualRows: Double

    public init(
        holderCapacity: Int = 40,
        anchors: [DiagnosticAffineAnchor],
        transform: DiagnosticAffineTransform,
        thresholds: DiagnosticAffineThresholds,
        meanAbsoluteResidualRows: Double,
        maximumResidualRows: Double
    ) {
        self.holderCapacity = holderCapacity
        self.anchors = anchors
        self.transform = transform
        self.thresholds = thresholds
        self.meanAbsoluteResidualRows = meanAbsoluteResidualRows
        self.maximumResidualRows = maximumResidualRows
    }
}

public struct DiagnosticTerminalPaddingWitness: Codable, Equatable, Sendable {
    public let recordCount: Int
    public let byteCount: Int
    public let parity: String
    public let housekeepingByteCount: Int
    public let nonzeroRgbCount: Int
    public let mismatchLocation: DiagnosticMismatchLocation

    public init(
        recordCount: Int,
        byteCount: Int,
        parity: String,
        housekeepingByteCount: Int,
        nonzeroRgbCount: Int,
        mismatchLocation: DiagnosticMismatchLocation
    ) {
        self.recordCount = recordCount
        self.byteCount = byteCount
        self.parity = parity
        self.housekeepingByteCount = housekeepingByteCount
        self.nonzeroRgbCount = nonzeroRgbCount
        self.mismatchLocation = mismatchLocation
    }
}

public struct DiagnosticMismatchLocation: Codable, Equatable, Sendable {
    public let recordIndex: Int
    public let byteOffset: Int

    public init(recordIndex: Int, byteOffset: Int) {
        self.recordIndex = recordIndex
        self.byteOffset = byteOffset
    }
}

/// The witness is deliberately a closed union. Adding an evidence kind is a
/// schema change reviewed in both producer and consumer; unknown kinds fail
/// decoding instead of being copied into a shareable archive as arbitrary
/// JSON.
public enum DiagnosticEvidenceWitness: Codable, Equatable, Sendable {
    case affine(DiagnosticAffineWitness)
    case terminalPadding(DiagnosticTerminalPaddingWitness)

    private enum CodingKeys: String, CodingKey {
        case kind
        case holderCapacity
        case anchors
        case transform
        case thresholds
        case meanAbsoluteResidualRows
        case maximumResidualRows
        case recordCount
        case byteCount
        case parity
        case housekeepingByteCount
        case nonzeroRgbCount
        case mismatchLocation
    }

    private enum Kind: String, Codable {
        case affine
        case terminalPadding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .affine:
            self = .affine(DiagnosticAffineWitness(
                holderCapacity: try container.decode(
                    Int.self,
                    forKey: .holderCapacity
                ),
                anchors: try container.decode(
                    [DiagnosticAffineAnchor].self,
                    forKey: .anchors
                ),
                transform: try container.decode(
                    DiagnosticAffineTransform.self,
                    forKey: .transform
                ),
                thresholds: try container.decode(
                    DiagnosticAffineThresholds.self,
                    forKey: .thresholds
                ),
                meanAbsoluteResidualRows: try container.decode(
                    Double.self,
                    forKey: .meanAbsoluteResidualRows
                ),
                maximumResidualRows: try container.decode(
                    Double.self,
                    forKey: .maximumResidualRows
                )
            ))
        case .terminalPadding:
            self = .terminalPadding(DiagnosticTerminalPaddingWitness(
                recordCount: try container.decode(Int.self, forKey: .recordCount),
                byteCount: try container.decode(Int.self, forKey: .byteCount),
                parity: try container.decode(String.self, forKey: .parity),
                housekeepingByteCount: try container.decode(
                    Int.self,
                    forKey: .housekeepingByteCount
                ),
                nonzeroRgbCount: try container.decode(
                    Int.self,
                    forKey: .nonzeroRgbCount
                ),
                mismatchLocation: try container.decode(
                    DiagnosticMismatchLocation.self,
                    forKey: .mismatchLocation
                )
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .affine(let witness):
            try container.encode(Kind.affine, forKey: .kind)
            try container.encode(
                witness.holderCapacity,
                forKey: .holderCapacity
            )
            try container.encode(witness.anchors, forKey: .anchors)
            try container.encode(witness.transform, forKey: .transform)
            try container.encode(witness.thresholds, forKey: .thresholds)
            try container.encode(
                witness.meanAbsoluteResidualRows,
                forKey: .meanAbsoluteResidualRows
            )
            try container.encode(
                witness.maximumResidualRows,
                forKey: .maximumResidualRows
            )
        case .terminalPadding(let witness):
            try container.encode(Kind.terminalPadding, forKey: .kind)
            try container.encode(witness.recordCount, forKey: .recordCount)
            try container.encode(witness.byteCount, forKey: .byteCount)
            try container.encode(witness.parity, forKey: .parity)
            try container.encode(
                witness.housekeepingByteCount,
                forKey: .housekeepingByteCount
            )
            try container.encode(
                witness.nonzeroRgbCount,
                forKey: .nonzeroRgbCount
            )
            try container.encode(
                witness.mismatchLocation,
                forKey: .mismatchLocation
            )
        }
    }
}

public enum DiagnosticEvidenceDecision: Equatable, Sendable {
    case affineResidualExceeded
    case terminalPaddingMismatch
}

public enum DiagnosticEvidenceValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case operationMismatch(expected: String, actual: String)
    case invalidField(String)
    case limitExceeded(String)
    case decisionNotReproduced
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "unsupported diagnostic evidence schema \(version)"
        case .operationMismatch:
            return "diagnostic evidence belongs to a different operation"
        case .invalidField(let field):
            return "diagnostic evidence contains an invalid \(field)"
        case .limitExceeded(let limit):
            return "diagnostic evidence exceeds the \(limit) limit"
        case .decisionNotReproduced:
            return "diagnostic evidence does not reproduce a terminal refusal"
        case .encodingFailed:
            return "diagnostic evidence could not be encoded safely"
        }
    }
}

public enum DiagnosticEvidenceValidator {
    public static let schemaVersion = 1
    public static let maximumEncodedBytes = 16 * 1_024
    public static let maximumAnchors = 40
    public static let maximumStringBytes = 128

    @discardableResult
    public static func validate(
        _ artifact: DiagnosticEvidenceArtifact,
        expectedOperationId: String? = nil
    ) throws -> DiagnosticEvidenceDecision {
        guard artifact.schemaVersion == schemaVersion else {
            throw DiagnosticEvidenceValidationError.unsupportedSchema(
                artifact.schemaVersion
            )
        }
        if let expectedOperationId,
           artifact.operationId != expectedOperationId {
            throw DiagnosticEvidenceValidationError.operationMismatch(
                expected: expectedOperationId,
                actual: artifact.operationId
            )
        }

        try validateBoundedString(artifact.evidenceId, field: "evidenceId")
        try validateBoundedString(artifact.operationId, field: "operationId")
        guard artifact.sessionEpoch.range(
            of: "^[1-9][0-9]*$",
            options: .regularExpression
        ) != nil else {
            throw DiagnosticEvidenceValidationError.invalidField("sessionEpoch")
        }
        try validateBoundedString(artifact.appBuild, field: "appBuild")
        try validateBoundedString(artifact.engineBuild, field: "engineBuild")
        try validateBoundedString(artifact.bridgeBuild, field: "bridgeBuild")
        guard artifact.operationKind == "preview"
                || artifact.operationKind == "scanBinding" else {
            throw DiagnosticEvidenceValidationError.invalidField("operationKind")
        }
        try validateBoundedString(artifact.device.model, field: "device.model")
        try validateBoundedString(artifact.device.adapter, field: "device.adapter")
        let holderCapacity: Int
        switch artifact.device.holder {
        case "mounted": holderCapacity = 1
        case "strip6": holderCapacity = 6
        case "roll36": holderCapacity = 40
        default:
            throw DiagnosticEvidenceValidationError.invalidField("device.holder")
        }

        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoded = try encoder.encode(artifact)
        } catch {
            throw DiagnosticEvidenceValidationError.encodingFailed
        }
        guard encoded.count <= maximumEncodedBytes else {
            throw DiagnosticEvidenceValidationError.limitExceeded("encoded byte")
        }

        switch artifact.witness {
        case .affine(let witness):
            return try validateAffine(witness, holderCapacity: holderCapacity)
        case .terminalPadding(let witness):
            return try validateTerminalPadding(witness)
        }
    }

    private static func validateAffine(
        _ witness: DiagnosticAffineWitness,
        holderCapacity: Int
    ) throws -> DiagnosticEvidenceDecision {
        guard witness.holderCapacity == holderCapacity,
              witness.anchors.count >= 3,
              witness.anchors.count <= holderCapacity else {
            throw DiagnosticEvidenceValidationError.limitExceeded("anchor count")
        }
        var ordinals = Set<Int>()
        for anchor in witness.anchors {
            guard (0..<holderCapacity).contains(anchor.ordinal),
                  ordinals.insert(anchor.ordinal).inserted,
                  anchor.inputRow.isFinite,
                  anchor.observedRow.isFinite,
                  anchor.fittedRow.isFinite,
                  anchor.residualRows.isFinite
            else {
                throw DiagnosticEvidenceValidationError.invalidField("affine anchor")
            }
        }
        let finiteValues = [
            witness.transform.slope,
            witness.transform.intercept,
            witness.thresholds.maximumMeanAbsoluteResidualRows,
            witness.thresholds.maximumResidualRows,
            witness.meanAbsoluteResidualRows,
            witness.maximumResidualRows,
        ]
        guard finiteValues.allSatisfy(\.isFinite),
              witness.transform.slope > 0,
              witness.thresholds.maximumMeanAbsoluteResidualRows > 0,
              witness.thresholds.maximumResidualRows > 0,
              witness.meanAbsoluteResidualRows >= 0,
              witness.maximumResidualRows >= 0
        else {
            throw DiagnosticEvidenceValidationError.invalidField("affine metrics")
        }
        let recomputedResiduals = witness.anchors.map {
            (witness.transform.slope * $0.inputRow
                + witness.transform.intercept - $0.observedRow)
                / witness.transform.slope
        }
        guard zip(witness.anchors, recomputedResiduals).allSatisfy({
            approximatelyEqual(
                $0.fittedRow,
                witness.transform.slope * $0.inputRow
                    + witness.transform.intercept
            ) && approximatelyEqual($0.residualRows, $1)
        }) else {
            throw DiagnosticEvidenceValidationError.invalidField(
                "affine anchor residual"
            )
        }
        let recomputedMean = recomputedResiduals
            .map { abs($0) }
            .reduce(0, +) / Double(recomputedResiduals.count)
        let recomputedMaximum = recomputedResiduals
            .map { abs($0) }
            .max() ?? 0
        guard approximatelyEqual(
                witness.meanAbsoluteResidualRows,
                recomputedMean
              ),
              approximatelyEqual(
                witness.maximumResidualRows,
                recomputedMaximum
              )
        else {
            throw DiagnosticEvidenceValidationError.invalidField(
                "affine aggregate residual"
            )
        }
        guard witness.meanAbsoluteResidualRows
                > witness.thresholds.maximumMeanAbsoluteResidualRows
                || witness.maximumResidualRows
                > witness.thresholds.maximumResidualRows
        else {
            throw DiagnosticEvidenceValidationError.decisionNotReproduced
        }
        return .affineResidualExceeded
    }

    private static func validateTerminalPadding(
        _ witness: DiagnosticTerminalPaddingWitness
    ) throws -> DiagnosticEvidenceDecision {
        guard (1...8_192).contains(witness.recordCount),
              (1...(8 * 1_024 * 1_024)).contains(witness.byteCount),
              witness.parity == "even" || witness.parity == "odd",
              (0...witness.byteCount).contains(witness.housekeepingByteCount),
              (0...(witness.recordCount * 96 * 3)).contains(
                witness.nonzeroRgbCount
              ),
              (0..<witness.recordCount).contains(
                witness.mismatchLocation.recordIndex
              ),
              (0..<witness.byteCount).contains(
                witness.mismatchLocation.byteOffset
              )
        else {
            throw DiagnosticEvidenceValidationError.invalidField(
                "terminal-padding metrics"
            )
        }
        return .terminalPaddingMismatch
    }

    private static func approximatelyEqual(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        abs(lhs - rhs) <= 0.01
    }

    private static func validateBoundedString(
        _ value: String,
        field: String
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumStringBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !value.contains("/"),
              !value.contains("\\"),
              value.range(of: "file:", options: .caseInsensitive) == nil
        else {
            throw DiagnosticEvidenceValidationError.invalidField(field)
        }
    }
}

/// Immutable client state for the exact terminal attempt currently offered
/// for export. A reason is kept when evidence was expected but absent or
/// invalid, so the manifest never silently implies that evidence existed.
public struct DiagnosticEvidenceAvailability: Equatable, Sendable {
    public let artifact: DiagnosticEvidenceArtifact?
    public let unavailableReason: String?

    public var evidenceId: String? { artifact?.evidenceId }

    public static func included(
        _ artifact: DiagnosticEvidenceArtifact
    ) -> DiagnosticEvidenceAvailability {
        DiagnosticEvidenceAvailability(
            artifact: artifact,
            unavailableReason: nil
        )
    }

    public static func unavailable(
        reason: String
    ) -> DiagnosticEvidenceAvailability {
        DiagnosticEvidenceAvailability(
            artifact: nil,
            unavailableReason: reason
        )
    }
}
