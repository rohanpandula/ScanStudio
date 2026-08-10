// Integration-facing coordinator for the optional browser runtime. The UI can
// inspect a launch-verified current install, resolve signed metadata for a
// consent prompt, and explicitly download/install that exact offer.

import Darwin
import Foundation

public struct WebRuntimeDownloadOffer: Equatable, Sendable {
    let release: VerifiedWebRuntimeRelease

    public var hostVersion: String { release.manifest.hostVersion }
    public var runtimeVersion: String { release.manifest.runtimeVersion }
    public var architecture: HostArchitecture { release.manifest.architecture }
    public var downloadSize: Int64 { release.manifest.artifact.size }
    public var developerIDSigned: Bool { release.manifest.payload.developerIDSigned }
    public var notarized: Bool { release.manifest.payload.notarized }
    public var sourceURL: URL { release.manifest.artifact.url }

    public init(release: VerifiedWebRuntimeRelease) {
        self.release = release
    }
}

public enum WebRuntimeInspection: Equatable, Sendable {
    case notInstalled
    case ready(InstalledWebRuntime)
    case invalid(WebRuntimeDistributionError)
}

public enum WebRuntimeInstallProgress: Equatable, Sendable {
    case resolvingMetadata
    case downloading
    case preparing
    case installing
    case verifyingForLaunch
    case complete
}

public enum WebRuntimeManagerState: Equatable, Sendable {
    case idle
    case resolvingMetadata
    case offerReady(WebRuntimeDownloadOffer)
    case installing(WebRuntimeInstallProgress)
    case ready(InstalledWebRuntime)
    case failed(WebRuntimeDistributionError)
}

public protocol WebRuntimePayloadPreparing: Sendable {
    /// Mounts/opens an already size-and-hash-verified release image and returns
    /// its single payload root. Implementations must use a read-only mount or
    /// equivalently safe extraction and leave code assessment to the cache's
    /// mandatory payload verifier.
    func preparePayload(
        fromVerifiedImage imageURL: URL,
        release: VerifiedWebRuntimeRelease,
        in workingDirectory: URL
    ) async throws -> URL
}

public struct UnavailableWebRuntimePayloadPreparer: WebRuntimePayloadPreparing {
    public init() {}

    public func preparePayload(
        fromVerifiedImage imageURL: URL,
        release: VerifiedWebRuntimeRelease,
        in workingDirectory: URL
    ) async throws -> URL {
        throw WebRuntimeDistributionError.payloadPreparationUnavailable
    }
}

public protocol WebRuntimeManaging: Sendable {
    /// Re-verifies signature, compatibility, tree hash, and code identity on
    /// each call. This is the entry point the native host uses before launch.
    func inspectVerifiedCurrent(
        for request: WebRuntimeReleaseRequest
    ) async -> WebRuntimeInspection

    /// Fetches only the small signed metadata needed for informed consent. It
    /// does not download or install executable code.
    func resolveMetadataForConsent(
        for request: WebRuntimeReleaseRequest
    ) async throws -> WebRuntimeDownloadOffer

    /// Installs exactly the already-authenticated offer the user accepted.
    /// Returns a launch-ready `WebServerRuntime` after one final verification.
    func install(
        _ offer: WebRuntimeDownloadOffer,
        progress: @escaping @Sendable (WebRuntimeInstallProgress) -> Void
    ) async throws -> WebServerRuntime

    func runtimeForLaunch(
        for request: WebRuntimeReleaseRequest
    ) async throws -> WebServerRuntime
}

