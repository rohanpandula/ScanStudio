// App entry point. Constructs the `EngineClient` + `SessionModel` once,
// during `AppDelegate` construction (which `@NSApplicationDelegateAdaptor`
// guarantees happens before the window's first render), and fixes SPM's
// well-known foregrounding gap (D-13): apps launched via `swift run` do not
// activate/foreground themselves without an explicit activation-policy +
// activate call.

import AppKit
import Observation
import ScanStudioKit
import SwiftUI

private struct ScanStudioFrameFocusKey: FocusedValueKey {
    typealias Value = Int
}

extension FocusedValues {
    var scanStudioFrameIndex: Int? {
        get { self[ScanStudioFrameFocusKey.self] }
        set { self[ScanStudioFrameFocusKey.self] = newValue }
    }
}

@main
struct ScanStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One process owns one physical scanner session. A single window also
        // makes the focused Photo commands unambiguous: there is no second
        // scene that can publish a competing focused frame.
        Window("Scan Studio", id: "main") {
            Group {
                switch appDelegate.launchState {
                case .ready(_, let model):
                    ContentView()
                        .environment(model)
                case .failed(let message):
                    EngineUnavailableView(message: message)
                }
            }
            .launchUpdateOfferAlert(appDelegate.updateFlowModel)
        }
        .defaultSize(width: 1_500, height: 920)
        .windowResizability(.contentMinSize)
        .commands {
            if case .ready(_, let model) = appDelegate.launchState {
                FrameTransformCommands(session: model)
            }
        }

        Settings {
            UpdateSettingsView(
                model: appDelegate.updateFlowModel,
                webServerModel: appDelegate.webServerModel
            )
        }
    }
}

private extension View {
    /// The launch-time "Update Now" / "Not Now" offer (feat/launch-update-offer,
    /// item 1): a native alert. The app's one existing notice idiom
    /// (`WorkspaceErrorBanner` in ContentView.swift) is purpose-built for
    /// `SessionModel` scan/preview errors -- it needs a `SessionModel` in the
    /// environment, which does not exist while `launchState == .failed`, and
    /// its red "something went wrong" styling and issue-report action do not
    /// fit an informational "there's a new version" notice. A plain alert
    /// covers both launch states from one place at the Window scene level and
    /// matches the two-action (primary / cancel) confirmation shape already
    /// used elsewhere (e.g. `AcquirePreviewConfirmationSheet`).
    func launchUpdateOfferAlert(_ model: UpdateFlowModel) -> some View {
        alert(
            "Update Available",
            isPresented: Binding(
                get: { model.launchUpdateOffer != nil },
                set: { isPresented in
                    if !isPresented {
                        model.dismissLaunchUpdateOffer()
                    }
                }
            ),
            presenting: model.launchUpdateOffer
        ) { _ in
            Button("Update Now") {
                Task { await model.installFromLaunchUpdateOffer() }
            }
            Button("Not Now", role: .cancel) {
                model.dismissLaunchUpdateOffer()
            }
        } message: { candidate in
            Text("Scan Studio \(candidate.version.raw) is available.")
        }
    }
}

/// Global commands cannot live inside a closed contact-sheet `Menu`: live
/// validation proved SwiftUI does not register those nested shortcuts until
/// the menu is open. A scene-level Photo menu keeps the commands active from
/// both the contact sheet and frame-detail workspace.
private struct FrameTransformCommands: Commands {
    let session: SessionModel
    @FocusedValue(\.scanStudioFrameIndex) private var activeFrameIndex

