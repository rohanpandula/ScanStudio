import CryptoKit
import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Optional web runtime signed distribution")
struct WebRuntimeDistributionTests {
    @Test("valid raw Ed25519 manifest is accepted for the exact release")
    func acceptsExactSignedManifest() throws {
        let fixture = try RuntimeDistributionFixture()
        let release = try fixture.verifiedRelease()

        #expect(release.manifest.hostVersion == fixture.request.hostVersionString)
        #expect(release.manifest.architecture == .arm64)
        #expect(release.manifest.artifact.url == fixture.request.diskImageURL)
        #expect(release.signatureBytes.count == 64)
    }

    @Test("default verifier fails closed without a real release key")
    func unavailableKeyFailsClosed() throws {
        let fixture = try RuntimeDistributionFixture()
        let bytes = try fixture.manifestBytes()
        let signature = try fixture.privateKey.signature(for: bytes)
        let verifier = WebRuntimeManifestVerifier()

        #expect(throws: WebRuntimeDistributionError.signatureVerifierUnavailable) {
            try verifier.verify(
                manifestBytes: bytes,
                signatureBytes: signature,
                for: fixture.request
            )
        }
    }

    @Test("signature covers the exact unmodified manifest bytes")
    func signatureCoversRawBytes() throws {
        let fixture = try RuntimeDistributionFixture()
        let bytes = try fixture.manifestBytes()
        let signature = try fixture.privateKey.signature(for: bytes)
        var changed = bytes
        changed.append(0x20)

        #expect(throws: WebRuntimeDistributionError.invalidSignature) {
            try fixture.verifier.verify(
                manifestBytes: changed,
                signatureBytes: signature,
                for: fixture.request
            )
        }
    }

    @Test("duplicate and unknown keys reject even when correctly signed")
    func strictKeysReject() throws {
        let fixture = try RuntimeDistributionFixture()
        let original = String(decoding: try fixture.manifestBytes(), as: UTF8.self)
        let duplicate = Data(
            original.replacingOccurrences(
                of: #""schemaVersion":1"#,
                with: #""schemaVersion":1,"schemaVersion":1"#
            ).utf8
        )
        let duplicateSignature = try fixture.privateKey.signature(for: duplicate)
        #expect(throws: WebRuntimeDistributionError.duplicateManifestKey("schemaVersion")) {
            try fixture.verifier.verify(
                manifestBytes: duplicate,
                signatureBytes: duplicateSignature,
                for: fixture.request
            )
        }

        var object = try fixture.manifestObject()
        object["surprise"] = true
        let unknown = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let unknownSignature = try fixture.privateKey.signature(for: unknown)
        #expect(throws: WebRuntimeDistributionError.unknownManifestField("surprise")) {
            try fixture.verifier.verify(
                manifestBytes: unknown,
                signatureBytes: unknownSignature,
                for: fixture.request
            )
        }
    }

    @Test("signed metadata cannot substitute repository tag arch URL size or hash")
    func exactFieldsRejectSubstitution() throws {
        let fixture = try RuntimeDistributionFixture()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["repository"] = "attacker/ScanStudio" },
            { $0["tag"] = "v9.9.9" },
            { $0["architecture"] = "x86_64" },
            { object in
                var asset = object["asset"] as! [String: Any]
                asset["url"] = "https://example.invalid/runtime.dmg"
                object["asset"] = asset
            },
            { object in
                var asset = object["asset"] as! [String: Any]
                asset["size"] = fixture.request.maximumAssetBytes + 1
                object["asset"] = asset
            },
            { object in
                var asset = object["asset"] as! [String: Any]
                asset["sha256"] = String(repeating: "A", count: 64)
                object["asset"] = asset
            },
        ]

        for mutate in mutations {
            var object = try fixture.manifestObject()
            mutate(&object)
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let signature = try fixture.privateKey.signature(for: bytes)
            #expect(throws: WebRuntimeDistributionError.self) {
                try fixture.verifier.verify(
                    manifestBytes: bytes,
                    signatureBytes: signature,
                    for: fixture.request
                )
            }
        }
    }

    @Test("signed metadata cannot redirect the fixed runtime launcher or frontend")
    func fixedPayloadContractRejectsSubstitution() throws {
        let fixture = try RuntimeDistributionFixture()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["runtimeVersion"] = "9.9.9" },
            { object in
                var payload = object["payload"] as! [String: Any]
                payload["executableRelativePath"] = "Contents/MacOS/other-launcher"
                object["payload"] = payload
            },
            { object in
                var payload = object["payload"] as! [String: Any]
                payload["staticDirectoryRelativePath"] = "Contents/Resources/OtherFrontend"
                object["payload"] = payload
            },
        ]

        for mutate in mutations {
            var object = try fixture.manifestObject()
            mutate(&object)
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let signature = try fixture.privateKey.signature(for: bytes)
            #expect(throws: WebRuntimeDistributionError.self) {
                try fixture.verifier.verify(
                    manifestBytes: bytes,
                    signatureBytes: signature,
                    for: fixture.request
                )
            }
        }
    }

    @Test("every downloaded release requires configured identity and notarized Developer ID assertion")
    func everyDownloadedReleaseRequiresProductionTrust() throws {
        let missingIdentity = try RuntimeDistributionFixture(
            hostVersion: "1.2.3",
            expectedCodeIdentity: nil,
            developerIDSigned: true,
            notarized: true
        )
        #expect(throws: WebRuntimeDistributionError.productionTrustUnavailable) {
            try missingIdentity.verifiedRelease()
        }

        let unsigned = try RuntimeDistributionFixture(
            hostVersion: "1.2.3",
            expectedCodeIdentity: try RuntimeDistributionFixture.codeIdentity(),
            developerIDSigned: false,
            notarized: false
        )
        #expect(throws: WebRuntimeDistributionError.productionTrustRequired) {
            try unsigned.verifiedRelease()
        }

        let trusted = try RuntimeDistributionFixture(
            hostVersion: "1.2.3",
            expectedCodeIdentity: try RuntimeDistributionFixture.codeIdentity(),
            developerIDSigned: true,
            notarized: true
        )
        #expect(try trusted.verifiedRelease().manifest.payload.notarized)

        let unsignedPrerelease = try RuntimeDistributionFixture(
            hostVersion: "1.2.3-beta.1",
            expectedCodeIdentity: try RuntimeDistributionFixture.codeIdentity(),
            developerIDSigned: false,
            notarized: false
        )
        #expect(throws: WebRuntimeDistributionError.productionTrustRequired) {
            try unsignedPrerelease.verifiedRelease()
        }
    }

    @Test("request identity, version, and size bounds use canonical ASCII")
    func requestInputsAreCanonicalAndBounded() {
        #expect(throws: WebRuntimeDistributionError.invalidRequest) {
            try WebRuntimeReleaseRequest(
                hostVersion: "١.2.3",
                architecture: .arm64,
                protocolVersion: 1
            )
        }
        #expect(throws: WebRuntimeDistributionError.invalidRequest) {
            try WebRuntimeExpectedCodeIdentity(
                bundleIdentifier: "dev.scanstudio.runtimé",
                teamIdentifier: "ABCDE12345"
            )
        }
        #expect(throws: WebRuntimeDistributionError.invalidRequest) {
            try WebRuntimeReleaseRequest(
                hostVersion: "1.2.3",
                architecture: .arm64,
                protocolVersion: 1,
                maximumAssetBytes: Int64.max
            )
        }
    }

    @Test("redirect policy permits only bounded GitHub release CDN hops")
    func redirectPolicyIsBounded() throws {
        let request = try RuntimeDistributionFixture.makeRequest()
        let policy = try WebRuntimeGitHubURLPolicy(originalURL: request.diskImageURL)
        let cdn = URL(
            string: "https://release-assets.githubusercontent.com/github-production-release-asset/opaque?token=signed"
        )!
        #expect(policy.permitsRedirect(to: cdn, hop: 1))
        #expect(policy.permitsFinalURL(cdn))
        #expect(!policy.permitsRedirect(to: cdn, hop: 3))
        #expect(!policy.permitsRedirect(to: URL(string: "https://example.com/file")!, hop: 1))
        #expect(!policy.permitsRedirect(to: URL(string: "http://release-assets.githubusercontent.com/file")!, hop: 1))
        #expect(!policy.permitsRedirect(
            to: URL(string: "https://github.com/other/repo/releases/download/v1/file")!,
            hop: 1
        ))
    }

    @Test("downloader authenticates metadata and verifies exact artifact bytes")
    func downloaderEndToEnd() async throws {
        let fixture = try RuntimeDistributionFixture()
        let manifestBytes = try fixture.manifestBytes()
        let signature = try fixture.privateKey.signature(for: manifestBytes)
        let http = FakeWebRuntimeHTTPClient(
            payloads: [
                fixture.request.manifestURL: manifestBytes,
                fixture.request.signatureURL: signature,
                fixture.request.diskImageURL: fixture.artifactBytes,
            ]
        )
        let downloader = GitHubWebRuntimeDownloader(
            httpClient: http,
            signatureVerifier: fixture.signatureVerifier
        )
        let release = try await downloader.resolve(fixture.request)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebRuntimeDownloaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let image = try await downloader.downloadArtifact(for: release, to: output)

        #expect(try Data(contentsOf: image) == fixture.artifactBytes)
    }

    @Test("downloader rejects non-200 final URL and size/hash mismatches")
    func downloaderFailures() async throws {
        let fixture = try RuntimeDistributionFixture()
        let manifestBytes = try fixture.manifestBytes()
        let signature = try fixture.privateKey.signature(for: manifestBytes)
        let attacker = URL(string: "https://example.invalid/manifest")!
        let http = FakeWebRuntimeHTTPClient(
            payloads: [fixture.request.manifestURL: manifestBytes],
            finalURLs: [fixture.request.manifestURL: attacker]
        )
        let downloader = GitHubWebRuntimeDownloader(
            httpClient: http,
            signatureVerifier: fixture.signatureVerifier
        )
        await #expect(throws: WebRuntimeDistributionError.redirectRejected) {
            try await downloader.resolve(fixture.request)
        }

        let corruptHTTP = FakeWebRuntimeHTTPClient(
            payloads: [
                fixture.request.manifestURL: manifestBytes,
                fixture.request.signatureURL: signature,
                fixture.request.diskImageURL: Data(repeating: 0xFF, count: fixture.artifactBytes.count),
            ]
        )
        let corruptDownloader = GitHubWebRuntimeDownloader(
            httpClient: corruptHTTP,
            signatureVerifier: fixture.signatureVerifier
        )
        let release = try await corruptDownloader.resolve(fixture.request)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebRuntimeDownloaderFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: output) }
        await #expect(throws: WebRuntimeDistributionError.checksumMismatch) {
            try await corruptDownloader.downloadArtifact(for: release, to: output)
        }
    }
}

