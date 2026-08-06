// Launch-time update offer: decides whether to run the once-per-launch
// update check and whether to surface a visible "Update Now" / "Not Now"
// offer. Split out from the host `UpdateFlowModel` (Sources/ScanStudio) so
// the rule that matters most -- the launch-check setting being off means
// literally no network call, not just a suppressed UI -- is directly unit
// testable here with an injected `UpdateChecking` fake, the same seam
// `GitHubUpdateChecker`/`UpdateFlowModel` already use. This type never
// installs anything itself: "Update Now" hands the candidate back to the
// caller, which routes it into the existing `UpdateFlowModel.install()`
// flow (the job-active guard stays there, unchanged).

import Foundation

/// The outcome of a launch-time offer check.
public enum LaunchUpdateOffer: Equatable, Sendable {
    case none
    case available(UpdateCandidate)

    /// The candidate to install, if one is currently offered.
    public var candidate: UpdateCandidate? {
        if case .available(let candidate) = self { return candidate }
        return nil
    }
}

/// Runs the launch-time offer check at most once per instance (the host
/// creates one instance per app run) and remembers whether the resulting
/// offer has already been shown/dismissed, so nothing re-nags the user
/// within the same launch.
@MainActor
public final class LaunchUpdateOfferModel {
    private let checker: any UpdateChecking
    private let installedVersion: UpdateVersion

    /// The current offer. `.none` before the check has run, when the
    /// launch-check setting was off, when nothing strictly newer was found,
    /// on any checker failure, after "Not Now", and after the candidate is
    /// consumed for install.
    public private(set) var offer: LaunchUpdateOffer = .none

    /// Latches true the first time `checkAtLaunch` runs its gate (whether or
    /// not it was enabled). Once true, every later call is a no-op -- this
    /// is both "at most one network call per launch" and "Not Now never
    /// re-offers within the same session (instance) lifetime" in one guard.
    private var hasCheckedThisLaunch = false

    public init(checker: any UpdateChecking, installedVersion: UpdateVersion) {
        self.checker = checker
        self.installedVersion = installedVersion
    }

    /// Performs the once-per-launch check for `channel` when
    /// `launchCheckEnabled` is true. When `false`, or when this instance has
    /// already run its launch check once, this makes NO call into `checker`
    /// at all -- the gate sits before the network call, not after it. Never
    /// throws; a transport/decode failure or a candidate that is not
    /// strictly newer than `installedVersion` both resolve to `.none`,
    /// exactly like "no update" everywhere else in the update flow.
    public func checkAtLaunch(launchCheckEnabled: Bool, channel: UpdateChannel) async {
        guard launchCheckEnabled, !hasCheckedThisLaunch else { return }
        hasCheckedThisLaunch = true
        guard
            let candidate = try? await checker.latestCandidate(channel: channel),
            installedVersion < candidate.version
        else {
            offer = .none
            return
        }
        offer = .available(candidate)
    }

    /// "Not Now": clears the current offer. `hasCheckedThisLaunch` is
    /// already latched by the check that produced it, so no later call to
    /// `checkAtLaunch` in this instance's lifetime can bring it back.
    public func dismiss() {
        offer = .none
    }

    /// "Update Now": returns the offered candidate for the caller to install
    /// and clears the offer so it cannot be shown or consumed twice. `nil`
    /// when nothing is currently offered.
    public func consumeForInstall() -> UpdateCandidate? {
        defer { offer = .none }
        return offer.candidate
    }
}
