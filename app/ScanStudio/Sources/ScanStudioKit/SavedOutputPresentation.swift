import Foundation

/// Only written-output receipts identify saved files. Recipe destinations and
/// temporary rgb/IR capture paths must never become saved-output actions.
public struct SavedOutputPresentation: Identifiable, Equatable, Sendable {
    public let label: String
    public let url: URL
    public var id: String { label }

    public static func files(in outputs: WrittenOutputs?) -> [Self] {
        guard let outputs else { return [] }
        let paths: [(String, String?)] = [
            ("Master capture", outputs.archivePath),
            ("Raw negative export", outputs.rawNegativePath),
            ("Infrared export", outputs.rawNegativeIrPath),
            ("Processed positive", outputs.positivePath),
            ("Processed preview export", outputs.previewPath),
        ]
        return paths.compactMap { label, path in
            // Do not guess a base directory for historical relative paths.
            guard let path, path.hasPrefix("/"), !path.contains("\0") else { return nil }
            return Self(label: label, url: URL(fileURLWithPath: path))
        }
    }
}
