import Foundation

/// Shared construction and teardown for the GUI and resident headless host
/// (D-01). Keeping this in ScanStudioKit leaves the CLI free of AppKit.
public enum SessionHost {
    private static let preferencesSuite = "dev.scanstudio.live"

    public struct Handle: Sendable {
        public let engineClient: any EngineClientProtocol
        public let model: SessionModel
        public let server: ControlChannelServer
        public let socketPath: String
        fileprivate let bindLock: Int32?

        fileprivate init(
            engineClient: any EngineClientProtocol,
            model: SessionModel,
            server: ControlChannelServer,
            socketPath: String,
            bindLock: Int32?
        ) {
            self.engineClient = engineClient
            self.model = model
            self.server = server
            self.socketPath = socketPath
            self.bindLock = bindLock
        }
    }

    /// Returns the GUI's `dev.scanstudio.live` defaults domain for every
    /// host. `UserDefaults.standard` is bundle-identity keyed, so a bare CLI
    /// process would otherwise use a different domain; the model's
    /// `archiveFilenameTemplate` crosses the wire through `outputs.get`.
    public static func sharedPreferences() -> UserDefaults {
        if Bundle.main.bundleIdentifier == preferencesSuite {
            return .standard
        }
        return UserDefaults(suiteName: preferencesSuite) ?? .standard
    }

    /// The diagnostics directory shared by GUI and headless sessions.
    public static func defaultDiagnosticsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".scanstudio/diagnostics", isDirectory: true)
    }

    /// Constructs one model/server pair and claims `socketPath` (D-01,
    /// D-02). The explicit defaults domain preserves GUI/headless parity.
    @MainActor
    public static func attach(
        engineClient: any EngineClientProtocol,
        socketPath: String,
        diagnosticsDirectory: URL? = nil,
        preferences: UserDefaults? = nil,
        hostKind: ControlHostKind
    ) async throws -> Handle {
        // Hold the path claim while SessionModel starts discovery, so a
        // concurrent host cannot construct a second scanner client first.
        let bindLock = try ControlSocketPath.claim(socketPath)
        var lockTransferred = false
        defer {
            if !lockTransferred { ControlSocketPath.releaseBindLock(bindLock) }
        }
        let handle = makeHandle(
            engineClient: engineClient,
            socketPath: socketPath,
            diagnosticsDirectory: diagnosticsDirectory,
            preferences: preferences,
            hostKind: hostKind,
            bindLock: bindLock
        )
        do {
            lockTransferred = true
            try await handle.server.start(path: socketPath, bindLock: bindLock)
        } catch {
            await handle.server.stop()
            throw error
        }
        return handle
    }

    /// Builds the same handle as `attach` while holding the socket claim. The
    /// GUI uses this synchronous step so its launch state remains available
    /// from `AppDelegate.init`; it starts the server in its existing task.
    @MainActor
    public static func prepare(
        engineURL: URL? = nil,
        socketPath: String = ControlSocketPath.defaultPath(),
        diagnosticsDirectory: URL? = nil,
        preferences: UserDefaults? = nil,
        hostKind: ControlHostKind
    ) throws -> Handle {
        let bindLock: Int32?
        do {
            bindLock = try ControlSocketPath.claim(socketPath)
        } catch let error as ControlSocketError where error.errnoValue != EADDRINUSE {
            // Preserve the GUI contract: ordinary socket setup failures are
            // logged by serve() and do not prevent the engine-backed UI.
            bindLock = nil
        }
        var lockTransferred = false
        defer {
            if !lockTransferred, let bindLock { ControlSocketPath.releaseBindLock(bindLock) }
        }
        let resolvedURL = try engineURL ?? EngineLocator.locate()
        let engineClient = try EngineClient(engineURL: resolvedURL)
        let handle = makeHandle(
            engineClient: engineClient,
            socketPath: socketPath,
            diagnosticsDirectory: diagnosticsDirectory,
            preferences: preferences,
            hostKind: hostKind,
            bindLock: bindLock
        )
        lockTransferred = bindLock != nil
        return handle
    }

    /// Starts a synchronously prepared handle and transfers its claim to the
    /// server. Socket startup errors are returned to the caller; ownership
    /// was already decided before the engine/model were constructed.
    @MainActor
    public static func serve(_ handle: Handle) async throws {
        try await handle.server.start(path: handle.socketPath, bindLock: handle.bindLock)
    }

    /// Resolves the engine and then uses the same construction path as an
    /// already-created client (D-01).
    @MainActor
    public static func launch(
        engineURL: URL? = nil,
        socketPath: String = ControlSocketPath.defaultPath(),
        diagnosticsDirectory: URL? = nil,
        preferences: UserDefaults? = nil,
        hostKind: ControlHostKind
    ) async throws -> Handle {
        let resolvedURL = try engineURL ?? EngineLocator.locate()
        let bindLock = try ControlSocketPath.claim(socketPath)
        var lockTransferred = false
        defer {
            if !lockTransferred { ControlSocketPath.releaseBindLock(bindLock) }
        }
        let engineClient = try EngineClient(engineURL: resolvedURL)
        let handle = makeHandle(
            engineClient: engineClient,
            socketPath: socketPath,
            diagnosticsDirectory: diagnosticsDirectory,
            preferences: preferences,
            hostKind: hostKind,
            bindLock: bindLock
        )
        do {
            lockTransferred = true
            try await handle.server.start(path: socketPath, bindLock: bindLock)
            return handle
        } catch {
            await shutdown(handle)
            throw error
        }
    }

    @MainActor
    private static func makeHandle(
        engineClient: any EngineClientProtocol,
        socketPath: String,
        diagnosticsDirectory: URL?,
        preferences: UserDefaults?,
        hostKind: ControlHostKind,
        bindLock: Int32? = nil
    ) -> Handle {
        let model = SessionModel(
            engineClient: engineClient,
            preferences: preferences ?? sharedPreferences(),
            diagnosticsDirectory: diagnosticsDirectory ?? defaultDiagnosticsDirectory()
        )
        return Handle(
            engineClient: engineClient,
            model: model,
            server: ControlChannelServer(sessionModel: model, hostKind: hostKind),
            socketPath: socketPath,
            bindLock: bindLock
        )
    }

    /// Stops the server first, then terminates a production engine client.
    /// Protocol test doubles have no subprocess to terminate.
    public static func shutdown(_ handle: Handle) async {
        await handle.server.stop()
        if let engineClient = handle.engineClient as? EngineClient {
            await engineClient.terminate()
        }
    }
}
