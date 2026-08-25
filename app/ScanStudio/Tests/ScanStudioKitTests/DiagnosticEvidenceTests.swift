import Foundation
import Testing

@testable import ScanStudioKit

private func evidenceFixture(_ name: String) throws -> DiagnosticEvidenceArtifact {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures/diagnostic-evidence-v1")
        .appendingPathComponent("\(name).json")
    return try JSONDecoder().decode(
        DiagnosticEvidenceArtifact.self,
        from: Data(contentsOf: url)
    )
}

private func readEvidenceZipEntries(_ data: Data) -> [(name: String, data: Data)] {
    var entries: [(name: String, data: Data)] = []
    var offset = data.startIndex
    func readUInt16LE(_ at: Data.Index) -> UInt16 {
        UInt16(data[at]) | (UInt16(data[at + 1]) << 8)
    }
    func readUInt32LE(_ at: Data.Index) -> UInt32 {
        UInt32(data[at]) | (UInt32(data[at + 1]) << 8)
            | (UInt32(data[at + 2]) << 16) | (UInt32(data[at + 3]) << 24)
    }
    while offset + 30 <= data.endIndex,
          readUInt32LE(offset) == 0x0403_4b50 {
        let size = Int(readUInt32LE(offset + 18))
        let nameLength = Int(readUInt16LE(offset + 26))
        let extraLength = Int(readUInt16LE(offset + 28))
        let nameStart = offset + 30
        let nameEnd = nameStart + nameLength
        let dataStart = nameEnd + extraLength
        let dataEnd = dataStart + size
        entries.append((
            name: String(decoding: data[nameStart..<nameEnd], as: UTF8.self),
            data: Data(data[dataStart..<dataEnd])
        ))
        offset = dataEnd
    }
    return entries
}

