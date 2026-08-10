// Host-owned lifecycle for the optional browser preview. The browser gateway
// is deliberately a second, simulator-only engine session: it never inherits
// the desktop app's hardware bridge or motion authorization. This model owns
// only process/readiness state; the gateway in ports/web remains the protocol
// and security authority.

import Darwin
import Foundation
import Observation

public enum WebServerState: Equatable, Sendable {
    case off
    case starting
    case running
    case stopping
    case failed(String)
}

public struct WebServerRuntime: Equatable, Sendable {
    public let executableURL: URL
    public let staticDirectoryURL: URL
    public let workingDirectoryURL: URL?

    public init(
        executableURL: URL,
        staticDirectoryURL: URL,
        workingDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.staticDirectoryURL = staticDirectoryURL
        self.workingDirectoryURL = workingDirectoryURL
    }
}

public struct WebServerLaunchConfiguration: Equatable, Sendable {
    public let identifier: UUID
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL?

    public init(
        identifier: UUID,
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String],
        workingDirectoryURL: URL? = nil
    ) {
        self.identifier = identifier
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
    }
}

public struct WebServerProcessExit: Equatable, Sendable {
    public let identifier: UUID
    public let status: Int32
    public let reason: Process.TerminationReason

    public init(
        identifier: UUID,
        status: Int32,
        reason: Process.TerminationReason
    ) {
        self.identifier = identifier
        self.status = status
        self.reason = reason
    }
}

/// Injectable process seam. The production actor wraps Foundation.Process;
/// tests use an in-memory actor and never spawn Python, Rust, or a scanner.
public protocol WebServerProcessControlling: Sendable {
    var terminationEvents: AsyncStream<WebServerProcessExit> { get }

    func start(configuration: WebServerLaunchConfiguration) async throws
    /// A non-nil identifier stops only that run; nil stops whichever process
    /// is current. Matching prevents stale startup work from stopping a newer
    /// retry after a rapid toggle sequence.
    func stop(identifier: UUID?) async
}

/// Injectable readiness seam so `running` means the gateway and its simulator
/// engine completed startup, not merely that Process.run() returned.
public protocol WebServerReadinessChecking: Sendable {
    func waitUntilReady(at startupURL: URL, timeout: Duration) async throws
}

public enum WebServerRuntimeLocateError: Error, LocalizedError, Equatable {
    case missingCommandOverride(String)
    case missingStaticDirectoryOverride(String)
    case incompatibleStaticDirectoryOverride(String)
    case runtimeUnavailable(commandPaths: [String], staticPaths: [String])
    case engineUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingCommandOverride(let path):
            return "SCANSTUDIO_WEB_COMMAND_PATH points to a missing executable: \(path)"
        case .missingStaticDirectoryOverride(let path):
            return "SCANSTUDIO_WEB_STATIC_DIR points to a missing directory: \(path)"
        case .incompatibleStaticDirectoryOverride(let path):
            return "SCANSTUDIO_WEB_STATIC_DIR is not a simulator-only web build: \(path). Run npm run build:web so it contains scanstudio-web-runtime.json."
        case .runtimeUnavailable(let commandPaths, let staticPaths):
            return "The browser preview runtime is not installed. Looked for the gateway at \(commandPaths.joined(separator: ", ")) and a simulator-only web build at \(staticPaths.joined(separator: ", ")). For development, run npm run build:web, or set SCANSTUDIO_WEB_COMMAND_PATH and SCANSTUDIO_WEB_STATIC_DIR."
        case .engineUnavailable:
            return "The browser preview cannot start because the Scan Studio engine is unavailable."
        }
    }
}

