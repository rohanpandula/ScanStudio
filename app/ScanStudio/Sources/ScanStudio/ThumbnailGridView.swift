import AppKit
import ScanStudioKit
import SwiftUI

struct ThumbnailGridView: View {
    @Environment(SessionModel.self) private var sessionModel
    /// Contact-sheet-local display toggle (DEF-05 "Show as positive").
    /// Purely a rendering choice for this screen's tiles — never sent to
    /// the engine, never persisted, default off.
    @State private var showAsPositive = false
    @State private var reviewPresentation: ReviewFramePresentation?

    private var hasMedia: Bool { sessionModel.status?.mediaLoaded == true }
    private var isConnected: Bool { sessionModel.status?.connected == true }
    private var isRealDevice: Bool { sessionModel.device?.kind == "real" }
    private var telemetryHonesty: ScanTelemetryHonesty {
        .init(isRealDevice: isRealDevice)
    }
    private var frameCount: Int {
        sessionModel.status?.frameCount ?? max(sessionModel.thumbnails.keys.max() ?? 0, 1)
    }
    /// 1-based frame indices to draw. A `ClosedRange` (`1...frameCount`)
    /// traps when `frameCount` is `0` -- reachable whenever the engine
    /// reports media loaded with zero frames -- so this stays a `Range`,
    /// which is simply empty instead.
    private var frameIndices: Range<Int> {
        frameCount > 0 ? 1..<(frameCount + 1) : 1..<1
    }
    /// Height the sheet gives up to the scrubber and its own padding before
    /// `ContactSheetLayout` decides whether the frames fit without scrolling.
    private static let nonGridChromeHeight: Double = 118

    private func columns(forPaneSize size: CGSize) -> [GridItem] {
        let interiorWidth = Double(size.width) - 40
        let count = ContactSheetLayout.columnCount(
            frameCount: frameCount,
            availableWidth: interiorWidth,
            availableHeight: Double(size.height) - Self.nonGridChromeHeight
        )
        return Array(repeating: GridItem(.flexible(), spacing: 9), count: count)
    }

    /// Widest the sheet itself may grow. Without this a one- or two-frame
    /// holder stretches its tiles across the whole pane and upscales a
    /// preview into blur; `ContactSheetLayout` caps the tile, this caps the
    /// row so the capped tiles stay centred rather than left-hugging.
    private func sheetMaxWidth(forPaneSize size: CGSize) -> Double {
        let count = Double(columns(forPaneSize: size).count)
        return count * ContactSheetLayout.defaultMaxTileWidth + (count - 1) * 9
    }

