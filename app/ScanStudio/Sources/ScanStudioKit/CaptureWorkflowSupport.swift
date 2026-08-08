import Foundation

/// A deliberately small, curated film-stock list. The process belongs to the
/// stock rather than being something the user has to remember separately.
public struct FilmStock: Identifiable, Hashable, Sendable {
    public let brand: String
    public let name: String
    public let process: FilmProcess
    public let boxSpeedIso: Int

    public var id: String { "\(brand)|\(name)" }
    public var displayName: String { "\(brand) \(name)" }
    public var isTraditionalBlackAndWhite: Bool { process == .bwNegative }

    public init(brand: String, name: String, process: FilmProcess, boxSpeedIso: Int) {
        self.brand = brand
        self.name = name
        self.process = process
        self.boxSpeedIso = boxSpeedIso
    }

    public static let curated: [FilmStock] = [
        .init(brand: "Kodak", name: "Gold 200", process: .c41ColorNegative, boxSpeedIso: 200),
        .init(brand: "Kodak", name: "UltraMax 400", process: .c41ColorNegative, boxSpeedIso: 400),
        .init(brand: "Kodak", name: "Portra 160", process: .c41ColorNegative, boxSpeedIso: 160),
        .init(brand: "Kodak", name: "Portra 400", process: .c41ColorNegative, boxSpeedIso: 400),
        .init(brand: "Kodak", name: "Portra 800", process: .c41ColorNegative, boxSpeedIso: 800),
        .init(brand: "Kodak", name: "Ektar 100", process: .c41ColorNegative, boxSpeedIso: 100),
        .init(brand: "Kodak", name: "Ektachrome E100", process: .positive, boxSpeedIso: 100),
        .init(brand: "Kodak", name: "Tri-X 400", process: .bwNegative, boxSpeedIso: 400),
        .init(brand: "Kodak", name: "T-MAX 100", process: .bwNegative, boxSpeedIso: 100),
        .init(brand: "Kodak", name: "T-MAX 400", process: .bwNegative, boxSpeedIso: 400),
        .init(brand: "Fujifilm", name: "200", process: .c41ColorNegative, boxSpeedIso: 200),
        .init(brand: "Fujifilm", name: "400", process: .c41ColorNegative, boxSpeedIso: 400),
        .init(brand: "Fujifilm", name: "Velvia 50", process: .positive, boxSpeedIso: 50),
        .init(brand: "Fujifilm", name: "Velvia 100", process: .positive, boxSpeedIso: 100),
        .init(brand: "Fujifilm", name: "Provia 100F", process: .positive, boxSpeedIso: 100),
        .init(brand: "Fujifilm", name: "Neopan Acros II", process: .bwNegative, boxSpeedIso: 100),
        .init(brand: "Ilford", name: "HP5 Plus", process: .bwNegative, boxSpeedIso: 400),
        .init(brand: "Ilford", name: "FP4 Plus", process: .bwNegative, boxSpeedIso: 125),
        .init(brand: "Ilford", name: "Pan F Plus", process: .bwNegative, boxSpeedIso: 50),
        .init(brand: "Ilford", name: "Delta 100", process: .bwNegative, boxSpeedIso: 100),
        .init(brand: "Ilford", name: "Delta 400", process: .bwNegative, boxSpeedIso: 400),
        .init(brand: "Ilford", name: "Delta 3200", process: .bwNegative, boxSpeedIso: 3200),
        .init(brand: "Ilford", name: "XP2 Super", process: .c41ColorNegative, boxSpeedIso: 400),
    ]

    public static func matching(metadataName: String?) -> FilmStock? {
        guard let metadataName else { return nil }
        return curated.first { $0.displayName.caseInsensitiveCompare(metadataName) == .orderedSame }
    }
}

public enum FilenameTemplate {
    public static let defaultTemplate = "ScanStudio#"

    /// Expands only the documented tokens. Existing `####` runs remain
    /// untouched, preserving legacy project templates exactly.
    public static func expand(
        _ template: String,
        metadata: MetadataSet,
        frameIndex: Int,
        fallbackDate: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let components = dateComponents(metadata.date, fallback: fallbackDate, calendar: calendar)
        let substitutions = [
            "$FilmStock": sanitizedComponent(metadata.filmStock ?? "UnknownFilm"),
            "$Camera": sanitizedComponent(metadata.camera ?? "UnknownCamera"),
            "$Lens": sanitizedComponent(metadata.lens ?? "UnknownLens"),
            "$Month": components.month.map { String(format: "%02d", $0) } ?? "UnknownMonth",
            "$Day": components.day.map { String(format: "%02d", $0) } ?? "UnknownDay",
            "$Year": components.year.map { String(format: "%04d", $0) } ?? "UnknownYear",
            "$Frame": String(format: "%04d", frameIndex),
        ]
        return substitutions.reduce(template) { result, substitution in
            result.replacingOccurrences(of: substitution.key, with: substitution.value)
        }
    }