@Suite("Bounded diagnostic evidence")
struct DiagnosticEvidenceTests {
    @Test("#42 and #68 affine fixtures reproduce the fail-closed classifier decision offline")
    func affineFixturesReproduceDecision() throws {
        for fixture in ["evidence-42-affine", "evidence-68-affine"] {
            let artifact = try evidenceFixture(fixture)
            #expect(
                try DiagnosticEvidenceValidator.validate(
                    artifact,
                    expectedOperationId: artifact.operationId
                ) == .affineResidualExceeded
            )
        }
    }

    @Test("#43 terminal-padding fixture reproduces its structural mismatch offline")
    func terminalPaddingFixtureReproducesDecision() throws {
        let artifact = try evidenceFixture("evidence-43-terminal-padding")
        #expect(
            try DiagnosticEvidenceValidator.validate(
                artifact,
                expectedOperationId: "preview-43"
            ) == .terminalPaddingMismatch
        )
    }

    @Test("wire errors carry the immutable evidence object and unavailable reason additively")
    func terminalErrorDecodesEvidence() throws {
        let artifactData = try JSONEncoder().encode(
            evidenceFixture("evidence-42-affine")
        )
        let artifactObject = try #require(
            JSONSerialization.jsonObject(with: artifactData) as? [String: Any]
        )
        let envelopeObject: [String: Any] = [
            "code": "REFEED_REQUIRED",
            "message": "typed preview refusal",
            "recoverable": false,
            "diagnosticEvidence": artifactObject,
            "diagnosticEvidenceUnavailableReason": NSNull(),
        ]
        let payload = try JSONDecoder().decode(
            ErrorPayload.self,
            from: JSONSerialization.data(withJSONObject: envelopeObject)
        )

        #expect(payload.diagnosticEvidence?.evidenceId == "evidence-42-affine")
        #expect(payload.diagnosticEvidence?.operationId == "preview-42")
        #expect(payload.diagnosticEvidenceUnavailableReason == nil)
    }

    @Test("operation mismatch, excess anchors, and excess bytes fail closed before export")
    func hardBoundsFailClosed() throws {
        let fixture = try evidenceFixture("evidence-42-affine")
        #expect(throws: DiagnosticEvidenceValidationError.self) {
            try DiagnosticEvidenceValidator.validate(
                fixture,
                expectedOperationId: "another-preview"
            )
        }

        let oversizedAnchors = (0...DiagnosticEvidenceValidator.maximumAnchors).map {
            DiagnosticAffineAnchor(
                ordinal: $0,
                inputRow: Double($0),
                observedRow: Double($0),
                fittedRow: Double($0),
                residualRows: 0
            )
        }
        let oversized = DiagnosticEvidenceArtifact(
            schemaVersion: 1,
            evidenceId: "too-many-anchors",
            operationId: "preview-oversized",
            sessionEpoch: "session-oversized",
            operationKind: "preview",
            appBuild: "test",
            engineBuild: "test",
            bridgeBuild: "test",
            device: .init(model: "LS-5000", adapter: "SA-30", holder: "roll36"),
            witness: .affine(.init(
                anchors: oversizedAnchors,
                transform: .init(slope: 1, intercept: 0),
                thresholds: .init(
                    maximumMeanAbsoluteResidualRows: 0.5,
                    maximumResidualRows: 3
                ),
                meanAbsoluteResidualRows: 0,
                maximumResidualRows: 0
            ))
        )
        #expect(throws: DiagnosticEvidenceValidationError.self) {
            try DiagnosticEvidenceValidator.validate(
                oversized,
                expectedOperationId: oversized.operationId
            )
        }

        guard case .affine(let validWitness) = fixture.witness else {
            Issue.record("expected affine fixture")
            return
        }
        let inconsistent = DiagnosticEvidenceArtifact(
            schemaVersion: fixture.schemaVersion,
            evidenceId: fixture.evidenceId,
            operationId: fixture.operationId,
            sessionEpoch: fixture.sessionEpoch,
            operationKind: fixture.operationKind,
            appBuild: fixture.appBuild,
            engineBuild: fixture.engineBuild,
            bridgeBuild: fixture.bridgeBuild,
            device: fixture.device,
            witness: .affine(.init(
                anchors: validWitness.anchors,
                transform: validWitness.transform,
                thresholds: validWitness.thresholds,
                meanAbsoluteResidualRows: 99,
                maximumResidualRows: validWitness.maximumResidualRows
            ))
        )
        #expect(throws: DiagnosticEvidenceValidationError.self) {
            try DiagnosticEvidenceValidator.validate(
                inconsistent,
                expectedOperationId: inconsistent.operationId
            )
        }
    }

    @Test("a valid witness is exported under a fixed name with explicit manifest disclosure")
    func bundleIncludesValidatedWitness() throws {
        let artifact = try evidenceFixture("evidence-43-terminal-padding")
        let entries = DiagnosticBundleBuilder.makeEntries(
            diagnosticsJSONL: Data(),
            reportText: "REFEED_REQUIRED: terminal padding mismatch",
            redactionContext: .init(),
            preview: .excludedByPrivacyDefault(candidate: nil),
            evidence: .included(artifact)
        )
        let zipEntries = readEvidenceZipEntries(StoredZipWriter.write(entries))

        #expect(Set(zipEntries.map(\.name)) == [
            "diagnostics.jsonl",
            "evidence-v1.json",
            "manifest.txt",
            "report.txt",
        ])
        let evidence = try #require(zipEntries.first { $0.name == "evidence-v1.json" })
        let decoded = try JSONDecoder().decode(
            DiagnosticEvidenceArtifact.self,
            from: evidence.data
        )
        #expect(decoded == artifact)
        let manifest = String(decoding: try #require(
            zipEntries.first { $0.name == "manifest.txt" }
        ).data, as: UTF8.self)
        #expect(manifest.contains("bounded evidence: included evidence-43-terminal-padding"))
        #expect(manifest.contains("film preview: excluded by privacy default"))
    }

    @Test("a structurally valid witness containing known private context is rejected at the share boundary")
    func privateEvidenceStringIsNotExported() throws {
        let fixture = try evidenceFixture("evidence-43-terminal-padding")
        let privateIdentifier = "private-scanner-serial-4815"
        let artifact = DiagnosticEvidenceArtifact(
            schemaVersion: fixture.schemaVersion,
            evidenceId: fixture.evidenceId,
            operationId: fixture.operationId,
            sessionEpoch: fixture.sessionEpoch,
            operationKind: fixture.operationKind,
            appBuild: fixture.appBuild,
            engineBuild: fixture.engineBuild,
            bridgeBuild: fixture.bridgeBuild,
            device: .init(
                model: privateIdentifier,
                adapter: fixture.device.adapter,
                holder: fixture.device.holder
            ),
            witness: fixture.witness
        )
        let entries = DiagnosticBundleBuilder.makeEntries(
            diagnosticsJSONL: Data(),
            reportText: "terminal refusal",
            redactionContext: .init(
                deviceIdentifiers: [privateIdentifier]
            ),
            preview: .excludedByPrivacyDefault(candidate: nil),
            evidence: .included(artifact)
        )

        #expect(!entries.contains { $0.name == "evidence-v1.json" })
        for entry in entries {
            #expect(!String(decoding: entry.data, as: UTF8.self).contains(
                privateIdentifier
            ))
        }
    }
}

