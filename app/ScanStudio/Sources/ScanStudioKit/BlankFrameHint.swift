import Foundation

/// Calibrated blank/leader-frame confidence heuristic (D-12/HEAD-06).
///
/// Source of truth: `.planning/phases/SSCLI-03-headless-mode-parity/03-BLANK-HINT.md`,
/// calibrated from the attended 2026-09-07 hardware run's own preview thumbnails
/// (frames 37/38 blank leader at `blankConfidence == 1.00`; frame 10, a dark
/// low-contrast exposure, is the highest-scoring non-blank frame at `0.36`).
/// Read that document before touching any number in this type.
///
/// This is a **heuristic**, never a fact: it reports a confidence, and the
/// hint never excludes a frame by itself — only an explicit
/// `frames select --skip-blank` acts on it. All five tunable constants a
/// later roll's own calibration data might need to re-tune live here, in one
/// place, rather than scattered across call sites.
public enum BlankFrameHint {
    /// Population stddev (0-255 luminance scale) at or below which the
    /// central-crop flatness is fully saturated (`flatness == 1.0`).
    public static let flatnessCeilingStddev: Double = 16.0
    /// Width of the linear ramp from `flatnessCeilingStddev` down to
    /// `flatness == 0.0` — i.e. `flatness` reaches zero once stddev grows by
    /// this much past the ceiling.
    public static let flatnessWindowStddev: Double = 12.0
    /// Positional-prior bonus applied when a frame sits in the last 10% or
    /// first 5% of the previewed roll (leader lives at the ends).
    public static let endBonus: Double = 0.2
    /// Positional-prior bonus applied when a numerically adjacent frame
    /// (index - 1 or index + 1) is itself flat (`flatness >= 0.5`) — blank
    /// leader comes in runs.
    public static let runBonus: Double = 0.2
    /// Default `frames select --skip-blank` threshold: a frame with
    /// `blankConfidence` below this value is kept; at or above it, skipped.
    public static let defaultSkipThreshold: Double = 0.8

    /// One frame's reported hint. The wire (`ControlFrameSummary`) reports
    /// `thumbnailMean`/`thumbnailStddev`/`endBonus`/`runBonus`/`blankConfidence`
    /// — never `flatness`, which stays an internal intermediate at full
    /// precision. Every other field is rounded to 2 decimals on
    /// construction, matching 03-BLANK-HINT.md's own calibration table.
    public struct Score: Codable, Equatable, Sendable {
        public let thumbnailMean: Double
        public let thumbnailStddev: Double
        public let flatness: Double
        public let endBonus: Double
        public let runBonus: Double
        public let blankConfidence: Double

        public init(
            thumbnailMean: Double,
            thumbnailStddev: Double,
            flatness: Double,
            endBonus: Double,
            runBonus: Double,
            blankConfidence: Double
        ) {
            self.thumbnailMean = Self.round2(thumbnailMean)
            self.thumbnailStddev = Self.round2(thumbnailStddev)
            self.flatness = flatness
            self.endBonus = Self.round2(endBonus)
            self.runBonus = Self.round2(runBonus)
            self.blankConfidence = Self.round2(blankConfidence)
        }

        private static func round2(_ value: Double) -> Double {
            (value * 100).rounded() / 100
        }
    }

    /// `clamp((flatnessCeilingStddev - stddev) / flatnessWindowStddev, 0, 1)`
    /// — 1.0 at stddev <= 4, 0.0 at stddev >= 16, per 03-BLANK-HINT.md step 2.
    public static func flatness(stddev: Double) -> Double {
        let raw = (flatnessCeilingStddev - stddev) / flatnessWindowStddev
        return min(max(raw, 0), 1)
    }

    /// The whole-roll scoring pass (03-BLANK-HINT.md steps 2-4). Only
    /// indices present in `statistics` (i.e. frames whose thumbnail actually
    /// decoded to a raster) get a `Score` back — an absent key is the honest
    /// "no raster, no hint" answer a caller reports as five `null`s, never a
    /// fabricated number.
    ///
    /// `previewedFrameCount` is the true total previewed-frame count, used
    /// only to size the first-5%/last-10% positional windows. The position
    /// of a given frame within those windows is computed from its **rank in
    /// sorted key order**, not from its raw index value — this is what lets
    /// a 1-based caller (this app's `ProjectFrame.index`) and a 0-based
    /// caller both get the identical window membership: rank is always
    /// `0..<count` regardless of what numbers the keys themselves are.
    /// `runBonus`'s "adjacent frame" check is the opposite: it looks up the
    /// literal `index - 1`/`index + 1` neighbor, because leader runs are a
    /// property of physical adjacency, not of rank.
    ///
    /// The combination `blankConfidence = min(1, flatness * (1 + endBonus +
    /// runBonus))` is **multiplicative on purpose**: a textured frame has
    /// `flatness == 0`, and `0 * anything == 0` — no positional bonus can
    /// ever promote a textured frame to blank. This is the exact property
    /// 03-BLANK-HINT.md's own frames 39/40 (partial frames at the roll's
    /// tail, next to a blank neighbor) depend on: both sit inside the
    /// end/run bonus windows and both still score `0.00`.
    public static func score(
        statistics: [Int: (mean: Double, stddev: Double)],
        previewedFrameCount: Int
    ) -> [Int: Score] {
        let sortedKeys = statistics.keys.sorted()
        let count = sortedKeys.count
        guard count > 0 else { return [:] }

        var flatnessByIndex: [Int: Double] = [:]
        flatnessByIndex.reserveCapacity(count)
        for key in sortedKeys {
            guard let stat = statistics[key] else { continue }
            flatnessByIndex[key] = flatness(stddev: stat.stddev)
        }

        let firstFiveThreshold = Double(previewedFrameCount) * 0.05
        let lastTenThreshold = Double(previewedFrameCount) * 0.10

        var results: [Int: Score] = [:]
        results.reserveCapacity(count)
        for (rank, key) in sortedKeys.enumerated() {
            guard let stat = statistics[key], let frameFlatness = flatnessByIndex[key] else { continue }
            let ordinalFromEnd = count - 1 - rank
            let isNearStart = Double(rank) < firstFiveThreshold
            let isNearEnd = Double(ordinalFromEnd) < lastTenThreshold
            let endBonusValue = (isNearStart || isNearEnd) ? endBonus : 0
            let hasFlatNeighbor = [key - 1, key + 1].contains { neighbor in
                (flatnessByIndex[neighbor] ?? 0) >= 0.5
            }
            let runBonusValue = hasFlatNeighbor ? runBonus : 0
            let confidence = min(1, frameFlatness * (1 + endBonusValue + runBonusValue))
            results[key] = Score(
                thumbnailMean: stat.mean,
                thumbnailStddev: stat.stddev,
                flatness: frameFlatness,
                endBonus: endBonusValue,
                runBonus: runBonusValue,
                blankConfidence: confidence
            )
        }
        return results
    }
}