public actor WebRuntimeManager: WebRuntimeManaging {
    public private(set) var state: WebRuntimeManagerState = .idle

    private let downloader: any WebRuntimeReleaseDownloading
    private let payloadPreparer: any WebRuntimePayloadPreparing
    private let cache: any WebRuntimeCacheInstalling
    private let scratchRootURL: URL
    private var operationActive = false

    public init(
        downloader: any WebRuntimeReleaseDownloading,
        payloadPreparer: any WebRuntimePayloadPreparing =
            UnavailableWebRuntimePayloadPreparer(),
        cache: any WebRuntimeCacheInstalling,
        scratchRootURL: URL
    ) {
        self.downloader = downloader
        self.payloadPreparer = payloadPreparer
        self.cache = cache
        self.scratchRootURL = scratchRootURL
    }

    public func inspectVerifiedCurrent(
        for request: WebRuntimeReleaseRequest
    ) async -> WebRuntimeInspection {
        do {
            let runtime = try await cache.verifiedRuntimeForLaunch(matching: request)
            state = .ready(runtime)
            return .ready(runtime)
        } catch WebRuntimeDistributionError.noVerifiedInstallation {
            state = .idle
            return .notInstalled
        } catch let error as WebRuntimeDistributionError {
            state = .failed(error)
            return .invalid(error)
        } catch {
            state = .failed(.cacheUnavailable)
            return .invalid(.cacheUnavailable)
        }
    }

    public func resolveMetadataForConsent(
        for request: WebRuntimeReleaseRequest
    ) async throws -> WebRuntimeDownloadOffer {
        guard !operationActive else {
            throw WebRuntimeDistributionError.operationInProgress
        }
        operationActive = true
        defer { operationActive = false }
        state = .resolvingMetadata
        do {
            let release = try await downloader.resolve(request)
            let offer = WebRuntimeDownloadOffer(release: release)
            state = .offerReady(offer)
            return offer
        } catch let error as WebRuntimeDistributionError {
            state = .failed(error)
            throw error
        } catch is CancellationError {
            state = .failed(.cancelled)
            throw WebRuntimeDistributionError.cancelled
        } catch {
            state = .failed(.transportFailed)
            throw WebRuntimeDistributionError.transportFailed
        }
    }

    public func install(
        _ offer: WebRuntimeDownloadOffer,
        progress: @escaping @Sendable (WebRuntimeInstallProgress) -> Void = { _ in }
    ) async throws -> WebServerRuntime {
        guard !operationActive else {
            throw WebRuntimeDistributionError.operationInProgress
        }
        operationActive = true
        defer { operationActive = false }

        let operationDirectory = scratchRootURL.appendingPathComponent(
            "operation-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try Self.ensurePrivateDirectory(
                scratchRootURL,
                withIntermediateDirectories: true
            )
            try Self.ensurePrivateDirectory(
                operationDirectory,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: operationDirectory) }

            try Task.checkCancellation()
            progress(.downloading)
            state = .installing(.downloading)
            let imageURL = try await downloader.downloadArtifact(
                for: offer.release,
                to: operationDirectory
            )

            try Task.checkCancellation()
            progress(.preparing)
            state = .installing(.preparing)
            let prepared = try await payloadPreparer.preparePayload(
                fromVerifiedImage: imageURL,
                release: offer.release,
                in: operationDirectory
            )

            try Task.checkCancellation()
            progress(.installing)
            state = .installing(.installing)
            _ = try await cache.install(
                preparedPayloadAt: prepared,
                release: offer.release
            )

            progress(.verifyingForLaunch)
            state = .installing(.verifyingForLaunch)
            let runtime = try await cache.verifiedRuntimeForLaunch(
                matching: offer.release.request
            )
            progress(.complete)
            state = .ready(runtime)
            return runtime.webServerRuntime
        } catch is CancellationError {
            state = .failed(.cancelled)
            throw WebRuntimeDistributionError.cancelled
        } catch let error as WebRuntimeDistributionError {
            state = .failed(error)
            throw error
        } catch {
            state = .failed(.cacheUnavailable)
            throw WebRuntimeDistributionError.cacheUnavailable
        }
    }

    public func runtimeForLaunch(
        for request: WebRuntimeReleaseRequest
    ) async throws -> WebServerRuntime {
        do {
            let runtime = try await cache.verifiedRuntimeForLaunch(matching: request)
            state = .ready(runtime)
            return runtime.webServerRuntime
        } catch let error as WebRuntimeDistributionError {
            state = .failed(error)
            throw error
        } catch {
            state = .failed(.cacheUnavailable)
            throw WebRuntimeDistributionError.cacheUnavailable
        }
    }

    private static func ensurePrivateDirectory(
        _ url: URL,
        withIntermediateDirectories: Bool
    ) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: withIntermediateDirectories,
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
}
