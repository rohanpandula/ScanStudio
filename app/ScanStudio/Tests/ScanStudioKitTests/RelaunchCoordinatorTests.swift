// Offline tests for RelaunchCoordinator (field fix: "Restart to finish" was
// inert text with no wired action -- see UpdateFlowModel.relaunchToFinishUpdate()
// and ProcessAppRelauncher). The real process spawn is never exercised here:
// a fake `AppRelaunching` stands in so the test asserts the call/guard
// instead of actually spawning and quitting a process.

import XCTest

@testable import ScanStudioKit

@MainActor
final class RelaunchCoordinatorTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/ScanStudio.app", isDirectory: true)

    func testRelaunchCallsTheInjectedRelauncherWithTheGivenURL() throws {
        let relauncher = FakeAppRelauncher()
        let coordinator = RelaunchCoordinator(relauncher: relauncher)

        try coordinator.relaunch(appURL: appURL, jobActive: false)

        XCTAssertEqual(relauncher.requestedURLs, [appURL])
    }

    func testRelaunchRefusesWhileJobActiveAndNeverCallsTheRelauncher() {
        let relauncher = FakeAppRelauncher()
        let coordinator = RelaunchCoordinator(relauncher: relauncher)

        XCTAssertThrowsError(try coordinator.relaunch(appURL: appURL, jobActive: true)) { error in
            XCTAssertEqual(error as? RelaunchError, .jobActive)
        }
        XCTAssertTrue(relauncher.requestedURLs.isEmpty, "a job-active refusal must never reach the relauncher")
    }

    func testRelaunchSurfacesATypedErrorWhenTheRelauncherFails() {
        let relauncher = FakeAppRelauncher()
        relauncher.errorToThrow = NSError(domain: "test", code: 1)
        let coordinator = RelaunchCoordinator(relauncher: relauncher)

        XCTAssertThrowsError(try coordinator.relaunch(appURL: appURL, jobActive: false)) { error in
            XCTAssertEqual(error as? RelaunchError, .launchFailed)
        }
        XCTAssertEqual(relauncher.requestedURLs, [appURL], "the relauncher was still called once before failing")
    }
}

/// Fake `AppRelaunching`: records every call instead of spawning a real
/// process, so tests never launch or quit a second ScanStudio instance.
/// `requestedURLs` records the call itself, independent of whether it then
/// succeeds or throws, so a failure test can still assert the attempt.
private final class FakeAppRelauncher: AppRelaunching, @unchecked Sendable {
    private(set) var requestedURLs: [URL] = []
    var errorToThrow: Error?

    func relaunch(appURL: URL) throws {
        requestedURLs.append(appURL)
        if let errorToThrow {
            throw errorToThrow
        }
    }
}
