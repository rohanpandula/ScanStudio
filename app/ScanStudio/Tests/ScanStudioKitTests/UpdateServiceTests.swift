// Offline tests for the update service (01-04): pointer parsing, channel
// logic (stable trusts the pointer only; alpha probes the GitHub API and
// degrades to the pointer on any trouble), SHA-256 verification, mount +
// locate app, and code-signature verification. Every case runs against
// injected canned payloads — zero network, zero real GitHub. The two
// hdiutil-dependent mount cases build a real minimal DMG via `hdiutil
// create` and skip gracefully when hdiutil is unavailable.

import CryptoKit
import XCTest

@testable import ScanStudioKit

final class UpdateServiceTests: XCTestCase {
    private var root: URL!

    private static let pointerJSON = """
    {
        "version": "0.3.0-alpha.11",
        "url": "https://github.com/rohanpandula/ScanStudio/releases/download/v0.3.0-alpha.11/ScanStudio-0.3.0-alpha.11-macOS-arm64.dmg",
        "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
    """

    private static let pointerDownloadURL =
        "https://github.com/rohanpandula/ScanStudio/releases/download/v0.3.0-alpha.11/ScanStudio-0.3.0-alpha.11-macOS-arm64.dmg"

    /// The configured pointer's checksum ('a'…). Deliberately distinct from the
    /// per-release checksum below so tests can prove the alpha path never
    /// borrows the stable pointer's sha256 for a different artifact.
    private static let stableChecksum = String(repeating: "a", count: 64)

    /// The newest pre-release's OWN per-release pointer checksum ('b'…).
    private static let perReleaseChecksum = String(repeating: "b", count: 64)

