import AppKit
import ScanStudioKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(SessionModel.self) private var sessionModel

    private var hasCompletePreviewRegistration: Bool {
        sessionModel.hasCompletePreviewRegistration
    }

    var body: some View {
        VStack(spacing: 0) {
            DeviceBarView()
            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)

            HStack(spacing: 0) {
                SessionSidebarView()
                    .frame(width: 248)

                ScanStudioDivider()

                VStack(spacing: 0) {
                    if let presentation = sessionModel.errorPresentation {
                        WorkspaceErrorBanner(presentation: presentation) {
                            sessionModel.dismissLastError()
                        }
                        .id(presentation.technicalDetails)
                    } else if let snapNote = sessionModel.manualPlacementSnapNote {
                        // Only shown once no error is active: a successful
                        // manual placement already clears `lastErrorMessage`,
                        // so this and the error banner above are never both
                        // relevant at once.
                        ManualPlacementSnapNoteBanner(text: snapNote) {
                            sessionModel.dismissManualPlacementSnapNote()
                        }
                    }

                    Group {
                        if sessionModel.status?.connected != true {
                            DeviceConnectionWorkspaceView()
                        } else if sessionModel.device?.kind == "simulated", sessionModel.status?.mediaLoaded != true {
                            SimulatorCarrierWorkspaceView()
                        } else if sessionModel.projectMediaMismatch,
                                  !sessionModel.isJobActive,
                                  !sessionModel.isAcquiringThumbnails
                        {
                            ProjectRegistrationMismatchWorkspaceView()
                        } else if let frameIndex = sessionModel.detailFrameIndex,
                                  !sessionModel.isJobActive,
                                  !sessionModel.isAcquiringThumbnails,
                                  sessionModel.canPresentFrameDetail(frameIndex)
                        {
                            // Alignment belongs to the live preview session,
                            // not to project creation. Let an unsaved preview
                            // open Frame Detail so the user can fix a boundary
                            // before Save Roll rather than forcing an
                            // arbitrary save-and-return detour.
                            FrameDetailWorkspaceView(frameIndex: frameIndex)
                        } else if sessionModel.project == nil, !sessionModel.isJobActive, !sessionModel.isAcquiringThumbnails {
                            // A stale status can still report loaded media
                            // after re-preview is refused. Do not offer the
                            // inline Save Roll callout until the current
                            // preview has both tiles and a committed material
                            // registration.
                            switch PreProjectPreviewPresentationPolicy.presentation(
                                hasOpenProject: false,
                                hasCompletePreviewRegistration: hasCompletePreviewRegistration
                            ) {
                            case .acquisitionGate:
                                PreviewGateWorkspaceView()
                            case .inlineSaveRollWithContactSheet:
                                PreProjectPreviewWorkspaceView()
                            case .contactSheet:
                                // This branch is unreachable while the
                                // enclosing condition requires no project;
                                // retaining it makes the policy exhaustive
                                // and keeps its saved-project contract plain.
                                ThumbnailGridView()
                            }
                        } else if sessionModel.thumbnails.isEmpty, !sessionModel.isJobActive, !sessionModel.isAcquiringThumbnails {
                            PreviewGateWorkspaceView()
                        } else if sessionModel.isAcquiringThumbnails {
                            CarrierLoadingWorkspaceView()
                                .transition(.opacity.combined(with: .offset(y: 8)))
                        } else {
                            // 2026-07-26 redesign: `ActiveScanWorkspaceView`
                            // — one blown-up, upscaled crop of whichever
                            // frame was currently scanning — is gone. The
                            // owner's own words: "i dont love the scanning
                            // interface, because its low res... but zoomed
                            // big... lets see the same view where it shows
                            // the entire strip." `ThumbnailGridView` now
                            // renders through an active batch too (this
                            // branch previously only ran while idle — a
                            // separate `else if sessionModel.isJobActive`
                            // above used to intercept first); its own
                            // `ThumbnailTile` overlays per-frame scan state
                            // — a scanning animation on the in-flight frame,
                            // a check mark on each completed one, a
                            // distinct failure marker — directly on the
                            // SAME whole-strip grid instead of swapping the
                            // center pane out entirely. See
                            // `ThumbnailGridView.isJobActive`'s own doc
                            // comment for where the few Capture Monitor
                            // readouts that had no other home ended up.
                            ThumbnailGridView()
                                .transition(.opacity)
                        }
                    }
                    .frame(minWidth: 680, maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeOut(duration: 0.22), value: sessionModel.isAcquiringThumbnails)
                }
                .frame(minWidth: 680, maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.18), value: sessionModel.lastErrorMessage != nil)

                ScanStudioDivider()

                BatchInspectorView()
                    .frame(width: 292)
            }

            if ScanPanelVisibilityPolicy.isVisible(hasOpenProject: sessionModel.project != nil) {
                Rectangle().fill(Color.scanStudioDivider).frame(height: 1)
                ScanPanelView()
            }
        }
        .background(Color.scanStudioWorkspace)
        .foregroundStyle(Color.scanStudioPrimaryText)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1_220, minHeight: 760)
        .sheet(item: manualReviewRequestBinding) { request in
            ManualReviewScanSheet(request: request)
        }
        .sheet(item: manualPlacementStripBinding) { strip in
            ManualFramePlacementSheet(strip: strip)
        }
        .focusedSceneValue(
            \.scanStudioFrameIndex,
            sessionModel.frameTransformTargetIndex
        )
    }

    private var manualReviewRequestBinding: Binding<ManualReviewScanRequest?> {
        Binding(
            get: { sessionModel.pendingManualReviewScan },
            set: { newValue in
                if newValue == nil {
                    sessionModel.cancelPendingManualReviewScan()
                }
            }
        )
    }

    /// Rung 4: presents `ManualFramePlacementSheet` exactly while
    /// `manualPlacementStripState` is `.ready` -- `.idle`/`.loading` both
    /// map to no sheet, so the loading interval is shown on the "Place
    /// frames manually" button itself (`WorkspaceErrorBanner`) rather than
    /// as an empty sheet.
    private var manualPlacementStripBinding: Binding<ManualPlacementStrip?> {
        Binding(
            get: {
                if case .ready(let strip) = sessionModel.manualPlacementStripState {
                    return strip
                }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    sessionModel.cancelManualFramePlacement()
                }
            }
        )
    }
}

