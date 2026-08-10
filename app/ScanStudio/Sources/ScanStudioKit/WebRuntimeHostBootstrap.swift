// Production wiring for the optional, separately downloaded browser runtime.
// The normal app bundle contains no runtime code. Releases that publish the
// optional component stamp only its public verification key and Developer ID
// Team ID into Info.plist so the host can authenticate exact-version assets.

import Foundation

public struct WebRuntimeHostServices: Sendable {
    public let manager: any WebRuntimeManaging
    public let request: WebRuntimeReleaseRequest

    public init(
        manager: any WebRuntimeManaging,
        request: WebRuntimeReleaseRequest
    ) {
        self.manager = manager
        self.request = request
    }
}

public enum WebRuntimeHostBootstrap {
    public static let releaseVersionKey = "ScanStudioRelease"
    public static let publicKeyInfoKey = "ScanStudioWebRuntimeEd25519PublicKey"
    public static let teamIdentifierInfoKey = "ScanStudioWebRuntimeTeamIdentifier"
    public static let bundleIdentifier = "dev.scanstudio.live.web-runtime"

    public static func makeServices(
        infoDictionary: [String: Any],
        applicationSupportDirectory: URL,
        cachesDirectory: URL,
        httpClient: any WebRuntimeHTTPClient = URLSessionWebRuntimeHTTPClient(),
        payloadPreparer: (any WebRuntimePayloadPreparing)? = nil,
        codeAssessor: any WebRuntimeCodeAssessing = SystemWebRuntimeCodeAssessor()
    ) throws -> WebRuntimeHostServices {
        guard let hostVersion = infoDictionary[releaseVersionKey] as? String,
              let encodedPublicKey = infoDictionary[publicKeyInfoKey] as? String,
              let teamIdentifier = infoDictionary[teamIdentifierInfoKey] as? String,
              !hostVersion.isEmpty,
              !encodedPublicKey.isEmpty,
              !teamIdentifier.isEmpty,
              let publicKey = Data(base64Encoded: encodedPublicKey),
              publicKey.count == 32,
              publicKey.base64EncodedString() == encodedPublicKey else {
            throw WebRuntimeDistributionError.productionTrustUnavailable
        }

        let signatureVerifier: Ed25519WebRuntimeSignatureVerifier
        let identity: WebRuntimeExpectedCodeIdentity
        let request: WebRuntimeReleaseRequest
        do {
            signatureVerifier = try Ed25519WebRuntimeSignatureVerifier(
                publicKeyRawRepresentation: publicKey
            )
            identity = try WebRuntimeExpectedCodeIdentity(
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: teamIdentifier
            )
            request = try WebRuntimeReleaseRequest(
                hostVersion: hostVersion,
                architecture: HostArchitectureProvider.current(),
                protocolVersion: 1,
                expectedCodeIdentity: identity
            )
        } catch {
            throw WebRuntimeDistributionError.productionTrustUnavailable
        }

        let payloadVerifier = FileSystemWebRuntimePayloadVerifier(
            codeAssessor: codeAssessor
        )
        let cacheRoot = applicationSupportDirectory
            .appendingPathComponent("ScanStudio/WebRuntime", isDirectory: true)
        let downloadRoot = cachesDirectory
            .appendingPathComponent("ScanStudio/WebRuntime/Downloads", isDirectory: true)
        let cache = try WebRuntimeCacheInstaller(
            rootDirectoryURL: cacheRoot,
            signatureVerifier: signatureVerifier,
            payloadVerifier: payloadVerifier
        )
        let downloader = GitHubWebRuntimeDownloader(
            httpClient: httpClient,
            signatureVerifier: signatureVerifier
        )
        let preparer = payloadPreparer ?? ReadOnlyDiskImageWebRuntimePayloadPreparer(
            payloadVerifier: payloadVerifier
        )
        let manager = WebRuntimeManager(
            downloader: downloader,
            payloadPreparer: preparer,
            cache: cache,
            scratchRootURL: downloadRoot
        )
        return WebRuntimeHostServices(manager: manager, request: request)
    }
}
