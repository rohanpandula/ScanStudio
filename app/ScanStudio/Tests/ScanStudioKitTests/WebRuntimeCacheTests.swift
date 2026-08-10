import Darwin
import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Optional web runtime verified cache")
struct WebRuntimeCacheTests {
    @Test("nested ordinary directories verify and install for launch")
    func nestedPayloadInstalls() async throws {
        let test = try CacheFixture()
        defer { test.cleanUp() }
        let payload = try test.makePayload(named: "first")
        let release = try test.release(
            payload: payload,
            artifactSHA256: String(repeating: "a", count: 64)
        )
        let cache = test.makeCache()

        let installed = try await cache.install(
            preparedPayloadAt: payload.url,
            release: release
        )
        let launched = try await cache.verifiedRuntimeForLaunch(
            matching: test.distribution.request
        )

        #expect(installed.runtimeVersion == test.distribution.request.hostVersionString)
        #expect(launched == installed)
        #expect(launched.executableURL.lastPathComponent == "scanstudio-web-runtime")
        #expect(launched.staticDirectoryURL.lastPathComponent == "WebFrontend")
    }

    @Test("same verified installation is selected without replacing its directory")
    func repeatedInstallReusesVerifiedDirectory() async throws {
        let test = try CacheFixture()
        defer { test.cleanUp() }
        let payload = try test.makePayload(named: "same")
        let release = try test.release(
            payload: payload,
            artifactSHA256: String(repeating: "a", count: 64)
        )
        let cache = test.makeCache()
        _ = try await cache.install(preparedPayloadAt: payload.url, release: release)
        let versionDirectory = try #require(test.versionDirectories().first)
        var before = stat()
        #expect(lstat(versionDirectory.path, &before) == 0)

        _ = try await cache.install(preparedPayloadAt: payload.url, release: release)
        let afterDirectory = try #require(test.versionDirectories().first)
        var after = stat()
        #expect(lstat(afterDirectory.path, &after) == 0)

        #expect(before.st_ino == after.st_ino)
    }

    @Test("tampered current runtime atomically falls back to verified previous")
    func tamperedCurrentRollsBack() async throws {
        let test = try CacheFixture()
        defer { test.cleanUp() }
        let firstPayload = try test.makePayload(named: "first")
        let secondPayload = try test.makePayload(named: "second")
        let first = try test.release(
            payload: firstPayload,
            artifactSHA256: String(repeating: "a", count: 64)
        )
        let second = try test.release(
            payload: secondPayload,
            artifactSHA256: String(repeating: "c", count: 64)
        )
        let cache = test.makeCache()
        let firstInstalled = try await cache.install(
            preparedPayloadAt: firstPayload.url,
            release: first
        )
        let current = try await cache.install(
            preparedPayloadAt: secondPayload.url,
            release: second
        )
        try Data("tampered".utf8).write(to: current.executableURL)
        chmod(current.executableURL.path, mode_t(0o755))

        let recovered = try await cache.verifiedRuntimeForLaunch(
            matching: test.distribution.request
        )
        let nextLaunch = try await cache.verifiedRuntimeForLaunch(
            matching: test.distribution.request
        )

        #expect(recovered.rootURL == firstInstalled.rootURL)
        #expect(nextLaunch.rootURL == firstInstalled.rootURL)
    }

