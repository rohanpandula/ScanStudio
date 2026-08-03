// Update feed and verified download service (01-04). Resolves the newest
// release for a channel (the `latest.json` pointer, plus a GitHub API probe
// for the alpha channel), downloads the DMG, verifies its SHA-256 before any
// mount, then mounts and checks the code signature so a corrupted or
// tampered download can never reach the install core (01-03). All network is
// behind an injectable `URLSessionProtocol`, so the whole service is unit
// tested offline with canned payloads — CI never touches the network.

import CryptoKit
import Foundation

/// A resolved, still-unverified update candidate: exactly what the feed
/// promised. `sha256` is the trust anchor the downloader checks before mount.
public struct UpdateCandidate: Sendable, Equatable {
    public let version: UpdateVersion
    public let downloadURL: URL
    public let sha256: String
    public let releaseNotesURL: URL?

    public init(version: UpdateVersion, downloadURL: URL, sha256: String, releaseNotesURL: URL?) {
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.releaseNotesURL = releaseNotesURL
    }
}

/// The `latest.json` update pointer asset: `{"version","url","sha256"}`.
public struct UpdatePointer: Decodable, Equatable {
    public let version: String
    public let url: URL
    public let sha256: String

    public init(version: String, url: URL, sha256: String) {
        self.version = version
        self.url = url
        self.sha256 = sha256
    }
}

/// The release channel a user is on. `stable` only trusts the pointer;
/// `alpha` also probes the GitHub API for freshly published pre-releases.
public enum UpdateChannel: String, CaseIterable, Sendable {
    case stable = "stable"
    case alpha = "alpha"
}

/// The minimal `URLSession` surface the update service needs. The repo had
/// no prior `URLSessionProtocol` (the engine client speaks over pipes, not
/// HTTP), so this is defined here and shared by the checker and downloader so
/// that tests can stub it with canned payloads and stay fully offline.
public protocol URLSessionProtocol: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
    func download(from url: URL, delegate: (any URLSessionTaskDelegate)?) async throws -> (URL, URLResponse)
}

extension URLSession: URLSessionProtocol {}

/// Feed resolver: latest.json pointer for stable, pointer + a best-effort
/// GitHub API probe for alpha.
public protocol UpdateChecking: Sendable {
    func latestCandidate(channel: UpdateChannel) async throws -> UpdateCandidate?
}

public final class GitHubUpdateChecker: UpdateChecking {
    /// GitHub releases list the alpha channel probes. `per_page=5` keeps the
    /// unauthenticated rate-limit headroom (60 req/hr/IP) comfortable for a
    /// once-per-launch check.
    public static let apiReleasesURL: URL =
        URL(string: "https://api.github.com/repos/rohanpandula/ScanStudio/releases?per_page=5")!

    private let pointerURL: URL
    private let session: any URLSessionProtocol

    public init(pointerURL: URL, session: any URLSessionProtocol = URLSession.shared) {
        self.pointerURL = pointerURL
        self.session = session
    }

    public func latestCandidate(channel: UpdateChannel) async throws -> UpdateCandidate? {
        switch channel {
        case .stable:
            return try await fetchPointerCandidate()
        case .alpha:
            guard let pointer = try await fetchPointerCandidate() else { return nil }
            return await newestPreRelease(over: pointer) ?? pointer
        }
    }

    // MARK: - Pointer

    /// Fetches and decodes `latest.json`. Transport or decode trouble is
    /// thrown so the caller can distinguish "couldn't reach the update
    /// server" from "no update available". Returns `nil` only when the
    /// pointer's version string does not parse — treated as no update.
    private func fetchPointerCandidate() async throws -> UpdateCandidate? {
        let (data, _) = try await session.data(from: pointerURL)
        let pointer = try JSONDecoder().decode(UpdatePointer.self, from: data)
        guard let version = UpdateVersion(raw: pointer.version) else { return nil }
        return UpdateCandidate(
            version: version,
            downloadURL: pointer.url,
            sha256: pointer.sha256,
            releaseNotesURL: nil
        )
    }

    // MARK: - Alpha API probe

