// Update feed and verified download service (01-04). Resolves the newest
// release for a channel (the `latest.json` pointer, plus a GitHub API probe
// for the prerelease channel), downloads the DMG, verifies its SHA-256 before any
// mount, then mounts and checks the code signature so a corrupted or
// tampered download can never reach the install core (01-03). All network is
// behind an injectable `URLSessionProtocol`, so the whole service is unit
// tested offline with canned payloads — CI never touches the network.

import CryptoKit
import Darwin
import Foundation
import Security

/// The `hw.machine` string, e.g. `arm64` on Apple Silicon, `x86_64` (or
/// `x86_64h`) on Intel. Read via a direct `sysctlbyname` syscall — no
/// subprocess, no `Process` — so the host-arch resolver stays pure and
/// deterministic. `ProcessInfo` does not expose this value directly on
/// current SDKs, hence this tiny extension.
extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else {
            return ""
        }
        let bytes = machine.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

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

/// Host CPU architecture for update feed selection. Pure, no subprocess.
///
/// Mirrors the per-arch DMG suffixes Phase 02 publishes (`-macOS-arm64.dmg`,
/// `-macOS-x86_64.dmg`): the updater must fetch the artifact for the running
/// machine's architecture and never the other one.
public enum HostArchitecture: String, Sendable, CaseIterable {
    case arm64 = "arm64"
    case x86_64 = "x86_64"
}

/// Resolves the host CPU architecture for feed selection. Pure, no subprocess.
///
/// `current()` reads `ProcessInfo.processInfo.machineHardwareName` only —
/// it never launches a process (no `/usr/bin/uname`), so it is deterministic
/// and unit-testable on any host.
public enum HostArchitectureProvider {
    /// Maps `machineHardwareName` to a feed architecture.
    ///
    /// Apple Silicon reports exactly `"arm64"`; Intel reports `"x86_64"` (or
    /// `"x86_64h"`). Prefix mapping tolerates the fine-grained spellings
    /// (`arm64e` → `.arm64`, `x86_64h` → `.x86_64`). Any name matching
    /// neither family is unexpected — real Macs always report one of these —
    /// and falls back to `.arm64`, the historically primary shipped arch;
    /// a pointer missing the arm64 entry then surfaces the typed
    /// unsupported-architecture error rather than silently trusting x86_64.
    public static func current() -> HostArchitecture {
        let name = ProcessInfo.processInfo.machineHardwareName
        if name.hasPrefix(HostArchitecture.arm64.rawValue) {
            return .arm64
        }
        if name.hasPrefix(HostArchitecture.x86_64.rawValue) {
            return .x86_64
        }
        // TODO(02-02): revisit if a third shipping Mac arch ever appears.
        return .arm64
    }

    /// Convenience for the UI: the current host architecture.
    public static var currentHostArchitecture: HostArchitecture { current() }
}

/// The release channel a user is on. `stable` only trusts the pointer;
/// `alpha` is the persisted raw value for the prerelease channel and also
/// probes the GitHub API for freshly published alpha, beta, or RC releases.
public enum UpdateChannel: String, CaseIterable, Sendable {
    case stable = "stable"
    case alpha = "alpha"
}

/// The per-arch download payload inside an arch-keyed pointer: the DMG URL
/// and its promised SHA-256 trust anchor for a single host architecture.
public struct UpdateArchEntry: Codable, Equatable {
    public let url: URL
    public let sha256: String

    public init(url: URL, sha256: String) {
        self.url = url
        self.sha256 = sha256
    }
}

/// The Phase-02 arch-keyed `latest.json` update pointer asset.
///
/// Decodes BOTH the arch-keyed form
/// `{"version":…,"architectures":{"arm64":{"url":…,"sha256":…},"x86_64":{…}}}`
/// AND the legacy flat form `{"version","url","sha256"}`. The flat form is
/// represented as a dictionary with a single entry under the current host
/// architecture, so downstream selection always consumes one shape.
/// Encoding always emits the arch-keyed form (a JSON object keyed by raw
/// architecture string).
public struct UpdatePointerArch: Codable, Equatable {
    public let version: String
    public let architectures: [HostArchitecture: UpdateArchEntry]

