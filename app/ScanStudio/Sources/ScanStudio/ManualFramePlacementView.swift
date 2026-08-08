import AppKit
import ScanStudioKit
import SwiftUI

/// Modal editor for placing frame boundaries on the whole captured film
/// strip (Rung 4 of the feeding UX ladder,
/// FEEDING-UX-LADDER-OVERNIGHT-20260807.md) -- the "Place frames manually"
/// flow the workspace error card offers whenever a preview refusal carries
/// a Rung-3 probable-cause diagnosis.
///
/// Adapted from an initial draft that assumed a *vertical* strip (row 0 at
/// the top edge, the transport axis running down the image's height). That
/// assumption is backwards for this wire contract: BRIDGE.md is explicit
/// that `PreviewStrip.imagePath` "is rendered through the identical
/// transform `Thumbnail.imagePath` already uses (`swapaxes(0,1)`...)
/// applied once to the whole captured raster... so the raster's row axis
/// (the coordinate space `roll.manualFrames`'s `rows` are given in) is the
/// image's WIDTH axis, not its height, exactly like every existing
/// `Thumbnail` crop already is" -- confirmed against the bridge's own
/// `_normalize_preview_tile` (`np.swapaxes(image, 0, 1)` on an
/// `(rowCount, width, 3)` array before it is ever written to disk). This
/// view is therefore laid out horizontally: row 0 is the LEFT edge, the
/// last row is the RIGHT edge, boundaries are vertical lines the operator
/// drags left/right, and the strip scrolls horizontally rather than
/// vertically. `pixelsPerRow` is always `1` today, so one preview row is
/// exactly one image pixel along that axis.
struct ManualFramePlacementView: View {
    @Environment(SessionModel.self) private var sessionModel
    @Environment(\.dismiss) private var dismiss

    let stripImage: NSImage
    /// How many preview rows the full strip represents. `boundaryRows` are
    /// expressed in this space ("preview row N"), mapped to view X
    /// proportionally so a wide strip that scrolls stays consistent with a
    /// narrow one in the same window.
    let rasterRows: Int
    /// The boundaries seeded for this editor -- equal spacing across the
    /// strip when no better guess exists (see `ManualFramePlacementSheet`).
    /// Empty seeds nothing and leans on the guidance copy.
    let initialBoundaryRows: [Int]

    /// The working set of boundaries. Seeded from `initialBoundaryRows` on
    /// appear (not in `init`, since `@State` cannot be assigned from an
    /// `init` parameter without a wrapper-name rename), and always sorted +
    /// deduplicated so a confirm can never hand the engine a degenerate
    /// (zero- or negative-width, or duplicate) frame.
    @State private var boundaryRows: [Int] = []
    /// The row value of the boundary line currently being dragged. Kept as
    /// a *value* (not an index) because each drag change re-sorts the array
    /// and the dragged line's index moves; the value is stable and the
    /// gesture below anchors on it. `nil` means no drag is in flight.
    @State private var draggingRow: Int?

    /// Cross-strip (display) axis: the strip's own fixed on-screen height.
    /// The transport axis (width) is whatever that implies given the
    /// image's aspect ratio, and is free to be much larger than the
    /// window -- that is exactly what the horizontal scroll is for.
    private static let stripHeight: CGFloat = 240
    private static let stripCoordinateSpace = "ManualFramePlacementStripSpace"
    /// Width of each boundary line's hit region/visual rule.
    private static let lineWidth: CGFloat = 2
    /// Total width of a boundary line's draggable column, wide enough for
    /// its row-number badge and delete control without a hairline-only
    /// drag target.
    private static let lineColumnWidth: CGFloat = 34
    /// Lines closer than this to a click position are treated as the click
    /// landing on the line itself (a grab), not as an add -- see
    /// `addBoundary`.
    private static let duplicateClickThresholdRows = 3

    private var isSubmitting: Bool { sessionModel.isSubmittingManualPlacement }
    private var submitError: String? { sessionModel.manualPlacementSubmitError }

    private var frameCount: Int {
        max(boundaryRows.count - 1, 0)
    }

    private var hasRealRaster: Bool {
        rasterRows > 1
    }

    private var scale: CGFloat {
        guard stripImage.size.height > 0 else { return 1 }
        return Self.stripHeight / stripImage.size.height
    }

