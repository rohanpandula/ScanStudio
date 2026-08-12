import Darwin
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

    @Test("app-bundled web resources are ignored in favor of a source checkout")
    func packagedResourcesAreIgnored() throws {
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

        #expect(runtime.executableURL.path == "/checkout/ports/web/.venv/bin/scanstudio-web")
        #expect(runtime.staticDirectoryURL.path == "/checkout/ports/tauri/app/dist")
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

    @Test("packaged web files never participate in development fallback")
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
            fileExists: {
                $0 == packagedCommand
                    || $0 == "/checkout/ports/web/.venv/bin/scanstudio-web"
            },
            isDirectory: { $0 == packagedStatic || $0 == developmentStatic },
            readFile: markerReader(developmentStatic)
        )

        #expect(runtime.executableURL.path == "/checkout/ports/web/.venv/bin/scanstudio-web")
        #expect(runtime.staticDirectoryURL.path == developmentStatic)
    }

    @Test("release mode ignores overrides, source paths, and app-bundled files")
    func releaseModeUsesOnlyVerifiedRuntimeManager() {
        #expect(
            throws: WebServerRuntimeLocateError.runtimeUnavailable(
                commandPaths: [],
                staticPaths: []
            )
        ) {
            try WebServerRuntimeLocator.locate(
                environment: [
                    WebServerRuntimeLocator.commandOverrideKey: "/override/gateway",
                    WebServerRuntimeLocator.staticDirectoryOverrideKey: "/override/dist",
                ],
                bundleResourceURL: URL(fileURLWithPath: "/Applications/ScanStudio.app/Contents/Resources"),
                developmentRepositoryURL: URL(fileURLWithPath: "/checkout"),
                fileExists: { _ in true },
                isDirectory: { _ in true },
                readFile: markerReader("/override/dist", "/checkout/ports/tauri/app/dist"),
                developmentRuntimeAllowed: false
            )
        }
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

@Suite("Browser preview production process lifecycle")
struct FoundationWebServerProcessTests {
    @Test("an exited gateway leader cannot leave an isolated group child behind")
    func exitedLeaderSweepsProcessGroup() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        #expect(FileManager.default.isExecutableFile(atPath: python.path))

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScanStudio-WebServerProcessTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let childPIDFile = temporary.appendingPathComponent("child.pid")

        let script = #"""
        import os
        import signal
        import sys