    public init(version: String, architectures: [HostArchitecture: UpdateArchEntry]) {
        self.version = version
        self.architectures = architectures
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case architectures
        case url
        case sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .version)
        // Wire form is a JSON object keyed by raw arch string; map to the
        // known enum. An unrecognized key is a malformed/untrusted pointer
        // (trust gate) → throw rather than silently dropping an entry.
        if let wire = try container.decodeIfPresent([String: UpdateArchEntry].self, forKey: .architectures) {
            var architectures: [HostArchitecture: UpdateArchEntry] = [:]
            architectures.reserveCapacity(wire.count)
            for (key, entry) in wire {
                guard let arch = HostArchitecture(rawValue: key) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .architectures,
                        in: container,
                        debugDescription: "Unknown architecture key in update pointer: \(key)"
                    )
                }
                architectures[arch] = entry
            }
            self.init(version: version, architectures: architectures)
        } else if let url = try container.decodeIfPresent(URL.self, forKey: .url),
                  let sha256 = try container.decodeIfPresent(String.self, forKey: .sha256) {
            // Legacy flat pointer: one representative entry under the current
            // host arch, so the rest of the pipeline sees an arch map.
            self.init(
                version: version,
                architectures: [HostArchitectureProvider.current(): UpdateArchEntry(url: url, sha256: sha256)]
            )
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Update pointer is neither arch-keyed nor legacy flat {version,url,sha256}"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        var wire: [String: UpdateArchEntry] = [:]
        wire.reserveCapacity(architectures.count)
        for (arch, entry) in architectures {
            wire[arch.rawValue] = entry
        }
        try container.encode(wire, forKey: .architectures)
    }
}

/// Typed feed errors the checker surfaces. The trust gate: a malformed or
/// incomplete pointer is reported to the caller, never silently skipped.
public enum UpdateArchError: Error, Equatable {
    /// The feed published no entry for the requested host architecture, so a
    /// correct install is impossible — never fall back to another arch.
    case unsupportedArchitecture(HostArchitecture)
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
/// GitHub API probe for prereleases.
public protocol UpdateChecking: Sendable {
    func latestCandidate(channel: UpdateChannel) async throws -> UpdateCandidate?
}

public final class GitHubUpdateChecker: UpdateChecking {
    /// GitHub releases list the prerelease channel probes. `per_page=5` keeps the
    /// unauthenticated rate-limit headroom (60 req/hr/IP) comfortable for a
    /// once-per-launch check.
    public static let apiReleasesURL: URL =
        URL(string: "https://api.github.com/repos/rohanpandula/ScanStudio/releases?per_page=5")!

    /// The deterministic per-release pointer asset for `tag`. The 01-01
    /// release pipeline emits a `latest.json` (`{"version","url","sha256"}`)
    /// into every release, so the prerelease path can fetch the newest release's
    /// OWN pointer instead of borrowing the configured (stable) pointer's
    /// checksum. Mirrors `apiReleasesURL` as an exposed constant surface for
    /// tests; the tag is a parameter because it varies per release.
    public static func releasePointerURL(tag: String) -> URL {
        URL(string: "https://github.com/rohanpandula/ScanStudio/releases/download/\(tag)/latest.json")!
    }

    private let pointerURL: URL
    private let session: any URLSessionProtocol

    public init(pointerURL: URL, session: any URLSessionProtocol = URLSession.shared) {
        self.pointerURL = pointerURL
        self.session = session
    }

    public func latestCandidate(channel: UpdateChannel) async throws -> UpdateCandidate? {
        try await latestCandidate(channel: channel, arch: HostArchitectureProvider.current())
    }

    /// Resolves the newest candidate for `channel` for a specific host
    /// architecture, so an Intel Mac fetches the x86_64 DMG and Apple Silicon
    /// the arm64 DMG. An architecture with no published entry throws our typed
    /// `UpdateArchError.unsupportedArchitecture` — never a wrong-arch install.
    public func latestCandidate(channel: UpdateChannel, arch: HostArchitecture) async throws -> UpdateCandidate? {
        switch channel {
        case .stable:
            return try await fetchPointerCandidate(arch: arch)
        case .alpha:
            do {
                let pointer = try await fetchPointerCandidate(arch: arch)
                return try await newestPreRelease(over: pointer, arch: arch) ?? pointer
            } catch {
                // A prerelease-only repository has no GitHub "latest" release,
                // so releases/latest/download/latest.json returns 404. Probe
                // prereleases anyway and use the chosen release's own pointer.
                // If that bootstrap probe also fails, preserve the original
                // feed error rather than disguising it as "no update."
                if let prerelease = try await newestPreRelease(over: nil, arch: arch) {
                    return prerelease
                }
                throw error
            }
        }
    }

    // MARK: - Pointer

    /// Fetches and decodes `latest.json` for `arch`. Transport or decode
    /// trouble is thrown so the caller can distinguish "couldn't reach the
    /// update server" from "no update available". Returns `nil` only when the
    /// pointer's version string does not parse — treated as no update. A
    /// missing entry for `arch` throws `UpdateArchError.unsupportedArchitecture`.
    private func fetchPointerCandidate(arch: HostArchitecture) async throws -> UpdateCandidate? {
        let (data, _) = try await session.data(from: pointerURL)
        let pointer = try JSONDecoder().decode(UpdatePointerArch.self, from: data)
        let entry = try archEntry(for: arch, in: pointer)
        guard let version = UpdateVersion(raw: pointer.version) else { return nil }
        return UpdateCandidate(
            version: version,
            downloadURL: entry.url,
            sha256: entry.sha256,
            releaseNotesURL: nil
        )
    }