    /// True whenever a batch is running. Read here (not just inline at each
    /// call site) because 2026-07-26 gave this a second job: this grid used
    /// to be swapped out for a separate `ActiveScanWorkspaceView` for the
    /// whole duration of a job (see `ContentView.swift`'s removal of that
    /// view) — the owner's own words: "i dont love the scanning interface,
    /// because its low res... but zoomed big... lets see the same view
    /// where it shows the entire strip." Now this same grid stays mounted
    /// through an active batch, with `ThumbnailTile` overlaying per-frame
    /// scan state directly on the whole-strip view instead.
    private var isJobActive: Bool { sessionModel.isJobActive }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)

            if hasMedia {
                GeometryReader { paneProxy in
                ScrollView {
                    LazyVGrid(columns: columns(forPaneSize: paneProxy.size), spacing: 9) {
                        ForEach(frameIndices, id: \.self) { frameIndex in
                            ThumbnailTile(
                                frameIndex: frameIndex,
                                thumbnail: sessionModel.thumbnails[frameIndex],
                                isSelected: sessionModel.selectedFrameIndices.contains(frameIndex),
                                isFocused: sessionModel.focusedFrameIndex == frameIndex,
                                frameState: sessionModel.frameStates[frameIndex],
                                displayMode: showAsPositive ? .positivePreview : .asScanned,
                                orientationDegrees: sessionModel.frameOrientation(frameIndex),
                                mirrored: sessionModel.frameMirror(frameIndex),
                                verticallyMirrored: sessionModel.frameVerticalMirror(frameIndex),
                                reviewDecision: sessionModel.manualReviewDecision(
                                    for: frameIndex
                                ),
                                onReview: {
                                    guard let previewOperationId =
                                        sessionModel.latestCompletedPreviewOperationId
                                    else { return }
                                    reviewPresentation = ReviewFramePresentation(
                                        frameIndex: frameIndex,
                                        previewOperationId: previewOperationId
                                    )
                                },
                                onFocus: {
                                    sessionModel.focusFrame(frameIndex)
                                },
                                onSelection: { shiftHeld in
                                    sessionModel.selectFrame(
                                        frameIndex,
                                        extendingSelectionIfShiftHeld: shiftHeld
                                    )
                                }
                            )
                        }
                    }
                    .frame(maxWidth: sheetMaxWidth(forPaneSize: paneProxy.size))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 16)

                    FilmStripScrubberView(
                        frameCount: frameCount,
                        // Tracks the in-flight frame during an active batch
                        // (2026-07-26) rather than a selection that's now
                        // stale bookkeeping for the duration of the job —
                        // `selectedFrameIndices` was fixed at
                        // `scan.start`/`scanSingleFrame` time and doesn't
                        // change as the batch progresses, so its `.max()`
                        // would otherwise freeze the caret at whichever
                        // frame happened to sort highest, for the whole job.
                        caretFrame: isJobActive
                            ? activeCaretFrame
                            : sessionModel.selectedFrameIndices.max(),
                        frameStates: sessionModel.frameStates
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                }
            } else {
                emptyState
            }
        }
        .background(Color.scanStudioWorkspace)
        .sheet(item: $reviewPresentation) { presentation in
            ManualReviewFrameSheet(
                session: sessionModel,
                presentation: presentation,
                displayMode: showAsPositive
                    ? .positivePreview
                    : .asScanned
            )
        }
    }

    private var workspaceHeader: some View {
        Group {
            if hasMedia {
                // Controls keep their intrinsic label widths, so the widest
                // candidate is rejected instead of silently ellipsizing. The
                // normal and compact candidates then add rows without hiding
                // or renaming any action.
                ViewThatFits(in: .horizontal) {
                    wideWorkspaceHeader
                    twoRowWorkspaceHeader
                    threeRowWorkspaceHeader
                }
            } else {
                workspaceIdentity
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color.scanStudioWorkspace)
    }

    private var wideWorkspaceHeader: some View {
        HStack(spacing: 12) {
            workspaceIdentity
            Spacer(minLength: 12)
            previewModeControl
            workspaceActionMenus
            autoCropScanTimeStatus
        }
    }

    private var twoRowWorkspaceHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                workspaceIdentity
                Spacer(minLength: 12)
                previewModeControl
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                workspaceActionMenus
                autoCropScanTimeStatus
            }
        }
    }

    private var threeRowWorkspaceHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                workspaceIdentity
                Spacer(minLength: 12)
                previewModeControl
            }
            HStack {
                Spacer(minLength: 0)
                workspaceActionMenus
            }
            HStack {
                Spacer(minLength: 0)
                autoCropScanTimeStatus
            }
        }
    }

    private var workspaceIdentity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(hasMedia ? sessionModel.carrierDisplayName : "Film workspace")
                    .font(.system(size: 17, weight: .semibold))
                if isJobActive {
                    InlineTag(text: "Scanning", color: .scanStudioAmber)
                }
            }
            Text(hasMedia
                ? "\(frameCount) frame\(frameCount == 1 ? "" : "s") detected · \(previewSourceCaption)"
                : "No film holder loaded")
                .font(.system(size: 11))
                .foregroundStyle(Color.scanStudioSecondaryText)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Contact-sheet-only approximation. It changes this contact sheet, never the
    /// scanned or saved files.
    private var previewModeControl: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Picker("Preview", selection: $showAsPositive) {
                Text("Negative").tag(false)
                Text("Positive").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 156)
            .help("Contact-sheet approximation, not the final render — Positive inverts and neutralizes the orange mask here. Scanned and saved files are unchanged.")
            .accessibilityHint("Preview approximation, not the final render. Scanned and saved files are unchanged.")
            .accessibilityLabel("Preview display mode")

            if showAsPositive {
                Text("Preview approximation")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var workspaceActionMenus: some View {
        HStack(spacing: 10) {
            selectionMenu
            rotationMenu
            mirrorMenu
        }
    }

    private var selectionMenu: some View {
        Menu("Select", systemImage: "checkmark.circle") {
            Button("All") { sessionModel.selectAllFrames() }
                .keyboardShortcut("a", modifiers: .command)
            Button("None") { sessionModel.clearFrameSelection() }
            Button("Invert") { sessionModel.invertFrameSelection() }
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var rotationMenu: some View {
        Menu("Rotate", systemImage: "rotate.right") {
            Button(transformActionLabel("Rotate Left")) {
                sessionModel.performFrameTransformCommand(.rotateLeft)
            }
            Button(transformActionLabel("Rotate Right")) {
                sessionModel.performFrameTransformCommand(.rotateRight)
            }
            Button(transformActionLabel("Reset Rotation")) {
                if let frameIndex = sessionModel.frameTransformTargetIndex {
                    sessionModel.resetFrameOrientation(frameIndex)
                }
            }

            if sessionModel.selectedFrameCount > 1 {
                Divider()
                Menu("Apply to \(sessionModel.selectedFrameCount) Selected Frames") {
                    Button("Rotate All Left") {
                        for frame in sessionModel.selectedFrames {
                            sessionModel.rotateFrame(frame, by: -90)
                        }
                    }
                    Button("Rotate All Right") {
                        for frame in sessionModel.selectedFrames {
                            sessionModel.rotateFrame(frame, by: 90)
                        }
                    }
                    Button("Reset All Rotations") {
                        for frame in sessionModel.selectedFrames {
                            sessionModel.resetFrameOrientation(frame)
                        }
                    }
                }
            }
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(
            sessionModel.frameTransformTargetIndex == nil
                || !sessionModel.frameTransformsAreEditable
        )
        .help(transformMenuHelp(
            missingTarget: "Click a frame to focus it, then rotate it.",
            available: "Rotates the focused frame's Positive/Preview files on its next scan. Existing files and Master TIFF, IR, and meter stay untouched. Command-L rotates left; Command-R rotates right."
        ))
    }

    private var mirrorMenu: some View {
        Menu("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
            Button(transformActionLabel("Flip Left to Right")) {
                sessionModel.performFrameTransformCommand(.flipLeftToRight)
            }
            Button(transformActionLabel("Flip Top to Bottom")) {
                sessionModel.performFrameTransformCommand(.flipTopToBottom)
            }
            Button(transformActionLabel("Reset Flips")) {
                if let frameIndex = sessionModel.frameTransformTargetIndex {
                    sessionModel.resetFrameMirrors(frameIndex)
                }
            }

            if sessionModel.selectedFrameCount > 1 {
                Divider()
                Menu("Apply to \(sessionModel.selectedFrameCount) Selected Frames") {
                    Button("Flip All Left to Right") {
                        for frame in sessionModel.selectedFrames {
                            sessionModel.toggleFrameMirror(frame)
                        }
                    }
                    Button("Flip All Top to Bottom") {
                        for frame in sessionModel.selectedFrames {
                            sessionModel.toggleFrameVerticalMirror(frame)
                        }
                    }
                    Button("Reset All Flips") {
                        for frame in sessionModel.selectedFrames {
                            sessionModel.resetFrameMirrors(frame)
                        }
                    }
                }
            }
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(
            sessionModel.frameTransformTargetIndex == nil
                || !sessionModel.frameTransformsAreEditable
        )
        .help(transformMenuHelp(
            missingTarget: "Click a frame to focus it, then flip it.",
            available: "Flips the focused frame's Positive/Preview files on its next scan. Existing files and Master TIFF, IR, and meter stay untouched. Shift-Command-H flips left to right; Option-Command-V flips top to bottom."
        ))
    }

    private func transformMenuHelp(
        missingTarget: String,
        available: String
    ) -> String {
        guard sessionModel.frameTransformsAreEditable else {
            return "Rotation and flips cannot be changed while a scan is starting or running."
        }
        return sessionModel.frameTransformTargetIndex == nil
            ? missingTarget
            : available
    }

    private func transformActionLabel(_ action: String) -> String {
        guard let frameIndex = sessionModel.frameTransformTargetIndex else {
            return action
        }
        return "\(action) — Frame \(String(format: "%02d", frameIndex))"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(Color.scanStudioSecondaryText)
            Text("Load a film holder")
                .font(.system(size: 17, weight: .semibold))
            Text(emptyStateDetail)
                .font(.system(size: 12))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Honest device-kind suffix for the workspace header's frame count —
    /// mirrors `DeviceBarView`/`SessionSidebarView`'s own kind-aware copy
    /// rather than a bare "simulated previews" literal that stayed true even
    /// once a real scanner delivered real previews.
    private var previewSourceCaption: String {
        isRealDevice ? "scanner previews" : "simulated previews"
    }

    private var activeCaretFrame: Int? {
        telemetryHonesty.currentFrameIndex(
            reported: sessionModel.progress?.frameIndex,
            frameStates: sessionModel.frameStates
        )
    }

    private var autoCropOffered: Bool {
        AutoCropAffordance.isOffered(
            selectedFrameIndices: sessionModel.selectedFrameIndices,
            thumbnails: sessionModel.thumbnails
        )
    }

    private var autoCropUnavailableReason: String {
        guard sessionModel.selectedFrameIndices.count == 1 else {
            return "Select exactly one frame for Auto Crop on Scan."
        }
        return "Needs a real scanner preview for the selected frame."
    }

    /// Mirrors the roll-wide toggle in the batch inspector so this status
    /// stays honest about what a scan of the selected frame would do.
    private var autoCropStateDescription: String {
        sessionModel.autoCropEnabled
            ? "On — derived outputs crop to the detected image area at scan time."
            : "Off — enable in Batch settings to crop derived outputs at scan time."
    }

    /// Auto crop has no immediate preview command: it is only evaluated when
    /// a derived scan output is made. This is deliberately a status, not a
    /// menu, toggle, or disabled control that would imply an action exists.
    private var autoCropScanTimeStatus: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Auto Crop on Scan", systemImage: "crop")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(autoCropOffered ? Color.scanStudioPrimaryText : Color.scanStudioSecondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(autoCropOffered
                ? autoCropStateDescription
                : autoCropUnavailableReason)
                .font(.system(size: 9))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: true, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(autoCropOffered
            ? "Auto Crop on Scan. \(autoCropStateDescription)"
            : "Auto Crop on Scan unavailable. \(autoCropUnavailableReason)")
    }

    /// Mirrors `SessionSidebarView`'s own media-section copy split (same
    /// three cases): disconnected gets a neutral "connect" prompt; a real
    /// device that's already connected has no simulator-style carrier
    /// picker at all, so it's told to feed film and run a preview instead of
    /// wording that only describes the simulator's three carrier types; a
    /// connected simulator drops the now-redundant "Connect" verb.
    private var emptyStateDetail: String {
        guard isConnected else {
            return "Connect the scanner, then choose a mounted slide, film strip, or 35 mm roll."
        }
        if isRealDevice {
            return "Feed film into the scanner, then run a preview to detect frames."
        }
        return "Choose a mounted slide, film strip, or 35 mm roll."
    }
}

/// Binds the visible Review sheet to the exact completed preview that
/// produced the warning. Frame numbers repeat across previews, so the
/// operation identity must travel with the presentation rather than being
/// looked up only when the user eventually chooses an action.
private struct ReviewFramePresentation: Identifiable {
    let frameIndex: Int
    let previewOperationId: String

    var id: String {
        "\(previewOperationId):\(frameIndex)"
    }
}

/// Turns the contact sheet's Review marker into a decision instead of a
/// dead-end warning. "Use anyway" and "Don't scan" resolve only this exact
/// preview. "Preview again" is the corrective path: it remains behind an
/// explicit movement confirmation because it re-reads and replaces the
/// whole preview registration, not only this tile.
private struct ManualReviewFrameSheet: View {
    @Bindable var session: SessionModel
    let presentation: ReviewFramePresentation
    let displayMode: ThumbnailDisplayMode

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingPreviewAgain = false
    @State private var isStartingPreview = false

    private var frameIndex: Int { presentation.frameIndex }
    private var thumbnail: Thumbnail? { session.thumbnails[frameIndex] }
    private var decision: ManualReviewDecision? {
        session.manualReviewDecision(for: frameIndex)
    }
    private var reviewIsCurrent: Bool {
        session.latestCompletedPreviewOperationId
            == presentation.previewOperationId
            && thumbnail?.needsApproval == true
    }
    private var canPreviewAgain: Bool {
        session.status?.transport == "idle"
            && session.hardwareMotionReadiness.allowsMotion
            && !session.isAcquiringThumbnails
            && !isStartingPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.scanStudioAmber)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Frame \(String(format: "%02d", frameIndex))")
                        .font(.system(size: 20, weight: .semibold))
                    Text(
                        reviewIsCurrent
                            ? reviewReason
                            : "This Review notice belongs to an older preview. Close it and use the current film preview."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if let decision {
                    InlineTag(
                        text: decision == .useFrameAnyway
                            ? "Use anyway"
                            : "Not scanning",
                        color: decision == .useFrameAnyway
                            ? .scanStudioGreen
                            : .scanStudioSecondaryText
                    )
                } else {
                    InlineTag(text: "Needs a choice", color: .scanStudioAmber)
                }
            }

            ThumbnailTileImage(
                frameIndex: frameIndex,
                thumbnail: thumbnail,
                displayMode: displayMode,
                orientationDegrees: session.frameOrientation(frameIndex),
                mirrored: session.frameMirror(frameIndex),
                verticallyMirrored: session.frameVerticalMirror(frameIndex)
            )
            .aspectRatio(
                FrameOrientation.displayAspectRatio(
                    session.frameOrientation(frameIndex)
                ),
                contentMode: .fit
            )
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 250)
            .background(Color.black.opacity(0.35))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ScanStudioMetrics.thumbnailCornerRadius
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: ScanStudioMetrics.thumbnailCornerRadius
                )
                .stroke(Color.scanStudioAmber, lineWidth: 2)
            }

            if FrameAlignmentAvailabilityPolicy.isVisible(
                deviceKind: session.device?.kind
            ) {
                FrameAlignmentControl(
                    session: session,
                    frameIndex: frameIndex,
                    compact: true
                )
            }

            if let decision {
                Label(
                    decision == .useFrameAnyway
                        ? "This frame will be included."
                        : "This frame will not be scanned.",
                    systemImage: decision == .useFrameAnyway
                        ? "checkmark.circle.fill"
                        : "minus.circle.fill"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    decision == .useFrameAnyway
                        ? Color.scanStudioGreen
                        : Color.scanStudioSecondaryText
                )
            } else if thumbnail?.partial == true {
                // Lane C: a partial frame (>=90% of its height inside the
                // preview, not all of it) is shown with an informed scan-or-
                // refeed badge; the frame is still scannable below.
                Label(
                    "Partial frame — refeed for full coverage",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.scanStudioSecondaryText)
            }

            HStack(spacing: 10) {
                Button {
                    resolve(.dontScan)
                } label: {
                    Label(
                        decision == .dontScan
                            ? "Not Scanning This Frame"
                            : "Don’t Scan This Frame",
                        systemImage: decision == .dontScan
                            ? "checkmark"
                            : "minus.circle"
                    )
                    .frame(minWidth: 155)
                }
                .buttonStyle(.bordered)
                .disabled(!reviewIsCurrent || decision == .dontScan)

                Spacer()

                Button {
                    resolve(.useFrameAnyway)
                } label: {
                    Label(
                        decision == .useFrameAnyway
                            ? "Using This Frame"
                            : "Use Frame Anyway",
                        systemImage: decision == .useFrameAnyway
                            ? "checkmark"
                            : "checkmark.circle"
                    )
                    .frame(minWidth: 145)
                }
                .buttonStyle(.borderedProminent)
                .tint(.scanStudioAmber)
                .foregroundStyle(.black)
                .disabled(!reviewIsCurrent || decision == .useFrameAnyway)
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Want ScanStudio to try the boundary again?")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Previewing again moves the film and replaces every current preview and Review choice."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    isConfirmingPreviewAgain = true
                } label: {
                    if isStartingPreview {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting…")
                        }
                    } else {
                        Label("Preview Again…", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canPreviewAgain)
                .help(previewAgainHelp)
            }

            HardwareMotionReadinessView(compact: true)

            if !warnings.isEmpty {
                DisclosureGroup("Technical reason") {
                    Text(warnings.joined(separator: ", "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .font(.system(size: 10))
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Color.scanStudioWorkspace)
        .foregroundStyle(Color.scanStudioPrimaryText)
        .interactiveDismissDisabled(isStartingPreview)
        .confirmationDialog(
            "Preview the film again?",
            isPresented: $isConfirmingPreviewAgain,
            titleVisibility: .visible
        ) {
            Button("Preview Again") {
                startPreviewAgain()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This moves the film through the scanner and replaces all current previews and Review choices."
            )
        }
    }

    private var warnings: [String] {
        thumbnail?.warnings ?? []
    }

    private var reviewReason: String {
        if warnings.contains("ambiguous-content-tail-boundary") {
            return "ScanStudio isn’t certain where this frame ends. If the preview shows a real photo you want, use it anyway. If it is blank or only part of a frame, don’t scan it."
        }
        return "ScanStudio could not determine this frame boundary confidently. Check the preview, then use the frame or leave it out."
    }

    private var previewAgainHelp: String {
        guard session.status?.transport == "idle" else {
            return "Wait for the current scanner movement to finish."
        }
        guard session.hardwareMotionReadiness.allowsMotion else {
            return session.hardwareMotionReadiness.guidance
        }
        return "Re-read the whole film and replace these previews."
    }

    private func resolve(_ newDecision: ManualReviewDecision) {
        guard session.decideManualReview(
            newDecision,
            for: frameIndex,
            previewOperationId: presentation.previewOperationId
        ) else { return }
        dismiss()
    }

    private func startPreviewAgain() {
        guard canPreviewAgain else { return }
        isStartingPreview = true
        let intent: PreviewIntent
        if session.project == nil {
            intent = .replaceFilmProcess(
                token: PreviewIntentToken(),
                filmProcess: session.previewFilmProcess
                    ?? session.scanFilmProcess
            )
        } else {
            intent = .refreshSavedProject(token: PreviewIntentToken())
        }
        Task {
            let outcome = await session.requestPreview(intent)
            isStartingPreview = false
            if outcome == .started {
                dismiss()
            }
        }
    }
}

/// Renders the real preview tile when the bridge/engine supplied a loadable
/// `imagePath` (a real backend's `Thumbnail` per Phase 10's one-of wire
/// contract); falls back to the bundled `SimulatedFrameImage` mockup art
/// only when `thumbnail` is ITSELF simulator-shaped (populated
/// `brightness`/`tint`, per PROTOCOL.md's strict one-of: "exactly one of the
/// {brightness, tint} pair or imagePath is populated... never both, never
/// neither"). Verified live 2026-07-25: the real-path branch was already
/// correct on its own, but every real thumbnail was silently dropped one
/// layer up, in `SessionModel.handle(event:)`'s `"scanner.thumbnail"` case —
/// see `ThumbnailAdmissionPolicy` (SessionModel.swift) for that root cause
/// and fix.
///
/// Fixed again live 2026-07-26 — a second, narrower bug the 07-25 fix
/// didn't touch: the fallback used to read `isAvailable: thumbnail != nil`,
/// which is true for a REAL thumbnail too whenever its `imagePath` exists
/// but hasn't successfully loaded on THIS particular render — the file
/// still mid-write by the bridge, or a transient `NSImage(contentsOfFile:)`
/// miss (`ThumbnailImageCache.image`'s own doc comment: a miss "is never
/// cached, so it's retried on the next render"). That let the bundled
/// mockup crop — unrelated demo-roll art — flash on screen for a real
/// frame until a later render's retry picked up the by-then-flushed file:
/// the "simulated placeholder before the real preview replaces it" bug the
/// owner reported live. The fallback must therefore ask "is this thumbnail
/// intrinsically simulated" (`isGenuinelySimulatedThumbnail` below), never
/// merely "does a `Thumbnail` object of some kind exist" — a real
/// thumbnail whose image isn't loadable yet renders the neutral empty
/// state instead.
///
/// `internal` (not `private`): `RollLoadingWorkspaceView.swift`'s
/// `RollLoadingFrameCell` reuses this exact type rather than re-deriving
/// the same real-vs-simulated distinction a third time — see that type's
/// own doc comment for the bug this reuse also fixes there.
struct ThumbnailTileImage: View {
    let frameIndex: Int
    let thumbnail: Thumbnail?
    var displayMode: ThumbnailDisplayMode = .asScanned
    /// Preview of the persisted derivative rotation (0/90/180/270).
    /// Centralized here (not at each
    /// call site) so the contact sheet, the carrier-loading grid, and the
    /// FrameDetail filmstrip all rotate identically for free.
    var orientationDegrees: Int = 0
    var mirrored: Bool = false
    var verticallyMirrored: Bool = false

    var body: some View {
        GeometryReader { geometry in
            imageContent
                // `rotationEffect` is paint-only: without swapping these
                // proposed dimensions first, a 90° image is still laid out
                // as landscape and then clipped/letterboxed inside the new
                // portrait card. Give it the card's opposite dimensions so
                // the painted quarter-turn lands exactly inside the card.
                .frame(
                    width: swapsLayoutAxes
                        ? geometry.size.height
                        : geometry.size.width,
                    height: swapsLayoutAxes
                        ? geometry.size.width
                        : geometry.size.height
                )
                .scaleEffect(
                    x: mirrored ? -1 : 1,
                    y: verticallyMirrored ? -1 : 1
                )
                .rotationEffect(.degrees(Double(orientationDegrees)))
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height / 2
                )
        }
        .clipped()
    }

    @ViewBuilder
    private var imageContent: some View {
        if let path = thumbnail?.imagePath,
           let nsImage = ThumbnailImageCache.image(atPath: path, mode: displayMode) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            SimulatedFrameImage(
                frameIndex: frameIndex,
                isAvailable: isGenuinelySimulatedThumbnail,
                displayMode: displayMode
            )
        }
    }

    private var swapsLayoutAxes: Bool {
        FrameOrientation.swapsLayoutAxes(orientationDegrees)
    }

    /// True only when `thumbnail` itself carries affirmative simulator
    /// provenance (populated brightness/tint) — never true merely because a
    /// `Thumbnail` of some kind exists, and never true from the mere absence
    /// of an `imagePath` (see `Thumbnail.isSimulatorShaped`'s own doc comment
    /// for why absence is not provenance). Routes through that one tested
    /// property so the real-vs-simulated decision lives in a single place.
    private var isGenuinelySimulatedThumbnail: Bool {
        guard let thumbnail else { return false }
        return thumbnail.isSimulatorShaped
    }
}

