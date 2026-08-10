// Distribution boundary for ScanStudio's optional browser runtime.
//
// The native application intentionally ships without this executable code. A
// caller must request the artifact for the exact installed ScanStudio release
// and host architecture, authenticate its detached Ed25519 signature, and
// verify its exact size and SHA-256 before handing it to the cache installer.
// No public key is embedded here: until release engineering supplies the real
// key, the default signature verifier fails closed before any artifact can be
// accepted.

import CryptoKit
import Foundation

public enum WebRuntimeManifestField: String, Equatable, Sendable {
    case schemaVersion
    case repository
    case tag
    case hostVersion
    case runtimeVersion
    case platform
    case architecture
    case protocolVersion
    case asset
    case payload
    case assetName
    case assetURL
    case assetSize
    case assetSHA256
    case bundleName
    case bundleIdentifier
    case teamIdentifier
    case developerIDSigned
    case notarized
    case executableRelativePath
    case staticDirectoryRelativePath
    case fileCount
    case installedSize
    case treeSHA256
}

public enum WebRuntimeDistributionError: Error, Equatable, Sendable {
    case invalidRequest
    case signatureVerifierUnavailable
    case invalidSignature
    case malformedManifest
    case duplicateManifestKey(String)
    case unknownManifestField(String)
    case manifestMismatch(WebRuntimeManifestField)
    case productionTrustUnavailable
    case productionTrustRequired
    case invalidGitHubURL
    case redirectRejected
    case transportFailed
    case unexpectedHTTPStatus(Int)
    case responseTooLarge
    case responseSizeMismatch
    case checksumMismatch
    case commandTimedOut
    case commandOutputTooLarge
    case diskImageMountFailed
    case diskImageLayoutInvalid
    case diskImageDetachFailed
    case codeSignatureInvalid
    case notarizationInvalid
    case unsafePayload
    case payloadIdentityMismatch
    case payloadPreparationUnavailable
    case operationInProgress
    case cacheUnavailable
    case cacheLockTimedOut
    case noVerifiedInstallation
    case atomicSelectionFailed
    case cancelled
}

extension WebRuntimeDistributionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest, .malformedManifest, .duplicateManifestKey,
             .unknownManifestField, .manifestMismatch, .invalidGitHubURL:
            "The web runtime release metadata is invalid."
        case .signatureVerifierUnavailable, .productionTrustUnavailable:
            "This Scan Studio build is not configured to verify web runtime releases."
        case .invalidSignature, .productionTrustRequired, .codeSignatureInvalid,
             .notarizationInvalid, .payloadIdentityMismatch:
            "The web runtime could not be verified as an authentic Scan Studio release."
        case .redirectRejected:
            "The web runtime download was redirected outside the trusted GitHub release service."
        case .transportFailed, .unexpectedHTTPStatus:
            "The web runtime could not be downloaded. Check your connection and try again."
        case .responseTooLarge, .responseSizeMismatch, .checksumMismatch,
             .commandOutputTooLarge:
            "The downloaded web runtime did not match its signed release metadata and was discarded."
        case .commandTimedOut, .diskImageMountFailed, .diskImageLayoutInvalid,
             .diskImageDetachFailed, .unsafePayload, .payloadPreparationUnavailable:
            "The downloaded web runtime could not be opened safely and was discarded."
        case .operationInProgress:
            "Another web runtime operation is already in progress."
        case .cacheUnavailable, .cacheLockTimedOut, .atomicSelectionFailed:
            "Scan Studio could not update its verified web runtime cache."
        case .noVerifiedInstallation:
            "The optional web runtime is not installed."
        case .cancelled:
            "The web runtime download was cancelled."
        }
    }
}

public struct WebRuntimeExpectedCodeIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(bundleIdentifier: String, teamIdentifier: String) throws {
        guard Self.isSafeIdentifier(bundleIdentifier), Self.isSafeIdentifier(teamIdentifier) else {
            throw WebRuntimeDistributionError.invalidRequest
        }
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39)
                    || ($0 >= 0x41 && $0 <= 0x5A)
                    || ($0 >= 0x61 && $0 <= 0x7A)
                    || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F
            }
    }
}

