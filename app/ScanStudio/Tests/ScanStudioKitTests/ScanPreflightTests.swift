import Foundation
import Testing
@testable import ScanStudioKit

@Suite("Observational scan preflight")
struct ScanPreflightTests {
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