struct RuntimeDistributionFixture {
    let request: WebRuntimeReleaseRequest
    let privateKey: Curve25519.Signing.PrivateKey
    let signatureVerifier: Ed25519WebRuntimeSignatureVerifier
    let verifier: WebRuntimeManifestVerifier
    let artifactBytes = Data("verified disk image fixture".utf8)
    let developerIDSigned: Bool
    let notarized: Bool

    init(
        hostVersion: String = "1.2.3-beta.1",
        expectedCodeIdentity: WebRuntimeExpectedCodeIdentity? = try? Self.codeIdentity(),
        developerIDSigned: Bool = true,
        notarized: Bool = true
    ) throws {
        request = try Self.makeRequest(
            hostVersion: hostVersion,
            expectedCodeIdentity: expectedCodeIdentity
        )
        privateKey = Curve25519.Signing.PrivateKey()
        signatureVerifier = try Ed25519WebRuntimeSignatureVerifier(
            publicKeyRawRepresentation: privateKey.publicKey.rawRepresentation
        )
        verifier = WebRuntimeManifestVerifier(signatureVerifier: signatureVerifier)
        self.developerIDSigned = developerIDSigned
        self.notarized = notarized
    }

    static func codeIdentity() throws -> WebRuntimeExpectedCodeIdentity {
        try WebRuntimeExpectedCodeIdentity(
            bundleIdentifier: "com.scanstudio.WebRuntime",
            teamIdentifier: "TESTTEAM1"
        )
    }

