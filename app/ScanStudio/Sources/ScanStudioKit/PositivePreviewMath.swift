// Pure, CONTACT-SHEET-ONLY negative-to-positive approximation math for the
// contact sheet's "Show as positive" toggle (`ThumbnailGridView`). Never
// touches capture data or written outputs -- this only affects what a tile
// looks like on screen. Kept pure and Foundation-only (no AppKit/CGImage
// dependency) so it is directly unit-testable from `ScanStudioKitTests`;
// the AppKit-specific pixel-buffer plumbing that calls into this lives in
// `ThumbnailGridView.swift` (the `ScanStudio` executable target, which this
// test target cannot import).

import Foundation

/// Two independent steps mirror what a proper negative-to-positive
/// conversion does approximately and cheaply enough to run per-tile at
/// render time:
///   1. Invert every sample (`255 - value` per 8-bit channel).
///   2. Per-channel percentile stretch ("neutralize the orange mask"):
///      each channel is independently rescaled so its own low-percentile
///      sample maps to 0 and its own high-percentile sample maps to 255,
///      clamped -- this is what pulls the orange base's channel-specific
///      cast back toward neutral gray without any per-stock calibration
///      data, at the cost of being an approximation, never colorimetric.
public enum PositivePreviewMath {
    /// Inverts a single 8-bit sample. Pure, total, and its own inverse:
    /// `invertSample(invertSample(x)) == x` for every `UInt8`.
    public static func invertSample(_ value: UInt8) -> UInt8 {
        255 - value
    }

    /// The per-channel low/high bounds a percentile stretch should map to
    /// 0/255, computed by direct sort (no histogram binning -- tile-sized
    /// sample counts make this cheap enough). `percentile` is clamped to
    /// `0...50` (symmetric: the low bound sits at `percentile`, the high
    /// bound at `100 - percentile`), since anything past the midpoint
    /// would invert the stretch's direction. An empty `samples` input
    /// returns `(0, 255)` (a no-op stretch) rather than dividing by zero or
    /// crashing.
    public static func percentileBounds(_ samples: [UInt8], percentile: Double) -> (low: UInt8, high: UInt8) {
        guard !samples.isEmpty else { return (0, 255) }
        let clampedPercentile = min(max(percentile, 0), 50)
        let sorted = samples.sorted()

        func index(forPercentile p: Double) -> Int {
            let raw = Int((p / 100.0 * Double(sorted.count - 1)).rounded())
            return min(max(raw, 0), sorted.count - 1)
        }

        let low = sorted[index(forPercentile: clampedPercentile)]
        let high = sorted[index(forPercentile: 100 - clampedPercentile)]
        return (low, high)
    }

    /// Rescales one sample so `low` maps to 0 and `high` maps to 255,
    /// clamping the input to `low...high` first so out-of-band samples
    /// saturate rather than wrapping or going negative. A degenerate/flat
    /// channel (`low >= high`, e.g. a solid-color tile) returns the
    /// original value unchanged rather than dividing by zero or amplifying
    /// noise.
    public static func stretch(_ value: UInt8, low: UInt8, high: UInt8) -> UInt8 {
        guard high > low else { return value }
        let clamped = min(max(value, low), high)
        let normalized = Double(clamped - low) / Double(high - low)
        return UInt8((normalized * 255).rounded())
    }

    /// The full per-channel pipeline for one channel's complete sample
    /// array: invert every sample, then percentile-stretch the INVERTED
    /// array by its own bounds. Inversion first is what turns "neutralize
    /// the orange mask" into a same-shape percentile-stretch problem,
    /// since the mask's color cast lands on the inverted (positive-ish)
    /// side, not the as-scanned negative side. `percentile` defaults to a
    /// gentle 0.5% trim on each end (clips only the most extreme outlier
    /// samples), matching a conservative, cheap "auto-levels"-style
    /// stretch rather than an aggressive one.
    public static func applyToChannel(_ samples: [UInt8], percentile: Double = 0.5) -> [UInt8] {
        let inverted = samples.map(invertSample)
        let bounds = percentileBounds(inverted, percentile: percentile)
        return inverted.map { stretch($0, low: bounds.low, high: bounds.high) }
    }
}
