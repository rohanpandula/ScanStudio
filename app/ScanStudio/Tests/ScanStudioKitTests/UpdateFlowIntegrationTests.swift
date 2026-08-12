// End-to-end updater flow test (01-06): drives the whole wired pipeline in
// one place — update pointer (file URL) -> GitHubUpdateChecker ->
// UpdateDownloader (SHA-256 verified) -> UpdateInstaller (snapshot / swap /
// rollback), plus the corrupt-checksum rejection path. Everything runs against
// seeded fake app bundles in temp directories: a canned URLSessionProtocol
// answers from injectable local fixtures, so there is zero network, zero
// /Applications mutation, and zero scanner interaction. The hdiutil mount leg
// is bypassed for directory fixtures by design (the mount path is exercised
// independently where a real DMG exists — see UpdateServiceTests).
//
// Phase 02 extends the suite with arch-selected cases: the seeded pointer is
// arch-keyed (arm64 + x86_64 entries with distinct real shas) and the wired
// flow must select + install the requested/HOST architecture's artifact, a
// cross-arch byte mismatch is checksum-rejected (wrong arch never installs),
// and a pointer with no entry for the requested arch surfaces the typed
// unsupported-architecture error in flow. All offline; a real Intel bundle
// only executes on the CI x86_64 leg (see 02-CONTEXT.md).

import CryptoKit
import XCTest

@testable import ScanStudioKit

final class UpdateFlowIntegrationTests: XCTestCase {
    private var root: URL!
    private var installDirectory: URL!
    private var rollbackDirectory: URL!
    private var releaseDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateFlowIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        installDirectory = root.appendingPathComponent("Applications", isDirectory: true)
        rollbackDirectory = root.appendingPathComponent("Rollback", isDirectory: true)
        releaseDirectory = root.appendingPathComponent("Release", isDirectory: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)

        try makeApp("ScanStudio.app", at: installDirectory, release: "0.3.0-alpha.10", marker: "old")
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Whole wired flow: pointer -> check -> download -> verify -> snapshot -> swap -> rollback

    func testWholeWiredFlow() async throws {
        // The "new release" bundle, plus a real on-disk release artifact (the
        // bundle zipped) whose bytes double as the checksum trust anchor.
        let newApp = releaseDirectory.appendingPathComponent("ScanStudio.app", isDirectory: true)
        try makeApp("ScanStudio.app", at: releaseDirectory, release: "0.3.0-alpha.11", marker: "new")
        let artifact = try makeReleaseArtifact(of: newApp)

        // Pointer asset: latest.json points at the artifact and carries its real sha256.
        let pointerURL = releaseDirectory.appendingPathComponent("latest.json")
        let pointerData = Data("""
        {
            "version": "0.3.0-alpha.11",
            "url": "\(artifact.url.absoluteString)",
            "sha256": "\(artifact.sha256)"
        }
        """.utf8)
        try pointerData.write(to: pointerURL)

        let session = CannedURLSession()
        session.dataByURL[pointerURL] = pointerData
        session.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("[]".utf8)
        session.dataByURL[artifact.url] = artifact.payload

        // 1. Checker resolves the candidate from the pointer. Alpha channel
        //    consults the API first; an empty release list degrades to the
        //    pointer candidate, mirroring the production degradation path.
        let checker = GitHubUpdateChecker(pointerURL: pointerURL, session: session)
        let resolvedCandidate = try await checker.latestCandidate(channel: .alpha)
        let candidate = try XCTUnwrap(resolvedCandidate)
        XCTAssertEqual(candidate.version, UpdateVersion(raw: "0.3.0-alpha.11"))
        XCTAssertEqual(candidate.sha256, artifact.sha256)

        // 2. Downloader fetches the artifact and must pass the SHA-256 gate
        //    before anything can be mounted or installed.
        let downloader = UpdateDownloader(session: session)
        let downloadDir = root.appendingPathComponent("Downloads", isDirectory: true)
        let downloaded = try await downloader.download(candidate, to: downloadDir)
        XCTAssertEqual(downloaded.lastPathComponent, "ScanStudio-0.3.0-alpha.11.dmg")
        XCTAssertEqual(try Data(contentsOf: downloaded), artifact.payload)

        // 3. Installer: snapshot current (old) -> swap in new -> rollback old.
        //    The scoped hdiutil leg is bypassed for directory fixtures by
        //    design (see header); the archive is pointed at the bundle that
        //    corresponds to the artifact we just verified and downloaded.
        let installer = try UpdateInstaller(
            appDirectory: installDirectory,
            rollbackDirectory: rollbackDirectory,
            bundleVerifier: makeBundleVerifier()
        )
        XCTAssertNil(installer.availableRollback, "no rollback is available before the first snapshot")

        let archive = UpdateArchive(
            version: candidate.version,
            sourceAppPath: newApp,
            checksumSHA256: candidate.sha256
        )
        try installer.install(archive)

        XCTAssertEqual(try markerContents(installDirectory.appendingPathComponent("ScanStudio.app")), "new")
        XCTAssertNotNil(installer.availableRollback, "install must first snapshot so rollback is available")
        XCTAssertEqual(installer.availableRollback?.version.raw, "0.3.0-alpha.10")

        let restored = try installer.restorePrevious()
        XCTAssertEqual(restored.lastPathComponent, "ScanStudio.app")
        XCTAssertEqual(try markerContents(installDirectory.appendingPathComponent("ScanStudio.app")), "old")
    }

