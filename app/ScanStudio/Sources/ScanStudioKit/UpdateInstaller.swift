// Safe app-bundle swap with snapshot/rollback. Never touches the scanner.
// Pure Foundation filesystem work: snapshot the current app, stage a
// source-verified archive, atomically swap it into place, and restore the
// previous version on demand. No bridge spawn, no device open, no motion
// latch, no project access, no subprocesses (FileManager is the copy helper,
// so `ditto` is not needed here).

import Foundation

/// Typed failures for the install core (AUT-04-SNAP, AUT-04-SWAP,
/// AUT-04-ROLLBACK). Every case is user-presentable and testable.
public enum UpdateInstallError: Error, Equatable {
    /// Misconfigured `UpdateInstaller` (a path was not a directory).
    case badArguments
    /// `UpdateArchive.sourceAppPath` does not exist or is not a directory.
    case sourceMissing
    /// The archive carried no checksum, so it cannot be claimed verified.
    case notVerified
    /// The current app could not be snapshotted; the install is aborted.
    case cannotSnapshot
    /// The staged swap (or its rollback) failed; the old app is intact.
    case swapFailed
    /// `restorePrevious()` was called but no snapshot is available.
    case rolledBack
}

/// A verified update candidate ready to install: the mounted app bundle
/// produced by 01-04's `UpdateDownloader`, stamped with the version it
/// claims to be and the SHA-256 the release feed promised.
public struct UpdateArchive: Sendable {
    /// The version the source bundle claims (matched against the feed).
    public let version: UpdateVersion
    /// Directory of the new `.app` bundle (e.g. a mounted DMG's app).
    public let sourceAppPath: URL
    /// Non-empty release SHA-256 (actual hash verification is 01-04's job,
    /// run before this core ever sees the archive).
    public let checksumSHA256: String

    public init(version: UpdateVersion, sourceAppPath: URL, checksumSHA256: String) {
        self.version = version
        self.sourceAppPath = sourceAppPath
        self.checksumSHA256 = checksumSHA256
    }
}

/// The install core: swaps the running app bundle with reversible
/// snapshot/restore. The rollback snapshot lives under the user's Support
/// library, mirroring the existing on-disk precedent.
public final class UpdateInstaller {
    /// Where the installed `ScanStudio.app` lives (injectable for tests;
    /// the real caller uses `/Applications`).
    private let appDirectory: URL
    /// Where versioned snapshots are written, e.g.
    /// `~/Library/Application Support/ScanStudio/Rollback/`.
    private let rollbackDirectory: URL

    /// The most recent snapshot taken by this instance — the only source of
    /// truth for `availableRollback`. Never cleared after a later successful
    /// call; stays true to the last good snapshot.
    private var lastSnapshot: (version: UpdateVersion, url: URL)?

    private let fileManager = FileManager.default

    public init(appDirectory: URL, rollbackDirectory: URL) throws {
        guard appDirectory.isExistingDirectory, rollbackDirectory.isExistingDirectory else {
            throw UpdateInstallError.badArguments
        }
        self.appDirectory = appDirectory
        self.rollbackDirectory = rollbackDirectory
    }

    /// The last snapshot this instance recorded, if any.
    public var availableRollback: (version: UpdateVersion, url: URL)? {
        lastSnapshot
    }

    /// Copies the current `<appDirectory>/ScanStudio.app` into the rollback
    /// directory as `ScanStudio-<version>.app`. No-op (does not throw) when
    /// there is no app to snapshot.
    public func snapshotCurrent() throws {
        let appURL = appDirectory.appendingPathComponent("ScanStudio.app", isDirectory: true)
        guard fileManager.fileExists(atPath: appURL.path) else {
            return
        }
        do {
            let version = try Self.versionOfBundle(at: appURL)
            try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
            let destination = rollbackDirectory.appendingPathComponent("ScanStudio-\(version.raw).app", isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: appURL, to: destination)
            lastSnapshot = (version, destination)
        } catch {
            throw UpdateInstallError.cannotSnapshot
        }
    }

    /// Installs a verified archive: snapshot current, stage the source
    /// bundle beside the app, atomically replace, confirm in place.
    public func install(_ archive: UpdateArchive) throws {
        guard fileManager.fileExists(atPath: archive.sourceAppPath.path),
              archive.sourceAppPath.isExistingDirectory else {
            throw UpdateInstallError.sourceMissing
        }
        guard !archive.checksumSHA256.isEmpty else {
            throw UpdateInstallError.notVerified
        }
        try snapshotCurrent()
        do {
            let staging = stagingURL()
            if fileManager.fileExists(atPath: staging.path) {
                try fileManager.removeItem(at: staging)
            }
            try fileManager.copyItem(at: archive.sourceAppPath, to: staging)
            try swapIn(staged: staging)
        } catch {
            throw UpdateInstallError.swapFailed
        }
    }

    /// Restores the last snapshot (if any) into `<appDirectory>/ScanStudio.app`
    /// via the same stage-and-swap path. Returns the restored app path.
    @discardableResult
    public func restorePrevious() throws -> URL {
        guard let snapshot = lastSnapshot else {
            throw UpdateInstallError.rolledBack
        }
        let staging = stagingURL()
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.copyItem(at: snapshot.url, to: staging)
        try swapIn(staged: staging)
        return appDirectory.appendingPathComponent("ScanStudio.app", isDirectory: true)
    }

    // MARK: - Swapping

    /// Atomic-ish replacement: move the staged bundle into the app slot,
    /// keeping the previous app as `ScanStudio.prev` until the new one is
    /// confirmed present and readable, then drop the backup.
    private func swapIn(staged: URL) throws {
        let current = appDirectory.appendingPathComponent("ScanStudio.app", isDirectory: true)
        let backup = appDirectory.appendingPathComponent("ScanStudio.prev", isDirectory: true)

        do {
            _ = try fileManager.replaceItemAt(current, withItemAt: staged, backupItemName: "ScanStudio.prev")
        } catch {
            restoreBackup(backup: backup, current: current)
            throw UpdateInstallError.swapFailed
        }

        guard fileManager.fileExists(atPath: current.path),
              fileManager.isReadableFile(atPath: current.path) else {
            restoreBackup(backup: backup, current: current)
            throw UpdateInstallError.swapFailed
        }

        if fileManager.fileExists(atPath: backup.path) {
            try? fileManager.removeItem(at: backup)
        }
    }

    /// Best-effort: put the staged backup back over whatever is at `current`.
    private func restoreBackup(backup: URL, current: URL) {
        guard fileManager.fileExists(atPath: backup.path) else { return }
        try? fileManager.removeItem(at: current)
        try? fileManager.moveItem(at: backup, to: current)
    }

    private func stagingURL() -> URL {
        appDirectory.appendingPathComponent(".ScanStudio.new", isDirectory: true)
    }

    // MARK: - Version helpers

    /// Reads the bundled release version from `Info.plist` — the stamped
    /// `ScanStudioRelease` key, falling back to `CFBundleShortVersionString`.
    /// Throws `.cannotSnapshot` when no usable version can be determined.
    private static func versionOfBundle(at appURL: URL) throws -> UpdateVersion {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            throw UpdateInstallError.cannotSnapshot
        }
        let raw: String? = {
            if let stamped = dictionary["ScanStudioRelease"] as? String, !stamped.isEmpty {
                return stamped
            }
            return dictionary["CFBundleShortVersionString"] as? String
        }()
        guard let raw, let version = UpdateVersion(raw: raw) else {
            throw UpdateInstallError.cannotSnapshot
        }
        return version
    }
}

private extension URL {
    var isExistingDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