/// Exact, tag-pinned release request. Artifact names and URLs are derived from
/// these values rather than accepted from a UI, environment variable, or
/// versionless "latest" pointer.
public struct WebRuntimeReleaseRequest: Equatable, Sendable {
    public static let repository = "rohanpandula/ScanStudio"
    public static let githubHost = "github.com"
    public static let manifestSchemaVersion = 1
    public static let payloadBundleName = "ScanStudioWebRuntime.bundle"
    public static let executableRelativePath = "Contents/MacOS/scanstudio-web-runtime"
    public static let staticDirectoryRelativePath = "Contents/Resources/WebFrontend"

    public let hostVersion: UpdateVersion
    public let hostVersionString: String
    public let architecture: HostArchitecture
    public let protocolVersion: Int
    public let maximumAssetBytes: Int64
    public let expectedCodeIdentity: WebRuntimeExpectedCodeIdentity?

    public init(
        hostVersion: String,
        architecture: HostArchitecture,
        protocolVersion: Int,
        maximumAssetBytes: Int64 = 1_073_741_824,
        expectedCodeIdentity: WebRuntimeExpectedCodeIdentity? = nil
    ) throws {
        guard Self.isCanonicalReleaseVersion(hostVersion),
              let parsed = UpdateVersion(raw: hostVersion),
              protocolVersion > 0,
              maximumAssetBytes > 0,
              maximumAssetBytes <= Int64.max / 8 else {
            throw WebRuntimeDistributionError.invalidRequest
        }
        self.hostVersion = parsed
        self.hostVersionString = hostVersion
        self.architecture = architecture
        self.protocolVersion = protocolVersion
        self.maximumAssetBytes = maximumAssetBytes
        self.expectedCodeIdentity = expectedCodeIdentity
    }

    public var tag: String { "v\(hostVersionString)" }

    public var artifactStem: String {
        "ScanStudio-WebRuntime-\(hostVersionString)-macOS-\(architecture.rawValue)"
    }

    public var manifestAssetName: String { "\(artifactStem).json" }
    public var signatureAssetName: String { "\(manifestAssetName).sig" }
    public var diskImageAssetName: String { "\(artifactStem).dmg" }

    public var manifestURL: URL {
        Self.releaseAssetURL(tag: tag, filename: manifestAssetName)
    }

    public var signatureURL: URL {
        Self.releaseAssetURL(tag: tag, filename: signatureAssetName)
    }

    public var diskImageURL: URL {
        Self.releaseAssetURL(tag: tag, filename: diskImageAssetName)
    }

    /// Every runtime obtained from GitHub is executable code and therefore
    /// requires the same production trust, including preview/prerelease tags.
    /// Unsigned development runtimes are discovered only through the DEBUG
    /// source-tree path and never enter this distribution pipeline.
    public var requiresProductionTrust: Bool { true }

    private static func releaseAssetURL(tag: String, filename: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = githubHost
        components.path = "/\(repository)/releases/download/\(tag)/\(filename)"
        // Construction is wholly internal from validated ASCII components.
        return components.url!
    }

    static func isCanonicalReleaseVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 96, !value.hasPrefix("v") else {
            return false
        }
        let halves = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = halves[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              core.allSatisfy({
                  !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
              }) else {
            return false
        }
        if halves.count == 2 {
            let prerelease = halves[1].split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(prerelease.count),
                  prerelease.allSatisfy({
                      !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
                  }) else {
                return false
            }
        }
        return true
    }
}

public struct WebRuntimeArtifact: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let size: Int64
    public let sha256: String
}

public struct WebRuntimePayloadManifest: Equatable, Sendable {
    public let bundleName: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let developerIDSigned: Bool
    public let notarized: Bool
    public let executableRelativePath: String
    public let staticDirectoryRelativePath: String
    public let fileCount: Int
    public let installedSize: Int64
    public let treeSHA256: String
}

public struct WebRuntimeManifest: Equatable, Sendable {
    public static let maximumManifestBytes = 65_536
    public static let maximumSignatureBytes = 1_024