    @Test("failed replacement restores the prior directory")
    func failedReplacementRestoresPriorDirectory() async throws {
        let test = try CacheFixture()
        defer { test.cleanUp() }
        let payload = try test.makePayload(named: "rollback")
        let release = try test.release(
            payload: payload,
            artifactSHA256: String(repeating: "d", count: 64)
        )
        let cache = test.makeCache()
        let installed = try await cache.install(
            preparedPayloadAt: payload.url,
            release: release
        )
        let oldMarker = Data("old-invalid-copy".utf8)
        try oldMarker.write(to: installed.executableURL)
        chmod(installed.executableURL.path, mode_t(0o755))

        // Force selection persistence to fail after the valid replacement has
        // reached its final directory. The catch path must move the new tree
        // away and restore this exact old (invalid) cache directory.
        let selection = test.cacheRoot.appendingPathComponent("selection.json")
        try FileManager.default.removeItem(at: selection)
        try FileManager.default.createDirectory(at: selection, withIntermediateDirectories: false)

        await #expect(throws: WebRuntimeDistributionError.self) {
            try await cache.install(preparedPayloadAt: payload.url, release: release)
        }
        let restoredExecutable = try #require(
            test.versionDirectories().first?
                .appendingPathComponent(
                    "ScanStudioWebRuntime.bundle/Contents/MacOS/scanstudio-web-runtime"
                )
        )
        #expect(try Data(contentsOf: restoredExecutable) == oldMarker)
    }

    @Test("cancellation after replacement restores the prior directory")
    func cancelledReplacementRestoresPriorDirectory() async throws {
        let test = try CacheFixture()
        defer { test.cleanUp() }
        let payload = try test.makePayload(named: "cancel-rollback")
        let release = try test.release(
            payload: payload,
            artifactSHA256: String(repeating: "f", count: 64)
        )
        let verifier = CancellationReplacementPayloadVerifier(
            identity: test.identity
        )
        let cache = WebRuntimeCacheInstaller(
            rootDirectoryURL: test.cacheRoot,
            lock: NoopRuntimeLock(),
            signatureVerifier: test.distribution.signatureVerifier,
            payloadVerifier: verifier
        )
        _ = try await cache.install(preparedPayloadAt: payload.url, release: release)
        let beforeDirectory = try #require(test.versionDirectories().first)
        var before = stat()
        #expect(lstat(beforeDirectory.path, &before) == 0)
        verifier.cancelAfterReplacement()

        await #expect(throws: WebRuntimeDistributionError.cancelled) {
            try await cache.install(preparedPayloadAt: payload.url, release: release)
        }
        let restoredDirectory = try #require(test.versionDirectories().first)
        var restored = stat()
        #expect(lstat(restoredDirectory.path, &restored) == 0)
        #expect(restored.st_ino == before.st_ino)
    }

    @Test("task cancellation after staged verification never changes selection")
    func taskCancellationBeforeSelectionPreservesCurrent() async throws {
        let test = try CacheFixture()
        defer { test.cleanUp() }
        let currentPayload = try test.makePayload(named: "current")
        let candidatePayload = try test.makePayload(named: "candidate")
        let currentRelease = try test.release(
            payload: currentPayload,
            artifactSHA256: String(repeating: "1", count: 64)
        )
        let candidateRelease = try test.release(
            payload: candidatePayload,
            artifactSHA256: String(repeating: "2", count: 64)
        )
        let currentCache = test.makeCache()
        let current = try await currentCache.install(
            preparedPayloadAt: currentPayload.url,
            release: currentRelease
        )

        let checkpointVerifier = CancellationCheckpointPayloadVerifier(
            identity: test.identity
        )
        let cancellingCache = WebRuntimeCacheInstaller(
            rootDirectoryURL: test.cacheRoot,
            lock: NoopRuntimeLock(),
            signatureVerifier: test.distribution.signatureVerifier,
            payloadVerifier: checkpointVerifier
        )
        let installation = Task.detached {
            try await cancellingCache.install(
                preparedPayloadAt: candidatePayload.url,
                release: candidateRelease
            )
        }
        #expect(checkpointVerifier.waitUntilStagedVerification())
        installation.cancel()
        checkpointVerifier.resumeStagedVerification()

        await #expect(throws: WebRuntimeDistributionError.cancelled) {
            try await installation.value
        }
        let stillSelected = try await cancellingCache.verifiedRuntimeForLaunch(
            matching: test.distribution.request
        )
        #expect(stillSelected.rootURL == current.rootURL)
        #expect(try test.versionDirectories().count == 1)
    }

    @Test("cache keeps its cross-process lease through verification and selection")
    func leaseLifetimeCoversCriticalSection() async throws {
        let test = try CacheFixture()
        defer { test.cleanUp() }
        let lock = TrackingRuntimeLock()
        let verifier = LockAwarePayloadVerifier(
            lock: lock,
            identity: test.identity
        )
        let cache = WebRuntimeCacheInstaller(
            rootDirectoryURL: test.cacheRoot,
            lock: lock,
            signatureVerifier: test.distribution.signatureVerifier,
            payloadVerifier: verifier
        )
        let payload = try test.makePayload(named: "lease")
        let release = try test.release(
            payload: payload,
            artifactSHA256: String(repeating: "e", count: 64)
        )

        _ = try await cache.install(preparedPayloadAt: payload.url, release: release)
        _ = try await cache.verifiedRuntimeForLaunch(matching: test.distribution.request)

        #expect(lock.acquireCount == 2)
        #expect(!lock.isHeld)
    }

    @Test("real file lock excludes a second process participant until lease release")
    func realFileLockExcludesSecondParticipant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebRuntimeLockTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try WebRuntimeFileLock(directoryURL: root, timeoutSeconds: 1)
        let second = try WebRuntimeFileLock(directoryURL: root, timeoutSeconds: 0.05)
        var lease: (any WebRuntimeLockLease)? = try first.acquire()

        let _: Void = withExtendedLifetime(lease) {
            #expect(throws: WebRuntimeDistributionError.cacheLockTimedOut) {
                try second.acquire()
            }
        }
        lease = nil
        _ = try second.acquire()
    }

    @Test("symlink and hard-linked regular files fail closed")
    func linksReject() throws {
        let test = try CacheFixture()
        defer { test.cleanUp() }
        let payload = try test.makePayload(named: "links")
        let symlink = payload.url.appendingPathComponent(
            "Contents/Resources/WebFrontend/escape"
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        #expect(throws: WebRuntimeDistributionError.unsafePayload) {
            try WebRuntimePayloadTreeHash.compute(
                at: payload.url,
                maximumEntries: payload.summary.fileCount,
                maximumBytes: payload.summary.installedSize
            )
        }

        try FileManager.default.removeItem(at: symlink)
        let hardLink = payload.url.appendingPathComponent(
            "Contents/Resources/WebFrontend/index-copy.html"
        )
        try FileManager.default.linkItem(
            at: payload.url.appendingPathComponent(
                "Contents/Resources/WebFrontend/index.html"
            ),
            to: hardLink
        )
        #expect(throws: WebRuntimeDistributionError.unsafePayload) {
            try WebRuntimePayloadTreeHash.compute(
                at: payload.url,
                maximumEntries: payload.summary.fileCount + 1,
                maximumBytes: payload.summary.installedSize * 2
            )
        }

        try FileManager.default.removeItem(at: hardLink)
        chmod(payload.url.path, mode_t(0o777))
        #expect(throws: WebRuntimeDistributionError.unsafePayload) {
            try WebRuntimePayloadTreeHash.compute(
                at: payload.url,
                maximumEntries: payload.summary.fileCount,
                maximumBytes: payload.summary.installedSize
            )
        }
    }

    @Test("file lock rejects non-finite or unbounded wait intervals")
    func fileLockTimeoutIsBounded() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebRuntimeLockBounds-\(UUID().uuidString)",
            isDirectory: true
        )
        #expect(throws: WebRuntimeDistributionError.invalidRequest) {
            try WebRuntimeFileLock(directoryURL: directory, timeoutSeconds: .infinity)
        }
        #expect(throws: WebRuntimeDistributionError.invalidRequest) {
            try WebRuntimeFileLock(directoryURL: directory, timeoutSeconds: 301)
        }
    }
}