    /// The per-release `latest.json` the 01-01 pipeline emits for the
    /// `v0.3.0-alpha.12` release: authoritative url + sha256 for THAT release.
    private static var alpha12ReleasePointerJSON: String {
        """
        {
            "version": "0.3.0-alpha.12",
            "url": "https://github.com/rohanpandula/ScanStudio/releases/download/v0.3.0-alpha.12/ScanStudio-0.3.0-alpha.12-macOS-arm64.dmg",
            "sha256": "\(perReleaseChecksum)"
        }
        """
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Pointer

    func testPointerDecodes() throws {
        let data = Data(Self.pointerJSON.utf8)
        let pointer = try JSONDecoder().decode(UpdatePointer.self, from: data)

        XCTAssertEqual(pointer.version, "0.3.0-alpha.11")
        XCTAssertEqual(pointer.url.absoluteString, Self.pointerDownloadURL)
        XCTAssertEqual(pointer.sha256, String(repeating: "a", count: 64))
    }

    // MARK: - 2. Stable trusts the pointer only

    func testStableUsesPointerOnly() async throws {
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.pointerJSON.utf8)

        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)
        let candidate = try await checker.latestCandidate(channel: .stable)

        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.version.raw, "0.3.0-alpha.11")
        XCTAssertEqual(candidate?.downloadURL.absoluteString, Self.pointerDownloadURL)
        XCTAssertEqual(candidate?.sha256, String(repeating: "a", count: 64))
        XCTAssertTrue(stub.requestedURLs.contains(pointerURL()))
        XCTAssertFalse(
            stub.requestedURLs.contains(GitHubUpdateChecker.apiReleasesURL),
            "stable must not consult the GitHub API"
        )
    }

    // MARK: - 3. Alpha prefers a newer prerelease from the API

    func testAlphaPrefersNewerPrerelease() async throws {
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.pointerJSON.utf8)
        stub.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("""
        [
            {
                "tag_name": "v0.3.0-alpha.12",
                "prerelease": true,
                "html_url": "https://github.com/rohanpandula/ScanStudio/releases/tag/v0.3.0-alpha.12"
            },
            {
                "tag_name": "v0.3.0",
                "prerelease": false,
                "html_url": "https://github.com/rohanpandula/ScanStudio/releases/tag/v0.3.0"
            }
        ]
        """.utf8)
        // Production behavior: the newer prerelease's candidate requires its
        // own per-release pointer (authoritative bytes+checksum). Stub it so
        // the API-probed alpha.12 is preferred, as the release pipeline emits.
        stub.dataByURL[perReleaseURL(tag: "v0.3.0-alpha.12")] = Data(Self.alpha12ReleasePointerJSON.utf8)

        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)
        let candidate = try await checker.latestCandidate(channel: .alpha)

        XCTAssertEqual(candidate?.version.raw, "0.3.0-alpha.12",
                       "alpha must prefer the newer prerelease from the API")
        XCTAssertEqual(candidate?.version, UpdateVersion(raw: "0.3.0-alpha.12"))
        XCTAssertEqual(candidate?.sha256, Self.perReleaseChecksum,
                       "the newer prerelease's checksum must come from its own per-release pointer")
        XCTAssertEqual(candidate?.releaseNotesURL?.absoluteString,
                       "https://github.com/rohanpandula/ScanStudio/releases/tag/v0.3.0-alpha.12")
    }

    // MARK: - 4. Alpha degrades to the pointer on API trouble

    func testAlphaFallsBackOnAPIError() async throws {
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.pointerJSON.utf8)
        stub.failingURLs.insert(GitHubUpdateChecker.apiReleasesURL)

        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)
        let candidate = try await checker.latestCandidate(channel: .alpha)

        XCTAssertNotNil(candidate, "an API failure must not crash or throw")
        XCTAssertEqual(candidate?.version.raw, "0.3.0-alpha.11",
                       "alpha must fall back to the pointer candidate on API error")
    }

    // MARK: - 4b. Authoritative alpha checksum (01-08 gap closure)

    func testAlphaUsesPerReleaseChecksum() async throws {
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.pointerJSON.utf8)
        stub.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("""
        [
            {
                "tag_name": "v0.3.0-alpha.12",
                "prerelease": true,
                "html_url": "https://github.com/rohanpandula/ScanStudio/releases/tag/v0.3.0-alpha.12"
            }
        ]
        """.utf8)
        // The newest pre-release's own per-release pointer — checksum 'b'…,
        // distinct from the configured pointer's 'a'….
        stub.dataByURL[perReleaseURL(tag: "v0.3.0-alpha.12")] = Data(Self.alpha12ReleasePointerJSON.utf8)

        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)
        let candidate = try await checker.latestCandidate(channel: .alpha)

        let resolved = try XCTUnwrap(candidate)
        XCTAssertEqual(resolved.version.raw, "0.3.0-alpha.12")
        XCTAssertEqual(resolved.sha256, Self.perReleaseChecksum,
                       "the candidate's sha256 must come from the release's own pointer, not the stable pointer")
        XCTAssertEqual(
            resolved.downloadURL.absoluteString,
            "https://github.com/rohanpandula/ScanStudio/releases/download/v0.3.0-alpha.12/ScanStudio-0.3.0-alpha.12-macOS-arm64.dmg"
        )
        XCTAssertNotEqual(resolved.sha256, Self.stableChecksum,
                         "the per-release checksum must differ from the configured pointer's")
    }

    func testAlphaFallsBackToPointerWhenPerReleasePointerUnavailable() async throws {
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.pointerJSON.utf8)
        stub.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("""
        [
            { "tag_name": "v0.3.0-alpha.12", "prerelease": true, "html_url": "https://github.com/x" }
        ]
        """.utf8)
        // NOTE: the per-release URL is NOT stubbed → data(from:) throws.

        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)
        let candidate = try await checker.latestCandidate(channel: .alpha)

        let resolved = try XCTUnwrap(candidate, "a missing per-release pointer must not throw")
        XCTAssertEqual(resolved.version.raw, "0.3.0-alpha.11",
                       "fallback must resolve to the configured pointer candidate")
        XCTAssertEqual(resolved.sha256, Self.stableChecksum)
        XCTAssertEqual(resolved.downloadURL.absoluteString, Self.pointerDownloadURL)
    }

    func testAlphaIgnoresPerReleasePointerOnVersionMismatch() async throws {
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.pointerJSON.utf8)
        stub.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("""
        [
            { "tag_name": "v0.3.0-alpha.12", "prerelease": true, "html_url": "https://github.com/x" }
        ]
        """.utf8)
        // Per-release pointer decodes but its version (alpha.11) ≠ the tag
        // (alpha.12) — equality-of-intent fails → fall back to the pointer.
        stub.dataByURL[perReleaseURL(tag: "v0.3.0-alpha.12")] = Data(Self.pointerJSON.utf8)

        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)
        let candidate = try await checker.latestCandidate(channel: .alpha)

        let resolved = try XCTUnwrap(candidate)
        XCTAssertEqual(resolved.version.raw, "0.3.0-alpha.11",
                       "a version mismatch between tag and per-release pointer must fall back to the configured pointer")
        XCTAssertEqual(resolved.sha256, Self.stableChecksum)
        XCTAssertEqual(resolved.downloadURL.absoluteString, Self.pointerDownloadURL)
    }

    func testAlphaStableChecksumDifferenceProvesBorrowEnded() {
        // Guards the regression: the per-release checksum constant and the
        // stable pointer's checksum genuinely differ, so the alpha test can
        // actually detect a re-borrow of the stable checksum.
        XCTAssertEqual(Self.stableChecksum, String(repeating: "a", count: 64))
        XCTAssertEqual(Self.perReleaseChecksum, String(repeating: "b", count: 64))
        XCTAssertNotEqual(Self.perReleaseChecksum, Self.stableChecksum)
        XCTAssertEqual(Self.perReleaseChecksum.count, 64)
        XCTAssertEqual(Self.stableChecksum.count, 64)
    }

    // MARK: - 5. Unparseable pointer version means no update

    func testUnparseablePointerMeansNoUpdate() async throws {
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data("""
        {
            "version": "garbage",
            "url": "https://example.com/ScanStudio.dmg",
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }
        """.utf8)

        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)
        let candidate = try await checker.latestCandidate(channel: .stable)

        XCTAssertNil(candidate, "an unparseable pointer version must be treated as no update")
    }

    // MARK: - 6. Checksum gate

    func testChecksumMismatchThrows() async throws {
        let stub = StubURLSession()
        let payload = Data("fake dmg payload \(UUID().uuidString)".utf8)
        let dmgURL = URL(string: "https://example.com/ScanStudio-0.3.0-alpha.11-macOS-arm64.dmg")!
        stub.dataByURL[dmgURL] = payload

        let downloader = UpdateDownloader(session: stub)
        let outDir = root.appendingPathComponent("downloads", isDirectory: true)
        let candidate = UpdateCandidate(
            version: UpdateVersion(raw: "0.3.0-alpha.11")!,
            downloadURL: dmgURL,
            sha256: String(repeating: "0", count: 64),
            releaseNotesURL: nil
        )

        do {
            _ = try await downloader.download(candidate, to: outDir)
            XCTFail("expected checksumMismatch")
        } catch let error as UpdateDownloadError {
            XCTAssertEqual(error, .checksumMismatch)
        }
    }

    // MARK: - 7. Valid checksum returns the DMG

    func testValidChecksumReturnsDmg() async throws {
        let stub = StubURLSession()
        let payload = Data("real dmg payload \(UUID().uuidString)".utf8)
        let dmgURL = URL(string: "https://example.com/ScanStudio-0.3.0-alpha.11-macOS-arm64.dmg")!
        stub.dataByURL[dmgURL] = payload
        let realSHA = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let downloader = UpdateDownloader(session: stub)
        let outDir = root.appendingPathComponent("downloads", isDirectory: true)
        let candidate = UpdateCandidate(
            version: UpdateVersion(raw: "0.3.0-alpha.11")!,
            downloadURL: dmgURL,
            sha256: realSHA,
            releaseNotesURL: nil
        )

        let url = try await downloader.download(candidate, to: outDir)

        XCTAssertEqual(url.lastPathComponent, "ScanStudio-0.3.0-alpha.11.dmg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    // MARK: - 8. Mount + locate app

    func testMountLocateApp() async throws {
        try requireHDIUtil()

        let appRoot = root.appendingPathComponent("Sample.app", isDirectory: true)
        let macos = appRoot.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: macos.appendingPathComponent("Sample"))

        let volname = "ScanStudioMount-\(UUID().uuidString.prefix(6))"
        let dmgURL = root.appendingPathComponent("sample.dmg")
        try Self.createMinimalDMG(from: appRoot, volname: volname, to: dmgURL)
        defer { try? FileManager.default.removeItem(at: dmgURL) }

        let downloader = UpdateDownloader()
        let appURL = try downloader.mountAndLocateApp(dmgURL)
        defer { downloader.tearDownMount(appURL.deletingLastPathComponent()) }

        XCTAssertEqual(appURL.lastPathComponent.lowercased(), "sample.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path),
                      "locate must return an existing bundle on the mounted volume")
    }

    func testMountLocateAppNoAppThrows() async throws {
        try requireHDIUtil()

        let emptyDir = root.appendingPathComponent("empty-volume", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let volname = "ScanStudioEmpty-\(UUID().uuidString.prefix(6))"
        let dmgURL = root.appendingPathComponent("empty.dmg")
        try Self.createMinimalDMG(from: emptyDir, volname: volname, to: dmgURL)
        defer { try? FileManager.default.removeItem(at: dmgURL) }

        let downloader = UpdateDownloader()
        XCTAssertThrowsError(try downloader.mountAndLocateApp(dmgURL)) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .notAnApp)
        }
    }

    // MARK: - 9. Signature gate

    func testSignatureInvalidForPlainDir() throws {
        let plain = root.appendingPathComponent("Plain.app", isDirectory: true)
        let macos = plain.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: macos.appendingPathComponent("ScanStudio"))

        let downloader = UpdateDownloader()
        XCTAssertThrowsError(try downloader.verifyCodeSignature(at: plain)) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .signatureInvalid)
        }
    }

    // MARK: - Fixture helpers

    private func pointerURL() -> URL {
        URL(string: "https://example.com/latest.json")!
    }

    /// The deterministic per-release pointer URL for a tag (mirrors the
    /// checker's exposed `releasePointerURL(tag:)`).
    private func perReleaseURL(tag: String) -> URL {
        GitHubUpdateChecker.releasePointerURL(tag: tag)
    }

    private func requireHDIUtil() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/hdiutil") else {
            throw XCTSkip("hdiutil not available; skipping mount tests")
        }
    }

    /// Builds a real minimal read-only DMG from `folder` via `hdiutil create`,
    /// so `mountAndLocateApp` runs against an actual mounted volume.
    private static func createMinimalDMG(from folder: URL, volname: String, to output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "create", "-srcfolder", folder.path, "-volname", volname,
            "-format", "UDRO", "-ov", output.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        _ = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "UpdateServiceTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "hdiutil create failed (status \(process.terminationStatus))"]
            )
        }
    }
}

/// Canned in-memory URLSession stand-in: `data(from:)`/`download(from:)`
/// answer from a URL-keyed map, so no test touches the network.
private final class StubURLSession: URLSessionProtocol, @unchecked Sendable {
    var dataByURL: [URL: Data] = [:]
    var failingURLs: Set<URL> = []
    private(set) var requestedURLs: [URL] = []

    func data(from url: URL) async throws -> (Data, URLResponse) {
        requestedURLs.append(url)
        if failingURLs.contains(url) {
            throw URLError(.cannotConnectToHost)
        }
        guard let data = dataByURL[url] else {
            throw URLError(.fileDoesNotExist)
        }
        return (data, response(for: url))
    }

    func download(from url: URL, delegate: (any URLSessionTaskDelegate)?) async throws -> (URL, URLResponse) {
        requestedURLs.append(url)
        guard let data = dataByURL[url] else {
            throw URLError(.fileDoesNotExist)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("StubDownload-\(UUID().uuidString)")
        try data.write(to: temporary)
        return (temporary, response(for: url))
    }

    private func response(for url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}