    /// Best-effort: the newest pre-release from the GitHub API that is at
    /// least as new as `pointer`. Any API failure (transport, decode, no
    /// match) degrades gracefully to nil → the caller keeps the pointer
    /// candidate. The API payload decodes only `tag_name`/`prerelease`/
    /// `html_url` (the source of truth for artifact bytes stays the pointer),
    /// so a found candidate's download URL is derived from the deterministic
    /// asset naming and its `sha256` falls back to the pointer's. If that
    /// derivation does not match the real artifact, the downloader's
    /// checksum gate rejects the download before anything is mounted or
    /// installed — a safe failure, never a silent wrong install.
    private func newestPreRelease(over pointer: UpdateCandidate) async -> UpdateCandidate? {
        guard let (data, _) = try? await session.data(from: Self.apiReleasesURL),
              let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            return nil
        }
        var candidates: [UpdateCandidate] = []
        candidates.reserveCapacity(releases.count)
        for release in releases where release.prerelease {
            // Normalize the tag so the candidate's raw version matches the
            // pointer's spelling (no leading `v`); the tag itself is still
            // used verbatim for the release download-URL path.
            let tag = release.tag_name
            let versionString = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard let version = UpdateVersion(raw: versionString) else { continue }
            candidates.append(UpdateCandidate(
                version: version,
                downloadURL: Self.releaseDownloadURL(tag: tag, version: version),
                sha256: pointer.sha256,
                releaseNotesURL: URL(string: release.html_url)
            ))
        }
        guard let newest = Self.newest(candidates), newest.version >= pointer.version else {
            return nil
        }
        return newest
    }

    /// Deterministic DMG asset path on GitHub Releases for a tag, matching the
    /// pipeline's `ScanStudio-<ver>-macOS-arm64.dmg` naming (leading `v` in
    /// the tag is not part of the asset name).
    private static func releaseDownloadURL(tag: String, version: UpdateVersion) -> URL {
        let stem = version.raw.hasPrefix("v") ? String(version.raw.dropFirst()) : version.raw
        return URL(
            string: "https://github.com/rohanpandula/ScanStudio/releases/download/\(tag)/ScanStudio-\(stem)-macOS-arm64.dmg"
        )!
    }

    /// Newest candidate under `UpdateVersion` ordering (`<`); nil when empty.
    static func newest(_ candidates: [UpdateCandidate]) -> UpdateCandidate? {
        guard var best = candidates.first else { return nil }
        for candidate in candidates.dropFirst() where best.version < candidate.version {
            best = candidate
        }
        return best
    }

    /// The subset of a GitHub release object the alpha probe decodes.
    private struct GitHubRelease: Decodable {
        let tag_name: String
        let prerelease: Bool
        let html_url: String
    }
}

/// Typed download/verify failures. Every case is a distinct, user-visible
/// outcome; "no update available" is the checker returning nil, not an error.
public enum UpdateDownloadError: Error, Equatable {
    /// The candidate itself is unusable (bad URL or malformed sha256).
    case badCandidate
    /// Transport or staging failure while fetching the DMG.
    case downloadFailed
    /// Downloaded bytes do not match the promised SHA-256 (tampered/corrupt).
    case checksumMismatch
    /// The DMG could not be attached (or its mount point could not be read).
    case mountFailed
    /// The mounted bundle failed `codesign --verify --deep --strict`.
    case signatureInvalid
    /// The feed described an archive format this downloader cannot handle.
    case invalidArchive
    /// The mounted volume held no usable `.app` bundle.
    case notAnApp
}

/// Downloads and cryptographically verifies a candidate into a mounted,
/// signature-checked app bundle that the install core can consume. The three
/// sanctioned `Process` uses (hdiutil attach/detach, codesign verify) are
/// isolated behind tiny private helpers so they are auditable.
public final class UpdateDownloader {
    private let session: any URLSessionProtocol

    public init(session: any URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    // MARK: - Download + SHA-256

    /// Downloads the candidate DMG into `directory` as
    /// `ScanStudio-<version>.dmg`, verifying the promised SHA-256 before
    /// returning. A mismatch deletes the download and throws
    /// `.checksumMismatch` — nothing is ever mounted on a bad checksum.
    public func download(_ candidate: UpdateCandidate, to directory: URL) async throws -> URL {
        guard isValidCandidate(candidate) else {
            throw UpdateDownloadError.badCandidate
        }
        let destination = directory.appendingPathComponent("ScanStudio-\(candidate.version.raw).dmg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (temporaryURL, _) = try await session.download(from: candidate.downloadURL, delegate: nil)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw UpdateDownloadError.downloadFailed
        }
        let actual = Self.sha256(ofFileAt: destination)
        guard actual == candidate.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateDownloadError.checksumMismatch
        }
        return destination
    }