    /// The strip's rendered width at `scale` -- this is the coordinate
    /// space every row<->pixel conversion below works in.
    private var renderedWidth: CGFloat {
        max(stripImage.size.width * scale, 1)
    }

    private var invalidBands: [ManualFramePlacementValidation.Band] {
        ManualFramePlacementValidation.bands(for: boundaryRows).filter { !$0.isValid }
    }

    private var canConfirm: Bool {
        !isSubmitting && ManualFramePlacementValidation.blockingReason(for: boundaryRows) == nil
    }

    private var isAtInitialState: Bool {
        boundaryRows == ManualFramePlacementValidation.normalize(initialBoundaryRows)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Color.scanStudioDivider)

            stripArea

            if let submitError {
                Divider().background(Color.scanStudioDivider)
                submitErrorBanner(submitError)
            }

            Divider().background(Color.scanStudioDivider)

            footer
        }
        .background(Color.scanStudioWorkspace)
        .foregroundStyle(Color.scanStudioPrimaryText)
        .frame(width: 880)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            // Seed once. Re-running on every appear (e.g. a later state
            // change) would throw away the operator's current drags, so
            // `boundaryRows` is the source of truth after first run.
            if boundaryRows.isEmpty {
                boundaryRows = ManualFramePlacementValidation.normalize(initialBoundaryRows)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Place Frame Boundaries")
                .font(.system(size: 20, weight: .semibold))
            Text(headerDetail)
                .font(.system(size: 12))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    /// One honest paragraph explaining what the affordances do. Whether
    /// this editor was seeded with equal-spacing guesses (the normal case)
    /// or nothing at all (no roll data to estimate spacing from) changes
    /// the wording, but both lean on the strip itself rather than repeating
    /// the reason automatic detection failed -- the workspace error card
    /// already showed that.
    private var headerDetail: String {
        let captureWindowNote =
            "The scanner captures about \(ManualFramePlacementValidation.millimeterText(ManualFramePlacementValidation.maximumFrameHeightMillimeters)) mm per frame, "
            + "so keep each frame within that."
        guard boundaryRows.isEmpty else {
            return "Drag each line to a frame edge, drag the strip to add a missing boundary, "
                + "and remove any line that doesn't belong. Film advances left to right. "
                + captureWindowNote
        }
        return "Click the film strip to add the left edge of the first frame, then add a line "
            + "at its right edge -- repeat for each frame. Film advances left to right. "
            + captureWindowNote
    }

    /// The horizontally scrolling strip.
    private var stripArea: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: stripImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: renderedWidth, height: Self.stripHeight)

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: renderedWidth, height: Self.stripHeight)
                    .onTapGesture { location in
                        addBoundary(atX: location.x)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Film strip")
                    .accessibilityHint("Click to add a frame boundary at that position")

                stripOverlay(width: renderedWidth)
            }
            .frame(width: renderedWidth, height: Self.stripHeight, alignment: .topLeading)
            .coordinateSpace(name: Self.stripCoordinateSpace)
            .padding(.horizontal, 20)
            .padding(.top, Self.lineColumnWidth)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.stripHeight + Self.lineColumnWidth + 40)
    }

    /// All the frame bands and boundary lines layered on top of the image.
    /// Two independent loops (bands, then lines) rather than one, so band
    /// rendering never has to know how lines draw themselves and vice
    /// versa.
    private func stripOverlay(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ManualFramePlacementValidation.bands(for: boundaryRows), id: \.topRow) { band in
                frameBand(band, width: width)
            }
            ForEach(boundaryRows, id: \.self) { row in
                boundaryLine(at: row)
            }
        }
        .frame(width: width, height: Self.stripHeight, alignment: .topLeading)
    }

    /// The red/neutral region between one pair of adjacent lines, carrying
    /// the implied mm width and -- only when out of the accepted height
    /// range -- a short plain-English warning. Valid bands stay quiet and
    /// untinted so the eye is drawn to what actually needs a decision.
    private func frameBand(_ band: ManualFramePlacementValidation.Band, width: CGFloat) -> some View {
        let leadingX = rowX(band.topRow)
        let bandWidth = max(rowX(band.bottomRow) - leadingX, 1)

        return VStack(spacing: 2) {
            if band.isValid {
                Text("\(ManualFramePlacementValidation.millimeterText(band.millimeters)) mm")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            } else {
                Text("\(ManualFramePlacementValidation.millimeterText(band.millimeters)) mm")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.scanStudioRed)
            }
        }
        .frame(width: bandWidth, height: Self.stripHeight)
        .background(band.isValid ? Color.clear : Color.scanStudioRed.opacity(0.16))
        .contentShape(Rectangle())
        .offset(x: leadingX)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            band.isValid
                ? "Frame from row \(band.topRow) to \(band.bottomRow), "
                    + "\(ManualFramePlacementValidation.millimeterText(band.millimeters)) millimetres"
                : "Frame from row \(band.topRow) to \(band.bottomRow). "
                    + ManualFramePlacementValidation.warning(forMillimeters: band.millimeters)
        )
    }

    /// One draggable, deletable boundary line: a vertical rule spanning the
    /// strip height, a badge above it showing the row number, and a delete
    /// control on the badge. The whole column (badge + rule) is one
    /// width-spanning hit region so a drag anywhere on it moves the line.
    private func boundaryLine(at row: Int) -> some View {
        let x = rowX(row) - Self.lineColumnWidth / 2
        return VStack(spacing: 3) {
            boundaryBadge(row: row)
            Rectangle()
                .fill(Color.scanStudioAmber)
                .frame(width: Self.lineWidth)
                .frame(maxHeight: .infinity)
        }
        .frame(width: Self.lineColumnWidth, height: Self.stripHeight + Self.lineColumnWidth)
        .padding(.top, -Self.lineColumnWidth)
        .contentShape(Rectangle())
        .offset(x: x)
        .gesture(
            DragGesture(coordinateSpace: .named(Self.stripCoordinateSpace))
                .onChanged { value in
                    dragBoundary(anchor: row, locationX: value.location.x)
                }
                .onEnded { _ in draggingRow = nil }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Boundary at row \(row)")
    }

    private func boundaryBadge(row: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(row)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
            Button {
                boundaryRows.removeAll { $0 == row }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Remove the boundary at row \(row)")
            .accessibilityLabel("Remove boundary at row \(row)")
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.scanStudioAmber.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
    }

    private func submitErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.scanStudioRed)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.scanStudioPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.scanStudioRed.opacity(0.14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Placement rejected: \(message)")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(frameCountLabel)
                    .font(.system(size: 12, weight: .semibold))
                if let reason = invalidBands.first {
                    Text(ManualFramePlacementValidation.warning(forMillimeters: reason.millimeters))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioRed)
                } else if boundaryRows.count == 1 {
                    Text("Add a second line to define a frame.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Reset") { reset() }
                .buttonStyle(.bordered)
                .disabled(isAtInitialState || isSubmitting)
                .help("Restore the boundaries to their starting positions")

            Button("Cancel") {
                sessionModel.cancelManualFramePlacement()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSubmitting)

            Button {
                confirm()
            } label: {
                if isSubmitting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Placing Frames…")
                    }
                    .frame(minWidth: 150)
                } else {
                    Text("Confirm").frame(minWidth: 150)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.scanStudioAmber)
            .foregroundStyle(.black)
            .disabled(!canConfirm)
            .help("Use these boundaries to scan the resulting frames")
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Confirm \(frameCount) frame\(frameCount == 1 ? "" : "s")")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var frameCountLabel: String {
        switch frameCount {
        case 0: return "0 frames yet"
        case 1: return "1 frame"
        default: return "\(frameCount) frames"
        }
    }

    private func confirm() {
        let rows = boundaryRows
        Task {
            let succeeded = await sessionModel.submitManualFrames(rows: rows)
            if succeeded {
                dismiss()
            }
            // On failure, `sessionModel.manualPlacementSubmitError` is
            // already set and this view stays on screen -- nothing further
            // to do here.
        }
    }

    private func rowX(_ row: Int) -> CGFloat {
        guard hasRealRaster else { return 0 }
        return CGFloat(row) / CGFloat(rasterRows) * renderedWidth
    }

    private func row(atX x: CGFloat) -> Int {
        guard hasRealRaster else { return 0 }
        let fraction = min(max(x / renderedWidth, 0), 1)
        // Clamp to the last valid row: the wire contract (and the driver's
        // own in-raster gate) is 0..rowCount-1, and a click at the strip's
        // far-right edge would otherwise round to rowCount itself and be
        // refused server-side after Confirm (2026-08-08 second-opinion
        // review, finding 4).
        return min(Int((fraction * CGFloat(rasterRows)).rounded()), rasterRows - 1)
    }

    private func addBoundary(atX x: CGFloat) {
        let row = row(atX: x)
        guard !boundaryRows.contains(where: { abs($0 - row) <= Self.duplicateClickThresholdRows }) else {
            // The click landed on (or right next to) an existing line;
            // treat it as a grab of that line rather than spawning a
            // microscopic duplicate frame the confirm would have to reject.
            return
        }
        boundaryRows = (boundaryRows + [row]).sorted()
    }

    /// Moves the line whose pre-drag value is `anchor` to `row` and
    /// re-sorts. Anchoring by value instead of index is the whole trick:
    /// each `onChanged` re-sorts, but the anchor the gesture closure
    /// captured stays stable, so subsequent frames keep removing *it*,
    /// never a now-different sibling.
    private func dragBoundary(anchor: Int, locationX: CGFloat) {
        let row = row(atX: locationX)
        var rows = boundaryRows.filter { $0 != anchor }
        if !rows.contains(row) {
            rows.append(row)
        }
        boundaryRows = rows.sorted()
        draggingRow = row
    }

    private func reset() {
        boundaryRows = ManualFramePlacementValidation.normalize(initialBoundaryRows)
    }
}