/// Contact-sheet header toggle's two tile-rendering modes (DEF-05 "Show as
/// positive"). `.asScanned` is the existing, unchanged look; `.positive`
/// runs the tile through `PositivePreviewRenderer`'s cheap approximate
/// inversion — see that type's own doc comment for exactly what it does
/// and does not do.
enum ThumbnailDisplayMode: Hashable {
    case asScanned
    case positivePreview
}

/// Process-wide preview-tile cache backing `ThumbnailTileImage` above —
/// reused verbatim by the contact-sheet grid (both idle and, since the
/// 2026-07-26 scanning-view redesign, through an active batch too, per
/// `ThumbnailGridView.isJobActive`'s own doc comment),
/// `RollLoadingWorkspaceView.swift`'s carrier-loading grid, and
/// `FrameDetailWorkspaceView`'s large preview. The same on-disk preview
/// TIFFs are genuinely visible across all of those screens in one session
/// (a frame loaded during acquisition, shown again in the contact sheet,
/// shown again in its own detail view), so one shared cache is what
/// actually avoids the repeat disk reads, not several independent
/// per-screen ones. `NSCache` itself is
/// thread-safe at runtime, but isn't `Sendable`, so this codebase's Swift 6
/// strict-concurrency mode needs it pinned to a single isolation domain;
/// `@MainActor` is correct here since every caller renders from SwiftUI view
/// bodies, which are themselves `@MainActor`. Keyed by the file path itself,
/// which is always fresh per BRIDGE.md (each `roll.preview` writes to a
/// brand-new UUID-named preview directory), so a cached entry can never go
/// stale. `internal` (not `private`) so `ScanStudioTheme.swift`'s
/// `SimulatedFrameImage` can share the exact same cache/keying scheme for
/// the simulator's own bundled art (see that type's own doc comment).
@MainActor
enum ThumbnailImageCache {
    static let shared = NSCache<NSString, NSImage>()

