import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Browser preview runtime locator")
struct WebServerRuntimeLocatorTests {
    @Test("explicit development paths win and are validated")
    func overridesWin() throws {
        let command = "/checkout/ports/web/.venv/bin/scanstudio-web"
        let staticDirectory = "/checkout/ports/tauri/app/dist"

        let runtime = try WebServerRuntimeLocator.locate(
            environment: [
                WebServerRuntimeLocator.commandOverrideKey: command,
                WebServerRuntimeLocator.staticDirectoryOverrideKey: staticDirectory,
            ],
            bundleResourceURL: URL(fileURLWithPath: "/Applications/ScanStudio.app/Contents/Resources"),
            developmentRepositoryURL: URL(fileURLWithPath: "/somewhere-else"),
            fileExists: { $0 == command },
            isDirectory: { $0 == staticDirectory },
            readFile: markerReader(staticDirectory)
        )

        #expect(runtime.executableURL.path == command)
        #expect(runtime.staticDirectoryURL.path == staticDirectory)
        #expect(runtime.workingDirectoryURL?.path == "/checkout/ports/web/.venv/bin")
    }

    @Test("packaged resources are preferred over a source checkout")
    func packagedResourcesWin() throws {
        let resources = URL(fileURLWithPath: "/Applications/ScanStudio.app/Contents/Resources")
        let repository = URL(fileURLWithPath: "/checkout")
        let packagedCommand = "/Applications/ScanStudio.app/Contents/Resources/WebRuntime/bin/scanstudio-web"
        let packagedStatic = "/Applications/ScanStudio.app/Contents/Resources/WebFrontend"

        let runtime = try WebServerRuntimeLocator.locate(
            environment: [:],
            bundleResourceURL: resources,
            developmentRepositoryURL: repository,
            fileExists: { path in
                path == packagedCommand
                    || path == "/checkout/ports/web/.venv/bin/scanstudio-web"
            },
            isDirectory: { path in
                path == packagedStatic || path == "/checkout/ports/tauri/app/dist"
            },
            readFile: markerReader(packagedStatic, "/checkout/ports/tauri/app/dist")
        )

        #expect(runtime.executableURL.path == packagedCommand)
        #expect(runtime.staticDirectoryURL.path == packagedStatic)
    }

    @Test("source checkout is a fallback when packaged resources are absent")
    func developmentFallback() throws {
        let repository = URL(fileURLWithPath: "/checkout")
        let command = "/checkout/ports/web/.venv/bin/scanstudio-web"
        let staticDirectory = "/checkout/ports/tauri/app/dist"

        let runtime = try WebServerRuntimeLocator.locate(
            environment: [:],
            bundleResourceURL: nil,
            developmentRepositoryURL: repository,
            fileExists: { $0 == command },
            isDirectory: { $0 == staticDirectory },
            readFile: markerReader(staticDirectory)
        )

        #expect(runtime.executableURL.path == command)
        #expect(runtime.staticDirectoryURL.path == staticDirectory)
    }

