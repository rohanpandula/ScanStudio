// Verified on-disk cache for the optional browser runtime. Selection is a
// small atomic current/previous record; the selected payload is never trusted
// from that record alone. Every launch re-authenticates the retained manifest,
// re-hashes the installed tree, and rechecks its code identity.

import CryptoKit
import Darwin
import Foundation

public struct WebRuntimeCodeIdentityAssertion: Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let developerIDSigned: Bool
    public let notarized: Bool

    public init(
        bundleIdentifier: String,
        teamIdentifier: String,
        developerIDSigned: Bool,
        notarized: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.developerIDSigned = developerIDSigned
        self.notarized = notarized
    }
}

public struct WebRuntimePayloadVerification: Equatable, Sendable {
    public let codeIdentity: WebRuntimeCodeIdentityAssertion
    public let fileCount: Int
    public let installedSize: Int64
    public let treeSHA256: String

    public init(
        codeIdentity: WebRuntimeCodeIdentityAssertion,
        fileCount: Int,
        installedSize: Int64,
        treeSHA256: String
    ) {
        self.codeIdentity = codeIdentity
        self.fileCount = fileCount
        self.installedSize = installedSize
        self.treeSHA256 = treeSHA256
    }
}

public protocol WebRuntimeCodeAssessing: Sendable {
    func assessPayload(
        at rootURL: URL,
        executableURL: URL
    ) throws -> WebRuntimeCodeIdentityAssertion
}

public struct UnavailableWebRuntimeCodeAssessor: WebRuntimeCodeAssessing {
    public init() {}

    public func assessPayload(
        at rootURL: URL,
        executableURL: URL
    ) throws -> WebRuntimeCodeIdentityAssertion {
        throw WebRuntimeDistributionError.productionTrustUnavailable
    }
}

public protocol WebRuntimePayloadVerifying: Sendable {
    func verifyPayload(
        at rootURL: URL,
        against manifest: WebRuntimeManifest
    ) throws -> WebRuntimePayloadVerification
}

public struct UnavailableWebRuntimePayloadVerifier: WebRuntimePayloadVerifying {
    public init() {}

    public func verifyPayload(
        at rootURL: URL,
        against manifest: WebRuntimeManifest
    ) throws -> WebRuntimePayloadVerification {
        throw WebRuntimeDistributionError.productionTrustUnavailable
    }
}

/// File-tree verifier shared by install and launch. Code-signature and
/// notarization assessment remains an injected platform service so tests never
/// weaken or pretend to perform those system checks.
public struct FileSystemWebRuntimePayloadVerifier: WebRuntimePayloadVerifying {
    private let codeAssessor: any WebRuntimeCodeAssessing

    public init(
        codeAssessor: any WebRuntimeCodeAssessing = UnavailableWebRuntimeCodeAssessor()
    ) {
        self.codeAssessor = codeAssessor
    }

    public func verifyPayload(
        at rootURL: URL,
        against manifest: WebRuntimeManifest
    ) throws -> WebRuntimePayloadVerification {
        let summary = try WebRuntimePayloadTreeHash.compute(
            at: rootURL,
            maximumEntries: manifest.payload.fileCount,
            maximumBytes: manifest.payload.installedSize
        )
        guard summary.fileCount == manifest.payload.fileCount,
              summary.installedSize == manifest.payload.installedSize,
              summary.treeSHA256 == manifest.payload.treeSHA256 else {
            throw WebRuntimeDistributionError.unsafePayload
        }

        let executable = try Self.containedURL(
            manifest.payload.executableRelativePath,
            beneath: rootURL,
            expectedDirectory: false
        )
        _ = try Self.containedURL(
            manifest.payload.staticDirectoryRelativePath,
            beneath: rootURL,
            expectedDirectory: true
        )
        var executableInfo = stat()
        guard lstat(executable.path, &executableInfo) == 0,
              executableInfo.st_mode & S_IFMT == S_IFREG,
              executableInfo.st_mode & 0o111 != 0,
              executableInfo.st_mode & 0o022 == 0 else {
            throw WebRuntimeDistributionError.unsafePayload
        }

        let identity = try codeAssessor.assessPayload(
            at: rootURL,
            executableURL: executable
        )
        guard identity.bundleIdentifier == manifest.payload.bundleIdentifier,
              identity.teamIdentifier == manifest.payload.teamIdentifier,
              identity.developerIDSigned == manifest.payload.developerIDSigned,
              identity.notarized == manifest.payload.notarized else {
            throw WebRuntimeDistributionError.payloadIdentityMismatch
        }
        if !identity.developerIDSigned || !identity.notarized {
            throw WebRuntimeDistributionError.productionTrustRequired
        }
        return WebRuntimePayloadVerification(
            codeIdentity: identity,
            fileCount: summary.fileCount,
            installedSize: summary.installedSize,
            treeSHA256: summary.treeSHA256
        )
    }

