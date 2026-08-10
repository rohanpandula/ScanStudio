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
    case checkingRuntime
    case downloadingRuntime
    case preparingRuntime
    case installingRuntime
    case verifyingRuntime
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

/// Thread-safe ownership for the executable-code provisioning task. AppKit
/// invokes termination on the main thread, so the app delegate cannot hop back
/// to `WebServerModel`'s MainActor just to cancel an in-flight DMG operation.
/// This coordinator gives both paths one task handle and a bounded completion
/// signal without weakening the model's UI isolation.
private final class WebRuntimeProvisioningCoordinator: @unchecked Sendable {
    private struct ActiveOperation {
        let identifier: UUID
        let task: Task<WebServerRuntime, Error>
        let completion: DispatchSemaphore
    }

    private let lock = NSLock()
    private var activeOperation: ActiveOperation?

    var hasActiveOperation: Bool {
        lock.withLock { activeOperation != nil }
    }

    func start(
        operation: @escaping @Sendable () async throws -> WebServerRuntime
    ) -> Task<WebServerRuntime, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard activeOperation == nil else { return nil }

        let identifier = UUID()
        let completion = DispatchSemaphore(value: 0)
        let task = Task { [self] in
            defer { finish(identifier: identifier, completion: completion) }
            return try await operation()
        }
        activeOperation = ActiveOperation(
            identifier: identifier,
            task: task,
            completion: completion
        )
        return task
    }

    func cancelCurrent() {
        let task = lock.withLock { activeOperation?.task }
        task?.cancel()
    }

    /// Cancels the current provisioning operation and waits only for the
    /// caller's cleanup budget. The provisioning task still owns its scratch
    /// cleanup if a platform command exceeds that budget; application shutdown
    /// must never wait indefinitely.
    func cancelCurrentAndWait(timeout: TimeInterval) async {
        guard timeout.isFinite, timeout > 0 else {
            cancelCurrent()
            return
        }
        guard let operation = lock.withLock({ activeOperation }) else { return }
        operation.task.cancel()
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                _ = operation.completion.wait(timeout: .now() + timeout)
                continuation.resume()
            }
        }
    }

    private func finish(identifier: UUID, completion: DispatchSemaphore) {
        lock.withLock {
            if activeOperation?.identifier == identifier {
                activeOperation = nil
            }
        }
        completion.signal()
    }
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

/// Resolves only explicit/source-development layouts. Release builds never
/// execute web code from the app bundle; their optional runtime is supplied by
/// the separately signed, per-user cache and is reverified before each launch.
public struct WebServerRuntimeLocator: Sendable {
    public static let commandOverrideKey = "SCANSTUDIO_WEB_COMMAND_PATH"
    public static let staticDirectoryOverrideKey = "SCANSTUDIO_WEB_STATIC_DIR"
    static let staticDirectoryMarkerFilename = "scanstudio-web-runtime.json"
    static let staticDirectoryMarkerSchemaVersion = 1
    static let staticDirectoryMarkerRuntime = "simulator-only-web"

    #if DEBUG
    private static let developmentRuntimeAllowed = true
    #else
    private static let developmentRuntimeAllowed = false
    #endif

    private struct StaticDirectoryMarker: Decodable {
        let schemaVersion: Int
        let runtime: String
    }

