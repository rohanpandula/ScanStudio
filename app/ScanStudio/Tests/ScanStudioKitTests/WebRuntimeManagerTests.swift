import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Optional web runtime manager")
struct WebRuntimeManagerTests {
    @Test("launch inspection distinguishes absent invalid and verified installs")
    func inspectionStates() async throws {
        let fixture = try ManagerFixture()
        defer { fixture.cleanUp() }

        let missingCache = ManagerCache(
            runtime: fixture.installed,
            lookupError: .noVerifiedInstallation
        )
        let missing = fixture.manager(cache: missingCache)
        #expect(
            await missing.inspectVerifiedCurrent(for: fixture.distribution.request)
                == .notInstalled
        )

        let invalidCache = ManagerCache(
            runtime: fixture.installed,
            lookupError: .unsafePayload
        )
        let invalid = fixture.manager(cache: invalidCache)
        #expect(
            await invalid.inspectVerifiedCurrent(for: fixture.distribution.request)
                == .invalid(.unsafePayload)
        )

        let readyCache = ManagerCache(runtime: fixture.installed)
        let ready = fixture.manager(cache: readyCache)
        #expect(
            await ready.inspectVerifiedCurrent(for: fixture.distribution.request)
                == .ready(fixture.installed)
        )
    }

    @Test("consent resolution fetches only signed metadata")
    func resolvesConsentMetadataOnly() async throws {
        let fixture = try ManagerFixture()
        defer { fixture.cleanUp() }
        let downloader = ManagerDownloader(
            release: fixture.release,
            imageURL: fixture.imageURL
        )
        let manager = fixture.manager(
            downloader: downloader,
            cache: ManagerCache(runtime: fixture.installed)
        )

        let offer = try await manager.resolveMetadataForConsent(
            for: fixture.distribution.request
        )
        let counts = await downloader.counts()

        #expect(offer.hostVersion == fixture.distribution.request.hostVersionString)
        #expect(offer.runtimeVersion == fixture.release.manifest.runtimeVersion)
        #expect(offer.architecture == .arm64)
        #expect(offer.downloadSize == fixture.release.manifest.artifact.size)
        #expect(offer.developerIDSigned)
        #expect(offer.notarized)
        #expect(offer.sourceURL == fixture.distribution.request.diskImageURL)
        #expect(counts.resolve == 1)
        #expect(counts.download == 0)
        #expect(await manager.state == .offerReady(offer))
    }

    @Test("accepted offer installs with progress and is reverified before launch")
    func installsAndReverifies() async throws {
        let fixture = try ManagerFixture()
        defer { fixture.cleanUp() }
        // Model the first launch, before the app has ever created its runtime
        // download cache.
        try FileManager.default.removeItem(at: fixture.scratch)
        let downloader = ManagerDownloader(
            release: fixture.release,
            imageURL: fixture.imageURL
        )
        let preparer = ManagerPayloadPreparer(payloadURL: fixture.payloadURL)
        let cache = ManagerCache(runtime: fixture.installed)
        let manager = fixture.manager(
            downloader: downloader,
            preparer: preparer,
            cache: cache
        )
        let progress = ProgressRecorder()
        let offer = try await manager.resolveMetadataForConsent(
            for: fixture.distribution.request
        )

        let runtime = try await manager.install(offer) { update in
            progress.append(update)
        }

        #expect(runtime == fixture.installed.webServerRuntime)
        #expect(progress.values == [
            .downloading, .preparing, .installing, .verifyingForLaunch, .complete,
        ])
        #expect(await downloader.counts().download == 1)
        #expect(await preparer.callCount == 1)
        let cacheCounts = await cache.counts()
        #expect(cacheCounts.install == 1)
        #expect(cacheCounts.launchVerification == 1)
        #expect(await manager.state == .ready(fixture.installed))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path).isEmpty
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.scratch.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test("every runtime request goes through cache launch verification")
    func runtimeForLaunchAlwaysReverifies() async throws {
        let fixture = try ManagerFixture()
        defer { fixture.cleanUp() }
        let cache = ManagerCache(runtime: fixture.installed)
        let manager = fixture.manager(cache: cache)

        _ = try await manager.runtimeForLaunch(for: fixture.distribution.request)
        _ = try await manager.runtimeForLaunch(for: fixture.distribution.request)

        #expect(await cache.counts().launchVerification == 2)
    }

    @Test("distribution errors provide a UI-safe localized description")
    func errorsAreLocalizable() {
        let errors: [WebRuntimeDistributionError] = [
            .signatureVerifierUnavailable,
            .invalidSignature,
            .redirectRejected,
            .transportFailed,
            .diskImageDetachFailed,
            .cacheLockTimedOut,
            .noVerifiedInstallation,
            .cancelled,
        ]
        #expect(errors.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }
}

