// Comparable version identity for ScanStudio release strings. This is the
// single source of truth for "what version am I, and is a remote one newer",
// used by the auto-update plans. It parses `major.minor[.patch][-prerelease]`
// strings without any external dependency and never throws.

import Foundation

/// A parseable, comparable ScanStudio version such as `0.3.0-alpha.11`.
///
/// Ordering rule: `alpha < beta < rc < stable`; prerelease numeric suffix
/// compares by value (`alpha.9 < alpha.11`).
///
/// `raw` preserves the caller's spelling (including any leading `v` and
/// patch-less core), while equality and ordering are semantic: `0.3` equals
/// `0.3.0`, and `v0.3.0` equals `0.3.0`.
public struct UpdateVersion: Equatable, Comparable, Sendable, Codable {
    /// The input string exactly as given (e.g. `"0.3.0-alpha.11"`).
    public let raw: String

    /// `true` when the version has a prerelease tail (e.g. `-alpha.11`).
    public let isPrerelease: Bool

    /// Core `major.minor.patch`, with missing minor/patch defaulting to 0.
    private let major: Int
    private let minor: Int
    private let patch: Int

    /// Rank of the prerelease tag: `0` alpha, `1` beta, `2` rc, `3` any
    /// unknown/newer tag. `nil` when the version is stable (no tail).
    private let tagRank: Int?

    /// Numeric prerelease suffix, defaulting to 0 when absent.
    private let suffix: Int

    private static let knownRanks: [String: Int] = ["alpha": 0, "beta": 1, "rc": 2]

    /// Parses `raw` (e.g. `"0.3.0-alpha.11"`, `"v0.3.0"`, `"1.2"`).
    ///
    /// Returns `nil` for empty input, a core with non-integer or negative
    /// components, a core that is not 2 or 3 dot-separated integers, a
    /// non-identifier prerelease tag, a duplicate `.` in the numeric tail,
    /// or a trailing empty tail/number. Never throws.
    public init?(raw: String) {
        guard !raw.isEmpty else { return nil }

        var core = raw
        if core.hasPrefix("v") {
            core.removeFirst()
        }

        let dashIndex = core.firstIndex(of: "-")
        let coreString: String
        let tailString: String?
        if let dashIndex {
            coreString = String(core[..<dashIndex])
            tailString = String(core[core.index(after: dashIndex)...])
        } else {
            coreString = core
            tailString = nil
        }

        let coreParts = coreString.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(coreParts.count) else { return nil }
        var coreNumbers: [Int] = []
        coreNumbers.reserveCapacity(coreParts.count)
        for part in coreParts {
            guard let number = Int(part), number >= 0 else { return nil }
            coreNumbers.append(number)
        }
        let major = coreNumbers[0]
        let minor = coreNumbers.count > 1 ? coreNumbers[1] : 0
        let patch = coreNumbers.count > 2 ? coreNumbers[2] : 0

        var tagRank: Int?
        var suffix = 0
        if let tailString {
            guard !tailString.isEmpty else { return nil }
            let firstDot = tailString.firstIndex(of: ".")
            let tag: String
            let numberString: String?
            if let firstDot {
                tag = String(tailString[..<firstDot])
                numberString = String(tailString[tailString.index(after: firstDot)...])
            } else {
                tag = tailString
                numberString = nil
            }
            guard !tag.isEmpty else { return nil }
            guard tag.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            if let numberString {
                guard !numberString.isEmpty else { return nil }
                guard let number = Int(numberString), number >= 0 else { return nil }
                suffix = number
            }
            tagRank = UpdateVersion.knownRanks[tag.lowercased()] ?? 3
        }

        self.raw = raw
        self.isPrerelease = tagRank != nil
        self.major = major
        self.minor = minor
        self.patch = patch
        self.tagRank = tagRank
        self.suffix = suffix
    }

    public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        lhs.compare(to: rhs) == .ascending
    }

    public static func == (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        lhs.compare(to: rhs) == .same
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .raw)
        guard let parsed = UpdateVersion(raw: rawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .raw,
                in: container,
                debugDescription: "Invalid ScanStudio version string: \(rawValue)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(raw, forKey: .raw)
    }

    private enum CodingKeys: String, CodingKey {
        case raw
    }

    private enum Order {
        case ascending
        case same
        case descending
    }

    private func compare(to other: UpdateVersion) -> Order {
        if major != other.major {
            return major < other.major ? .ascending : .descending
        }
        if minor != other.minor {
            return minor < other.minor ? .ascending : .descending
        }
        if patch != other.patch {
            return patch < other.patch ? .ascending : .descending
        }
        switch (tagRank, other.tagRank) {
        case (nil, nil):
            return .same
        case (nil, _?):
            return .descending
        case (_?, nil):
            return .ascending
        case (let lhsRank?, let rhsRank?):
            if lhsRank != rhsRank {
                return lhsRank < rhsRank ? .ascending : .descending
            }
            if suffix != other.suffix {
                return suffix < other.suffix ? .ascending : .descending
            }
            let lhsRaw = raw.lowercased()
            let rhsRaw = other.raw.lowercased()
            if lhsRaw == rhsRaw {
                return .same
            }
            return lhsRaw < rhsRaw ? .ascending : .descending
        }
    }
}
