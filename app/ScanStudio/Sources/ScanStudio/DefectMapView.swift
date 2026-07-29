import AppKit
import ScanStudioKit
import SwiftUI

/// The three switchable modes `FrameDetailWorkspaceView`'s large preview
/// offers (DEF-01). Exactly one is ever shown at a time — no 50/50
/// comparison. `Final` and `Before Repair` render the identical image (see
/// `FrameDetailWorkspaceView`'s own scope note); `Defect Map` is the only
/// mode that visibly differs, via `DefectOverlayCanvas`.
enum FrameViewingMode: String, CaseIterable {
    case finalPositive, beforeRepair, defectMap

    var label: String {
        switch self {
        case .finalPositive: "Final"
        case .beforeRepair: "Before Repair"
        case .defectMap: "Defect Map"
        }
    }
}

/// Draws every defect's marker (stroked circle for dust, stroked line for
/// scratch) at its normalized [0,1] position scaled to this canvas's own
/// size — red for .willCorrect, amber for .uncertain. Non-interactive
/// (allowsHitTesting(false)): selection/loupe targeting is Plan 05-04's
/// concern, this view only renders.
struct DefectOverlayCanvas: View {
    let defects: [DefectInstance]
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            for defect in defects {
                let color: Color = defect.classification == .willCorrect ? .scanStudioRed : .scanStudioAmber
                let center = CGPoint(x: size.width * defect.centerX, y: size.height * defect.centerY)
                switch defect.kind {
                case .dust:
                    let r = size.width * defect.radius
                    let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2)
                case .scratch:
                    guard let endX = defect.endX, let endY = defect.endY else { continue }
                    let end = CGPoint(x: size.width * endX, y: size.height * endY)
                    var path = Path()
                    path.move(to: center)
                    path.addLine(to: end)
                    context.stroke(path, with: .color(color), lineWidth: max(1.5, size.width * defect.radius * 2))
                }
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true) // the legend + counts (Plan 05-04) carry the accessible summary
    }
}

/// "RED - WILL CORRECT / AMBER - REVIEW" legend, optionally paired with
/// provenance tags (DEF-02 honesty requirement): "Simulated" only when the
/// engine reports simulated data, and "Transport Smear" when hardware
/// telemetry flags reduced repair confidence.
struct DefectMapLegend: View {
    let simulated: Bool
    let transportSmearFlagged: Bool
    let transportSmearReason: String?

    private var accessibilityLabelText: String {
        var label = "Legend: red marks mean will correct, amber marks mean uncertain, review recommended."
        if simulated {
            label += " This is simulated data."
        }
        if transportSmearFlagged {
            label += " Transport smear detected during capture: \(transportSmearReason ?? "reduced repair confidence")."
        }
        return label
    }

    var body: some View {
        HStack(spacing: 10) {
            Label("Will Correct", systemImage: "circle.fill")
                .foregroundStyle(Color.scanStudioRed)
            Label("Uncertain", systemImage: "circle.fill")
                .foregroundStyle(Color.scanStudioAmber)
            Spacer(minLength: 4)
            if simulated {
                InlineTag(text: "Simulated", color: .scanStudioSecondaryText)
            }
            if transportSmearFlagged {
                InlineTag(text: "Transport Smear", color: .scanStudioAmber)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }
}

/// One Dust/Scratches/Uncertain filter toggle (DEF-02) — a capsule pill
/// following `InlineTag`'s established visual language (tinted fill +
/// matching hairline stroke when active), muted when off. `count` is
/// always this chip's OWN full, unfiltered count (dust chip counts dust
/// instances, scratches chip counts scratch instances, uncertain chip
/// counts uncertain-classification instances) — never the post-filter
/// count, so toggling siblings off never makes this chip's own number
/// change out from under it.
struct DefectFilterChip: View {
    let label: String
    let count: Int
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(isOn ? color : Color.scanStudioSecondaryText.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text("\(label) \(count)")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isOn ? color.opacity(0.18) : Color.white.opacity(0.05), in: Capsule())
            .foregroundStyle(isOn ? color : Color.scanStudioSecondaryText)
            .overlay(Capsule().stroke(isOn ? color.opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) filter, \(count) defects, \(isOn ? "shown" : "hidden")")
    }
}

/// Fixed-position 400% magnifier: crops the SAME image source (real
/// backend thumbnail or the simulated concept crop — never a fabricated
/// higher-resolution source) centered on the selected defect's normalized
/// position. Deliberately outside the main preview's own zoom/pan
/// transform (same layer as `zoomControls`/`DefectMapLegend`), so its own
/// magnification is independent of whatever zoom level the user has the
/// main preview at.
struct DefectLoupeView: View {
    let defect: DefectInstance
    let realImage: NSImage?
    let frameIndex: Int
    let isSimulatedAvailable: Bool

    private let size: CGFloat = 132
    private let magnification: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            Group {
                if let realImage {
                    Image(nsImage: realImage).resizable().scaledToFill()
                } else {
                    SimulatedFrameImage(frameIndex: frameIndex, isAvailable: isSimulatedAvailable)
                }
            }
            .frame(width: geo.size.width * magnification, height: geo.size.height * magnification)
            .offset(
                x: -CGFloat(defect.centerX) * geo.size.width * magnification + geo.size.width / 2,
                y: -CGFloat(defect.centerY) * geo.size.height * magnification + geo.size.height / 2
            )
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(defect.classification == .willCorrect ? Color.scanStudioRed : Color.scanStudioAmber, lineWidth: 2))
        .shadow(radius: 6)
        .accessibilityLabel("400 percent loupe on the selected \(defect.kind == .dust ? "dust" : "scratch") defect")
    }
}

/// Shown in place of the overlay/legend when Defect Map mode has nothing
/// to draw because Digital ICE is off for this frame's effective
/// processing recipe — see 05-01-PLAN's PROTOCOL.md note: an empty
/// `defects` array from `analyzeFrameDefects` ALWAYS means this, never
/// "ran and found nothing" (the generator's own minimum count floor is
/// never zero once it runs).
struct DigitalIceOffNotice: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "wand.and.stars.inverse")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.scanStudioSecondaryText)
            Text("Digital ICE is off for this frame")
                .font(.system(size: 13, weight: .semibold))
            Text("Enable it in the Processing section below to see proposed corrections.")
                .font(.system(size: 11))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: 260)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// Shown when Digital ICE analyzed a frame and found nothing to repair —
/// distinct from `DigitalIceOffNotice` so ICE-off and real-and-clean never
/// render the same message.
struct CleanFrameNotice: View {
    let simulated: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.scanStudioSecondaryText)
            Text("No defects detected")
                .font(.system(size: 13, weight: .semibold))
            Text(
                simulated
                    ? "Simulated Digital ICE analysis produced no defects for this frame."
                    : "Digital ICE analyzed this frame and found nothing to repair."
            )
            .font(.system(size: 11))
            .foregroundStyle(Color.scanStudioSecondaryText)
            .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: 260)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
