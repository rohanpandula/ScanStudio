// Offline tests for the update service (01-04): pointer parsing, channel
// logic (stable trusts the pointer only; alpha probes the GitHub API and
// degrades to the pointer on any trouble), SHA-256 verification, mount +
// locate app, and code-signature verification. Every case runs against
// injected canned payloads — zero network, zero real GitHub. The two
// hdiutil-dependent mount cases build a real minimal DMG via `hdiutil
// create` and skip gracefully when hdiutil is unavailable.

import CryptoKit
import Security
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

    // MARK: - Phase-02 arch-aware pointer fixtures

    /// The arch-keyed pointer (02-01 emitter output) for a hypothetical
    /// `v0.3.1-alpha.13`: one distinct url+sha256 per architecture.
    private static let archPointerVersion = "0.3.1-alpha.13"
    private static let arm64Checksum = String(repeating: "c", count: 64)
    private static let x8664Checksum = String(repeating: "d", count: 64)

    private static let archKeyedArm64URL =
        "https://github.com/rohanpandula/ScanStudio/releases/download/v0.3.1-alpha.13/ScanStudio-0.3.1-alpha.13-macOS-arm64.dmg"
    private static let archKeyedX86_64URL =
        "https://github.com/rohanpandula/ScanStudio/releases/download/v0.3.1-alpha.13/ScanStudio-0.3.1-alpha.13-macOS-x86_64.dmg"

    private static var archKeyedPointerJSON: String {
        """
        {
            "version": "\(archPointerVersion)",
            "architectures": {
                "arm64": { "url": "\(archKeyedArm64URL)", "sha256": "\(arm64Checksum)" },
                "x86_64": { "url": "\(archKeyedX86_64URL)", "sha256": "\(x8664Checksum)" }
            }
        }
        """
    }

    private static var archKeyedArm64OnlyJSON: String {
        """
        {
            "version": "\(archPointerVersion)",
            "architectures": {
                "arm64": { "url": "\(archKeyedArm64URL)", "sha256": "\(arm64Checksum)" }
            }
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

    // MARK: - 1b. Phase-02 arch-keyed pointer decode + selection

    func testArchKeyedPointerDecodesBothArchs() throws {
        let pointer = try JSONDecoder().decode(UpdatePointerArch.self, from: Data(Self.archKeyedPointerJSON.utf8))

        XCTAssertEqual(pointer.version, Self.archPointerVersion)
        XCTAssertEqual(pointer.architectures.count, 2)
        XCTAssertEqual(pointer.architectures[.arm64]?.url.absoluteString, Self.archKeyedArm64URL)
        XCTAssertEqual(pointer.architectures[.x86_64]?.url.absoluteString, Self.archKeyedX86_64URL)
        XCTAssertEqual(pointer.architectures[.arm64]?.sha256, Self.arm64Checksum)
        XCTAssertEqual(pointer.architectures[.x86_64]?.sha256, Self.x8664Checksum)
        XCTAssertNotEqual(pointer.architectures[.arm64]?.sha256, pointer.architectures[.x86_64]?.sha256,
                          "the two arch entries must describe distinct artifacts")
    }

    func testPointerArchRoundTripEncodesArchKeyedForm() throws {
        let original = UpdatePointerArch(
            version: Self.archPointerVersion,
            architectures: [
                .arm64: UpdateArchEntry(url: URL(string: Self.archKeyedArm64URL)!, sha256: Self.arm64Checksum),
                .x86_64: UpdateArchEntry(url: URL(string: Self.archKeyedX86_64URL)!, sha256: Self.x8664Checksum),
            ]
        )

        let data = try JSONEncoder().encode(original)
        // Encode must emit the arch-keyed JSON *object* (per-arch keys), not
        // a key/value array.
        let jsonObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let archs = try XCTUnwrap(jsonObject["architectures"] as? [String: Any])
        XCTAssertEqual(archs.count, 2)
        XCTAssertNotNil(archs["arm64"])
        XCTAssertNotNil(archs["x86_64"])

        let decoded = try JSONDecoder().decode(UpdatePointerArch.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownArchKeyInPointerThrowsOnDecode() throws {
        // Trust gate: an unrecognized arch key is a malformed/untrusted
        // pointer and must throw, never be silently dropped.
        let json = """
        {
            "version": "\(Self.archPointerVersion)",
            "architectures": {
                "arm64": { "url": "\(Self.archKeyedArm64URL)", "sha256": "\(Self.arm64Checksum)" },
                "powerpc": { "url": "https://example.com/ScanStudio-ppc.dmg", "sha256": "\(Self.x8664Checksum)" }
            }
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(UpdatePointerArch.self, from: Data(json.utf8)))
    }

    func testLegacyFlatPointerStillDecodes() async throws {
        // Regression guard: the old flat {version,url,sha256} pointer must
        // still yield a single candidate with the promised bytes+checksum.
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.pointerJSON.utf8)

        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)
        let candidate = try await checker.latestCandidate(channel: .stable)

        let resolved = try XCTUnwrap(candidate, "a legacy flat pointer must still produce a candidate")
        XCTAssertEqual(resolved.version.raw, "0.3.0-alpha.11")
        XCTAssertEqual(resolved.downloadURL.absoluteString, Self.pointerDownloadURL)
        XCTAssertEqual(resolved.sha256, String(repeating: "a", count: 64))
    }

    func testSelectsHostArchEntry() async throws {
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.archKeyedPointerJSON.utf8)
        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)

        let arm = try await checker.latestCandidate(channel: .stable, arch: .arm64)
        let armCandidate = try XCTUnwrap(arm)
        XCTAssertEqual(armCandidate.version.raw, Self.archPointerVersion)
        XCTAssertEqual(armCandidate.downloadURL.absoluteString, Self.archKeyedArm64URL)
        XCTAssertEqual(armCandidate.sha256, Self.arm64Checksum)

        let intel = try await checker.latestCandidate(channel: .stable, arch: .x86_64)
        let intelCandidate = try XCTUnwrap(intel)
        XCTAssertEqual(intelCandidate.version.raw, Self.archPointerVersion)
        XCTAssertEqual(intelCandidate.downloadURL.absoluteString, Self.archKeyedX86_64URL)
        XCTAssertEqual(intelCandidate.sha256, Self.x8664Checksum)
    }

    func testSelectsDefaultCurrentArchForExistingCallSites() async throws {
        // The single-arch entry point must keep working (the 01-05 model calls
        // it with no arch), delegating to the current host architecture.
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.archKeyedPointerJSON.utf8)
        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)

        let fetched = try await checker.latestCandidate(channel: .stable)
        let candidate = try XCTUnwrap(fetched)
        let expected = HostArchitectureProvider.current() == .arm64
            ? Self.archKeyedArm64URL
            : Self.archKeyedX86_64URL
        XCTAssertEqual(candidate.downloadURL.absoluteString, expected,
                       "the default arch must match the current host architecture")
    }

    func testMissingArchThrowsUnsupported() async throws {
        let stub = StubURLSession()
        stub.dataByURL[pointerURL()] = Data(Self.archKeyedArm64OnlyJSON.utf8)
        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)

        do {
            _ = try await checker.latestCandidate(channel: .stable, arch: .x86_64)
            XCTFail("expected unsupportedArchitecture for a missing x86_64 entry")
        } catch let error as UpdateArchError {
            XCTAssertEqual(error, .unsupportedArchitecture(.x86_64))
        }
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

    func testPrereleaseBootstrapsWhenStablePointerIsMissing() async throws {
        let stub = StubURLSession()
        stub.failingURLs.insert(pointerURL())
        stub.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("""
        [
            {
                "tag_name": "v0.3.0-beta.1",
                "prerelease": true,
                "html_url": "https://github.com/rohanpandula/ScanStudio/releases/tag/v0.3.0-beta.1"
            }
        ]
        """.utf8)
        let betaChecksum = String(repeating: "e", count: 64)
        let betaURL = "https://github.com/rohanpandula/ScanStudio/releases/download/v0.3.0-beta.1/ScanStudio-0.3.0-beta.1-macOS-arm64.dmg"
        stub.dataByURL[perReleaseURL(tag: "v0.3.0-beta.1")] = Data("""
        {
            "version": "0.3.0-beta.1",
            "architectures": {
                "arm64": { "url": "\(betaURL)", "sha256": "\(betaChecksum)" }
            }
        }
        """.utf8)

        let checker = GitHubUpdateChecker(pointerURL: pointerURL(), session: stub)
        let candidate = try await checker.latestCandidate(channel: .alpha, arch: .arm64)

        let resolved = try XCTUnwrap(candidate)
        XCTAssertEqual(resolved.version.raw, "0.3.0-beta.1")
        XCTAssertEqual(resolved.downloadURL.absoluteString, betaURL)
        XCTAssertEqual(resolved.sha256, betaChecksum)
        XCTAssertEqual(resolved.releaseNotesURL?.absoluteString,
                       "https://github.com/rohanpandula/ScanStudio/releases/tag/v0.3.0-beta.1")
        XCTAssertTrue(stub.requestedURLs.contains(pointerURL()),
                      "the checker should first try the stable pointer")
        XCTAssertTrue(stub.requestedURLs.contains(GitHubUpdateChecker.apiReleasesURL),
                      "a missing stable pointer must still probe prereleases")
        XCTAssertTrue(stub.requestedURLs.contains(perReleaseURL(tag: "v0.3.0-beta.1")),
                      "the candidate must come from the beta release's own pointer")
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

        let appRoot = root.appendingPathComponent("ScanStudio.app", isDirectory: true)
        let macos = appRoot.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: macos.appendingPathComponent("Sample"))

        let volname = "ScanStudioMount-\(UUID().uuidString.prefix(6))"
        let dmgURL = root.appendingPathComponent("sample.dmg")
        try Self.createMinimalDMG(from: appRoot, volname: volname, to: dmgURL)
        defer { try? FileManager.default.removeItem(at: dmgURL) }

        let downloader = UpdateDownloader()
        try downloader.withMountedApp(dmgURL) { appURL in
            XCTAssertEqual(appURL.lastPathComponent, "ScanStudio.app")
            XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path),
                          "locate must return an existing bundle on the mounted volume")
        }
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
        XCTAssertThrowsError(try downloader.withMountedApp(dmgURL) { _ in () }) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .notAnApp)
        }
    }

    // MARK: - 9. Signature gate

    func testPublisherTrustAbsentFailsClosedBeforeBundleReads() throws {
        let plain = root.appendingPathComponent("Plain.app", isDirectory: true)
        let macos = plain.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: macos.appendingPathComponent("ScanStudio"))

        let verifier = UpdateBundleVerifier(publisherTrust: nil)
        XCTAssertThrowsError(
            try verifier.validate(
                appURL: plain,
                expectedVersion: UpdateVersion(raw: "0.3.0-alpha.11")!,
                expectedArchitecture: HostArchitectureProvider.current()
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .publisherTrustNotConfigured)
        }
    }

    func testAuthorizedBundleMatchesIdentityVersionArchitectureAndOS() throws {
        let app = try makeValidApp(version: "0.3.0-alpha.11")

        XCTAssertNoThrow(
            try makeBundleVerifier().validate(
                appURL: app,
                expectedVersion: UpdateVersion(raw: "0.3.0-alpha.11")!,
                expectedArchitecture: HostArchitectureProvider.current()
            )
        )
    }

    func testUnauthorizedSignerRejectedEvenWithCorrectMetadata() throws {
        let app = try makeValidApp(version: "0.3.0-alpha.11")
        let verifier = makeBundleVerifier(signatureValidator: RejectingUpdateSignatureValidator())

        XCTAssertThrowsError(
            try verifier.validate(
                appURL: app,
                expectedVersion: UpdateVersion(raw: "0.3.0-alpha.11")!,
                expectedArchitecture: HostArchitectureProvider.current()
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .publisherUnauthorized)
        }
    }

    func testWrongBundleIdentifierRejected() throws {
        let app = try makeValidApp(
            version: "0.3.0-alpha.11",
            overrides: ["CFBundleIdentifier": "example.wrong"]
        )
        assertBundleError(.bundleIdentityMismatch, app: app)
    }

    func testWrongBundleExecutableRejected() throws {
        let app = try makeValidApp(
            version: "0.3.0-alpha.11",
            overrides: ["CFBundleExecutable": "WrongLauncher"]
        )
        assertBundleError(.bundleIdentityMismatch, app: app)
    }

    func testWrongSelectedVersionRejected() throws {
        let app = try makeValidApp(version: "0.3.0-alpha.10")
        assertBundleError(.versionMismatch, app: app)
    }

    func testWrongArchitectureRejected() throws {
        let wrong: HostArchitecture = HostArchitectureProvider.current() == .arm64 ? .x86_64 : .arm64
        let app = try makeValidApp(version: "0.3.0-alpha.11", architecture: wrong)
        assertBundleError(.architectureMismatch, app: app)
    }

    func testUnsupportedMinimumOSRejected() throws {
        let app = try makeValidApp(
            version: "0.3.0-alpha.11",
            overrides: ["LSMinimumSystemVersion": "100.0"]
        )
        assertBundleError(.operatingSystemUnsupported, app: app)
    }

    func testMinimumOSBelowSupportedFloorRejected() throws {
        let app = try makeValidApp(
            version: "0.3.0-alpha.11",
            overrides: ["LSMinimumSystemVersion": "13.0"]
        )
        assertBundleError(.operatingSystemUnsupported, app: app)
    }

    func testAdHocSignerRejectedBySystemPublisherGate() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") else {
            throw XCTSkip("codesign unavailable")
        }
        let app = try makeValidApp(version: "0.3.0-alpha.11")
        let productBinary = app.appendingPathComponent("Contents/MacOS/ScanStudio")
        try FileManager.default.removeItem(at: productBinary)
        let testExecutable = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        try FileManager.default.copyItem(at: testExecutable, to: productBinary)

        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--deep", "--sign", "-", app.path]
        try signing.run()
        signing.waitUntilExit()
        guard signing.terminationStatus == 0 else {
            throw XCTSkip("could not create an ad-hoc signed fixture")
        }

        let designated = try designatedRequirementData(at: app)
        let trust = try XCTUnwrap(
            UpdatePublisherTrust(
                authorizedTeamIdentifier: "ABCDEFGHIJ",
                designatedRequirementData: designated
            )
        )
        let verifier = UpdateBundleVerifier(publisherTrust: trust)

        XCTAssertThrowsError(
            try verifier.validate(
                appURL: app,
                expectedVersion: UpdateVersion(raw: "0.3.0-alpha.11")!,
                expectedArchitecture: HostArchitectureProvider.current()
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .publisherUnauthorized)
        }
    }

    // MARK: - Scoped mount cleanup

    func testMissingPublisherTrustRejectsBeforeAttach() throws {
        let runner = CannedUpdateCommandRunner(mountRoot: root)
        let downloader = makeDownloader(commandRunner: runner)
        let candidate = UpdateCandidate(
            version: UpdateVersion(raw: "0.3.0-alpha.11")!,
            downloadURL: URL(string: "https://example.com/update.dmg")!,
            sha256: String(repeating: "a", count: 64),
            releaseNotesURL: nil
        )

        XCTAssertThrowsError(
            try downloader.withVerifiedMountedApp(
                root.appendingPathComponent("fixture.dmg"),
                candidate: candidate,
                architecture: HostArchitectureProvider.current()
            ) { _ in () }
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .publisherTrustNotConfigured)
        }
        XCTAssertEqual(runner.attachCount, 0)
    }

    func testScopedMountDetachesAfterSuccess() throws {
        let mountRoot = try makeMountRoot(appCount: 1)
        let runner = CannedUpdateCommandRunner(mountRoot: mountRoot)
        let downloader = makeDownloader(commandRunner: runner)

        let value = try downloader.withMountedApp(root.appendingPathComponent("fixture.dmg")) { appURL in
            XCTAssertEqual(appURL.lastPathComponent, "ScanStudio.app")
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(runner.normalDetachCount, 1)
        XCTAssertEqual(runner.forcedDetachCount, 0)
    }

    func testScopedMountDetachesWhenBodyThrows() throws {
        let mountRoot = try makeMountRoot(appCount: 1)
        let runner = CannedUpdateCommandRunner(mountRoot: mountRoot)
        let downloader = makeDownloader(commandRunner: runner)

        XCTAssertThrowsError(
            try downloader.withMountedApp(root.appendingPathComponent("fixture.dmg")) { _ in
                throw URLError(.cancelled)
            }
        ) { error in
            XCTAssertEqual(error as? URLError, URLError(.cancelled))
        }
        XCTAssertEqual(runner.normalDetachCount, 1)
    }

    func testMultipleAppsRejectedAndDetached() throws {
        let mountRoot = try makeMountRoot(appCount: 2)
        let runner = CannedUpdateCommandRunner(mountRoot: mountRoot)
        let downloader = makeDownloader(commandRunner: runner)

        XCTAssertThrowsError(
            try downloader.withMountedApp(root.appendingPathComponent("fixture.dmg")) { _ in () }
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .notAnApp)
        }
        XCTAssertEqual(runner.normalDetachCount, 1)
    }

    func testNestedHiddenSecondAppRejectedAndDetached() throws {
        let mountRoot = try makeMountRoot(appCount: 1)
        try FileManager.default.createDirectory(
            at: mountRoot.appendingPathComponent("Extras/.Hidden.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        let runner = CannedUpdateCommandRunner(mountRoot: mountRoot)
        let downloader = makeDownloader(commandRunner: runner)

        XCTAssertThrowsError(
            try downloader.withMountedApp(root.appendingPathComponent("fixture.dmg")) { _ in () }
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .notAnApp)
        }
        XCTAssertEqual(runner.normalDetachCount, 1)
    }

    func testDetachFailureFallsBackToBoundedForce() throws {
        let mountRoot = try makeMountRoot(appCount: 1)
        let runner = CannedUpdateCommandRunner(
            mountRoot: mountRoot,
            normalDetachStatus: 1,
            forcedDetachStatus: 0
        )
        let downloader = makeDownloader(commandRunner: runner)

        XCTAssertNoThrow(
            try downloader.withMountedApp(root.appendingPathComponent("fixture.dmg")) { _ in () }
        )
        XCTAssertEqual(runner.normalDetachCount, 1)
        XCTAssertEqual(runner.forcedDetachCount, 1)
    }

    func testBothDetachAttemptsFailClosed() throws {
        let mountRoot = try makeMountRoot(appCount: 1)
        let runner = CannedUpdateCommandRunner(
            mountRoot: mountRoot,
            normalDetachStatus: 1,
            forcedDetachStatus: 1
        )
        let downloader = makeDownloader(commandRunner: runner)

        XCTAssertThrowsError(
            try downloader.withMountedApp(root.appendingPathComponent("fixture.dmg")) { _ in () }
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadError, .detachFailed)
        }
        XCTAssertEqual(runner.normalDetachCount, 1)
        XCTAssertEqual(runner.forcedDetachCount, 1)
    }

    func testMidStreamChecksumReadErrorIsNotReportedAsMismatch() async throws {
        let stub = StubURLSession()
        let dmgURL = URL(string: "https://example.com/ScanStudio-0.3.0-alpha.11-macOS-arm64.dmg")!
        stub.dataByURL[dmgURL] = Data("downloaded bytes".utf8)
        let outDir = root.appendingPathComponent("read-error-download", isDirectory: true)
        let expectedPath = outDir.appendingPathComponent("ScanStudio-0.3.0-alpha.11.dmg").path
        let downloader = UpdateDownloader(
            session: stub,
            bundleVerifier: UpdateBundleVerifier(publisherTrust: nil),
            commandRunner: CannedUpdateCommandRunner(mountRoot: root),
            fileReader: FaultingUpdateFileReader()
        )
        let candidate = UpdateCandidate(
            version: UpdateVersion(raw: "0.3.0-alpha.11")!,
            downloadURL: dmgURL,
            sha256: String(repeating: "a", count: 64),
            releaseNotesURL: nil
        )

        do {
            _ = try await downloader.download(candidate, to: outDir)
            XCTFail("expected checksumReadFailed")
        } catch let error as UpdateDownloadError {
            guard case .checksumReadFailed(let path, let cause) = error else {
                return XCTFail("expected checksumReadFailed, got \(error)")
            }
            XCTAssertEqual(path, expectedPath)
            XCTAssertFalse(cause.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath))
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

    private func makeBundleVerifier(
        signatureValidator: any UpdateCodeSignatureValidating = AcceptingServiceSignatureValidator()
    ) -> UpdateBundleVerifier {
        UpdateBundleVerifier(
            publisherTrust: UpdatePublisherTrust(
                authorizedTeamIdentifier: "ABCDEFGHIJ",
                designatedRequirementData: Data([1])
            ),
            signatureValidator: signatureValidator,
            hostOperatingSystemVersion: OperatingSystemVersion(
                majorVersion: 99,
                minorVersion: 0,
                patchVersion: 0
            )
        )
    }

    private func assertBundleError(
        _ expected: UpdateDownloadError,
        app: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try makeBundleVerifier().validate(
                appURL: app,
                expectedVersion: UpdateVersion(raw: "0.3.0-alpha.11")!,
                expectedArchitecture: HostArchitectureProvider.current()
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadError, expected, file: file, line: line)
        }
    }

    private func makeValidApp(
        version: String,
        architecture: HostArchitecture = HostArchitectureProvider.current(),
        overrides: [String: Any] = [:]
    ) throws -> URL {
        let app = root.appendingPathComponent("Bundle-\(UUID().uuidString)/ScanStudio.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var information: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": UpdatePublisherTrust.bundleIdentifier,
            "CFBundleExecutable": UpdatePublisherTrust.bundleExecutable,
            "CFBundleShortVersionString": "0.3.0",
            "ScanStudioRelease": version,
            "LSMinimumSystemVersion": "14.0",
        ]
        for (key, value) in overrides { information[key] = value }
        let plist = try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let launcher = macOS.appendingPathComponent(UpdatePublisherTrust.bundleExecutable)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let binary = macOS.appendingPathComponent(UpdatePublisherTrust.architectureExecutable)
        try fakeMachO(for: architecture).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return app
    }

    private func fakeMachO(for architecture: HostArchitecture) -> Data {
        let cpu: [UInt8] = architecture == .arm64
            ? [0x0c, 0x00, 0x00, 0x01]
            : [0x07, 0x00, 0x00, 0x01]
        return Data([0xcf, 0xfa, 0xed, 0xfe] + cpu)
    }

    private func designatedRequirementData(at app: URL) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else {
            throw XCTSkip("Security.framework could not open ad-hoc fixture")
        }
        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSRequirementInformation),
            &rawInformation
        ) == errSecSuccess,
              let information = rawInformation as? [String: Any],
              let rawRequirement = information[kSecCodeInfoDesignatedRequirement as String] else {
            throw XCTSkip("ad-hoc fixture has no designated requirement")
        }
        let cfRequirement = rawRequirement as CFTypeRef
        guard CFGetTypeID(cfRequirement) == SecRequirementGetTypeID() else {
            throw XCTSkip("unexpected designated-requirement type")
        }
        let requirement = unsafeDowncast(cfRequirement, to: SecRequirement.self)
        var data: CFData?
        guard SecRequirementCopyData(requirement, SecCSFlags(rawValue: 0), &data) == errSecSuccess,
              let data else {
            throw XCTSkip("could not serialize designated requirement")
        }
        return data as Data
    }

    private func makeMountRoot(appCount: Int) throws -> URL {
        let mount = root.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        if appCount > 0 {
            try FileManager.default.createDirectory(
                at: mount.appendingPathComponent("ScanStudio.app", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        if appCount > 1 {
            try FileManager.default.createDirectory(
                at: mount.appendingPathComponent("Other.app", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return mount
    }

    private func makeDownloader(commandRunner: CannedUpdateCommandRunner) -> UpdateDownloader {
        UpdateDownloader(
            session: StubURLSession(),
            bundleVerifier: UpdateBundleVerifier(publisherTrust: nil),
            commandRunner: commandRunner,
            fileReader: NeverOpenedUpdateFileReader()
        )
    }

    private func requireHDIUtil() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/hdiutil") else {
            throw XCTSkip("hdiutil not available; skipping mount tests")
        }
    }

    /// Builds a real minimal read-only DMG from `folder` via `hdiutil create`,
    /// so the scoped mount path runs against an actual mounted volume.
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

private struct AcceptingServiceSignatureValidator: UpdateCodeSignatureValidating {
    func validateApplication(at appURL: URL, trust: UpdatePublisherTrust) throws {}
}

private struct RejectingUpdateSignatureValidator: UpdateCodeSignatureValidating {
    func validateApplication(at appURL: URL, trust: UpdatePublisherTrust) throws {
        throw UpdateDownloadError.publisherUnauthorized
    }
}

private final class CannedUpdateCommandRunner: UpdateCommandRunning, @unchecked Sendable {
    private let mountRoot: URL
    private let normalDetachStatus: Int32
    private let forcedDetachStatus: Int32
    private(set) var attachCount = 0
    private(set) var normalDetachCount = 0
    private(set) var forcedDetachCount = 0

    init(
        mountRoot: URL,
        normalDetachStatus: Int32 = 0,
        forcedDetachStatus: Int32 = 0
    ) {
        self.mountRoot = mountRoot
        self.normalDetachStatus = normalDetachStatus
        self.forcedDetachStatus = forcedDetachStatus
    }

    func run(_ executablePath: String, arguments: [String], timeout: TimeInterval) throws -> UpdateCommandResult {
        if arguments.first == "attach" {
            attachCount += 1
            let plist: [String: Any] = [
                "system-entities": [[
                    "dev-entry": "/dev/disk-test",
                    "mount-point": mountRoot.path,
                ]],
            ]
            return UpdateCommandResult(
                status: 0,
                output: try PropertyListSerialization.data(
                    fromPropertyList: plist,
                    format: .xml,
                    options: 0
                )
            )
        }
        if arguments.contains("-force") {
            forcedDetachCount += 1
            return UpdateCommandResult(status: forcedDetachStatus, output: Data())
        }
        normalDetachCount += 1
        return UpdateCommandResult(status: normalDetachStatus, output: Data())
    }
}

private struct NeverOpenedUpdateFileReader: UpdateFileReading {
    func open(_ url: URL) throws -> any UpdateReadableFile {
        throw URLError(.cannotOpenFile)
    }
}

private struct FaultingUpdateFileReader: UpdateFileReading {
    func open(_ url: URL) throws -> any UpdateReadableFile {
        FaultingUpdateReadableFile()
    }
}

private final class FaultingUpdateReadableFile: UpdateReadableFile, @unchecked Sendable {
    private var readCount = 0

    func read(upToCount count: Int) throws -> Data {
        defer { readCount += 1 }
        if readCount == 0 { return Data("prefix".utf8) }
        throw CocoaError(.fileReadUnknown)
    }

    func close() throws {}
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