    // MARK: - Corrupt release: a bad sha256 is rejected before anything swaps

    func testChecksumRejectsCorruptRelease() async throws {
        // Same fixture as the happy path, but the feed promises a bogus (yet
        // well-formed) sha256 — the downloader must refuse the bytes.
        let newApp = releaseDirectory.appendingPathComponent("ScanStudio.app", isDirectory: true)
        try makeApp("ScanStudio.app", at: releaseDirectory, release: "0.3.0-alpha.11", marker: "new")
        let artifact = try makeReleaseArtifact(of: newApp)

        let bogusSHA = String(repeating: "0", count: 64)
        let pointerURL = releaseDirectory.appendingPathComponent("latest.json")
        let pointerData = Data("""
        {
            "version": "0.3.0-alpha.11",
            "url": "\(artifact.url.absoluteString)",
            "sha256": "\(bogusSHA)"
        }
        """.utf8)
        try pointerData.write(to: pointerURL)

        let session = CannedURLSession()
        session.dataByURL[pointerURL] = pointerData
        session.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("[]".utf8)
        session.dataByURL[artifact.url] = artifact.payload

        let checker = GitHubUpdateChecker(pointerURL: pointerURL, session: session)
        let resolvedCandidate = try await checker.latestCandidate(channel: .alpha)
        let candidate = try XCTUnwrap(resolvedCandidate)
        XCTAssertEqual(candidate.sha256, bogusSHA)

        let downloader = UpdateDownloader(session: session)
        let downloadDir = root.appendingPathComponent("Downloads", isDirectory: true)
        do {
            _ = try await downloader.download(candidate, to: downloadDir)
            XCTFail("expected checksumMismatch for a corrupt release")
        } catch let error as UpdateDownloadError {
            XCTAssertEqual(error, .checksumMismatch)
        }

        // Nothing may have been swapped, snapshotted, or left staged.
        XCTAssertEqual(try markerContents(installDirectory.appendingPathComponent("ScanStudio.app")), "old")
        let installer = try UpdateInstaller(
            appDirectory: installDirectory,
            rollbackDirectory: rollbackDirectory,
            bundleVerifier: makeBundleVerifier()
        )
        XCTAssertNil(installer.availableRollback)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: downloadDir.path)
        XCTAssertTrue(leftovers.isEmpty, "a rejected download must not leave a staged artifact")
    }

    // MARK: - Arch-selected flow (Phase 02): right arch installs, wrong arch
    //         never, unsupported arch is a typed error

    func testArchSelectedFlowInstallsHostArchArtifact() async throws {
        // Arch-keyed pointer (02-01 emitter shape) carrying BOTH architectures
        // with distinct real shas: the whole wired flow must select and
        // install the HOST architecture's artifact (on this arm64
        // verification host, the .arm64 entry) and never the other one.
        let armApp = releaseDirectory.appendingPathComponent("ScanStudio.app", isDirectory: true)
        try makeApp("ScanStudio.app", at: releaseDirectory, release: "0.3.0-alpha.11", marker: "arch")
        let armArtifact = try makeReleaseArtifact(of: armApp)

        let intelApp = releaseDirectory.appendingPathComponent("ScanStudio-intel.app", isDirectory: true)
        try makeApp("ScanStudio-intel.app", at: releaseDirectory, release: "0.3.0-alpha.11", marker: "intel")
        let intelArtifact = try makeReleaseArtifact(of: intelApp, version: "0.3.0-alpha.11", arch: "x86_64")
        XCTAssertNotEqual(armArtifact.sha256, intelArtifact.sha256,
                          "the two arch entries must describe distinct artifacts")

        let pointerURL = releaseDirectory.appendingPathComponent("latest.json")
        let pointerData = Data("""
        {
            "version": "0.3.0-alpha.11",
            "architectures": {
                "arm64": { "url": "\(armArtifact.url.absoluteString)", "sha256": "\(armArtifact.sha256)" },
                "x86_64": { "url": "\(intelArtifact.url.absoluteString)", "sha256": "\(intelArtifact.sha256)" }
            }
        }
        """.utf8)
        try pointerData.write(to: pointerURL)

        let session = CannedURLSession()
        session.dataByURL[pointerURL] = pointerData
        session.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("[]".utf8)
        session.dataByURL[armArtifact.url] = armArtifact.payload
        session.dataByURL[intelArtifact.url] = intelArtifact.payload

        let checker = GitHubUpdateChecker(pointerURL: pointerURL, session: session)

        // The host architecture on this verification machine (arm64, no
        // Rosetta per CONTEXT); it must always be one of the feed archs.
        let host = HostArchitectureProvider.current()
        XCTAssertTrue(HostArchitecture.allCases.contains(host), "host arch must be a known feed arch")
        let hostArtifact = host == .arm64 ? armArtifact : intelArtifact

        // Explicit .arm64 selection resolves the arm64 entry.
        let armResolved = try await checker.latestCandidate(channel: .alpha, arch: .arm64)
        let armCandidate = try XCTUnwrap(armResolved)
        XCTAssertEqual(armCandidate.version, UpdateVersion(raw: "0.3.0-alpha.11"))
        XCTAssertEqual(armCandidate.downloadURL, armArtifact.url)
        XCTAssertEqual(armCandidate.sha256, armArtifact.sha256)

        // The default entry point (no explicit arch) delegates to the host
        // arch and lands on the same entry the host-arch request returns.
        let defaultResolved = try await checker.latestCandidate(channel: .alpha)
        let hostCandidate = try XCTUnwrap(defaultResolved)
        XCTAssertEqual(hostCandidate.downloadURL, hostArtifact.url)
        XCTAssertEqual(hostCandidate.sha256, hostArtifact.sha256)

        // Downloader verifies against the SELECTED arch's sha, then the
        // installer swaps the corresponding bundle in. On this arm64 host the
        // marker proves the arm64 artifact was the one installed.
        let downloader = UpdateDownloader(session: session)
        let downloadDir = root.appendingPathComponent("Downloads", isDirectory: true)
        let downloaded = try await downloader.download(hostCandidate, to: downloadDir)
        XCTAssertEqual(try Data(contentsOf: downloaded), hostArtifact.payload)

        let sourceApp = host == .arm64 ? armApp : intelApp
        let installer = try UpdateInstaller(
            appDirectory: installDirectory,
            rollbackDirectory: rollbackDirectory,
            bundleVerifier: makeBundleVerifier()
        )
        XCTAssertNil(installer.availableRollback)

        let archive = UpdateArchive(
            version: hostCandidate.version,
            sourceAppPath: sourceApp,
            checksumSHA256: hostCandidate.sha256
        )
        try installer.install(archive)

        XCTAssertEqual(
            try markerContents(installDirectory.appendingPathComponent("ScanStudio.app")),
            host == .arm64 ? "arch" : "intel",
            "install must consume the host-arch artifact"
        )
        XCTAssertNotNil(installer.availableRollback)
        XCTAssertEqual(installer.availableRollback?.version.raw, "0.3.0-alpha.10")

        let restored = try installer.restorePrevious()
        XCTAssertEqual(restored.lastPathComponent, "ScanStudio.app")
        XCTAssertEqual(try markerContents(installDirectory.appendingPathComponent("ScanStudio.app")), "old")
    }

    func testCrossArchChecksumMismatchIsRejected() async throws {
        // A tampered mirror (or malformed feed) must never install: the x86_64
        // entry promises the x86_64 artifact's real sha, but the mirror serves
        // the ARM64 bytes at that URL — the checksum gate rejects the
        // wrong-arch content before anything is mounted or swapped.
        let armApp = releaseDirectory.appendingPathComponent("ScanStudio.app", isDirectory: true)
        try makeApp("ScanStudio.app", at: releaseDirectory, release: "0.3.0-alpha.11", marker: "arch")
        let armArtifact = try makeReleaseArtifact(of: armApp)

        let intelApp = releaseDirectory.appendingPathComponent("ScanStudio-intel.app", isDirectory: true)
        try makeApp("ScanStudio-intel.app", at: releaseDirectory, release: "0.3.0-alpha.11", marker: "intel")
        let intelArtifact = try makeReleaseArtifact(of: intelApp, version: "0.3.0-alpha.11", arch: "x86_64")
        XCTAssertNotEqual(armArtifact.sha256, intelArtifact.sha256)

        let pointerURL = releaseDirectory.appendingPathComponent("latest.json")
        let pointerData = Data("""
        {
            "version": "0.3.0-alpha.11",
            "architectures": {
                "arm64": { "url": "\(armArtifact.url.absoluteString)", "sha256": "\(armArtifact.sha256)" },
                "x86_64": { "url": "\(intelArtifact.url.absoluteString)", "sha256": "\(intelArtifact.sha256)" }
            }
        }
        """.utf8)
        try pointerData.write(to: pointerURL)

        // Built-in cross-arch hazard: the intel URL answers with arm64 bytes.
        let session = CannedURLSession()
        session.dataByURL[pointerURL] = pointerData
        session.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("[]".utf8)
        session.dataByURL[intelArtifact.url] = armArtifact.payload

        let checker = GitHubUpdateChecker(pointerURL: pointerURL, session: session)
        let resolved = try await checker.latestCandidate(channel: .alpha, arch: .x86_64)
        let candidate = try XCTUnwrap(resolved)
        XCTAssertEqual(candidate.sha256, intelArtifact.sha256)

        let downloader = UpdateDownloader(session: session)
        let downloadDir = root.appendingPathComponent("Downloads", isDirectory: true)
        do {
            _ = try await downloader.download(candidate, to: downloadDir)
            XCTFail("expected checksumMismatch for cross-arch content")
        } catch let error as UpdateDownloadError {
            XCTAssertEqual(error, .checksumMismatch)
        }

        // Nothing may have been swapped, snapshotted, or left staged.
        XCTAssertEqual(try markerContents(installDirectory.appendingPathComponent("ScanStudio.app")), "old")
        let installer = try UpdateInstaller(appDirectory: installDirectory, rollbackDirectory: rollbackDirectory)
        XCTAssertNil(installer.availableRollback, "a rejected cross-arch download must not snapshot or swap")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: downloadDir.path)
        XCTAssertTrue(leftovers.isEmpty, "a rejected cross-arch download must not leave a staged artifact")
    }

    func testUnsupportedArchitectureTypedErrorInFlow() async throws {
        // A pointer with only the arm64 entry, requested for x86_64: the
        // surfaced outcome is the typed unsupported-architecture error through
        // the full checker flow (not a decode-only case), never a crash and
        // never a wrong-arch install.
        let armApp = releaseDirectory.appendingPathComponent("ScanStudio.app", isDirectory: true)
        try makeApp("ScanStudio.app", at: releaseDirectory, release: "0.3.0-alpha.11", marker: "arch")
        let armArtifact = try makeReleaseArtifact(of: armApp)

        let pointerURL = releaseDirectory.appendingPathComponent("latest.json")
        let pointerData = Data("""
        {
            "version": "0.3.0-alpha.11",
            "architectures": {
                "arm64": { "url": "\(armArtifact.url.absoluteString)", "sha256": "\(armArtifact.sha256)" }
            }
        }
        """.utf8)
        try pointerData.write(to: pointerURL)

        let session = CannedURLSession()
        session.dataByURL[pointerURL] = pointerData
        session.dataByURL[GitHubUpdateChecker.apiReleasesURL] = Data("[]".utf8)
        session.dataByURL[armArtifact.url] = armArtifact.payload

        let checker = GitHubUpdateChecker(pointerURL: pointerURL, session: session)
        do {
            _ = try await checker.latestCandidate(channel: .alpha, arch: .x86_64)
            XCTFail("expected UpdateArchError.unsupportedArchitecture(.x86_64)")
        } catch let error as UpdateArchError {
            XCTAssertEqual(error, .unsupportedArchitecture(.x86_64))
        }

        // No install may have happened: the old bundle is intact and no
        // snapshot exists.
        XCTAssertEqual(try markerContents(installDirectory.appendingPathComponent("ScanStudio.app")), "old")
        let installer = try UpdateInstaller(appDirectory: installDirectory, rollbackDirectory: rollbackDirectory)
        XCTAssertNil(installer.availableRollback, "unsupported arch must never reach the installer")
    }

    // MARK: - Fixture helpers

    private struct ReleaseArtifact {
        let payload: Data
        let sha256: String
        let url: URL
    }

    /// Bakes the app bundle into a release artifact (a zip) and returns its
    /// exact bytes with the real SHA-256 the feed must carry. Backed by an
    /// arm64-named artifact for the Phase-01 callers.
    private func makeReleaseArtifact(of app: URL) throws -> ReleaseArtifact {
        try makeReleaseArtifact(of: app, version: "0.3.0-alpha.11", arch: "arm64")
    }

    /// Bakes the app bundle into a release artifact (a zip) named for its
    /// `arch` (`-macOS-<arch>.zip`, mirroring the per-arch DMG suffix
    /// convention) and returns its exact bytes with the real SHA-256 the feed
    /// must carry.
    private func makeReleaseArtifact(of app: URL, version: String, arch: String) throws -> ReleaseArtifact {
        let zipURL = releaseDirectory
            .appendingPathComponent("ScanStudio-\(version)-macOS-\(arch).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "UpdateFlowIntegrationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ditto failed (status \(process.terminationStatus))"]
            )
        }
        let payload = try Data(contentsOf: zipURL)
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return ReleaseArtifact(payload: payload, sha256: sha, url: zipURL)
    }

    private func makeApp(_ name: String, at parent: URL, release: String, marker: String) throws {
        let appURL = parent.appendingPathComponent(name, isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": UpdatePublisherTrust.bundleIdentifier,
            "CFBundleExecutable": UpdatePublisherTrust.bundleExecutable,
            "CFBundleShortVersionString": release,
            "ScanStudioRelease": release,
            "LSMinimumSystemVersion": "14.0",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        let launcher = macos.appendingPathComponent(UpdatePublisherTrust.bundleExecutable)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let binary = macos.appendingPathComponent(UpdatePublisherTrust.architectureExecutable)
        try fakeMachO(for: HostArchitectureProvider.current()).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Data(marker.utf8).write(to: resources.appendingPathComponent("marker.txt"))
    }

    private func markerContents(_ appURL: URL) throws -> String {
        try String(contentsOf: appURL.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
    }

    private func makeBundleVerifier() -> UpdateBundleVerifier {
        UpdateBundleVerifier(
            publisherTrust: UpdatePublisherTrust(
                authorizedTeamIdentifier: "ABCDEFGHIJ",
                designatedRequirementData: Data([1])
            ),
            signatureValidator: AcceptingIntegrationSignatureValidator(),
            hostOperatingSystemVersion: OperatingSystemVersion(
                majorVersion: 99,
                minorVersion: 0,
                patchVersion: 0
            )
        )
    }

    private func fakeMachO(for architecture: HostArchitecture) -> Data {
        let cpu: [UInt8] = architecture == .arm64
            ? [0x0c, 0x00, 0x00, 0x01]
            : [0x07, 0x00, 0x00, 0x01]
        return Data([0xcf, 0xfa, 0xed, 0xfe] + cpu)
    }
}

private struct AcceptingIntegrationSignatureValidator: UpdateCodeSignatureValidating {
    func validateApplication(at appURL: URL, trust: UpdatePublisherTrust) throws {}
}

/// Canned in-memory URLSession stand-in for the offline flow: `data(from:)`
/// and `download(from:)` answer from a URL-keyed map. Mirrors the stub pattern
/// from 01-04's UpdateServiceTests without coupling to its file-private type.
private final class CannedURLSession: URLSessionProtocol, @unchecked Sendable {
    var dataByURL: [URL: Data] = [:]

    func data(from url: URL) async throws -> (Data, URLResponse) {
        guard let data = dataByURL[url] else {
            throw URLError(.fileDoesNotExist)
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func download(from url: URL, delegate: (any URLSessionTaskDelegate)?) async throws -> (URL, URLResponse) {
        guard let data = dataByURL[url] else {
            throw URLError(.fileDoesNotExist)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("CannedDownload-\(UUID().uuidString)")
        try data.write(to: temporary)
        return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
