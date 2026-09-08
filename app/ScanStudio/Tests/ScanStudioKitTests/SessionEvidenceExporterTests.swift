import CryptoKit
import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Session evidence exporter")
struct SessionEvidenceExporterTests {
    @Test("exports stable held sources and rejects changed or linked input")
    func stableExportAndRefusals() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let diagnostics = root.appendingPathComponent("diagnostics.jsonl")
        let telemetry = root.appendingPathComponent("telemetry.ndjson")
        let diagnosticsBytes = Data((#"{"event":"session.started"}"# + "\n").utf8)
        let telemetryBytes = Data((#"{"event":"bridge.open"}"# + "\n").utf8)
        try diagnosticsBytes.write(to: diagnostics)
        try telemetryBytes.write(to: telemetry)
        let transcriptBytes = Data((#"{"direction":"request"}"# + "\n").utf8)
        let transcript = ControlSessionTranscriptSnapshot(
            path: root.appendingPathComponent("active.ndjson").path,
            data: transcriptBytes,
            byteCount: transcriptBytes.count
        )
        let inventory: [SessionEvidenceInventoryEntry] = [
            .init(
                entryName: "diagnostics.jsonl",
                sourceKind: "appDiagnostics",
                source: .file(diagnostics, allowedRoot: root)
            ),
            .init(
                entryName: "telemetry.ndjson",
                sourceKind: "bridgeTelemetry",
                source: .file(telemetry, allowedRoot: root)
            ),
            .init(
                entryName: "attempt-journals",
                sourceKind: "attemptJournals",
                source: .missing(reason: "no receipt-bound attempts were recorded")
            ),
        ]
        let wireInventory = ControlSessionInventoryResult(
            diagnosticSessionId: "diagnostic-test",
            entries: [
                .init(
                    entryName: "telemetry.ndjson",
                    sourceKind: "bridgeTelemetry",
                    path: telemetry.path,
                    allowedRoot: root.path,
                    expectedSha256: sha256(telemetryBytes)
                ),
                .init(
                    entryName: "attempt-journals",
                    sourceKind: "attemptJournals",
                    missingReason: "no receipt-bound attempts were recorded"
                ),
            ]
        )
        let converted = try wireInventory.exportEntries()
        #expect(try SessionEvidenceExporter.verifiedSnapshot(of: converted[0]) == telemetryBytes)
        #expect(try SessionEvidenceExporter.verifiedSnapshot(of: converted[1]) == nil)
        #expect(throws: SessionEvidenceExportError.self) {
            _ = try SessionEvidenceExporter.verifiedSnapshot(of: .init(
                entryName: "wrong-hash.ndjson",
                sourceKind: "bridgeTelemetry",
                source: .file(telemetry, allowedRoot: root),
                expectedSha256: String(repeating: "0", count: 64)
            ))
        }
        #expect(throws: SessionEvidenceExportError.self) {
            _ = try ControlSessionInventoryResult(
                diagnosticSessionId: "diagnostic-test",
                entries: [.init(
                    entryName: "ambiguous",
                    sourceKind: "bridgeTelemetry",
                    path: telemetry.path,
                    missingReason: "both present and missing"
                )]
            ).exportEntries()
        }
        let destination = root.appendingPathComponent("session.zip")

        let result = try SessionEvidenceExporter.export(
            inventory: inventory,
            transcript: transcript,
            to: destination
        )
        #expect(result.path == destination.path)
        #expect(result.includedEntryCount == 3)
        #expect(result.missingEntryCount == 1)
        #expect(try Data(contentsOf: diagnostics) == diagnosticsBytes)
        #expect(try Data(contentsOf: telemetry) == telemetryBytes)

        let entries = Dictionary(uniqueKeysWithValues: try readStoredEntries(
            Data(contentsOf: destination)
        ))
        #expect(Set(entries.keys) == [
            "control-transcript.ndjson", "diagnostics.jsonl", "manifest.json", "telemetry.ndjson",
        ])
        #expect(entries["diagnostics.jsonl"] == diagnosticsBytes)
        #expect(entries["telemetry.ndjson"] == telemetryBytes)
        #expect(entries["control-transcript.ndjson"] == transcriptBytes)
        let manifest = try JSONDecoder().decode(
            TestManifest.self,
            from: try #require(entries["manifest.json"])
        )
        #expect(manifest.entries.map(\.entryName) == manifest.entries.map(\.entryName).sorted())
        let diagnosticsManifest = try #require(
            manifest.entries.first { $0.entryName == "diagnostics.jsonl" }
        )
        #expect(diagnosticsManifest.byteLength == diagnosticsBytes.count)
        #expect(diagnosticsManifest.sha256 == sha256(diagnosticsBytes))
        let missing = try #require(
            manifest.entries.first { $0.entryName == "attempt-journals" }
        )
        #expect(missing.byteLength == nil)
        #expect(missing.sha256 == nil)
        #expect(missing.missingReason == "no receipt-bound attempts were recorded")

