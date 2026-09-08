import Foundation

public enum PreviewDerivedExposurePolicy {
    public static let source = "previewThumbnailMean"
    public static let minimumRaw10ns = 50_000
    public static let maximumRaw10ns = 400_000

    public enum Refusal: Error, Equatable, Sendable {
        case missingEvidence(Int)
        case blank(Int)
        case ambiguous(Int)
        case invalidReference
    }

    public struct Evidence: Codable, Equatable, Sendable {
        public let frameIndex: Int
        public let thumbnailMean: Double?
        public let thumbnailStddev: Double?
        public let blankConfidence: Double?
        public let needsApproval: Bool

        public init(
            frameIndex: Int,
            thumbnailMean: Double?,
            thumbnailStddev: Double?,
            blankConfidence: Double?,
            needsApproval: Bool
        ) {
            self.frameIndex = frameIndex
            self.thumbnailMean = thumbnailMean
            self.thumbnailStddev = thumbnailStddev
            self.blankConfidence = blankConfidence
            self.needsApproval = needsApproval
        }
    }

    /// AUTO12 uses the roll-wide capture geometry. Existing frame overrides
    /// may still be retained when their geometry matches; only exposure is
    /// replaced by the derived value.
    public static func hasCompatibleCaptureGeometry(
        _ frame: CaptureRecipe,
        with roll: CaptureRecipe
    ) -> Bool {
        frame.resolutionDpi == roll.resolutionDpi
            && frame.bitDepth == roll.bitDepth
            && frame.multisamplePasses == roll.multisamplePasses
            && frame.channels == roll.channels
    }

    public static func referenceFrame(in evidence: [Evidence]) throws -> Int {
        guard !evidence.isEmpty,
              Set(evidence.map(\.frameIndex)).count == evidence.count,
              evidence.allSatisfy({ 1...40 ~= $0.frameIndex }) else {
            throw Refusal.invalidReference
        }
        let validated = try evidence.map { item -> (Int, Double) in
            guard let mean = item.thumbnailMean,
                  let stddev = item.thumbnailStddev,
                  let blankConfidence = item.blankConfidence,
                  mean.isFinite, mean > 0, mean <= 255,
                  stddev.isFinite, stddev > 0, stddev <= 255,
                  blankConfidence.isFinite, 0...1 ~= blankConfidence else {
                throw Refusal.missingEvidence(item.frameIndex)
            }
            guard blankConfidence < BlankFrameHint.defaultSkipThreshold else {
                throw Refusal.blank(item.frameIndex)
            }
            guard !item.needsApproval else {
                throw Refusal.ambiguous(item.frameIndex)
            }
            return (item.frameIndex, mean)
        }
        return validated.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
        }[validated.count / 2].0
    }

    public static func adjustments(
        evidence: [Evidence],
        referenceFrameIndex: Int,
        referenceRGBRaw10ns: [Int]
    ) throws -> [Int: PreviewExposureAdjustment] {
        guard referenceRGBRaw10ns.count == 3,
              referenceRGBRaw10ns.allSatisfy({ minimumRaw10ns...maximumRaw10ns ~= $0 }),
              let reference = evidence.first(where: { $0.frameIndex == referenceFrameIndex }),
              let referenceMean = reference.thumbnailMean,
              referenceMean.isFinite, referenceMean > 0 else {
            throw Refusal.invalidReference
        }
        _ = try referenceFrame(in: evidence)
        let channels = ["R", "G", "B"]
        return try Dictionary(uniqueKeysWithValues: evidence.map { item in
            guard let mean = item.thumbnailMean, mean.isFinite, mean > 0 else {
                throw Refusal.missingEvidence(item.frameIndex)
            }
            let requestedEV = max(0, log2(referenceMean / mean))
            let appliedEV = min(1, requestedEV)
            let scale = pow(2, appliedEV)
            var clamped: [String] = []
            let applied = zip(channels, referenceRGBRaw10ns).map { channel, baseline in
                let requested = Int((Double(baseline) * scale).rounded())
                let bounded = min(maximumRaw10ns, max(minimumRaw10ns, requested))
                if bounded != requested { clamped.append(channel) }
                return bounded
            }
            return (item.frameIndex, PreviewExposureAdjustment(
                referenceFrameIndex: referenceFrameIndex,
                referenceThumbnailMean: referenceMean,
                frameThumbnailMean: mean,
                requestedPositiveEv: requestedEV,
                appliedPositiveEv: appliedEV,
                referenceRgbExposuresRaw10ns: referenceRGBRaw10ns,
                appliedRgbExposuresRaw10ns: applied,
                deviceBoundClampedChannels: clamped
            ))
        })
    }
}