    /// Resolves the requested arch's entry, throwing a typed error when the
    /// pointer has none. This is the trust gate against a wrong-arch install:
    /// a missing entry is a real unsupported-host signal, never a silent
    /// fallthrough to the other architecture.
    private func archEntry(for arch: HostArchitecture, in pointer: UpdatePointerArch) throws -> UpdateArchEntry {
        guard let entry = pointer.architectures[arch] else {
            throw UpdateArchError.unsupportedArchitecture(arch)
        }
        return entry
    }

    // MARK: - Prerelease API probe

    /// Best-effort: the newest pre-release from the GitHub API that is at
    /// least as new as `pointer` when a stable pointer exists, for the
    /// requested host arch. With no stable release yet, `pointer` is nil and
    /// the newest valid prerelease bootstraps the channel. The API probe
    /// only answers *which* tag is newest; the candidate's bytes + sha256 come
    /// from that release's OWN per-release `latest.json` (authoritative
    /// artifact metadata), never borrowed from the configured stable pointer.
    /// Transport/decode trouble, a missing or corrupt per-release pointer, or
    /// a version mismatch between the tag and its pointer degrades silently to
    /// nil, so the caller keeps the configured pointer candidate (fail-closed:
    /// never a wrong install, never a self-inconsistent url+sha256 pairing).
    /// A per-release pointer with no entry for `arch` is NOT a transient
    /// network issue — it throws `UpdateArchError.unsupportedArchitecture`.
    private func newestPreRelease(over pointer: UpdateCandidate?, arch: HostArchitecture) async throws -> UpdateCandidate? {
        guard let (data, _) = try? await session.data(from: Self.apiReleasesURL),
              let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            return nil
        }
        // Locate the newest prerelease tag that is at least as new as the
        // pointer (as today). Normalize the tag so versions compare
        // semantically (no leading `v`); the tag stays verbatim for the URL.
        var newest: (tag: String, version: UpdateVersion, notesURL: URL?)?
        for release in releases where release.prerelease {
            let tag = release.tag_name
            let versionString = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard let version = UpdateVersion(raw: versionString) else {
                continue
            }
            if let pointer, version < pointer.version { continue }
            if newest == nil || newest!.version < version {
                newest = (tag, version, URL(string: release.html_url))
            }
        }
        guard let newest else { return nil }

        // Authoritative bytes + checksum come from the newest release's own
        // per-release pointer. Equality-of-intent: the pointer's version must
        // match the tag we probed, or we silently fall back to the configured
        // pointer rather than install mismatched bytes.
        guard let releasePointer = await fetchReleasePointer(tag: newest.tag),
              let releaseVersion = UpdateVersion(raw: releasePointer.version),
              releaseVersion == newest.version else {
            return nil
        }
        let entry = try archEntry(for: arch, in: releasePointer)
        return UpdateCandidate(
            version: newest.version,
            downloadURL: entry.url,
            sha256: entry.sha256,
            releaseNotesURL: newest.notesURL
        )
    }

    /// Fetches and decodes the per-release arch-aware `latest.json` pointer
    /// for `tag`. Returns nil (never throws) on any transport or decode
    /// failure so the prerelease path can fall back silently to the configured
    /// pointer. Version validation against the tag happens in the caller.
    private func fetchReleasePointer(tag: String) async -> UpdatePointerArch? {
        let url = Self.releasePointerURL(tag: tag)
        guard let (data, _) = try? await session.data(from: url),
              let pointer = try? JSONDecoder().decode(UpdatePointerArch.self, from: data) else {
            return nil
        }
        return pointer
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
    /// Reading the staged DMG failed. The associated path makes this
    /// distinguishable from a complete-file checksum mismatch in diagnostics.
    case checksumReadFailed(path: String, cause: String)
    /// The DMG could not be attached (or its mount point could not be read).
    case mountFailed
    /// Both normal and forced bounded detach failed.
    case detachFailed
    /// The installed app carries no usable, signed publisher trust root.
    case publisherTrustNotConfigured
    /// Security.framework rejected the mounted bundle's signature structure.
    case signatureInvalid
    /// The bundle was validly signed, but not by the pinned publisher or
    /// designated requirement.
    case publisherUnauthorized
    /// A Developer ID signature without a secure timestamp and stapled
    /// notarization ticket is not an authorized update.
    case notarizationMissing
    /// A required bundle metadata value or executable identity did not match.
    case bundleIdentityMismatch
    /// `ScanStudioRelease` did not equal the selected feed version.
    case versionMismatch
    /// The shipped ScanStudio Mach-O did not match the selected host arch.
    case architectureMismatch
    /// The bundle's minimum-macOS declaration is absent, malformed, outside
    /// the supported floor, or newer than the running host.
    case operatingSystemUnsupported
    /// A required bundle file could not be read. Carries the failing path.
    case bundleReadFailed(String)
    /// The feed described an archive format this downloader cannot handle.
    case invalidArchive
    /// The mounted volume held no usable `.app` bundle.
    case notAnApp
}

/// Publisher identity rooted in the already-installed application rather than
/// in the release server. Production construction is deliberately gated on an
/// explicit `ScanStudioUpdateTeamIdentifier` Info.plist stamp that must match
/// the running app's valid Developer ID signature. Its exact designated
/// requirement is persisted in Security.framework's stable binary form.
///
/// Ad-hoc/unsigned builds, unstamped builds, and builds without a secure
/// timestamp plus stapled notarization ticket produce `nil`, leaving update
/// installation fail-closed until the real Apple identity is available.
public struct UpdatePublisherTrust: Sendable, Equatable {
    public static let teamIdentifierInfoKey = "ScanStudioUpdateTeamIdentifier"
    public static let bundleIdentifier = "dev.scanstudio.live"
    public static let bundleExecutable = "ScanStudioLauncher"
    public static let architectureExecutable = "ScanStudio"