    @Test("a missing command override fails closed")
    func missingCommandOverrideFailsClosed() {
        #expect(throws: WebServerRuntimeLocateError.missingCommandOverride("/missing/gateway")) {
            try WebServerRuntimeLocator.locate(
                environment: [WebServerRuntimeLocator.commandOverrideKey: "/missing/gateway"],
                bundleResourceURL: nil,
                developmentRepositoryURL: nil,
                fileExists: { _ in false },
                isDirectory: { _ in false },
                readFile: { _ in nil }
            )
        }
    }

    @Test("a missing static-directory override fails closed")
    func missingStaticOverrideFailsClosed() {
        let command = "/working/gateway"
        #expect(throws: WebServerRuntimeLocateError.missingStaticDirectoryOverride("/missing/dist")) {
            try WebServerRuntimeLocator.locate(
                environment: [
                    WebServerRuntimeLocator.commandOverrideKey: command,
                    WebServerRuntimeLocator.staticDirectoryOverrideKey: "/missing/dist",
                ],
                bundleResourceURL: nil,
                developmentRepositoryURL: nil,
                fileExists: { $0 == command },
                isDirectory: { _ in false },
                readFile: { _ in nil }
            )
        }
    }

    @Test("a static-directory override without a web runtime marker fails closed")
    func unmarkedStaticOverrideFailsClosed() {
        let command = "/working/gateway"
        let staticDirectory = "/working/dist"
        #expect(
            throws: WebServerRuntimeLocateError.incompatibleStaticDirectoryOverride(
                staticDirectory
            )
        ) {
            try WebServerRuntimeLocator.locate(
                environment: [
                    WebServerRuntimeLocator.commandOverrideKey: command,
                    WebServerRuntimeLocator.staticDirectoryOverrideKey: staticDirectory,
                ],
                bundleResourceURL: nil,
                developmentRepositoryURL: nil,
                fileExists: { $0 == command },
                isDirectory: { $0 == staticDirectory },
                readFile: { _ in nil }
            )
        }
    }

    @Test("an incompatible packaged frontend falls back to a marked development build")
    func incompatiblePackagedStaticFallsBackToDevelopment() throws {
        let resources = URL(fileURLWithPath: "/Applications/ScanStudio.app/Contents/Resources")
        let repository = URL(fileURLWithPath: "/checkout")
        let packagedCommand = "/Applications/ScanStudio.app/Contents/Resources/WebRuntime/bin/scanstudio-web"
        let packagedStatic = "/Applications/ScanStudio.app/Contents/Resources/WebFrontend"
        let developmentStatic = "/checkout/ports/tauri/app/dist"

        let runtime = try WebServerRuntimeLocator.locate(
            environment: [:],
            bundleResourceURL: resources,
            developmentRepositoryURL: repository,
            fileExists: { $0 == packagedCommand },
            isDirectory: { $0 == packagedStatic || $0 == developmentStatic },
            readFile: markerReader(developmentStatic)
        )

        #expect(runtime.executableURL.path == packagedCommand)
        #expect(runtime.staticDirectoryURL.path == developmentStatic)
    }

    @Test("automatic static candidates without a compatible marker fail closed")
    func unmarkedAutomaticStaticFailsClosed() {
        let repository = URL(fileURLWithPath: "/checkout")
        let command = "/checkout/ports/web/.venv/bin/scanstudio-web"
        let staticDirectory = "/checkout/ports/tauri/app/dist"

        #expect(
            throws: WebServerRuntimeLocateError.runtimeUnavailable(
                commandPaths: [command],
                staticPaths: [staticDirectory]
            )
        ) {
            try WebServerRuntimeLocator.locate(
                environment: [:],
                bundleResourceURL: nil,
                developmentRepositoryURL: repository,
                fileExists: { $0 == command },
                isDirectory: { $0 == staticDirectory },
                readFile: { _ in nil }
            )
        }
    }

    @Test("a mismatched marker cannot satisfy an explicit static override")
    func mismatchedStaticMarkerFailsClosed() {
        let command = "/working/gateway"
        let staticDirectory = "/working/dist"
        let markerPath = URL(fileURLWithPath: staticDirectory, isDirectory: true)
            .appendingPathComponent(WebServerRuntimeLocator.staticDirectoryMarkerFilename)
            .path
        let mismatchedMarker = Data(
            #"{"schemaVersion":1,"runtime":"desktop"}"#.utf8
        )

        #expect(
            throws: WebServerRuntimeLocateError.incompatibleStaticDirectoryOverride(
                staticDirectory
            )
        ) {
            try WebServerRuntimeLocator.locate(
                environment: [
                    WebServerRuntimeLocator.commandOverrideKey: command,
                    WebServerRuntimeLocator.staticDirectoryOverrideKey: staticDirectory,
                ],
                bundleResourceURL: nil,
                developmentRepositoryURL: nil,
                fileExists: { $0 == command },
                isDirectory: { $0 == staticDirectory },
                readFile: { $0 == markerPath ? mismatchedMarker : nil }
            )
        }
    }

    private func markerReader(_ directories: String...) -> (String) -> Data? {
        let markerPaths = Set(directories.map { directory in
            URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(WebServerRuntimeLocator.staticDirectoryMarkerFilename)
                .path
        })
        let marker = Data(
            #"{"schemaVersion":1,"runtime":"simulator-only-web"}"#.utf8
        )
        return { markerPaths.contains($0) ? marker : nil }
    }
}

