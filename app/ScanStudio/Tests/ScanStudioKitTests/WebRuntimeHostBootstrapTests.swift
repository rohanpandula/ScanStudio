import CryptoKit
import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Optional web runtime host bootstrap")
struct WebRuntimeHostBootstrapTests {
    @Test("release trust metadata builds an exact-version service")
    func validTrustMetadata() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebRuntimeHostBootstrapTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let services = try WebRuntimeHostBootstrap.makeServices(
            infoDictionary: [
                WebRuntimeHostBootstrap.releaseVersionKey: "0.4.0",
                WebRuntimeHostBootstrap.publicKeyInfoKey:
                    privateKey.publicKey.rawRepresentation.base64EncodedString(),
                WebRuntimeHostBootstrap.teamIdentifierInfoKey: "TESTTEAM01",
            ],
            applicationSupportDirectory: root.appendingPathComponent("Application Support"),
            cachesDirectory: root.appendingPathComponent("Caches"),
            httpClient: BootstrapUnavailableHTTPClient(),
            payloadPreparer: UnavailableWebRuntimePayloadPreparer(),
            codeAssessor: UnavailableWebRuntimeCodeAssessor()
        )

        #expect(services.request.hostVersionString == "0.4.0")
        #expect(services.request.protocolVersion == 1)
        #expect(services.request.expectedCodeIdentity?.bundleIdentifier
            == "dev.scanstudio.live.web-runtime")
        #expect(services.request.expectedCodeIdentity?.teamIdentifier == "TESTTEAM01")
    }

    @Test("missing, partial, or noncanonical trust metadata fails closed")
    func invalidTrustMetadata() {
        let root = FileManager.default.temporaryDirectory
        let validKey = Data(repeating: 7, count: 32).base64EncodedString()
        let invalidDictionaries: [[String: Any]] = [
            [:],
            [
                WebRuntimeHostBootstrap.releaseVersionKey: "0.4.0",
                WebRuntimeHostBootstrap.publicKeyInfoKey: validKey,
            ],
            [
                WebRuntimeHostBootstrap.releaseVersionKey: "0.4.0",
                WebRuntimeHostBootstrap.publicKeyInfoKey: "not-base64",
                WebRuntimeHostBootstrap.teamIdentifierInfoKey: "TESTTEAM01",
            ],
            [
                WebRuntimeHostBootstrap.releaseVersionKey: "latest",
                WebRuntimeHostBootstrap.publicKeyInfoKey: validKey,
                WebRuntimeHostBootstrap.teamIdentifierInfoKey: "TESTTEAM01",
            ],
        ]

        for dictionary in invalidDictionaries {
            #expect(throws: WebRuntimeDistributionError.productionTrustUnavailable) {
                try WebRuntimeHostBootstrap.makeServices(
                    infoDictionary: dictionary,
                    applicationSupportDirectory: root,
                    cachesDirectory: root,
                    httpClient: BootstrapUnavailableHTTPClient(),
                    payloadPreparer: UnavailableWebRuntimePayloadPreparer(),
                    codeAssessor: UnavailableWebRuntimeCodeAssessor()
                )
            }
        }
    }
}

private struct BootstrapUnavailableHTTPClient: WebRuntimeHTTPClient {
    func download(
        from url: URL,
        to destination: URL,
        maximumBytes: Int64,
        redirectPolicy: WebRuntimeGitHubURLPolicy
    ) async throws -> WebRuntimeHTTPPayload {
        throw WebRuntimeDistributionError.transportFailed
    }
}