private final class ManagerFixture: @unchecked Sendable {
    let root: URL
    let scratch: URL
    let imageURL: URL
    let payloadURL: URL
    let distribution: RuntimeDistributionFixture
    let release: VerifiedWebRuntimeRelease
    let installed: InstalledWebRuntime

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebRuntimeManagerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        scratch = root.appendingPathComponent("scratch", isDirectory: true)
        imageURL = root.appendingPathComponent("runtime.dmg")
        payloadURL = root.appendingPathComponent(
            "ScanStudioWebRuntime.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadURL, withIntermediateDirectories: false)
        try Data("verified image".utf8).write(to: imageURL)
        distribution = try RuntimeDistributionFixture()
        release = try distribution.verifiedRelease()
        let executable = payloadURL.appendingPathComponent(
            WebRuntimeReleaseRequest.executableRelativePath
        )
        let staticDirectory = payloadURL.appendingPathComponent(
            WebRuntimeReleaseRequest.staticDirectoryRelativePath,
            isDirectory: true
        )
        installed = InstalledWebRuntime(
            hostVersion: release.manifest.hostVersion,
            runtimeVersion: release.manifest.runtimeVersion,
            architecture: release.manifest.architecture,
            rootURL: payloadURL,
            executableURL: executable,
            staticDirectoryURL: staticDirectory,
            codeIdentity: WebRuntimeCodeIdentityAssertion(
                bundleIdentifier: release.manifest.payload.bundleIdentifier,
                teamIdentifier: release.manifest.payload.teamIdentifier,
                developerIDSigned: release.manifest.payload.developerIDSigned,
                notarized: release.manifest.payload.notarized
            )
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func manager(
        downloader: (any WebRuntimeReleaseDownloading)? = nil,
        preparer: (any WebRuntimePayloadPreparing)? = nil,
        cache: any WebRuntimeCacheInstalling
    ) -> WebRuntimeManager {
        WebRuntimeManager(
            downloader: downloader ?? ManagerDownloader(
                release: release,
                imageURL: imageURL
            ),
            payloadPreparer: preparer ?? ManagerPayloadPreparer(payloadURL: payloadURL),
            cache: cache,
            scratchRootURL: scratch
        )
    }
}

private actor ManagerDownloader: WebRuntimeReleaseDownloading {
    private let release: VerifiedWebRuntimeRelease
    private let imageURL: URL
    private var resolveCount = 0
    private var downloadCount = 0

    init(release: VerifiedWebRuntimeRelease, imageURL: URL) {
        self.release = release
        self.imageURL = imageURL
    }

    func resolve(_ request: WebRuntimeReleaseRequest) throws -> VerifiedWebRuntimeRelease {
        resolveCount += 1
        guard request == release.request else {
            throw WebRuntimeDistributionError.invalidRequest
        }
        return release
    }

    func downloadArtifact(
        for requestedRelease: VerifiedWebRuntimeRelease,
        to directory: URL
    ) throws -> URL {
        downloadCount += 1
        guard requestedRelease == release else {
            throw WebRuntimeDistributionError.invalidRequest
        }
        return imageURL
    }

    func counts() -> (resolve: Int, download: Int) {
        (resolveCount, downloadCount)
    }
}

private actor ManagerPayloadPreparer: WebRuntimePayloadPreparing {
    private let payloadURL: URL
    private(set) var callCount = 0

    init(payloadURL: URL) {
        self.payloadURL = payloadURL
    }

    func preparePayload(
        fromVerifiedImage imageURL: URL,
        release: VerifiedWebRuntimeRelease,
        in workingDirectory: URL
    ) throws -> URL {
        callCount += 1
        return payloadURL
    }
}

private actor ManagerCache: WebRuntimeCacheInstalling {
    private let runtime: InstalledWebRuntime
    private let lookupError: WebRuntimeDistributionError?
    private var installCount = 0
    private var launchVerificationCount = 0

    init(
        runtime: InstalledWebRuntime,
        lookupError: WebRuntimeDistributionError? = nil
    ) {
        self.runtime = runtime
        self.lookupError = lookupError
    }

    func install(
        preparedPayloadAt payloadURL: URL,
        release: VerifiedWebRuntimeRelease
    ) throws -> InstalledWebRuntime {
        installCount += 1
        return runtime
    }

    func verifiedRuntimeForLaunch(
        matching request: WebRuntimeReleaseRequest
    ) throws -> InstalledWebRuntime {
        launchVerificationCount += 1
        if let lookupError { throw lookupError }
        return runtime
    }

    func counts() -> (install: Int, launchVerification: Int) {
        (installCount, launchVerificationCount)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [WebRuntimeInstallProgress] = []

    var values: [WebRuntimeInstallProgress] {
        lock.withLock { recorded }
    }

    func append(_ value: WebRuntimeInstallProgress) {
        lock.withLock { recorded.append(value) }
    }
}