/// The one explicit operator boundary between preview evidence and physical
/// fine-scan motion. It shows the actual flagged preview(s), not only a
/// technical warning, and states that confirmation resumes the original
/// complete batch as one scan.
private struct ManualReviewScanSheet: View {
    @Environment(SessionModel.self) private var sessionModel
    @Environment(\.dismiss) private var dismiss

    let request: ManualReviewScanRequest

    private var isApproving: Bool {
        sessionModel.approvingFrameIndex != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.scanStudioAmber)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Review before scanning")
                        .font(.system(size: 20, weight: .semibold))
                    Text(reviewSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(request.requirements) { requirement in
                        reviewCard(requirement)
                    }
                }
            }
            .frame(maxHeight: 330)

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "The fine scan has not started.",
                    systemImage: "pause.circle.fill"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.scanStudioAmber)

                Text(
                    "After confirmation, ScanStudio approves the flagged "
                    + "preview \(request.requirements.count == 1 ? "boundary" : "boundaries") "
                    + "and sends the original \(request.frames.count)-frame request once."
                )
                .font(.system(size: 11))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Curated title, not the raw `lastErrorMessage` -- an operator
            // confirming physical scanner motion needs true, calm
            // information here, not an echoed engine diagnostic.
            if let title = sessionModel.errorPresentation?.title {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    sessionModel.cancelPendingManualReviewScan()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isApproving)

                Spacer()

                Button {
                    Task {
                        await sessionModel.approvePendingManualReviewAndStart()
                    }
                } label: {
                    if let frameIndex = sessionModel.approvingFrameIndex {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Approving Frame \(frameIndex)…")
                        }
                        .frame(minWidth: 190)
                    } else {
                        Label(
                            approvalButtonLabel,
                            systemImage: "scanner.fill"
                        )
                        .frame(minWidth: 190)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.scanStudioAmber)
                .foregroundStyle(.black)
                .disabled(isApproving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(Color.scanStudioWorkspace)
        .foregroundStyle(Color.scanStudioPrimaryText)
        .interactiveDismissDisabled(isApproving)
    }

    private var reviewSummary: String {
        let count = request.requirements.count
        return count == 1
            ? "One preview boundary needs your confirmation before this "
                + "\(request.frames.count)-frame scan can begin."
            : "\(count) preview boundaries need your confirmation before this "
                + "\(request.frames.count)-frame scan can begin."
    }

    private var approvalButtonLabel: String {
        let noun = request.frames.count == 1 ? "Frame" : "Frames"
        return "Confirm & Scan \(request.frames.count) \(noun)"
    }

    @ViewBuilder
    private func reviewCard(
        _ requirement: ManualReviewRequirement
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ThumbnailTileImage(
                frameIndex: requirement.frameIndex,
                thumbnail: sessionModel.thumbnails[requirement.frameIndex],
                orientationDegrees: sessionModel.frameOrientation(
                    requirement.frameIndex
                ),
                mirrored: sessionModel.frameMirror(requirement.frameIndex),
                verticallyMirrored: sessionModel.frameVerticalMirror(
                    requirement.frameIndex
                )
            )
            .aspectRatio(
                FrameOrientation.displayAspectRatio(
                    sessionModel.frameOrientation(requirement.frameIndex)
                ),
                contentMode: .fit
            )
            .frame(width: 190)
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

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(
                        "Frame \(String(format: "%02d", requirement.frameIndex))"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    InlineTag(text: "Needs review", color: .scanStudioAmber)
                }

                Text(humanReviewReason(requirement.warnings))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if !requirement.warnings.isEmpty {
                    Text(
                        "Evidence: "
                            + requirement.warnings.joined(separator: ", ")
                    )
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(
                        Color.scanStudioSecondaryText.opacity(0.72)
                    )
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            Color.scanStudioRaised,
            in: RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius)
        )
    }

    private func humanReviewReason(_ warnings: [String]) -> String {
        if warnings.contains("ambiguous-content-tail-boundary") {
            return "The final detected film edge is ambiguous. Confirm that "
                + "this preview contains a real frame you want included."
        }
        return "The scanner could not establish this frame boundary with "
            + "enough confidence. Confirm the preview before continuing."
    }
}