    public let schemaVersion: Int
    public let repository: String
    public let tag: String
    public let hostVersion: String
    public let runtimeVersion: String
    public let platform: String
    public let architecture: HostArchitecture
    public let protocolVersion: Int
    public let artifact: WebRuntimeArtifact
    public let payload: WebRuntimePayloadManifest
}

public struct VerifiedWebRuntimeRelease: Equatable, Sendable {
    public let request: WebRuntimeReleaseRequest
    public let manifest: WebRuntimeManifest
    public let manifestBytes: Data
    public let signatureBytes: Data

    public init(
        request: WebRuntimeReleaseRequest,
        manifest: WebRuntimeManifest,
        manifestBytes: Data,
        signatureBytes: Data
    ) {
        self.request = request
        self.manifest = manifest
        self.manifestBytes = manifestBytes
        self.signatureBytes = signatureBytes
    }
}

public protocol WebRuntimeManifestSignatureVerifying: Sendable {
    func verify(signature: Data, for manifest: Data) throws
}

/// Deliberate production default until release engineering supplies the actual
/// ScanStudio runtime signing key.
public struct UnavailableWebRuntimeSignatureVerifier: WebRuntimeManifestSignatureVerifying {
    public init() {}

    public func verify(signature: Data, for manifest: Data) throws {
        throw WebRuntimeDistributionError.signatureVerifierUnavailable
    }
}

public struct Ed25519WebRuntimeSignatureVerifier: WebRuntimeManifestSignatureVerifying {
    private let publicKey: Curve25519.Signing.PublicKey

    public init(publicKeyRawRepresentation: Data) throws {
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyRawRepresentation
            )
        } catch {
            throw WebRuntimeDistributionError.invalidRequest
        }
    }

    public func verify(signature: Data, for manifest: Data) throws {
        guard signature.count == 64,
              publicKey.isValidSignature(signature, for: manifest) else {
            throw WebRuntimeDistributionError.invalidSignature
        }
    }
}

public struct WebRuntimeManifestVerifier: Sendable {
    private let signatureVerifier: any WebRuntimeManifestSignatureVerifying

    public init(
        signatureVerifier: any WebRuntimeManifestSignatureVerifying =
            UnavailableWebRuntimeSignatureVerifier()
    ) {
        self.signatureVerifier = signatureVerifier
    }

