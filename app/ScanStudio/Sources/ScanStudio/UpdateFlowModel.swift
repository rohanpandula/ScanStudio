// In-app update flow (01-05): the host-owned model behind the Settings scene.
// Renders honest check/install/rollback state and enforces the AUT-05-GUARD:
// no install while a scan/preview job is active. The model itself never
// relaunches the app, never auto-installs, and never touches the scanner --
// it only mutates observable state and drives the 01-03/01-04 services on
// explicit user action. Relaunch wiring is deliberately out of scope here and
// left to explicit user confirmation ("Restart to finish"), per the plan.

import Foundation
import Observation
import ScanStudioKit

/// The visible outcomes of an update check. "No update" and "error" are
/// deliberately distinct so the UI never presents a failure as success.
enum UpdateCheckState: Equatable {
    case idle
    case checking
    case updateAvailable(UpdateCandidate)
    case upToDate
    case failed(String)
}

@MainActor
@Observable
final class UpdateFlowModel {
    /// Feed client (01-04): resolves the newest candidate for a channel.
    private let checker: any UpdateChecking
    /// Downloads + cryptographically verifies the DMG (01-04). `UpdateDownloader`
    /// (a public final class) is not implicitly `Sendable`, so it is carried in a
    /// tiny immutable box that forwards the one async method; the box is honest
    /// `@unchecked Sendable` only because the downloader is stateless by
    /// construction (it holds just a `URLSessionProtocol`).
    private let downloader: UpdateDownloaderBox
    /// Snapshots/swaps/restores the app bundle (01-03).
    private let installer: UpdateInstaller
    /// The running app's stamped version, read from `Bundle.main` at launch.
    private let installedVersion: UpdateVersion
    private let channelDefaultsKey: String
    private let defaults: UserDefaults

    /// Release channel the user is on. Persisted on change. The `.alpha` raw
    /// value is retained for compatibility and represents all prereleases.
    var channel: UpdateChannel {
        didSet {
            defaults.set(channel.rawValue, forKey: channelDefaultsKey)
        }
    }

    /// Whichever of `.idle` / `.checking` / `.updateAvailable` / `.upToDate`
    /// / `.failed` the last action produced.
    var checkState: UpdateCheckState = .idle

    /// Non-nil while an install is in flight, 0 at download start and 1 once
    /// the swap completes.
    var installProgress: Double?

    /// Non-nil after a successful install (the bundle that was swapped in):
    /// this is the "Restart to finish" marker. The model never relaunches on
    /// its own.
    var pendingInstallURL: URL?

    /// The resolved install destination (user-visible path) once an install
    /// has preflighted writability — e.g. `/Applications` or a user-writable
    /// `~/Applications` fallback (01-08 gap closure). Surfaced in the Settings
    /// scene so the user knows where the update is going.
    var pendingInstallDestination: String?

    /// Host-owned job-active guard (AUT-05-GUARD). `ScanStudioApp`'s
    /// `AppDelegate` mirrors the real `SessionModel.isJobActive` signal into
    /// this property. The Settings scene disables Install while `true`, and
    /// `install()` also refuses while `true`.
    var jobActive = false

    /// Whether a previous-version snapshot exists to restore (01-03).
    var canRollback: Bool { installer.availableRollback != nil }

    init(
        checker: any UpdateChecking,
        downloader: UpdateDownloader,
        installer: UpdateInstaller,
        installedVersion: UpdateVersion,
        channelDefaultsKey: String,
        defaults: UserDefaults = .standard
    ) {
        self.checker = checker
        self.downloader = UpdateDownloaderBox(downloader: downloader)
        self.installer = installer
        self.installedVersion = installedVersion
        self.channelDefaultsKey = channelDefaultsKey
        self.defaults = defaults
        if let stored = defaults.string(forKey: channelDefaultsKey),
           let parsed = UpdateChannel(rawValue: stored) {
            channel = parsed
        } else {
            channel = .alpha
        }
    }

    // MARK: - Actions

    /// Resolves the newest candidate for the current channel and reflects it
    /// in `checkState`. Runs regardless of `jobActive`: the job guard gates
    /// *install* only (AUT-05-GUARD). Never throws and never crashes;
    /// transport/decode trouble becomes `.failed`.
    func checkNow() async {
        checkState = .checking
        do {
            let candidate = try await checker.latestCandidate(channel: channel)
            if let candidate, installedVersion < candidate.version {
                checkState = .updateAvailable(candidate)
            } else {
                checkState = .upToDate
            }
        } catch {
            checkState = .failed(Self.describe(error))
        }
    }

