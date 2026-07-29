// Unit tests for the pure, DISPLAY-ONLY negative-to-positive approximation
// math backing the contact sheet's "Show as positive" toggle. The
// AppKit/CGImage plumbing that actually calls this (`PositivePreviewRenderer`
// in `ThumbnailGridView.swift`) lives in the `ScanStudio` executable
// target, which this test target cannot import (see Package.swift) --
// that glue is UI-only wiring, untestable in this harness.

import Testing

@testable import ScanStudioKit

@Suite("Positive preview math")
struct PositivePreviewMathTests {
    @Test("invertSample is its own inverse for every boundary and midpoint value")
    func invertSampleIsInvolutive() {
        for value: UInt8 in [0, 1, 127, 128, 254, 255] {
            #expect(PositivePreviewMath.invertSample(PositivePreviewMath.invertSample(value)) == value)
        }
    }

    @Test("invertSample maps the two extremes exactly")
    func invertSampleMapsExtremes() {
        #expect(PositivePreviewMath.invertSample(0) == 255)
        #expect(PositivePreviewMath.invertSample(255) == 0)
        #expect(PositivePreviewMath.invertSample(128) == 127)
    }

    @Test("percentileBounds on an empty sample array is a no-op stretch (0, 255) rather than dividing by zero")
    func percentileBoundsEmptyArrayIsNoOp() {
        let bounds = PositivePreviewMath.percentileBounds([], percentile: 0.5)
        #expect(bounds.low == 0)
        #expect(bounds.high == 255)
    }

    @Test("percentileBounds on a single-value array collapses low and high to that same value")
    func percentileBoundsSingleValueCollapses() {
        let bounds = PositivePreviewMath.percentileBounds([42], percentile: 10)
        #expect(bounds.low == 42)
        #expect(bounds.high == 42)
    }

    @Test("percentileBounds at 0% returns the true min/max of the sample array")
    func percentileBoundsZeroPercentReturnsMinMax() {
        let samples: [UInt8] = [10, 250, 30, 200, 90]
        let bounds = PositivePreviewMath.percentileBounds(samples, percentile: 0)
        #expect(bounds.low == 10)
        #expect(bounds.high == 250)
    }

    @Test("percentileBounds clamps any percentile above 50 to 50 (never inverts the stretch direction)")
    func percentileBoundsClampsAboveFifty() {
        let samples: [UInt8] = Array(0...100).map { UInt8($0) }
        let clampedAt50 = PositivePreviewMath.percentileBounds(samples, percentile: 50)
        let overshootTo90 = PositivePreviewMath.percentileBounds(samples, percentile: 90)
        #expect(clampedAt50.low == overshootTo90.low)
        #expect(clampedAt50.high == overshootTo90.high)
        #expect(clampedAt50.low <= clampedAt50.high)
    }

    @Test("percentileBounds clamps any negative percentile to 0")
    func percentileBoundsClampsNegative() {
        let samples: [UInt8] = [10, 250, 30, 200, 90]
        let clampedAtZero = PositivePreviewMath.percentileBounds(samples, percentile: 0)
        let negative = PositivePreviewMath.percentileBounds(samples, percentile: -20)
        #expect(clampedAtZero.low == negative.low)
        #expect(clampedAtZero.high == negative.high)
    }

    @Test("stretch maps low to 0 and high to 255")
    func stretchMapsBoundsToExtremes() {
        #expect(PositivePreviewMath.stretch(50, low: 50, high: 200) == 0)
        #expect(PositivePreviewMath.stretch(200, low: 50, high: 200) == 255)
    }

    @Test("stretch maps the midpoint between low and high to roughly the middle of the output range")
    func stretchMapsMidpointToRoughlyHalf() {
        let midpoint = PositivePreviewMath.stretch(125, low: 50, high: 200)
        #expect(abs(Int(midpoint) - 128) <= 2)
    }

    @Test("stretch clamps values outside low...high to the output extremes instead of wrapping or going negative")
    func stretchClampsOutOfBandValues() {
        #expect(PositivePreviewMath.stretch(0, low: 50, high: 200) == 0)
        #expect(PositivePreviewMath.stretch(255, low: 50, high: 200) == 255)
    }

    @Test("stretch is a pass-through for a degenerate flat channel (low >= high) rather than dividing by zero")
    func stretchPassesThroughDegenerateChannel() {
        #expect(PositivePreviewMath.stretch(77, low: 100, high: 100) == 77)
        #expect(PositivePreviewMath.stretch(77, low: 150, high: 100) == 77)
    }

    @Test("applyToChannel on a uniform (flat) channel inverts every sample and leaves it there — the degenerate stretch (low == high) is a passthrough of the already-inverted value, not the original")
    func applyToChannelUniformChannelInvertsWithDegenerateStretch() {
        let samples: [UInt8] = Array(repeating: 100, count: 16)
        let expected = Array(repeating: PositivePreviewMath.invertSample(100), count: 16)
        #expect(PositivePreviewMath.applyToChannel(samples) == expected)
    }

    @Test("applyToChannel darkens what was brightest in the source (an orange mask's bright channel becomes the darkest after invert-and-stretch)")
    func applyToChannelInvertsRelativeOrdering() {
        // A tiny, varied channel: the darkest raw (as-scanned) sample should
        // become the brightest displayed sample, and vice versa -- this is
        // the actual "invert" effect a real orange-mask negative relies on,
        // expressed as a same-shape ordering check rather than exact bytes
        // (the percentile stretch legitimately shifts absolute values).
        let samples: [UInt8] = [20, 60, 100, 140, 180, 220]
        let result = PositivePreviewMath.applyToChannel(samples, percentile: 0)
        #expect(result.first! > result.last!)
    }

    @Test("applyToChannel output samples always stay within the valid UInt8 display range")
    func applyToChannelStaysInByteRange() {
        let samples: [UInt8] = (0..<64).map { UInt8(($0 * 37) % 256) }
        let result = PositivePreviewMath.applyToChannel(samples, percentile: 1)
        #expect(result.count == samples.count)
        // UInt8 is already bounded 0...255 by its own type; this asserts
        // the pipeline never traps/crashes across a spread of inputs
        // rather than re-asserting the type system's own guarantee.
        #expect(result.allSatisfy { $0 >= 0 && $0 <= 255 })
    }

    @Test("applyToChannel on an empty array returns an empty array")
    func applyToChannelEmptyArrayStaysEmpty() {
        #expect(PositivePreviewMath.applyToChannel([]).isEmpty)
    }
}