    static func makeRequest(
        hostVersion: String = "1.2.3-beta.1",
        expectedCodeIdentity: WebRuntimeExpectedCodeIdentity? = try? codeIdentity()
    ) throws -> WebRuntimeReleaseRequest {
        try WebRuntimeReleaseRequest(
            hostVersion: hostVersion,
            architecture: .arm64,
            protocolVersion: 1,
            maximumAssetBytes: 1_024 * 1_024,
            expectedCodeIdentity: expectedCodeIdentity
        )
    }

    func manifestObject(
        runtimeVersion: String? = nil,
        treeSHA256: String = String(repeating: "b", count: 64),
        fileCount: Int = 2,
        installedSize: Int64 = 100,
        artifactSHA256: String? = nil
    ) throws -> [String: Any] {
        let digest = artifactSHA256 ?? Self.sha256(artifactBytes)
        return [
            "schemaVersion": 1,
            "repository": WebRuntimeReleaseRequest.repository,
            "tag": request.tag,
            "hostVersion": request.hostVersionString,
            "runtimeVersion": runtimeVersion ?? request.hostVersionString,
            "platform": "macos",
            "architecture": request.architecture.rawValue,
            "protocolVersion": request.protocolVersion,
            "asset": [
                "name": request.diskImageAssetName,
                "url": request.diskImageURL.absoluteString,
                "size": artifactBytes.count,
                "sha256": digest,
            ],
            "payload": [
                "bundleName": WebRuntimeReleaseRequest.payloadBundleName,
                "bundleIdentifier": "com.scanstudio.WebRuntime",
                "teamIdentifier": "TESTTEAM1",
                "developerIDSigned": developerIDSigned,
                "notarized": notarized,
                "executableRelativePath": WebRuntimeReleaseRequest.executableRelativePath,
                "staticDirectoryRelativePath": WebRuntimeReleaseRequest.staticDirectoryRelativePath,
                "fileCount": fileCount,
                "installedSize": installedSize,
                "treeSHA256": treeSHA256,
            ],
        ]
    }