    public let authorizedTeamIdentifier: String
    public let designatedRequirementData: Data

    init?(authorizedTeamIdentifier: String, designatedRequirementData: Data) {
        guard Self.isValidTeamIdentifier(authorizedTeamIdentifier),
              !designatedRequirementData.isEmpty else {
            return nil
        }
        self.authorizedTeamIdentifier = authorizedTeamIdentifier
        self.designatedRequirementData = designatedRequirementData
    }

    /// Builds the production trust root from the running, locally installed
    /// app. The Team ID stamp is part of the signed Info.plist; Security.framework
    /// must independently report the same Team ID and exact designated
    /// requirement before this returns a policy.
    public static func currentApplication(bundle: Bundle = .main) -> UpdatePublisherTrust? {
        guard bundle.bundleIdentifier == bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == bundleExecutable,
              let stampedTeam = bundle.object(forInfoDictionaryKey: teamIdentifierInfoKey) as? String,
              isValidTeamIdentifier(stampedTeam) else {
            return nil
        }
        return try? SystemUpdateCodeSignatureValidator().publisherTrust(
            at: bundle.bundleURL,
            stampedTeamIdentifier: stampedTeam
        )
    }

    fileprivate static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.utf8.allSatisfy {
            ($0 >= Character("A").asciiValue! && $0 <= Character("Z").asciiValue!)
                || ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
        }
    }
}

protocol UpdateCodeSignatureValidating: Sendable {
    func validateApplication(at appURL: URL, trust: UpdatePublisherTrust) throws
}

/// Security.framework implementation of the independent publisher gate. It
/// validates the complete bundle, nested code, all architectures, exact
/// designated requirement bytes, Apple Developer ID certificate OIDs, Team ID,
/// secure timestamp, stapled ticket, and a bounded Gatekeeper assessment.
private struct SystemUpdateCodeSignatureValidator: UpdateCodeSignatureValidating {
    func publisherTrust(at appURL: URL, stampedTeamIdentifier: String) throws -> UpdatePublisherTrust {
        guard UpdatePublisherTrust.isValidTeamIdentifier(stampedTeamIdentifier) else {
            throw UpdateDownloadError.publisherTrustNotConfigured
        }
        let code = try staticCode(at: appURL)
        try validateStructure(of: code, requirement: nil)
        let information = try signingInformation(for: code)
        guard string(kSecCodeInfoIdentifier, in: information) == UpdatePublisherTrust.bundleIdentifier,
              string(kSecCodeInfoTeamIdentifier, in: information) == stampedTeamIdentifier,
              hasTimestampAndStapledTicket(information),
              let actualRequirement = designatedRequirement(in: information),
              let requirementData = copyData(of: actualRequirement),
              let trust = UpdatePublisherTrust(
                authorizedTeamIdentifier: stampedTeamIdentifier,
                designatedRequirementData: requirementData
              ) else {
            throw UpdateDownloadError.publisherTrustNotConfigured
        }
        try validateDeveloperID(code, teamIdentifier: stampedTeamIdentifier)
        try validateNotarization(at: appURL)
        return trust
    }

    func validateApplication(at appURL: URL, trust: UpdatePublisherTrust) throws {
        let code = try staticCode(at: appURL)
        guard let expectedRequirement = requirement(from: trust.designatedRequirementData) else {
            throw UpdateDownloadError.publisherTrustNotConfigured
        }
        try validateStructure(of: code, requirement: expectedRequirement)
        try validateDeveloperID(code, teamIdentifier: trust.authorizedTeamIdentifier)

        let information = try signingInformation(for: code)
        guard string(kSecCodeInfoIdentifier, in: information) == UpdatePublisherTrust.bundleIdentifier,
              string(kSecCodeInfoTeamIdentifier, in: information) == trust.authorizedTeamIdentifier,
              let actualRequirement = designatedRequirement(in: information),
              copyData(of: actualRequirement) == trust.designatedRequirementData else {
            throw UpdateDownloadError.publisherUnauthorized
        }
        guard hasTimestampAndStapledTicket(information) else {
            throw UpdateDownloadError.notarizationMissing
        }
        try validateNotarization(at: appURL)
    }