    /// Loads by file path, caching the result so re-rendering a tile
    /// (selection toggles, hover, scroll, badge updates, progress ticks —
    /// all far more frequent than the underlying file ever changing) never
    /// re-reads the same on-disk TIFF twice. A miss (file missing, still
    /// being written by the bridge, or unreadable) is never cached, so it's
    /// retried on the next render rather than permanently frozen as a
    /// failure. Keyed by `path` + `mode` together (a distinct cache slot
    /// per display mode) so the "Show as positive" toggle never clobbers
    /// or reuses the plain as-scanned entry for the same path.
    static func image(atPath path: String, mode: ThumbnailDisplayMode = .asScanned) -> NSImage? {
        rendered(key: path, mode: mode) { NSImage(contentsOfFile: path) }
    }

    /// Same convert-and-cache machinery as `image(atPath:mode:)`, but for a
    /// source image with no on-disk path of its own — the simulator's
    /// bundled `SimulatedRollFrames` crops (`ScanStudioTheme.swift`'s
    /// `SimulatedFrameImage`), so its own "Show as positive" tiles share
    /// this exact same cache/conversion path rather than a second,
    /// parallel one. `key` only needs to be stable and unique per source
    /// image (`SimulatedFrameImage` uses `"sim-frame-<index>"`); `source`
    /// is only invoked on a genuine cache miss.
    static func image(forKey key: String, mode: ThumbnailDisplayMode, source: () -> NSImage?) -> NSImage? {
        rendered(key: key, mode: mode, source: source)
    }