/// Prominent, dismissible failure banner pinned to the center workspace.
/// Immediate copy is human and actionable; the untouched local diagnostic
/// stays selectable behind an explicit disclosure, while issue reporting
/// uses `ErrorPresentation`'s separately privacy-scrubbed URL. The
/// underlying `lastErrorMessage` lifecycle remains unchanged.
private struct WorkspaceErrorBanner: View {
    let presentation: ErrorPresentation
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(SessionModel.self) private var sessionModel
    @State private var isShowingTechnicalDetails = false
    @State private var didCopyTechnicalDetails = false
    @State private var didSaveDiagnosticBundle = false
    @State private var diagnosticBundleSaveError: String?

    private var isLoadingManualPlacement: Bool {
        sessionModel.manualPlacementStripState == .loading
    }

    /// Rung 4 is reachable whenever this refusal classifies as
    /// `REFEED_REQUIRED` (`ErrorPresentation.canPlaceFramesManually`) and
    /// the session is still in the "current physical registration cannot be
    /// trusted" state `beginManualFramePlacement()` depends on -- the same
    /// `refeedRequired` flag that gates `DeviceBarView`'s Eject affordance.
    private var showsManualPlacementAction: Bool {
        presentation.canPlaceFramesManually && sessionModel.refeedRequired
    }

    /// Attended binding (feed-detector round; issues #24/#16/#42). Offered
    /// only when the policy classified this refusal as the rescuable
    /// (medium) confidence gate AND there are frames selected to approve --
    /// the action approves every selected frame and re-scans, so with an
    /// empty selection it would have nothing to authorize.
    private var showsApproveEveryFrameAction: Bool {
        presentation.canApproveEveryFrameAndScan
            && !sessionModel.selectedFrames.isEmpty
    }