    private func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &code
        )
        guard status == errSecSuccess, let code else {
            throw UpdateDownloadError.signatureInvalid
        }
        return code
    }

    private func validateStructure(of code: SecStaticCode, requirement: SecRequirement?) throws {
        let rawFlags = kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks
            | kSecCSRestrictToAppLike
            | kSecCSRestrictSidebandData
        let status = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: rawFlags),
            requirement
        )
        guard status == errSecSuccess else {
            throw requirement == nil
                ? UpdateDownloadError.signatureInvalid
                : UpdateDownloadError.publisherUnauthorized
        }
    }

    private func validateDeveloperID(_ code: SecStaticCode, teamIdentifier: String) throws {
        guard let requirement = requirement(from: developerIDRequirement(teamIdentifier: teamIdentifier)) else {
            throw UpdateDownloadError.publisherTrustNotConfigured
        }
        let status = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
            requirement
        )
        guard status == errSecSuccess else {
            throw UpdateDownloadError.publisherUnauthorized
        }
    }

    private func signingInformation(for code: SecStaticCode) throws -> [String: Any] {
        var rawInformation: CFDictionary?
        let flags = SecCSFlags(
            rawValue: kSecCSSigningInformation
                | kSecCSRequirementInformation
                | kSecCSContentInformation
        )
        let status = SecCodeCopySigningInformation(code, flags, &rawInformation)
        guard status == errSecSuccess,
              let information = rawInformation as? [String: Any] else {
            throw UpdateDownloadError.signatureInvalid
        }
        return information
    }

    private func hasTimestampAndStapledTicket(_ information: [String: Any]) -> Bool {
        guard information[kSecCodeInfoTimestamp as String] != nil,
              let ticket = information[kSecCodeInfoStapledNotarizationTicket as String] as? Data else {
            return false
        }
        return !ticket.isEmpty
    }

    private func string(_ key: CFString, in information: [String: Any]) -> String? {
        information[key as String] as? String
    }

    private func designatedRequirement(in information: [String: Any]) -> SecRequirement? {
        guard let raw = information[kSecCodeInfoDesignatedRequirement as String] else {
            return nil
        }
        let value = raw as CFTypeRef
        guard CFGetTypeID(value) == SecRequirementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: SecRequirement.self)
    }

    private func copyData(of requirement: SecRequirement) -> Data? {
        var data: CFData?
        guard SecRequirementCopyData(requirement, SecCSFlags(rawValue: 0), &data) == errSecSuccess else {
            return nil
        }
        return data as Data?
    }

    private func requirement(from data: Data) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithData(
            data as CFData,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private func requirement(from text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            text as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private func developerIDRequirement(teamIdentifier: String) -> String {
        // Team IDs are validated as ten ASCII A-Z/0-9 bytes before reaching
        // this interpolation, so this requirement cannot be injected.
        """
        anchor apple generic and identifier \"\(UpdatePublisherTrust.bundleIdentifier)\" \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = \"\(teamIdentifier)\"
        """
    }

    private func validateNotarization(at appURL: URL) throws {
        let result: UpdateCommandResult
        do {
            result = try SystemUpdateCommandRunner().run(
                "/usr/sbin/spctl",
                arguments: [
                    "--assess", "--type", "execute", "--ignore-cache",
                    "--no-cache", "--raw", appURL.path,
                ],
                timeout: 30
            )
        } catch {
            throw UpdateDownloadError.notarizationMissing
        }
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: result.output,
                options: [],
                format: nil
              ) as? [String: Any],
              plist["assessment:verdict"] as? Bool == true,
              let authority = plist["assessment:authority"] as? [String: Any],
              authority["assessment:authority:source"] as? String == "Notarized Developer ID" else {
            throw UpdateDownloadError.notarizationMissing
        }
    }
}

/// Complete bundle-identity verifier shared by the downloader (mounted source)
/// and installer (source, private staging copy, and installed destination).
/// The signature validator is injectable only inside the module's tests; the
/// public initializer always uses Security.framework.
final class UpdateBundleVerifier: @unchecked Sendable {
    private let publisherTrust: UpdatePublisherTrust?
    private let signatureValidator: any UpdateCodeSignatureValidating
    private let hostOperatingSystemVersion: OperatingSystemVersion

