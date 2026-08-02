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
    /// Height claimed by the status card, rail, explanation, and padding
    /// before `ContactSheetLayout` judges whether the tiles fit unscrolled.
    private static let nonGridChromeHeight: Double = 210

    private func columns(forPaneSize size: CGSize) -> [GridItem] {
        let count = ContactSheetLayout.columnCount(
            frameCount: tileCount,
            availableWidth: Double(size.width) - 40,
            availableHeight: Double(size.height) - Self.nonGridChromeHeight,
            spacing: 8
        )
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private func gridMaxWidth(forPaneSize size: CGSize) -> Double {
        let count = Double(columns(forPaneSize: size).count)
        return count * ContactSheetLayout.defaultMaxTileWidth + (count - 1) * 8
    }
    private var loadedCount: Int { min(sessionModel.thumbnailCount, frameCount) }
    private var currentFrame: Int { hasKnownFrameCount ? min(loadedCount + 1, frameCount) : 0 }

    /// The frame the scanner is working on right now, or `nil` once every
    /// known frame has arrived.
    ///
    /// A real preview reports no total until its final status, so
    /// `currentFrame` is 0 for the whole pass and `frameCount` collapses to
    /// the frames already delivered. Before 2026-07-28 that combination left
    /// this screen with no moving element at all for the entire acquisition
    /// — a single static "01" tile while the transport was audibly running.
    /// Carrying the in-flight frame separately fixes that without inventing a
    /// total: this view only renders while `isAcquiringThumbnails`, so one
    /// unfinished frame after the delivered ones is exactly what is true.
    private var inFlightFrame: Int? {
        guard sessionModel.isAcquiringThumbnails else { return nil }
        if hasKnownFrameCount {
            return loadedCount < frameCount ? min(loadedCount + 1, frameCount) : nil
        }
        return loadedCount + 1
    }

    /// Delivered frames plus the in-flight one, so the grid and the rail
    /// agree on how many cells exist.
    private var tileCount: Int { max(frameCount, inFlightFrame ?? 0) }
    /// 1-based frame indices for the grid/rail. A `Range`, not
    /// `1...tileCount` -- that `ClosedRange` traps if `tileCount` is ever
    /// non-positive, and this stays an empty `Range` in that case instead.
    private var tileIndices: Range<Int> {
        tileCount > 0 ? 1..<(tileCount + 1) : 1..<1
    }
    private var percentComplete: Int {
        Int((Double(loadedCount) / Double(frameCount) * 100).rounded())
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)

            GeometryReader { paneProxy in
            ScrollView {
                VStack(spacing: 16) {
                    loadingStatusCard
                    frameGrid(paneSize: paneProxy.size)
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

    private func frameGrid(paneSize: CGSize) -> some View {
        LazyVGrid(columns: columns(forPaneSize: paneSize), spacing: 8) {
            ForEach(tileIndices, id: \.self) { frameIndex in
                RollLoadingFrameCell(
                    frameIndex: frameIndex,
                    thumbnail: sessionModel.thumbnails[frameIndex],
                    isCurrent: frameIndex == inFlightFrame,
                    orientationDegrees: sessionModel.frameOrientation(frameIndex),
                    mirrored: sessionModel.frameMirror(frameIndex)
                )
            }
        }
        .frame(maxWidth: gridMaxWidth(forPaneSize: paneSize))
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: loadedCount)
    }

    private var frameRail: some View {
        GeometryReader { proxy in
            let spacing = CGFloat(2)
            let segmentWidth = max(4, (proxy.size.width - spacing * CGFloat(tileCount - 1)) / CGFloat(tileCount))

            HStack(spacing: spacing) {
                ForEach(tileIndices, id: \.self) { frameIndex in
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
        if frameIndex == inFlightFrame { return .scanStudioAmber }
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
                ZStack {
                    FilmScanSweep()
                    Text("READING")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Color.scanStudioAmber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.42), in: Capsule())
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

/// The activity affordance for a frame the scanner is reading right now: a
/// light bar travelling down the tile, standing in for the sensor's own
/// traverse, over faint sensor rows.
///
/// Deliberately abstract. The tile has no pixels yet, and the previous
/// occupant of this space — bundled mockup crop art — is exactly the "fake
/// imagery on a real device" this project rejects. A sweep claims only that
/// something is moving, which is the one thing that is true here.
///
/// Driven by `TimelineView(.animation)` rather than a `@State` +
/// `repeatForever` pair so the phase is derived from the clock: a
/// `LazyVGrid` recycling this view mid-pass cannot leave it parked.
struct FilmScanSweep: View {
    var accent: Color = .scanStudioAmber

    /// One head traverse. Slow enough to read as deliberate mechanical
    /// motion rather than a spinner's idle churn.
    private let period: Double = 2.1

    /// Sensor-row pitch, in points. Fixed rather than proportional so the
    /// texture reads the same on a 40-frame roll's small tiles as on a
    /// single mounted slide.
    private let rowPitch: Double = 3

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period

            GeometryReader { proxy in
                let height = proxy.size.height
                let band = max(16, height * 0.34)

                ZStack {
                    sensorRows

                    LinearGradient(
                        colors: [accent.opacity(0), accent.opacity(0.5), accent.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: band)
                    .blur(radius: 4)
                    .blendMode(.plusLighter)
                    // Travels from fully clear of the top edge to fully clear
                    // of the bottom one, so the bar is never parked at a
                    // boundary looking like a static rule.
                    .offset(y: -band + (height + band * 2) * phase)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var sensorRows: some View {
        Canvas { context, size in
            var rows = Path()
            var y = 0.0
            while y < size.height {
                rows.move(to: CGPoint(x: 0, y: y))
                rows.addLine(to: CGPoint(x: size.width, y: y))
                y += rowPitch
            }
            context.stroke(rows, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
        }
    }
}