    private var isApprovingEveryFrame: Bool {
        sessionModel.approvingFrameIndex != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.scanStudioRed)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.scanStudioPrimaryText)
                        Text(presentation.guidance)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.scanStudioSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Error: \(presentation.title). \(presentation.guidance)")

                    Spacer(minLength: 12)

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
                }

                // Rung 3 + Rung 4 of the feeding UX ladder
                // (FEEDING-UX-LADDER-OVERNIGHT-20260807.md): the
                // manual-placement action is offered for every
                // REFEED_REQUIRED this session can actually recover from
                // (`showsManualPlacementAction`), not only the minority
                // that also carry a Rung-3 diagnosis (issue #16). When the
                // engine attached that plain-English diagnosis, show it
                // prominently -- never the raw JSON it was extracted from
                // (`ProbableCauseExtractor`) -- right above the button.
                // The two are independent: the sentence renders on its own
                // when `refeedRequired` has since cleared (a disconnect
                // composes NOT_CONNECTED over the old message), and the
                // button renders without a sentence for undiagnosed
                // refeeds.
                if showsManualPlacementAction
                    || showsApproveEveryFrameAction
                    || presentation.probableCause != nil
                {
                    VStack(alignment: .leading, spacing: 8) {
                        if let probableCause = presentation.probableCause {
                            Text(probableCause)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.scanStudioPrimaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }

                        if showsManualPlacementAction {
                            Button {
                                Task {
                                    await sessionModel.beginManualFramePlacement()
                                }
                            } label: {
                                if isLoadingManualPlacement {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Loading Film Strip…")
                                    }
                                } else {
                                    Label(
                                        "Place frames manually",
                                        systemImage: "rectangle.and.hand.point.up.left"
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.scanStudioAmber)
                            .font(.system(size: 11, weight: .medium))
                            .disabled(isLoadingManualPlacement)
                            .help("Draw your own frame boundaries on the captured film strip")
                        }

                        // Attended binding (feed-detector round; issues
                        // #24/#16/#42). The operator is standing at the
                        // scanner looking at correct thumbnails the
                        // detector could not fully corroborate. This
                        // approves every selected frame against the exact
                        // preview they reviewed and re-issues the scan.
                        if showsApproveEveryFrameAction {
                            Button {
                                Task {
                                    await sessionModel.approveEveryFrameAndScan()
                                }
                            } label: {
                                if isApprovingEveryFrame {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("Approving Frames…")
                                    }
                                } else {
                                    Label(
                                        "Approve every frame and scan",
                                        systemImage: "checkmark.seal"
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.scanStudioAmber)
                            .font(.system(size: 11, weight: .medium))
                            .disabled(isApprovingEveryFrame)
                            .help(
                                "Confirm the previewed framing yourself and scan the "
                                + "selected frames with you supervising"
                            )
                        }
                    }
                    .padding(10)
                    .background(Color.scanStudioRaised, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        presentation.probableCause.map { "Probable cause: \($0)" }
                            ?? (showsApproveEveryFrameAction
                                ? "Approving every frame yourself is available"
                                : "Manual frame placement is available")
                    )
                }

                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isShowingTechnicalDetails.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(isShowingTechnicalDetails ? 90 : 0))
                            Text("Technical details")
                        }
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .accessibilityValue(isShowingTechnicalDetails ? "Expanded" : "Collapsed")

                    Spacer(minLength: 8)

                    Button {
                        openURL(presentation.issueURL)
                    } label: {
                        Label("Open an issue…", systemImage: "arrow.up.right.square")
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .help("Open a privacy-scrubbed GitHub issue draft")
                    .accessibilityLabel("Open an issue on GitHub")
                }

                if isShowingTechnicalDetails {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Local diagnostic")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.scanStudioSecondaryText)
                            Spacer()
                            Button {
                                copyTechnicalDetails()
                            } label: {
                                Label(
                                    didCopyTechnicalDetails ? "Copied" : "Copy",
                                    systemImage: didCopyTechnicalDetails ? "checkmark" : "doc.on.doc"
                                )
                                .frame(minWidth: 64, minHeight: 32)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                            .accessibilityLabel("Copy technical details")

                            Button {
                                saveDiagnosticBundle()
                            } label: {
                                Label(
                                    didSaveDiagnosticBundle ? "Saved" : "Save Diagnostic Bundle…",
                                    systemImage: didSaveDiagnosticBundle ? "checkmark" : "shippingbox"
                                )
                                .frame(minHeight: 32)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                            .help(
                                "Save a zip with this session's diagnostics, the report, "
                                    + "and the roll preview when one is available"
                            )
                            .accessibilityLabel("Save diagnostic bundle")
                        }

                        if let diagnosticBundleSaveError {
                            Text(diagnosticBundleSaveError)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.scanStudioRed)
                                .textSelection(.enabled)
                                .accessibilityLabel(
                                    "Diagnostic bundle save failed: \(diagnosticBundleSaveError)"
                                )
                        }

                        ScrollView(.vertical) {
                            Text(presentation.technicalDetails)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.scanStudioPrimaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                        .padding(10)
                        .background(
                            Color.scanStudioRaised,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.scanStudioRed.opacity(0.14))

            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func copyTechnicalDetails() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(presentation.technicalDetails, forType: .string)
        didCopyTechnicalDetails = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopyTechnicalDetails = false
        }
    }

    /// Presents a native save panel, then writes `SessionModel
    /// .makeDiagnosticBundleData()`'s zip bytes verbatim -- this view never
    /// builds the archive itself, so the saved bundle always matches
    /// whatever ScanStudioKit assembled (T-ERR-04).
    private func saveDiagnosticBundle() {
        didSaveDiagnosticBundle = false
        diagnosticBundleSaveError = nil
        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Bundle"
        panel.nameFieldStringValue = "ScanStudio-Diagnostics-\(Self.diagnosticBundleTimestamp()).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data = sessionModel.makeDiagnosticBundleData()
        do {
            try DiagnosticBundleFileWriter.write(data, to: url)
            didSaveDiagnosticBundle = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                didSaveDiagnosticBundle = false
            }
        } catch let error as DiagnosticBundleSaveError {
            diagnosticBundleSaveError = error.localizedDescription
        } catch {
            diagnosticBundleSaveError =
                "DIAGNOSTIC_WRITE_FAILED: Could not save the diagnostic bundle: "
                + error.localizedDescription
        }
    }

    private static func diagnosticBundleTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
    }
}

