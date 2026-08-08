import AppKit
import ScanStudioKit
import SwiftUI

/// The single-frame detail workspace: a large zoomable/pannable preview, a
/// filmstrip row for jumping directly between frames without returning to
/// the contact-sheet grid, a "Scan Frame NN" CTA that scans exactly this
/// frame regardless of the grid's current batch selection, and the
/// per-frame override editor for capture/processing/output — the one piece
/// of SHEET-03 that genuinely needs its own screen rather than a toolbar
/// menu. Mirrors this app's established workspace-header/divider/content
/// layout (`ThumbnailGridView`), extended with a matching divider + footer
/// at the bottom for the Scan Frame NN CTA — the
/// same header/divider/content/divider/footer shape `ContentView` itself
/// already uses at the whole-app level (`DeviceBarView` / divider / main
/// `HStack` / divider / `ScanPanelView`).
struct FrameDetailWorkspaceView: View {
    let frameIndex: Int

    @Environment(SessionModel.self) private var sessionModel

    @State private var zoomState = FrameDetailZoomState()

    /// Deliberately NOT reset inside `.task(id: frameIndex)` — unlike
    /// `zoomScale`/`panOffset` (a per-image viewport that must reset), a
    /// reviewer switching frames via the filmstrip while inspecting defects
    /// across a whole roll should stay in Defect Map mode; resetting it
    /// every frame would make batch defect review unusable.
    @State private var viewingMode: FrameViewingMode = .finalPositive
    @State private var overlayOpacity: Double = 0.7

    /// Filter-chip state (DEF-02) — also NOT reset per frame, same
    /// reasoning as `viewingMode`/`overlayOpacity` above: a reviewer who
    /// hides dust to focus on scratches across a whole roll shouldn't have
    /// that choice reset every time the filmstrip advances a frame.
    @State private var showDust = true
    @State private var showScratches = true
    @State private var showUncertain = true

    /// Which defect Previous/Next/tap has selected, if any. Unlike the
    /// filter toggles above, this DOES reset inside `.task(id: frameIndex)`
    /// — it indexes into a frame-specific defect list, so leaving it set
    /// while switching frames would either point at nothing or, worse,
    /// silently point at a same-id-coincidence defect on the new frame.
    /// Read through `effectiveSelectedDefectID` below, never directly, so a
    /// filter change or a fresh fetch can never leave this pointing at a
    /// defect that's no longer visible.
    @State private var selectedDefectID: Int?

    /// `nil` = this section is collapsed, showing only "Using roll default"
    /// plus an "Override for This Frame" button. Non-`nil` = the editable
    /// rows are revealed, seeded either from the roll-wide recipe (freshly
    /// started via that button) or from this frame's already-saved override
    /// (revealed automatically — see `syncOverrideDrafts()`).
    @State private var captureDraft: CaptureRecipe?
    @State private var processingDraft: ProcessingRecipe?
    @State private var outputDraft: OutputRecipe?
    @State private var metadataDraft: MetadataSet?

    /// Which frame `sessionModel.metadataPreview` was actually fetched for —
    /// see `metadataPreviewForCurrentFrame` below for why this client-side
    /// tracking is necessary. The last `applyMetadata` result shown in the
    /// same panel. Both are purely transient, per-frame banners — never
    /// persisted, and always cleared inside `.task(id: frameIndex)` so
    /// switching frames via the filmstrip never leaks one frame's
    /// in-progress preview or apply-result banner into another's view.
    @State private var metadataPreviewFrameIndex: Int?
    @State private var metadataApplyResult: ApplyMetadataResult?

    private var frameCount: Int {
        max(sessionModel.status?.frameCount ?? 0, sessionModel.thumbnails.keys.max() ?? 0, frameIndex)
    }
    /// 1-based frame indices for the filmstrip row. A `Range`, not
    /// `1...frameCount` -- that `ClosedRange` traps whenever `frameCount`
    /// is non-positive, and this stays an empty `Range` in that case
    /// instead.
    private var frameIndices: Range<Int> {
        frameCount > 0 ? 1..<(frameCount + 1) : 1..<1
    }

    /// The exact same readiness decision as the contact sheet's batch Scan.
    /// A detail view may choose a single valid frame instead of the current
    /// selection, but it cannot bypass the connection/project/transport gate.
    private var frameScanReadiness: ScanReadinessPolicy.Decision {
        sessionModel.scanReadiness(for: [frameIndex])
    }

    private var currentProjectFrame: ProjectFrame? {
        sessionModel.project?.frames.first(where: { $0.index == frameIndex })
    }
    private var currentCaptureOverride: CaptureRecipe? { currentProjectFrame?.captureOverride }
    private var currentProcessingOverride: ProcessingRecipe? { currentProjectFrame?.processingOverride }
    private var currentOutputOverride: OutputRecipe? { currentProjectFrame?.outputOverride }
    private var currentMetadataOverride: MetadataSet? { currentProjectFrame?.metadataOverride }

    /// The roll preview, not a frame-level legacy override, owns capture
    /// material. This keeps a reopened B&W project truthful even when an
    /// older manifest still contains a conflicting per-frame recipe.
    private var rollFilmProcess: FilmProcess {
        sessionModel.project?.filmProcess ?? sessionModel.processingRecipe.filmProcess
    }

    private var isBlackAndWhiteRoll: Bool { rollFilmProcess == .bwNegative }

    /// Only valid for display when it matches the frame currently open —
    /// `PreviewMetadataCommandResult` carries no `frameIndex` field of its
    /// own (per `WireProtocol.swift`), and `sessionModel.metadataPreview` is
    /// intentionally a single last-result slot, not a per-frame cache (see
    /// that property's own doc comment). Tracking which frame it was fetched
    /// for here, client-side, is what lets the ExifTool panel below correctly
    /// treat a still-resident previous frame's preview as stale the instant
    /// the filmstrip advances — without needing any engine-side change.
    private var metadataPreviewForCurrentFrame: PreviewMetadataCommandResult? {
        guard metadataPreviewFrameIndex == frameIndex else { return nil }
        return sessionModel.metadataPreview
    }

    // MARK: - Defect filtering / navigation (DEF-02)

    /// This frame's full, unfiltered defect set — the counts row and each
    /// filter chip's own count both read from this, never from
    /// `visibleDefectsForFrame`, so a chip's number never changes out from
    /// under it when a SIBLING chip is toggled off.
    private var allDefectsForFrame: [DefectInstance] {
        sessionModel.frameDefects[frameIndex]?.defects ?? []
    }

    /// The cached `analyzeFrameDefects` result for this frame, including
    /// provenance signals used by the legend and empty-state branching.
    private var currentDefectAnalysis: AnalyzeFrameDefectsResult? {
        sessionModel.frameDefects[frameIndex]
    }
    private var dustCountForFrame: Int { allDefectsForFrame.filter { $0.kind == .dust }.count }
    private var scratchCountForFrame: Int { allDefectsForFrame.filter { $0.kind == .scratch }.count }
    private var uncertainCountForFrame: Int { allDefectsForFrame.filter { $0.classification == .uncertain }.count }

    /// The one call site both the overlay and Previous/Next read from —
    /// reuses `ScanStudioKit`'s pure `visibleDefects` rather than
    /// re-deriving the same filter logic inline.
    private var visibleDefectsForFrame: [DefectInstance] {
        visibleDefects(
            allDefectsForFrame,
            filters: DefectMapFilters(showDust: showDust, showScratches: showScratches, showUncertain: showUncertain)
        )
    }