    public func verify(
        manifestBytes: Data,
        signatureBytes: Data,
        for request: WebRuntimeReleaseRequest
    ) throws -> VerifiedWebRuntimeRelease {
        guard !manifestBytes.isEmpty,
              manifestBytes.count <= WebRuntimeManifest.maximumManifestBytes,
              !signatureBytes.isEmpty,
              signatureBytes.count <= WebRuntimeManifest.maximumSignatureBytes else {
            throw WebRuntimeDistributionError.responseTooLarge
        }

        // Authenticate the exact downloaded bytes before interpreting any URL,
        // path, size, or code-identity field contained in them.
        try signatureVerifier.verify(signature: signatureBytes, for: manifestBytes)

        let value: StrictWebRuntimeJSON.Value
        do {
            value = try StrictWebRuntimeJSON.parse(manifestBytes)
        } catch let error as StrictWebRuntimeJSON.ParseError {
            switch error {
            case .duplicateKey(let key):
                throw WebRuntimeDistributionError.duplicateManifestKey(key)
            default:
                throw WebRuntimeDistributionError.malformedManifest
            }
        }

        let root = try value.exactObject(
            keys: [
                "schemaVersion", "repository", "tag", "hostVersion",
                "runtimeVersion", "platform", "architecture", "protocolVersion",
                "asset", "payload",
            ]
        )
        let assetObject = try root.required("asset").exactObject(
            keys: ["name", "url", "size", "sha256"]
        )
        let payloadObject = try root.required("payload").exactObject(
            keys: [
                "bundleName", "bundleIdentifier", "teamIdentifier",
                "developerIDSigned", "notarized", "executableRelativePath",
                "staticDirectoryRelativePath", "fileCount", "installedSize",
                "treeSHA256",
            ]
        )

        let schemaVersion = try root.required("schemaVersion").positiveInt()
        let repository = try root.required("repository").string()
        let tag = try root.required("tag").string()
        let hostVersion = try root.required("hostVersion").string()
        let runtimeVersion = try root.required("runtimeVersion").string()
        let platform = try root.required("platform").string()
        let architectureRaw = try root.required("architecture").string()
        let protocolVersion = try root.required("protocolVersion").positiveInt()

        let assetName = try assetObject.required("name").string()
        let assetURLString = try assetObject.required("url").string()
        let assetSize = try assetObject.required("size").positiveInt64()
        let assetSHA256 = try assetObject.required("sha256").string()

        let bundleName = try payloadObject.required("bundleName").string()
        let bundleIdentifier = try payloadObject.required("bundleIdentifier").string()
        let teamIdentifier = try payloadObject.required("teamIdentifier").string()
        let developerIDSigned = try payloadObject.required("developerIDSigned").bool()
        let notarized = try payloadObject.required("notarized").bool()
        let executableRelativePath = try payloadObject.required("executableRelativePath").string()
        let staticDirectoryRelativePath = try payloadObject.required("staticDirectoryRelativePath").string()
        let fileCount = try payloadObject.required("fileCount").positiveInt()
        let installedSize = try payloadObject.required("installedSize").positiveInt64()
        let treeSHA256 = try payloadObject.required("treeSHA256").string()

        guard schemaVersion == WebRuntimeReleaseRequest.manifestSchemaVersion else {
            throw WebRuntimeDistributionError.manifestMismatch(.schemaVersion)
        }
        guard repository == WebRuntimeReleaseRequest.repository else {
            throw WebRuntimeDistributionError.manifestMismatch(.repository)
        }
        guard tag == request.tag else {
            throw WebRuntimeDistributionError.manifestMismatch(.tag)
        }
        guard hostVersion == request.hostVersionString else {
            throw WebRuntimeDistributionError.manifestMismatch(.hostVersion)
        }
        guard runtimeVersion == request.hostVersionString else {
            throw WebRuntimeDistributionError.manifestMismatch(.runtimeVersion)
        }
        guard platform == "macos" else {
            throw WebRuntimeDistributionError.manifestMismatch(.platform)
        }
        guard let architecture = HostArchitecture(rawValue: architectureRaw),
              architecture == request.architecture else {
            throw WebRuntimeDistributionError.manifestMismatch(.architecture)
        }
        guard protocolVersion == request.protocolVersion else {
            throw WebRuntimeDistributionError.manifestMismatch(.protocolVersion)
        }
        guard assetName == request.diskImageAssetName else {
            throw WebRuntimeDistributionError.manifestMismatch(.assetName)
        }
        guard let assetURL = URL(string: assetURLString), assetURL == request.diskImageURL,
              WebRuntimeGitHubURLPolicy.isExactReleaseURL(assetURL, expected: request.diskImageURL) else {
            throw WebRuntimeDistributionError.manifestMismatch(.assetURL)
        }
        guard assetSize <= request.maximumAssetBytes else {
            throw WebRuntimeDistributionError.manifestMismatch(.assetSize)
        }
        guard Self.isLowercaseSHA256(assetSHA256) else {
            throw WebRuntimeDistributionError.manifestMismatch(.assetSHA256)
        }
        guard bundleName == WebRuntimeReleaseRequest.payloadBundleName,
              executableRelativePath == WebRuntimeReleaseRequest.executableRelativePath,
              staticDirectoryRelativePath == WebRuntimeReleaseRequest.staticDirectoryRelativePath,
              Self.isLowercaseSHA256(treeSHA256),
              fileCount <= 100_000,
              installedSize <= request.maximumAssetBytes * 8 else {
            throw WebRuntimeDistributionError.malformedManifest
        }

        if let expected = request.expectedCodeIdentity {
            guard bundleIdentifier == expected.bundleIdentifier else {
                throw WebRuntimeDistributionError.manifestMismatch(.bundleIdentifier)
            }
            guard teamIdentifier == expected.teamIdentifier else {
                throw WebRuntimeDistributionError.manifestMismatch(.teamIdentifier)
            }
        } else if request.requiresProductionTrust {
            throw WebRuntimeDistributionError.productionTrustUnavailable
        }
        if request.requiresProductionTrust && (!developerIDSigned || !notarized) {
            throw WebRuntimeDistributionError.productionTrustRequired
        }

        let manifest = WebRuntimeManifest(
            schemaVersion: schemaVersion,
            repository: repository,
            tag: tag,
            hostVersion: hostVersion,
            runtimeVersion: runtimeVersion,
            platform: platform,
            architecture: architecture,
            protocolVersion: protocolVersion,
            artifact: WebRuntimeArtifact(
                name: assetName,
                url: assetURL,
                size: assetSize,
                sha256: assetSHA256
            ),
            payload: WebRuntimePayloadManifest(
                bundleName: bundleName,
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: teamIdentifier,
                developerIDSigned: developerIDSigned,
                notarized: notarized,
                executableRelativePath: executableRelativePath,
                staticDirectoryRelativePath: staticDirectoryRelativePath,
                fileCount: fileCount,
                installedSize: installedSize,
                treeSHA256: treeSHA256
            )
        )
        return VerifiedWebRuntimeRelease(
            request: request,
            manifest: manifest,
            manifestBytes: manifestBytes,
            signatureBytes: signatureBytes
        )
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
                    || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
            }
    }

}