        #expect(throws: DiagnosticBundleSaveError.self) {
            _ = try SessionEvidenceExporter.export(
                inventory: inventory,
                transcript: transcript,
                to: destination
            )
        }

        let changing = root.appendingPathComponent("changing.ndjson")
        try Data("original".utf8).write(to: changing)
        #expect(throws: SessionEvidenceExportError.self) {
            _ = try SessionEvidenceExporter.export(
                inventory: [.init(
                    entryName: "changing.ndjson",
                    sourceKind: "appDiagnostics",
                    source: .file(changing, allowedRoot: root)
                )],
                transcript: nil,
                to: root.appendingPathComponent("changed.zip"),
                sourceDidRead: { source in
                    try Data("replaced".utf8).write(to: source, options: .atomic)
                }
            )
        }

        let authorityRoot = root.appendingPathComponent("authority", isDirectory: true)
        let displacedAuthorityRoot = root.appendingPathComponent("authority-displaced", isDirectory: true)
        try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: false)
        let authoritySource = authorityRoot.appendingPathComponent("diagnostics.jsonl")
        try diagnosticsBytes.write(to: authoritySource)
        #expect(throws: SessionEvidenceExportError.self) {
            _ = try SessionEvidenceExporter.export(
                inventory: [.init(
                    entryName: "authority-diagnostics.jsonl",
                    sourceKind: "appDiagnostics",
                    source: .file(authoritySource, allowedRoot: authorityRoot)
                )],
                transcript: nil,
                to: root.appendingPathComponent("authority-swapped.zip"),
                sourceDidRead: { _ in
                    try FileManager.default.moveItem(at: authorityRoot, to: displacedAuthorityRoot)
                    try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: false)
                    try Data("substituted\n".utf8).write(to: authoritySource)
                }
            )
        }

        let linked = root.appendingPathComponent("linked.ndjson")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: diagnostics)
        #expect(throws: SessionEvidenceExportError.self) {
            _ = try SessionEvidenceExporter.export(
                inventory: [.init(
                    entryName: "linked.ndjson",
                    sourceKind: "appDiagnostics",
                    source: .file(linked, allowedRoot: root)
                )],
                transcript: nil,
                to: root.appendingPathComponent("linked.zip")
            )
        }
        #expect(throws: SessionEvidenceExportError.self) {
            _ = try SessionEvidenceExporter.export(
                inventory: [.init(
                    entryName: #"..\escape.ndjson"#,
                    sourceKind: "appDiagnostics",
                    source: .file(diagnostics, allowedRoot: root)
                )],
                transcript: nil,
                to: root.appendingPathComponent("unsafe-name.zip")
            )
        }
    }

    private struct TestManifest: Decodable {
        let entries: [TestManifestEntry]
    }

    private struct TestManifestEntry: Decodable {
        let entryName: String
        let sourceKind: String
        let byteLength: Int?
        let sha256: String?
        let missingReason: String?
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func readStoredEntries(_ data: Data) throws -> [(String, Data)] {
        var entries: [(String, Data)] = []
        var offset = data.startIndex
        func u16(_ index: Data.Index) -> UInt16 {
            UInt16(data[index]) | UInt16(data[index + 1]) << 8
        }
        func u32(_ index: Data.Index) -> UInt32 {
            UInt32(data[index]) | UInt32(data[index + 1]) << 8
                | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
        }
        while offset + 30 <= data.endIndex, u32(offset) == 0x0403_4b50 {
            let size = Int(u32(offset + 18))
            let nameLength = Int(u16(offset + 26))
            let extraLength = Int(u16(offset + 28))
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            let payloadStart = nameEnd + extraLength
            let payloadEnd = payloadStart + size
            guard payloadEnd <= data.endIndex else { throw CocoaError(.fileReadCorruptFile) }
            entries.append((
                String(decoding: data[nameStart..<nameEnd], as: UTF8.self),
                Data(data[payloadStart..<payloadEnd])
            ))
            offset = payloadEnd
        }
        return entries
    }
}