@Suite("Browser preview server model")
@MainActor
struct WebServerModelTests {
    private let engineURL = URL(fileURLWithPath: "/checkout/scanstudio-engine")
    private let runtime = WebServerRuntime(
        executableURL: URL(fileURLWithPath: "/checkout/scanstudio-web"),
        staticDirectoryURL: URL(fileURLWithPath: "/checkout/dist", isDirectory: true),
        workingDirectoryURL: URL(fileURLWithPath: "/checkout", isDirectory: true)
    )

    @Test("preview is off by default and a ready process becomes running")
    func startsWithSafeSimulatorOnlyEnvironment() async throws {
        let process = FakeWebServerProcess()
        let readiness = FakeWebServerReadiness()
        let model = makeModel(process: process, readiness: readiness)

        #expect(model.state == .off)
        #expect(!model.isEnabled)
        #expect(model.accessToken == "unit-test-access-token")

        await model.setEnabled(true)

        #expect(model.state == .running)
        #expect(model.isEnabled)
        let snapshot = await process.snapshot()
        let launch = try #require(snapshot.configurations.last)
        #expect(snapshot.stopCount == 1, "startup first clears any stale process")
        #expect(launch.executableURL == runtime.executableURL)
        #expect(launch.workingDirectoryURL == runtime.workingDirectoryURL)
        #expect(launch.environment["SCANSTUDIO_ENGINE_PATH"] == engineURL.path)
        #expect(launch.environment["SCANSTUDIO_WEB_STATIC_DIR"] == runtime.staticDirectoryURL.path)
        #expect(launch.environment["SCANSTUDIO_WEB_BIND"] == "127.0.0.1")
        #expect(launch.environment["SCANSTUDIO_WEB_PORT"] == "8787")
        #expect(launch.environment["SCANSTUDIO_WEB_TOKEN"] == "unit-test-access-token")
        #expect(launch.environment["SCANSTUDIO_WEB_ALLOWED_ORIGINS"] == "http://127.0.0.1:8787")
        #expect(launch.environment["SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP"] == "1")
        #expect(launch.environment["SCANSTUDIO_WEB_ENGINE_SHUTDOWN_TIMEOUT_SECONDS"] == "0.75")
        #expect(launch.environment["SCANSTUDIO_BRIDGE_CMD"] == nil)
        #expect(launch.environment["SCANSTUDIO_HW_MOTION"] == nil)
        #expect(launch.environment["PRESERVED"] == "yes")
        #expect(await readiness.urls == [URL(string: "http://127.0.0.1:8787/startupz")!])
    }

    @Test("turning the toggle off stops the process")
    func toggleOffStopsProcess() async {
        let process = FakeWebServerProcess()
        let model = makeModel(process: process)
        await model.setEnabled(true)

        await model.setEnabled(false)

        #expect(model.state == .off)
        #expect(!model.isEnabled)
        #expect(await process.snapshot().stopCount == 2)
    }

    @Test("readiness failure is visible and returns the toggle to off")
    func readinessFailureIsVisible() async {
        let process = FakeWebServerProcess()
        let readiness = FakeWebServerReadiness(failure: .readiness)
        let model = makeModel(process: process, readiness: readiness)

        await model.setEnabled(true)

        #expect(!model.isEnabled)
        guard case .failed(let message) = model.state else {
            Issue.record("Expected a visible failure state")
            return
        }
        #expect(message.contains("test readiness failure"))
        #expect(await process.snapshot().stopCount == 2)
    }

    @Test("process launch failure is visible and returns the toggle to off")
    func processLaunchFailureIsVisible() async {
        let process = FakeWebServerProcess(startFailure: .processStart)
        let model = makeModel(process: process)

        await model.setEnabled(true)

        #expect(!model.isEnabled)
        #expect(model.state == .failed("test process start failure"))
        #expect(await process.snapshot().configurations.isEmpty)
    }

    @Test("a missing engine fails without launching a gateway")
    func missingEngineFailsClosed() async {
        let process = FakeWebServerProcess()
        let model = WebServerModel(
            engineURL: nil,
            process: process,
            readinessChecker: FakeWebServerReadiness(),
            inheritedEnvironment: [:],
            runtimeResolver: { self.runtime },
            tokenGenerator: { "token" }
        )

        await model.setEnabled(true)

        #expect(!model.isEnabled)
        #expect(model.visibleErrorMessage.contains("engine is unavailable"))
        #expect(await process.snapshot().configurations.isEmpty)
    }