    private static func containedURL(
        _ relativePath: String,
        beneath rootURL: URL,
        expectedDirectory: Bool
    ) throws -> URL {
        let root = rootURL.standardizedFileURL
        let candidate = root.appendingPathComponent(
            relativePath,
            isDirectory: expectedDirectory
        ).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw WebRuntimeDistributionError.unsafePayload
        }

        var cursor = root
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            var info = stat()
            guard lstat(cursor.path, &info) == 0,
                  info.st_mode & S_IFMT != S_IFLNK else {
                throw WebRuntimeDistributionError.unsafePayload
            }
        }
        var finalInfo = stat()
        guard lstat(candidate.path, &finalInfo) == 0 else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        let expectedType = expectedDirectory ? S_IFDIR : S_IFREG
        guard finalInfo.st_mode & S_IFMT == expectedType else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        return candidate
    }
}

public protocol WebRuntimeLockLease: AnyObject, Sendable {}

public protocol WebRuntimeCrossProcessLocking: Sendable {
    func acquire() throws -> any WebRuntimeLockLease
}

public struct WebRuntimeFileLock: WebRuntimeCrossProcessLocking, Sendable {
    private let directoryURL: URL
    private let timeoutSeconds: Double
    private let filename: String

    public init(
        directoryURL: URL,
        timeoutSeconds: Double = 5,
        filename: String = ".runtime.lock"
    ) throws {
        guard timeoutSeconds.isFinite,
              timeoutSeconds > 0,
              timeoutSeconds <= 300,
              !filename.isEmpty,
              !filename.contains("/"),
              filename != ".",
              filename != ".." else {
            throw WebRuntimeDistributionError.invalidRequest
        }
        self.directoryURL = directoryURL
        self.timeoutSeconds = timeoutSeconds
        self.filename = filename
    }

    public func acquire() throws -> any WebRuntimeLockLease {
        try WebRuntimeSecureFileSystem.ensurePrivateDirectory(directoryURL)
        let directoryFD = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryFD >= 0 else {
            throw WebRuntimeDistributionError.cacheUnavailable
        }
        defer { close(directoryFD) }

        let descriptor = filename.withCString { pointer in
            openat(
                directoryFD,
                pointer,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw WebRuntimeDistributionError.cacheUnavailable
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            throw WebRuntimeDistributionError.cacheUnavailable
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutSeconds * 1_000_000_000)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EAGAIN {
                close(descriptor)
                throw WebRuntimeDistributionError.cacheUnavailable
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                close(descriptor)
                throw WebRuntimeDistributionError.cacheLockTimedOut
            }
            usleep(10_000)
        }
        return WebRuntimePOSIXLockLease(descriptor: descriptor)
    }
}

private final class WebRuntimePOSIXLockLease: WebRuntimeLockLease, @unchecked Sendable {
    private let descriptor: Int32
    private let stateLock = NSLock()
    private var released = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { release() }

    private func release() {
        stateLock.withLock {
            guard !released else { return }
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            released = true
        }
    }
}

public struct InstalledWebRuntime: Equatable, Sendable {
    public let hostVersion: String
    public let runtimeVersion: String
    public let architecture: HostArchitecture
    public let rootURL: URL
    public let executableURL: URL
    public let staticDirectoryURL: URL
    public let codeIdentity: WebRuntimeCodeIdentityAssertion

    public init(
        hostVersion: String,
        runtimeVersion: String,
        architecture: HostArchitecture,
        rootURL: URL,
        executableURL: URL,
        staticDirectoryURL: URL,
        codeIdentity: WebRuntimeCodeIdentityAssertion
    ) {
        self.hostVersion = hostVersion
        self.runtimeVersion = runtimeVersion
        self.architecture = architecture
        self.rootURL = rootURL
        self.executableURL = executableURL
        self.staticDirectoryURL = staticDirectoryURL
        self.codeIdentity = codeIdentity
    }