    private static func rendered(key: String, mode: ThumbnailDisplayMode, source: () -> NSImage?) -> NSImage? {
        let modeKey = cacheKey(path: key, mode: mode)
        if let cached = shared.object(forKey: modeKey) {
            return cached
        }
        guard let sourceImage = asScannedImage(key: key, source: source) else { return nil }
        let result: NSImage
        switch mode {
        case .asScanned:
            result = sourceImage
        case .positivePreview:
            guard let converted = PositivePreviewRenderer.positiveApproximation(from: sourceImage) else { return nil }
            result = converted
        }
        shared.setObject(result, forKey: modeKey)
        return result
    }

    /// The as-scanned image backing `key`, itself cached under its own
    /// `.asScanned` slot so computing a `.positivePreview` conversion never
    /// re-invokes `source` (an on-disk file read, or a dictionary lookup
    /// into `SimulatedRollFrames`) if the as-scanned tile already rendered
    /// this session.
    private static func asScannedImage(key: String, source: () -> NSImage?) -> NSImage? {
        let modeKey = cacheKey(path: key, mode: .asScanned)
        if let cached = shared.object(forKey: modeKey) {
            return cached
        }
        guard let image = source() else { return nil }
        shared.setObject(image, forKey: modeKey)
        return image
    }

    private static func cacheKey(path: String, mode: ThumbnailDisplayMode) -> NSString {
        "\(path)#\(mode)" as NSString
    }
}

/// Cheap, CONTACT-SHEET-ONLY negative-to-positive approximation for one tile
/// image — never touches capture data or written outputs, and is
/// intentionally not colorimetric (no per-stock calibration, no ICC
/// awareness). This is the small AppKit/CGImage-specific glue: it extracts
/// R/G/B channel byte arrays from the tile, hands each to
/// `PositivePreviewMath.applyToChannel` (the pure, unit-tested math this
/// approximation actually runs — see `PositivePreviewMath` in
/// ScanStudioKit), then reassembles the result. Returns `nil` for any image
/// this cheap path can't handle (no CGImage backing, unreadable pixel
/// buffer), so callers fall back to the as-scanned tile rather than
/// crashing or showing a blank one.
enum PositivePreviewRenderer {
    static func positiveApproximation(from image: NSImage, percentile: Double = 0.5) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pixelCount = width * height
        var red = [UInt8](repeating: 0, count: pixelCount)
        var green = [UInt8](repeating: 0, count: pixelCount)
        var blue = [UInt8](repeating: 0, count: pixelCount)
        for pixel in 0..<pixelCount {
            let offset = pixel * bytesPerPixel
            red[pixel] = buffer[offset]
            green[pixel] = buffer[offset + 1]
            blue[pixel] = buffer[offset + 2]
        }

        let stretchedRed = PositivePreviewMath.applyToChannel(red, percentile: percentile)
        let stretchedGreen = PositivePreviewMath.applyToChannel(green, percentile: percentile)
        let stretchedBlue = PositivePreviewMath.applyToChannel(blue, percentile: percentile)

        for pixel in 0..<pixelCount {
            let offset = pixel * bytesPerPixel
            buffer[offset] = stretchedRed[pixel]
            buffer[offset + 1] = stretchedGreen[pixel]
            buffer[offset + 2] = stretchedBlue[pixel]
            // buffer[offset + 3] (the padding byte under `.noneSkipLast`)
            // is left untouched -- this pipeline has no alpha/opacity
            // concept, it only ever rewrites color channels.
        }

        guard
            let outputContext = CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ),
            let outputCGImage = outputContext.makeImage()
        else { return nil }

        return NSImage(cgImage: outputCGImage, size: image.size)
    }
}

private struct ThumbnailTile: View {
    let frameIndex: Int
    let thumbnail: Thumbnail?
    let isSelected: Bool
    let isFocused: Bool
    let frameState: FrameState?
    /// DEF-05 "Show as positive" — see `ThumbnailTileImage`/
    /// `PositivePreviewRenderer`'s own doc comments.
    var displayMode: ThumbnailDisplayMode = .asScanned
    /// Preview of the saved derivative rotation in degrees (0/90/180/270).
    var orientationDegrees: Int = 0
    var mirrored: Bool = false
    var verticallyMirrored: Bool = false
    let reviewDecision: ManualReviewDecision?
    let onReview: () -> Void
    /// `Bool` is whether Shift was held at tap time (Finder-style
    /// range-select). SwiftUI's plain `Button` action carries no modifier
    /// info of its own, so `tileButton` below reads
    /// `NSEvent.modifierFlags` at the moment the tap fires and reports it
    /// here, rather than this view (or `SessionModel`) needing its own
    /// gesture recognizer.
    let onFocus: () -> Void
    let onSelection: (Bool) -> Void

    @Environment(SessionModel.self) private var sessionModel

    private var isRealDevice: Bool { sessionModel.device?.kind == "real" }

    /// Which live telemetry this tile may honestly show — see
    /// `ScanTelemetryHonesty` (ScanStudioKit) for the engine-side root cause.
    private var telemetryHonesty: ScanTelemetryHonesty { .init(isRealDevice: isRealDevice) }

    /// Per-frame scan progress, honest about what the engine can actually
    /// back with real data — see `ScanningTileOverlay`'s own doc comment for
    /// the full root-cause writeup (`real_backend.rs::run_real_scan_job_inner`
    /// and `compute_frame_ordinal`'s doc comment, both dated 2026-07-25).
    /// Short version: the simulator's `scan.progress.framePercent` is a
    /// genuine, continuously live per-frame fraction (`sim.rs`'s own
    /// elapsed/total timer); a real LS-5000's is not — its entire burst
    /// fires before hardware ever moves, and the engine's own corrective
    /// re-emission deliberately hardcodes `0.0` as an honest "unknown"
    /// rather than fabricate one. `nil` here means "render coarse state
    /// only," never "assume zero." Routed through `telemetryHonesty` so the
    /// real-vs-simulated decision lives in one tested place.
    private var liveFramePercent: Double? {
        guard let progress = sessionModel.progress else { return nil }
        return telemetryHonesty.liveFramePercent(
            reported: progress.framePercent,
            isInFlightFrame: frameState == .active && progress.frameIndex == frameIndex
        )
    }

    /// Retry starts the same single-frame scan as the detail workspace, so it
    /// must render from the same readiness decision rather than only checking
    /// whether a job happens to be active.
    private var retryReadiness: ScanReadinessPolicy.Decision {
        sessionModel.scanReadiness(for: [frameIndex])
    }