    /// Downloads, verifies, and installs the offered candidate. Gated on
    /// `!jobActive` (AUT-05-GUARD). On success this leaves `pendingInstallURL`
    /// set so the Settings scene shows "Restart to finish" -- it never
    /// auto-relaunches.
    func install() async {
        guard !jobActive else {
            checkState = .failed("Cannot install while a scan is active.")
            return
        }
        guard case .updateAvailable(let candidate) = checkState else {
            checkState = .failed("Choose an available update before installing.")
            return
        }
        installProgress = 0
        do {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScanStudio Updates", isDirectory: true)
            let dmgURL = try await downloader.download(candidate, to: temporaryDirectory)
            let appURL = try downloader.mountAndLocateApp(dmgURL)
            try downloader.verifyCodeSignature(at: appURL)
            let archive = UpdateArchive(
                version: candidate.version,
                sourceAppPath: appURL,
                checksumSHA256: candidate.sha256
            )
            // Preflight the destination so an unwritable target resolves to a
            // user-writable location (or a clear typed error) — never a
            // misleading bare `.swapFailed`. The installer re-resolves the same
            // destination internally, so the surfaced path matches the swap.
            let destination = try installer.installDestination
            pendingInstallDestination = destination.path
            try installer.install(archive)
            installProgress = 1
            pendingInstallURL = appURL
        } catch {
            installProgress = nil
            pendingInstallURL = nil
            checkState = .failed(Self.describe(error))
        }
    }

    /// Restores the 01-03 snapshot, if any. Best-effort; never crashes. Clears
    /// the "Restart to finish" marker on success.
    func rollback() async {
        do {
            try installer.restorePrevious()
            pendingInstallURL = nil
            installProgress = nil
            checkState = .idle
        } catch {
            checkState = .failed(Self.describe(error))
        }
    }

    // MARK: - Errors

    /// User-safe copy for typed update failures. Never includes URLs or
    /// checksum internals (T-01-05-04).
    private static func describe(_ error: Error) -> String {
        switch error {
        case UpdateDownloadError.badCandidate:
            return "The update feed described an invalid release."
        case UpdateDownloadError.downloadFailed:
            return "The update could not be downloaded. Check your connection and try again."
        case UpdateDownloadError.checksumMismatch:
            return "The downloaded update did not match its checksum and was discarded."
        case UpdateDownloadError.mountFailed:
            return "The update disk image could not be opened."
        case UpdateDownloadError.signatureInvalid:
            return "The downloaded update failed its code-signature check."
        case UpdateDownloadError.invalidArchive:
            return "The update is not a supported disk image."
        case UpdateDownloadError.notAnApp:
            return "The update disk image did not contain the Scan Studio app."
        case UpdateInstallError.badArguments:
            return "The updater was not configured correctly."
        case UpdateInstallError.sourceMissing:
            return "The verified update bundle was missing."
        case UpdateInstallError.notVerified:
            return "The update could not be verified before install."
        case UpdateInstallError.cannotSnapshot:
            return "The current app could not be snapshotted for rollback."
        case UpdateInstallError.swapFailed:
            return "The install failed; your previous version is still in place."
        case UpdateInstallError.cannotWriteTarget:
            return "The current user cannot write to the app folder; install to ~/Applications (or add an administrator account) and try again."
        case UpdateInstallError.rolledBack:
            return "No previous version was available to roll back to."
        default:
            return String(describing: error)
        }
    }
}

/// Immutable, stateless way to carry the 01-04 `UpdateDownloader` across
/// isolation boundaries without a `sending` diagnostic: the downloader is a
/// public final class (so not implicitly `Sendable`) that holds only a
/// `URLSessionProtocol`, and this box forwards its three methods unchanged.
private struct UpdateDownloaderBox: @unchecked Sendable {
    let downloader: UpdateDownloader

    func download(_ candidate: UpdateCandidate, to directory: URL) async throws -> URL {
        try await downloader.download(candidate, to: directory)
    }

    func mountAndLocateApp(_ dmgURL: URL) throws -> URL {
        try downloader.mountAndLocateApp(dmgURL)
    }

    func verifyCodeSignature(at appURL: URL) throws {
        try downloader.verifyCodeSignature(at: appURL)
    }
}