private final class CacheFixture: @unchecked Sendable {
    struct Payload {
        let url: URL
        let summary: WebRuntimePayloadTreeHash.Summary
    }

    let root: URL
    let cacheRoot: URL
    let distribution: RuntimeDistributionFixture
    let identity: WebRuntimeCodeIdentityAssertion

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebRuntimeCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
        cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        distribution = try RuntimeDistributionFixture()
        identity = WebRuntimeCodeIdentityAssertion(
            bundleIdentifier: "com.scanstudio.WebRuntime",
            teamIdentifier: "TESTTEAM1",
            developerIDSigned: true,
            notarized: true
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func makePayload(named name: String) throws -> Payload {
        let payload = root.appendingPathComponent(
            "\(name)-ScanStudioWebRuntime.bundle",
            isDirectory: true
        )
        let bin = payload.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let staticDirectory = payload.appendingPathComponent(
            "Contents/Resources/WebFrontend",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staticDirectory, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("scanstudio-web-runtime")
        let executableData = Data("#!/bin/sh\nexit 0\n".utf8)
        let indexData = Data("<html>ScanStudio</html>\n".utf8)
        try executableData.write(to: executable)
        chmod(executable.path, mode_t(0o755))
        try indexData.write(to: staticDirectory.appendingPathComponent("index.html"))
        let installedSize = Int64(executableData.count + indexData.count)
        let summary = try WebRuntimePayloadTreeHash.compute(
            at: payload,
            maximumEntries: 2,
            maximumBytes: installedSize
        )
        return Payload(url: payload, summary: summary)
    }

    func release(
        payload: Payload,
        artifactSHA256: String
    ) throws -> VerifiedWebRuntimeRelease {
        try distribution.verifiedRelease(
            treeSHA256: payload.summary.treeSHA256,
            fileCount: payload.summary.fileCount,
            installedSize: payload.summary.installedSize,
            artifactSHA256: artifactSHA256
        )
    }

    func makeCache() -> WebRuntimeCacheInstaller {
        WebRuntimeCacheInstaller(
            rootDirectoryURL: cacheRoot,
            lock: NoopRuntimeLock(),
            signatureVerifier: distribution.signatureVerifier,
            payloadVerifier: FileSystemWebRuntimePayloadVerifier(
                codeAssessor: FakeRuntimeCodeAssessor(identity: identity)
            )
        )
    }

    func versionDirectories() throws -> [URL] {
        let versions = cacheRoot.appendingPathComponent("versions", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: versions,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}

private struct FakeRuntimeCodeAssessor: WebRuntimeCodeAssessing {
    let identity: WebRuntimeCodeIdentityAssertion

    func assessPayload(
        at rootURL: URL,
        executableURL: URL
    ) -> WebRuntimeCodeIdentityAssertion {
        identity
    }
}

private final class NoopRuntimeLease: WebRuntimeLockLease, @unchecked Sendable {}

private struct NoopRuntimeLock: WebRuntimeCrossProcessLocking {
    func acquire() -> any WebRuntimeLockLease { NoopRuntimeLease() }
}

private final class TrackingRuntimeLock: WebRuntimeCrossProcessLocking,
    @unchecked Sendable
{
    private let mutex = NSLock()
    private var held = false
    private var acquisitions = 0

    var isHeld: Bool { mutex.withLock { held } }
    var acquireCount: Int { mutex.withLock { acquisitions } }

    func acquire() throws -> any WebRuntimeLockLease {
        try mutex.withLock {
            guard !held else { throw WebRuntimeDistributionError.cacheLockTimedOut }
            held = true
            acquisitions += 1
        }
        return TrackingRuntimeLease(lock: self)
    }

    fileprivate func release() {
        mutex.withLock { held = false }
    }
}

private final class TrackingRuntimeLease: WebRuntimeLockLease, @unchecked Sendable {
    private let lock: TrackingRuntimeLock
    init(lock: TrackingRuntimeLock) { self.lock = lock }
    deinit { lock.release() }
}

private struct LockAwarePayloadVerifier: WebRuntimePayloadVerifying {
    let lock: TrackingRuntimeLock
    let identity: WebRuntimeCodeIdentityAssertion

    func verifyPayload(
        at rootURL: URL,
        against manifest: WebRuntimeManifest
    ) throws -> WebRuntimePayloadVerification {
        guard lock.isHeld else { throw WebRuntimeDistributionError.cacheLockTimedOut }
        return WebRuntimePayloadVerification(
            codeIdentity: identity,
            fileCount: manifest.payload.fileCount,
            installedSize: manifest.payload.installedSize,
            treeSHA256: manifest.payload.treeSHA256
        )
    }
}

private final class CancellationReplacementPayloadVerifier: WebRuntimePayloadVerifying,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let identity: WebRuntimeCodeIdentityAssertion
    private var cancellationMode = false
    private var modeCalls = 0

    init(identity: WebRuntimeCodeIdentityAssertion) {
        self.identity = identity
    }

    func cancelAfterReplacement() {
        lock.withLock {
            cancellationMode = true
            modeCalls = 0
        }
    }

    func verifyPayload(
        at rootURL: URL,
        against manifest: WebRuntimeManifest
    ) throws -> WebRuntimePayloadVerification {
        let action: Int = lock.withLock {
            guard cancellationMode else { return 0 }
            modeCalls += 1
            return modeCalls
        }
        // Second call is verification of the existing final directory, which
        // forces the replacement path. Fourth is verification after the new
        // staging directory has been moved to its final name.
        if action == 2 { throw WebRuntimeDistributionError.unsafePayload }
        if action == 4 { throw CancellationError() }
        return WebRuntimePayloadVerification(
            codeIdentity: identity,
            fileCount: manifest.payload.fileCount,
            installedSize: manifest.payload.installedSize,
            treeSHA256: manifest.payload.treeSHA256
        )
    }
}

private final class CancellationCheckpointPayloadVerifier: WebRuntimePayloadVerifying,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let identity: WebRuntimeCodeIdentityAssertion
    private let stagedVerificationReached = DispatchSemaphore(value: 0)
    private let stagedVerificationMayReturn = DispatchSemaphore(value: 0)
    private var callCount = 0

    init(identity: WebRuntimeCodeIdentityAssertion) {
        self.identity = identity
    }

    func waitUntilStagedVerification() -> Bool {
        stagedVerificationReached.wait(timeout: .now() + 2) == .success
    }

    func resumeStagedVerification() {
        stagedVerificationMayReturn.signal()
    }

    func verifyPayload(
        at rootURL: URL,
        against manifest: WebRuntimeManifest
    ) throws -> WebRuntimePayloadVerification {
        let call = lock.withLock {
            callCount += 1
            return callCount
        }
        if call == 2 {
            stagedVerificationReached.signal()
            guard stagedVerificationMayReturn.wait(timeout: .now() + 2) == .success else {
                throw WebRuntimeDistributionError.commandTimedOut
            }
        }
        return WebRuntimePayloadVerification(
            codeIdentity: identity,
            fileCount: manifest.payload.fileCount,
            installedSize: manifest.payload.installedSize,
            treeSHA256: manifest.payload.treeSHA256
        )
    }
}