public struct WebRuntimeHTTPPayload: Equatable, Sendable {
    public let fileURL: URL
    public let finalURL: URL
    public let statusCode: Int
    public let byteCount: Int64

    public init(fileURL: URL, finalURL: URL, statusCode: Int, byteCount: Int64) {
        self.fileURL = fileURL
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.byteCount = byteCount
    }
}

public protocol WebRuntimeHTTPClient: Sendable {
    /// Streams the response to `destination`, stopping once `maximumBytes` is
    /// exceeded. Implementations must apply the supplied redirect policy to
    /// every hop, not merely inspect the final response URL.
    func download(
        from url: URL,
        to destination: URL,
        maximumBytes: Int64,
        redirectPolicy: WebRuntimeGitHubURLPolicy
    ) async throws -> WebRuntimeHTTPPayload
}

public struct WebRuntimeGitHubURLPolicy: Equatable, Sendable {
    public static let approvedReleaseCDNHosts: Set<String> = [
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
    ]

    public let originalURL: URL
    public let maximumRedirects: Int

    public init(originalURL: URL, maximumRedirects: Int = 2) throws {
        guard maximumRedirects >= 0,
              Self.isExactReleaseURL(originalURL, expected: originalURL) else {
            throw WebRuntimeDistributionError.invalidGitHubURL
        }
        self.originalURL = originalURL
        self.maximumRedirects = maximumRedirects
    }

    public func permitsRedirect(to candidate: URL, hop: Int) -> Bool {
        guard hop <= maximumRedirects,
              Self.hasSecureURLShape(candidate),
              let host = candidate.host?.lowercased() else {
            return false
        }
        if host == WebRuntimeReleaseRequest.githubHost {
            return Self.isExactReleaseURL(candidate, expected: originalURL)
        }
        return Self.approvedReleaseCDNHosts.contains(host)
    }

    public func permitsFinalURL(_ candidate: URL) -> Bool {
        Self.isExactReleaseURL(candidate, expected: originalURL)
            || (Self.hasSecureURLShape(candidate)
                && Self.approvedReleaseCDNHosts.contains(candidate.host?.lowercased() ?? ""))
    }

    static func isExactReleaseURL(_ candidate: URL, expected: URL) -> Bool {
        guard candidate == expected,
              hasSecureURLShape(candidate),
              candidate.host?.lowercased() == WebRuntimeReleaseRequest.githubHost,
              candidate.query == nil else {
            return false
        }
        let expectedPrefix = "/\(WebRuntimeReleaseRequest.repository)/releases/download/"
        return candidate.path.hasPrefix(expectedPrefix)
    }

    private static func hasSecureURLShape(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
            && (url.port == nil || url.port == 443)
    }
}

public protocol WebRuntimeReleaseDownloading: Sendable {
    func resolve(_ request: WebRuntimeReleaseRequest) async throws -> VerifiedWebRuntimeRelease
    func downloadArtifact(
        for release: VerifiedWebRuntimeRelease,
        to directory: URL
    ) async throws -> URL
}

