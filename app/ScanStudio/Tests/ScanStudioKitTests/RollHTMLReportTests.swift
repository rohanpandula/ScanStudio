import CryptoKit
import Foundation
import Testing

@testable import ScanStudioKit

@Suite("roll HTML reports")
struct RollHTMLReportTests {
    @Test("renders a verified retained preview, escapes text, and refuses tampering")
    func retainedFixtureVerification() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanstudio-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let preview = Data("retained-preview".utf8)
        try preview.write(to: directory.appendingPathComponent("preview.jpg"), options: [.withoutOverwriting])
        let hash = SHA256.hash(data: preview).map { String(format: "%02x", $0) }.joined()
        let binding = WrittenFileBinding(
            relativePath: "preview.jpg", sha256: hash, byteLength: UInt64(preview.count), volumeId: nil, fileId: nil
        )
        // A retained archive can exceed the evidence export snapshot limit;
        // reports must verify its binding by streaming rather than loading it.
        let archive = Data(repeating: 0x5A, count: 64 * 1024 * 1024 + 1)
        try archive.write(to: directory.appendingPathComponent("archive.tiff"), options: [.withoutOverwriting])
        let archiveHash = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let archiveBinding = WrittenFileBinding(
            relativePath: "archive.tiff", sha256: archiveHash, byteLength: UInt64(archive.count), volumeId: nil, fileId: nil
        )
        let receipt = ScanReceipt(
            jobId: "job-1", frameIndex: 1, startedAt: "2026-09-08T00:00:00Z", durationMs: 100,
            passes: 1, resolutionDpi: 4_000, bitDepth: 16, channels: "rgb", engineVersion: "test",
            deviceId: "sim-ls5000-0", simulated: true, settingsFingerprint: "fingerprint",
            processing: nil, output: nil,
            outputs: WrittenOutputs(
                archivePath: "/untrusted/archive.tiff", positivePath: nil, previewPath: "/untrusted/path.jpg",
                metadataBindings: MetadataOutputBindings(archive: archiveBinding, preview: binding)
            ),
            rgbPath: nil, irPath: nil, meterRgbiPath: nil, hardwareTelemetry: nil
        )
        let project = ScanProject(
            schemaVersion: 4, id: "roll-1", name: "Roll <unsafe>", carrier: .strip6,
            frameCount: 1, filmProcess: .c41ColorNegative,
            recipes: OutputRecipe(
                archive: ArchiveRecipe(filenameTemplate: "Archive#", destination: directory.path),
                positive: PositiveRecipe(enabled: false, fileFormat: .tiff, colorProfile: .adobeRgb1998, filenameTemplate: "", destination: ""),
                preview: PreviewRecipe(enabled: true, fileFormat: .jpeg, maxLongEdgePx: 1024, filenameTemplate: "Preview#", destination: directory.path)
            ),
            rollMetadata: MetadataSet(), createdAt: "2026-09-08T00:00:00Z",
            frames: [ProjectFrame(index: 1, excluded: false, receipts: [receipt])]
        )
        try JSONEncoder().encode(project).write(to: directory.appendingPathComponent("manifest.json"), options: [.withoutOverwriting])

        let result = try RollHTMLReport.write(projectDirectory: directory)
        let html = try String(contentsOfFile: result.path, encoding: .utf8)
        #expect(html.contains("Roll &lt;unsafe&gt;"))
        #expect(html.contains("data:image/jpeg;base64,"))
        #expect(html.contains(hash))
        #expect(html.contains(archiveHash))
        #expect(result.embeddedThumbnailCount == 1)

        try Data("tampered".utf8).write(to: directory.appendingPathComponent("preview.jpg"))
        do {
            _ = try RollHTMLReport.render(project: project, projectDirectory: directory)
            Issue.record("expected a changed retained artifact to refuse")
        } catch let error as RollHTMLReportError {
            #expect(error.localizedDescription.contains("changed"))
        }
    }
}