    @Test("an unexpected matching process exit becomes a visible failure")
    func unexpectedExitIsVisible() async throws {
        let process = FakeWebServerProcess()
        let model = makeModel(process: process)
        await model.setEnabled(true)
        let identifier = try #require(await process.snapshot().configurations.last?.identifier)

        await process.emitExit(identifier: identifier, status: 7)
        await waitForObserver()

        #expect(!model.isEnabled)
        #expect(model.state == .failed("The browser preview stopped unexpectedly (exit code 7). Turn it on to try again."))
    }

    @Test("a delayed exit from an old process cannot fail a new run")
    func staleExitIsIgnored() async throws {
        let process = FakeWebServerProcess()
        let model = makeModel(process: process)
        await model.setEnabled(true)
        let firstIdentifier = try #require(await process.snapshot().configurations.last?.identifier)
        await model.setEnabled(false)
        await model.setEnabled(true)

        await process.emitExit(identifier: firstIdentifier, status: 0)
        await waitForObserver()

        #expect(model.isEnabled)
        #expect(model.state == .running)
    }

    @Test("explicit and app-termination shutdown hooks both stop the process")
    func shutdownAlwaysStopsProcess() async {
        let process = FakeWebServerProcess()
        let model = makeModel(process: process)
        await model.setEnabled(true)

        await model.shutDown()
        #expect(model.state == .off)
        #expect(!model.isEnabled)
        #expect(await process.snapshot().stopCount == 2)

        await model.stopProcessForApplicationTermination()
        #expect(await process.snapshot().stopCount == 3)
    }

    private func makeModel(
        process: FakeWebServerProcess,
        readiness: FakeWebServerReadiness = FakeWebServerReadiness()
    ) -> WebServerModel {
        WebServerModel(
            engineURL: engineURL,
            process: process,
            readinessChecker: readiness,
            inheritedEnvironment: [
                "SCANSTUDIO_BRIDGE_CMD": "/hardware/bridge",
                "SCANSTUDIO_HW_MOTION": "I_UNDERSTAND",
                "PRESERVED": "yes",
            ],
            runtimeResolver: { self.runtime },
            tokenGenerator: { "unit-test-access-token" }
        )
    }

    private func waitForObserver() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

private enum FakeWebServerFailure: Error, LocalizedError, Sendable {
    case processStart
    case readiness

    var errorDescription: String? {
        switch self {
        case .processStart: "test process start failure"
        case .readiness: "test readiness failure"
        }
    }
}

private actor FakeWebServerProcess: WebServerProcessControlling {
    nonisolated let terminationEvents: AsyncStream<WebServerProcessExit>
    private let continuation: AsyncStream<WebServerProcessExit>.Continuation
    private let startFailure: FakeWebServerFailure?
    private var configurations: [WebServerLaunchConfiguration] = []
    private var stopCount = 0

    init(startFailure: FakeWebServerFailure? = nil) {
        self.startFailure = startFailure
        var continuation: AsyncStream<WebServerProcessExit>.Continuation!
        terminationEvents = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func start(configuration: WebServerLaunchConfiguration) throws {
        if let startFailure { throw startFailure }
        configurations.append(configuration)
    }

    func stop(identifier: UUID?) {
        stopCount += 1
    }

    func emitExit(identifier: UUID, status: Int32) {
        continuation.yield(
            WebServerProcessExit(identifier: identifier, status: status, reason: .exit)
        )
    }

    func snapshot() -> (configurations: [WebServerLaunchConfiguration], stopCount: Int) {
        (configurations, stopCount)
    }
}

private actor FakeWebServerReadiness: WebServerReadinessChecking {
    private let failure: FakeWebServerFailure?
    private(set) var urls: [URL] = []

    init(failure: FakeWebServerFailure? = nil) {
        self.failure = failure
    }

    func waitUntilReady(at startupURL: URL, timeout: Duration) throws {
        urls.append(startupURL)
        if let failure { throw failure }
    }
}
