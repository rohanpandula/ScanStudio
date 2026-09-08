import CoreGraphics
import Foundation
import ImageIO

/// 8-bit luminance extraction feeding `BlankFrameHint`. `ImageIO`/
/// `CoreGraphics` only — **no `AppKit`** — so this stays usable from a
/// headless host with no window server. This is the small `ImageIO`-based
/// decoder `PositivePreviewMath.swift`'s own doc comment anticipates: pure
/// math lives in `ScanStudioKit`, the AppKit/`NSImage`-specific glue
/// (`ThumbnailImageCache`, `ThumbnailGridView.swift`) stays in the `ScanStudio`
/// app target and is not reachable here.
///
/// Every failure path in this type returns `nil` — never throws, never
/// logs, never retries. A bridge-written preview tile can be unreadable,
/// truncated, or still being written; the only correct response is "no hint
/// for this frame," not a crash or a fabricated number (T-03-31/T-03-32).
public enum ThumbnailLuminance {
    /// Population mean/stddev (03-BLANK-HINT.md step 1-2) of the central 80%
    /// crop of an 8-bit single-channel buffer — 10% dropped off every side
    /// so sprocket/edge bleed never counts. `nil` for an empty, zero-sized,
    /// or size-inconsistent buffer, or a crop that degenerates to nothing —
    /// never a fabricated zero.
    public static func statistics(
        centralCropOf pixels: [UInt8],
        width: Int,
        height: Int
    ) -> (mean: Double, stddev: Double)? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        let marginX = width / 10
        let marginY = height / 10
        let cropWidth = width - 2 * marginX
        let cropHeight = height - 2 * marginY
        guard cropWidth > 0, cropHeight > 0 else { return nil }

        var sum = 0.0
        var sampleCount = 0
        for row in marginY..<(marginY + cropHeight) {
            let rowStart = row * width + marginX
            for column in 0..<cropWidth {
                sum += Double(pixels[rowStart + column])
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return nil }
        let mean = sum / Double(sampleCount)

        var varianceSum = 0.0
        for row in marginY..<(marginY + cropHeight) {
            let rowStart = row * width + marginX
            for column in 0..<cropWidth {
                let delta = Double(pixels[rowStart + column]) - mean
                varianceSum += delta * delta
            }
        }
        let stddev = (varianceSum / Double(sampleCount)).squareRoot()
        return (mean: mean, stddev: stddev)
    }

    /// Decodes an arbitrary image file (the bridge's own preview tile path,
    /// `Thumbnail.imagePath`) into an 8-bit grayscale luminance buffer via
    /// `CGImageSourceCreateWithURL`/`CGImageSourceCreateImageAtIndex`, then a
    /// single draw into an 8-bit `CGColorSpaceCreateDeviceGray()` context.
    /// `nil` for a missing/unreadable file, an undecodable image, or a
    /// context that can't be created — no throw, no log, no retry.
    public static func decodeLuminance(
        atPath path: String
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        let url = URL(fileURLWithPath: path)
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels: buffer, width: width, height: height)
    }
}