    convenience init(publisherTrust: UpdatePublisherTrust?) {
        self.init(
            publisherTrust: publisherTrust,
            signatureValidator: SystemUpdateCodeSignatureValidator(),
            hostOperatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    init(
        publisherTrust: UpdatePublisherTrust?,
        signatureValidator: any UpdateCodeSignatureValidating,
        hostOperatingSystemVersion: OperatingSystemVersion
    ) {
        self.publisherTrust = publisherTrust
        self.signatureValidator = signatureValidator
        self.hostOperatingSystemVersion = hostOperatingSystemVersion
    }

    func validate(
        appURL: URL,
        expectedVersion: UpdateVersion,
        expectedArchitecture: HostArchitecture
    ) throws {
        let publisherTrust = try configuredPublisherTrust()
        let appValues: URLResourceValues
        do {
            appValues = try appURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw UpdateDownloadError.bundleReadFailed(appURL.path)
        }
        guard appValues.isDirectory == true, appValues.isSymbolicLink != true else {
            throw UpdateDownloadError.bundleIdentityMismatch
        }

        // Validate the sealed bundle first. Metadata reads below therefore
        // consume bytes covered by an authorized signature.
        try signatureValidator.validateApplication(at: appURL, trust: publisherTrust)

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let information: [String: Any]
        do {
            let data = try Data(contentsOf: infoURL, options: .mappedIfSafe)
            guard let decoded = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw UpdateDownloadError.bundleIdentityMismatch
            }
            information = decoded
        } catch let error as UpdateDownloadError {
            throw error
        } catch {
            throw UpdateDownloadError.bundleReadFailed(infoURL.path)
        }

        guard information["CFBundlePackageType"] as? String == "APPL",
              information["CFBundleIdentifier"] as? String == UpdatePublisherTrust.bundleIdentifier,
              information["CFBundleExecutable"] as? String == UpdatePublisherTrust.bundleExecutable else {
            throw UpdateDownloadError.bundleIdentityMismatch
        }
        guard information["ScanStudioRelease"] as? String == expectedVersion.raw else {
            throw UpdateDownloadError.versionMismatch
        }

        let launcherURL = appURL.appendingPathComponent(
            "Contents/MacOS/\(UpdatePublisherTrust.bundleExecutable)"
        )
        guard try Self.isRegularNonSymlink(launcherURL),
              FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
            throw UpdateDownloadError.bundleIdentityMismatch
        }

        let architectureURL = appURL.appendingPathComponent(
            "Contents/MacOS/\(UpdatePublisherTrust.architectureExecutable)"
        )
        guard try Self.isRegularNonSymlink(architectureURL) else {
            throw UpdateDownloadError.bundleIdentityMismatch
        }
        do {
            guard try MachOArchitectureInspector.architectures(at: architectureURL)
                == [expectedArchitecture] else {
                throw UpdateDownloadError.architectureMismatch
            }
        } catch let error as UpdateDownloadError {
            throw error
        } catch {
            throw UpdateDownloadError.bundleReadFailed(architectureURL.path)
        }

        guard let minimumRaw = information["LSMinimumSystemVersion"] as? String,
              let minimum = ParsedOperatingSystemVersion(minimumRaw),
              let supportedFloor = ParsedOperatingSystemVersion("14.0"),
              minimum >= supportedFloor,
              minimum <= ParsedOperatingSystemVersion(hostOperatingSystemVersion) else {
            throw UpdateDownloadError.operatingSystemUnsupported
        }
    }

    func requireConfiguredPublisherTrust() throws {
        _ = try configuredPublisherTrust()
    }

    private func configuredPublisherTrust() throws -> UpdatePublisherTrust {
        guard let publisherTrust else {
            throw UpdateDownloadError.publisherTrustNotConfigured
        }
        return publisherTrust
    }

    private static func isRegularNonSymlink(_ url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        } catch {
            throw UpdateDownloadError.bundleReadFailed(url.path)
        }
    }
}

