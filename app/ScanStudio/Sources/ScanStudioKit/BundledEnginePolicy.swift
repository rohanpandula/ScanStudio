import Foundation

/// The engine boundary used by the distributed CLI.
public enum BundledEnginePolicy {
    public struct BundledEngineRefusal: Error, LocalizedError, Equatable, Sendable {
        public let code: String
        public let message: String
        public let guidance: String

        public var errorDescription: String? { message }
    }

    /// Resolves the engine without allowing a bundled CLI to escape its app.
    public static func resolve(
        cliExecutableURL: URL?,
        environment: [String: String],
        engineOverride: String?,
        fileExists: (String) -> Bool,
        resolvingPath: (URL) -> URL = { $0.resolvingSymlinksInPath() },
        locateLoose: () throws -> URL = { try EngineLocator.locate() }
    ) throws -> URL {
        guard let cliExecutableURL else {
            return try refuseLoose(engineOverride: engineOverride, fileExists: fileExists, locateLoose: locateLoose)
        }

        let executable = resolvingPath(cliExecutableURL)
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        let bundled = macOS.lastPathComponent == "MacOS"
            && contents.lastPathComponent == "Contents"
            && app.pathExtension == "app"

        guard bundled else { return try refuseLoose(engineOverride: engineOverride, fileExists: fileExists, locateLoose: locateLoose) }

        let sibling = macOS.appendingPathComponent("scanstudio-engine")
        let resolvedSibling = resolvingPath(sibling)
        let resolvedMacOS = resolvingPath(macOS)
        guard resolvedSibling.lastPathComponent == "scanstudio-engine",
              resolvedSibling.deletingLastPathComponent().path == resolvedMacOS.path else {
            throw BundledEngineRefusal(
                code: "ENGINE_OVERRIDE_REFUSED",
                message: "Refusing bundled engine path outside the app's Contents/MacOS directory.",
                guidance: "Reinstall ScanStudio so Contents/MacOS/scanstudio-engine is a regular bundled file."
            )
        }
        let requested = engineOverride?.isEmpty == false
            ? engineOverride
            : environment["SCANSTUDIO_ENGINE_PATH"]?.isEmpty == false
                ? environment["SCANSTUDIO_ENGINE_PATH"]
                : nil

        if let requested {
            let candidate = resolvingPath(URL(fileURLWithPath: requested))
            guard candidate.path == resolvedSibling.path else {
                throw BundledEngineRefusal(
                    code: "ENGINE_OVERRIDE_REFUSED",
                    message: "Refusing engine '\(requested)' for bundled CLI; only '\(sibling.path)' is permitted.",
                    guidance: "Run the bundled scanstudio-cli with its sibling scanstudio-engine."
                )
            }
        }

        guard fileExists(resolvedSibling.path) else {
            throw BundledEngineRefusal(
                code: "ENGINE_NOT_FOUND",
                message: "Bundled engine not found at '\(sibling.path)'.",
                guidance: "Reinstall ScanStudio so Contents/MacOS/scanstudio-engine is present."
            )
        }
        return sibling
    }

    private static func refuseLoose(
        engineOverride: String?,
        fileExists: (String) -> Bool,
        locateLoose: () throws -> URL
    ) throws -> URL {
        if let engineOverride, !engineOverride.isEmpty {
            let url = URL(fileURLWithPath: engineOverride)
            guard fileExists(url.path) else {
                throw BundledEngineRefusal(code: "ENGINE_NOT_FOUND", message: "Engine override not found at '\(engineOverride)'.", guidance: "Choose an executable engine path and retry.")
            }
            return url
        }
        do {
            return try locateLoose()
        } catch {
            throw BundledEngineRefusal(
                code: "ENGINE_NOT_BUNDLED",
                message: "scanstudio-cli is not running from a ScanStudio.app bundle.",
                guidance: "Run it in place inside the bundle, or put it on PATH with scripts/install_cli_shim.sh; copying or symlinking the Mach-O out of the bundle is unsupported."
            )
        }
    }
}