    // MARK: - Mount + locate app

    /// Attaches the DMG read-only (`hdiutil attach -nobrowse -readonly
    /// -plist`), locates the single `.app` bundle at the mount root
    /// (preferring case-insensitive `ScanStudio.app`, else any single
    /// `.app`), and returns the mounted app's URL. A volume with no usable
    /// `.app` is detached again and reported as `.notAnApp`.
    public func mountAndLocateApp(_ dmgURL: URL) throws -> URL {
        let result: (status: Int32, output: String)
        do {
            result = try Self.launch("/usr/bin/hdiutil", arguments: [
                "attach", "-nobrowse", "-readonly", "-plist", dmgURL.path,
            ])
        } catch {
            throw UpdateDownloadError.mountFailed
        }
        guard result.status == 0 else { throw UpdateDownloadError.mountFailed }
        guard let mountRoot = Self.mountPoint(from: result.output) else {
            throw UpdateDownloadError.mountFailed
        }

        let apps = Self.appBundles(in: mountRoot)
        let scanStudio = apps.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == "scanstudio" }
        var located: URL?
        if scanStudio.count == 1 {
            located = scanStudio.first
        } else if apps.count == 1 {
            located = apps.first
        }
        guard let located else {
            try? tearDownMount(mountRoot)
            throw UpdateDownloadError.notAnApp
        }
        return located
    }

    // MARK: - Code-signature verification

    /// Verifies the mounted bundle with `codesign --verify --deep --strict`
    /// (`/usr/bin/codesign` on macOS 14+). Any non-zero exit is
    /// `.signatureInvalid` — no archive is produced from an unsigned or
    /// unverifiable bundle.
    public func verifyCodeSignature(at appURL: URL) throws {
        let result: (status: Int32, output: String)
        do {
            result = try Self.launch("/usr/bin/codesign", arguments: [
                "--verify", "--deep", "--strict", appURL.path,
            ])
        } catch {
            throw UpdateDownloadError.signatureInvalid
        }
        guard result.status == 0 else { throw UpdateDownloadError.signatureInvalid }
    }

    // MARK: - Mount teardown (internal for tests)

    /// Detaches a mounted volume previously produced by `mountAndLocateApp`.
    /// Best-effort; failures are ignored. Internal (not private) so the
    /// offline tests can clean up after themselves.
    func tearDownMount(_ mountURL: URL) {
        _ = try? Self.launch("/usr/bin/hdiutil", arguments: ["detach", mountURL.path])
    }

    // MARK: - Primitives

    private func isValidCandidate(_ candidate: UpdateCandidate) -> Bool {
        candidate.downloadURL.scheme != nil
            && !candidate.downloadURL.absoluteString.isEmpty
            && Self.isValidHexSHA256(candidate.sha256)
    }

    private static func isValidHexSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    /// Streams the file through CryptoKit's SHA-256 so arbitrarily large
    /// DMGs are hashed in bounded memory (macOS 14 target → CryptoKit is
    /// always available; no shelling out to `/usr/bin/shasum`).
    private static func sha256(ofFileAt url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs an external command and returns its exit status and combined
    /// stdout/stderr. Introduced only for the sanctioned subprocess uses
    /// (hdiutil attach/detach, codesign verify).
    private static func launch(_ executablePath: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Extracts the first `mount-point` from `hdiutil attach -plist` output.
    private static func mountPoint(from plistOutput: String) -> URL? {
        guard let data = plistOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else {
            return nil
        }
        for entity in entities {
            if let mountPath = entity["mount-point"] as? String {
                return URL(fileURLWithPath: mountPath, isDirectory: true)
            }
        }
        return nil
    }

    /// Direct `.app` subdirectories (case-insensitive extension) at `directory`.
    private static func appBundles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return contents.filter { url in
            url.pathExtension.lowercased() == "app"
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
