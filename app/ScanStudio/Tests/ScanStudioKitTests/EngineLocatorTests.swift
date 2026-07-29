import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Engine locator")
struct EngineLocatorTests {
    private let sourceFile = "/checkout/ScanStudio/Sources/ScanStudioKit/EngineLocator.swift"
    private let executable = URL(fileURLWithPath: "/Applications/ScanStudio.app/Contents/MacOS/ScanStudioLauncher")

    @Test("packaged app prefers its embedded engine over source-tree builds")
    func embeddedEngineWins() throws {
        let existing = Set([
            "/Applications/ScanStudio.app/Contents/MacOS/scanstudio-engine",
            "/checkout/ScanStudio/engine/target/release/scanstudio-engine",
        ])

        let result = try EngineLocator.locate(
            environment: [:],
            bundleExecutableURL: executable,
            fileExists: { existing.contains($0) },
            sourceFilePath: sourceFile
        )

        #expect(result.path == "/Applications/ScanStudio.app/Contents/MacOS/scanstudio-engine")
    }

    @Test("explicit environment override still wins")
    func environmentOverrideWins() throws {
        let result = try EngineLocator.locate(
            environment: ["SCANSTUDIO_ENGINE_PATH": "/custom/scanstudio-engine"],
            bundleExecutableURL: executable,
            fileExists: { $0 == "/custom/scanstudio-engine" },
            sourceFilePath: sourceFile
        )

        #expect(result.path == "/custom/scanstudio-engine")
    }

    @Test("missing override fails closed instead of silently choosing another engine")
    func missingEnvironmentOverrideFailsClosed() {
        #expect(throws: EngineLocator.LocateError.self) {
            try EngineLocator.locate(
                environment: ["SCANSTUDIO_ENGINE_PATH": "/missing/scanstudio-engine"],
                bundleExecutableURL: executable,
                fileExists: { _ in false },
                sourceFilePath: sourceFile
            )
        }
    }

    @Test("empty environment override is treated as unset")
    func emptyEnvironmentOverrideIsUnset() throws {
        let embedded = "/Applications/ScanStudio.app/Contents/MacOS/scanstudio-engine"
        let result = try EngineLocator.locate(
            environment: ["SCANSTUDIO_ENGINE_PATH": ""],
            bundleExecutableURL: executable,
            fileExists: { $0 == embedded },
            sourceFilePath: sourceFile
        )

        #expect(result.path == embedded)
    }

    @Test("developer release build remains the first unbundled fallback")
    func releaseFallback() throws {
        let release = "/checkout/ScanStudio/engine/target/release/scanstudio-engine"
        let result = try EngineLocator.locate(
            environment: [:],
            bundleExecutableURL: nil,
            fileExists: { $0 == release },
            sourceFilePath: sourceFile
        )

        #expect(result.path == release)
    }

    @Test("developer debug build is used when release is absent")
    func debugFallback() throws {
        let debug = "/checkout/ScanStudio/engine/target/debug/scanstudio-engine"
        let result = try EngineLocator.locate(
            environment: [:],
            bundleExecutableURL: nil,
            fileExists: { $0 == debug },
            sourceFilePath: sourceFile
        )

        #expect(result.path == debug)
    }

    @Test("not-found error names embedded, release, and debug candidates")
    func notFoundErrorNamesCandidates() {
        do {
            _ = try EngineLocator.locate(
                environment: [:],
                bundleExecutableURL: executable,
                fileExists: { _ in false },
                sourceFilePath: sourceFile
            )
            Issue.record("Expected EngineLocator.LocateError")
        } catch let error as EngineLocator.LocateError {
            #expect(error.message.contains("/Applications/ScanStudio.app/Contents/MacOS/scanstudio-engine"))
            #expect(error.message.contains("/checkout/ScanStudio/engine/target/release/scanstudio-engine"))
            #expect(error.message.contains("/checkout/ScanStudio/engine/target/debug/scanstudio-engine"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