    /// `selectedDefectID` self-heals through this computed property whenever
    /// filters change or data (re)loads: a hidden or stale raw selection
    /// falls back to the first currently-visible defect, with no `onChange`
    /// handler needed anywhere. The loupe and connector (Task 2) always read
    /// this, never the raw `@State` directly.
    private var effectiveSelectedDefectID: Int? {
        if let selectedDefectID, visibleDefectsForFrame.contains(where: { $0.id == selectedDefectID }) {
            return selectedDefectID
        }
        return visibleDefectsForFrame.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    previewSection
                    if viewingMode == .defectMap {
                        defectMapControlsSection
                    }
                    filmstripSection
                    overridesSection
                    exifToolPanel
                }
                .padding(20)
            }

            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)
            footerCTA
        }
        .background(Color.scanStudioWorkspace)
        // Runs once on first appearance and again every time `frameIndex`
        // changes — jumping via the filmstrip reuses this same view's
        // identity (same type, same position in `ContentView`'s branch), so
        // `@State` would otherwise leak the previous frame's in-progress
        // draft/zoom into the newly-selected frame without this.
        .task(id: frameIndex) {
            syncOverrideDrafts()
            selectedDefectID = nil
            metadataPreviewFrameIndex = nil
            metadataApplyResult = nil
            if sessionModel.frameDefects[frameIndex] == nil {
                await sessionModel.analyzeFrameDefects(frameIndex)
            }
        }
    }

    // MARK: - Header

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Button {
                sessionModel.closeFrameDetail()
            } label: {
                Label("Back to Contact Sheet", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("Frame \(String(format: "%02d", frameIndex)) of \(frameCount)")
                    .font(.system(size: 17, weight: .semibold))
                Text(sessionModel.carrierDisplayName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }

            Spacer()

        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    // MARK: - Large preview (zoom / pan)

    /// Prefers a real backend thumbnail's `imagePath` (Phase 10's real-tile
    /// rendering) the same way `ThumbnailGridView`'s own `ThumbnailTileImage`
    /// does, falling back to the shared simulated crop otherwise — this
    /// view's zoom/pan is a real interaction control over whichever image is
    /// actually available, never a claim of new higher-resolution data.
    private var realPreviewImage: NSImage? {
        guard let path = sessionModel.thumbnails[frameIndex]?.imagePath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    /// The defect the loupe and its dashed connector both target — `nil`
    /// whenever there's nothing currently visible to select (filters hid
    /// everything, Digital ICE is off, or the fetch hasn't landed yet), in
    /// which case neither renders. Single lookup shared by both overlays
    /// below rather than repeating the same `first(where:)` twice.
    private var selectedDefectForLoupe: DefectInstance? {
        visibleDefectsForFrame.first(where: { $0.id == effectiveSelectedDefectID })
    }

    private var previewSection: some View {
        let realImage = realPreviewImage
        // Must ask "is this thumbnail intrinsically simulator-shaped"
        // (populated brightness/tint, per PROTOCOL.md's strict one-of:
        // "never both, never neither"), not merely "does a `Thumbnail`
        // object exist" — the latter let a real thumbnail whose `imagePath`
        // hadn't loaded yet on this render (file still mid-write, or a
        // transient `NSImage(contentsOfFile:)` miss) fall through to the
        // bundled MOCKUP crop instead of a neutral placeholder: the
        // "simulated art flashes before the real preview" bug reported live
        // 2026-07-26 (see `ThumbnailTileImage`'s own doc comment in
        // ThumbnailGridView.swift for the identical fix applied to the
        // contact-sheet grid and the carrier-loading screen).
        let isAvailable = sessionModel.thumbnails[frameIndex].map { $0.isSimulatorShaped } ?? false
        let orientationDegrees = sessionModel.frameOrientation(frameIndex)
        let mirrored = sessionModel.frameMirror(frameIndex)
        let verticallyMirrored = sessionModel.frameVerticalMirror(frameIndex)

        return VStack(alignment: .leading, spacing: 6) {
            viewingModeSwitcher
            orientationControls

            // `ZStack`, not `Group`: `Group`'s multiple children are NOT
            // overlaid — inside this VStack, a second simultaneous Group
            // child would become a separate row rather than a layer on top
            // of the image. This ZStack keeps every modifier below chained
            // after it exactly as before, so the defect markers inherit the
            // SAME scaleEffect/offset the image gets and never drift off
            // the image on pinch-zoom/pan.
            ZStack {
                // Preview of the persisted derivative rotation
                // (`SessionModel.rotateFrame`).
                // The image and the defect markers rotate together by the same
                // angle about the same center: marker coordinates are defined
                // in the UNROTATED frame (DefectOverlayCanvas, DefectMapView.swift),
                // so the overlay gets the identical rotationEffect below to stay
                // registered to the now-rotated pixels.
                Group {
                    if let realImage {
                        Image(nsImage: realImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        SimulatedFrameImage(frameIndex: frameIndex, isAvailable: isAvailable)
                    }
                }
                .scaleEffect(
                    x: mirrored ? -1 : 1,
                    y: verticallyMirrored ? -1 : 1
                )
                .rotationEffect(.degrees(Double(orientationDegrees)))
                if viewingMode == .defectMap {
                    defectMapOverlayContent(
                        orientationDegrees: orientationDegrees,
                        mirrored: mirrored,
                        verticallyMirrored: verticallyMirrored
                    )
                }
            }
            .scaleEffect(zoomState.scale)
            .offset(zoomState.panOffset)
            // Swap to portrait (2:3) at 90/270 so the rotated frame fits instead
            // of being clipped to the landscape box (rotationEffect does not
            // resize layout bounds).
            .aspectRatio(
                FrameOrientation.displayAspectRatio(orientationDegrees),
                contentMode: .fit
            )
            .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 480)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.12)))
            // Keep the preview's changing description scoped to the image
            // before adding interactive overlays. Applying this label after
            // `zoomControls` causes SwiftUI to replace each button's own
            // accessible name with the preview description.
            .accessibilityLabel(previewAccessibilityLabel(usesRealImage: realImage != nil))
            .overlay(alignment: .topTrailing) { zoomControls }
            .overlay(alignment: .bottomLeading) {
                if viewingMode == .defectMap {
                    DefectMapLegend(
                        simulated: currentDefectAnalysis?.simulated ?? true,
                        transportSmearFlagged: currentDefectAnalysis?.transportSmearFlagged ?? false,
                        transportSmearReason: currentDefectAnalysis?.transportSmearReason
                    )
                    .padding(10)
                }
            }
            // Dashed connector, drawn BEFORE (so it renders underneath) the
            // bottom-trailing loupe below. Deliberately targets the
            // UNSCALED (base fit-zoom) defect position, not a
            // zoomScale/panOffset-corrected one -- re-deriving the loupe's
            // own screen-space anchor every frame during an active pinch
            // would be disproportionate to what's actually a cosmetic line
            // pointing at a defect, not a claim of pixel-perfect fidelity
            // through every zoom state.
            .overlay {
                if viewingMode == .defectMap, let selected = selectedDefectForLoupe {
                    GeometryReader { geo in
                        Path { path in
                            path.move(to: CGPoint(x: selected.centerX * geo.size.width, y: selected.centerY * geo.size.height))
                            path.addLine(to: CGPoint(x: geo.size.width - 40, y: geo.size.height - 40))
                        }
                        .stroke(
                            selected.classification == .willCorrect ? Color.scanStudioRed : Color.scanStudioAmber,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if viewingMode == .defectMap, let selected = selectedDefectForLoupe {
                    DefectLoupeView(
                        defect: selected,
                        realImage: realPreviewImage,
                        frameIndex: frameIndex,
                        // Same fix as `previewSection`'s own `isAvailable`
                        // just above (2026-07-26) — see that property's doc
                        // comment.
                        isSimulatedAvailable: sessionModel.thumbnails[frameIndex].map { $0.isSimulatorShaped } ?? false
                    )
                    .padding(10)
                }
            }
            .contentShape(Rectangle())
            .gesture(SimultaneousGesture(magnifyGesture, panGesture))

            if FrameAlignmentAvailabilityPolicy.isVisible(
                deviceKind: sessionModel.device?.kind
            ) {
                FrameAlignmentControl(
                    session: sessionModel,
                    frameIndex: frameIndex
                )
            }

            if viewingMode == .defectMap {
                overlayOpacitySlider
            }

            Text(previewCaption(usesRealImage: realImage != nil))
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
        }
    }

    /// Final/Before Repair/Defect Map (DEF-01) — exactly one mode is ever
    /// shown, no 50/50 comparison. Segmented style matches the mode-picker
    /// precedent this app already establishes (`BatchInspectorView`'s
    /// Digital ICE mode picker, this file's own `processingEditorRows`
    /// Digital ICE mode picker).
    private var viewingModeSwitcher: some View {
        Picker("Viewing mode", selection: $viewingMode) {
            ForEach(FrameViewingMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    private var orientationControls: some View {
        HStack(spacing: 8) {
            Button {
                sessionModel.rotateFrame(frameIndex, by: -90)
            } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!sessionModel.frameTransformsAreEditable)
            .help(frameTransformHelp("Rotate the Positive/Preview files produced by the next scan counter-clockwise. Existing files and Master TIFF, IR, and meter files stay untouched."))

            Button {
                sessionModel.rotateFrame(frameIndex, by: 90)
            } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!sessionModel.frameTransformsAreEditable)
            .help(frameTransformHelp("Rotate the Positive/Preview files produced by the next scan clockwise. Existing files and Master TIFF, IR, and meter files stay untouched."))

            Button {
                sessionModel.resetFrameOrientation(frameIndex)
            } label: {
                Label("Reset Rotation", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                !sessionModel.frameTransformsAreEditable
                    || sessionModel.frameOrientation(frameIndex) == 0
            )
            .help(frameTransformHelp("Reset this frame's rotation for its next Positive/Preview scan."))

            Divider().frame(height: 18)

            Button {
                sessionModel.toggleFrameMirror(frameIndex)
            } label: {
                Label("Flip Left to Right", systemImage: "arrow.left.and.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!sessionModel.frameTransformsAreEditable)
            .help(frameTransformHelp("Flip the Positive/Preview files produced by the next scan left to right. Existing files and Master TIFF, IR, and meter files stay untouched."))

            Button {
                sessionModel.toggleFrameVerticalMirror(frameIndex)
            } label: {
                Label("Flip Top to Bottom", systemImage: "arrow.up.and.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!sessionModel.frameTransformsAreEditable)
            .help(frameTransformHelp("Flip the Positive/Preview files produced by the next scan top to bottom. Existing files and Master TIFF, IR, and meter files stay untouched."))

            Button {
                sessionModel.resetFrameMirrors(frameIndex)
            } label: {
                Label("Reset Flips", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                !sessionModel.frameTransformsAreEditable
                    || (!sessionModel.frameMirror(frameIndex)
                    && !sessionModel.frameVerticalMirror(frameIndex)
                    )
            )
            .help(frameTransformHelp("Reset both flips for this frame's next Positive/Preview scan."))

            Spacer(minLength: 12)

            Text("Applied on next scan · Existing files and capture masters stay untouched")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frame orientation and flips for the next Positive and Preview scan")
    }

    private func frameTransformHelp(_ availableHelp: String) -> String {
        sessionModel.frameTransformsAreEditable
            ? availableHelp
            : "Rotation and flips cannot be changed while a scan is starting or running."
    }

    /// Defect Map mode's overlay content, layered inside the same
    /// ZStack/transform chain as the image itself. Four branches, driven by
    /// the cache `.task(id: frameIndex)` populates and the engine's
    /// provenance signals: not yet fetched (`nil`) shows nothing; fetched
    /// with `digitalIceEnabled == false` renders `DigitalIceOffNotice`;
    /// fetched with ICE on but an empty defect list renders
    /// `CleanFrameNotice`; otherwise the filtered overlay renders. This order
    /// keys the empty states off the authoritative wire boolean, never
    /// `defects.isEmpty` alone.
    @ViewBuilder
    private func defectMapOverlayContent(
        orientationDegrees: Int,
        mirrored: Bool,
        verticallyMirrored: Bool
    ) -> some View {
        if let analysis = currentDefectAnalysis {
            if analysis.digitalIceEnabled == false {
                DigitalIceOffNotice()
            } else if analysis.defects.isEmpty {
                CleanFrameNotice(simulated: analysis.simulated)
            } else {
                DefectOverlayCanvas(defects: visibleDefectsForFrame, opacity: overlayOpacity)
                    .scaleEffect(
                        x: mirrored ? -1 : 1,
                        y: verticallyMirrored ? -1 : 1
                    )
                    // Track the image rotation so markers stay on their defects.
                    // Scoped to the canvas only so the centered empty-state notices
                    // above stay upright.
                    .rotationEffect(.degrees(Double(orientationDegrees)))
            }
        }
    }

    private var overlayOpacitySlider: some View {
        HStack(spacing: 8) {
            Text("Overlay")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
            Slider(value: $overlayOpacity, in: 0.15...1.0)
            Text("\(Int(overlayOpacity * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.scanStudioSecondaryText)
                .frame(width: 34, alignment: .trailing)
        }
    }

    /// `beforeRepair` gets its own honest caption (see this plan's
    /// `scope_decision`: no pixel pipeline in this codebase currently
    /// produces a genuinely different before/after-ICE buffer for any
    /// frame); `finalPositive`/`defectMap` keep the existing real/simulated
    /// caption unchanged.
    private func previewCaption(usesRealImage: Bool) -> String {
        if viewingMode == .beforeRepair {
            return "Before-repair view: Digital ICE correction is not yet applied to any rendered output in this build — shown identically to Final."
        }
        return usesRealImage
            ? "Real scanner preview tile · zoom and pan"
            : "Simulated preview crop, the same source imagery shown throughout Scan Studio · zoom and pan"
    }

    private func previewAccessibilityLabel(usesRealImage: Bool) -> String {
        let base = usesRealImage
            ? "Real scanner preview for frame \(frameIndex)"
            : "Simulated preview for frame \(frameIndex), same preview crop shown elsewhere in the app"
        var label = "\(base), zoomed to \(Int(zoomState.scale * 100)) percent"
        if let orientationText = FrameOrientation.accessibilityText(sessionModel.frameOrientation(frameIndex)) {
            label += ", \(orientationText)"
        }
        if sessionModel.frameMirror(frameIndex) {
            label += ", mirrored horizontally"
        }
        if sessionModel.frameVerticalMirror(frameIndex) {
            label += ", mirrored vertically"
        }
        if viewingMode == .defectMap, let defects = currentDefectAnalysis?.defects, !defects.isEmpty {
            let provenance = currentDefectAnalysis?.simulated ?? true ? "simulated" : "real"
            label += ", showing \(defects.count) \(provenance) defect markers"
        }
        return label
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                zoomState.step(by: -FrameDetailZoomState.controlStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel("Zoom Out")
            .accessibilityHint("Decreases the frame preview magnification")
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!zoomState.canZoomOut)

            Text("\(Int(zoomState.scale * 100))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.scanStudioPrimaryText)

            Button {
                zoomState.step(by: FrameDetailZoomState.controlStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel("Zoom In")
            .accessibilityHint("Increases the frame preview magnification")
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!zoomState.canZoomIn)

            Button("Fit") { zoomState.reset() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityHint("Fits the entire frame preview and resets its position")
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoomState.isFitted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 5))
        .padding(10)
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomState.updateMagnification(value)
            }
            .onEnded { _ in zoomState.finishMagnification() }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                zoomState.updatePan(translation: value.translation)
            }
            .onEnded { _ in zoomState.finishPan() }
    }

    private func resetZoomAndPan() {
        zoomState.reset()
    }

    // MARK: - Defect map controls (DEF-02)

    /// Dust/Scratches/Uncertain filter chips — shown only in Defect Map
    /// mode, directly below the large preview. Each chip's own count is
    /// always the FULL unfiltered count for its own meaning (kind for
    /// Dust/Scratches, classification for Uncertain), never the post-filter
    /// count, so toggling a sibling chip never changes another chip's own
    /// number.
    private var defectMapControlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Defect Filters")

            HStack(spacing: 8) {
                DefectFilterChip(label: "Dust", count: dustCountForFrame, color: .scanStudioCyan, isOn: $showDust)
                DefectFilterChip(label: "Scratches", count: scratchCountForFrame, color: .scanStudioGreen, isOn: $showScratches)
                DefectFilterChip(label: "Uncertain", count: uncertainCountForFrame, color: .scanStudioAmber, isOn: $showUncertain)
                Spacer()
            }

            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)

            defectCountsAndNavRow
        }
        .padding(12)
        .background(Color.scanStudioInspector.opacity(0.5), in: RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    /// The footer's total, always-unfiltered summary text — matches the
    /// mockup's own footer text format exactly ("37 defects • Dust 32 •
    /// Scratches 5"). Deliberately reads `allDefectsForFrame`/
    /// `dustCountForFrame`/`scratchCountForFrame`, never the filtered set:
    /// this is the one place in Defect Map mode that always shows the
    /// frame's real total, regardless of which filter chips are currently
    /// on or off (see this plan's own `scope_decision`).
    private var defectCountsSummary: String {
        let total = allDefectsForFrame.count
        return "\(total) defect\(total == 1 ? "" : "s") \u{2022} Dust \(dustCountForFrame) \u{2022} Scratches \(scratchCountForFrame)"
    }

    /// "N/M" against the FILTERED set — a defect a filter has hidden is
    /// never reachable via Previous/Next and never counted here. Naturally
    /// renders "0/0" when `visibleDefectsForFrame` is empty: `firstIndex`
    /// returns `nil` on an empty array regardless of what it's compared
    /// against, so `(nil ?? -1) + 1 == 0`, over a `count` that's also `0` --
    /// no separate empty-case branch needed.
    private var defectPositionLabel: String {
        let currentPosition = (visibleDefectsForFrame.firstIndex(where: { $0.id == effectiveSelectedDefectID }) ?? -1) + 1
        return "\(currentPosition)/\(visibleDefectsForFrame.count)"
    }

    /// Total/position text (combined into one accessibility element, same
    /// pattern `DefectMapLegend` already establishes for read-only summary
    /// text) plus the real, individually-focusable Previous/Next/Re-analyze
    /// actions -- combining THOSE into the same element would hide them
    /// from VoiceOver as separately activatable controls, which the plan's
    /// own example combined label (counts/position only, no button text)
    /// does not ask for.
    private var defectCountsAndNavRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(defectCountsSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                Text(defectPositionLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.scanStudioPrimaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(defectCountsSummary), showing position \(defectPositionLabel)")

            Spacer()

            Button("Previous") {
                selectedDefectID = stepDefectSelection(current: effectiveSelectedDefectID, in: visibleDefectsForFrame, forward: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(visibleDefectsForFrame.isEmpty)

            Button("Next") {
                selectedDefectID = stepDefectSelection(current: effectiveSelectedDefectID, in: visibleDefectsForFrame, forward: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(visibleDefectsForFrame.isEmpty)

            Button {
                Task { await sessionModel.analyzeFrameDefects(frameIndex) }
            } label: {
                Label("Re-analyze", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(sessionModel.isJobActive)
        }
    }

    // MARK: - Filmstrip navigation

    private var filmstripSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(title: "Frames")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(frameIndices, id: \.self) { otherFrameIndex in
                            FilmstripTile(
                                frameIndex: otherFrameIndex,
                                isCurrent: otherFrameIndex == frameIndex,
                                thumbnail: sessionModel.thumbnails[otherFrameIndex],
                                orientationDegrees: sessionModel.frameOrientation(otherFrameIndex),
                                mirrored: sessionModel.frameMirror(otherFrameIndex),
                                verticallyMirrored: sessionModel.frameVerticalMirror(otherFrameIndex)
                            ) {
                                sessionModel.openFrameDetail(otherFrameIndex)
                            }
                            .id(otherFrameIndex)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { proxy.scrollTo(frameIndex, anchor: .center) }
                .onChange(of: frameIndex) {
                    withAnimation { proxy.scrollTo(frameIndex, anchor: .center) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filmstrip navigation, frame \(frameIndex) of \(frameCount)")
    }

    // MARK: - Per-frame override editor (capture / processing / output)

    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(title: "Per-Frame Overrides")
                .padding(.bottom, 8)

            Label(
                "Override capture, processing, or output settings for just this frame. Creating an override starts from the current roll default; reverting clears it and this frame inherits the roll default again.",
                systemImage: "square.on.square"
            )
            .font(.system(size: 10))
            .foregroundStyle(Color.scanStudioSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                captureSection
                processingSection
                outputSection
                metadataSection
            }
            .background(Color.scanStudioInspector.opacity(0.5), in: RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var captureSection: some View {
        FrameOverrideSection(
            title: "Capture",
            isOverridden: currentCaptureOverride != nil,
            isDraftActive: captureDraft != nil,
            canSave: captureDraft != nil && captureDraft != currentCaptureOverride,
            onStart: startCaptureOverride,
            onSave: saveCaptureOverride,
            onRevert: revertCaptureOverride
        ) {
            captureEditorRows
        }
    }

    private var processingSection: some View {
        FrameOverrideSection(
            title: "Processing",
            isOverridden: currentProcessingOverride != nil,
            isDraftActive: processingDraft != nil,
            canSave: processingDraft != nil && processingDraft != currentProcessingOverride,
            onStart: startProcessingOverride,
            onSave: saveProcessingOverride,
            onRevert: revertProcessingOverride
        ) {
            processingEditorRows
        }
    }

    private var outputSection: some View {
        FrameOverrideSection(
            title: "Output",
            isOverridden: currentOutputOverride != nil,
            isDraftActive: outputDraft != nil,
            canSave: outputDraft != nil && outputDraft != currentOutputOverride,
            onStart: startOutputOverride,
            onSave: saveOutputOverride,
            onRevert: revertOutputOverride
        ) {
            outputEditorRows
        }
    }

    private var metadataSection: some View {
        FrameOverrideSection(
            title: "Metadata",
            isOverridden: currentMetadataOverride != nil,
            isDraftActive: metadataDraft != nil,
            canSave: metadataDraft != nil && metadataDraft != currentMetadataOverride,
            onStart: startMetadataOverride,
            onSave: saveMetadataOverride,
            onRevert: revertMetadataOverride
        ) {
            metadataEditorRows
        }
    }

    private var captureEditorRows: some View {
        Group {
            InspectorSettingRow(label: "Resolution") {
                Picker("Resolution", selection: captureResolutionBinding) {
                    Text("1000 ppi").tag(1_000)
                    Text("2000 ppi").tag(2_000)
                    Text("4000 ppi").tag(4_000)
                }
            }
            InspectorSettingRow(label: "Bit depth") {
                Picker("Bit depth", selection: captureBitDepthBinding) {
                    Text("8-bit").tag(8)
                    Text("16-bit").tag(16)
                }
            }
            InspectorSettingRow(label: "Multi-sampling") {
                // Same connected-device-constrained options as
                // `BatchInspectorView`'s roll-wide picker (see
                // `MultisamplePassPolicy` in SessionModel.swift). An
                // already-saved per-frame override is never silently
                // rewritten here -- only future picker choices are
                // constrained.
                Picker("Multi-sampling", selection: captureMultisampleBinding) {
                    ForEach(MultisamplePassPolicy.supportedOptions(for: sessionModel.device), id: \.self) { passes in
                        Text(MultisamplePassPolicy.label(for: passes)).tag(passes)
                    }
                }
            }
            InspectorSettingRow(label: "Color mode") {
                Picker("Color mode", selection: captureChannelsBinding) {
                    Text("RGB").tag("rgb")
                    Text("RGB + infrared").tag("rgbi")
                }
                .disabled(isBlackAndWhiteRoll)
            }
            if isBlackAndWhiteRoll {
                Text("B&W uses RGB capture only; infrared Digital ICE is unavailable.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }
        }
    }

    private var processingEditorRows: some View {
        Group {
            InspectorSettingRow(label: "Film type") {
                Picker("Film type", selection: processingFilmProcessBinding) {
                    Text("Positive").tag(FilmProcess.positive)
                    Text("Color negative").tag(FilmProcess.c41ColorNegative)
                    Text("B&W negative").tag(FilmProcess.bwNegative)
                    Text("Kodachrome").tag(FilmProcess.kodachrome)
                }
                .disabled(true)
            }
            Text("Film process is fixed by the roll preview; re-preview to change it.")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
            InspectorToggleRow(label: "Autofocus", isOn: processingAutofocusBinding)
            InspectorToggleRow(label: "Auto exposure", isOn: processingAutoExposureBinding)
            InspectorToggleRow(label: "Digital ICE", isOn: processingDigitalIceEnabledBinding)
                .disabled(isBlackAndWhiteRoll)

            if isBlackAndWhiteRoll {
                InspectorToggleRow(label: "Software dust removal", isOn: processingSoftwareDustRemovalBinding)
                Text("Optional RGB-only cleanup affects regenerated derivatives, never the archive master.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            } else if processingDraft?.digitalIceEnabled == true {
                Picker("Digital ICE mode", selection: processingDigitalIceModeBinding) {
                    Text("Legacy").tag(DigitalIceMode.legacy)
                    Text("Hybrid").tag(DigitalIceMode.hybrid)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: processingDraft?.digitalIceEnabled)
    }

    private var outputEditorRows: some View {
        Group {
            subHeading("Archive")
            InspectorToggleRow(label: "Keep master TIFF", isOn: outputArchiveEnabledBinding)
                .disabled(!canToggleOutput(.archive))
                .help(OutputRetentionPolicy.helpText)
            if outputDraft?.archive.enabled == true {
                InspectorToggleRow(label: "Full capture package", isOn: outputArchiveFullCapturePackageBinding)
                InspectorTextFieldRow(label: "Naming", text: outputArchiveFilenameBinding)
                InspectorTextFieldRow(label: "Destination", text: outputArchiveDestinationBinding)
            }

            subHeading("Raw negative").padding(.top, 8)
            InspectorToggleRow(label: "Untouched negative", isOn: outputRawEnabledBinding)
                .disabled(!canToggleOutput(.rawExport))
                .help(OutputRetentionPolicy.helpText)
            if outputDraft?.rawExport.enabled == true {
                InspectorSettingRow(label: "File format") {
                    Picker("File format", selection: outputRawFormatBinding) {
                        Text("Linear DNG").tag(RawExportFormat.linearDng)
                        Text("Linear TIFF").tag(RawExportFormat.linearTiff)
                    }
                }
                if outputDraft?.rawExport.fileFormat == .linearTiff {
                    InspectorSettingRow(label: "Infrared") {
                        Picker("Infrared", selection: outputRawTiffInfraredBinding) {
                            Text("Fourth channel").tag(RawTiffInfrared.fourthChannel)
                            Text("Omit (RGB only)").tag(RawTiffInfrared.omitted)
                        }
                    }
                }
                Text("This is the untouched 16-bit negative. DNG embeds infrared; TIFF follows the infrared choice above. Processing and geometry settings do not alter it.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                InspectorTextFieldRow(label: "Naming", text: outputRawFilenameBinding)
                InspectorTextFieldRow(label: "Destination", text: outputRawDestinationBinding)
            }

            subHeading("Positive").padding(.top, 8)
            InspectorToggleRow(label: "Positive derivative", isOn: outputPositiveEnabledBinding)
                .disabled(!canToggleOutput(.positive))
                .help(OutputRetentionPolicy.helpText)
            if outputDraft?.positive.enabled == true {
                InspectorSettingRow(label: "File format") {
                    Picker("File format", selection: outputPositiveFileFormatBinding) {
                        Text("TIFF").tag(OutputFileFormat.tiff)
                        Text("JPEG").tag(OutputFileFormat.jpeg)
                    }
                }
                InspectorSettingRow(label: "Color encoding") {
                    Picker("Color encoding", selection: outputPositiveColorProfileBinding) {
                        Text("Adobe RGB (1998)").tag(OutputColorProfile.adobeRgb1998)
                    }
                }
                Text("C41 files include a ScanStudio color profile compatible with Adobe RGB (1998).")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                InspectorTextFieldRow(label: "Naming", text: outputPositiveFilenameBinding)
                InspectorTextFieldRow(label: "Destination", text: outputPositiveDestinationBinding)
            }

            subHeading("Preview").padding(.top, 8)
            InspectorToggleRow(label: "Preview / export copy", isOn: outputPreviewEnabledBinding)
                .disabled(!canToggleOutput(.preview))
                .help(OutputRetentionPolicy.helpText)
            if outputDraft?.preview.enabled == true {
                InspectorSettingRow(label: "File format") {
                    Picker("File format", selection: outputPreviewFileFormatBinding) {
                        Text("TIFF").tag(OutputFileFormat.tiff)
                        Text("JPEG").tag(OutputFileFormat.jpeg)
                    }
                }
                InspectorSettingRow(label: "Max size") {
                    Picker("Max size", selection: outputPreviewMaxLongEdgeBinding) {
                        Text("1024 px").tag(1_024)
                        Text("2048 px").tag(2_048)
                        Text("4096 px").tag(4_096)
                    }
                }
                InspectorTextFieldRow(label: "Naming", text: outputPreviewFilenameBinding)
                InspectorTextFieldRow(label: "Destination", text: outputPreviewDestinationBinding)
            }

            subHeading("Geometry").padding(.top, 8)
            InspectorToggleRow(label: "Auto crop derived outputs", isOn: outputAutoCropBinding)
            Text("Crops this frame's positive and preview to its own detected image area at scan time. The master TIFF keeps the full frame; the crop is recorded in the frame's receipt.")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Label(OutputRetentionPolicy.helpText, systemImage: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    /// Mirrors the roll-wide Metadata section's own field rows
    /// (`BatchInspectorView.swift`'s `setupInspector`) exactly — same
    /// `InspectorTextFieldRow`/`InspectorSettingRow`/`Picker`/
    /// `PartialDateEditor` controls, same field order — but bound to this
    /// frame's local `metadataDraft` via the draft-then-Save/Revert bindings
    /// below rather than a live per-keystroke round trip, matching
    /// Capture/Processing/Output's own established per-frame shape. Row
    /// *declarations* are duplicated here (not shared via a generic
    /// component) because the two contexts' binding shapes genuinely differ
    /// — this file's `set` closures only ever mutate local `@State`, while
    /// `BatchInspectorView`'s call `setRollMetadata` on every edit — but
    /// `PartialDateEditor` itself is reused unduplicated, as required.
    private var metadataEditorRows: some View {
        Group {
            InspectorTextFieldRow(label: "Camera", text: metadataCameraBinding)
            InspectorTextFieldRow(label: "Lens", text: metadataLensBinding)
            InspectorTextFieldRow(label: "Film stock", text: metadataFilmStockBinding)
            InspectorSettingRow(label: "Process") {
                Picker("Process", selection: metadataProcessBinding) {
                    Text("Positive").tag(FilmProcess.positive)
                    Text("Color negative").tag(FilmProcess.c41ColorNegative)
                    Text("B&W negative").tag(FilmProcess.bwNegative)
                    Text("Kodachrome").tag(FilmProcess.kodachrome)
                }
            }
            InspectorSettingRow(label: "ISO") {
                Picker("ISO", selection: metadataIsoBinding) {
                    ForEach(metadataIsoOptions, id: \.self) { iso in
                        Text("\(iso)").tag(iso)
                    }
                }
            }
            InspectorSettingRow(label: "Date") {
                PartialDateEditor(date: metadataDateBinding)
            }
            InspectorTextFieldRow(label: "Location", text: metadataLocationBinding)
            InspectorTextFieldRow(label: "Photographer", text: metadataPhotographerBinding)
            InspectorTextFieldRow(label: "Copyright", text: metadataCopyrightBinding)
            InspectorTextFieldRow(label: "Roll ID", text: metadataRollIdBinding)
            InspectorTextFieldRow(label: "Notes", text: metadataNotesBinding)
            InspectorTextFieldRow(label: "Keywords", text: metadataKeywordsBinding)
        }
    }

    /// A smaller, dimmer sibling of `SectionEyebrow` for the four
    /// archive/raw/positive/preview sub-groups nested inside the single
    /// "Output" collapsible section — visually subordinate to that
    /// section's own `SectionEyebrow`-style disclosure title, so the two
    /// heading levels stay distinguishable rather than reusing the exact
    /// same look for both.
    private func subHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Color.scanStudioSecondaryText.opacity(0.8))
    }

    // MARK: - ExifTool preview / apply panel (META-03)

    /// A distinct block below all four override sections (not a sub-block of
    /// Metadata's own `FrameOverrideSection`) — this is a real action against
    /// this frame's already-scanned outputs, not another field to edit.
    /// Mirrors `defectMapControlsSection`'s own card chrome (padding,
    /// `scanStudioInspector` background, hairline stroke) since that's this
    /// file's other precedent for "a distinct block below the main content."
    private var exifToolPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "ExifTool")

            Label(exifToolStatusSummary, systemImage: exifToolAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(exifToolAvailable ? Color.scanStudioCyan : Color.scanStudioAmber)

            HStack(spacing: 8) {
                Button {
                    Task {
                        await sessionModel.previewMetadataCommand(frameIndex)
                        metadataPreviewFrameIndex = frameIndex
                    }
                } label: {
                    Label("Preview Command", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!exifToolAvailable)

                Button {
                    Task { metadataApplyResult = await sessionModel.applyMetadata(frameIndex) }
                } label: {
                    Label("Apply Metadata", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .tint(.scanStudioAmber)
                .controlSize(.small)
                .disabled(metadataPreviewForCurrentFrame?.targets.isEmpty != false)
            }

            // Plain-text explanation for every disabled state — never a
            // silently-disabled button with no stated reason (this plan's
            // own explicit requirement).
            Text(exifToolGuidanceText)
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let preview = metadataPreviewForCurrentFrame {
                VStack(alignment: .leading, spacing: 6) {
                    Text(preview.targets.isEmpty
                        ? "No scanned outputs yet for this frame — nothing to tag."
                        : "Targets: \(preview.targets.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioSecondaryText)

                    Text(preview.arguments.isEmpty
                        ? "No metadata fields are set. Apply Metadata will leave these outputs unchanged."
                        : preview.arguments.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.scanStudioPrimaryText)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 5))
                }
            }

            if let result = metadataApplyResult {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        result.success ? "Applied successfully" : "Apply failed (exit code \(result.exitCode))",
                        systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(result.success ? Color.scanStudioGreen : Color.scanStudioRed)

                    if !result.stdout.isEmpty {
                        Text(result.stdout)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.scanStudioSecondaryText)
                            .textSelection(.enabled)
                    }
                    if !result.stderr.isEmpty {
                        Text(result.stderr)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.scanStudioRed)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color.scanStudioInspector.opacity(0.5), in: RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var exifToolAvailable: Bool { sessionModel.exifToolDetection?.available == true }

    /// Same phrasing as `BatchInspectorView.swift`'s own
    /// `exifToolStatusSummary` (kept as separate, small, file-local logic
    /// rather than a cross-file call — that property is `private` there, and
    /// duplicating four lines of text formatting is far cheaper than
    /// widening its access purely for this).
    private var exifToolStatusSummary: String {
        guard let detection = sessionModel.exifToolDetection else { return "Checking…" }
        guard detection.available else { return "Not found — install ExifTool" }
        return detection.version.map { "\($0) detected" } ?? "Detected"
    }

    /// States plainly, in plain UI text, exactly why the buttons above are
    /// (or aren't) enabled right now — never a silently-disabled control.
    private var exifToolGuidanceText: String {
        guard exifToolAvailable else {
            return "ExifTool isn't installed on this machine, so no command can run yet."
        }
        guard let preview = metadataPreviewForCurrentFrame else {
            return "Preview the command to see exactly what Apply Metadata would run, before running it."
        }
        guard !preview.targets.isEmpty else {
            return "This frame has no scanned outputs yet, so there's nothing for ExifTool to tag."
        }
        guard !preview.arguments.isEmpty else {
            return "No metadata fields are set. Apply Metadata is a successful no-op and won't launch ExifTool."
        }
        return "Apply runs ExifTool against this frame's scanned outputs for real."
    }

    // MARK: - Draft lifecycle

    /// Re-derives all three drafts from this frame's own project state.
    /// Non-`nil` current overrides are copied straight into the matching
    /// draft (auto-revealing that section's editable rows); `nil` overrides
    /// collapse back to the "Using roll default" + start-editing button
    /// state. Also resets zoom/pan so a newly-selected frame never inherits
    /// the previous one's zoomed-in viewport.
    private func syncOverrideDrafts() {
        captureDraft = currentCaptureOverride
        processingDraft = currentProcessingOverride
        outputDraft = currentOutputOverride
        metadataDraft = currentMetadataOverride
        resetZoomAndPan()
    }

    private func startCaptureOverride() { captureDraft = sessionModel.captureRecipe }
    private func startProcessingOverride() { processingDraft = sessionModel.processingRecipe }
    private func startOutputOverride() { outputDraft = sessionModel.outputRecipe }
    private func startMetadataOverride() { metadataDraft = sessionModel.rollMetadataDraft }

    private func saveCaptureOverride() {
        guard let captureDraft else { return }
        let capture = isBlackAndWhiteRoll ? captureDraft.with(channels: "rgb") : captureDraft
        Task { await sessionModel.setFrameCaptureOverride(frameIndex, to: capture) }
    }
    private func saveProcessingOverride() {
        guard let processingDraft else { return }
        let processing = processingDraft.with(
            filmProcess: rollFilmProcess,
            digitalIceEnabled: isBlackAndWhiteRoll ? false : processingDraft.digitalIceEnabled,
            softwareDustRemovalBw: isBlackAndWhiteRoll ? processingDraft.softwareDustRemovalBw : false
        )
        Task { await sessionModel.setFrameProcessingOverride(frameIndex, to: processing) }
    }
    private func saveOutputOverride() {
        guard let outputDraft else { return }
        Task { await sessionModel.setFrameOutputOverride(frameIndex, to: outputDraft) }
    }
    private func saveMetadataOverride() {
        guard let metadataDraft else { return }
        Task { await sessionModel.setFrameMetadataOverride(frameIndex, to: metadataDraft) }
    }

    /// Reverting round-trips through the engine exactly like Save, then
    /// re-reads this frame's override back from the fresh project response
    /// — rather than assuming success and unconditionally setting the draft
    /// to `nil` — so a failed revert leaves the section visibly still in
    /// its overridden state instead of lying about having reverted.
    private func revertCaptureOverride() {
        Task {
            await sessionModel.setFrameCaptureOverride(frameIndex, to: nil)
            captureDraft = currentCaptureOverride
        }
    }
    private func revertProcessingOverride() {
        Task {
            await sessionModel.setFrameProcessingOverride(frameIndex, to: nil)
            processingDraft = currentProcessingOverride
        }
    }
    private func revertOutputOverride() {
        Task {
            await sessionModel.setFrameOutputOverride(frameIndex, to: nil)
            outputDraft = currentOutputOverride
        }
    }
    private func revertMetadataOverride() {
        Task {
            await sessionModel.setFrameMetadataOverride(frameIndex, to: nil)
            metadataDraft = currentMetadataOverride
        }
    }

    // MARK: - Capture draft bindings

    private var captureResolutionBinding: Binding<Int> {
        Binding(
            get: { captureDraft?.resolutionDpi ?? sessionModel.captureRecipe.resolutionDpi },
            set: { newValue in captureDraft = captureDraft?.with(resolutionDpi: newValue) }
        )
    }
    private var captureBitDepthBinding: Binding<Int> {
        Binding(
            get: { captureDraft?.bitDepth ?? sessionModel.captureRecipe.bitDepth },
            set: { newValue in captureDraft = captureDraft?.with(bitDepth: newValue) }
        )
    }
    private var captureMultisampleBinding: Binding<Int> {
        Binding(
            get: { captureDraft?.multisamplePasses ?? sessionModel.captureRecipe.multisamplePasses },
            set: { newValue in captureDraft = captureDraft?.with(multisamplePasses: newValue) }
        )
    }
    private var captureChannelsBinding: Binding<String> {
        Binding(
            get: { isBlackAndWhiteRoll ? "rgb" : (captureDraft?.channels ?? sessionModel.captureRecipe.channels) },
            set: { newValue in
                guard !isBlackAndWhiteRoll else { return }
                captureDraft = captureDraft?.with(channels: newValue)
            }
        )
    }

    // MARK: - Processing draft bindings

    private var processingFilmProcessBinding: Binding<FilmProcess> {
        Binding(
            get: { rollFilmProcess },
            set: { _ in }
        )
    }
    private var processingAutofocusBinding: Binding<Bool> {
        Binding(
            get: { processingDraft?.autofocusEachFrame ?? sessionModel.processingRecipe.autofocusEachFrame },
            set: { newValue in processingDraft = processingDraft?.with(autofocusEachFrame: newValue) }
        )
    }
    private var processingAutoExposureBinding: Binding<Bool> {
        Binding(
            get: { processingDraft?.autoExposureEachFrame ?? sessionModel.processingRecipe.autoExposureEachFrame },
            set: { newValue in processingDraft = processingDraft?.with(autoExposureEachFrame: newValue) }
        )
    }
    private var processingDigitalIceEnabledBinding: Binding<Bool> {
        Binding(
            get: { isBlackAndWhiteRoll ? false : (processingDraft?.digitalIceEnabled ?? sessionModel.processingRecipe.digitalIceEnabled) },
            set: { newValue in
                guard !isBlackAndWhiteRoll else { return }
                processingDraft = processingDraft?.with(digitalIceEnabled: newValue)
            }
        )
    }
    private var processingDigitalIceModeBinding: Binding<DigitalIceMode> {
        Binding(
            get: { processingDraft?.digitalIceMode ?? sessionModel.processingRecipe.digitalIceMode },
            set: { newValue in processingDraft = processingDraft?.with(digitalIceMode: newValue) }
        )
    }

    private var processingSoftwareDustRemovalBinding: Binding<Bool> {
        Binding(
            get: { processingDraft?.softwareDustRemovalBw ?? sessionModel.processingRecipe.softwareDustRemovalBw },
            set: { newValue in
                guard isBlackAndWhiteRoll else { return }
                processingDraft = processingDraft?.with(softwareDustRemovalBw: newValue)
            }
        )
    }

    // MARK: - Output draft bindings

    private func canToggleOutput(_ role: OutputRetentionPolicy.Role) -> Bool {
        guard let current = outputDraft else { return false }
        let currentlyEnabled = switch role {
        case .archive: current.archive.enabled
        case .rawExport: current.rawExport.enabled
        case .positive: current.positive.enabled
        case .preview: current.preview.enabled
        }
        return OutputRetentionPolicy.allowsChange(
            role,
            to: !currentlyEnabled,
            archiveEnabled: current.archive.enabled,
            rawExportEnabled: current.rawExport.enabled,
            positiveEnabled: current.positive.enabled,
            previewEnabled: current.preview.enabled
        )
    }

    private var outputAutoCropBinding: Binding<Bool> {
        Binding(
            get: { outputDraft?.autoCrop ?? sessionModel.outputRecipe.autoCrop },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(autoCrop: newValue)
            }
        )
    }

    private var outputArchiveEnabledBinding: Binding<Bool> {
        Binding(
            get: { outputDraft?.archive.enabled ?? sessionModel.outputRecipe.archive.enabled },
            set: { newValue in
                guard let current = outputDraft,
                      OutputRetentionPolicy.allowsChange(
                          .archive,
                          to: newValue,
                          archiveEnabled: current.archive.enabled,
                          rawExportEnabled: current.rawExport.enabled,
                          positiveEnabled: current.positive.enabled,
                          previewEnabled: current.preview.enabled
                      )
                else { return }
                outputDraft = current.with(
                    archive: current.archive.with(
                        enabled: newValue,
                        fullCapturePackage: newValue ? current.archive.fullCapturePackage : false
                    )
                )
            }
        )
    }

    private var outputArchiveFullCapturePackageBinding: Binding<Bool> {
        Binding(
            get: {
                guard let archive = outputDraft?.archive else {
                    return sessionModel.outputRecipe.archive.enabled
                        && sessionModel.outputRecipe.archive.fullCapturePackage
                }
                return archive.enabled && archive.fullCapturePackage
            },
            set: { newValue in
                guard let current = outputDraft, current.archive.enabled else { return }
                outputDraft = current.with(
                    archive: current.archive.with(fullCapturePackage: newValue)
                )
            }
        )
    }
    private var outputRawEnabledBinding: Binding<Bool> {
        Binding(
            get: { outputDraft?.rawExport.enabled ?? sessionModel.outputRecipe.rawExport.enabled },
            set: { newValue in
                guard let current = outputDraft,
                      OutputRetentionPolicy.allowsChange(
                          .rawExport,
                          to: newValue,
                          archiveEnabled: current.archive.enabled,
                          rawExportEnabled: current.rawExport.enabled,
                          positiveEnabled: current.positive.enabled,
                          previewEnabled: current.preview.enabled
                      )
                else { return }
                outputDraft = current.with(rawExport: current.rawExport.with(enabled: newValue))
            }
        )
    }
    private var outputRawFormatBinding: Binding<RawExportFormat> {
        Binding(
            get: { outputDraft?.rawExport.fileFormat ?? sessionModel.outputRecipe.rawExport.fileFormat },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(rawExport: current.rawExport.with(fileFormat: newValue))
            }
        )
    }
    private var outputRawTiffInfraredBinding: Binding<RawTiffInfrared> {
        Binding(
            get: { outputDraft?.rawExport.tiffInfrared ?? sessionModel.outputRecipe.rawExport.tiffInfrared },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(rawExport: current.rawExport.with(tiffInfrared: newValue))
            }
        )
    }
    private var outputRawFilenameBinding: Binding<String> {
        Binding(
            get: { outputDraft?.rawExport.filenameTemplate ?? sessionModel.outputRecipe.rawExport.filenameTemplate },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(rawExport: current.rawExport.with(filenameTemplate: newValue))
            }
        )
    }
    private var outputRawDestinationBinding: Binding<String> {
        Binding(
            get: { outputDraft?.rawExport.destination ?? sessionModel.outputRecipe.rawExport.destination },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(rawExport: current.rawExport.with(destination: newValue))
            }
        )
    }

    private var outputArchiveFilenameBinding: Binding<String> {
        Binding(
            get: { outputDraft?.archive.filenameTemplate ?? sessionModel.outputRecipe.archive.filenameTemplate },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(archive: current.archive.with(filenameTemplate: newValue))
            }
        )
    }
    private var outputArchiveDestinationBinding: Binding<String> {
        Binding(
            get: { outputDraft?.archive.destination ?? sessionModel.outputRecipe.archive.destination },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(archive: current.archive.with(destination: newValue))
            }
        )
    }
    private var outputPositiveEnabledBinding: Binding<Bool> {
        Binding(
            get: { outputDraft?.positive.enabled ?? sessionModel.outputRecipe.positive.enabled },
            set: { newValue in
                guard let current = outputDraft,
                      OutputRetentionPolicy.allowsChange(
                          .positive,
                          to: newValue,
                          archiveEnabled: current.archive.enabled,
                          rawExportEnabled: current.rawExport.enabled,
                          positiveEnabled: current.positive.enabled,
                          previewEnabled: current.preview.enabled
                      )
                else { return }
                outputDraft = current.with(positive: current.positive.with(enabled: newValue))
            }
        )
    }
    private var outputPositiveFileFormatBinding: Binding<OutputFileFormat> {
        Binding(
            get: { outputDraft?.positive.fileFormat ?? sessionModel.outputRecipe.positive.fileFormat },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(positive: current.positive.with(fileFormat: newValue))
            }
        )
    }
    private var outputPositiveColorProfileBinding: Binding<OutputColorProfile> {
        Binding(
            get: { outputDraft?.positive.colorProfile ?? sessionModel.outputRecipe.positive.colorProfile },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(positive: current.positive.with(colorProfile: newValue))
            }
        )
    }
    private var outputPositiveFilenameBinding: Binding<String> {
        Binding(
            get: { outputDraft?.positive.filenameTemplate ?? sessionModel.outputRecipe.positive.filenameTemplate },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(positive: current.positive.with(filenameTemplate: newValue))
            }
        )
    }
    private var outputPositiveDestinationBinding: Binding<String> {
        Binding(
            get: { outputDraft?.positive.destination ?? sessionModel.outputRecipe.positive.destination },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(positive: current.positive.with(destination: newValue))
            }
        )
    }
    private var outputPreviewEnabledBinding: Binding<Bool> {
        Binding(
            get: { outputDraft?.preview.enabled ?? sessionModel.outputRecipe.preview.enabled },
            set: { newValue in
                guard let current = outputDraft,
                      OutputRetentionPolicy.allowsChange(
                          .preview,
                          to: newValue,
                          archiveEnabled: current.archive.enabled,
                          rawExportEnabled: current.rawExport.enabled,
                          positiveEnabled: current.positive.enabled,
                          previewEnabled: current.preview.enabled
                      )
                else { return }
                outputDraft = current.with(preview: current.preview.with(enabled: newValue))
            }
        )
    }
    private var outputPreviewFileFormatBinding: Binding<OutputFileFormat> {
        Binding(
            get: { outputDraft?.preview.fileFormat ?? sessionModel.outputRecipe.preview.fileFormat },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(preview: current.preview.with(fileFormat: newValue))
            }
        )
    }
    private var outputPreviewMaxLongEdgeBinding: Binding<Int> {
        Binding(
            get: { outputDraft?.preview.maxLongEdgePx ?? sessionModel.outputRecipe.preview.maxLongEdgePx },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(preview: current.preview.with(maxLongEdgePx: newValue))
            }
        )
    }
    private var outputPreviewFilenameBinding: Binding<String> {
        Binding(
            get: { outputDraft?.preview.filenameTemplate ?? sessionModel.outputRecipe.preview.filenameTemplate },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(preview: current.preview.with(filenameTemplate: newValue))
            }
        )
    }
    private var outputPreviewDestinationBinding: Binding<String> {
        Binding(
            get: { outputDraft?.preview.destination ?? sessionModel.outputRecipe.preview.destination },
            set: { newValue in
                guard let current = outputDraft else { return }
                outputDraft = current.with(preview: current.preview.with(destination: newValue))
            }
        )
    }

    // MARK: - Metadata draft bindings
    //
    // Same `metadataDraft?.field ?? sessionModel.rollMetadataDraft.field`
    // get / `metadataDraft = metadataDraft?.with(field:)` set shape the
    // capture/processing/output bindings above already use — `metadataDraft`
    // is only ever non-`nil` while these rows are actually on screen (see
    // `FrameOverrideSection`'s `isDraftActive` gate), so the optional-chained
    // `with(...)` in each `set` closure mirrors those bindings' own
    // effectively-guaranteed-non-nil assumption exactly.

    /// Shared plumbing for the free-text rows only — same empty-string-means-
    /// clear-to-nil reasoning as `BatchInspectorView.swift`'s
    /// `rollMetadataTextBinding` (the engine's ExifTool argument builder only
    /// omits a tag for a genuinely absent field, never an empty-string one).
    private func metadataTextBinding(
        get: @escaping (MetadataSet) -> String?,
        apply: @escaping (MetadataSet, String?) -> MetadataSet
    ) -> Binding<String> {
        Binding(
            get: { metadataDraft.flatMap(get) ?? get(sessionModel.rollMetadataDraft) ?? "" },
            set: { newValue in
                let value: String? = newValue.isEmpty ? nil : newValue
                metadataDraft = metadataDraft.map { apply($0, value) }
            }
        )
    }

    private var metadataCameraBinding: Binding<String> {
        metadataTextBinding(get: { $0.camera }, apply: { $0.with(camera: $1) })
    }
    private var metadataLensBinding: Binding<String> {
        metadataTextBinding(get: { $0.lens }, apply: { $0.with(lens: $1) })
    }
    private var metadataFilmStockBinding: Binding<String> {
        metadataTextBinding(get: { $0.filmStock }, apply: { $0.with(filmStock: $1) })
    }
    private var metadataLocationBinding: Binding<String> {
        metadataTextBinding(get: { $0.location }, apply: { $0.with(location: $1) })
    }
    private var metadataPhotographerBinding: Binding<String> {
        metadataTextBinding(get: { $0.photographer }, apply: { $0.with(photographer: $1) })
    }
    private var metadataCopyrightBinding: Binding<String> {
        metadataTextBinding(get: { $0.copyright }, apply: { $0.with(copyright: $1) })
    }
    private var metadataRollIdBinding: Binding<String> {
        metadataTextBinding(get: { $0.rollId }, apply: { $0.with(rollId: $1) })
    }
    private var metadataNotesBinding: Binding<String> {
        metadataTextBinding(get: { $0.notes }, apply: { $0.with(notes: $1) })
    }

    /// Comma-separated free text, same convention as the roll-wide row.
    private var metadataKeywordsBinding: Binding<String> {
        Binding(
            get: { (metadataDraft ?? sessionModel.rollMetadataDraft).keywords.joined(separator: ", ") },
            set: { newValue in
                let keywords = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                metadataDraft = metadataDraft?.with(keywords: keywords)
            }
        )
    }

    private var metadataProcessBinding: Binding<FilmProcess> {
        Binding(
            get: { metadataDraft?.process ?? sessionModel.rollMetadataDraft.process ?? sessionModel.scanFilmProcess },
            set: { newValue in metadataDraft = metadataDraft?.with(process: newValue) }
        )
    }

    /// Same fixed-set-plus-current-custom-value convention as the roll-wide
    /// row (`BatchInspectorView.swift`'s `rollMetadataIsoOptions`).
    private var metadataIsoOptions: [Int] {
        let base = [100, 200, 400, 800, 1_600, 3_200]
        let current = metadataDraft?.iso ?? sessionModel.rollMetadataDraft.iso
        guard let current, !base.contains(current) else { return base }
        return (base + [current]).sorted()
    }

    private var metadataIsoBinding: Binding<Int> {
        Binding(
            get: { metadataDraft?.iso ?? sessionModel.rollMetadataDraft.iso ?? 400 },
            set: { newValue in metadataDraft = metadataDraft?.with(iso: newValue) }
        )
    }

    private var metadataDateBinding: Binding<PartialDate?> {
        Binding(
            get: { metadataDraft?.date ?? sessionModel.rollMetadataDraft.date },
            set: { newValue in metadataDraft = metadataDraft?.with(date: newValue) }
        )
    }

    // MARK: - Footer CTA

    private var footerCTA: some View {
        HStack {
            Spacer()
            Button {
                Task { await sessionModel.scanSingleFrame(frameIndex) }
            } label: {
                Label("Scan Frame \(String(format: "%02d", frameIndex))", systemImage: "scanner.fill")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .tint(.scanStudioAmber)
            .foregroundStyle(.black)
            .disabled(!frameScanReadiness.isReady)
            .help(frameScanReadiness.reason ?? "Scan this frame")
            if let reason = frameScanReadiness.reason {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .frame(maxWidth: 190, alignment: .leading)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }
}

// MARK: - Filmstrip tile

/// A small, independent tile purpose-built for horizontal filmstrip
/// navigation. Renders through the SAME `ThumbnailTileImage` the contact-
/// sheet grid uses (ThumbnailGridView.swift), so it inherits that type's
/// honest real-vs-simulated branch: a real backend's thumbnail shows its
/// actual bridge-written preview tile (or a neutral placeholder while that
/// tile is still mid-write/unloadable), and the bundled mockup crop appears
/// ONLY for a genuinely simulator-shaped thumbnail. This closes the owner's
/// 2026-07-26 requirement that the small FrameDetail filmstrip must not show
/// simulated art on real hardware — an earlier same-day judgment that this
/// strip was "pure navigation chrome" the principle didn't reach is hereby
/// overridden by that explicit requirement. Simulator behavior is unchanged
/// (truthful to simulator data).
private struct FilmstripTile: View {
    let frameIndex: Int
    let isCurrent: Bool
    let thumbnail: Thumbnail?
    /// Derivative rotation preview, kept in sync with the contact sheet
    /// — see `ThumbnailTileImage.orientationDegrees`.
    let orientationDegrees: Int
    let mirrored: Bool
    let verticallyMirrored: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                ThumbnailTileImage(
                    frameIndex: frameIndex,
                    thumbnail: thumbnail,
                    orientationDegrees: orientationDegrees,
                    mirrored: mirrored,
                    verticallyMirrored: verticallyMirrored
                )

                Text(String(format: "%02d", frameIndex))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Color.black.opacity(0.64))
            }
            .frame(
                width: swapsLayoutAxes ? 44 : 64,
                height: swapsLayoutAxes ? 64 : 44
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.scanStudioAmber : Color.white.opacity(0.12), lineWidth: isCurrent ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filmstripAccessibilityLabel)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .accessibilityHint(isCurrent ? "Currently open" : "Open this frame's detail view")
    }

    private var filmstripAccessibilityLabel: String {
        var label = "Frame \(frameIndex)"
        if let orientationText = FrameOrientation.accessibilityText(orientationDegrees) {
            label += ", \(orientationText)"
        }
        if mirrored {
            label += ", mirrored horizontally"
        }
        if verticallyMirrored {
            label += ", mirrored vertically"
        }
        return label
    }

    private var swapsLayoutAxes: Bool {
        FrameOrientation.swapsLayoutAxes(orientationDegrees)
    }
}

// MARK: - Per-frame override section chrome

/// Shared chrome for one of the three per-frame override sections
/// (Capture/Processing/Output): the status row (roll default vs. custom
/// override), the "start editing" button, and the Save/Revert actions are
/// identical in structure across all three — only the editable rows inside
/// `content` differ per recipe type, so those stay in
/// `FrameDetailWorkspaceView`'s own `captureEditorRows`/
/// `processingEditorRows`/`outputEditorRows` rather than forcing a single
/// generic-over-recipe-type editor.
private struct FrameOverrideSection<Content: View>: View {
    let title: String
    let isOverridden: Bool
    let isDraftActive: Bool
    let canSave: Bool
    let onStart: () -> Void
    let onSave: () -> Void
    let onRevert: () -> Void
    let content: Content

    init(
        title: String,
        isOverridden: Bool,
        isDraftActive: Bool,
        canSave: Bool,
        onStart: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onRevert: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isOverridden = isOverridden
        self.isDraftActive = isDraftActive
        self.canSave = canSave
        self.onStart = onStart
        self.onSave = onSave
        self.onRevert = onRevert
        self.content = content()
    }

    var body: some View {
        InspectorSection(title: title) {
            HStack(spacing: 8) {
                if isOverridden {
                    InlineTag(text: "Custom Override", color: .scanStudioAmber)
                } else {
                    Text("Using roll default")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }
                Spacer()
            }

            if isDraftActive {
                VStack(alignment: .leading, spacing: 10) {
                    content

                    HStack(spacing: 8) {
                        Button("Save Override") { onSave() }
                            .buttonStyle(.borderedProminent)
                            .tint(.scanStudioAmber)
                            .controlSize(.small)
                            .disabled(!canSave)

                        if isOverridden {
                            Button("Revert to Roll Default") { onRevert() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 8)
            } else {
                Button("Override for This Frame") { onStart() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Draft-mutation helpers
//
// `CaptureRecipe`/`ProcessingRecipe`/`ArchiveRecipe`/`PositiveRecipe`/
// `PreviewRecipe`/`OutputRecipe` are all plain immutable `let`-only structs
// (mirroring the engine's own wire shapes exactly, per `WireProtocol.swift`)
// — there is no in-place field mutation, so each `with(...)` returns a copy
// with only the passed fields changed. Kept `private` to this file since no
// other view needs them.

private extension CaptureRecipe {
    func with(resolutionDpi: Int? = nil, bitDepth: Int? = nil, multisamplePasses: Int? = nil, channels: String? = nil) -> CaptureRecipe {
        CaptureRecipe(
            resolutionDpi: resolutionDpi ?? self.resolutionDpi,
            bitDepth: bitDepth ?? self.bitDepth,
            multisamplePasses: multisamplePasses ?? self.multisamplePasses,
            channels: channels ?? self.channels
        )
    }
}

private extension ProcessingRecipe {
    func with(
        filmProcess: FilmProcess? = nil,
        autofocusEachFrame: Bool? = nil,
        autoExposureEachFrame: Bool? = nil,
        digitalIceEnabled: Bool? = nil,
        digitalIceMode: DigitalIceMode? = nil,
        softwareDustRemovalBw: Bool? = nil
    ) -> ProcessingRecipe {
        ProcessingRecipe(
            filmProcess: filmProcess ?? self.filmProcess,
            autofocusEachFrame: autofocusEachFrame ?? self.autofocusEachFrame,
            autoExposureEachFrame: autoExposureEachFrame ?? self.autoExposureEachFrame,
            digitalIceEnabled: digitalIceEnabled ?? self.digitalIceEnabled,
            digitalIceMode: digitalIceMode ?? self.digitalIceMode,
            softwareDustRemovalBw: softwareDustRemovalBw ?? self.softwareDustRemovalBw
        )
    }
}

private extension ArchiveRecipe {
    func with(enabled: Bool? = nil, filenameTemplate: String? = nil, destination: String? = nil, fullCapturePackage: Bool? = nil) -> ArchiveRecipe {
        ArchiveRecipe(
            enabled: enabled ?? self.enabled,
            filenameTemplate: filenameTemplate ?? self.filenameTemplate,
            destination: destination ?? self.destination,
            fullCapturePackage: fullCapturePackage ?? self.fullCapturePackage
        )
    }
}

private extension PositiveRecipe {
    func with(
        enabled: Bool? = nil,
        fileFormat: OutputFileFormat? = nil,
        colorProfile: OutputColorProfile? = nil,
        filenameTemplate: String? = nil,
        destination: String? = nil
    ) -> PositiveRecipe {
        PositiveRecipe(
            enabled: enabled ?? self.enabled,
            fileFormat: fileFormat ?? self.fileFormat,
            colorProfile: colorProfile ?? self.colorProfile,
            filenameTemplate: filenameTemplate ?? self.filenameTemplate,
            destination: destination ?? self.destination
        )
    }
}

private extension RawExportRecipe {
    func with(
        enabled: Bool? = nil,
        fileFormat: RawExportFormat? = nil,
        tiffInfrared: RawTiffInfrared? = nil,
        filenameTemplate: String? = nil,
        destination: String? = nil
    ) -> RawExportRecipe {
        RawExportRecipe(
            enabled: enabled ?? self.enabled,
            fileFormat: fileFormat ?? self.fileFormat,
            tiffInfrared: tiffInfrared ?? self.tiffInfrared,
            filenameTemplate: filenameTemplate ?? self.filenameTemplate,
            destination: destination ?? self.destination
        )
    }
}

private extension PreviewRecipe {
    func with(
        enabled: Bool? = nil,
        fileFormat: OutputFileFormat? = nil,
        maxLongEdgePx: Int? = nil,
        filenameTemplate: String? = nil,
        destination: String? = nil
    ) -> PreviewRecipe {
        PreviewRecipe(
            enabled: enabled ?? self.enabled,
            fileFormat: fileFormat ?? self.fileFormat,
            maxLongEdgePx: maxLongEdgePx ?? self.maxLongEdgePx,
            filenameTemplate: filenameTemplate ?? self.filenameTemplate,
            destination: destination ?? self.destination
        )
    }
}

private extension OutputRecipe {
    func with(
        archive: ArchiveRecipe? = nil,
        rawExport: RawExportRecipe? = nil,
        positive: PositiveRecipe? = nil,
        preview: PreviewRecipe? = nil,
        autoCrop: Bool? = nil
    ) -> OutputRecipe {
        OutputRecipe(
            archive: archive ?? self.archive,
            rawExport: rawExport ?? self.rawExport,
            positive: positive ?? self.positive,
            preview: preview ?? self.preview,
            autoCrop: autoCrop ?? self.autoCrop
        )
    }
}