    public var webServerRuntime: WebServerRuntime {
        WebServerRuntime(
            executableURL: executableURL,
            staticDirectoryURL: staticDirectoryURL,
            workingDirectoryURL: rootURL
        )
    }
}

public protocol WebRuntimeCacheInstalling: Sendable {
    func install(
        preparedPayloadAt payloadURL: URL,
        release: VerifiedWebRuntimeRelease
    ) async throws -> InstalledWebRuntime

    /// Must re-authenticate and re-hash the selected runtime on every call.
    func verifiedRuntimeForLaunch(
        matching request: WebRuntimeReleaseRequest
    ) async throws -> InstalledWebRuntime
}

public actor WebRuntimeCacheInstaller: WebRuntimeCacheInstalling {
    private static let selectionFilename = "selection.json"
    private static let manifestFilename = "manifest.json"
    private static let signatureFilename = "manifest.sig"
    private static let payloadDirectoryName = "ScanStudioWebRuntime.bundle"
    private static let maximumSelectionBytes = 16_384

    private let rootDirectoryURL: URL
    private let versionsDirectoryURL: URL
    private let lock: any WebRuntimeCrossProcessLocking
    private let manifestVerifier: WebRuntimeManifestVerifier
    private let payloadVerifier: any WebRuntimePayloadVerifying

    public init(
        rootDirectoryURL: URL,
        signatureVerifier: any WebRuntimeManifestSignatureVerifying =
            UnavailableWebRuntimeSignatureVerifier(),
        payloadVerifier: any WebRuntimePayloadVerifying =
            UnavailableWebRuntimePayloadVerifier()
    ) throws {
        self.rootDirectoryURL = rootDirectoryURL
        versionsDirectoryURL = rootDirectoryURL.appendingPathComponent(
            "versions",
            isDirectory: true
        )
        lock = try WebRuntimeFileLock(directoryURL: rootDirectoryURL)
        manifestVerifier = WebRuntimeManifestVerifier(signatureVerifier: signatureVerifier)
        self.payloadVerifier = payloadVerifier
    }

    public init(
        rootDirectoryURL: URL,
        lock: any WebRuntimeCrossProcessLocking,
        signatureVerifier: any WebRuntimeManifestSignatureVerifying,
        payloadVerifier: any WebRuntimePayloadVerifying
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        versionsDirectoryURL = rootDirectoryURL.appendingPathComponent(
            "versions",
            isDirectory: true
        )
        self.lock = lock
        manifestVerifier = WebRuntimeManifestVerifier(signatureVerifier: signatureVerifier)
        self.payloadVerifier = payloadVerifier
    }

    public func install(
        preparedPayloadAt payloadURL: URL,
        release: VerifiedWebRuntimeRelease
    ) throws -> InstalledWebRuntime {
        do {
            return try installCheckingCancellation(
                preparedPayloadAt: payloadURL,
                release: release
            )
        } catch is CancellationError {
            throw WebRuntimeDistributionError.cancelled
        }
    }

    private func installCheckingCancellation(
        preparedPayloadAt payloadURL: URL,
        release: VerifiedWebRuntimeRelease
    ) throws -> InstalledWebRuntime {
        try Task.checkCancellation()
        try prepareCacheDirectories()
        try Task.checkCancellation()
        let lease = try lock.acquire()
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()

        // Validate before copying, then validate the copied bytes again. The
        // source may be a mounted image that disappears immediately afterward.
        _ = try payloadVerifier.verifyPayload(at: payloadURL, against: release.manifest)
        try Task.checkCancellation()
        let installationID = Self.installationID(for: release.manifest)
        let finalDirectory = versionsDirectoryURL.appendingPathComponent(
            installationID,
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: finalDirectory.path),
           let existing = try? verifyInstallation(
               id: installationID,
               request: release.request
           )
        {
            try Task.checkCancellation()
            let prior = try readSelection()
            let previous = prior?.current == installationID
                ? prior?.previous
                : prior?.current
            try Task.checkCancellation()
            try writeSelection(
                Selection(schemaVersion: 1, current: installationID, previous: previous)
            )
            return existing
        }
        let stagingDirectory = rootDirectoryURL.appendingPathComponent(
            ".install-\(UUID().uuidString)",
            isDirectory: true
        )
        var rejectedDirectory: URL?
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Task.checkCancellation()
            let stagedPayload = stagingDirectory.appendingPathComponent(
                Self.payloadDirectoryName,
                isDirectory: true
            )
            try FileManager.default.copyItem(at: payloadURL, to: stagedPayload)
            try Task.checkCancellation()
            try release.manifestBytes.write(
                to: stagingDirectory.appendingPathComponent(Self.manifestFilename),
                options: .withoutOverwriting
            )
            try Task.checkCancellation()
            try release.signatureBytes.write(
                to: stagingDirectory.appendingPathComponent(Self.signatureFilename),
                options: .withoutOverwriting
            )
            try Task.checkCancellation()
            _ = try payloadVerifier.verifyPayload(
                at: stagedPayload,
                against: release.manifest
            )
            try Task.checkCancellation()

            if FileManager.default.fileExists(atPath: finalDirectory.path) {
                // Never delete an existing selection in-place. Move it aside
                // under the same locked root, install atomically, then remove
                // the rejected cache copy only after the new tree is complete.
                let rejected = rootDirectoryURL.appendingPathComponent(
                    ".rejected-\(UUID().uuidString)",
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: finalDirectory, to: rejected)
                rejectedDirectory = rejected
                try Task.checkCancellation()
            }
            try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
            try Task.checkCancellation()

            // Confirm the final, cache-owned bytes before selecting them. This
            // also catches a copy-time race or metadata loss.
            let installed = try verifyInstallation(
                id: installationID,
                request: release.request
            )
            try Task.checkCancellation()

            let previousSelection = try readSelection()
            let previous = previousSelection?.current == installationID
                ? previousSelection?.previous
                : previousSelection?.current
            try Task.checkCancellation()
            try writeSelection(
                Selection(schemaVersion: 1, current: installationID, previous: previous)
            )
            if let rejectedDirectory {
                try? FileManager.default.removeItem(at: rejectedDirectory)
            }
            return installed
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            if let rejectedDirectory {
                // The old directory was valid enough to be the prior cache
                // occupant. Never leave the unselected replacement in its
                // place when final verification or selection persistence fails.
                let failedDirectory = rootDirectoryURL.appendingPathComponent(
                    ".failed-\(UUID().uuidString)",
                    isDirectory: true
                )
                if FileManager.default.fileExists(atPath: finalDirectory.path) {
                    try? FileManager.default.moveItem(at: finalDirectory, to: failedDirectory)
                }
                if !FileManager.default.fileExists(atPath: finalDirectory.path) {
                    try? FileManager.default.moveItem(at: rejectedDirectory, to: finalDirectory)
                }
                try? FileManager.default.removeItem(at: failedDirectory)
            } else if FileManager.default.fileExists(atPath: finalDirectory.path) {
                try? FileManager.default.removeItem(at: finalDirectory)
            }
            if error is CancellationError {
                throw WebRuntimeDistributionError.cancelled
            }
            throw error
        }
    }

    public func verifiedRuntimeForLaunch(
        matching request: WebRuntimeReleaseRequest
    ) throws -> InstalledWebRuntime {
        try prepareCacheDirectories()
        let lease = try lock.acquire()
        defer { withExtendedLifetime(lease) {} }
        guard let selection = try readSelection() else {
            throw WebRuntimeDistributionError.noVerifiedInstallation
        }

        var firstFailure: Error?
        do {
            return try verifyInstallation(id: selection.current, request: request)
        } catch {
            firstFailure = error
        }
        if let previous = selection.previous {
            do {
                let runtime = try verifyInstallation(id: previous, request: request)
                try writeSelection(
                    Selection(schemaVersion: 1, current: previous, previous: nil)
                )
                return runtime
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let failure = firstFailure as? WebRuntimeDistributionError {
            throw failure
        }
        throw WebRuntimeDistributionError.noVerifiedInstallation
    }

    private func verifyInstallation(
        id: String,
        request: WebRuntimeReleaseRequest
    ) throws -> InstalledWebRuntime {
        guard Self.isSafeInstallationID(id) else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        let installation = versionsDirectoryURL.appendingPathComponent(id, isDirectory: true)
        try WebRuntimeSecureFileSystem.requirePrivateDirectory(installation)
        let manifestBytes = try WebRuntimeSecureFileSystem.readRegularFile(
            installation.appendingPathComponent(Self.manifestFilename),
            maximumBytes: WebRuntimeManifest.maximumManifestBytes
        )
        let signatureBytes = try WebRuntimeSecureFileSystem.readRegularFile(
            installation.appendingPathComponent(Self.signatureFilename),
            maximumBytes: WebRuntimeManifest.maximumSignatureBytes
        )
        let release = try manifestVerifier.verify(
            manifestBytes: manifestBytes,
            signatureBytes: signatureBytes,
            for: request
        )
        guard Self.installationID(for: release.manifest) == id else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        let payload = installation.appendingPathComponent(
            Self.payloadDirectoryName,
            isDirectory: true
        )
        let verification = try payloadVerifier.verifyPayload(
            at: payload,
            against: release.manifest
        )
        let executable = payload.appendingPathComponent(
            release.manifest.payload.executableRelativePath,
            isDirectory: false
        )
        let staticDirectory = payload.appendingPathComponent(
            release.manifest.payload.staticDirectoryRelativePath,
            isDirectory: true
        )
        return InstalledWebRuntime(
            hostVersion: release.manifest.hostVersion,
            runtimeVersion: release.manifest.runtimeVersion,
            architecture: release.manifest.architecture,
            rootURL: payload,
            executableURL: executable,
            staticDirectoryURL: staticDirectory,
            codeIdentity: verification.codeIdentity
        )
    }

    private func prepareCacheDirectories() throws {
        try WebRuntimeSecureFileSystem.ensurePrivateDirectory(rootDirectoryURL)
        try WebRuntimeSecureFileSystem.ensurePrivateDirectory(versionsDirectoryURL)
    }

    private func readSelection() throws -> Selection? {
        let url = rootDirectoryURL.appendingPathComponent(Self.selectionFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try WebRuntimeSecureFileSystem.readRegularFile(
            url,
            maximumBytes: Self.maximumSelectionBytes
        )
        let selection: Selection
        do {
            selection = try JSONDecoder().decode(Selection.self, from: data)
        } catch {
            throw WebRuntimeDistributionError.atomicSelectionFailed
        }
        guard selection.schemaVersion == 1,
              Self.isSafeInstallationID(selection.current),
              selection.previous.map(Self.isSafeInstallationID) ?? true,
              selection.previous != selection.current else {
            throw WebRuntimeDistributionError.atomicSelectionFailed
        }
        return selection
    }

    private func writeSelection(_ selection: Selection) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(selection)
        } catch {
            throw WebRuntimeDistributionError.atomicSelectionFailed
        }
        try WebRuntimeSecureFileSystem.atomicWrite(
            data,
            to: rootDirectoryURL.appendingPathComponent(Self.selectionFilename)
        )
    }

    private static func installationID(for manifest: WebRuntimeManifest) -> String {
        "v1-\(manifest.runtimeVersion)-\(manifest.architecture.rawValue)-\(manifest.artifact.sha256)"
    }

    private static func isSafeInstallationID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 180
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
            }
            && !value.contains("..")
    }

    private struct Selection: Codable {
        let schemaVersion: Int
        let current: String
        let previous: String?
    }
}