/// Rung 4's "surface snaps subtly" requirement: a single quiet line, never
/// styled as an error (`scanStudioRaised`, not `scanStudioRed`), shown only
/// while no error is active (`ContentView`'s own `if/else if` with
/// `WorkspaceErrorBanner`) -- a successful manual placement already
/// resolved whatever was showing before it.
private struct ManualPlacementSnapNoteBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioAmber)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                Spacer(minLength: 12)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.scanStudioSecondaryText)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            .background(Color.scanStudioRaised)

            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct DeviceConnectionWorkspaceView: View {
    @Environment(SessionModel.self) private var sessionModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "scanner")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Color.scanStudioCyan)

            switch DeviceSelectionPolicy.state(
                isDiscovering: sessionModel.isDiscoveringDevices,
                isConnecting: sessionModel.isConnectingDevice,
                devices: sessionModel.availableDevices
            ) {
            case .discovering:
                connectionProgress(.discovering)
            case .connecting:
                connectionProgress(.connecting)
            case .noDevices:
                Text("No scanner found")
                    .font(.system(size: 19, weight: .semibold))
                Button("Look Again") { Task { await sessionModel.refreshAvailableDevices() } }
                    .buttonStyle(.bordered)
            case .unsupported(let devices):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.secondary)
                    ForEach(devices, id: \.deviceId) { device in
                        VStack(spacing: 4) {
                            Text("\(device.model) detected")
                                .font(.system(size: 16, weight: .semibold))
                            Text("This model is not yet supported (LS-5000 only today). Follow rohanpandula/ScanStudio#14 for updates.")
                                .font(.system(size: 12))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Color.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(Color.secondary)
                    }
                }
            case .directConnect(let device):
                deviceCard(device)
                unsupportedCards(DeviceSelectionPolicy.unsupportedDevices(from: sessionModel.availableDevices))
            case .explicitChoice(let devices):
                Text("Choose a scanner")
                    .font(.system(size: 19, weight: .semibold))
                ForEach(devices, id: \.deviceId) { device in
                    deviceCard(device)
                }
                unsupportedCards(DeviceSelectionPolicy.unsupportedDevices(from: sessionModel.availableDevices))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.scanStudioWorkspace)
    }

    @ViewBuilder
    private func unsupportedCards(_ devices: [DeviceInfo]) -> some View {
        if !devices.isEmpty {
            VStack(spacing: 6) {
                ForEach(devices, id: \.deviceId) { device in
                    Text("\(device.model) detected — not yet supported (LS-5000 only today). Follow rohanpandula/ScanStudio#14 for updates.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                }
            }
        }
    }

    private func connectionProgress(_ state: DeviceSelectionPolicy.State) -> some View {
        let text = state.progressText ?? ""
        return VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 16, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private func deviceCard(_ device: DeviceInfo) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(device.model)
                    .font(.system(size: 15, weight: .semibold))
                if device.kind == "simulated" {
                    DeviceProvenanceBadge(kind: device.kind)
                } else if device.kind == "real" {
                    Text(device.connection.uppercased())
                        .font(.system(size: 11))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }
            }
            Button(DeviceSelectionPolicy.connectLabel(for: device)) {
                Task { await sessionModel.connect(deviceId: device.deviceId) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.scanStudioAmber)
            .foregroundStyle(.black)
        }
        .padding(16)
        .background(Color.scanStudioRaised, in: RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(DeviceSelectionPolicy.menuLabel(for: device)). \(DeviceSelectionPolicy.connectLabel(for: device))")
    }
}

private struct SimulatorCarrierWorkspaceView: View {
    @Environment(SessionModel.self) private var sessionModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Color.scanStudioAmber)
            Text("Choose a film holder")
                .font(.system(size: 19, weight: .semibold))
            Text("Simulator only — choose the film holder you want to work with.")
                .font(.system(size: 13))
                .foregroundStyle(Color.scanStudioSecondaryText)
            HStack(spacing: 10) {
                ForEach(SimulatedFilmCarrier.allCases) { carrier in
                    Button(carrier.displayName) {
                        Task { await sessionModel.loadCarrier(carrier) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(sessionModel.isAcquiringThumbnails || sessionModel.status?.transport != "idle")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.scanStudioWorkspace)
    }
}

/// Keeps a successful, unsaved preview visible while making saving the roll
/// the next clear action. The grid owns the evidence and frame interactions;
/// this compact callout owns only project creation and film-type replacement.
private struct PreProjectPreviewWorkspaceView: View {
    @Environment(SessionModel.self) private var sessionModel
    @State private var isShowingProjectLauncher = false
    @State private var processPreviewToken: PreviewIntentToken?

    var body: some View {
        VStack(spacing: 0) {
            saveRollCallout
            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)
            ThumbnailGridView()
        }
        .background(Color.scanStudioWorkspace)
        .sheet(isPresented: $isShowingProjectLauncher) {
            ProjectLauncherView(
                session: sessionModel,
                purpose: .saveRollAndScan
            )
        }
        .sheet(item: $processPreviewToken) { token in
            RePreviewProcessSheet(session: sessionModel, intentToken: token)
        }
    }

    private var saveRollCallout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                calloutCopy
                Spacer(minLength: 8)
                calloutActions
            }

            VStack(alignment: .leading, spacing: 10) {
                calloutCopy
                calloutActions
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(minHeight: 68, alignment: .leading)
        .background(Color.scanStudioWorkspace)
    }

    private var calloutCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(sessionModel.thumbnailCount) previews ready · \(sessionModel.selectedFrameCount) selected")
                .font(.system(size: 15, weight: .semibold))
            Text(calloutGuidance)
                .font(.system(size: 11))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 300, alignment: .leading)
    }

    private var unresolvedReviewCount: Int {
        sessionModel.selectedFrames.filter { frameIndex in
            sessionModel.thumbnails[frameIndex]?.needsApproval == true
                && sessionModel.manualReviewDecision(for: frameIndex) != .useFrameAnyway
        }.count
    }

    private var calloutGuidance: String {
        if unresolvedReviewCount == 1 {
            return "One selected frame needs a boundary check. Save now; its review opens next, before any scan starts."
        }
        if unresolvedReviewCount > 1 {
            return "\(unresolvedReviewCount) selected frames need boundary checks. Save now; those reviews open next, before any scan starts."
        }
        return "Save once to name this roll and start scanning the selected frames."
    }

    private var calloutActions: some View {
        HStack(spacing: 10) {
            Button("Change Film Type…") {
                processPreviewToken = PreviewIntentToken()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                isShowingProjectLauncher = true
            } label: {
                Label(saveAndScanButtonLabel, systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.scanStudioAmber)
            .foregroundStyle(.black)
            .controlSize(.regular)
            .disabled(sessionModel.selectedFrameCount == 0)
            .help(
                sessionModel.selectedFrameCount == 0
                    ? "Select at least one frame to scan."
                    : "Save the roll and continue into review or scanning."
            )
        }
    }

    private var saveAndScanButtonLabel: String {
        let count = sessionModel.selectedFrameCount
        return unresolvedReviewCount > 0
            ? "Save & Review \(count)…"
            : "Save & Scan \(count)…"
    }
}