    /// File-system-safe metadata components. Separators and control
    /// characters cannot escape the selected destination; hyphens and dots
    /// stay legible for camera/lens names.
    public static func sanitizedComponent(_ value: String) -> String {
        let value = value
            .replacingOccurrences(of: "f/", with: "F")
            .replacingOccurrences(of: "F/", with: "F")
        let forbidden = CharacterSet(charactersIn: "\\:\u{0}").union(.newlines)
        let pieces = value.components(separatedBy: forbidden)
        let collapsed = pieces.joined()
            .replacingOccurrences(of: "/", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return collapsed.isEmpty ? "Unknown" : collapsed
    }

    private static func dateComponents(
        _ partialDate: PartialDate?,
        fallback: Date,
        calendar: Calendar
    ) -> DateComponents {
        guard let partialDate else { return DateComponents() }
        switch partialDate {
        case .exact(let value):
            let bits = value.split(separator: "-").compactMap { Int($0) }
            guard bits.count == 3 else { return DateComponents() }
            return DateComponents(year: bits[0], month: bits[1], day: bits[2])
        case .monthOnly(let year, let month):
            return DateComponents(year: year, month: month)
        case .yearOnly(let year):
            return DateComponents(year: year)
        case .unknown:
            return DateComponents()
        }
    }
}

/// Per-user history. It is intentionally separate from `MetadataSet` and
/// project manifests: a roll can be shared without leaking a user's gear.
public struct RecentGearHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let camera: String
        public let lens: String
        public var id: String { "\(camera)\u{1F}\(lens)" }

        public init(camera: String, lens: String) {
            self.camera = camera
            self.lens = lens
        }
    }

    public private(set) var entries: [Entry]
    public static let maximumEntries = 30

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public mutating func remember(camera: String?, lens: String?) {
        let camera = normalized(camera)
        let lens = normalized(lens)
        guard camera != nil || lens != nil else { return }
        let entry = Entry(camera: camera ?? "", lens: lens ?? "")
        entries.removeAll { $0 == entry }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.maximumEntries))
    }

    public mutating func removeCamera(_ camera: String) {
        entries.removeAll { $0.camera == camera }
    }

    public mutating func removeLens(_ lens: String) {
        entries.removeAll { $0.lens == lens }
    }

    public var recentCameras: [String] {
        unique(entries.map(\.camera).filter { !$0.isEmpty })
    }

    /// Lenses last used with the selected camera are placed first, then the
    /// rest of the user's list. This is rank-only; it never hides manual
    /// choices or other lenses.
    public func recentLenses(for camera: String?) -> [String] {
        let selected = normalized(camera)
        let matching = entries.filter { selected != nil && $0.camera == selected }.map(\.lens)
        let remaining = entries.filter { $0.camera != selected }.map(\.lens)
        return unique((matching + remaining).filter { !$0.isEmpty })
    }

    /// A blank roll prefill is a camera/lens pair, never a partial edit
    /// that happened to receive focus last.
    public var lastUsed: Entry? { entries.first { !$0.camera.isEmpty && !$0.lens.isEmpty } }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

public enum OutputDestination {
    public static func destination(base: String, subfolder: String?, fallback: String) -> String {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return fallback }
        guard let subfolder = subfolder?.trimmingCharacters(in: .whitespacesAndNewlines), !subfolder.isEmpty else {
            return root
        }
        return URL(fileURLWithPath: root).appendingPathComponent(safeFolderComponent(subfolder)).path
    }

    private static func safeFolderComponent(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "Output" }
        return cleaned
    }
}

/// Presents the output location as an already-valid part of a saved roll,
/// while keeping a custom base folder an optional override. Project creation
/// and output redirection are separate concepts; the interface must not imply
/// that a second save-location choice is required before scanning.
public enum OutputLocationPresentation {
    public static func summary(
        hasOpenProject: Bool,
        customLocation: String
    ) -> String {
        guard hasOpenProject else {
            return "Save Roll creates the project and sets up default output locations automatically."
        }
        let customLocation = customLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !customLocation.isEmpty else {
            return "Ready: every enabled output already has a save location. Changing it is optional."
        }
        return "Custom output location:\n\(customLocation)"
    }

    public static func showsChangeAction(hasOpenProject: Bool) -> Bool {
        hasOpenProject
    }
}

/// A single folder needs distinct master/derivative stems. Separate output
/// folders can intentionally share the user's template without a collision.
public enum OutputNamingTemplate {
    public static func template(_ template: String, roleSuffix: String, separateFolders: Bool) -> String {
        guard !separateFolders else { return template }
        let suffix = "-\(roleSuffix)"
        return template.hasSuffix(suffix) ? template : "\(template)\(suffix)"
    }
}

/// One shared rule for roll-wide and per-frame output controls: enabling an
/// output is always allowed, but the last retained output cannot be turned
/// off. The engine independently enforces the same invariant at its request
/// boundary.
public enum OutputRetentionPolicy {
    public enum Role: Sendable {
        case archive
        case rawExport
        case positive
        case preview
    }