private enum WebRuntimeSecureFileSystem {
    static func ensurePrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw WebRuntimeDistributionError.cacheUnavailable
        }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              chmod(url.path, mode_t(0o700)) == 0 else {
            throw WebRuntimeDistributionError.cacheUnavailable
        }
    }

    static func requirePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o022 == 0 else {
            throw WebRuntimeDistributionError.unsafePayload
        }
    }

    static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WebRuntimeDistributionError.unsafePayload }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        var data = Data(count: Int(info.st_size))
        let result = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return info.st_size == 0 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        guard result else { throw WebRuntimeDistributionError.unsafePayload }
        return data
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw WebRuntimeDistributionError.atomicSelectionFailed
        }
        var success = false
        defer {
            close(descriptor)
            if !success { unlink(temporary.path) }
        }
        let wroteAll = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0,
              rename(temporary.path, destination.path) == 0 else {
            throw WebRuntimeDistributionError.atomicSelectionFailed
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else {
            throw WebRuntimeDistributionError.atomicSelectionFailed
        }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else {
            throw WebRuntimeDistributionError.atomicSelectionFailed
        }
        success = true
    }
}

enum WebRuntimePayloadTreeHash {
    struct Summary {
        let fileCount: Int
        let installedSize: Int64
        let treeSHA256: String
    }

