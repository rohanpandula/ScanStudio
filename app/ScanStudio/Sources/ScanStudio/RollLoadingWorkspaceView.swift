import ScanStudioKit
import SwiftUI

/// A truthful, event-driven loading surface for the slow part of importing
/// film. Each cell becomes available only after the engine emits that
/// frame's `scanner.thumbnail` event.
struct CarrierLoadingWorkspaceView: View {
    @Environment(SessionModel.self) private var sessionModel

    /// A real preview has no total until its final status. While frames are
    /// streaming, render only the observed range instead of claiming a
    /// 35 mm roll has a predetermined exposure count.
    private var knownFrameCount: Int? {
        sessionModel.status?.frameCount.flatMap { $0 > 0 ? $0 : nil }
    }
    private var frameCount: Int { knownFrameCount ?? max(sessionModel.thumbnailCount, 1) }
    private var hasKnownFrameCount: Bool { knownFrameCount != nil }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: frameCount == 1 ? 1 : min(frameCount, 6))
    }
    private var loadedCount: Int { min(sessionModel.thumbnailCount, frameCount) }
    private var currentFrame: Int { hasKnownFrameCount ? min(loadedCount + 1, frameCount) : 0 }
    private var percentComplete: Int {
        Int((Double(loadedCount) / Double(frameCount) * 100).rounded())
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)

            ScrollView {
                VStack(spacing: 16) {
                    loadingStatusCard
                    frameGrid
                    frameRail

                    Text(loadingExplanation)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
        .background(Color.scanStudioWorkspace)
        .accessibilityElement(children: .contain)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Loading \(sessionModel.carrierDisplayName.lowercased())")
                    .font(.system(size: 17, weight: .semibold))
                Text("Reading and indexing frame previews")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }

            Spacer()

            Text(hasKnownFrameCount ? "\(loadedCount) / \(frameCount)" : "\(loadedCount) found")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.scanStudioAmber)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private var loadingStatusCard: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.scanStudioAmber.opacity(0.12))
                Image(systemName: "film.stack")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Color.scanStudioAmber)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(loadedCount == 0 ? "Preparing the film path" : (hasKnownFrameCount ? "Reading frame \(currentFrame)" : "Reading frame previews"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if hasKnownFrameCount {
                        Text("\(percentComplete)%")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(Color.scanStudioAmber)
                            .contentTransition(.numericText())
                    } else {
                        Text("Detecting count")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.scanStudioAmber)
                    }
                }

                if hasKnownFrameCount {
                    ProgressView(value: Double(loadedCount), total: Double(frameCount))
                        .tint(.scanStudioAmber)
                } else {
                    ProgressView()
                        .tint(.scanStudioAmber)
                }

                Text(hasKnownFrameCount
                    ? "\(loadedCount) frames ready · \(frameCount - loadedCount) remaining"
                    : "\(loadedCount) frame\(loadedCount == 1 ? "" : "s") found so far")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .contentTransition(.numericText())
            }
        }
        .padding(14)
        .background(Color.scanStudioRaised.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hasKnownFrameCount
            ? "Loading roll, \(loadedCount) of \(frameCount) frames ready, \(percentComplete) percent"
            : "Loading roll, \(loadedCount) frames found so far; total not established")
    }

    private var frameGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(1...frameCount, id: \.self) { frameIndex in
                RollLoadingFrameCell(
                    frameIndex: frameIndex,
                    thumbnail: sessionModel.thumbnails[frameIndex],
                    isCurrent: currentFrame > 0 && frameIndex == currentFrame && loadedCount < frameCount,
                    orientationDegrees: sessionModel.frameOrientation(frameIndex),
                    mirrored: sessionModel.frameMirror(frameIndex)
                )
            }
        }
        .frame(maxWidth: frameCount == 1 ? 420 : .infinity)
        .animation(.easeOut(duration: 0.2), value: loadedCount)
    }

    private var frameRail: some View {
        GeometryReader { proxy in
            let spacing = CGFloat(2)
            let segmentWidth = max(4, (proxy.size.width - spacing * CGFloat(frameCount - 1)) / CGFloat(frameCount))

            HStack(spacing: spacing) {
                ForEach(1...frameCount, id: \.self) { frameIndex in
                    Capsule()
                        .fill(railColor(for: frameIndex))
                        .frame(width: segmentWidth)
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func railColor(for frameIndex: Int) -> Color {
        if sessionModel.thumbnails[frameIndex] != nil { return .scanStudioCyan }
        if currentFrame > 0 && frameIndex == currentFrame { return .scanStudioAmber }
        return Color.white.opacity(0.10)
    }

    private var loadingExplanation: String {
        switch sessionModel.loadedCarrier {
        case .mounted:
            "The scanner is reading the mounted slide. Keep the holder inserted until its preview appears."
        case .strip6:
            "The scanner advances the strip one frame at a time. This can take about a minute on real hardware."
        case .roll36:
            "The scanner advances the roll one frame at a time. This can take 1–2 minutes on real hardware."
        case .none:
            "The scanner is reading the film holder. Keep it inserted until every preview is ready."
        }
    }
}

private struct RollLoadingFrameCell: View {
    let frameIndex: Int
    let thumbnail: Thumbnail?
    let isCurrent: Bool
    /// Session-local display rotation, kept in sync with the contact sheet
    /// — see `ThumbnailTileImage.orientationDegrees`.
    let orientationDegrees: Int
    /// Session-local horizontal mirror, kept in sync with the contact sheet.
    let mirrored: Bool

    /// Whether the engine has reported ANY preview for this frame yet —
    /// real or simulated. This carries no real-vs-simulated meaning on its
    /// own (unlike `ThumbnailTileImage`'s internal availability check) —
    /// it only drives the checkmark/"READING" branch below, exactly as
    /// `isLoaded` did before this type carried the full `Thumbnail` instead
    /// of a bare bool.
    private var isLoaded: Bool { thumbnail != nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 2026-07-26 fix: this used to be an unconditional
            // `SimulatedFrameImage(frameIndex:, isAvailable: isLoaded)`,
            // which shows the bundled MOCKUP crop art the instant ANY
            // thumbnail arrives — it never looked at a real backend's
            // `imagePath` at all. On real hardware, every cell in this grid
            // therefore "loaded" into unrelated demo-roll art for the
            // entire acquisition pass (per `loadingExplanation` below, up
            // to 1-2 minutes for a full roll), only swapping to the actual
            // scanner preview once this screen hands off to
            // `ThumbnailGridView` — exactly the "simulated art flashes
            // before the real preview replaces it" bug the owner reported
            // live. `ThumbnailTileImage` (ThumbnailGridView.swift) already
            // gets this right — the real image when it's loadable, the
            // bundled crop only for a genuinely simulator-shaped thumbnail,
            // a neutral placeholder otherwise — so it's reused here instead
            // of re-deriving that same real-vs-simulated distinction a
            // second, easy-to-drift-out-of-sync time.
            ThumbnailTileImage(frameIndex: frameIndex, thumbnail: thumbnail, orientationDegrees: orientationDegrees, mirrored: mirrored)

            LinearGradient(
                colors: [.black.opacity(0.56), .clear],
                startPoint: .top,
                endPoint: .center
            )

            Text(String(format: "%02d", frameIndex))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(5)

            if isLoaded {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black.opacity(0.84), Color.scanStudioGreen)
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(5)
                    .transition(.opacity.combined(with: .scale(scale: 0.25)))
            } else if isCurrent {
                VStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.scanStudioAmber)
                    Text("READING")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Color.scanStudioAmber)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .background(Color.black.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: ScanStudioMetrics.thumbnailCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ScanStudioMetrics.thumbnailCornerRadius)
                .stroke(isCurrent ? Color.scanStudioAmber : Color.white.opacity(isLoaded ? 0.13 : 0.07), lineWidth: isCurrent ? 2 : 1)
        }
        .animation(.easeOut(duration: 0.2), value: isLoaded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frame \(frameIndex), \(isLoaded ? "ready" : (isCurrent ? "reading" : "waiting"))")
    }
}