private struct RePreviewProcessSheet: View {
    @Bindable var session: SessionModel
    let intentToken: PreviewIntentToken
    @Environment(\.dismiss) private var dismiss
    @State private var process: FilmProcess

    init(session: SessionModel, intentToken: PreviewIntentToken) {
        self.session = session
        self.intentToken = intentToken
        _process = State(initialValue: session.previewFilmProcess ?? session.scanFilmProcess)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Film Type & Preview Again")
                .font(.headline)
            Picker("Film process", selection: $process) {
                Text("Positive").tag(FilmProcess.positive)
                Text("Color negative").tag(FilmProcess.c41ColorNegative)
                Text("B&W negative").tag(FilmProcess.bwNegative)
                Text("Kodachrome").tag(FilmProcess.kodachrome)
            }
            Text("This replaces the current preview registration before scanning or saving the roll.")
                .font(.footnote)
                .foregroundStyle(Color.scanStudioSecondaryText)
            HardwareMotionReadinessView()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Preview Again") {
                    let intent = PreviewIntent.replaceFilmProcess(
                        token: intentToken,
                        filmProcess: process
                    )
                    Task {
                        _ = await session.requestPreview(intent)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.hardwareMotionReadiness.allowsMotion)
                .help(session.hardwareMotionReadiness.allowsMotion
                    ? "Preview the film again"
                    : session.hardwareMotionReadiness.guidance)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

private struct PreviewGateWorkspaceView: View {
    @Environment(SessionModel.self) private var sessionModel
    @State private var confirmation: PreviewIntentPresentation?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Color.scanStudioAmber)
            Text(sessionModel.device?.kind == "real" && sessionModel.project == nil ? "Preview the film first" : "Preview the film")
                .font(.system(size: 19, weight: .semibold))
            Text(sessionModel.device?.kind == "real" && sessionModel.project == nil
                ? "Read the frame previews to detect the actual frame count before saving the roll."
                : "Read the frame previews before choosing frames to scan.")
                .font(.system(size: 13))
                .foregroundStyle(Color.scanStudioSecondaryText)
            HardwareMotionReadinessView()
                .frame(maxWidth: 520)
            if let project = sessionModel.project {
                LabeledContent("Film process", value: previewProcessLabel(project.filmProcess))
                    .frame(maxWidth: 300)
            } else {
                Picker("Film process", selection: previewFilmProcessBinding) {
                    Text("Positive").tag(FilmProcess.positive)
                    Text("Color negative").tag(FilmProcess.c41ColorNegative)
                    Text("B&W negative").tag(FilmProcess.bwNegative)
                    Text("Kodachrome").tag(FilmProcess.kodachrome)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
            Button("Acquire Previews") {
                let token = PreviewIntentToken()
                let intent: PreviewIntent = if sessionModel.project == nil {
                    .initial(token: token)
                } else {
                    .refreshSavedProject(token: token)
                }
                confirmation = PreviewIntentPresentation(intent: intent)
            }
            .buttonStyle(.borderedProminent)
            .tint(.scanStudioAmber)
            .foregroundStyle(.black)
            .disabled(
                sessionModel.status?.transport != "idle"
                    || !sessionModel.hardwareMotionReadiness.allowsMotion
            )
            .help(sessionModel.hardwareMotionReadiness.allowsMotion
                ? "Open the explicit preview confirmation"
                : sessionModel.hardwareMotionReadiness.guidance)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.scanStudioWorkspace)
        .sheet(item: $confirmation) { presentation in
            AcquirePreviewConfirmationSheet(
                session: sessionModel,
                intent: presentation.intent
            )
        }
    }

    private var previewFilmProcessBinding: Binding<FilmProcess> {
        Binding(get: { sessionModel.scanFilmProcess }, set: { newValue in
            sessionModel.scanFilmProcess = newValue
            if newValue == .bwNegative {
                sessionModel.scanChannels = "rgb"
                sessionModel.digitalIceEnabled = false
            }
        })
    }

    private func previewProcessLabel(_ process: FilmProcess) -> String {
        switch process {
        case .positive: "Positive"
        case .c41ColorNegative: "Color negative"
        case .bwNegative: "B&W negative"
        case .kodachrome: "Kodachrome"
        }
    }
}

private struct PreviewIntentPresentation: Identifiable {
    let id = UUID()
    let intent: PreviewIntent
}

private struct AcquirePreviewConfirmationSheet: View {
    @Bindable var session: SessionModel
    let intent: PreviewIntent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Acquire previews?")
                .font(.headline)
            Text("This moves the film through the scanner to read the available frames.")
                .font(.footnote)
                .foregroundStyle(Color.scanStudioSecondaryText)
            HardwareMotionReadinessView()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Acquire Previews") {
                    let admittedIntent = intent
                    Task {
                        _ = await session.requestPreview(admittedIntent)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.hardwareMotionReadiness.allowsMotion)
                .help(session.hardwareMotionReadiness.allowsMotion
                    ? "Acquire previews"
                    : session.hardwareMotionReadiness.guidance)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

/// A saved project's registration is immutable. When a fresh real preview
/// establishes a different frame count, never let the familiar grid imply
/// that its old indices are safe to scan; guide the operator to a matching
/// project instead.
private struct ProjectRegistrationMismatchWorkspaceView: View {
    @Environment(SessionModel.self) private var sessionModel
    @State private var isShowingProjectLauncher = false