    private var failureAction: FrameFailureAction {
        FrameFailureLabel.action(
            forErrorCode: sessionModel.frameErrors[frameIndex]?.code
        )
    }

    private var failureActionLabel: String {
        failureAction == .approveAndRetry ? "Preview Again" : "Retry"
    }

    private var failureActionIsEnabled: Bool {
        retryReadiness.isReady
            && sessionModel.approvingFrameIndex == nil
    }

    var body: some View {
        // The retry affordance (both its VoiceOver action and its visible
        // icon) is only attached when there's a failed attempt to retry —
        // `tileButton` alone (no retry) covers every other state. The
        // "view details" affordance below is unconditional (every tile can
        // open its frame's detail workspace), so it's applied once to
        // whichever branch renders rather than duplicated inside both.
        Group {
            if frameState == .failed {
                tileButton
                    .accessibilityAction(named: Text(failureActionLabel)) {
                        // 2026-07-26: a `.failed` tile is now reachable
                        // while a batch is still active (this grid stays
                        // mounted through a running job — see
                        // `ThumbnailGridView.isJobActive`'s own doc
                        // comment) — e.g. the engine's own one-shot
                        // auto-retry on a recoverable fault (PROTOCOL.md's
                        // fault-injection note: "failed, attempt 1... the
                        // engine automatically retries once"). Retrying
                        // from here too would issue a second, concurrent
                        // `scan.start` the engine can only refuse
                        // (`SCANNER_BUSY`/bridge `HARDWARE_LANE_BUSY`) or
                        // race the job already resolving this exact frame.
                        performFailureAction()
                    }
                    .overlay(alignment: .bottomLeading) { failureActionButton }
            } else {
                tileButton
            }
        }
        .accessibilityAction(named: "View Details") {
            sessionModel.openFrameDetail(frameIndex)
        }
        .overlay(alignment: .topTrailing) { selectionButton }
        .overlay(alignment: .bottomLeading) { reviewActionButton }
        .overlay(alignment: .topLeading) { viewDetailsButton }
    }

