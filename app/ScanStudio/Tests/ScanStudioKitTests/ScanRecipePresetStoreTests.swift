import Foundation
import Testing
import Darwin

@testable import ScanStudioKit

@Suite("scan recipe presets")
struct ScanRecipePresetStoreTests {
    @Test("presets round-trip, reject escaping names, and refuse tampered JSON")
    func roundTripNameAndTamperChecks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanstudio-presets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanRecipePresetStore(directory: directory)
        #expect(try store.list().isEmpty)
        let preset = ScanRecipePresetDocument(
            name: "nightly",
            capture: CaptureRecipe(resolutionDpi: 4_000, bitDepth: 16, multisamplePasses: 4, channels: "rgbi"),
            processing: ProcessingRecipe(
                filmProcess: .c41ColorNegative,
                autofocusEachFrame: true,
                autoExposureEachFrame: true,
                digitalIceEnabled: true,
                digitalIceMode: .legacy
            ),
            output: OutputRecipe(
                archive: ArchiveRecipe(filenameTemplate: "Archive#", destination: "/tmp/preset-output/archive"),
                rawExport: RawExportRecipe(enabled: false, filenameTemplate: "", destination: ""),
                positive: PositiveRecipe(
                    enabled: true,
                    fileFormat: .tiff,
                    colorProfile: .adobeRgb1998,
                    filenameTemplate: "Positive#",
                    destination: "/tmp/preset-output/positive"
                ),
                preview: PreviewRecipe(
                    enabled: true,
                    fileFormat: .jpeg,
                    maxLongEdgePx: 2_048,
                    filenameTemplate: "Preview#",
                    destination: "/tmp/preset-output/preview"
                )
            )
        )

        try store.save(preset)
        #expect(try store.load(named: "nightly") == preset)
        #expect(try store.list() == ["nightly"])
        let savedJSON = try String(contentsOf: directory.appendingPathComponent("nightly.json"), encoding: .utf8)
        #expect(savedJSON.contains("allowUnverifiedHardware") == false)
        #expect(savedJSON.contains("motionConfirmed") == false)

        let invalidName = ScanRecipePresetDocument(
            name: "../escape",
            capture: preset.capture,
            processing: preset.processing,
            output: preset.output
        )
        do {
            try store.save(invalidName)
            Issue.record("expected an escaping preset name to be refused")
        } catch let error as ScanRecipePresetStoreError {
            #expect(error == .invalidName("../escape"))
        }

        let invalidExposure = ScanRecipePresetDocument(
            name: "invalid-exposure",
            capture: CaptureRecipe(
                resolutionDpi: 4_000,
                bitDepth: 16,
                multisamplePasses: 4,
                channels: "rgbi",
                exposureOverride10ns: [49_999, 200_000, 200_000]
            ),
            processing: preset.processing,
            output: preset.output
        )
        do {
            try store.save(invalidExposure)
            Issue.record("expected an out-of-bounds exposure override to be refused")
        } catch let error as ScanRecipePresetStoreError {
            #expect(error == .invalidRecipe("capture"))
        }

        try Data("{tampered".utf8).write(to: directory.appendingPathComponent("nightly.json"))
        chmod(directory.appendingPathComponent("nightly.json").path, 0o600)
        do {
            _ = try store.load(named: "nightly")
            Issue.record("expected tampered JSON to be refused")
        } catch let error as ScanRecipePresetStoreError {
            #expect(error == .invalidJSON("nightly.json"))
        }
    }
}