private enum EvidenceExportStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

private actor EvidenceExportEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "evidence-export-stub"
    private var requestCount = 0
    private let device = DeviceInfo(
        deviceId: "real-evidence-export",
        model: "SUPER COOLSCAN 5000 ED",
        kind: "real",
        firmware: "test",
        connection: "USB",
        supported: true,
        supportedMultisamplePasses: [4]
    )

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        requestCount += 1
        let value: any Sendable
        switch method {
        case "scanner.list":
            value = ScannerListResult(devices: [device])
        case "scanner.connect":
            value = ConnectResult(
                device: device,
                status: ScannerStatus(
                    connected: true,
                    adapter: "SA-30",
                    mediaLoaded: false,
                    carrier: nil,
                    frameCount: nil,
                    lamp: "stable",
                    transport: "idle",
                    activeJobId: nil,
                    filmPresent: true,
                    motionArmed: true
                )
            )
        case "scanner.acquireThumbnails":
            value = AcquireThumbnailsAck(accepted: true, frames: [1])
        default:
            throw EvidenceExportStubError.unexpectedMethod(method)
        }
        guard let result = value as? Result else {
            throw EvidenceExportStubError.unexpectedResultType
        }
        return result
    }

    func requests() -> Int { requestCount }
}

@Suite("Diagnostic evidence export integration")
struct DiagnosticEvidenceExportIntegrationTests {
    @Test("export uses the exact failed-attempt witness already in memory and performs no engine request")
    @MainActor
    func exportIsNonMotionAndNonRequesting() async throws {
        let client = EvidenceExportEngineStub()
        let model = SessionModel(engineClient: client)
        await model.connect(deviceId: "real-evidence-export")
        let token = PreviewIntentToken()
        _ = await model.requestPreview(.initial(token: token))

        let artifactData = try JSONEncoder().encode(
            evidenceFixture("evidence-42-affine")
        )
        var artifactObject = try #require(
            JSONSerialization.jsonObject(with: artifactData) as? [String: Any]
        )
        artifactObject["operationId"] = token.id.uuidString
        let evidenceEvent: [String: Any] = [
            "event": "diagnostic.evidence",
            "payload": artifactObject,
        ]
        model.handle(event: EngineEvent(
            name: "diagnostic.evidence",
            rawLine: try JSONSerialization.data(withJSONObject: evidenceEvent)
        ))
        let eventObject: [String: Any] = [
            "event": "scanner.thumbnailsFailed",
            "payload": [
                "operationId": token.id.uuidString,
                "code": "REFEED_REQUIRED",
                "message": "typed affine refusal",
                "evidence": [
                    "schemaVersion": artifactObject["schemaVersion"]!,
                    "evidenceId": artifactObject["evidenceId"]!,
                    "operationId": token.id.uuidString,
                    "sessionEpoch": artifactObject["sessionEpoch"]!,
                ],
            ],
        ]
        model.handle(event: EngineEvent(
            name: "scanner.thumbnailsFailed",
            rawLine: try JSONSerialization.data(withJSONObject: eventObject)
        ))
        let before = await client.requests()

        let zip = model.makeDiagnosticBundleData()
        let after = await client.requests()

        #expect(after == before)
        #expect(model.diagnosticEvidenceAvailability?.evidenceId == "evidence-42-affine")
        #expect(readEvidenceZipEntries(zip).contains { $0.name == "evidence-v1.json" })
    }
}
