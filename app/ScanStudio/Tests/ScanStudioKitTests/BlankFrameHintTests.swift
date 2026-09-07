// Synthetic-bitmap calibration proof for `BlankFrameHint`/`ThumbnailLuminance`
// against 03-BLANK-HINT.md's own formula, constants, and 40-frame fixture
// table. Every buffer here is synthesized in code -- never a committed
// image, never the owner's own preview thumbnails, per that document's own
// "Test fixtures" rule.

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ScanStudioKit

@Suite("Blank frame hint")
struct BlankFrameHintTests {
    static let width = 143
    static let height = 96

    /// A uniform single-channel buffer of the given value, `width x height`.
    static func uniformBuffer(_ value: UInt8, width: Int = width, height: Int = height) -> [UInt8] {
        Array(repeating: value, count: width * height)
    }

    @Test("a uniform 203-gray buffer scores flatness == 1.00")
    func uniformGrayScoresFullFlatness() throws {
        let buffer = Self.uniformBuffer(203)
        let stats = try #require(ThumbnailLuminance.statistics(centralCropOf: buffer, width: Self.width, height: Self.height))
        #expect(abs(stats.mean - 203) < 0.001)
        #expect(abs(stats.stddev) < 0.001)
        #expect(BlankFrameHint.flatness(stddev: stats.stddev) == 1.0)
    }

    @Test("uniform gray with deterministic +/-3 noise still scores flatness >= 0.9")
    func noisyUniformGrayStaysNearlyFlat() throws {
        var buffer = [UInt8](repeating: 0, count: Self.width * Self.height)
        for row in 0..<Self.height {
            for column in 0..<Self.width {
                // A deterministic checkerboard of 197/203 around a mean of
                // 200 -- every sample deviates from the mean by exactly 3,
                // giving a known, small population stddev.
                buffer[row * Self.width + column] = (row + column).isMultiple(of: 2) ? 197 : 203
            }
        }
        let stats = try #require(ThumbnailLuminance.statistics(centralCropOf: buffer, width: Self.width, height: Self.height))
        let flatness = BlankFrameHint.flatness(stddev: stats.stddev)
        #expect(flatness >= 0.9)
    }

    @Test("a horizontal gradient (stddev far above the flatness ceiling) scores flatness == 0.00")
    func texturedGradientScoresZeroFlatness() throws {
        var buffer = [UInt8](repeating: 0, count: Self.width * Self.height)
        for row in 0..<Self.height {
            for column in 0..<Self.width {
                let value = Double(column) / Double(Self.width - 1) * 255.0
                buffer[row * Self.width + column] = UInt8(value.rounded())
            }
        }
        let stats = try #require(ThumbnailLuminance.statistics(centralCropOf: buffer, width: Self.width, height: Self.height))
        // Not asserting the exact "~40" figure 03-BLANK-HINT.md's prose
        // uses for this fixture shape -- only that it clears the flatness
        // ceiling comfortably, which is the actual thing this test proves.
        #expect(stats.stddev > BlankFrameHint.flatnessCeilingStddev)
        #expect(BlankFrameHint.flatness(stddev: stats.stddev) == 0.0)
    }

    @Test("statistics crops the outer 10% border -- a black border around a uniform 203 center reads as mean ~203, stddev ~0")
    func statisticsDropsTheBorderRatherThanAveragingIt() throws {
        var buffer = [UInt8](repeating: 0, count: Self.width * Self.height)
        let marginX = Self.width / 10
        let marginY = Self.height / 10
        for row in marginY..<(Self.height - marginY) {
            for column in marginX..<(Self.width - marginX) {
                buffer[row * Self.width + column] = 203
            }
        }
        let stats = try #require(ThumbnailLuminance.statistics(centralCropOf: buffer, width: Self.width, height: Self.height))
        #expect(abs(stats.mean - 203) < 0.001)
        #expect(abs(stats.stddev) < 0.001)
    }

