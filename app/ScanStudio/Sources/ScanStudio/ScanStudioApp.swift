// App entry point. Constructs the `EngineClient` + `SessionModel` once,
// during `AppDelegate` construction (which `@NSApplicationDelegateAdaptor`
// guarantees happens before the window's first render), and fixes SPM's
// well-known foregrounding gap (D-13): apps launched via `swift run` do not
// activate/foreground themselves without an explicit activation-policy +
// activate call.

import AppKit
import ScanStudioKit
import SwiftUI

@main
struct ScanStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Scan Studio") {
            switch appDelegate.launchState {
            case .ready(_, let model):
                ContentView()
                    .environment(model)
            case .failed(let message):
                EngineUnavailableView(message: message)
            }
        }
        .defaultSize(width: 1_500, height: 920)
        .windowResizability(.contentMinSize)
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

    override init() {
        do {
            let engineURL = try EngineLocator.locate()
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
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SPM-run apps do not foreground correctly without this.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.applyDockIcon()
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
        guard case .ready(let client, _) = launchState else { return }
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await client.terminate()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 2)
    }

    private static func describe(_ error: Error) -> String {
        if let locateError = error as? EngineLocator.LocateError {
            return locateError.message
        }
        return String(describing: error)
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