    private var tileButton: some View {
        Button {
            onFocus()
        } label: {
            ZStack(alignment: .topLeading) {
                ThumbnailTileImage(
                    frameIndex: frameIndex,
                    thumbnail: thumbnail,
                    displayMode: displayMode,
                    orientationDegrees: orientationDegrees,
                    mirrored: mirrored,
                    verticallyMirrored: verticallyMirrored
                )

                LinearGradient(
                    colors: [.black.opacity(0.58), .clear],
                    startPoint: .top,
                    endPoint: .center
                )

                Text(String(format: "%02d", frameIndex))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)

                if frameState == .failed {
                    // A tinted wash, not just the small corner badge below —
                    // this grid is now the ONLY view of an active batch
                    // (2026-07-26 redesign, see
                    // `ThumbnailGridView.isJobActive`'s own doc comment), so
                    // a failure has to read at a glance across a full
                    // 30-40-tile grid, not only to someone whose eye already
                    // landed on a small corner icon.
                    (failureAction == .approveAndRetry
                        ? Color.scanStudioAmber
                        : Color.scanStudioRed
                    ).opacity(0.22)
                }

                // Excluded takes visual precedence over any live FrameState
                // treatment in the same corner — exclusion means this frame
                // will never be scanned regardless of a prior transient
                // state. `.active` gets its own richer overlay (the owner's
                // explicit ask, 2026-07-26: "a progress scanning
                // animation... over the frame its doing") instead of the
                // plain corner badge every other state still uses.
                if frameState == .active {
                    ScanningTileOverlay(framePercent: liveFramePercent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(5)
                } else if let frameState {
                    FrameStateBadge(
                        state: frameState,
                        errorCode: frameState == .failed
                            ? sessionModel.frameErrors[frameIndex]?.code
                            : nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
                }
            }
            .aspectRatio(
                FrameOrientation.displayAspectRatio(orientationDegrees),
                contentMode: .fit
            )
            .background(Color.black.opacity(0.34))
            .clipShape(RoundedRectangle(cornerRadius: ScanStudioMetrics.thumbnailCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ScanStudioMetrics.thumbnailCornerRadius)
                    .stroke(tileBorderColor, lineWidth: tileBorderLineWidth)
            }
            .contentShape(RoundedRectangle(cornerRadius: ScanStudioMetrics.thumbnailCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Frame \(frameIndex) image")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Focus this frame for rotation, flipping, or detail editing")
    }

    /// Scan inclusion is independent from edit focus. Keeping this as a
    /// sibling overlay—not a button nested inside `tileButton`—lets all six
    /// frames stay checked while the image button focuses only one of them.
    private var selectionButton: some View {
        Button {
            onSelection(
                NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            )
        } label: {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(isSelected ? .palette : .monochrome)
                .foregroundStyle(
                    isSelected ? Color.black.opacity(0.86) : Color.white.opacity(0.78),
                    Color.scanStudioAmber
                )
                .font(.system(size: 16, weight: .bold))
                .frame(
                    minWidth: ScanStudioMetrics.minimumInteractiveTarget,
                    minHeight: ScanStudioMetrics.minimumInteractiveTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Do not scan frame \(frameIndex)" : "Scan frame \(frameIndex)")
        .accessibilityLabel(
            isSelected
                ? "Remove frame \(frameIndex) from this scan"
                : "Include frame \(frameIndex) in this scan"
        )
    }

    /// Transport-smear is a completed-capture QC verdict only; it is
    /// meaningless (and therefore never rendered) for failed, waiting,
    /// skipped, or excluded frames. Excluded frames already take the
    /// bottom-trailing badge corner, so this plan uses a tile-border tint
    /// instead of competing with that corner.
    private var transportSmearFlagged: Bool {
        frameState == .completed && sessionModel.frameTransportSmearReasons[frameIndex] != nil
    }

    /// `.active`/`.failed` win over selection: once a batch is running, the
    /// more urgent thing this border can communicate is "in progress" or
    /// "needs attention," not "was selected for this batch" — that's now
    /// historical bookkeeping (the frames actually running were already
    /// fixed at `scan.start`/`scanSingleFrame` time; toggling selection
    /// mid-job only affects a future batch, per the "Select" menu's own doc
    /// comment above). `transportSmearFlagged` can never overlap either
    /// branch (it requires `frameState == .completed`), so the ordering
    /// among these three is never actually ambiguous at runtime.
    private var tileBorderColor: Color {
        if frameState == .active { return Color.scanStudioAmber }
        if frameState == .failed {
            return failureAction == .approveAndRetry
                ? Color.scanStudioAmber
                : Color.scanStudioRed.opacity(0.85)
        }
        if isFocused { return Color.scanStudioAmber }
        if isSelected { return Color.scanStudioAmber.opacity(0.55) }
        if transportSmearFlagged { return Color.scanStudioAmber }
        return Color.white.opacity(0.14)
    }

    private var tileBorderLineWidth: CGFloat {
        if frameState == .active { return 2.5 }
        if isFocused { return 2.5 }
        if isSelected || transportSmearFlagged || frameState == .failed { return 1.5 }
        return 1
    }

    /// Independent from the tile-selection button so Review is a real
    /// action, not a passive label or a tap that unexpectedly toggles the
    /// frame. The visible capsule is compact, while its 32-point minimum
    /// height gives mouse and accessibility users a forgiving target.
    @ViewBuilder
    private var reviewActionButton: some View {
        if thumbnail?.needsApproval == true, frameState != .failed {
            Button(action: onReview) {
                Label(reviewBadgeLabel, systemImage: reviewBadgeSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(reviewBadgeForeground)
                    .padding(.horizontal, 7)
                    .frame(minHeight: 32)
                    .background(reviewBadgeBackground, in: Capsule())
                    .overlay {
                        if reviewDecision == .dontScan {
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        }
                    }
            }
            .buttonStyle(.plain)
            .padding(5)
            .help("Review the detected boundary for frame \(frameIndex)")
            .accessibilityLabel("Review frame \(frameIndex)")
            .accessibilityHint(
                "Choose whether to use this frame, not scan it, or preview the film again."
            )
        }
    }

    private var reviewBadgeLabel: String {
        switch reviewDecision {
        case .useFrameAnyway: "Use anyway"
        case .dontScan: "Not scanning"
        case nil: "Review"
        }
    }

    private var reviewBadgeSymbol: String {
        switch reviewDecision {
        case .useFrameAnyway: "checkmark.circle.fill"
        case .dontScan: "minus.circle.fill"
        case nil: "exclamationmark.triangle.fill"
        }
    }

    private var reviewBadgeBackground: Color {
        switch reviewDecision {
        case .useFrameAnyway: .scanStudioGreen
        case .dontScan: Color.black.opacity(0.76)
        case nil: .scanStudioAmber
        }
    }

    private var reviewBadgeForeground: Color {
        reviewDecision == .dontScan
            ? Color.white.opacity(0.84)
            : Color.black.opacity(0.86)
    }

    /// Composed via `.overlay` on top of the already-constructed
    /// `tileButton`, not nested inside `tileButton`'s own `label:` closure —
    /// a `Button` nested directly inside another `Button`'s label does not
    /// reliably receive independent taps in SwiftUI, while a `Button`
    /// overlaid after construction does, so tapping this icon retries the
    /// frame instead of toggling selection.
    /// The retry control uses the same single-frame readiness as the detail
    /// workspace and accessibility action; it cannot look enabled when the
    /// model will refuse its eventual `scan.start`.
    @ViewBuilder
    private var failureActionButton: some View {
        if failureAction == .approveAndRetry {
            Button {
                performFailureAction()
            } label: {
                Label("Preview Again", systemImage: "photo.stack")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.86))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.scanStudioAmber, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(5)
            .disabled(!failureActionIsEnabled)
            .help(approvalHelp)
            .accessibilityLabel("Preview the film again before retrying frame \(frameIndex)")
            .accessibilityHint(
                "A new preview is required before another scan traversal."
            )
        } else {
            retryButton
        }
    }

    private var retryButton: some View {
        Button {
            performFailureAction()
        } label: {
            Image(systemName: "arrow.clockwise.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.black.opacity(0.62))
                .font(.system(size: 15, weight: .semibold))
        }
        .buttonStyle(.plain)
        .padding(5)
        .disabled(!failureActionIsEnabled)
        .help(retryReadiness.reason ?? "Retry this frame")
        .accessibilityLabel("Retry frame \(frameIndex)")
    }

    private var approvalHelp: String {
        if sessionModel.approvingFrameIndex != nil {
            return "Approval is already in progress."
        }
        return retryReadiness.reason
            ?? "Acquire a fresh preview before starting another scan."
    }

    private func performFailureAction() {
        guard failureActionIsEnabled else { return }
        Task {
            switch failureAction {
            case .retry:
                await sessionModel.scanSingleFrame(frameIndex)
            case .approveAndRetry:
                _ = await sessionModel.requestPreview(
                    .refreshSavedProject(token: PreviewIntentToken())
                )
            }
        }
    }

    /// Composed via `.overlay` on the tile's branch result, matching
    /// `retryButton`'s own composition — not nested inside `tileButton`'s
    /// `label:` closure, which SwiftUI does not reliably route independent
    /// taps to. Placed in the tile's top-leading region (the one corner the
    /// three existing badge-style corners — selection, state, retry — leave
    /// unclaimed), but nudged right of the existing frame-number chip that
    /// already sits flush at that literal corner, rather than reusing that
    /// chip's exact 0pt inset, so the two never visually collide.
    private var viewDetailsButton: some View {
        Button {
            sessionModel.openFrameDetail(frameIndex)
        } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.94))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.68), in: Capsule())
                .frame(
                    minWidth: ScanStudioMetrics.minimumInteractiveTarget,
                    minHeight: ScanStudioMetrics.minimumInteractiveTarget
                )
        }
        .buttonStyle(.plain)
        .padding(.leading, 20)
        .help("Edit frame alignment, rotation, and flips")
        .accessibilityLabel("Edit frame \(frameIndex)")
        .accessibilityHint("Opens the full preview and frame editing controls.")
    }

    private var accessibilityValue: String {
        var values = [isSelected ? "selected for scanning" : "not selected for scanning"]
        if isFocused { values.append("focused for editing") }
        values.append(thumbnail == nil ? "preview not acquired" : "preview acquired")
        if let frameState { values.append(frameState.rawValue) }
        if thumbnail?.needsApproval == true {
            switch reviewDecision {
            case .useFrameAnyway:
                values.append("review resolved, use anyway")
            case .dontScan:
                values.append("review resolved, not scanning")
            case nil:
                values.append("manual review required before scanning")
            }
        }
        if let orientationText = FrameOrientation.accessibilityText(orientationDegrees) { values.append(orientationText) }
        if mirrored { values.append("mirrored horizontally") }
        if verticallyMirrored { values.append("mirrored vertically") }
        // Only ever appended for the simulator's genuinely live per-frame
        // fraction (see `liveFramePercent`'s own doc comment) — VoiceOver
        // must not hear a percentage real hardware cannot back either.
        if let liveFramePercent { values.append("\(Int(liveFramePercent)) percent") }
        if transportSmearFlagged { values.append("transport smear") }
        return values.joined(separator: ", ")
    }
}

struct FrameStateBadge: View {
    let state: FrameState
    var errorCode: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if isManualReview {
                Text(label)
            }
        }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(color)
            .padding(4)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3))
            .help(helpText)
            .accessibilityLabel(helpText)
    }

    /// Never the raw engine diagnostic (`scan.frameState`'s `error.message`,
    /// PROTOCOL.md) -- that text is written for whoever is debugging the
    /// bridge, not for the person running the scanner. A known code gets its
    /// curated copy (`FrameFailureLabel`); an unrecognized one still gets a
    /// calm sentence plus the code itself, so a report at least names what
    /// happened. The raw message stays reachable through `frameErrors` for
    /// logs and evidence -- it just never renders here.
    private var helpText: String {
        if let help = FrameFailureLabel.help(forErrorCode: errorCode) {
            return "\(label): \(help)"
        }
        guard let errorCode else { return label }
        return "Scan failed (\(errorCode)). Try this frame again."
    }

    private var label: String {
        switch state {
        case .waiting: "Waiting"
        case .active: "Scanning"
        case .completed: "Completed"
        case .failed: FrameFailureLabel.label(forErrorCode: errorCode)
        case .skipped: "Skipped"
        }
    }

    private var symbol: String {
        switch state {
        case .waiting: "clock"
        case .active: "dot.radiowaves.left.and.right"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .skipped: "forward"
        }
    }

    private var color: Color {
        switch state {
        case .active: .scanStudioAmber
        case .completed: .scanStudioGreen
        case .failed: isManualReview ? .scanStudioAmber : .scanStudioRed
        case .waiting, .skipped: .scanStudioSecondaryText
        }
    }

    private var isManualReview: Bool {
        state == .failed
            && FrameFailureLabel.action(forErrorCode: errorCode) == .approveAndRetry
    }
}

