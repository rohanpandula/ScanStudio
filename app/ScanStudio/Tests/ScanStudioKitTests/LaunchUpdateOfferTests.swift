// Offline tests for the launch-time update offer (feat/launch-update-offer):
// the toggle gate must sit BEFORE the network call (not after, as a
// suppressed UI would), an equal-version candidate must never be offered,
// and "Not Now" must not re-offer within the same instance's lifetime.
// Mirrors UpdateVersionTests/UpdateServiceTests' offline, injected-fake
// style: a private fake `UpdateChecking` stands in for `GitHubUpdateChecker`
// so no case ever touches the network.

import XCTest

@testable import ScanStudioKit

@MainActor
final class LaunchUpdateOfferTests: XCTestCase {
    private func candidate(_ version: String) -> UpdateCandidate {
        UpdateCandidate(
            version: UpdateVersion(raw: version)!,
            downloadURL: URL(string: "https://example.com/ScanStudio.dmg")!,
            sha256: String(repeating: "a", count: 64),
            releaseNotesURL: nil
        )
    }

    // MARK: - Shown when enabled + newer

    func testOfferShownWhenLaunchCheckEnabledAndCandidateIsNewer() async {
        let checker = FakeUpdateChecker()
        checker.candidateToReturn = candidate("0.4.0")
        let model = LaunchUpdateOfferModel(checker: checker, installedVersion: UpdateVersion(raw: "0.3.0")!)

        await model.checkAtLaunch(launchCheckEnabled: true, channel: .stable)

        XCTAssertEqual(model.offer, .available(candidate("0.4.0")))
        XCTAssertEqual(checker.callCount, 1)
    }

    // MARK: - Suppressed when the toggle is off: NO network call at all

    func testOfferSuppressedWhenLaunchCheckDisabledMakesNoNetworkCall() async {
        let checker = FakeUpdateChecker()
        checker.candidateToReturn = candidate("0.4.0")
        let model = LaunchUpdateOfferModel(checker: checker, installedVersion: UpdateVersion(raw: "0.3.0")!)

        await model.checkAtLaunch(launchCheckEnabled: false, channel: .stable)

        XCTAssertEqual(model.offer, .none)
        XCTAssertEqual(checker.callCount, 0, "the toggle being off must never reach the checker")
    }

    // MARK: - Suppressed when the candidate equals the installed version

    func testOfferSuppressedWhenCandidateEqualsInstalled() async {
        let checker = FakeUpdateChecker()
        checker.candidateToReturn = candidate("0.3.0")
        let model = LaunchUpdateOfferModel(checker: checker, installedVersion: UpdateVersion(raw: "0.3.0")!)

        await model.checkAtLaunch(launchCheckEnabled: true, channel: .stable)

        XCTAssertEqual(model.offer, .none)
    }

    // MARK: - "Not Now" never re-offers within the same session (instance) lifetime

    func testNotNowDoesNotReofferWithinTheSameSessionLifetime() async {
        let checker = FakeUpdateChecker()
        checker.candidateToReturn = candidate("0.4.0")
        let model = LaunchUpdateOfferModel(checker: checker, installedVersion: UpdateVersion(raw: "0.3.0")!)

        await model.checkAtLaunch(launchCheckEnabled: true, channel: .stable)
        XCTAssertEqual(model.offer, .available(candidate("0.4.0")))

        model.dismiss()
        XCTAssertEqual(model.offer, .none)

        // A later call on the SAME instance (e.g. if the launch call site
        // were ever invoked twice in one run) must neither resurrect the
        // offer nor hit the network again.
        await model.checkAtLaunch(launchCheckEnabled: true, channel: .stable)

        XCTAssertEqual(model.offer, .none)
        XCTAssertEqual(checker.callCount, 1, "a dismissed offer must not trigger a second check")
    }

    // MARK: - At most one network call per instance, even without a dismissal

    func testCheckAtLaunchRunsAtMostOncePerInstance() async {
        let checker = FakeUpdateChecker()
        checker.candidateToReturn = candidate("0.4.0")
        let model = LaunchUpdateOfferModel(checker: checker, installedVersion: UpdateVersion(raw: "0.3.0")!)

        await model.checkAtLaunch(launchCheckEnabled: true, channel: .stable)
        await model.checkAtLaunch(launchCheckEnabled: true, channel: .stable)

        XCTAssertEqual(checker.callCount, 1)
    }

    // MARK: - consumeForInstall hands the candidate over exactly once

    func testConsumeForInstallReturnsAndClearsTheOffer() async {
        let checker = FakeUpdateChecker()
        checker.candidateToReturn = candidate("0.4.0")
        let model = LaunchUpdateOfferModel(checker: checker, installedVersion: UpdateVersion(raw: "0.3.0")!)
        await model.checkAtLaunch(launchCheckEnabled: true, channel: .stable)

        let consumed = model.consumeForInstall()

        XCTAssertEqual(consumed, candidate("0.4.0"))
        XCTAssertEqual(model.offer, .none)
        XCTAssertNil(model.consumeForInstall(), "a second consume must find nothing left to take")
    }

    // MARK: - A checker failure degrades to "no offer", never a crash

    func testOfferStaysNoneOnCheckerFailure() async {
        let checker = FakeUpdateChecker()
        checker.errorToThrow = URLError(.notConnectedToInternet)
        let model = LaunchUpdateOfferModel(checker: checker, installedVersion: UpdateVersion(raw: "0.3.0")!)

        await model.checkAtLaunch(launchCheckEnabled: true, channel: .stable)

        XCTAssertEqual(model.offer, .none)
        XCTAssertEqual(checker.callCount, 1)
    }
}

/// Fake `UpdateChecking` conformer: answers a canned candidate/error and
/// counts calls, so tests can assert the toggle gate stops the call from
/// ever reaching the checker (rather than only suppressing its result).
private final class FakeUpdateChecker: UpdateChecking, @unchecked Sendable {
    var candidateToReturn: UpdateCandidate?
    var errorToThrow: Error?
    private(set) var callCount = 0

    func latestCandidate(channel: UpdateChannel) async throws -> UpdateCandidate? {
        callCount += 1
        if let errorToThrow {
            throw errorToThrow
        }
        return candidateToReturn
    }
}