    private var previewedFrameCount: Int { sessionModel.status?.frameCount ?? 0 }
    private var projectFrameCount: Int { sessionModel.project?.frameCount ?? 0 }
    private var holderMismatches: Bool { sessionModel.project?.carrier != sessionModel.loadedCarrier }
    private var countMismatches: Bool { previewedFrameCount != projectFrameCount }

    private var mismatchDescription: String {
        let holderDescription = "The previewed holder is \(sessionModel.carrierDisplayName), but the open project is for \(sessionModel.project?.carrier.displayName ?? "a different film type")."
        let countDescription = "The preview found \(previewedFrameCount) frames, but the open project has \(projectFrameCount)."
        switch (holderMismatches, countMismatches) {
        case (true, true): return "\(holderDescription) \(countDescription) Create or open a matching project before scanning."
        case (true, false): return "\(holderDescription) Create or open a matching project before scanning."
        case (false, true): return "\(countDescription) Create or open a matching project before scanning."
        case (false, false): return "Create or open a matching project before scanning."
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.3.group.bubble.left")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Color.scanStudioAmber)
            Text("This preview does not match the saved roll")
                .font(.system(size: 19, weight: .semibold))
            Text(mismatchDescription)
                .font(.system(size: 13))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
            Button {
                isShowingProjectLauncher = true
            } label: {
                Label("Create Matching Project…", systemImage: "folder.badge.plus")
                    .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .tint(.scanStudioAmber)
            .foregroundStyle(.black)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.scanStudioWorkspace)
        .sheet(isPresented: $isShowingProjectLauncher) {
            ProjectLauncherView(session: sessionModel)
        }
    }
}
