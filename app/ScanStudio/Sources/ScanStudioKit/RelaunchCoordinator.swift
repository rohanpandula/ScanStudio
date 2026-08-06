// Relaunches the installed app after a completed update. `AppRelaunching` is
// the process-spawning seam (mirrors `URLSessionProtocol`'s role for network
// calls): the real implementation lives in the executable target
// (Sources/ScanStudio) since spawning a process and quitting the running app
// are host/AppKit concerns, not ScanStudioKit's. `RelaunchCoordinator`
// carries only the routing decision -- refuse while a scan/preview job is
// active (the same guard `UpdateFlowModel.install()` already applies),
// otherwise call the injected relauncher exactly once -- so that guard is
// directly unit testable with a fake here, without ever spawning a real
// process or quitting anything during a test run.

import Foundation

/// Spawns a fresh process for the app at `appURL`. The caller is
/// responsible for terminating the current process afterward; this
/// protocol's only job is starting the new one.
public protocol AppRelaunching: Sendable {
    func relaunch(appURL: URL) throws
}

/// Typed relaunch failures.
public enum RelaunchError: Error, Equatable {
    /// Refused because a scan/preview job is active.
    case jobActive
    /// The injected `AppRelaunching` failed to spawn the new process.
    case launchFailed
}

@MainActor
public final class RelaunchCoordinator {
    private let relauncher: any AppRelaunching

    public init(relauncher: any AppRelaunching) {
        self.relauncher = relauncher
    }

    /// Attempts to relaunch `appURL`. Refuses -- without calling the
    /// relauncher at all -- while `jobActive`, mirroring the install guard.
    public func relaunch(appURL: URL, jobActive: Bool) throws {
        guard !jobActive else { throw RelaunchError.jobActive }
        do {
            try relauncher.relaunch(appURL: appURL)
        } catch {
            throw RelaunchError.launchFailed
        }
    }
}