    /// A synthetic 40-frame roll (03-BLANK-HINT.md's own "Test fixtures"
    /// paragraph): only the last two frames (39, 40) are uniform/blank;
    /// every other frame is textured. Deliberately different from the real
    /// calibration table (whose blanks sit at 37/38) -- this shape is
    /// chosen purely to make the tail-pair/mid-roll/positional-prior
    /// assertions below simple to construct and verify independently.
    @Test("the synthetic 40-frame fixture: a uniform tail pair scores >= 0.8, and the positional prior moves a fixed stddev-13 frame from ~0.25 to ~0.35")
    func syntheticFortyFrameRollMatchesFixtureNumbers() throws {
        var roll: [Int: (mean: Double, stddev: Double)] = [:]
        for index in 1...40 {
            roll[index] = (mean: 80.0, stddev: 35.0) // textured filler
        }
        roll[20] = (mean: 60.0, stddev: 13.0) // mid-roll, no bonus expected
        roll[39] = (mean: 203.0, stddev: 0.5)
        roll[40] = (mean: 203.0, stddev: 0.5)

        let scores = BlankFrameHint.score(statistics: roll, previewedFrameCount: 40)

        let frame39 = try #require(scores[39])
        let frame40 = try #require(scores[40])
        #expect(frame39.blankConfidence >= 0.8)
        #expect(frame40.blankConfidence >= 0.8)

        let midRoll = try #require(scores[20])
        #expect(midRoll.endBonus == 0)
        #expect(midRoll.runBonus == 0)
        #expect(abs(midRoll.blankConfidence - 0.25) < 0.01)

        // The same stddev-13 frame, now placed at the tail (frame 37, inside
        // the last 10% of 40) next to a flat neighbour (frame 38) -- a
        // separate roll so it cannot interact with the tail pair above.
        var tailRoll: [Int: (mean: Double, stddev: Double)] = [:]
        for index in 1...40 {
            tailRoll[index] = (mean: 80.0, stddev: 35.0)
        }
        tailRoll[37] = (mean: 60.0, stddev: 13.0)
        tailRoll[38] = (mean: 203.0, stddev: 0.5)
        let tailScores = BlankFrameHint.score(statistics: tailRoll, previewedFrameCount: 40)
        let tailFrame = try #require(tailScores[37])
        #expect(tailFrame.endBonus == 0.2)
        #expect(tailFrame.runBonus == 0.2)
        #expect(abs(tailFrame.blankConfidence - 0.35) < 0.01)
    }

    @Test("a decodeLuminance round trip through a synthesized uniform-203 PNG matches the direct-buffer score")
    func decodeLuminanceRoundTripMatchesDirectBuffer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("uniform203.png")

        let buffer = Self.uniformBuffer(203)
        var writeBuffer = buffer
        let context = try #require(CGContext(
            data: &writeBuffer,
            width: Self.width,
            height: Self.height,
            bitsPerComponent: 8,
            bytesPerRow: Self.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let sourceImage = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(fileURL as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sourceImage, nil)
        #expect(CGImageDestinationFinalize(destination))

        let decoded = try #require(ThumbnailLuminance.decodeLuminance(atPath: fileURL.path))
        let decodedStats = try #require(ThumbnailLuminance.statistics(centralCropOf: decoded.pixels, width: decoded.width, height: decoded.height))
        let directStats = try #require(ThumbnailLuminance.statistics(centralCropOf: buffer, width: Self.width, height: Self.height))
        #expect(abs(decodedStats.mean - directStats.mean) < 1e-6)
        #expect(abs(decodedStats.stddev - directStats.stddev) < 1e-6)
        #expect(BlankFrameHint.flatness(stddev: decodedStats.stddev) == 1.0)
    }

    @Test("the 0.8 default threshold's own boundary cases: a flatness-0.6 tail frame with a flat neighbour is skipped (0.84), frame 10's real 0.36 is not")
    func thresholdBoundaryCasesFromTheCalibrationTable() throws {
        var roll: [Int: (mean: Double, stddev: Double)] = [:]
        for index in 1...40 {
            roll[index] = (mean: 80.0, stddev: 35.0)
        }
        // Frame 10, using the real calibration table's own measured numbers
        // (mean 54.6, stddev 11.7 -> flatness ~0.358 -> blankConfidence 0.36
        // with no bonus, since neighbours 9/11 are textured and it is nowhere
        // near either end of a 40-frame roll).
        roll[10] = (mean: 54.6, stddev: 11.7)
        // A flatness-0.6 frame (stddev 8.8) at the tail (index 38, inside
        // the last 10% of 40) next to a flat neighbour (39) -- the exact
        // boundary case 03-BLANK-HINT.md names: 0.6 * (1 + 0.2 + 0.2) = 0.84.
        roll[38] = (mean: 70.0, stddev: 8.8)
        roll[39] = (mean: 203.0, stddev: 0.5)

        let scores = BlankFrameHint.score(statistics: roll, previewedFrameCount: 40)

        let frame10 = try #require(scores[10])
        #expect(abs(frame10.blankConfidence - 0.36) < 0.01)
        #expect(frame10.blankConfidence < BlankFrameHint.defaultSkipThreshold)

        let frame38 = try #require(scores[38])
        #expect(abs(frame38.blankConfidence - 0.84) < 0.01)
        #expect(frame38.blankConfidence >= BlankFrameHint.defaultSkipThreshold)
    }
}