    func manifestBytes(
        runtimeVersion: String? = nil,
        treeSHA256: String = String(repeating: "b", count: 64),
        fileCount: Int = 2,
        installedSize: Int64 = 100,
        artifactSHA256: String? = nil
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: manifestObject(
                runtimeVersion: runtimeVersion,
                treeSHA256: treeSHA256,
                fileCount: fileCount,
                installedSize: installedSize,
                artifactSHA256: artifactSHA256
            ),
            options: [.sortedKeys]
        )
    }

    func verifiedRelease(
        runtimeVersion: String? = nil,
        treeSHA256: String = String(repeating: "b", count: 64),
        fileCount: Int = 2,
        installedSize: Int64 = 100,
        artifactSHA256: String? = nil
    ) throws -> VerifiedWebRuntimeRelease {
        let bytes = try manifestBytes(
            runtimeVersion: runtimeVersion,
            treeSHA256: treeSHA256,
            fileCount: fileCount,
            installedSize: installedSize,
            artifactSHA256: artifactSHA256
        )
        return try verifier.verify(
            manifestBytes: bytes,
            signatureBytes: try privateKey.signature(for: bytes),
            for: request
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor FakeWebRuntimeHTTPClient: WebRuntimeHTTPClient {
    let payloads: [URL: Data]
    let finalURLs: [URL: URL]
    let statusCodes: [URL: Int]

    init(
        payloads: [URL: Data],
        finalURLs: [URL: URL] = [:],
        statusCodes: [URL: Int] = [:]
    ) {
        self.payloads = payloads
        self.finalURLs = finalURLs
        self.statusCodes = statusCodes
    }

    func download(
        from url: URL,
        to destination: URL,
        maximumBytes: Int64,
        redirectPolicy: WebRuntimeGitHubURLPolicy
    ) throws -> WebRuntimeHTTPPayload {
        guard let data = payloads[url] else {
            throw WebRuntimeDistributionError.transportFailed
        }
        guard data.count <= maximumBytes else {
            throw WebRuntimeDistributionError.responseTooLarge
        }
        try data.write(to: destination, options: .withoutOverwriting)
        return WebRuntimeHTTPPayload(
            fileURL: destination,
            finalURL: finalURLs[url] ?? url,
            statusCode: statusCodes[url] ?? 200,
            byteCount: Int64(data.count)
        )
    }
}