    private let environment: [String: String]
    private let developmentRepositoryURL: URL?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        engineURL: URL?
    ) {
        self.environment = environment
        self.developmentRepositoryURL = Self.inferRepositoryRoot(from: engineURL)
    }

    public func locate() throws -> WebServerRuntime {
        try Self.locate(
            environment: environment,
            bundleResourceURL: nil,
            developmentRepositoryURL: developmentRepositoryURL,
            fileExists: FileManager.default.fileExists(atPath:),
            isDirectory: Self.isDirectory(atPath:),
            readFile: FileManager.default.contents(atPath:),
            developmentRuntimeAllowed: Self.developmentRuntimeAllowed
        )
    }

    static func locate(
        environment: [String: String],
        bundleResourceURL: URL?,
        developmentRepositoryURL: URL?,
        fileExists: (String) -> Bool,
        isDirectory: (String) -> Bool,
        readFile: (String) -> Data?,
        developmentRuntimeAllowed: Bool = true
    ) throws -> WebServerRuntime {
        let developmentCommand = developmentRuntimeAllowed ? developmentRepositoryURL?
            .appendingPathComponent("ports/web/.venv/bin/scanstudio-web", isDirectory: false)
            : nil
        let commandCandidates = [developmentCommand].compactMap { $0 }

        let commandURL: URL
        if developmentRuntimeAllowed,
           let override = nonempty(environment[commandOverrideKey]) {
            commandURL = URL(fileURLWithPath: override)
            guard fileExists(commandURL.path) else {
                throw WebServerRuntimeLocateError.missingCommandOverride(commandURL.path)
            }
        } else if let candidate = commandCandidates.first(where: { fileExists($0.path) }) {
            commandURL = candidate
        } else {
            let staticCandidates = staticCandidates(
                bundleResourceURL: nil,
                developmentRepositoryURL: developmentRuntimeAllowed
                    ? developmentRepositoryURL : nil
            )
            throw WebServerRuntimeLocateError.runtimeUnavailable(
                commandPaths: commandCandidates.map(\.path),
                staticPaths: staticCandidates.map(\.path)
            )
        }

        let developmentStatic = developmentRuntimeAllowed ? developmentRepositoryURL?
            .appendingPathComponent("ports/tauri/app/dist", isDirectory: true)
            : nil
        let staticCandidates = [developmentStatic].compactMap { $0 }

        let staticURL: URL
        if developmentRuntimeAllowed,
           let override = nonempty(environment[staticDirectoryOverrideKey]) {
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
    private var process: (
        identifier: UUID,
        value: Process,
        processGroup: WebServerOwnedProcessGroup
    )?

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
        let processGroup = WebServerOwnedProcessGroup(
            isIsolated: configuration.environment["SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP"] == "1"
        )
        process.terminationHandler = { terminated in
            // The gateway may exit before an explicit stop (for example after
            // a fatal Python error). Sweep its owned group before publishing
            // that exit so an engine child cannot escape when a retry replaces
            // the stored Process. The one-shot token also prevents a later stop
            // from signaling a PID/PGID that the OS may have reused.
            processGroup.sweep()
            continuation.yield(
                WebServerProcessExit(
                    identifier: identifier,
                    status: terminated.terminationStatus,
                    reason: terminated.terminationReason
                )
            )
        }

        try process.run()
        processGroup.activate(processIdentifier: process.processIdentifier)
        self.process = (configuration.identifier, process, processGroup)
    }

    public func stop(identifier: UUID?) {
        guard let current = process,
              identifier == nil || identifier == current.identifier else {
            return
        }
        defer { self.process = nil }
        let process = current.value
        let processGroup = current.processGroup
        guard process.isRunning else {
            // The termination handler normally won this race. Calling the
            // one-shot token here covers the narrow interval where Process has
            // stopped reporting `isRunning` but its handler has not run yet.
            processGroup.sweep()
            return
        }

        let processIdentifier = process.processIdentifier
        process.terminate()
        // The app-hosted gateway uses a 0.75 second engine timeout. Its three
        // bounded shutdown stages therefore fit inside this grace window.
        let deadline = Date().addingTimeInterval(3.5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            // `scanstudio-web` confirms or creates a dedicated process group
            // before it spawns the engine, so the negative PID targets only
            // that isolated gateway group.
            // The direct signal is a safe fallback for a rapid stop that lands
            // before Python has completed that setup.
            processGroup.sweep()
            Darwin.kill(processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        // A process group can outlive its leader. Sweep it once more after the
        // gateway has exited so a stuck engine child cannot become an orphan.
        processGroup.sweep()
    }
}

/// One lifecycle-scoped right to signal a gateway's isolated process group.
/// The termination callback consumes it synchronously before publishing the
/// exit; explicit stop shares the same token for race coverage. Once consumed,
/// no later retry or shutdown path can send a signal to a reused PID/PGID.
private final class WebServerOwnedProcessGroup: @unchecked Sendable {
    private let isIsolated: Bool
    private let lock = NSLock()
    private var processIdentifier: pid_t?
    private var sweepPending = false
    private var wasSwept = false

    init(isIsolated: Bool) {
        self.isIsolated = isIsolated
    }

    /// `Process` exposes its PID only after `run()`. If a very short-lived
    /// command terminates between `run()` and this activation, its handler has
    /// already recorded a pending sweep and activation performs it immediately.
    func activate(processIdentifier: pid_t) {
        guard isIsolated else { return }
        let shouldSweep = lock.withLock { () -> Bool in
            guard !wasSwept else { return false }
            self.processIdentifier = processIdentifier
            guard sweepPending else { return false }
            wasSwept = true
            return true
        }
        if shouldSweep {
            _ = Darwin.kill(-processIdentifier, SIGKILL)
        }
    }

    func sweep() {
        guard isIsolated else { return }
        let target = lock.withLock { () -> pid_t? in
            guard !wasSwept else { return nil }
            guard let processIdentifier else {
                sweepPending = true
                return nil
            }
            wasSwept = true
            return processIdentifier
        }
        guard let target else { return }
        _ = Darwin.kill(-target, SIGKILL)
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

    public private(set) var preferences: WebServerPreferences
    public private(set) var availableLANAddresses: [String]
    public private(set) var pendingRuntimeDownloadOffer: WebRuntimeDownloadOffer?

    public private(set) var accessToken: String

    public var browserURL: URL {
        activeNetworkConfiguration?.browserURL
            ?? (try? resolvedNetworkConfiguration().browserURL)
            ?? Self.loopbackURL
    }

    public var advertisedURLs: [URL] {
        activeNetworkConfiguration?.advertisedURLs
            ?? (try? resolvedNetworkConfiguration().advertisedURLs)
            ?? [Self.loopbackURL]
    }

    public var configurationErrorMessage: String {
        do {
            _ = try resolvedNetworkConfiguration()
            return ""
        } catch {
            return Self.describe(error)
        }
    }

    private let engineURL: URL?
    private let process: any WebServerProcessControlling
    private let readinessChecker: any WebServerReadinessChecking
    private let inheritedEnvironment: [String: String]
    private let runtimeResolver: () throws -> WebServerRuntime
    private let runtimeManager: (any WebRuntimeManaging)?
    private let runtimeRequest: WebRuntimeReleaseRequest?
    private let lanAddressProvider: () -> [String]
    private let preferencesDefaults: UserDefaults?
    private var generation: UInt64 = 0
    private var activeProcessIdentifier: UUID?
    private var activeNetworkConfiguration: WebServerNetworkConfiguration?
    private let runtimeProvisioning = WebRuntimeProvisioningCoordinator()
    private var terminationObserver: Task<Void, Never>?

    public convenience init(engineURL: URL?) {
        self.init(engineURL: engineURL, runtimeManager: nil, runtimeRequest: nil)
    }

    public convenience init(
        engineURL: URL?,
        runtimeManager: (any WebRuntimeManaging)?,
        runtimeRequest: WebRuntimeReleaseRequest?
    ) {
        let process = FoundationWebServerProcess()
        let locator = WebServerRuntimeLocator(engineURL: engineURL)
        self.init(
            engineURL: engineURL,
            process: process,
            readinessChecker: URLSessionWebServerReadinessChecker(),
            inheritedEnvironment: ProcessInfo.processInfo.environment,
            preferences: Self.loadPreferences(from: .standard),
            preferencesDefaults: .standard,
            runtimeManager: runtimeManager,
            runtimeRequest: runtimeRequest,
            runtimeResolver: { try locator.locate() },
            tokenGenerator: Self.makeAccessToken
        )
    }

    init(
        engineURL: URL?,
        process: any WebServerProcessControlling,
        readinessChecker: any WebServerReadinessChecking,
        inheritedEnvironment: [String: String],
        preferences: WebServerPreferences = WebServerPreferences(),
        privateLANAddresses: @escaping () -> [String] = SystemLANAddressProvider.privateAddresses,
        preferencesDefaults: UserDefaults? = nil,
        runtimeManager: (any WebRuntimeManaging)? = nil,
        runtimeRequest: WebRuntimeReleaseRequest? = nil,
        runtimeResolver: @escaping () throws -> WebServerRuntime,
        tokenGenerator: () -> String
    ) {
        self.engineURL = engineURL
        self.process = process
        self.readinessChecker = readinessChecker
        self.inheritedEnvironment = inheritedEnvironment
        self.preferences = preferences
        self.lanAddressProvider = privateLANAddresses
        self.availableLANAddresses = privateLANAddresses()
        self.preferencesDefaults = preferencesDefaults
        self.runtimeManager = runtimeManager
        self.runtimeRequest = runtimeRequest
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

    public func updatePreferences(_ preferences: WebServerPreferences) {
        guard !isEnabled, state != .starting, state != .stopping else { return }
        self.preferences = preferences
        refreshLANAddresses()
        savePreferences()
    }

    public func refreshLANAddresses() {
        availableLANAddresses = lanAddressProvider()
    }

    public func regenerateAccessToken() {
        guard !isEnabled, state != .starting, state != .stopping else { return }
        accessToken = Self.makeAccessToken()
    }

    public func cancelRuntimeDownloadOffer() {
        guard !isEnabled else { return }
        pendingRuntimeDownloadOffer = nil
        if state == .checkingRuntime { state = .off }
    }

    /// Synchronously consumes the consent offer before SwiftUI dismisses its
    /// confirmation dialog, then starts the accepted operation. This prevents
    /// the dialog's dismissal binding from clearing the offer before an
    /// asynchronously scheduled button task can observe it.
    public func acceptPendingRuntimeDownloadAndEnable() {
        guard let accepted = consumePendingRuntimeDownloadOffer() else { return }
        Task { @MainActor [weak self] in
            await self?.performAcceptedRuntimeDownload(accepted)
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
            runtimeProvisioning.cancelCurrent()
            pendingRuntimeDownloadOffer = nil
            state = .stopping
            let processIdentifier = activeProcessIdentifier
            activeProcessIdentifier = nil
            await process.stop(identifier: processIdentifier)
            guard generation == operationGeneration else { return }
            activeNetworkConfiguration = nil
            state = .off
            return
        }

        state = .starting
        // Clear any process left behind by a failed/rapid previous attempt.
        await process.stop(identifier: nil)
        guard generation == operationGeneration, isEnabled else { return }

        do {
            guard let engineURL else {
                throw WebServerRuntimeLocateError.engineUnavailable
            }
            refreshLANAddresses()
            let networkConfiguration = try resolvedNetworkConfiguration()
            let resolution = try await resolveRuntimeForEnable()
            guard generation == operationGeneration, isEnabled else { return }
            switch resolution {
            case .download(let offer):
                pendingRuntimeDownloadOffer = offer
                isEnabled = false
                state = .off
                return
            case .runtime(let runtime):
                try await launch(
                    runtime: runtime,
                    engineURL: engineURL,
                    networkConfiguration: networkConfiguration,
                    operationGeneration: operationGeneration
                )
            }
        } catch is CancellationError {
            guard generation == operationGeneration else { return }
            isEnabled = false
            activeNetworkConfiguration = nil
            state = .off
        } catch {
            guard generation == operationGeneration else { return }
            isEnabled = false
            activeNetworkConfiguration = nil
            state = .failed(Self.describe(error))
        }
    }

    /// Starts the exact signed offer that the user accepted. The offer is
    /// removed before the executable download begins so a second click cannot
    /// start a concurrent install. Turning the toggle off cancels this task.
    public func downloadPendingRuntimeAndEnable() async {
        guard let accepted = consumePendingRuntimeDownloadOffer() else { return }
        await performAcceptedRuntimeDownload(accepted)
    }

    private struct AcceptedRuntimeDownload {
        let offer: WebRuntimeDownloadOffer
        let operationGeneration: UInt64
    }

    private func consumePendingRuntimeDownloadOffer() -> AcceptedRuntimeDownload? {
        guard let offer = pendingRuntimeDownloadOffer,
              runtimeManager != nil,
              !runtimeProvisioning.hasActiveOperation else { return nil }
        generation &+= 1
        let accepted = AcceptedRuntimeDownload(
            offer: offer,
            operationGeneration: generation
        )
        pendingRuntimeDownloadOffer = nil
        isEnabled = true
        state = .downloadingRuntime
        return accepted
    }

    private func performAcceptedRuntimeDownload(
        _ accepted: AcceptedRuntimeDownload
    ) async {
        guard let runtimeManager else { return }
        let operationGeneration = accepted.operationGeneration
        await process.stop(identifier: nil)
        guard generation == operationGeneration, isEnabled else { return }

        do {
            guard let engineURL else {
                throw WebServerRuntimeLocateError.engineUnavailable
            }
            refreshLANAddresses()
            let networkConfiguration = try resolvedNetworkConfiguration()
            guard let task = runtimeProvisioning.start(operation: {
                try await runtimeManager.install(accepted.offer) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.generation == operationGeneration,
                              self.isEnabled else { return }
                        self.state = Self.webServerState(for: progress)
                    }
                }
            }) else {
                throw WebRuntimeDistributionError.operationInProgress
            }
            let runtime = try await task.value
            guard generation == operationGeneration, isEnabled else { return }
            try await launch(
                runtime: runtime,
                engineURL: engineURL,
                networkConfiguration: networkConfiguration,
                operationGeneration: operationGeneration
            )
        } catch is CancellationError {
            guard generation == operationGeneration else { return }
            isEnabled = false
            activeNetworkConfiguration = nil
            state = .off
        } catch {
            guard generation == operationGeneration else { return }
            isEnabled = false
            activeNetworkConfiguration = nil
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
        await runtimeProvisioning.cancelCurrentAndWait(timeout: 4)
        pendingRuntimeDownloadOffer = nil
        await process.stop(identifier: nil)
        activeNetworkConfiguration = nil
        state = .off
    }

    /// AppKit calls `applicationWillTerminate` on the main thread and then
    /// waits briefly for cleanup. This nonisolated hook cancels executable-code
    /// provisioning, gives its DMG/scratch cleanup a bounded window, and stops
    /// the shared process without waiting for MainActor, which is already
    /// occupied by the termination callback.
    public nonisolated func stopProcessForApplicationTermination() async {
        async let provisioning: Void = runtimeProvisioning.cancelCurrentAndWait(timeout: 4)
        async let processStop: Void = process.stop(identifier: nil)
        _ = await (provisioning, processStop)
    }

    public var visibleErrorMessage: String {
        if case .failed(let message) = state { return message }
        return ""
    }

    private func launchConfiguration(
        identifier: UUID,
        runtime: WebServerRuntime,
        engineURL: URL,
        networkConfiguration: WebServerNetworkConfiguration
    ) -> WebServerLaunchConfiguration {
        // Start from a narrow allowlist. In particular, never inherit bridge,
        // motion, loader, or Python module-search variables into downloaded
        // executable code. Source builds retain only the simulator time scale.
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "SCANSTUDIO_TIMESCALE"] {
            if let value = inheritedEnvironment[key], !value.isEmpty {
                environment[key] = value
            }
        }
        environment["SCANSTUDIO_ENGINE_PATH"] = engineURL.path
        environment["SCANSTUDIO_WEB_STATIC_DIR"] = runtime.staticDirectoryURL.path
        environment["SCANSTUDIO_WEB_BIND"] = networkConfiguration.bindAddress
        environment["SCANSTUDIO_WEB_PORT"] = String(networkConfiguration.port)
        environment["SCANSTUDIO_WEB_AUTH_MODE"] = networkConfiguration.authenticationMode.rawValue
        if networkConfiguration.authenticationMode == .accessToken {
            environment["SCANSTUDIO_WEB_TOKEN"] = accessToken
        }
        environment["SCANSTUDIO_WEB_ALLOWED_ORIGINS"] = networkConfiguration.allowedOrigins.joined(separator: ",")
        environment["SCANSTUDIO_WEB_COOKIE_SECURE"] = networkConfiguration.cookieSecure
            ? "true"
            : "false"
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

    private enum RuntimeResolution {
        case runtime(WebServerRuntime)
        case download(WebRuntimeDownloadOffer)
    }

    private func resolveRuntimeForEnable() async throws -> RuntimeResolution {
        do {
            return .runtime(try runtimeResolver())
        } catch WebServerRuntimeLocateError.runtimeUnavailable {
            // Release builds intentionally have no app-bundled fallback.
        }

        guard let runtimeManager, let runtimeRequest else {
            throw WebServerRuntimeLocateError.runtimeUnavailable(
                commandPaths: [],
                staticPaths: []
            )
        }
        state = .checkingRuntime
        switch await runtimeManager.inspectVerifiedCurrent(for: runtimeRequest) {
        case .ready(let installed):
            return .runtime(installed.webServerRuntime)
        case .notInstalled, .invalid:
            let offer = try await runtimeManager.resolveMetadataForConsent(
                for: runtimeRequest
            )
            return .download(offer)
        }
    }

    private func launch(
        runtime: WebServerRuntime,
        engineURL: URL,
        networkConfiguration: WebServerNetworkConfiguration,
        operationGeneration: UInt64
    ) async throws {
        state = .starting
        let processIdentifier = UUID()
        activeProcessIdentifier = processIdentifier
        activeNetworkConfiguration = networkConfiguration
        do {
            try await process.start(
                configuration: launchConfiguration(
                    identifier: processIdentifier,
                    runtime: runtime,
                    engineURL: engineURL,
                    networkConfiguration: networkConfiguration
                )
            )
            try await readinessChecker.waitUntilReady(
                at: networkConfiguration.readinessURL.appendingPathComponent("startupz"),
                timeout: .seconds(10)
            )
            guard generation == operationGeneration, isEnabled else {
                throw CancellationError()
            }
            state = .running
        } catch {
            if activeProcessIdentifier == processIdentifier {
                activeProcessIdentifier = nil
            }
            activeNetworkConfiguration = nil
            await process.stop(identifier: processIdentifier)
            throw error
        }
    }

    private static func webServerState(
        for progress: WebRuntimeInstallProgress
    ) -> WebServerState {
        switch progress {
        case .resolvingMetadata: .checkingRuntime
        case .downloading: .downloadingRuntime
        case .preparing: .preparingRuntime
        case .installing: .installingRuntime
        case .verifyingForLaunch, .complete: .verifyingRuntime
        }
    }

    private func handleProcessExit(_ exit: WebServerProcessExit) {
        guard exit.identifier == activeProcessIdentifier else { return }
        activeProcessIdentifier = nil
        activeNetworkConfiguration = nil
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

    private func resolvedNetworkConfiguration() throws -> WebServerNetworkConfiguration {
        try WebServerNetworkResolver.resolve(
            preferences,
            privateLANAddresses: availableLANAddresses
        )
    }

    private enum PreferenceKey {
        static let bindScope = "ScanStudio.web.bindScope"
        static let customBindAddress = "ScanStudio.web.customBindAddress"
        static let port = "ScanStudio.web.port"
        static let authenticationMode = "ScanStudio.web.authenticationMode"
        static let additionalOrigins = "ScanStudio.web.additionalOrigins"
    }

    private static func loadPreferences(from defaults: UserDefaults) -> WebServerPreferences {
        let bindScope = defaults.string(forKey: PreferenceKey.bindScope)
            .flatMap(WebServerBindScope.init(rawValue:)) ?? .thisMac
        let authenticationMode = defaults.string(forKey: PreferenceKey.authenticationMode)
            .flatMap(WebServerAuthenticationMode.init(rawValue:)) ?? .accessToken
        let persistedPort = defaults.object(forKey: PreferenceKey.port) == nil
            ? 8787
            : defaults.integer(forKey: PreferenceKey.port)
        return WebServerPreferences(
            bindScope: bindScope,
            customBindAddress: defaults.string(forKey: PreferenceKey.customBindAddress) ?? "",
            port: persistedPort,
            authenticationMode: authenticationMode,
            additionalOrigins: defaults.string(forKey: PreferenceKey.additionalOrigins) ?? ""
        )
    }

    private func savePreferences() {
        guard let defaults = preferencesDefaults else { return }
        defaults.set(preferences.bindScope.rawValue, forKey: PreferenceKey.bindScope)
        defaults.set(preferences.customBindAddress, forKey: PreferenceKey.customBindAddress)
        defaults.set(preferences.port, forKey: PreferenceKey.port)
        defaults.set(preferences.authenticationMode.rawValue, forKey: PreferenceKey.authenticationMode)
        defaults.set(preferences.additionalOrigins, forKey: PreferenceKey.additionalOrigins)
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