/// The active tile's own capture-in-progress treatment (2026-07-26 redesign
/// — see `ThumbnailGridView.isJobActive`'s own doc comment, and
/// `ContentView.swift`'s removal of `ActiveScanWorkspaceView`, for the full
/// context: the owner wanted the whole-strip grid to stay on screen through
/// an active batch, with per-frame state overlaid on each tile, instead of
/// swapping to one blown-up crop of whichever frame is current).  Replaces
/// the plain `FrameStateBadge` corner icon for exactly this one
/// `FrameState` — every other state (`waiting`/`completed`/`failed`/
/// `skipped`) still gets that badge, unchanged.
///
/// `framePercent` is `nil` whenever the engine has no genuine per-frame
/// completion fraction for THIS tile — always true for a real LS-5000, see
/// `ThumbnailTile.liveFramePercent`'s own doc comment for the full
/// root-cause citation (`real_backend.rs`, dated 2026-07-25). In that case
/// this renders an honest indeterminate "in progress" chip: the same
/// "something is happening, no finer-grained signal exists" idiom
/// `RollLoadingWorkspaceView.swift`'s `RollLoadingFrameCell` already
/// established for thumbnail acquisition ("READING" + no fabricated
/// number), never a fabricated bar position.
private struct ScanningTileOverlay: View {
    let framePercent: Double?

    var body: some View {
        VStack(spacing: 3) {
            // `.symbolEffect(.pulse)` (macOS 14+, matches this package's own
            // deployment target) gives the tile a genuine, system-managed
            // "this one's live right now" animation without hand-rolled
            // `@State` + `repeatForever` timing that a `LazyVGrid` recycling
            // this view's identity could otherwise interrupt or desync.
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(Color.scanStudioAmber)
                .symbolEffect(.pulse)

            if let framePercent {
                ProgressView(value: framePercent, total: 100)
                    .tint(.scanStudioAmber)
                    .frame(width: 42)
                    .animation(.linear(duration: 0.15), value: framePercent)
                Text("\(Int(framePercent))%")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.scanStudioAmber)
            } else {
                Text("SCANNING")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Color.scanStudioAmber)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 4))
        // Purely decorative restatement of what `ThumbnailTile`'s own
        // `accessibilityValue` already says in words ("active", plus the
        // live percent when one genuinely exists) — hidden here so
        // VoiceOver doesn't read the same fact twice.
        .accessibilityHidden(true)
    }
}

/// Stylized film-strip scrubber for the contact-sheet workspace — a brown
/// film-stock band with sprocket-hole marks, a numeric ruler, and an amber
/// caret at `caretFrame`. Each frame's own position along the band is
/// tinted from real `frameStates`/`excludedFrames` data (the same
/// state->color mapping `ThumbnailTile`'s own border/overlay logic uses,
/// with excluded taking precedence) rather than the flat, purely
/// decorative brown band this view rendered before this plan. Click-to-
/// select is still intentionally not implemented in 2.1 (UI-SPEC: "purely
/// visual position indicator... click-to-select optional if cheap" —
/// deferred, not cheap enough to justify here).
///
/// Shown continuously now, through an active batch too (2026-07-26
/// redesign — see `ThumbnailGridView.isJobActive`'s own doc comment): this
/// view took no code changes to make that correct, since it already reads
/// live `frameStates`/`excludedFrames` off `SessionModel` rather than any
/// idle-only snapshot. The two per-frame overview strips this replaced
/// (`FilmTimelineView`/`TimelinePreview`, deleted alongside
/// `ActiveScanWorkspaceView`) drew the identical state->color mapping a
/// second time for a screen that no longer exists.
struct FilmStripScrubberView: View {
    let frameCount: Int
    let caretFrame: Int?
    let frameStates: [Int: FrameState]

    private let sprocketCount = 16

    /// 1-based frame indices for the tinted band. A `Range`, not
    /// `1...frameCount` -- that `ClosedRange` traps for a zero-frame roll,
    /// and this view renders whenever the parent grid does, including that
    /// case.
    private var frameIndices: Range<Int> {
        frameCount > 0 ? 1..<(frameCount + 1) : 1..<1
    }

    private var markers: [Int] {
        if frameCount <= 6 { return Array(frameIndices) }
        return [1, 6, 12, 18, 24, 30, frameCount]
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let bandWidth = proxy.size.width

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.29, green: 0.22, blue: 0.16))
                        .frame(height: 28)

                    HStack(spacing: 0) {
                        ForEach(frameIndices, id: \.self) { frameIndex in
                            frameTint(for: frameIndex)
                        }
                    }
                    .frame(height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    VStack {
                        sprocketRow
                        Spacer()
                        sprocketRow
                    }
                    .padding(.vertical, 5)

                    if let caretFrame {
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.scanStudioAmber)
                            .offset(x: (CGFloat(caretFrame) - 0.5) / CGFloat(frameCount) * bandWidth)
                    }
                }
            }
            .frame(height: 28)

            HStack {
                ForEach(Array(markers.enumerated()), id: \.element) { offset, marker in
                    Text("\(marker)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(marker == caretFrame ? Color.scanStudioAmber : Color.scanStudioSecondaryText)
                    if offset != markers.count - 1 { Spacer() }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caretFrame != nil ? "Film position indicator, frame \(caretFrame!) of \(frameCount)" : "Film position indicator, no frame selected")
    }

    /// Excluded takes precedence over any live `FrameState` tint, mirroring
    /// `ThumbnailTile`'s own excluded-over-frameState precedence rule (and
    /// reusing that same `Color.black.opacity(0.5)` excluded treatment for
    /// visual consistency between the grid and this scrubber).
    private func frameTint(for frameIndex: Int) -> Color {
        switch frameStates[frameIndex] {
        case .active: return Color.scanStudioAmber.opacity(0.32)
        case .completed: return Color.scanStudioGreen.opacity(0.24)
        case .failed: return Color.scanStudioRed.opacity(0.32)
        case .skipped: return Color.black.opacity(0.30)
        case .waiting, .none: return Color.clear
        }
    }

    private var sprocketRow: some View {
        HStack {
            ForEach(0..<sprocketCount, id: \.self) { index in
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 4, height: 4)
                if index != sprocketCount - 1 { Spacer() }
            }
        }
        .padding(.horizontal, 6)
    }
}

// `ActiveScanWorkspaceView` (the single-frame, upscaled "Capture Monitor"
// hero crop) and its exclusive helpers (`CaptureMonitorFrameImage`,
// `QueueThumbnail`) were removed here 2026-07-26. `ContentView.swift` no
// longer swaps this grid out for that screen during an active batch — see
// `ThumbnailGridView.isJobActive`'s own doc comment for the owner's
// original request and the redesign this enabled. Every readout that
// screen showed now lives somewhere still on screen during a job:
// `ThumbnailTile`'s per-frame overlays (this file), `ScanPanelView
// .activeActions` (Pass N of M, the queued/scanning/pausing/stopping
// phrase, ETA — relocated verbatim), `SessionSidebarView`'s activity card
// (elapsed, completed/remaining, last frame), and
// `BatchInspectorView.activeInspector` (Pass, per-outcome counts).
