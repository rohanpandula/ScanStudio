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
    /// No install destination is writable: neither `appDirectory` nor any
    /// user-writable fallback (e.g. `~/Applications`) accepts the install.
    case cannotWriteTarget
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
    /// Additional destinations the caller permits falling back to when
    /// `appDirectory` is not writable (01-08 gap closure). Empty means
    /// "default to the user-writable `~/Applications`".
    private let authorizedDestinations: [URL]

    /// The most recent snapshot taken by this instance — the only source of
    /// truth for `availableRollback`. Never cleared after a later successful
    /// call; stays true to the last good snapshot.
    private var lastSnapshot: (version: UpdateVersion, url: URL)?

    private let fileManager = FileManager.default

    /// The preferred install candidate destinations, in preference order:
    /// `/Applications`, then the current user's `~/Applications` (a candidate
    /// only — never created on disk here). Kept as a pure static helper so
    /// tests and the flow model share one source of truth.
    public static func defaultInstallDestinations() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    public init(
        appDirectory: URL,
        rollbackDirectory: URL,
        authorizedDestinations: [URL] = []
    ) throws {
        guard appDirectory.isExistingDirectory, rollbackDirectory.isExistingDirectory else {
            throw UpdateInstallError.badArguments
        }
        self.appDirectory = appDirectory
        self.rollbackDirectory = rollbackDirectory
        self.authorizedDestinations = authorizedDestinations
    }

    /// The last snapshot this instance recorded, if any.
    public var availableRollback: (version: UpdateVersion, url: URL)? {
        lastSnapshot
    }

    /// The destination installs will actually write to, given the state of the
    /// filesystem: `appDirectory` when writable, else the first writable
    /// authorized destination, else `.cannotWriteTarget`. Throwing so the
    /// caller can surface a clear error instead of a misleading `.swapFailed`.
    public var installDestination: URL {
        get throws { try resolveInstallDestination() }
    }

    /// Resolves where an install may happen: prefers `appDirectory` when it is
    /// writable; otherwise falls back through `authorizedDestinations`
    /// (defaulting to `~/Applications`) to the first writable one; otherwise
    /// throws `.cannotWriteTarget`. `~/Applications` keeps snapshot/rollback
    /// identical — both are per-destination rollback directories.
    public func resolveInstallDestination() throws -> URL {
        if fileManager.isWritableFile(atPath: appDirectory.path) {
            return appDirectory
        }
        let fallbacks = authorizedDestinations.isEmpty
            ? Array(Self.defaultInstallDestinations().dropFirst())
            : authorizedDestinations
        for destination in fallbacks where Self.isWritableTarget(destination) {
            return destination
        }
        throw UpdateInstallError.cannotWriteTarget
    }

    /// Whether `directory` can accept a write: writable when it exists;
    /// when it does not exist yet (e.g. `~/Applications`), writable iff its
    /// nearest existing ancestor is writable.
    private static func isWritableTarget(_ directory: URL) -> Bool {
        var probe = directory
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent == probe { return false }
            probe = parent
        }
        return FileManager.default.isWritableFile(atPath: probe.path)
    }

    /// Copies the current `<appDirectory>/ScanStudio.app` into the rollback
    /// directory as `ScanStudio-<version>.app`. No-op (does not throw) when
    /// there is no app to snapshot.
    public func snapshotCurrent() throws {
        try snapshotCurrentCore(in: appDirectory)
    }

    /// The snapshot core — exactly the shipped snapshot mechanics, operating
    /// on whichever install directory is actually in use (so a user-folder
    /// install snapshots/restores correctly from that destination).
    private func snapshotCurrentCore(in destination: URL) throws {
        let appURL = destination.appendingPathComponent("ScanStudio.app", isDirectory: true)
        guard fileManager.fileExists(atPath: appURL.path) else {
            return
        }
        do {
            let version = try Self.versionOfBundle(at: appURL)
            try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
            let snapshotURL = rollbackDirectory.appendingPathComponent("ScanStudio-\(version.raw).app", isDirectory: true)
            if fileManager.fileExists(atPath: snapshotURL.path) {
                try fileManager.removeItem(at: snapshotURL)
            }
            try fileManager.copyItem(at: appURL, to: snapshotURL)
            lastSnapshot = (version, snapshotURL)
        } catch {
            throw UpdateInstallError.cannotSnapshot
        }
    }

    /// Installs a verified archive: resolve the writable destination, snapshot
    /// current, stage the source bundle beside the app, atomically replace,
    /// confirm in place.
    public func install(_ archive: UpdateArchive) throws {
        guard fileManager.fileExists(atPath: archive.sourceAppPath.path),
              archive.sourceAppPath.isExistingDirectory else {
            throw UpdateInstallError.sourceMissing
        }
        guard !archive.checksumSHA256.isEmpty else {
            throw UpdateInstallError.notVerified
        }
        // Preflight the destination up front: an unwritable target surfaces a
        // clear `.cannotWriteTarget`, never a misleading `.swapFailed`.
        let destination = try resolveInstallDestination()
        try snapshotCurrentCore(in: destination)
        do {
            let staging = stagingURL(in: destination)
            if fileManager.fileExists(atPath: staging.path) {
                try fileManager.removeItem(at: staging)
            }
            try fileManager.copyItem(at: archive.sourceAppPath, to: staging)
            try swapIn(staged: staging, into: destination)
        } catch {
            throw UpdateInstallError.swapFailed
        }
    }

    /// Restores the last snapshot (if any) into the resolved install
    /// destination's `ScanStudio.app` via the same stage-and-swap path.
    /// Returns the restored app path.
    @discardableResult
    public func restorePrevious() throws -> URL {
        guard let snapshot = lastSnapshot else {
            throw UpdateInstallError.rolledBack
        }
        let destination = try resolveInstallDestination()
        let staging = stagingURL(in: destination)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.copyItem(at: snapshot.url, to: staging)
        try swapIn(staged: staging, into: destination)
        return destination.appendingPathComponent("ScanStudio.app", isDirectory: true)
    }

    // MARK: - Swapping

    /// Atomic-ish replacement: move the staged bundle into the app slot,
    /// keeping the previous app as `ScanStudio.prev` until the new one is
    /// confirmed present and readable, then drop the backup.
    private func swapIn(staged: URL, into destination: URL) throws {
        let current = destination.appendingPathComponent("ScanStudio.app", isDirectory: true)
        let backup = destination.appendingPathComponent("ScanStudio.prev", isDirectory: true)

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

    private func stagingURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".ScanStudio.new", isDirectory: true)
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
