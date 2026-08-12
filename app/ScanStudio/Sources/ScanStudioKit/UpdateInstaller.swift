// Safe app-bundle swap with snapshot/rollback. Never touches the scanner.
// Pure Foundation filesystem work: snapshot the current app, stage a
// source-verified archive, atomically swap it into place, and restore the
// previous version on demand. No bridge spawn, no device open, no motion
// latch, or project access. FileManager is the copy helper (`ditto` is not
// needed); the shared verifier performs the bounded notarization assessment.

import Darwin
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
    /// Architecture selected from the feed for this archive. The install core
    /// revalidates the copied Mach-O against it before and after publication.
    public let architecture: HostArchitecture

    public init(
        version: UpdateVersion,
        sourceAppPath: URL,
        checksumSHA256: String,
        architecture: HostArchitecture = HostArchitectureProvider.current()
    ) {
        self.version = version
        self.sourceAppPath = sourceAppPath
        self.checksumSHA256 = checksumSHA256
        self.architecture = architecture
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
    /// Same publisher/identity verifier used on the mounted source. Re-running
    /// it on the private staging copy and final destination closes copy/swap
    /// mistakes and makes the installer independently fail-closed.
    private let bundleVerifier: UpdateBundleVerifier

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

    public convenience init(
        appDirectory: URL,
        rollbackDirectory: URL,
        authorizedDestinations: [URL] = [],
        publisherTrust: UpdatePublisherTrust? = nil
    ) throws {
        try self.init(
            appDirectory: appDirectory,
            rollbackDirectory: rollbackDirectory,
            authorizedDestinations: authorizedDestinations,
            bundleVerifier: UpdateBundleVerifier(publisherTrust: publisherTrust)
        )
    }

    init(
        appDirectory: URL,
        rollbackDirectory: URL,
        authorizedDestinations: [URL] = [],
        bundleVerifier: UpdateBundleVerifier
    ) throws {
        guard appDirectory.isExistingDirectory, rollbackDirectory.isExistingDirectory else {
            throw UpdateInstallError.badArguments
        }
        self.appDirectory = appDirectory
        self.rollbackDirectory = rollbackDirectory
        self.authorizedDestinations = authorizedDestinations
        self.bundleVerifier = bundleVerifier
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
        // Do not snapshot or mutate a destination until the mounted source has
        // independently passed the complete publisher/identity gate.
        try bundleVerifier.validate(
            appURL: archive.sourceAppPath,
            expectedVersion: archive.version,
            expectedArchitecture: archive.architecture
        )
        // Preflight the destination up front: an unwritable target surfaces a
        // clear `.cannotWriteTarget`, never a misleading `.swapFailed`.
        let destination = try resolveInstallDestination()
        if !fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                try Self.syncDirectory(destination.deletingLastPathComponent())
            } catch {
                throw UpdateInstallError.cannotWriteTarget
            }
        }
        let currentApp = destination.appendingPathComponent("ScanStudio.app", isDirectory: true)
        if fileManager.fileExists(atPath: currentApp.path) {
            let currentVersion: UpdateVersion
            do {
                currentVersion = try Self.versionOfBundle(at: currentApp)
            } catch {
                throw UpdateInstallError.cannotSnapshot
            }
            guard currentVersion < archive.version else {
                throw UpdateDownloadError.versionMismatch
            }
        }
        try snapshotCurrentCore(in: destination)
        let stagingContainer: URL
        do {
            stagingContainer = try makePrivateStagingContainer(in: destination)
        } catch {
            throw UpdateInstallError.swapFailed
        }
        let staging = stagingContainer.appendingPathComponent("ScanStudio.app", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingContainer) }
        do {
            try fileManager.copyItem(at: archive.sourceAppPath, to: staging)
            try bundleVerifier.validate(
                appURL: staging,
                expectedVersion: archive.version,
                expectedArchitecture: archive.architecture
            )
            try swapIn(
                staged: staging,
                into: destination,
                expectedVersion: archive.version,
                expectedArchitecture: archive.architecture
            )
        } catch let error as UpdateDownloadError {
            throw error
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
        let stagingContainer = try makePrivateStagingContainer(in: destination)
        let staging = stagingContainer.appendingPathComponent("ScanStudio.app", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingContainer) }
        try fileManager.copyItem(at: snapshot.url, to: staging)
        try bundleVerifier.validate(
            appURL: staging,
            expectedVersion: snapshot.version,
            expectedArchitecture: HostArchitectureProvider.current()
        )
        try swapIn(
            staged: staging,
            into: destination,
            expectedVersion: snapshot.version,
            expectedArchitecture: HostArchitectureProvider.current()
        )
        return destination.appendingPathComponent("ScanStudio.app", isDirectory: true)
    }

    // MARK: - Swapping

    /// Atomic-ish replacement: move the staged bundle into the app slot,
    /// keeping the previous app as `ScanStudio.prev` until the new one is
    /// confirmed present and readable, then drop the backup.
    private func swapIn(
        staged: URL,
        into destination: URL,
        expectedVersion: UpdateVersion,
        expectedArchitecture: HostArchitecture
    ) throws {
        let current = destination.appendingPathComponent("ScanStudio.app", isDirectory: true)
        let backupName = ".ScanStudio.prev.\(UUID().uuidString)"
        let backup = destination.appendingPathComponent(backupName, isDirectory: true)
        let hadCurrent = fileManager.fileExists(atPath: current.path)

        do {
            if hadCurrent {
                _ = try fileManager.replaceItemAt(
                    current,
                    withItemAt: staged,
                    backupItemName: backupName
                )
            } else {
                try Self.renameExclusive(staged, to: current)
            }
            try bundleVerifier.validate(
                appURL: current,
                expectedVersion: expectedVersion,
                expectedArchitecture: expectedArchitecture
            )
            try Self.syncDirectory(destination)
        } catch {
            if hadCurrent {
                restoreBackup(backup: backup, current: current)
            } else {
                try? fileManager.removeItem(at: current)
                try? Self.syncDirectory(destination)
            }
            if let validationError = error as? UpdateDownloadError {
                throw validationError
            }
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
        try? Self.syncDirectory(current.deletingLastPathComponent())
    }

    /// Creates a randomized mode-0700 sibling atomically. The copied app stays
    /// inside this private directory until its final same-volume rename/swap.
    private func makePrivateStagingContainer(in directory: URL) throws -> URL {
        for _ in 0..<8 {
            let container = directory.appendingPathComponent(
                ".ScanStudio.stage.\(UUID().uuidString)",
                isDirectory: true
            )
            let result = container.path.withCString { Darwin.mkdir($0, 0o700) }
            if result == 0 { return container }
            if errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        throw POSIXError(.EEXIST)
    }

    /// Atomic create-only publication for an empty destination. `RENAME_EXCL`
    /// prevents a path appearing between validation and rename from being
    /// overwritten.
    private static func renameExclusive(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Makes the create/replace directory entry durable before reporting
    /// success. This is intentionally a throwing gate, not best-effort.
    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