/// Loads the strip image and seeds initial boundary guesses, then presents
/// `ManualFramePlacementView`. Kept separate from the editor itself so the
/// editor's own state (`boundaryRows`, drag handling) never has to account
/// for an unloaded image.
struct ManualFramePlacementSheet: View {
    @Environment(SessionModel.self) private var sessionModel
    @Environment(\.dismiss) private var dismiss

    let strip: ManualPlacementStrip

    var body: some View {
        if let image = ThumbnailImageCache.image(atPath: strip.imagePath) {
            ManualFramePlacementView(
                stripImage: image,
                rasterRows: strip.rowCount,
                initialBoundaryRows: Self.equalSpacingSeed(
                    rowCount: strip.rowCount,
                    expectedFrameCount: sessionModel.status?.frameCount
                )
            )
        } else {
            unloadable
        }
    }

    private var unloadable: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.scanStudioRed)
            Text("The film strip preview couldn't be loaded.")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Try Place Frames Manually again, or acquire a fresh preview.")
                .font(.system(size: 11))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .multilineTextAlignment(.center)
            Button("Close") {
                sessionModel.cancelManualFramePlacement()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 420)
        .background(Color.scanStudioWorkspace)
        .foregroundStyle(Color.scanStudioPrimaryText)
    }

    /// Equal-spacing seed across the strip -- the achievable half of
    /// FEEDING-UX-LADDER-OVERNIGHT-20260807.md's "seeded from equal spacing
    /// or detected clear-film edges": `roll.previewStrip` returns only the
    /// raw raster, with no edge candidates of its own, so a client-side
    /// "detected edges" seed isn't available data to seed from. Snap
    /// assist (server-side, on confirm) still pulls a near-enough pick onto
    /// a real clear-film edge, so equal spacing only has to get the
    /// operator close, not exact. `expectedFrameCount` is the loaded
    /// carrier's own scanner-addressable slot count when known; absent
    /// that, spacing falls back to the same ~135-row nominal 35mm pitch the
    /// engine itself uses for its simulator parity.
    static func equalSpacingSeed(rowCount: Int, expectedFrameCount: Int?) -> [Int] {
        guard rowCount > 1 else { return [] }
        let nominalPitchRows = 135
        let estimatedFrames = expectedFrameCount ?? max(rowCount / nominalPitchRows, 1)
        let frameCount = max(estimatedFrames, 1)
        let pitch = Double(rowCount - 1) / Double(frameCount)
        return (0...frameCount).map { index in
            min(rowCount - 1, max(0, Int((Double(index) * pitch).rounded())))
        }
    }
}