/// Resolves an eventual packaged runtime first, then the current source-tree
/// development layout. Packaging is intentionally not changed in this slice:
/// a future release may place an executable gateway at
/// `Contents/Resources/WebRuntime/bin/scanstudio-web` and Vite output at
/// `Contents/Resources/WebFrontend` without changing the app-side contract.
public struct WebServerRuntimeLocator: Sendable {
    public static let commandOverrideKey = "SCANSTUDIO_WEB_COMMAND_PATH"
    public static let staticDirectoryOverrideKey = "SCANSTUDIO_WEB_STATIC_DIR"
    static let staticDirectoryMarkerFilename = "scanstudio-web-runtime.json"
    static let staticDirectoryMarkerSchemaVersion = 1
    static let staticDirectoryMarkerRuntime = "simulator-only-web"

    private struct StaticDirectoryMarker: Decodable {
        let schemaVersion: Int
        let runtime: String
    }

    private let environment: [String: String]
    private let bundleResourceURL: URL?
    private let developmentRepositoryURL: URL?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        engineURL: URL?
    ) {
        self.environment = environment
        self.bundleResourceURL = bundleResourceURL
        self.developmentRepositoryURL = Self.inferRepositoryRoot(from: engineURL)
    }

    public func locate() throws -> WebServerRuntime {
        try Self.locate(
            environment: environment,
            bundleResourceURL: bundleResourceURL,
            developmentRepositoryURL: developmentRepositoryURL,
            fileExists: FileManager.default.fileExists(atPath:),
            isDirectory: Self.isDirectory(atPath:),
            readFile: FileManager.default.contents(atPath:)
        )
    }

    static func locate(
        environment: [String: String],
        bundleResourceURL: URL?,
        developmentRepositoryURL: URL?,
        fileExists: (String) -> Bool,
        isDirectory: (String) -> Bool,
        readFile: (String) -> Data?
    ) throws -> WebServerRuntime {
        let packagedCommand = bundleResourceURL?
            .appendingPathComponent("WebRuntime", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("scanstudio-web", isDirectory: false)
        let developmentCommand = developmentRepositoryURL?
            .appendingPathComponent("ports/web/.venv/bin/scanstudio-web", isDirectory: false)
        let commandCandidates = [packagedCommand, developmentCommand].compactMap { $0 }

        let commandURL: URL
        if let override = nonempty(environment[commandOverrideKey]) {
            commandURL = URL(fileURLWithPath: override)
            guard fileExists(commandURL.path) else {
                throw WebServerRuntimeLocateError.missingCommandOverride(commandURL.path)
            }
        } else if let candidate = commandCandidates.first(where: { fileExists($0.path) }) {
            commandURL = candidate
        } else {
            let staticCandidates = staticCandidates(
                bundleResourceURL: bundleResourceURL,
                developmentRepositoryURL: developmentRepositoryURL
            )
            throw WebServerRuntimeLocateError.runtimeUnavailable(
                commandPaths: commandCandidates.map(\.path),
                staticPaths: staticCandidates.map(\.path)
            )
        }

        let packagedStatic = bundleResourceURL?
            .appendingPathComponent("WebFrontend", isDirectory: true)
        let developmentStatic = developmentRepositoryURL?
            .appendingPathComponent("ports/tauri/app/dist", isDirectory: true)
        let staticCandidates = [packagedStatic, developmentStatic].compactMap { $0 }

        let staticURL: URL
        if let override = nonempty(environment[staticDirectoryOverrideKey]) {
            staticURL = URL(fileURLWithPath: override, isDirectory: true)
            guard isDirectory(staticURL.path) else {
                throw WebServerRuntimeLocateError.missingStaticDirectoryOverride(staticURL.path)
            }
            guard hasCompatibleMarker(in: staticURL, readFile: readFile) else {
                throw WebServerRuntimeLocateError.incompatibleStaticDirectoryOverride(
                    staticURL.path
                )
            }
        } else if let candidate = staticCandidates.first(where: {
            isDirectory($0.path) && hasCompatibleMarker(in: $0, readFile: readFile)
        }) {
            staticURL = candidate
        } else {
            throw WebServerRuntimeLocateError.runtimeUnavailable(
                commandPaths: commandCandidates.map(\.path),
                staticPaths: staticCandidates.map(\.path)
            )
        }

        return WebServerRuntime(
            executableURL: commandURL,
            staticDirectoryURL: staticURL,
            workingDirectoryURL: commandURL.deletingLastPathComponent()
        )
    }

    private static func staticCandidates(
        bundleResourceURL: URL?,
        developmentRepositoryURL: URL?
    ) -> [URL] {
        [
            bundleResourceURL?.appendingPathComponent("WebFrontend", isDirectory: true),
            developmentRepositoryURL?.appendingPathComponent(
                "ports/tauri/app/dist",
                isDirectory: true
            ),
        ].compactMap { $0 }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hasCompatibleMarker(
        in staticDirectoryURL: URL,
        readFile: (String) -> Data?
    ) -> Bool {
        let markerURL = staticDirectoryURL.appendingPathComponent(
            staticDirectoryMarkerFilename,
            isDirectory: false
        )
        guard let data = readFile(markerURL.path),
              let marker = try? JSONDecoder().decode(StaticDirectoryMarker.self, from: data) else {
            return false
        }
        return marker.schemaVersion == staticDirectoryMarkerSchemaVersion
            && marker.runtime == staticDirectoryMarkerRuntime
    }

    private static func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Source builds already resolve an engine under
    /// `<repo>/app/ScanStudio/engine/target/{release,debug}`. Recognize that
    /// exact shape instead of embedding a developer's absolute checkout path.
    private static func inferRepositoryRoot(from engineURL: URL?) -> URL? {
        guard let engineURL else { return nil }
        let components = engineURL.standardizedFileURL.pathComponents
        guard components.count >= 7 else { return nil }
        let suffix = Array(components.suffix(6))
        guard suffix[0] == "app",
              suffix[1] == "ScanStudio",
              suffix[2] == "engine",
              suffix[3] == "target",
              ["release", "debug"].contains(suffix[4]),
              suffix[5] == "scanstudio-engine" else {
            return nil
        }
        return (0..<6).reduce(engineURL) { partial, _ in
            partial.deletingLastPathComponent()
        }
    }
}

/// Production process controller. The gateway opts into a dedicated process
/// group before spawning its simulator engine. Stop gives the gateway a short
/// graceful window, then targets that whole group so neither process can
/// survive app termination.
public actor FoundationWebServerProcess: WebServerProcessControlling {
    public nonisolated let terminationEvents: AsyncStream<WebServerProcessExit>

    private let terminationContinuation: AsyncStream<WebServerProcessExit>.Continuation
    private var process: (identifier: UUID, value: Process)?

    public init() {
        var continuation: AsyncStream<WebServerProcessExit>.Continuation!
        terminationEvents = AsyncStream { continuation = $0 }
        terminationContinuation = continuation
    }

    public func start(configuration: WebServerLaunchConfiguration) throws {
        if let process, process.value.isRunning {
            throw CocoaError(.executableLoad)
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError

        let continuation = terminationContinuation
        let identifier = configuration.identifier
        process.terminationHandler = { terminated in
            continuation.yield(
                WebServerProcessExit(
                    identifier: identifier,
                    status: terminated.terminationStatus,
                    reason: terminated.terminationReason
                )
            )
        }

        try process.run()
        self.process = (configuration.identifier, process)
    }

    public func stop(identifier: UUID?) {
        guard let current = process,
              identifier == nil || identifier == current.identifier else {
            return
        }
        defer { self.process = nil }
        let process = current.value
        guard process.isRunning else { return }

        let processIdentifier = process.processIdentifier
        process.terminate()
        // The app-hosted gateway uses a 0.75 second engine timeout. Its three
        // bounded shutdown stages therefore fit inside this grace window.
        let deadline = Date().addingTimeInterval(3.5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            // `scanstudio-web` calls setsid() before it spawns the engine, so
            // the negative PID targets the isolated gateway process group.
            // The direct signal is a safe fallback for a rapid stop that lands
            // before Python has completed that setup.
            Darwin.kill(-processIdentifier, SIGKILL)
            Darwin.kill(processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        // A process group can outlive its leader. Sweep it once more after the
        // gateway has exited so a stuck engine child cannot become an orphan.
        Darwin.kill(-processIdentifier, SIGKILL)
    }
}

public struct URLSessionWebServerReadinessChecker: WebServerReadinessChecking {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func waitUntilReady(at startupURL: URL, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error?

        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: startupURL)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.timeoutInterval = 1
                let (_, response) = try await session.data(for: request)
                if let response = response as? HTTPURLResponse,
                   response.statusCode == 200 {
                    return
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        if let lastError {
            throw WebServerReadinessError.timedOut(lastError.localizedDescription)
        }
        throw WebServerReadinessError.timedOut("the startup check never became ready")
    }
}

public enum WebServerReadinessError: Error, LocalizedError, Equatable {
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let detail):
            return "The browser preview did not become ready: \(detail)"
        }
    }
}

@MainActor
@Observable
public final class WebServerModel {
    public static let loopbackURL = URL(string: "http://127.0.0.1:8787/")!

    public private(set) var isEnabled = false
    public private(set) var state: WebServerState = .off

    public let browserURL: URL
    public let accessToken: String

    private let engineURL: URL?
    private let process: any WebServerProcessControlling
    private let readinessChecker: any WebServerReadinessChecking
    private let inheritedEnvironment: [String: String]
    private let runtimeResolver: () throws -> WebServerRuntime
    private var generation: UInt64 = 0
    private var activeProcessIdentifier: UUID?
    private var terminationObserver: Task<Void, Never>?

    public convenience init(engineURL: URL?) {
        let process = FoundationWebServerProcess()
        let locator = WebServerRuntimeLocator(engineURL: engineURL)
        self.init(
            engineURL: engineURL,
            process: process,
            readinessChecker: URLSessionWebServerReadinessChecker(),
            inheritedEnvironment: ProcessInfo.processInfo.environment,
            runtimeResolver: { try locator.locate() },
            tokenGenerator: Self.makeAccessToken
        )
    }

    init(
        engineURL: URL?,
        process: any WebServerProcessControlling,
        readinessChecker: any WebServerReadinessChecking,
        inheritedEnvironment: [String: String],
        browserURL: URL = WebServerModel.loopbackURL,
        runtimeResolver: @escaping () throws -> WebServerRuntime,
        tokenGenerator: () -> String
    ) {
        self.engineURL = engineURL
        self.process = process
        self.readinessChecker = readinessChecker
        self.inheritedEnvironment = inheritedEnvironment
        self.browserURL = browserURL
        self.runtimeResolver = runtimeResolver
        self.accessToken = tokenGenerator()

        let events = process.terminationEvents
        terminationObserver = Task { @MainActor [weak self] in
            for await exit in events {
                guard let self else { return }
                self.handleProcessExit(exit)
            }
        }
    }

    /// The SwiftUI Toggle calls this asynchronously. It is generation-gated
    /// so a quick on/off/on sequence cannot let stale readiness or shutdown
    /// completion overwrite the newest user choice.
    public func setEnabled(_ enabled: Bool) async {
        if enabled == isEnabled {
            guard case .failed = state else { return }
        }

        generation &+= 1
        let operationGeneration = generation
        isEnabled = enabled

        if !enabled {
            state = .stopping
            let processIdentifier = activeProcessIdentifier
            activeProcessIdentifier = nil
            await process.stop(identifier: processIdentifier)
            guard generation == operationGeneration else { return }
            state = .off
            return
        }

        state = .starting
        // Clear any process left behind by a failed/rapid previous attempt.
        await process.stop(identifier: nil)
        guard generation == operationGeneration, isEnabled else { return }

        var launchedIdentifier: UUID?
        do {
            guard let engineURL else {
                throw WebServerRuntimeLocateError.engineUnavailable
            }
            let runtime = try runtimeResolver()
            let processIdentifier = UUID()
            launchedIdentifier = processIdentifier
            activeProcessIdentifier = processIdentifier
            try await process.start(
                configuration: launchConfiguration(
                    identifier: processIdentifier,
                    runtime: runtime,
                    engineURL: engineURL
                )
            )
            try await readinessChecker.waitUntilReady(
                at: browserURL.appendingPathComponent("startupz"),
                timeout: .seconds(10)
            )
            guard generation == operationGeneration, isEnabled else {
                await process.stop(identifier: processIdentifier)
                return
            }
            state = .running
        } catch is CancellationError {
            if activeProcessIdentifier == launchedIdentifier {
                activeProcessIdentifier = nil
            }
            await process.stop(identifier: launchedIdentifier)
            guard generation == operationGeneration else { return }
            isEnabled = false
            state = .off
        } catch {
            if activeProcessIdentifier == launchedIdentifier {
                activeProcessIdentifier = nil
            }
            await process.stop(identifier: launchedIdentifier)
            guard generation == operationGeneration else { return }
            isEnabled = false
            state = .failed(Self.describe(error))
        }
    }

    /// Used by tests and hosts that can await shutdown. The macOS app delegate
    /// also owns the same process controller directly so it can stop it from a
    /// detached task while the main run loop is terminating.
    public func shutDown() async {
        generation &+= 1
        isEnabled = false
        state = .stopping
        activeProcessIdentifier = nil
        await process.stop(identifier: nil)
        state = .off
    }

    /// AppKit calls `applicationWillTerminate` on the main thread and then
    /// waits briefly for cleanup. This nonisolated hook lets its detached
    /// cleanup task stop the shared process without waiting for MainActor,
    /// which is already occupied by the termination callback.
    public nonisolated func stopProcessForApplicationTermination() async {
        await process.stop(identifier: nil)
    }

    public var visibleErrorMessage: String {
        if case .failed(let message) = state { return message }
        return ""
    }

    private func launchConfiguration(
        identifier: UUID,
        runtime: WebServerRuntime,
        engineURL: URL
    ) -> WebServerLaunchConfiguration {
        var environment = inheritedEnvironment
        // Defense in depth in addition to the gateway's own child-environment
        // scrub: the desktop bridge and motion latch never enter this process.
        environment.removeValue(forKey: "SCANSTUDIO_BRIDGE_CMD")
        environment.removeValue(forKey: "SCANSTUDIO_HW_MOTION")
        environment["SCANSTUDIO_ENGINE_PATH"] = engineURL.path
        environment["SCANSTUDIO_WEB_STATIC_DIR"] = runtime.staticDirectoryURL.path
        environment["SCANSTUDIO_WEB_BIND"] = "127.0.0.1"
        environment["SCANSTUDIO_WEB_PORT"] = "8787"
        environment["SCANSTUDIO_WEB_TOKEN"] = accessToken
        environment["SCANSTUDIO_WEB_ALLOWED_ORIGINS"] = "http://127.0.0.1:8787"
        environment["SCANSTUDIO_WEB_COOKIE_SECURE"] = "false"
        environment["SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP"] = "1"
        environment["SCANSTUDIO_WEB_ENGINE_SHUTDOWN_TIMEOUT_SECONDS"] = "0.75"
        environment["PYTHONUNBUFFERED"] = "1"

        return WebServerLaunchConfiguration(
            identifier: identifier,
            executableURL: runtime.executableURL,
            environment: environment,
            workingDirectoryURL: runtime.workingDirectoryURL
        )
    }

    private func handleProcessExit(_ exit: WebServerProcessExit) {
        guard exit.identifier == activeProcessIdentifier else { return }
        activeProcessIdentifier = nil
        guard isEnabled else {
            if state == .stopping { state = .off }
            return
        }
        generation &+= 1
        isEnabled = false
        let reason = exit.reason == .uncaughtSignal
            ? "signal \(exit.status)"
            : "exit code \(exit.status)"
        state = .failed("The browser preview stopped unexpectedly (\(reason)). Turn it on to try again.")
    }

    private static func makeAccessToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription,
           !message.isEmpty {
            return message
        }
        return "The browser preview could not start: \(error.localizedDescription)"
    }
}
