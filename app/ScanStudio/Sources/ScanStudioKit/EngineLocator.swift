// Engine binary discovery (D-05): `SCANSTUDIO_ENGINE_PATH` env var wins;
// otherwise prefer the engine embedded beside the app executable, then use
// source-tree release/debug builds as developer-only fallbacks.

import Foundation

public enum EngineLocator {
    /// Thrown when the engine binary cannot be found anywhere it was
    /// looked for. `errorDescription` is what D-05 requires: a clear,
    /// user-visible message naming exactly which paths were checked.
    public struct LocateError: Error, LocalizedError, Equatable {
        public let message: String

        public var errorDescription: String? { message }
    }

    /// Resolves the `scanstudio-engine` binary's location.
    ///
    /// 1. `SCANSTUDIO_ENGINE_PATH` env var, if set, wins outright (the file
    ///    must exist there or this throws naming that exact path).
    /// 2. In a packaged app, use `scanstudio-engine` embedded beside the main
    ///    executable in `Contents/MacOS`.
    /// 3. Otherwise, derive the package root from the caller-supplied source
    ///    path (this file
    ///    lives at `.../Sources/ScanStudioKit/EngineLocator.swift`; three
    ///    `.deletingLastPathComponent()` calls strip `EngineLocator.swift`,
    ///    `ScanStudioKit`, and `Sources` to land on the package root) and
    ///    check `engine/target/release/scanstudio-engine`, then
    ///    `engine/target/debug/scanstudio-engine`.
    public static func locate() throws -> URL {
        try locate(
            environment: ProcessInfo.processInfo.environment,
            bundleExecutableURL: Bundle.main.executableURL,
            fileExists: FileManager.default.fileExists(atPath:),
            // Source builds normally set SCANSTUDIO_ENGINE_PATH (`make run`)
            // and packaged apps always use their embedded engine. `#fileID`
            // avoids embedding an individual developer's absolute path in a
            // distributable binary; tests inject an absolute source path when
            // they exercise the source-tree fallback explicitly.
            sourceFilePath: #fileID
        )
    }

    /// Injectable resolver used by tests to prove the packaged-app lookup and
    /// fallback order without depending on the test runner's own bundle.
    static func locate(
        environment: [String: String],
        bundleExecutableURL: URL?,
        fileExists: (String) -> Bool,
        sourceFilePath: String
    ) throws -> URL {
        if let envPath = environment["SCANSTUDIO_ENGINE_PATH"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath)
            guard fileExists(url.path) else {
                throw LocateError(
                    message: "SCANSTUDIO_ENGINE_PATH is set to '\(envPath)' but no file exists there."
                )
            }
            return url
        }

        let embeddedURL = bundleExecutableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("scanstudio-engine")
        if let embeddedURL, fileExists(embeddedURL.path) {
            return embeddedURL
        }

        let packageRoot = URL(fileURLWithPath: sourceFilePath)
            .deletingLastPathComponent() // EngineLocator.swift -> ScanStudioKit/
            .deletingLastPathComponent() // ScanStudioKit/ -> Sources/
            .deletingLastPathComponent() // Sources/ -> package root

        let releaseURL = packageRoot
            .appendingPathComponent("engine")
            .appendingPathComponent("target")
            .appendingPathComponent("release")
            .appendingPathComponent("scanstudio-engine")
        let debugURL = packageRoot
            .appendingPathComponent("engine")
            .appendingPathComponent("target")
            .appendingPathComponent("debug")
            .appendingPathComponent("scanstudio-engine")

        if fileExists(releaseURL.path) {
            return releaseURL
        }
        if fileExists(debugURL.path) {
            return debugURL
        }

        let embeddedPath = embeddedURL?.path ?? "(main bundle has no executable URL)"
        throw LocateError(
            message: """
            scanstudio-engine binary not found. Reinstall ScanStudio or set \
            SCANSTUDIO_ENGINE_PATH for development. Looked in: \(embeddedPath), \
            \(releaseURL.path), \(debugURL.path).
            """
        )
    }
}