    var body: some Commands {
        CommandMenu("Photo") {
            Button("Rotate Focused Photo Left") {
                perform(.rotateLeft)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(activeFrameIndex == nil)

            Button("Rotate Focused Photo Right") {
                perform(.rotateRight)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(activeFrameIndex == nil)

            Divider()

            Button("Flip Focused Photo Left to Right") {
                perform(.flipLeftToRight)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(activeFrameIndex == nil)

            Button("Flip Focused Photo Top to Bottom") {
                perform(.flipTopToBottom)
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(activeFrameIndex == nil)
        }
    }

    private func perform(_ command: FrameTransformCommand) {
        guard let activeFrameIndex else { return }
        session.performFrameTransformCommand(command, for: activeFrameIndex)
    }
}

/// The real `AppRelaunching`: spawns a detached new process for the app at
/// `appURL` via `/usr/bin/open -n`, so the fresh instance is independent of
/// the quitting one. `UpdateFlowModel.relaunchToFinishUpdate()` only calls
/// `NSApp.terminate` after this returns without throwing. Kept in the
/// executable target -- spawning a process and quitting the running app are
/// host/AppKit concerns -- with only the guard/routing logic (`RelaunchCoordinator`)
/// living in ScanStudioKit, where it is unit tested with a fake instead.
private struct ProcessAppRelauncher: AppRelaunching {
    func relaunch(appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path]
        try process.run()
    }
}

/// What `ScanStudioApp` could build at launch: either a working
/// `EngineClient`/`SessionModel` pair, or — if `EngineLocator.locate()`
/// threw — a message describing exactly why, surfaced in the window rather
/// than crashing or exiting silently (D-05 requires the failure to be
/// user-visible).
enum LaunchState {
    case ready(client: EngineClient, model: SessionModel)
    case failed(message: String)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let launchState: LaunchState
    /// Shared in-app update flow (01-05): one instance per app run, handed to
    /// the Settings scene and the launch + 24 h background check.
    let updateFlowModel: UpdateFlowModel
    /// Optional, session-only browser preview. It always starts off and owns a
    /// separate simulator engine; it never shares the native scanner session.
    let webServerModel: WebServerModel
    /// Cancellable handle for the rolling 24 h background check task.
    private var backgroundUpdateTask: Task<Void, Never>?

    override init() {
        var browserEngineURL: URL?
        do {
            let engineURL = try EngineLocator.locate()
            browserEngineURL = engineURL
            let client = try EngineClient(engineURL: engineURL)
            let diagnosticsDirectory = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".scanstudio/diagnostics", isDirectory: true)
            let model = SessionModel(
                engineClient: client,
                diagnosticsDirectory: diagnosticsDirectory
            )
            launchState = .ready(client: client, model: model)
        } catch {
            launchState = .failed(message: AppDelegate.describe(error))
        }

        updateFlowModel = Self.makeUpdateFlowModel()
        let webRuntimeServices = Self.makeWebRuntimeServices()
        webServerModel = WebServerModel(
            engineURL: browserEngineURL,
            runtimeManager: webRuntimeServices?.manager,
            runtimeRequest: webRuntimeServices?.request
        )
        super.init()

        // AUT-05-GUARD: mirror the real job-active signal into the update flow
        // so no install is offered or run during an active scan/preview. When
        // the engine failed to launch there is no SessionModel, and `jobActive`
        // stays false -- with no connected scanner there is nothing to guard.
        if case .ready(_, let session) = launchState {
            Self.bindJobActivity(of: session, into: updateFlowModel)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SPM-run apps do not foreground correctly without this.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.applyDockIcon()
        startUpdateCheckLoops()
    }

    /// Packaged apps place resources directly in `Contents/Resources`. Source
    /// builds may run without a Dock icon; never embed SwiftPM's build-path
    /// resource fallback in the distributable executable.
    private static func applyDockIcon() {
        guard
            let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else {
            // Non-fatal by design: a missing icon must never block launch.
            return
        }
        NSApp.applicationIconImage = icon
    }

    func applicationWillTerminate(_ notification: Notification) {
        backgroundUpdateTask?.cancel()
        let client: EngineClient?
        if case .ready(let readyClient, _) = launchState {
            client = readyClient
        } else {
            client = nil
        }
        let finished = DispatchSemaphore(value: 0)
        let webServerModel = webServerModel
        Task.detached {
            // AppKit is synchronously waiting on the main thread here, so use
            // the model's nonisolated process hook. The bounded process
            // controller escalates after its graceful-shutdown window, which
            // prevents a gateway from outliving Scan Studio.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await webServerModel.stopProcessForApplicationTermination()
                }
                if let client {
                    group.addTask {
                        await client.terminate()
                    }
                }
            }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 6)
    }

    private static func describe(_ error: Error) -> String {
        if let locateError = error as? EngineLocator.LocateError {
            return locateError.message
        }
        return String(describing: error)
    }

    /// The ordinary app release contains no browser-runtime executable. If a
    /// release opts into publishing the separate component, packaging stamps
    /// only its public verification key and Developer ID Team ID. Missing or
    /// malformed trust metadata keeps on-demand installation unavailable;
    /// source builds can still use the explicitly development-only locator.
    private static func makeWebRuntimeServices() -> WebRuntimeHostServices? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return try? WebRuntimeHostBootstrap.makeServices(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            applicationSupportDirectory: applicationSupport,
            cachesDirectory: caches
        )
    }