private struct ParsedOperatingSystemVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              let major = Int(parts[0]), major >= 0 else {
            return nil
        }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        let patch = parts.count > 2 ? Int(parts[2]) : 0
        guard let minor, let patch, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init(_ version: OperatingSystemVersion) {
        major = version.majorVersion
        minor = version.minorVersion
        patch = version.patchVersion
    }

    static func < (lhs: ParsedOperatingSystemVersion, rhs: ParsedOperatingSystemVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

private enum MachOArchitectureInspector {
    private static let mhMagic = UInt32(0xfeedface)
    private static let mhMagic64 = UInt32(0xfeedfacf)
    private static let fatMagic = UInt32(0xcafebabe)
    private static let fatMagic64 = UInt32(0xcafebabf)
    private static let cpuArm64 = UInt32(0x0100000c)
    private static let cpuX8664 = UInt32(0x01000007)

    static func architectures(at url: URL) throws -> Set<HostArchitecture> {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 8 else { throw UpdateDownloadError.architectureMismatch }

        let bigMagic = try uint32(data, offset: 0, byteOrder: .big)
        let littleMagic = try uint32(data, offset: 0, byteOrder: .little)
        if littleMagic == mhMagic || littleMagic == mhMagic64 {
            return try architectureSet([uint32(data, offset: 4, byteOrder: .little)])
        }
        if bigMagic == mhMagic || bigMagic == mhMagic64 {
            return try architectureSet([uint32(data, offset: 4, byteOrder: .big)])
        }
        if bigMagic == fatMagic || bigMagic == fatMagic64 {
            return try fatArchitectures(data, byteOrder: .big, is64Bit: bigMagic == fatMagic64)
        }
        if littleMagic == fatMagic || littleMagic == fatMagic64 {
            return try fatArchitectures(data, byteOrder: .little, is64Bit: littleMagic == fatMagic64)
        }
        throw UpdateDownloadError.architectureMismatch
    }

    private static func fatArchitectures(
        _ data: Data,
        byteOrder: ByteOrder,
        is64Bit: Bool
    ) throws -> Set<HostArchitecture> {
        let count = Int(try uint32(data, offset: 4, byteOrder: byteOrder))
        guard count > 0, count <= 64 else { throw UpdateDownloadError.architectureMismatch }
        let stride = is64Bit ? 32 : 20
        guard data.count >= 8 + count * stride else {
            throw UpdateDownloadError.architectureMismatch
        }
        var rawArchitectures: [UInt32] = []
        rawArchitectures.reserveCapacity(count)
        for index in 0..<count {
            rawArchitectures.append(
                try uint32(data, offset: 8 + index * stride, byteOrder: byteOrder)
            )
        }
        return try architectureSet(rawArchitectures)
    }

    private static func architectureSet(_ rawValues: [UInt32]) throws -> Set<HostArchitecture> {
        // Release artifacts are architecture-specific. A fat binary (including
        // duplicate slices) is not the selected per-arch product.
        guard rawValues.count == 1 else { throw UpdateDownloadError.architectureMismatch }
        var result: Set<HostArchitecture> = []
        for raw in rawValues {
            switch raw {
            case cpuArm64: result.insert(.arm64)
            case cpuX8664: result.insert(.x86_64)
            default: throw UpdateDownloadError.architectureMismatch
            }
        }
        return result
    }

    private enum ByteOrder { case big, little }

    private static func uint32(_ data: Data, offset: Int, byteOrder: ByteOrder) throws -> UInt32 {
        guard offset >= 0, data.count >= offset + 4 else {
            throw UpdateDownloadError.architectureMismatch
        }
        let bytes = data[offset..<(offset + 4)]
        switch byteOrder {
        case .big:
            return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        case .little:
            return bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
    }
}

struct UpdateCommandResult: Sendable {
    let status: Int32
    let output: Data
}

protocol UpdateCommandRunning: Sendable {
    func run(_ executablePath: String, arguments: [String], timeout: TimeInterval) throws -> UpdateCommandResult
}

private enum UpdateCommandFailure: Error { case timedOut(Data) }

private struct SystemUpdateCommandRunner: UpdateCommandRunning {
    func run(_ executablePath: String, arguments: [String], timeout: TimeInterval) throws -> UpdateCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            let output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            throw UpdateCommandFailure.timedOut(output)
        }
        let output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return UpdateCommandResult(status: process.terminationStatus, output: output)
    }
}

protocol UpdateReadableFile: AnyObject, Sendable {
    func read(upToCount count: Int) throws -> Data
    func close() throws
}

protocol UpdateFileReading: Sendable {
    func open(_ url: URL) throws -> any UpdateReadableFile
}

private final class SystemUpdateReadableFile: UpdateReadableFile, @unchecked Sendable {
    private let handle: FileHandle

    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    func read(upToCount count: Int) throws -> Data { try handle.read(upToCount: count) ?? Data() }
    func close() throws { try handle.close() }
}

private struct SystemUpdateFileReader: UpdateFileReading {
    func open(_ url: URL) throws -> any UpdateReadableFile {
        try SystemUpdateReadableFile(url: url)
    }
}

/// Downloads and cryptographically verifies a candidate into a mounted,
/// signature-checked app bundle that the install core can consume. The only
/// subprocesses are bounded `hdiutil` attach/detach and `spctl` notarization
/// assessment; signature and designated-requirement trust are evaluated
/// directly through Security.framework.
public final class UpdateDownloader {
    private let session: any URLSessionProtocol
    private let bundleVerifier: UpdateBundleVerifier
    private let commandRunner: any UpdateCommandRunning
    private let fileReader: any UpdateFileReading

    public convenience init(
        session: any URLSessionProtocol = URLSession.shared,
        publisherTrust: UpdatePublisherTrust? = nil
    ) {
        self.init(
            session: session,
            bundleVerifier: UpdateBundleVerifier(publisherTrust: publisherTrust),
            commandRunner: SystemUpdateCommandRunner(),
            fileReader: SystemUpdateFileReader()
        )
    }