    public static let helpText = "Keep at least one output."

    public static func allowsChange(
        _ role: Role,
        to enabled: Bool,
        archiveEnabled: Bool,
        rawExportEnabled: Bool = false,
        positiveEnabled: Bool,
        previewEnabled: Bool
    ) -> Bool {
        guard !enabled else { return true }
        return switch role {
        case .archive:
            rawExportEnabled || positiveEnabled || previewEnabled
        case .rawExport:
            archiveEnabled || positiveEnabled || previewEnabled
        case .positive:
            archiveEnabled || rawExportEnabled || previewEnabled
        case .preview:
            archiveEnabled || rawExportEnabled || positiveEnabled
        }
    }
}

public enum ScanRecipePreset: String, CaseIterable, Identifiable, Sendable {
    case masterTiffJpeg
    case masterTiff
    case masterOnly
    case fastReview
    case custom

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .masterTiffJpeg: "Master + TIFF + JPEG"
        case .masterTiff: "Master + TIFF"
        case .masterOnly: "Master only"
        case .fastReview: "Fast review"
        case .custom: "Custom"
        }
    }
}

public struct ScanRecipeValues: Equatable, Sendable {
    public var resolutionDpi: Int
    public var bitDepth: Int
    public var multisamplePasses: Int
    public var channels: String
    public var autofocus: Bool
    public var autoExposure: Bool
    public var digitalIce: Bool
    public var digitalIceMode: DigitalIceMode
    public var softwareDustRemovalBw: Bool
    public var positiveTiff: Bool
    public var positiveJPEG: Bool
    public var positiveFileFormat: OutputFileFormat
    public var previewFileFormat: OutputFileFormat
    public var positiveColorProfile: OutputColorProfile
    public var previewMaxLongEdgePx: Int

    public init(
        resolutionDpi: Int,
        bitDepth: Int,
        multisamplePasses: Int,
        channels: String,
        autofocus: Bool,
        autoExposure: Bool,
        digitalIce: Bool,
        digitalIceMode: DigitalIceMode = .legacy,
        softwareDustRemovalBw: Bool = false,
        positiveTiff: Bool,
        positiveJPEG: Bool,
        positiveFileFormat: OutputFileFormat = .tiff,
        previewFileFormat: OutputFileFormat = .jpeg,
        positiveColorProfile: OutputColorProfile = .adobeRgb1998,
        previewMaxLongEdgePx: Int = 0
    ) {
        self.resolutionDpi = resolutionDpi
        self.bitDepth = bitDepth
        self.multisamplePasses = multisamplePasses
        self.channels = channels
        self.autofocus = autofocus
        self.autoExposure = autoExposure
        self.digitalIce = digitalIce
        self.digitalIceMode = digitalIceMode
        self.softwareDustRemovalBw = softwareDustRemovalBw
        self.positiveTiff = positiveTiff
        self.positiveJPEG = positiveJPEG
        self.positiveFileFormat = positiveFileFormat
        self.previewFileFormat = previewFileFormat
        self.positiveColorProfile = positiveColorProfile
        self.previewMaxLongEdgePx = previewMaxLongEdgePx
    }
}

public enum ScanRecipePolicy {
    public static func values(
        for preset: ScanRecipePreset,
        filmProcess: FilmProcess,
        supportedMultisamplePasses: [Int]
    ) -> ScanRecipeValues? {
        guard preset != .custom else { return nil }
        let fast = preset == .fastReview
        let requestedPasses = fast ? 1 : 4
        let passes = MultisamplePassPolicy.coerce(requestedPasses, into: supportedMultisamplePasses)
        let traditionalBlackAndWhite = filmProcess == .bwNegative
        return ScanRecipeValues(
            resolutionDpi: fast ? 1_000 : 4_000,
            bitDepth: fast ? 8 : 16,
            multisamplePasses: passes,
            channels: traditionalBlackAndWhite || fast ? "rgb" : "rgbi",
            autofocus: !fast,
            autoExposure: !fast,
            digitalIce: !traditionalBlackAndWhite && !fast,
            digitalIceMode: .legacy,
            softwareDustRemovalBw: false,
            positiveTiff: preset == .masterTiffJpeg || preset == .masterTiff,
            positiveJPEG: preset == .masterTiffJpeg || preset == .fastReview,
            positiveFileFormat: .tiff,
            previewFileFormat: .jpeg,
            positiveColorProfile: .adobeRgb1998,
            previewMaxLongEdgePx: fast ? 2_048 : 0
        )
    }

    public static func preset(
        matching values: ScanRecipeValues,
        filmProcess: FilmProcess,
        supportedMultisamplePasses: [Int]
    ) -> ScanRecipePreset {
        for preset in ScanRecipePreset.allCases where preset != .custom {
            if Self.values(for: preset, filmProcess: filmProcess, supportedMultisamplePasses: supportedMultisamplePasses) == values {
                return preset
            }
        }
        return .custom
    }
}
