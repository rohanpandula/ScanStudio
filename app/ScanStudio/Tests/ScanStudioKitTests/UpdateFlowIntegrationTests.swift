// End-to-end updater flow test (01-06): drives the whole wired pipeline in
// one place — update pointer (file URL) -> GitHubUpdateChecker ->
// UpdateDownloader (SHA-256 verified) -> UpdateInstaller (snapshot / swap /
// rollback), plus the corrupt-checksum rejection path. Everything runs against
// seeded fake app bundles in temp directories: a canned URLSessionProtocol
// answers from injectable local fixtures, so there is zero network, zero
// /Applications mutation, and zero scanner interaction. The hdiutil mount leg
// is bypassed for directory fixtures by design (the mount path is exercised
// independently where a real DMG exists — see UpdateServiceTests).

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
        //    mountAndLocateApp is bypassed for directory fixtures by design
        //    (see header); the archive is pointed at the release bundle that
        //    corresponds to the artifact we just verified and downloaded.
        let installer = try UpdateInstaller(appDirectory: installDirectory, rollbackDirectory: rollbackDirectory)
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
        let installer = try UpdateInstaller(appDirectory: installDirectory, rollbackDirectory: rollbackDirectory)
        XCTAssertNil(installer.availableRollback)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: downloadDir.path)
        XCTAssertTrue(leftovers.isEmpty, "a rejected download must not leave a staged artifact")
    }

    // MARK: - Fixture helpers

    private struct ReleaseArtifact {
        let payload: Data
        let sha256: String
        let url: URL
    }

    /// Bakes the app bundle into a release artifact (a zip) and returns its
    /// exact bytes with the real SHA-256 the feed must carry.
    private func makeReleaseArtifact(of app: URL) throws -> ReleaseArtifact {
        let zipURL = releaseDirectory
            .appendingPathComponent("ScanStudio-0.3.0-alpha.11-macOS-arm64.zip")
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
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleShortVersionString": release,
            "ScanStudioRelease": release,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: macos.appendingPathComponent("ScanStudio"))
    }

    private func markerContents(_ appURL: URL) throws -> String {
        try String(contentsOf: appURL.appendingPathComponent("Contents/MacOS/ScanStudio"), encoding: .utf8)
    }
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
