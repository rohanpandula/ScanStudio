import AppKit
import SwiftUI

extension Color {
    static let scanStudioWorkspace = Color(red: 0.078, green: 0.086, blue: 0.094)
    static let scanStudioSidebar = Color(red: 0.110, green: 0.122, blue: 0.133)
    static let scanStudioInspector = Color(red: 0.110, green: 0.122, blue: 0.133)
    static let scanStudioRaised = Color(red: 0.141, green: 0.153, blue: 0.169)
    static let scanStudioDivider = Color.white.opacity(0.10)
    static let scanStudioPrimaryText = Color(red: 0.933, green: 0.945, blue: 0.949)
    static let scanStudioSecondaryText = Color(red: 0.604, green: 0.639, blue: 0.659)
    static let scanStudioAmber = Color(red: 0.910, green: 0.639, blue: 0.239)
    static let scanStudioCyan = Color(red: 0.310, green: 0.788, blue: 0.851)
    static let scanStudioRed = Color(red: 0.839, green: 0.271, blue: 0.271)
    static let scanStudioGreen = Color(red: 0.247, green: 0.749, blue: 0.435)
    static let scanStudioRowLabel = Color.white.opacity(0.70)
    static let scanStudioSectionHeaderText = Color.white.opacity(0.55)
}

/// Shared corner-radius constants for the mockup token system. `cardCornerRadius`
/// covers UI-SPEC's 8-10px card/button range; `thumbnailCornerRadius` is the
/// spec's thumbnail-specific radius. Defined once here so Plans 02/03's grid
/// tiles and card shapes don't each invent their own numbers.
enum ScanStudioMetrics {
    static let cardCornerRadius: CGFloat = 9
    static let thumbnailCornerRadius: CGFloat = 6
    /// A forgiving minimum target for the app's compact icon and alignment
    /// controls. macOS controls can look visually smaller while their actual
    /// clickable area remains comfortably reachable.
    static let minimumInteractiveTarget: CGFloat = 40
}

struct ScanStudioDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.scanStudioDivider)
            .frame(width: 1)
    }
}

struct SectionEyebrow: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.scanStudioSectionHeaderText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Small status-style trailing pill (e.g. the MEDIA section's cyan "Active"
/// tag) — an uppercased, bolded capsule with a tinted fill and matching
/// hairline stroke.
struct InlineTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
    }
}

struct StatusPill: View {
    let label: String
    let color: Color
    var symbol: String = "circle.fill"

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

/// Deterministic simulated preview frames. These are generated image content,
/// not crops from the old workspace screenshot: that asset contained its own
/// selection borders, checkmarks, and frame labels, which made simulator
/// thumbnails falsely look selected before the current UI had made a choice.
/// They are only ever requested for a simulator-shaped thumbnail (see
/// `ThumbnailTileImage`), never for real hardware.
@MainActor
enum SimulatedRollFrames {
    static let images: [Int: NSImage] = Dictionary(
        uniqueKeysWithValues: (1...36).map { ($0, makeImage(frameIndex: $0)) }
    )

    private static func makeImage(frameIndex: Int) -> NSImage {
        let size = NSSize(width: 480, height: 320)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let phase = CGFloat((frameIndex * 37) % 100) / 100
        let base = NSColor(
            calibratedRed: 0.20 + phase * 0.16,
            green: 0.17 + phase * 0.10,
            blue: 0.10 + phase * 0.08,
            alpha: 1
        )
        let highlight = NSColor(
            calibratedRed: min(base.redComponent + 0.20, 1),
            green: min(base.greenComponent + 0.16, 1),
            blue: min(base.blueComponent + 0.12, 1),
            alpha: 1
        )
        NSGradient(starting: base, ending: highlight)?.draw(in: NSRect(origin: .zero, size: size), angle: 22)

        NSColor.black.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: 45, y: 36, width: 390, height: 248), xRadius: 34, yRadius: 34).fill()
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: NSRect(x: 94 + phase * 70, y: 92, width: 202, height: 126)).fill()
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(ovalIn: NSRect(x: 248 - phase * 42, y: 112, width: 122, height: 82)).fill()
        return image
    }
}

struct SimulatedFrameImage: View {
    let frameIndex: Int
    var isAvailable = true
    /// DEF-05 "Show as positive": the contact sheet's toggle applies to
    /// simulator tiles too, not just real ones — this routes the same
    /// bundled crop through `ThumbnailImageCache`'s shared conversion path
    /// (`PositivePreviewRenderer`) rather than skipping simulated tiles.
    var displayMode: ThumbnailDisplayMode = .asScanned

    var body: some View {
        Group {
            if isAvailable, let image = displayedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.black.opacity(0.34)
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Color.scanStudioSecondaryText.opacity(0.55))
                }
            }
        }
        .clipped()
    }

    private var displayedImage: NSImage? {
        ThumbnailImageCache.image(forKey: "sim-frame-\(frameIndex)", mode: displayMode) {
            SimulatedRollFrames.images[frameIndex]
        }
    }
}