        if os.getpgrp() != os.getpid():
            raise RuntimeError("Foundation did not create the promised process group")
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            os.execl("/bin/sleep", "sleep", "30")
        descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(descriptor, str(child).encode("ascii"))
        os.fsync(descriptor)
        os.close(descriptor)
        os._exit(23)
        """#

        let process = FoundationWebServerProcess()
        let identifier = UUID()
        let exitTask = Task<WebServerProcessExit?, Never> {
            for await exit in process.terminationEvents where exit.identifier == identifier {
                return exit
            }
            return nil
        }
        try await process.start(
            configuration: WebServerLaunchConfiguration(
                identifier: identifier,
                executableURL: python,
                arguments: ["-c", script, childPIDFile.path],
                environment: [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP": "1",
                ]
            )
        )

        let exit = try #require(await exitTask.value)
        #expect(exit.status == 23)
        // Exercise the explicit-stop side of the leader-already-exited race as
        // well; it shares the termination handler's one-shot cleanup token.
        await process.stop(identifier: identifier)

        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
        let childPID = try #require(pid_t(childPIDText))
        var childStillExists = true
        for _ in 0..<200 {
            if Darwin.kill(childPID, 0) == -1, errno == ESRCH {
                childStillExists = false
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if childStillExists {
            // Keep a failing regression test from leaking its probe process.
            _ = Darwin.kill(childPID, SIGKILL)
        }
        #expect(!childStillExists)
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
        #expect(launch.environment["SCANSTUDIO_WEB_AUTH_MODE"] == "token")
        #expect(launch.environment["SCANSTUDIO_WEB_TOKEN"] == "unit-test-access-token")
        #expect(launch.environment["SCANSTUDIO_WEB_ALLOWED_ORIGINS"] == "http://127.0.0.1:8787")
        #expect(launch.environment["SCANSTUDIO_WEB_COOKIE_SECURE"] == "false")
        #expect(launch.environment["SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP"] == "1")
        #expect(launch.environment["SCANSTUDIO_WEB_ENGINE_SHUTDOWN_TIMEOUT_SECONDS"] == "0.75")
        #expect(launch.environment["SCANSTUDIO_BRIDGE_CMD"] == nil)
        #expect(launch.environment["SCANSTUDIO_HW_MOTION"] == nil)
        #expect(launch.environment["PYTHONPATH"] == nil)
        #expect(launch.environment["DYLD_LIBRARY_PATH"] == nil)
        #expect(launch.environment["PRESERVED"] == nil)
        #expect(launch.environment["SCANSTUDIO_TIMESCALE"] == "0.05")
        #expect(await readiness.urls == [URL(string: "http://127.0.0.1:8787/startupz")!])
    }

    @Test("HTTPS proxy origins use secure cookies while readiness stays local")
    func httpsProxyUsesSecureCookieAndLocalReadiness() async throws {
        let process = FakeWebServerProcess()
        let readiness = FakeWebServerReadiness()
        let model = makeModel(process: process, readiness: readiness)
        model.updatePreferences(
            WebServerPreferences(additionalOrigins: "https://scan.example.test")
        )

        await model.setEnabled(true)

        let launch = try #require(await process.snapshot().configurations.last)
        #expect(launch.environment["SCANSTUDIO_WEB_ALLOWED_ORIGINS"] == "https://scan.example.test")
        #expect(launch.environment["SCANSTUDIO_WEB_COOKIE_SECURE"] == "true")
        #expect(model.browserURL == URL(string: "https://scan.example.test/")!)
        #expect(model.advertisedURLs == [URL(string: "https://scan.example.test/")!])
        #expect(await readiness.urls == [URL(string: "http://127.0.0.1:8787/startupz")!])
    }

    @Test("trusted LAN configuration launches without a token on the chosen port")
    func trustedLANLaunchEnvironment() async throws {
        let process = FakeWebServerProcess()
        let model = makeModel(process: process)
        model.updatePreferences(
            WebServerPreferences(
                bindScope: .localNetwork,
                port: 9444,
                authenticationMode: .trustedLAN
            )
        )

        await model.setEnabled(true)

        let launch = try #require(await process.snapshot().configurations.last)
        #expect(launch.environment["SCANSTUDIO_WEB_BIND"] == "192.168.50.4")
        #expect(launch.environment["SCANSTUDIO_WEB_PORT"] == "9444")
        #expect(launch.environment["SCANSTUDIO_WEB_AUTH_MODE"] == "trusted-lan-no-login")
        #expect(launch.environment["SCANSTUDIO_WEB_TOKEN"] == nil)
        #expect(launch.environment["SCANSTUDIO_WEB_ALLOWED_ORIGINS"] == "http://192.168.50.4:9444")
        #expect(model.browserURL == URL(string: "http://192.168.50.4:9444/")!)
        #expect(model.advertisedURLs == [
            URL(string: "http://192.168.50.4:9444/")!,
        ])
    }

    @Test("invalid network preferences fail before a process is launched")
    func invalidPreferencesFailBeforeLaunch() async {
        let process = FakeWebServerProcess()
        let model = makeModel(process: process)
        model.updatePreferences(
            WebServerPreferences(authenticationMode: .trustedLAN)
        )

        await model.setEnabled(true)

        #expect(!model.isEnabled)
        #expect(model.visibleErrorMessage.contains("requires a private network interface"))
        #expect(await process.snapshot().configurations.isEmpty)
    }

    @Test("validated preferences persist and cannot change while running")
    func preferencesPersistAndFreezeWhileRunning() async throws {
        let suite = "ScanStudio.WebServerModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let process = FakeWebServerProcess()
        let model = WebServerModel(
            engineURL: engineURL,
            process: process,
            readinessChecker: FakeWebServerReadiness(),
            inheritedEnvironment: [:],
            privateLANAddresses: { ["192.168.50.4"] },
            preferencesDefaults: defaults,
            runtimeResolver: { self.runtime },
            tokenGenerator: { "initial-token" }
        )
        let chosen = WebServerPreferences(
            bindScope: .localNetwork,
            port: 9123,
            authenticationMode: .accessToken,
            additionalOrigins: "https://scan.example.test"
        )

        model.updatePreferences(chosen)

        #expect(model.preferences == chosen)
        #expect(defaults.string(forKey: "ScanStudio.web.bindScope") == "local-network")
        #expect(defaults.integer(forKey: "ScanStudio.web.port") == 9123)
        #expect(defaults.string(forKey: "ScanStudio.web.authenticationMode") == "token")

        await model.setEnabled(true)
        model.updatePreferences(WebServerPreferences(port: 9999))
        #expect(model.preferences == chosen)
    }

    @Test("the user can revoke the current token while the server is off")
    func tokenCanBeRegeneratedWhileOff() async {
        let process = FakeWebServerProcess()
        let model = makeModel(process: process)

        model.regenerateAccessToken()

        #expect(model.accessToken != "unit-test-access-token")
        #expect(model.accessToken.count == 64)

        await model.setEnabled(true)
        let runningToken = model.accessToken
        model.regenerateAccessToken()
        #expect(model.accessToken == runningToken)
    }

    @Test("a missing release runtime asks before downloading and then enables")
    func runtimeDownloadRequiresConsent() async throws {
        let fixture = try RuntimeDistributionFixture()
        let offer = WebRuntimeDownloadOffer(release: try fixture.verifiedRelease())
        let manager = FakeWebRuntimeManager(
            inspection: .notInstalled,
            offer: offer,
            installedRuntime: installedRuntime()
        )
        let process = FakeWebServerProcess()
        let model = makeDistributionModel(process: process, manager: manager, fixture: fixture)

        await model.setEnabled(true)

        #expect(!model.isEnabled)
        #expect(model.state == .off)
        #expect(model.pendingRuntimeDownloadOffer == offer)
        #expect(await process.snapshot().configurations.isEmpty)
        #expect(await manager.snapshot() == .init(inspections: 1, resolves: 1, installs: 0))

        await model.downloadPendingRuntimeAndEnable()

        #expect(model.isEnabled)
        #expect(model.state == .running)
        #expect(model.pendingRuntimeDownloadOffer == nil)
        #expect(await manager.snapshot() == .init(inspections: 1, resolves: 1, installs: 1))
        let launch = try #require(await process.snapshot().configurations.last)
        #expect(launch.executableURL.path == "/verified/runtime/scanstudio-web")
    }

    @Test("dismissing consent never downloads executable code")
    func runtimeDownloadConsentCanBeCancelled() async throws {
        let fixture = try RuntimeDistributionFixture()
        let offer = WebRuntimeDownloadOffer(release: try fixture.verifiedRelease())
        let manager = FakeWebRuntimeManager(
            inspection: .notInstalled,
            offer: offer,
            installedRuntime: installedRuntime()
        )
        let process = FakeWebServerProcess()
        let model = makeDistributionModel(process: process, manager: manager, fixture: fixture)

        await model.setEnabled(true)
        model.cancelRuntimeDownloadOffer()

        #expect(model.pendingRuntimeDownloadOffer == nil)
        #expect(!model.isEnabled)
        #expect(await manager.snapshot().installs == 0)
        #expect(await process.snapshot().configurations.isEmpty)
    }

    @Test("affirmative consent survives dialog dismissal")
    func acceptedConsentSurvivesDialogDismissal() async throws {
        let fixture = try RuntimeDistributionFixture()
        let offer = WebRuntimeDownloadOffer(release: try fixture.verifiedRelease())
        let manager = FakeWebRuntimeManager(
            inspection: .notInstalled,
            offer: offer,
            installedRuntime: installedRuntime()
        )
        let process = FakeWebServerProcess()
        let model = makeDistributionModel(process: process, manager: manager, fixture: fixture)
        await model.setEnabled(true)

        model.acceptPendingRuntimeDownloadAndEnable()
        model.cancelRuntimeDownloadOffer()
        await waitUntil { model.state == .running }

        #expect(model.isEnabled)
        #expect(await manager.snapshot().installs == 1)
    }

    @Test("turning off during accepted-offer cleanup prevents installation")
    func acceptedConsentCanBeCancelledBeforeInstall() async throws {
        let fixture = try RuntimeDistributionFixture()
        let offer = WebRuntimeDownloadOffer(release: try fixture.verifiedRelease())
        let manager = FakeWebRuntimeManager(
            inspection: .notInstalled,
            offer: offer,
            installedRuntime: installedRuntime()
        )
        let process = FakeWebServerProcess()
        let model = makeDistributionModel(process: process, manager: manager, fixture: fixture)
        await model.setEnabled(true)

        model.acceptPendingRuntimeDownloadAndEnable()
        await model.setEnabled(false)
        await Task.yield()

        #expect(model.state == .off)
        #expect(!model.isEnabled)
        #expect(await manager.snapshot().installs == 0)
        #expect(await process.snapshot().configurations.isEmpty)
    }

    @Test("a launch-verified cached runtime starts without a network offer")
    func verifiedRuntimeStartsWithoutDownload() async throws {
        let fixture = try RuntimeDistributionFixture()
        let installed = installedRuntime()
        let manager = FakeWebRuntimeManager(
            inspection: .ready(installed),
            offer: WebRuntimeDownloadOffer(release: try fixture.verifiedRelease()),
            installedRuntime: installed
        )
        let process = FakeWebServerProcess()
        let model = makeDistributionModel(process: process, manager: manager, fixture: fixture)

        await model.setEnabled(true)

        #expect(model.state == .running)
        #expect(model.pendingRuntimeDownloadOffer == nil)
        #expect(await manager.snapshot() == .init(inspections: 1, resolves: 0, installs: 0))
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

    @Test("app termination cancels and waits for runtime provisioning cleanup")
    func applicationTerminationCancelsRuntimeProvisioning() async throws {
        let fixture = try RuntimeDistributionFixture()
        let offer = WebRuntimeDownloadOffer(release: try fixture.verifiedRelease())
        let manager = CancellableWebRuntimeManager(
            offer: offer,
            installedRuntime: installedRuntime()
        )
        let process = FakeWebServerProcess()
        let model = makeDistributionModel(
            process: process,
            manager: manager,
            fixture: fixture
        )
        await model.setEnabled(true)
        model.acceptPendingRuntimeDownloadAndEnable()
        for _ in 0..<100 {
            if await manager.snapshot().installStarted { break }
            await Task.yield()
        }
        #expect(await manager.snapshot().installStarted)

        let clock = ContinuousClock()
        let started = clock.now
        await model.stopProcessForApplicationTermination()
        let elapsed = started.duration(to: clock.now)
        await waitUntil { model.state == .off }

        #expect(await manager.snapshot().cancellationObserved)
        #expect(elapsed < .seconds(2))
        #expect(!model.isEnabled)
        #expect(await process.snapshot().configurations.isEmpty)
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
                "PYTHONPATH": "/untrusted/modules",
                "DYLD_LIBRARY_PATH": "/untrusted/libraries",
                "PRESERVED": "yes",
                "SCANSTUDIO_TIMESCALE": "0.05",
            ],
            privateLANAddresses: { ["192.168.50.4", "fd12:3456::4"] },
            runtimeResolver: { self.runtime },
            tokenGenerator: { "unit-test-access-token" }
        )
    }

    private func makeDistributionModel(
        process: FakeWebServerProcess,
        manager: any WebRuntimeManaging,
        fixture: RuntimeDistributionFixture
    ) -> WebServerModel {
        WebServerModel(
            engineURL: engineURL,
            process: process,
            readinessChecker: FakeWebServerReadiness(),
            inheritedEnvironment: [:],
            runtimeManager: manager,
            runtimeRequest: fixture.request,
            runtimeResolver: {
                throw WebServerRuntimeLocateError.runtimeUnavailable(
                    commandPaths: [],
                    staticPaths: []
                )
            },
            tokenGenerator: { "unit-test-access-token" }
        )
    }

    private func installedRuntime() -> InstalledWebRuntime {
        InstalledWebRuntime(
            hostVersion: "1.2.3-beta.1",
            runtimeVersion: "1.2.3-beta.1",
            architecture: .arm64,
            rootURL: URL(fileURLWithPath: "/verified/runtime", isDirectory: true),
            executableURL: URL(fileURLWithPath: "/verified/runtime/scanstudio-web"),
            staticDirectoryURL: URL(fileURLWithPath: "/verified/runtime/static", isDirectory: true),
            codeIdentity: WebRuntimeCodeIdentityAssertion(
                bundleIdentifier: "dev.scanstudio.live.web-runtime",
                teamIdentifier: "TEAMID1234",
                developerIDSigned: true,
                notarized: true
            )
        )
    }

    private func waitForObserver() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for browser preview state")
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

private actor FakeWebRuntimeManager: WebRuntimeManaging {
    struct Snapshot: Equatable {
        let inspections: Int
        let resolves: Int
        let installs: Int
    }

    private let inspection: WebRuntimeInspection
    private let offer: WebRuntimeDownloadOffer
    private let installedRuntime: InstalledWebRuntime
    private var inspections = 0
    private var resolves = 0
    private var installs = 0

    init(
        inspection: WebRuntimeInspection,
        offer: WebRuntimeDownloadOffer,
        installedRuntime: InstalledWebRuntime
    ) {
        self.inspection = inspection
        self.offer = offer
        self.installedRuntime = installedRuntime
    }

    func inspectVerifiedCurrent(
        for request: WebRuntimeReleaseRequest
    ) -> WebRuntimeInspection {
        inspections += 1
        return inspection
    }

    func resolveMetadataForConsent(
        for request: WebRuntimeReleaseRequest
    ) -> WebRuntimeDownloadOffer {
        resolves += 1
        return offer
    }

    func install(
        _ offer: WebRuntimeDownloadOffer,
        progress: @escaping @Sendable (WebRuntimeInstallProgress) -> Void
    ) -> WebServerRuntime {
        installs += 1
        for phase in [
            WebRuntimeInstallProgress.downloading,
            .preparing,
            .installing,
            .verifyingForLaunch,
            .complete,
        ] {
            progress(phase)
        }
        return installedRuntime.webServerRuntime
    }

    func runtimeForLaunch(
        for request: WebRuntimeReleaseRequest
    ) -> WebServerRuntime {
        installedRuntime.webServerRuntime
    }

    func snapshot() -> Snapshot {
        Snapshot(inspections: inspections, resolves: resolves, installs: installs)
    }
}

private actor CancellableWebRuntimeManager: WebRuntimeManaging {
    struct Snapshot: Sendable {
        let installStarted: Bool
        let cancellationObserved: Bool
    }

    private let offer: WebRuntimeDownloadOffer
    private let installedRuntime: InstalledWebRuntime
    private var installStarted = false
    private var cancellationObserved = false

    init(offer: WebRuntimeDownloadOffer, installedRuntime: InstalledWebRuntime) {
        self.offer = offer
        self.installedRuntime = installedRuntime
    }

    func inspectVerifiedCurrent(
        for request: WebRuntimeReleaseRequest
    ) -> WebRuntimeInspection {
        .notInstalled
    }

    func resolveMetadataForConsent(
        for request: WebRuntimeReleaseRequest
    ) -> WebRuntimeDownloadOffer {
        offer
    }

    func install(
        _ offer: WebRuntimeDownloadOffer,
        progress: @escaping @Sendable (WebRuntimeInstallProgress) -> Void
    ) async throws -> WebServerRuntime {
        installStarted = true
        progress(.downloading)
        do {
            try await Task.sleep(for: .seconds(30))
            return installedRuntime.webServerRuntime
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
    }

    func runtimeForLaunch(
        for request: WebRuntimeReleaseRequest
    ) -> WebServerRuntime {
        installedRuntime.webServerRuntime
    }

    func snapshot() -> Snapshot {
        Snapshot(
            installStarted: installStarted,
            cancellationObserved: cancellationObserved
        )
    }
}