    // MARK: - Update wiring (01-05)

    /// The versionless `latest.json` pointer. GitHub exposes assets of the
    /// newest non-prerelease release at `releases/latest/download/<asset>`.
    /// Alpha pre-releases are additionally probed via the API by the checker
    /// (01-04), so this URL plus the API probe covers both channels.
    private static let updatePointerURL = URL(
        string: "https://github.com/rohanpandula/ScanStudio/releases/latest/download/latest.json"
    )!

    /// Constructs the single shared `UpdateFlowModel`: the 01-03 install core
    /// pointed at `/Applications`, the 01-04 checker/downloader against the
    /// feed, and an installed version stamped from `Info.plist` (or an
    /// always-up-to-date sentinel for unstamped dev builds, T-01-05-02).
    private static func makeUpdateFlowModel() -> UpdateFlowModel {
        let supportURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/ScanStudio",
                isDirectory: true
            )
        let rollbackDirectory = supportURL.appendingPathComponent("Rollback", isDirectory: true)
        // The rollback directory is created up front: `UpdateInstaller` only
        // rejects non-existent directories, and `/Applications` always exists
        // on macOS, so this construction cannot throw once the directory
        // exists.
        try? FileManager.default.createDirectory(
            at: rollbackDirectory,
            withIntermediateDirectories: true
        )
        let installer = try! UpdateInstaller(
            appDirectory: URL(fileURLWithPath: "/Applications", isDirectory: true),
            rollbackDirectory: rollbackDirectory
        )
        return UpdateFlowModel(
            checker: GitHubUpdateChecker(pointerURL: Self.updatePointerURL),
            downloader: UpdateDownloader(),
            installer: installer,
            installedVersion: Self.installedUpdateVersion(),
            channelDefaultsKey: "ScanStudio.updateChannel",
            launchCheckEnabledDefaultsKey: "ScanStudio.checkForUpdatesAtLaunch",
            relauncher: ProcessAppRelauncher()
        )
    }

    /// The running app's version: the packaged `ScanStudioRelease` stamp, or
    /// an always-up-to-date sentinel for unstamped source/dev builds so a dev
    /// build is never offered as an install target (T-01-05-02).
    private static func installedUpdateVersion() -> UpdateVersion {
        if let stamp = Bundle.main.infoDictionary?["ScanStudioRelease"] as? String,
           !stamp.isEmpty,
           let version = UpdateVersion(raw: stamp) {
            return version
        }
        return UpdateVersion(raw: "999.0.0")!
    }

    /// Mirrors `SessionModel.isJobActive` into `model.jobActive` and re-arms
    /// the observation after every change, so the AUT-05-GUARD stays live for
    /// the whole run without polling.
    private static func bindJobActivity(of session: SessionModel, into model: UpdateFlowModel) {
        let isActive = withObservationTracking {
            MainActor.assumeIsolated { session.isJobActive }
        } onChange: {
            Task { @MainActor [weak model] in
                guard let model else { return }
                model.jobActive = session.isJobActive
                Self.bindJobActivity(of: session, into: model)
            }
        }
        model.jobActive = isActive
    }

    /// Kicks the update cadence (AUT-05-CHECK): one check at launch, then one
    /// every 24 h via a rolling `Task.sleep`. Read-only plumbing -- neither
    /// leg downloads or installs, and the 24 h leg skips a beat while an
    /// install is already in flight.
    ///
    /// The launch leg (feat/launch-update-offer) is gated on the "Check for
    /// updates at launch" setting and, when it finds something newer, also
    /// drives the visible launch-time offer -- see
    /// `UpdateFlowModel.checkForUpdateAtLaunch()`. The 24 h leg below is
    /// untouched: it always runs, regardless of that setting.
    private func startUpdateCheckLoops() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.updateFlowModel.checkForUpdateAtLaunch()
        }
        backgroundUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // 24 h between checks (AUT-05-CHECK). `Duration` has no
                    // `.hours` member, so spell it in seconds.
                    try await Task.sleep(for: .seconds(24 * 60 * 60))
                } catch {
                    break
                }
                guard let self, self.updateFlowModel.installProgress == nil else {
                    continue
                }
                await self.updateFlowModel.checkNow()
            }
        }
    }
}

private struct EngineUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Scan Studio engine unavailable")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 320)
    }
}