public actor GitHubWebRuntimeDownloader: WebRuntimeReleaseDownloading {
    private let httpClient: any WebRuntimeHTTPClient
    private let manifestVerifier: WebRuntimeManifestVerifier

    public init(
        httpClient: any WebRuntimeHTTPClient,
        signatureVerifier: any WebRuntimeManifestSignatureVerifying =
            UnavailableWebRuntimeSignatureVerifier()
    ) {
        self.httpClient = httpClient
        manifestVerifier = WebRuntimeManifestVerifier(signatureVerifier: signatureVerifier)
    }

    public func resolve(
        _ request: WebRuntimeReleaseRequest
    ) async throws -> VerifiedWebRuntimeRelease {
        let temporary = try Self.makeTemporaryDirectory(prefix: "metadata")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let manifestPath = temporary.appendingPathComponent("manifest.json")
        let signaturePath = temporary.appendingPathComponent("manifest.sig")
        let manifestResponse = try await retrieve(
            request.manifestURL,
            to: manifestPath,
            maximumBytes: Int64(WebRuntimeManifest.maximumManifestBytes)
        )
        let signatureResponse = try await retrieve(
            request.signatureURL,
            to: signaturePath,
            maximumBytes: Int64(WebRuntimeManifest.maximumSignatureBytes)
        )
        guard manifestResponse.byteCount > 0, signatureResponse.byteCount == 64 else {
            throw WebRuntimeDistributionError.responseSizeMismatch
        }
        let manifestBytes = try Self.readBounded(
            manifestPath,
            maximumBytes: WebRuntimeManifest.maximumManifestBytes
        )
        let signatureBytes = try Self.readBounded(
            signaturePath,
            maximumBytes: WebRuntimeManifest.maximumSignatureBytes
        )
        return try manifestVerifier.verify(
            manifestBytes: manifestBytes,
            signatureBytes: signatureBytes,
            for: request
        )
    }

    public func downloadArtifact(
        for release: VerifiedWebRuntimeRelease,
        to directory: URL
    ) async throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent(
            ".\(release.manifest.artifact.name).\(UUID().uuidString).download"
        )
        do {
            let response = try await retrieve(
                release.manifest.artifact.url,
                to: destination,
                maximumBytes: release.manifest.artifact.size
            )
            guard response.byteCount == release.manifest.artifact.size else {
                throw WebRuntimeDistributionError.responseSizeMismatch
            }
            let digest = try WebRuntimeFileHash.sha256(of: destination)
            guard digest == release.manifest.artifact.sha256 else {
                throw WebRuntimeDistributionError.checksumMismatch
            }
            return destination
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw WebRuntimeDistributionError.cancelled
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func retrieve(
        _ url: URL,
        to destination: URL,
        maximumBytes: Int64
    ) async throws -> WebRuntimeHTTPPayload {
        let policy = try WebRuntimeGitHubURLPolicy(originalURL: url)
        let response: WebRuntimeHTTPPayload
        do {
            response = try await httpClient.download(
                from: url,
                to: destination,
                maximumBytes: maximumBytes,
                redirectPolicy: policy
            )
        } catch let error as WebRuntimeDistributionError {
            throw error
        } catch is CancellationError {
            throw WebRuntimeDistributionError.cancelled
        } catch {
            throw WebRuntimeDistributionError.transportFailed
        }
        guard response.statusCode == 200 else {
            throw WebRuntimeDistributionError.unexpectedHTTPStatus(response.statusCode)
        }
        guard policy.permitsFinalURL(response.finalURL) else {
            throw WebRuntimeDistributionError.redirectRejected
        }
        guard response.byteCount >= 0, response.byteCount <= maximumBytes else {
            throw WebRuntimeDistributionError.responseTooLarge
        }
        return response
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScanStudio-WebRuntime-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return root
        } catch {
            throw WebRuntimeDistributionError.cacheUnavailable
        }
    }

    private static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                throw WebRuntimeDistributionError.responseTooLarge
            }
            return data
        } catch let error as WebRuntimeDistributionError {
            throw error
        } catch {
            throw WebRuntimeDistributionError.transportFailed
        }
    }
}