    private struct Entry {
        enum Kind: UInt8 { case directory = 0x44, file = 0x46 }
        let kind: Kind
        let relativePath: String
        let permissions: UInt16
        let size: UInt64
        let contentDigest: Data
    }

    static func compute(
        at rootURL: URL,
        maximumEntries: Int,
        maximumBytes: Int64
    ) throws -> Summary {
        var rootInfo = stat()
        guard maximumEntries > 0, maximumBytes > 0,
              lstat(rootURL.path, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_mode & 0o022 == 0 else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        let root = rootURL.standardizedFileURL
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        var entries: [Entry] = []
        var regularFileCount = 0
        var installedSize: Int64 = 0
        for case let url as URL in enumerator {
            let maximumTreeEntries = min(100_000, maximumEntries * 4 + 128)
            guard entries.count < maximumTreeEntries,
                  url.standardizedFileURL.path.hasPrefix(root.path + "/") else {
                throw WebRuntimeDistributionError.unsafePayload
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                throw WebRuntimeDistributionError.unsafePayload
            }
            guard values.isSymbolicLink != true else {
                throw WebRuntimeDistributionError.unsafePayload
            }
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  info.st_mode & S_IFMT != S_IFLNK,
                  info.st_mode & 0o022 == 0 else {
                throw WebRuntimeDistributionError.unsafePayload
            }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty, !relative.contains("\0") else {
                throw WebRuntimeDistributionError.unsafePayload
            }
            let permissions = UInt16(info.st_mode & 0o777)
            if values.isDirectory == true, info.st_mode & S_IFMT == S_IFDIR {
                entries.append(
                    Entry(
                        kind: .directory,
                        relativePath: relative,
                        permissions: permissions,
                        size: 0,
                        contentDigest: Data()
                    )
                )
            } else if values.isRegularFile == true, info.st_mode & S_IFMT == S_IFREG {
                regularFileCount += 1
                guard regularFileCount <= maximumEntries, info.st_nlink == 1 else {
                    throw WebRuntimeDistributionError.unsafePayload
                }
                guard info.st_size >= 0,
                      installedSize <= maximumBytes - info.st_size else {
                    throw WebRuntimeDistributionError.unsafePayload
                }
                installedSize += info.st_size
                let digest = try contentDigest(of: url, matching: info)
                entries.append(
                    Entry(
                        kind: .file,
                        relativePath: relative,
                        permissions: permissions,
                        size: UInt64(info.st_size),
                        contentDigest: digest
                    )
                )
            } else {
                throw WebRuntimeDistributionError.unsafePayload
            }
        }
        guard !enumerationFailed,
              regularFileCount == maximumEntries,
              installedSize == maximumBytes else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        entries.sort {
            $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
        }

        var hasher = SHA256()
        hasher.update(data: Data("ScanStudioWebRuntimeTreeV1\0".utf8))
        for entry in entries {
            hasher.update(data: Data([entry.kind.rawValue]))
            let path = Data(entry.relativePath.utf8)
            hasher.update(data: encoded(UInt32(path.count)))
            hasher.update(data: path)
            hasher.update(data: encoded(entry.permissions))
            hasher.update(data: encoded(entry.size))
            hasher.update(data: entry.contentDigest)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Summary(
            fileCount: regularFileCount,
            installedSize: installedSize,
            treeSHA256: digest
        )
    }

    private static func contentDigest(of url: URL, matching expected: stat) throws -> Data {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o022 == 0,
              before.st_nlink == 1,
              before.st_dev == expected.st_dev,
              before.st_ino == expected.st_ino,
              before.st_size == expected.st_size else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw WebRuntimeDistributionError.unsafePayload
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw WebRuntimeDistributionError.unsafePayload
        }
        return Data(hasher.finalize())
    }

    private static func encoded<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
