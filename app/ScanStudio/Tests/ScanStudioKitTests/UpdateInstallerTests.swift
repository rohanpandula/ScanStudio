// UpdateInstaller snapshot/swap/rollback tests (AUT-04-SNAP, AUT-04-SWAP,
// AUT-04-ROLLBACK, AUT-04-NOMOTION). Pure filesystem: a throwaway fake
// `.app` tree in a temp dir, zero hardware, zero network, zero subprocess.

import XCTest

@testable import ScanStudioKit

final class UpdateInstallerTests: XCTestCase {
    private var root: URL!
    private var applicationsDirectory: URL!
    private var rollbackDirectory: URL!
    private var sourceDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        applicationsDirectory = root.appendingPathComponent("Applications", isDirectory: true)
        rollbackDirectory = root.appendingPathComponent("Rollback", isDirectory: true)
        sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        try makeFakeApp("ScanStudio.app", at: applicationsDirectory, release: "0.3.0-alpha.10", marker: "old")
        try makeFakeApp("ScanStudio.app", at: sourceDirectory, release: "0.3.0-alpha.11", marker: "new")
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testInstallSwapsApp() throws {
        let installer = try makeInstaller()
        let archive = makeArchive(appName: "ScanStudio.app", in: sourceDirectory, version: "0.3.0-alpha.11")

        try installer.install(archive)

        let marker = try markerContents(at: applicationsDirectory.appendingPathComponent("ScanStudio.app"))
        XCTAssertEqual(marker, "new", "Install must swap the marker contents, not just create files")
        XCTAssertNotNil(installer.availableRollback, "Install must first snapshot so rollback is available")
        XCTAssertEqual(installer.availableRollback?.version.raw, "0.3.0-alpha.10")
    }

    func testSnapshotCreatesRollbackEntry() throws {
        let installer = try makeInstaller()

        try installer.snapshotCurrent()

        let snapshotURL = rollbackDirectory.appendingPathComponent("ScanStudio-0.3.0-alpha.10.app", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path), "Snapshot must be written to the rollback directory")
        XCTAssertEqual(try markerContents(at: snapshotURL), "old", "Snapshot must be a faithful copy of the current app")
    }

    func testRestorePreviousReturnsOldApp() throws {
        let installer = try makeInstaller()
        try installer.install(makeArchive(appName: "ScanStudio.app", in: sourceDirectory, version: "0.3.0-alpha.11"))
        XCTAssertEqual(try markerContents(at: applicationsDirectory.appendingPathComponent("ScanStudio.app")), "new")

        let restored = try installer.restorePrevious()

        XCTAssertEqual(restored.lastPathComponent, "ScanStudio.app")
        XCTAssertEqual(try markerContents(at: applicationsDirectory.appendingPathComponent("ScanStudio.app")), "old", "Restore must put the snapshot marker back")
    }

    func testInstallMissingSourceThrows() throws {
        let installer = try makeInstaller()
        let missing = sourceDirectory.appendingPathComponent("DoesNotExist.app", isDirectory: true)
        let archive = UpdateArchive(
            version: UpdateVersion(raw: "0.3.0-alpha.11")!,
            sourceAppPath: missing,
            checksumSHA256: "abc"
        )

        XCTAssertThrowsError(try installer.install(archive)) { error in
            XCTAssertEqual(error as? UpdateInstallError, .sourceMissing)
        }
    }

    func testInstallEmptyChecksumThrows() throws {
        let installer = try makeInstaller()
        let archive = UpdateArchive(
            version: UpdateVersion(raw: "0.3.0-alpha.11")!,
            sourceAppPath: sourceDirectory.appendingPathComponent("ScanStudio.app", isDirectory: true),
            checksumSHA256: ""
        )

        XCTAssertThrowsError(try installer.install(archive)) { error in
            XCTAssertEqual(error as? UpdateInstallError, .notVerified)
        }
    }

    func testSnapshotMissingAppNoop() throws {
        let emptyDirectory = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        let installer = try UpdateInstaller(appDirectory: emptyDirectory, rollbackDirectory: rollbackDirectory)

        XCTAssertNoThrow(try installer.snapshotCurrent(), "Snapshotting a directory with no app must not throw")
        XCTAssertNil(installer.availableRollback)
    }

    func testRollbackNothingAvailableThrows() throws {
        let installer = try makeInstaller()

        XCTAssertThrowsError(try installer.restorePrevious()) { error in
            XCTAssertEqual(error as? UpdateInstallError, .rolledBack)
        }
    }

    // MARK: - Fixture helpers

    private func makeInstaller() throws -> UpdateInstaller {
        try UpdateInstaller(appDirectory: applicationsDirectory, rollbackDirectory: rollbackDirectory)
    }

    private func makeArchive(appName: String, in directory: URL, version: String) -> UpdateArchive {
        UpdateArchive(
            version: UpdateVersion(raw: version)!,
            sourceAppPath: directory.appendingPathComponent(appName, isDirectory: true),
            checksumSHA256: "abc"
        )
    }

    private func makeFakeApp(
        _ name: String,
        at parent: URL,
        release: String,
        marker: String
    ) throws {
        let appURL = parent.appendingPathComponent(name, isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleShortVersionString": release,
            "ScanStudioRelease": release
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        try marker.data(using: .utf8)!
            .write(to: macos.appendingPathComponent("ScanStudio"))
    }

    private func markerContents(at appURL: URL) throws -> String {
        let markerURL = sourceMarkerURL(at: appURL)
        return try String(contentsOf: markerURL, encoding: .utf8)
    }

    private func sourceMarkerURL(at appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/MacOS/ScanStudio")
    }
}