enum WebRuntimeFileHash {
    static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WebRuntimeDistributionError.transportFailed
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
        } catch {
            throw WebRuntimeDistributionError.transportFailed
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Strict, bounded JSON

enum StrictWebRuntimeJSON {
    enum Value: Equatable {
        case object([String: Value])
        case array([Value])
        case string(String)
        case number(String)
        case bool(Bool)
        case null

        func exactObject(keys expected: Set<String>) throws -> [String: Value] {
            guard case .object(let value) = self else {
                throw WebRuntimeDistributionError.malformedManifest
            }
            let actual = Set(value.keys)
            if let unknown = actual.subtracting(expected).sorted().first {
                throw WebRuntimeDistributionError.unknownManifestField(unknown)
            }
            guard actual == expected else {
                throw WebRuntimeDistributionError.malformedManifest
            }
            return value
        }

        func string() throws -> String {
            guard case .string(let value) = self else {
                throw WebRuntimeDistributionError.malformedManifest
            }
            return value
        }

        func bool() throws -> Bool {
            guard case .bool(let value) = self else {
                throw WebRuntimeDistributionError.malformedManifest
            }
            return value
        }

        func positiveInt() throws -> Int {
            let value = try positiveInt64()
            guard value <= Int64(Int.max) else {
                throw WebRuntimeDistributionError.malformedManifest
            }
            return Int(value)
        }

        func positiveInt64() throws -> Int64 {
            guard case .number(let token) = self,
                  !token.isEmpty,
                  token.allSatisfy(\.isNumber),
                  token.first != "0" || token.count == 1,
                  let value = Int64(token), value > 0 else {
                throw WebRuntimeDistributionError.malformedManifest
            }
            return value
        }
    }

    enum ParseError: Error, Equatable {
        case malformed
        case duplicateKey(String)
        case limitExceeded
    }

    static func parse(_ data: Data) throws -> Value {
        guard data.count <= WebRuntimeManifest.maximumManifestBytes else {
            throw ParseError.limitExceeded
        }
        var parser = Parser(bytes: Array(data))
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw ParseError.malformed }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var entryCount = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func parseValue(depth: Int) throws -> Value {
            guard depth <= 12 else { throw ParseError.limitExceeded }
            skipWhitespace()
            guard index < bytes.count else { throw ParseError.malformed }
            switch bytes[index] {
            case 0x7B: return try parseObject(depth: depth + 1) // {
            case 0x5B: return try parseArray(depth: depth + 1) // [
            case 0x22: return .string(try parseString())
            case 0x74:
                try consumeLiteral("true")
                return .bool(true)
            case 0x66:
                try consumeLiteral("false")
                return .bool(false)
            case 0x6E:
                try consumeLiteral("null")
                return .null
            case 0x2D, 0x30...0x39:
                return .number(try parseNumber())
            default:
                throw ParseError.malformed
            }
        }

        mutating func parseObject(depth: Int) throws -> Value {
            index += 1
            skipWhitespace()
            var result: [String: Value] = [:]
            if consumeIf(0x7D) { return .object(result) }
            while true {
                skipWhitespace()
                guard peek() == 0x22 else { throw ParseError.malformed }
                let key = try parseString()
                guard result[key] == nil else { throw ParseError.duplicateKey(key) }
                skipWhitespace()
                guard consumeIf(0x3A) else { throw ParseError.malformed }
                entryCount += 1
                guard entryCount <= 256 else { throw ParseError.limitExceeded }
                result[key] = try parseValue(depth: depth)
                skipWhitespace()
                if consumeIf(0x7D) { break }
                guard consumeIf(0x2C) else { throw ParseError.malformed }
            }
            return .object(result)
        }

        mutating func parseArray(depth: Int) throws -> Value {
            index += 1
            skipWhitespace()
            var result: [Value] = []
            if consumeIf(0x5D) { return .array(result) }
            while true {
                entryCount += 1
                guard entryCount <= 256 else { throw ParseError.limitExceeded }
                result.append(try parseValue(depth: depth))
                skipWhitespace()
                if consumeIf(0x5D) { break }
                guard consumeIf(0x2C) else { throw ParseError.malformed }
            }
            return .array(result)
        }

        mutating func parseString() throws -> String {
            guard consumeIf(0x22) else { throw ParseError.malformed }
            var output: [UInt8] = []
            output.reserveCapacity(64)
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    guard output.count <= 4_096,
                          let value = String(bytes: output, encoding: .utf8) else {
                        throw ParseError.limitExceeded
                    }
                    return value
                }
                if byte == 0x5C {
                    guard index < bytes.count else { throw ParseError.malformed }
                    let escaped = bytes[index]
                    index += 1
                    switch escaped {
                    case 0x22, 0x5C, 0x2F: output.append(escaped)
                    case 0x62: output.append(0x08)
                    case 0x66: output.append(0x0C)
                    case 0x6E: output.append(0x0A)
                    case 0x72: output.append(0x0D)
                    case 0x74: output.append(0x09)
                    case 0x75:
                        let first = try parseUnicodeEscape()
                        let scalar: UInt32
                        if (0xD800...0xDBFF).contains(first) {
                            guard index + 2 <= bytes.count,
                                  bytes[index] == 0x5C,
                                  bytes[index + 1] == 0x75 else {
                                throw ParseError.malformed
                            }
                            index += 2
                            let second = try parseUnicodeEscape()
                            guard (0xDC00...0xDFFF).contains(second) else {
                                throw ParseError.malformed
                            }
                            scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                        } else {
                            guard !(0xDC00...0xDFFF).contains(first) else {
                                throw ParseError.malformed
                            }
                            scalar = first
                        }
                        guard let unicode = UnicodeScalar(scalar) else {
                            throw ParseError.malformed
                        }
                        output.append(contentsOf: String(unicode).utf8)
                    default:
                        throw ParseError.malformed
                    }
                } else {
                    guard byte >= 0x20 else { throw ParseError.malformed }
                    output.append(byte)
                }
                guard output.count <= 4_096 else { throw ParseError.limitExceeded }
            }
            throw ParseError.malformed
        }

        mutating func parseUnicodeEscape() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw ParseError.malformed }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                index += 1
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte - 0x30)
                case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
                case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
                default: throw ParseError.malformed
                }
                value = (value << 4) | digit
            }
            return value
        }

        mutating func parseNumber() throws -> String {
            let start = index
            _ = consumeIf(0x2D)
            guard index < bytes.count else { throw ParseError.malformed }
            if consumeIf(0x30) {
                if let next = peek(), (0x30...0x39).contains(next) {
                    throw ParseError.malformed
                }
            } else {
                guard let next = peek(), (0x31...0x39).contains(next) else {
                    throw ParseError.malformed
                }
                while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
            }
            if consumeIf(0x2E) {
                guard let next = peek(), (0x30...0x39).contains(next) else {
                    throw ParseError.malformed
                }
                while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
            }
            if let next = peek(), next == 0x65 || next == 0x45 {
                index += 1
                if let sign = peek(), sign == 0x2B || sign == 0x2D { index += 1 }
                guard let digit = peek(), (0x30...0x39).contains(digit) else {
                    throw ParseError.malformed
                }
                while let digit = peek(), (0x30...0x39).contains(digit) { index += 1 }
            }
            guard let value = String(bytes: bytes[start..<index], encoding: .utf8) else {
                throw ParseError.malformed
            }
            return value
        }

        mutating func consumeLiteral(_ literal: StaticString) throws {
            let value = Array("\(literal)".utf8)
            guard index + value.count <= bytes.count,
                  Array(bytes[index..<(index + value.count)]) == value else {
                throw ParseError.malformed
            }
            index += value.count
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard peek() == byte else { return false }
            index += 1
            return true
        }
    }
}

private extension Dictionary where Key == String, Value == StrictWebRuntimeJSON.Value {
    func required(_ key: String) throws -> Value {
        guard let value = self[key] else {
            throw WebRuntimeDistributionError.malformedManifest
        }
        return value
    }
}
