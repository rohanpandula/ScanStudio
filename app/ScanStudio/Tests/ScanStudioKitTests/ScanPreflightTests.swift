import Foundation
import Testing
@testable import ScanStudioKit

@Suite("Observational scan preflight")
struct ScanPreflightTests {
    @Test("metadata destinations stay project-bound while raw export may be external")
    func metadataDestinationParity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preflight-root-\(UUID().uuidString)")
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("preflight-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let status = ControlStatusResult(
            device: DeviceInfo(
                deviceId: "sim-ls5000-0", model: "LS-5000", kind: "simulated",
                firmware: "test", connection: "simulator", supported: true
            ),
            scanner: ScannerStatus(
                connected: true, adapter: "sim", mediaLoaded: true, carrier: "mounted",
                frameCount: 1, lamp: "ready", transport: "idle", activeJobId: nil,
                filmPresent: nil, motionArmed: true
            ),
            projectDirectory: root.path,
            previewComplete: true,
            refeedRequired: false,
            hardwareMotionReadiness: "notApplicable",
            motionAllowed: true,
            selectedFrames: [1],
            scanReadiness: "ready"
        )
        let capture = CaptureRecipe(
            resolutionDpi: 4000, bitDepth: 16, multisamplePasses: 1, channels: "rgbi"
        )
        let output = OutputRecipe(
            archive: ArchiveRecipe(filenameTemplate: "Archive#", destination: external.appendingPathComponent("archive").path),
            rawExport: RawExportRecipe(
                enabled: true, fileFormat: .linearTiff, tiffInfrared: .sidecar,
                filenameTemplate: "Raw#", destination: external.appendingPathComponent("raw").path
            ),
            positive: PositiveRecipe(enabled: false, fileFormat: .tiff, colorProfile: .adobeRgb1998, filenameTemplate: "Positive#", destination: ""),
            preview: PreviewRecipe(enabled: false, fileFormat: .jpeg, maxLongEdgePx: 1_024, filenameTemplate: "Preview#", destination: "")
        )
        let outside = ScanPreflightReport.evaluate(
            status: status, frames: [1], readiness: .ready, capture: capture, outputs: output
        )
        #expect(!outside.ready)
        #expect(outside.checks.contains { $0.code == "DESTINATION_WITHIN_PROJECT" && !$0.passed })

        let insideOutput = OutputRecipe(
            archive: ArchiveRecipe(filenameTemplate: "Archive#", destination: root.appendingPathComponent("archive").path),
            rawExport: output.rawExport,
            positive: output.positive,
            preview: output.preview
        )
        let inside = ScanPreflightReport.evaluate(
            status: status, frames: [1], readiness: .ready, capture: capture, outputs: insideOutput
        )
        #expect(inside.ready)
        #expect(!inside.checks.contains { $0.code == "DESTINATION_WITHIN_PROJECT" && !$0.passed })
    }

    @Test("missing film and unwritable destinations refuse without creating output")
    func gatesAndNoMutation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("file")
        try Data("unchanged".utf8).write(to: blocked)
        let status = ControlStatusResult(
            projectDirectory: directory.path, previewComplete: false,
            refeedRequired: true, hardwareMotionReadiness: "unknown", motionAllowed: false,
            selectedFrames: [1], scanReadiness: "hardwareMotionNotReady"
        )
        let output = OutputRecipe(
            archive: ArchiveRecipe(filenameTemplate: "Archive#", destination: blocked.appendingPathComponent("child").path),
            positive: PositiveRecipe(enabled: false, fileFormat: .tiff, colorProfile: .adobeRgb1998, filenameTemplate: "Positive#", destination: ""),
            preview: PreviewRecipe(enabled: false, fileFormat: .jpeg, maxLongEdgePx: 2048, filenameTemplate: "Preview#", destination: "")
        )
        let report = ScanPreflightReport.evaluate(
            status: status, frames: [1], readiness: .hardwareMotionNotReady,
            capture: CaptureRecipe(resolutionDpi: 4000, bitDepth: 16, multisamplePasses: 1, channels: "rgbi"), outputs: output
        )
        #expect(!report.ready)
        let failures = Set(report.checks.filter { !$0.passed }.map(\.code))
        #expect(failures.isSuperset(of: ["FILM_REQUIRED", "REGISTRATION_REQUIRED", "MOTION_NOT_READY", "DESTINATION_NOT_WRITABLE"]))
        #expect(try Data(contentsOf: blocked) == Data("unchanged".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["file"])
    }
}