    init(
        session: any URLSessionProtocol,
        bundleVerifier: UpdateBundleVerifier,
        commandRunner: any UpdateCommandRunning,
        fileReader: any UpdateFileReading
    ) {
        self.session = session
        self.bundleVerifier = bundleVerifier
        self.commandRunner = commandRunner
        self.fileReader = fileReader
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
        let actual: String
        do {
            actual = try Self.sha256(ofFileAt: destination, using: fileReader)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateDownloadError.checksumReadFailed(
                path: destination.path,
                cause: String(describing: error)
            )
        }
        guard actual == candidate.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateDownloadError.checksumMismatch
        }
        return destination
    }

    // MARK: - Mount + locate app

    /// Scoped mount API: attaches read-only, requires exactly one application
    /// `ScanStudio.app`, validates publisher + identity + candidate version +
    /// architecture + host OS, runs `body`, then always performs a bounded
    /// detach. A failed normal detach is retried with `-force`; failure of both
    /// is surfaced as `.detachFailed` rather than silently leaking the mount.
    public func withVerifiedMountedApp<T>(
        _ dmgURL: URL,
        candidate: UpdateCandidate,
        architecture: HostArchitecture,
        _ body: (URL) throws -> T
    ) throws -> T {
        // Missing publisher configuration is known before any untrusted disk
        // image is attached; fail here and avoid the mount attack surface.
        try bundleVerifier.requireConfiguredPublisherTrust()
        return try withMountedApp(dmgURL) { appURL in
            try bundleVerifier.validate(
                appURL: appURL,
                expectedVersion: candidate.version,
                expectedArchitecture: architecture
            )
            return try body(appURL)
        }
    }

    func withMountedApp<T>(_ dmgURL: URL, _ body: (URL) throws -> T) throws -> T {
        let result: UpdateCommandResult
        do {
            result = try commandRunner.run(
                "/usr/bin/hdiutil",
                arguments: ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path],
                timeout: 30
            )
        } catch let UpdateCommandFailure.timedOut(output) {
            if let descriptor = Self.mountDescriptor(from: output),
               !detach(descriptor.detachTarget) {
                throw UpdateDownloadError.detachFailed
            }
            throw UpdateDownloadError.mountFailed
        } catch {
            throw UpdateDownloadError.mountFailed
        }

        let descriptor = Self.mountDescriptor(from: result.output)
        if result.status != 0 {
            if let descriptor, !detach(descriptor.detachTarget) {
                throw UpdateDownloadError.detachFailed
            }
            throw UpdateDownloadError.mountFailed
        }
        guard let descriptor, let mountRoot = descriptor.mountRoot else {
            if let descriptor, !detach(descriptor.detachTarget) {
                throw UpdateDownloadError.detachFailed
            }
            throw UpdateDownloadError.mountFailed
        }

        let operation: Result<T, Error>
        do {
            operation = .success(try body(Self.singleApp(in: mountRoot)))
        } catch {
            operation = .failure(error)
        }

        guard detach(descriptor.detachTarget) else {
            throw UpdateDownloadError.detachFailed
        }
        return try operation.get()
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
    private static func sha256(ofFileAt url: URL, using reader: any UpdateFileReading) throws -> String {
        let handle = try reader.open(url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20)
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct MountDescriptor {
        let mountRoot: URL?
        let detachTarget: String
    }

    /// Extracts both mount point and a device/path detach target. Keeping the
    /// device entry means even a malformed attach response with no mount point
    /// can still be cleaned up.
    private static func mountDescriptor(from data: Data) -> MountDescriptor? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else {
            return nil
        }
        var firstDevice: String?
        for entity in entities {
            if firstDevice == nil, let device = entity["dev-entry"] as? String {
                firstDevice = device
            }
            if let mountPath = entity["mount-point"] as? String {
                return MountDescriptor(
                    mountRoot: URL(fileURLWithPath: mountPath, isDirectory: true),
                    detachTarget: (entity["dev-entry"] as? String) ?? mountPath
                )
            }
        }
        guard let firstDevice else { return nil }
        return MountDescriptor(mountRoot: nil, detachTarget: firstDevice)
    }

    /// Requires one and only one application anywhere in the mounted image,
    /// named ScanStudio.app at the root.
    /// A second app is an archive-identity failure even when one has the right
    /// name; no preference/fallback selection is permitted.
    private static func singleApp(in directory: URL) throws -> URL {
        var enumerationFailure: String?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { url, _ in
                enumerationFailure = url.path
                return false
            }
        ) else {
            throw UpdateDownloadError.bundleReadFailed(directory.path)
        }
        var apps: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                throw UpdateDownloadError.bundleReadFailed(url.path)
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "app", values.isDirectory == true {
                apps.append(url)
                enumerator.skipDescendants()
            }
        }
        if let enumerationFailure {
            throw UpdateDownloadError.bundleReadFailed(enumerationFailure)
        }
        guard apps.count == 1,
              apps[0].lastPathComponent == "ScanStudio.app",
              apps[0].deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL else {
            throw UpdateDownloadError.notAnApp
        }
        return apps[0]
    }

    private func detach(_ target: String) -> Bool {
        let normal = try? commandRunner.run(
            "/usr/bin/hdiutil",
            arguments: ["detach", target],
            timeout: 10
        )
        if normal?.status == 0 { return true }
        let forced = try? commandRunner.run(
            "/usr/bin/hdiutil",
            arguments: ["detach", "-force", target],
            timeout: 10
        )
        return forced?.status == 0
    }
}
