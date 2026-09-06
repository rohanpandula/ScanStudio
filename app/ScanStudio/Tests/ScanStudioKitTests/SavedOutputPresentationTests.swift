import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Receipt-backed saved output presentation")
struct SavedOutputPresentationTests {
    @Test("Only explicit written paths become file actions")
    func writtenFiles() {
        let files = SavedOutputPresentation.files(in: WrittenOutputs(
            archivePath: "/roll/master 01.tiff",
            positivePath: "/roll/positive.tiff",
            previewPath: "/roll/export.jpg",
            rawNegativePath: "/roll/negative.dng",
            rawNegativeIrPath: "/roll/infrared.tiff"
        ))
        #expect(files.map(\.label) == [
            "Master capture", "Raw negative export", "Infrared export",
            "Processed positive", "Processed preview export",
        ])
        #expect(files.map(\.url.path) == [
            "/roll/master 01.tiff", "/roll/negative.dng", "/roll/infrared.tiff",
            "/roll/positive.tiff", "/roll/export.jpg",
        ])
        #expect(files.allSatisfy { $0.url.isFileURL })
        #expect(SavedOutputPresentation.files(in: nil).isEmpty)
    }

    @Test("Missing, relative, and URL-shaped paths are not guessed")
    func invalidPaths() {
        #expect(SavedOutputPresentation.files(in: WrittenOutputs(
            archivePath: nil,
            positivePath: "Positive/frame.tiff",
            previewPath: "https://example.com/export.jpg",
            rawNegativePath: "",
            rawNegativeIrPath: "/roll/invalid\0.tiff"
        )).isEmpty)
    }
}
