import Foundation

/// A complete, reviewable input for one new roll. Authorization is explicit
/// in this document and must also be confirmed on the CLI invocation.
public struct ScanJobDocument: Codable, Equatable, Sendable {
    public struct Roll: Codable, Equatable, Sendable {
        public let name: String
        public let carrier: SimulatedFilmCarrier
        public let frameCount: Int
        public let filmProcess: FilmProcess
    }
    public struct Confirmations: Codable, Equatable, Sendable {
        public let filmLoaded: Bool
        public let motion: Bool
    }
    public let schemaVersion: Int
    public let deviceId: String
    public let roll: Roll
    public var frames: [Int]
    public let capture: CaptureRecipe
    public let processing: ProcessingRecipe
    public let outputs: OutputRecipe
    public let confirmations: Confirmations
    public let autoApprove: Bool?
    public let wait: Bool?

    public enum Invalid: Error { case document(String) }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "deviceId", "roll", "frames", "capture", "processing", "outputs", "confirmations", "autoApprove", "wait"]) else {
            throw Invalid.document("Expected a job object of at most 1 MiB with only documented fields.")
        }
        var job = try JSONDecoder().decode(Self.self, from: data)
        guard job.schemaVersion == 1 else { throw Invalid.document("schemaVersion must be 1.") }
        guard !job.deviceId.isEmpty, job.deviceId.utf8.count <= 256,
              !job.deviceId.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !job.roll.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              job.roll.name.utf8.count <= 256,
              !job.roll.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...10_000).contains(job.roll.frameCount), !job.frames.isEmpty,
              job.frames.count == Set(job.frames).count,
              job.frames.allSatisfy({ (1...job.roll.frameCount).contains($0) }) else {
            throw Invalid.document("Provide a device ID, roll name, and unique in-range frames.")
        }
        guard job.processing.filmProcess == job.roll.filmProcess else {
            throw Invalid.document("The roll and processing filmProcess must agree.")
        }
        guard job.capture.exposureOverride10ns == nil else {
            throw Invalid.document("A new job cannot import a scanner-bound exposure lock; solve exposure in its project first.")
        }
        try ScanRecipePresetStore.validateRecipes(capture: job.capture, output: job.outputs)
        job.frames.sort()
        return job
    }

    public func normalizedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
