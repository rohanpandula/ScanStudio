import AppKit
import ScanStudioKit
import SwiftUI

struct BatchInspectorView: View {
    @Environment(SessionModel.self) private var sessionModel
    @State private var masterSettingsExpanded = false
    @State private var positiveTiffSettingsExpanded = false
    @State private var positiveJPEGSettingsExpanded = false
    @FocusState private var focusedGearField: GearField?
    @State private var presentedRecentGear: GearField?

    private enum GearField: Hashable { case camera, lens }

    /// Same idiom `ThumbnailGridView`/`ScanPanelView` already use for
    /// device-kind-aware copy.
    private var isRealDevice: Bool { sessionModel.device?.kind == "real" }

    /// Which live scan telemetry this device may honestly display — see
    /// `ScanTelemetryHonesty` (ScanStudioKit).
    private var telemetryHonesty: ScanTelemetryHonesty { .init(isRealDevice: isRealDevice) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sessionModel.isJobActive ? "CAPTURE MONITOR" : "BATCH SETTINGS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 58)

            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    if sessionModel.isJobActive {
                        activeInspector
                    } else {
                        setupInspector
                    }
                    batchResultSummary
                    hardwareStatusSection
                }
            }
        }
        .background(Color.scanStudioInspector)
        // Runs once when the inspector first appears (this view is mounted
        // for the app's whole lifetime by `ContentView`, never recreated per
        // project) so `sessionModel.exifToolDetection` is already populated
        // before the user ever opens a frame detail view's ExifTool panel.
        .task { await sessionModel.detectExifTool() }
    }

    private var setupInspector: some View {
        Group {
            InspectorSection(title: "Scan Settings") {
                InspectorSettingRow(label: "Recipe") {
                    Picker("Recipe", selection: scanRecipePresetBinding) {
                        ForEach(ScanRecipePreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                }
                if sessionModel.scanRecipePreset == .custom {
                    Label("This recipe has manual changes.", systemImage: "slider.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }
                InspectorSettingRow(label: "Resolution") {
                    Picker("Resolution", selection: resolutionBinding) {
                        Text("1000 ppi").tag(1_000)
                        Text("2000 ppi").tag(2_000)
                        Text("4000 ppi").tag(4_000)
                    }
                }
                InspectorSettingRow(label: "Bit depth") {
                    Picker("Bit depth", selection: bitDepthBinding) {
                        Text("8-bit").tag(8)
                        Text("16-bit").tag(16)
                    }
                }
                InspectorSettingRow(label: "Multi-sampling") {
                    // Constrained to the CONNECTED device's own supported
                    // set (a real LS-5000 accepts only 4x; the simulator
                    // keeps the fuller historical range) rather than a
                    // fixed [1,2,4,8,16] -- offering an option the real
                    // device rejects let the owner hit `scan.start`'s
                    // INVALID_PARAMS twice (verified live 2026-07-25). See
                    // `MultisamplePassPolicy` (SessionModel.swift).
                    Picker("Multi-sampling", selection: multisampleBinding) {
                        ForEach(MultisamplePassPolicy.supportedOptions(for: sessionModel.device), id: \.self) { passes in
                            Text(MultisamplePassPolicy.label(for: passes)).tag(passes)
                        }
                    }
                }
                if let note = sessionModel.multisampleCoercionNote {
                    Label(note, systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                InspectorSettingRow(label: "Color mode") {
                    Picker("Color mode", selection: channelsBinding) {
                        Text("RGB").tag("rgb")
                        Text("RGB + infrared").tag("rgbi")
                    }
                    .disabled(sessionModel.scanFilmProcess == .bwNegative)
                }
                if sessionModel.scanFilmProcess == .bwNegative {
                    Text("B&W uses RGB only; infrared is not captured.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }

                Label(
                    "Applies to all \(sessionModel.selectedFrameCount) selected frame\(sessionModel.selectedFrameCount == 1 ? "" : "s").",
                    systemImage: "square.stack.3d.up"
                )
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

                HStack(spacing: 8) {
                    CompactInspectorToggle(label: "Autofocus", isOn: autofocusBinding)
                    CompactInspectorToggle(label: "Auto exposure", isOn: autoExposureBinding)
                }
                .padding(.top, 6)

                Label(
                    perFrameAutomationExplanation,
                    systemImage: "viewfinder"
                )
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                InspectorToggleRow(label: "Digital ICE", isOn: digitalIceBinding)
                    .disabled(sessionModel.scanFilmProcess == .bwNegative)

                if sessionModel.scanFilmProcess == .bwNegative {
                    Label("Traditional silver B&W film blocks infrared, so Digital ICE is unavailable.", systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                    InspectorToggleRow(label: "Software Dust Removal (B&W)", isOn: softwareDustRemovalBinding)
                    Label("Beta classical CV cleanup for compact dust specks. It affects positive and preview derivatives only; the archive master is unchanged.", systemImage: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }

                if sessionModel.digitalIceEnabled && sessionModel.scanFilmProcess != .bwNegative {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Digital ICE mode", selection: digitalIceModeBinding) {
                            Text("Legacy").tag(DigitalIceMode.legacy)
                            Text("Hybrid").tag(DigitalIceMode.hybrid)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)

                        Label(iceModeExplanation, systemImage: "wand.and.stars")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.scanStudioSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: sessionModel.digitalIceEnabled)
            saveOutputsSection
            InspectorSection(title: "Film & gear") {
                InspectorSettingRow(label: "Film stock") {
                    Picker("Film stock", selection: filmStockSelectionBinding) {
                        ForEach(["Kodak", "Fujifilm", "Ilford"], id: \.self) { brand in
                            Section(brand) {
                                ForEach(FilmStock.curated.filter { $0.brand == brand }) { stock in
                                    Text(stock.name).tag(stock.id)
                                }
                            }
                        }
                        Divider()
                        Text("Custom…").tag(customFilmStockID)
                    }
                }
                if filmStockSelectionBinding.wrappedValue == customFilmStockID {
                    InspectorTextFieldRow(label: "Custom stock", text: rollMetadataFilmStockBinding)
                    InspectorSettingRow(label: "Process") {
                        Picker("Process", selection: rollMetadataProcessBinding) {
                            Text("Positive").tag(FilmProcess.positive)
                            Text("C-41 color negative").tag(FilmProcess.c41ColorNegative)
                            Text("Traditional B&W").tag(FilmProcess.bwNegative)
                            Text("Kodachrome").tag(FilmProcess.kodachrome)
                        }
                    }
                } else {
                    InspectorRow(label: "Process", value: processDisplayName)
                }
                if processIsEstablished {
                    Text("The preview/project process is established. Re-preview to change how the scanner captures it.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }
                recentGearField(label: "Camera", text: rollMetadataCameraBinding, values: sessionModel.recentGearHistory.recentCameras, select: setRecentCamera, remove: sessionModel.removeRecentCamera)
                recentGearField(label: "Lens", text: rollMetadataLensBinding, values: sessionModel.recentGearHistory.recentLenses(for: sessionModel.rollMetadataDraft.camera), select: setRecentLens, remove: sessionModel.removeRecentLens)
                InspectorSettingRow(label: "ISO") {
                    Picker("ISO", selection: rollMetadataIsoBinding) {
                        ForEach(rollMetadataIsoOptions, id: \.self) { iso in
                            Text("\(iso)").tag(iso)
                        }
                    }
                }
                InspectorSettingRow(label: "Date") {
                    PartialDateEditor(date: rollMetadataDateBinding)
                }
                Label("Known stocks set their box speed once when selected. You can still enter a pushed or pulled ISO.", systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }
            InspectorSection(title: "Roll notes") {
                InspectorTextFieldRow(label: "Location", text: rollMetadataLocationBinding)
                InspectorTextFieldRow(label: "Photographer", text: rollMetadataPhotographerBinding)
                InspectorTextFieldRow(label: "Copyright", text: rollMetadataCopyrightBinding)
                InspectorTextFieldRow(label: "Roll ID", text: rollMetadataRollIdBinding)
                InspectorTextFieldRow(label: "Notes", text: rollMetadataNotesBinding)
                InspectorTextFieldRow(label: "Keywords", text: rollMetadataKeywordsBinding)

                Label(
                    "Keywords are comma-separated. Every field here is optional and inherited by any frame without its own Metadata override.",
                    systemImage: "tag"
                )
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 6)

                InspectorRow(label: "ExifTool", value: exifToolStatusSummary)
            }
            InspectorSection(title: "Estimated Size") {
                InspectorRow(
                    label: "Master TIFF (per frame)",
                    value: sessionModel.masterTIFFEnabled
                        ? formattedSize(bytes: ScanSizeEstimator.archiveBytesPerFrame(
                            carrier: sessionModel.loadedCarrier ?? .roll36,
                            resolutionDpi: sessionModel.scanResolutionDpi,
                            bitDepth: sessionModel.scanBitDepth
                        ))
                        : "Off"
                )
                InspectorRow(
                    label: "\(positiveTiffOutputTitle) (per frame)",
                    value: sessionModel.positiveEnabled
                        ? formattedSize(bytes: ScanSizeEstimator.positiveBytesPerFrame(
                            carrier: sessionModel.loadedCarrier ?? .roll36,
                            resolutionDpi: sessionModel.scanResolutionDpi,
                            bitDepth: sessionModel.scanBitDepth,
                            fileFormat: sessionModel.positiveFileFormat
                        ))
                        : "Off"
                )
                InspectorRow(
                    label: "Preview (per frame)",
                    value: sessionModel.previewEnabled
                        ? formattedSize(bytes: ScanSizeEstimator.previewBytesPerFrame(
                            carrier: sessionModel.loadedCarrier ?? .roll36,
                            resolutionDpi: sessionModel.scanResolutionDpi,
                            maxLongEdgePx: sessionModel.previewMaxLongEdgePx,
                            fileFormat: sessionModel.previewFileFormat
                        ))
                        : "Off"
                )
                InspectorRow(label: "Selected (\(sessionModel.selectedFrameCount))", value: selectedSize)
                InspectorRow(label: "Roll Total (\(sessionModel.status?.frameCount ?? 0))", value: carrierSize)

                Label(sizeExplanation, systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    private var saveOutputsSection: some View {
        InspectorSection(title: "Save & outputs") {
            Label(
                sessionModel.masterTIFFEnabled
                    ? "Master scans are append-only and are never overwritten."
                    : "A temporary capture is used internally to render selected outputs and is retained only on failure for recovery.",
                systemImage: sessionModel.masterTIFFEnabled ? "lock.fill" : "externaldrive.badge.exclamationmark"
            )
            .font(.system(size: 10))
            .foregroundStyle(Color.scanStudioSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 6)

            HStack(alignment: .top, spacing: 8) {
                Text(sessionModel.saveLocation.isEmpty ? "Choose a save location when you are ready." : sessionModel.saveLocation)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseSaveLocation)
                    .controlSize(.small)
            }
            InspectorToggleRow(label: "Save each output in its own folder", isOn: saveEachOutputInOwnFolderBinding)
            Text("Keep at least one output.")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)

            outputDisclosure(title: "Keep master TIFF", isEnabled: masterTIFFEnabledBinding, canToggle: !sessionModel.masterTIFFEnabled || sessionModel.positiveEnabled || sessionModel.previewEnabled, folderName: masterFolderNameBinding, expanded: $masterSettingsExpanded) {
                if sessionModel.masterTIFFEnabled {
                    InspectorToggleRow(label: "Full capture package", isOn: fullCapturePackageBinding)
                    Text(fullCapturePackageExplanation)
                }
            }
            outputDisclosure(title: positiveTiffOutputTitle, isEnabled: positiveEnabledBinding, canToggle: !sessionModel.positiveEnabled || sessionModel.masterTIFFEnabled || sessionModel.previewEnabled, folderName: positiveTiffFolderNameBinding, expanded: $positiveTiffSettingsExpanded) {
                InspectorSettingRow(label: "Color setting") {
                    Picker("Color setting", selection: positiveColorProfileBinding) {
                        Text("Current engine default").tag(OutputColorProfile.adobeRgb1998)
                    }
                }
                Text(positiveOutputExplanation)
            }
            outputDisclosure(title: positiveJPEGOutputTitle, isEnabled: previewEnabledBinding, canToggle: !sessionModel.previewEnabled || sessionModel.masterTIFFEnabled || sessionModel.positiveEnabled, folderName: positiveJPEGFolderNameBinding, expanded: $positiveJPEGSettingsExpanded) {
                InspectorSettingRow(label: "Long edge") {
                    Picker("Long edge", selection: previewMaxLongEdgePxBinding) {
                        Text("Full resolution").tag(0)
                        Text("4096 px").tag(4_096)
                        Text("2048 px").tag(2_048)
                        Text("1024 px").tag(1_024)
                    }
                }
                Text("JPEG quality is fixed by the current engine.")
            }

            InspectorToggleRow(label: "Auto crop derived outputs", isOn: autoCropEnabledBinding)
            Text("Each frame's positive and JPEG are cropped to that frame's own detected image area at scan time. The master TIFF always keeps the full frame, and every crop is recorded in the frame's receipt, so this is reversible by re-rendering.")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            InspectorTextFieldRow(label: "File naming", text: sharedFilenameTemplateBinding)
            Text(FilenameTemplate.expand(sessionModel.archiveFilenameTemplate, metadata: sessionModel.rollMetadataDraft, frameIndex: 1))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .textSelection(.enabled)
            InspectorToggleRow(label: "Save naming template as my default", isOn: saveFilenameTemplateAsDefaultBinding)
            Label("Tokens: $FilmStock  $Camera  $Lens  $Month  $Day  $Year  $Frame  •  # next sequence number", systemImage: "textformat")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
        }
    }

    private var activeInspector: some View {
        Group {
            InspectorSection(title: "Current Frame") {
                InspectorRow(
                    label: "Frame",
                    value: reportedCurrentFrame.map(String.init)
                        ?? "Not reported"
                )
                // A live pass counter is genuine only on the simulator; a
                // real backend hardcodes `pass` to 1 and echoes the recipe
                // for `total_passes` (see `ScanTelemetryHonesty`), so "1 of
                // 2" would assert a current-pass position it never tracks.
                if telemetryHonesty.showsLivePassCount {
                    InspectorRow(label: "Pass", value: "\(sessionModel.progress?.pass ?? 1) of \(sessionModel.progress?.totalPasses ?? 2)")
                }
                InspectorRow(label: "Resolution", value: "\(sessionModel.scanResolutionDpi) ppi")
                InspectorRow(label: "Bit depth", value: "\(sessionModel.scanBitDepth)-bit")
                InspectorRow(label: "Channels", value: sessionModel.scanChannels.uppercased())
                InspectorRow(label: "Autofocus", value: sessionModel.autofocusEachFrame ? "Each frame" : "Off")
                InspectorRow(label: "Auto exposure", value: sessionModel.autoExposureEachFrame ? "Each frame" : "Off")
                InspectorRow(label: "Digital ICE", value: digitalIceSummary)
                InspectorRow(label: "Saved outputs", value: activeOutputsSummary)
            }

            InspectorSection(title: histogramSectionTitle) {
                histogramContent
            }

            InspectorSection(title: "Batch") {
                InspectorRow(label: "Completed", value: "\(sessionModel.receiptCount)")
                InspectorRow(label: "Requested", value: "\(sessionModel.selectedFrameCount)")
                InspectorRow(label: "Failed", value: "\(failedCount)")
                InspectorRow(label: "Skipped", value: "\(skippedCount)")
                if transportSmearCount > 0 {
                    InspectorRow(label: "Transport Smear", value: "\(transportSmearCount)")
                }
                if sessionModel.masterTIFFEnabled {
                    InspectorRow(label: "Master TIFF", value: sessionModel.outputRecipe.archive.destination)
                }
                if sessionModel.positiveEnabled {
                    InspectorRow(label: positiveTiffOutputTitle, value: sessionModel.outputRecipe.positive.destination)
                }
                if sessionModel.previewEnabled {
                    InspectorRow(label: positiveJPEGOutputTitle, value: sessionModel.outputRecipe.preview.destination)
                }
            }

            if let receipt = sessionModel.receipts.last {
                InspectorSection(title: "Scan Receipt") {
                    InspectorRow(label: "Frame", value: "\(receipt.frameIndex)")
                    InspectorRow(label: "Duration", value: String(format: "%.1fs", Double(receipt.durationMs) / 1_000))
                    InspectorRow(label: "Passes", value: "\(receipt.passes)")
                    InspectorRow(label: "Engine", value: receipt.engineVersion)
                    InspectorRow(label: "Proof", value: String(receipt.settingsFingerprint.prefix(8)))
                }
            }

        }
    }

    private var reportedCurrentFrame: Int? {
        telemetryHonesty.currentFrameIndex(
            reported: sessionModel.progress?.frameIndex,
            frameStates: sessionModel.frameStates
        )
    }

    private var hardwareStatusSection: some View {
        InspectorSection(title: "Hardware Status") {
            StatusPill(label: transportStatusLabel, color: transportStatusColor, symbol: transportStatusSymbol)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(transportStatusLabel)
            StatusPill(label: errorStatusLabel, color: errorStatusColor, symbol: errorStatusSymbol)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(errorStatusLabel)
            InspectorRow(label: "Device", value: sessionModel.device?.deviceId ?? "Simulator")
        }
    }

    @ViewBuilder
    private var batchResultSummary: some View {
        if let summary = sessionModel.scanSummary, !sessionModel.isJobActive {
            InspectorSection(title: "Last Batch") {
                InspectorRow(label: "Completed", value: "\(summary.completed.count)")
                if !needsReviewFrames.isEmpty {
                    InspectorRow(label: "Needs review", value: frameList(needsReviewFrames))
                }
                if !failedFrames.isEmpty {
                    InspectorRow(label: "Failed", value: frameList(failedFrames))
                }
                if !summary.skipped.isEmpty {
                    InspectorRow(label: "Skipped", value: frameList(summary.skipped))
                }
                if summary.stopped {
                    InspectorRow(label: "Stopped early", value: "Yes")
                }
                if let evidence = summary.evidencePackageStatus {
                    InspectorRow(label: "Capture evidence", value: evidence)
                }
                if !needsReviewFrames.isEmpty {
                    Label(
                        "Needs review frames were refused before scanning, not capture failures.",
                        systemImage: "info.circle"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var needsReviewFrames: [Int] {
        (sessionModel.scanSummary?.failed ?? []).filter {
            sessionModel.frameErrors[$0]?.code == FrameFailureLabel.manualReviewCode
        }
    }

    private var failedFrames: [Int] {
        (sessionModel.scanSummary?.failed ?? []).filter {
            sessionModel.frameErrors[$0]?.code != FrameFailureLabel.manualReviewCode
        }
    }

    private func frameList(_ frames: [Int]) -> String {
        frames.sorted().map { String(format: "%02d", $0) }.joined(separator: ", ")
    }

    private var selectedSize: String {
        formattedSize(bytes: totalEstimatedBytesPerFrame * sessionModel.selectedFrameCount)
    }

    private var carrierSize: String {
        formattedSize(bytes: totalEstimatedBytesPerFrame * (sessionModel.status?.frameCount ?? 0))
    }

    /// Retained-master bytes, plus either selected derivative. Internal
    /// temporary capture workspace is intentionally excluded when the
    /// master is off: it is not a user-visible saved output.
    private var totalEstimatedBytesPerFrame: Int {
        let carrier = sessionModel.loadedCarrier ?? .roll36
        var total = 0
        if sessionModel.masterTIFFEnabled {
            total += ScanSizeEstimator.archiveBytesPerFrame(
                carrier: carrier,
                resolutionDpi: sessionModel.scanResolutionDpi,
                bitDepth: sessionModel.scanBitDepth
            )
        }
        if sessionModel.positiveEnabled {
            total += ScanSizeEstimator.positiveBytesPerFrame(
                carrier: carrier,
                resolutionDpi: sessionModel.scanResolutionDpi,
                bitDepth: sessionModel.scanBitDepth,
                fileFormat: sessionModel.positiveFileFormat
            )
        }
        if sessionModel.previewEnabled {
            total += ScanSizeEstimator.previewBytesPerFrame(
                carrier: carrier,
                resolutionDpi: sessionModel.scanResolutionDpi,
                maxLongEdgePx: sessionModel.previewMaxLongEdgePx,
                fileFormat: sessionModel.previewFileFormat
            )
        }
        return total
    }

    private func formattedSize(bytes: Int) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1_000 { return String(format: "~%.2f GB", megabytes / 1_000) }
        return String(format: "~%.0f MB", megabytes)
    }

    private var sizeExplanation: String {
        sessionModel.masterTIFFEnabled
            ? "Master TIFF uses uncompressed capture resolution; Positive and Preview use their own format and size settings above."
            : "Estimate includes only retained derivatives. The internal temporary capture is not saved as an output and is held only if recovery is needed."
    }

    /// A real, always-current summary of which outputs this batch will
    /// write — the Archive master plus whichever derivatives are enabled —
    /// replacing the old single "Save image" three-way choice now that the
    /// three outputs are independent (REC-01/02/03).
    private var activeOutputsSummary: String {
        var parts: [String] = []
        if sessionModel.masterTIFFEnabled { parts.append("Master TIFF") }
        if sessionModel.positiveEnabled { parts.append(positiveTiffOutputTitle) }
        if sessionModel.previewEnabled { parts.append(positiveJPEGOutputTitle) }
        return parts.joined(separator: " + ")
    }

    private var digitalIceSummary: String {
        guard sessionModel.digitalIceEnabled else { return "Off" }
        return sessionModel.digitalIceMode == .legacy ? "Legacy" : "Hybrid"
    }

    private var histogramSectionTitle: String {
        histogramThumbnail?.isSimulatorShaped == true ? "Histogram (Simulated)" : "Histogram"
    }

    private var histogramTargetFrame: Int? {
        if sessionModel.isJobActive { return sessionModel.progress?.frameIndex }
        return sessionModel.selectedFrameIndices.count == 1 ? sessionModel.selectedFrameIndices.first : nil
    }

    private var histogramThumbnail: Thumbnail? {
        guard let frame = histogramTargetFrame else { return nil }
        return sessionModel.thumbnails[frame]
    }

    @ViewBuilder
    private var histogramContent: some View {
        if let frame = histogramTargetFrame {
            histogramContent(for: frame)
        } else {
            histogramReason(sessionModel.isJobActive
                ? "Waiting for the active frame."
                : "Select a single frame to see its histogram.")
        }
    }

    @ViewBuilder
    private func histogramContent(for frame: Int) -> some View {
        if let thumbnail = histogramThumbnail, thumbnail.isSimulatorShaped {
            HistogramView(seed: frame)
                .frame(height: 104)
                .accessibilityLabel("Simulated color histogram")
            Text("Illustrative waveform, not measured from real pixel data.")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
        } else if let path = histogramThumbnail?.imagePath,
                  let image = ThumbnailImageCache.image(atPath: path),
                  let bins = HistogramSampler.bins(from: image) {
            RealHistogramView(bins: bins)
                .frame(height: 104)
                .accessibilityLabel("Color histogram from frame \(frame) preview pixels")
        } else {
            histogramReason(histogramNoImageReason(for: frame))
        }
    }

    private func histogramNoImageReason(for frame: Int) -> String {
        histogramThumbnail == nil
            ? "No preview for frame \(frame)."
            : "No loadable preview for frame \(frame) yet."
    }

    private func histogramReason(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Color.scanStudioSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var perFrameAutomationExplanation: String {
        switch sessionModel.selectedFrameCount {
        case 0: "Runs before each frame you select."
        case 1: "Runs before the selected single scan."
        default: "Runs independently before every selected frame in the batch."
        }
    }

    private var iceModeExplanation: String {
        switch sessionModel.digitalIceMode {
        case .legacy:
            "Digital ICE (Legacy) uses the scanner's infrared dust and scratch data."
        case .hybrid:
            "Digital ICE (Hybrid) carries the infrared mask into the modern processing pipeline."
        }
    }

    /// Hardware Status StatusPill rows read only real `ScannerStatus`/
    /// `lastErrorMessage` state -- never a fixed "always healthy" placebo
    /// (T-05-04).
    private var transportStatusLabel: String {
        sessionModel.status?.transport == "idle" ? "Transport idle" : "Transport locked"
    }

    private var transportStatusColor: Color {
        sessionModel.status?.transport == "idle" ? .scanStudioCyan : .scanStudioAmber
    }

    private var transportStatusSymbol: String {
        sessionModel.status?.transport == "idle" ? "checkmark.circle.fill" : "lock.fill"
    }

    /// Curated title, not the raw `lastErrorMessage` -- this pill sits in the
    /// always-visible inspector, not behind a "technical details" disclosure
    /// like `WorkspaceErrorBanner`, so it never gets to show engine text
    /// verbatim. `errorPresentation` is `nil` exactly when `lastErrorMessage`
    /// is, so the fallback stays in sync automatically.
    private var errorStatusLabel: String {
        sessionModel.errorPresentation.map { "Error: \($0.title)" } ?? "No errors"
    }

    private var errorStatusColor: Color {
        sessionModel.lastErrorMessage != nil ? .scanStudioRed : .scanStudioGreen
    }

    private var errorStatusSymbol: String {
        sessionModel.lastErrorMessage != nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var failedCount: Int {
        sessionModel.frameStates.values.filter { $0 == .failed }.count
    }

    private var skippedCount: Int {
        sessionModel.frameStates.values.filter { $0 == .skipped }.count
    }

    private var transportSmearCount: Int {
        sessionModel.frameStates.compactMap { frameIndex, state in
            state == .completed ? sessionModel.frameTransportSmearReasons[frameIndex] : nil
        }.count
    }

    private var resolutionBinding: Binding<Int> {
        Binding(
            get: { sessionModel.scanResolutionDpi },
            set: { sessionModel.scanResolutionDpi = $0 }
        )
    }

    private var bitDepthBinding: Binding<Int> {
        Binding(
            get: { sessionModel.scanBitDepth },
            set: { sessionModel.scanBitDepth = $0 }
        )
    }

    private var multisampleBinding: Binding<Int> {
        Binding(
            get: { sessionModel.scanMultisamplePasses },
            set: { sessionModel.scanMultisamplePasses = $0 }
        )
    }

    private var channelsBinding: Binding<String> {
        Binding(
            get: { sessionModel.scanFilmProcess == .bwNegative ? "rgb" : sessionModel.scanChannels },
            set: {
                guard sessionModel.scanFilmProcess != .bwNegative else { return }
                sessionModel.scanChannels = $0
                if $0 == "rgb" { sessionModel.digitalIceEnabled = false }
            }
        )
    }

    private var filmProcessBinding: Binding<FilmProcess> {
        Binding(get: { sessionModel.scanFilmProcess }, set: { newValue in
            guard !processIsEstablished else { return }
            sessionModel.scanFilmProcess = newValue
            if newValue == .bwNegative {
                sessionModel.scanChannels = "rgb"
                sessionModel.digitalIceEnabled = false
            }
        })
    }

    private var processIsEstablished: Bool {
        sessionModel.previewFilmProcess != nil || sessionModel.project != nil
    }

    private var autofocusBinding: Binding<Bool> {
        Binding(get: { sessionModel.autofocusEachFrame }, set: { sessionModel.autofocusEachFrame = $0 })
    }

    private var autoExposureBinding: Binding<Bool> {
        Binding(get: { sessionModel.autoExposureEachFrame }, set: { sessionModel.autoExposureEachFrame = $0 })
    }

    private var digitalIceBinding: Binding<Bool> {
        Binding(
            get: { sessionModel.digitalIceEnabled },
            set: {
                guard sessionModel.scanFilmProcess != .bwNegative else { return }
                sessionModel.digitalIceEnabled = $0
                if $0 { sessionModel.scanChannels = "rgbi" }
            }
        )
    }

    private var softwareDustRemovalBinding: Binding<Bool> {
        Binding(get: { sessionModel.softwareDustRemovalBw }, set: { sessionModel.softwareDustRemovalBw = $0 })
    }

    private var digitalIceModeBinding: Binding<DigitalIceMode> {
        Binding(get: { sessionModel.digitalIceMode }, set: { sessionModel.digitalIceMode = $0 })
    }

    private var scanRecipePresetBinding: Binding<ScanRecipePreset> {
        Binding(
            get: { sessionModel.scanRecipePreset },
            set: { sessionModel.applyScanRecipePreset($0) }
        )
    }

    private let customFilmStockID = "custom"

    private var filmStockSelectionBinding: Binding<String> {
        Binding(
            get: {
                sessionModel.isCustomFilmStockSelected
                    ? customFilmStockID
                    : (FilmStock.matching(metadataName: sessionModel.rollMetadataDraft.filmStock)?.id ?? customFilmStockID)
            },
            set: { identifier in
                if identifier == customFilmStockID {
                    sessionModel.beginCustomFilmStock()
                    Task { await sessionModel.setRollMetadata(sessionModel.rollMetadataDraft) }
                    return
                }
                guard let stock = FilmStock.curated.first(where: { $0.id == identifier }) else { return }
                sessionModel.applyFilmStock(stock)
                Task { await sessionModel.setRollMetadata(sessionModel.rollMetadataDraft) }
            }
        )
    }

    private var processDisplayName: String {
        switch sessionModel.rollMetadataDraft.process ?? sessionModel.scanFilmProcess {
        case .positive: "E-6 positive"
        case .c41ColorNegative: "C-41 color negative"
        case .bwNegative: "Traditional B&W"
        case .kodachrome: "Kodachrome"
        }
    }

    private var positiveTiffOutputTitle: String {
        guard sessionModel.positiveFileFormat == .tiff else {
            return "Positive \(sessionModel.positiveFileFormat.rawValue.uppercased())"
        }
        return switch sessionModel.scanFilmProcess {
        case .c41ColorNegative, .bwNegative: "Positive TIFF"
        case .positive, .kodachrome: "TIFF copy"
        }
    }

    private var positiveJPEGOutputTitle: String {
        guard sessionModel.previewFileFormat == .jpeg else {
            return "Positive \(sessionModel.previewFileFormat.rawValue.uppercased())"
        }
        return switch sessionModel.scanFilmProcess {
        case .c41ColorNegative, .bwNegative: "Positive JPEG"
        case .positive, .kodachrome: "JPEG copy"
        }
    }

    private var positiveOutputExplanation: String {
        switch sessionModel.scanFilmProcess {
        case .c41ColorNegative:
            "Beta: C-41 positive conversion is experimental. Retain the master TIFF so you can re-render it as the conversion improves."
        case .bwNegative: "A full-resolution B&W negative conversion."
        case .positive, .kodachrome: "A full-resolution copy; positive film is not inverted."
        }
    }

    private var saveEachOutputInOwnFolderBinding: Binding<Bool> {
        Binding(get: { sessionModel.saveEachOutputInOwnFolder }, set: { sessionModel.saveEachOutputInOwnFolder = $0 })
    }

    private var fullCapturePackageBinding: Binding<Bool> {
        Binding(
            get: { sessionModel.masterTIFFEnabled && sessionModel.fullCapturePackageEnabled },
            set: { sessionModel.fullCapturePackageEnabled = sessionModel.masterTIFFEnabled && $0 }
        )
    }

    private var fullCapturePackageExplanation: String {
        sessionModel.scanChannels == "rgbi"
            ? "Copies bridge-provided attempt evidence after the job finishes; available IR and meter paths are recorded."
            : "Copies bridge-provided attempt evidence after the job finishes. IR is unavailable for RGB-only capture."
    }


    private var masterFolderNameBinding: Binding<String> {
        Binding(get: { sessionModel.masterFolderName }, set: { sessionModel.masterFolderName = $0 })
    }

    private var masterTIFFEnabledBinding: Binding<Bool> {
        Binding(get: { sessionModel.masterTIFFEnabled }, set: { sessionModel.setMasterTIFFEnabled($0) })
    }

    private var positiveTiffFolderNameBinding: Binding<String> {
        Binding(get: { sessionModel.positiveTiffFolderName }, set: { sessionModel.positiveTiffFolderName = $0 })
    }

    private var positiveJPEGFolderNameBinding: Binding<String> {
        Binding(get: { sessionModel.positiveJPEGFolderName }, set: { sessionModel.positiveJPEGFolderName = $0 })
    }

    private var autoCropEnabledBinding: Binding<Bool> {
        Binding(get: { sessionModel.autoCropEnabled }, set: { sessionModel.setAutoCropEnabled($0) })
    }

    private var sharedFilenameTemplateBinding: Binding<String> {
        Binding(
            get: { sessionModel.archiveFilenameTemplate },
            set: { value in
                sessionModel.setSharedFilenameTemplate(value)
            }
        )
    }

    private var saveFilenameTemplateAsDefaultBinding: Binding<Bool> {
        Binding(
            get: { sessionModel.saveFilenameTemplateAsDefault },
            set: { enabled in
                sessionModel.saveFilenameTemplateAsDefault = enabled
                if enabled { sessionModel.saveCurrentFilenameTemplateAsUserDefault() }
            }
        )
    }

    private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Save Location"
        if panel.runModal() == .OK, let url = panel.url {
            sessionModel.saveLocation = url.path
        }
    }

    @ViewBuilder
    private func outputDisclosure<Content: View>(
        title: String,
        isEnabled: Binding<Bool>,
        canToggle: Bool,
        folderName: Binding<String>,
        expanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(title, isOn: isEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(!canToggle)
                Spacer()
                if isEnabled.wrappedValue {
                    Button {
                        expanded.wrappedValue.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(title) settings")
                }
            }
            if sessionModel.saveEachOutputInOwnFolder && isEnabled.wrappedValue {
                InspectorTextFieldRow(label: "Folder", text: folderName)
            }
            if isEnabled.wrappedValue && expanded.wrappedValue {
                content()
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func recentGearField(
        label: String,
        text: Binding<String>,
        values: [String],
        select: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        let field: GearField = label == "Camera" ? .camera : .lens
        InspectorSettingRow(label: label) {
            HStack(spacing: 6) {
                TextField(label, text: text)
                    .onSubmit { sessionModel.rememberCurrentGear() }
                    .focused($focusedGearField, equals: field)
                    .onChange(of: focusedGearField) { _, next in
                        if next != field { sessionModel.rememberCurrentGear() }
                    }
                Button {
                    presentedRecentGear = field
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Recent \(label.lowercased())")
                .popover(isPresented: Binding(
                    get: { presentedRecentGear == field },
                    set: { if !$0 { presentedRecentGear = nil } }
                ), arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent \(label)")
                            .font(.system(size: 11, weight: .semibold))
                        if values.isEmpty {
                            Text("No remembered values yet.")
                                .foregroundStyle(Color.scanStudioSecondaryText)
                        } else {
                            ForEach(values, id: \.self) { value in
                                HStack(spacing: 6) {
                                    Button(value) {
                                        select(value)
                                        presentedRecentGear = nil
                                    }
                                    .buttonStyle(.plain)
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) { remove(value) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(value) from recent \(label.lowercased())")
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(minWidth: 180)
                }
            }
        }
    }

    private func setRecentCamera(_ value: String) {
        applyRollMetadata { $0.with(camera: value) }
        sessionModel.rememberCurrentGear()
    }

    private func setRecentLens(_ value: String) {
        applyRollMetadata { $0.with(lens: value) }
        sessionModel.rememberCurrentGear()
    }

    private var archiveFilenameTemplateBinding: Binding<String> {
        Binding(get: { sessionModel.archiveFilenameTemplate }, set: { sessionModel.archiveFilenameTemplate = $0 })
    }

    private var archiveDestinationBinding: Binding<String> {
        Binding(get: { sessionModel.archiveDestination }, set: { sessionModel.archiveDestination = $0 })
    }

    private var positiveEnabledBinding: Binding<Bool> {
        Binding(get: { sessionModel.positiveEnabled }, set: { sessionModel.setPositiveEnabled($0) })
    }

    private var positiveFileFormatBinding: Binding<OutputFileFormat> {
        Binding(get: { sessionModel.positiveFileFormat }, set: { sessionModel.positiveFileFormat = $0 })
    }

    private var positiveColorProfileBinding: Binding<OutputColorProfile> {
        Binding(get: { sessionModel.positiveColorProfile }, set: { sessionModel.positiveColorProfile = $0 })
    }

    private var positiveFilenameTemplateBinding: Binding<String> {
        Binding(get: { sessionModel.positiveFilenameTemplate }, set: { sessionModel.positiveFilenameTemplate = $0 })
    }

    private var positiveDestinationBinding: Binding<String> {
        Binding(get: { sessionModel.positiveDestination }, set: { sessionModel.positiveDestination = $0 })
    }

    private var previewEnabledBinding: Binding<Bool> {
        Binding(get: { sessionModel.previewEnabled }, set: { sessionModel.setPreviewEnabled($0) })
    }

    private var previewFileFormatBinding: Binding<OutputFileFormat> {
        Binding(get: { sessionModel.previewFileFormat }, set: { sessionModel.previewFileFormat = $0 })
    }

    private var previewMaxLongEdgePxBinding: Binding<Int> {
        Binding(get: { sessionModel.previewMaxLongEdgePx }, set: { sessionModel.previewMaxLongEdgePx = $0 })
    }

    private var previewFilenameTemplateBinding: Binding<String> {
        Binding(get: { sessionModel.previewFilenameTemplate }, set: { sessionModel.previewFilenameTemplate = $0 })
    }

    private var previewDestinationBinding: Binding<String> {
        Binding(get: { sessionModel.previewDestination }, set: { sessionModel.previewDestination = $0 })
    }

    // MARK: - Roll metadata bindings (META-01/02)
    //
    // Every row here is live-bound directly to `sessionModel.rollMetadataDraft`
    // and round-trips through a real `setRollMetadata` call on every edit —
    // there is deliberately no separate draft/Save step, matching every other
    // roll-wide setting in this file (the draft-then-Save/Revert shape is
    // reserved for FrameDetailWorkspaceView's per-frame override sections).

    /// Applies `mutate` to the live roll-metadata draft *synchronously* and
    /// then persists the already-applied result to the engine as a fire-
    /// and-forget background action. This is the fix for the bug where
    /// typing into Camera/Lens (and, it turns out, every other Metadata row)
    /// and then moving focus away made the just-typed value disappear
    /// (found + fixed 2026-07-26).
    ///
    /// Root cause: every binding below used to build the new value with
    /// `apply(sessionModel.rollMetadataDraft, ...)` *inside* the `Task`, then
    /// hand only that value to `setRollMetadata` — which, on success, does
    /// `project = result.project` and nothing else (see
    /// `SessionModel.setRollMetadata` in SessionModel.swift). `rollMetadataDraft`
    /// itself — the only thing every `get` closure here reads — was written
    /// nowhere except once, at project load (`createProject`/`openProject`).
    /// So the moment anything caused `BatchInspectorView.body` to re-render —
    /// most commonly the very `project` reassignment that landed from that
    /// same edit's own round trip completing — every Metadata `get` closure
    /// re-read the untouched, load-time `rollMetadataDraft` and snapped the
    /// field back to it, discarding whatever the user had just typed. This
    /// was not a narrow timing race that "usually" resolves once the round
    /// trip finishes: `rollMetadataDraft` was never updated by an edit at
    /// all, so the field was reverting to stale state on every single edit,
    /// it just wasn't visible until *some* re-render finally happened to
    /// occur (typically the very edit's own completion, which tends to land
    /// right around the time focus moves to the next field).
    ///
    /// Fix: write `rollMetadataDraft` here, synchronously, before firing the
    /// persist `Task` — the same "local state is the immediate source of
    /// truth; the round trip is a secondary persistence action" shape
    /// `FrameDetailWorkspaceView`'s per-frame override bindings already use
    /// for their own local `metadataDraft` (that file's `set` closures never
    /// touch the engine at all until the user taps Save). Doing this also
    /// sidesteps `EngineClient`'s per-request-ID concurrent continuations
    /// (EngineClient.swift) ever resolving two overlapping edits out of
    /// order: `get` now always answers from state this function just set,
    /// never from whatever an in-flight response eventually writes back.
    private func applyRollMetadata(_ mutate: (MetadataSet) -> MetadataSet) {
        let updated = mutate(sessionModel.rollMetadataDraft)
        sessionModel.rollMetadataDraft = updated
        Task { await sessionModel.setRollMetadata(updated) }
    }

    /// Shared plumbing for the free-text Metadata rows: reads the field
    /// straight from the live draft, and on edit writes an empty typed field
    /// back as a real absent value (`nil`), never a stored empty string — the
    /// engine's own ExifTool argument builder only omits a tag when its
    /// `MetadataSet` field is `None` (`if let Some(camera) = &metadata.camera`
    /// in `exiftool.rs`), so a stored `Some("")` would emit a bogus empty-value
    /// argument instead of omitting the tag entirely.
    private func rollMetadataTextBinding(
        get: @escaping (MetadataSet) -> String?,
        apply: @escaping (MetadataSet, String?) -> MetadataSet
    ) -> Binding<String> {
        Binding(
            get: { get(sessionModel.rollMetadataDraft) ?? "" },
            set: { newValue in
                let value: String? = newValue.isEmpty ? nil : newValue
                applyRollMetadata { apply($0, value) }
            }
        )
    }

    private var rollMetadataCameraBinding: Binding<String> {
        rollMetadataTextBinding(get: { $0.camera }, apply: { $0.with(camera: $1) })
    }
    private var rollMetadataLensBinding: Binding<String> {
        rollMetadataTextBinding(get: { $0.lens }, apply: { $0.with(lens: $1) })
    }
    private var rollMetadataFilmStockBinding: Binding<String> {
        rollMetadataTextBinding(get: { $0.filmStock }, apply: { $0.with(filmStock: $1) })
    }
    private var rollMetadataLocationBinding: Binding<String> {
        rollMetadataTextBinding(get: { $0.location }, apply: { $0.with(location: $1) })
    }
    private var rollMetadataPhotographerBinding: Binding<String> {
        rollMetadataTextBinding(get: { $0.photographer }, apply: { $0.with(photographer: $1) })
    }
    private var rollMetadataCopyrightBinding: Binding<String> {
        rollMetadataTextBinding(get: { $0.copyright }, apply: { $0.with(copyright: $1) })
    }
    private var rollMetadataRollIdBinding: Binding<String> {
        rollMetadataTextBinding(get: { $0.rollId }, apply: { $0.with(rollId: $1) })
    }
    private var rollMetadataNotesBinding: Binding<String> {
        rollMetadataTextBinding(get: { $0.notes }, apply: { $0.with(notes: $1) })
    }

    /// Comma-separated free text rather than a dedicated chip editor (kept
    /// deliberately simple, per this plan's own scope decision) — splits and
    /// trims on `,`, dropping empty entries so trailing/duplicate commas
    /// never produce blank keyword entries. Routed through
    /// `applyRollMetadata` for the same reason every other roll-metadata
    /// binding in this file is (see that function's doc comment) — this row
    /// shared the identical revert-on-focus-change bug before that fix.
    private var rollMetadataKeywordsBinding: Binding<String> {
        Binding(
            get: { sessionModel.rollMetadataDraft.keywords.joined(separator: ", ") },
            set: { newValue in
                let keywords = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                applyRollMetadata { $0.with(keywords: keywords) }
            }
        )
    }

    /// Defaults the picker's displayed selection to the roll's already-
    /// configured film process (never a fixed hardcoded case) whenever no
    /// metadata-specific process has been chosen yet — mirrors this file's
    /// own `sessionModel.loadedCarrier ?? .roll36` fallback-for-display
    /// precedent above; this is a display default only, and is never written
    /// back unless the user actually interacts with the picker.
    private var rollMetadataProcessBinding: Binding<FilmProcess> {
        Binding(
            get: { sessionModel.rollMetadataDraft.process ?? sessionModel.scanFilmProcess },
            set: { newValue in
                applyRollMetadata { $0.with(process: newValue) }
                sessionModel.applyCustomFilmProcess(newValue)
            }
        )
    }

    /// Fixed common-ISO set, plus the current custom value spliced in and
    /// sorted whenever it isn't already one of the fixed options — so a
    /// project opened with an unusual ISO already recorded never silently
    /// snaps to the nearest fixed value.
    private var rollMetadataIsoOptions: [Int] {
        let base = [100, 200, 400, 800, 1_600, 3_200]
        guard let current = sessionModel.rollMetadataDraft.iso, !base.contains(current) else { return base }
        return (base + [current]).sorted()
    }

    private var rollMetadataIsoBinding: Binding<Int> {
        Binding(
            get: { sessionModel.rollMetadataDraft.iso ?? 400 },
            set: { newValue in
                applyRollMetadata { $0.with(iso: newValue) }
            }
        )
    }

    private var rollMetadataDateBinding: Binding<PartialDate?> {
        Binding(
            get: { sessionModel.rollMetadataDraft.date },
            set: { newValue in
                applyRollMetadata { $0.with(date: newValue) }
            }
        )
    }

    /// Honest, at-a-glance ExifTool status — "Checking…" only appears for the
    /// brief window before the first `detectExifTool()` round trip lands;
    /// afterward this always states plainly whether ExifTool is usable
    /// (never a silent/blank state), matching META-03's own requirement.
    private var exifToolStatusSummary: String {
        guard let detection = sessionModel.exifToolDetection else { return "Checking…" }
        guard detection.available else { return "Not found — install ExifTool" }
        return detection.version.map { "\($0) detected" } ?? "Detected"
    }

}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(
            content: { content },
            label: { SectionEyebrow(title: title) }
        )
        .disclosureGroupStyle(LargeTargetDisclosureStyle())
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.scanStudioDivider).frame(height: 1)
        }
    }
}

/// Keeps the disclosure arrow visually small while making the entire section
/// header a minimum 44-point-tall click target.
struct LargeTargetDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Toggles this section")

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

struct InspectorRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(Color.scanStudioRowLabel)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(Color.scanStudioPrimaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }
}

struct InspectorSettingRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    init(label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .foregroundStyle(Color.scanStudioRowLabel)
            Spacer(minLength: 8)
            control
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 142, alignment: .trailing)
        }
        .font(.system(size: 13))
        .frame(minHeight: 32)
        .contentShape(Rectangle())
    }
}

struct InspectorToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    init(label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .foregroundStyle(Color.scanStudioSecondaryText)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11))
        .frame(minHeight: 32)
        .contentShape(Rectangle())
    }
}

private struct CompactInspectorToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.scanStudioDivider, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct InspectorTextFieldRow: View {
    let label: String
    @Binding var text: String

    init(label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
        .frame(minHeight: 44)
    }
}

/// Exact/Month/Year/Unknown precision editor for a `PartialDate?` — reused by
/// both `BatchInspectorView`'s roll-wide Metadata section and
/// `FrameDetailWorkspaceView`'s per-frame Metadata override section (kept
/// `internal`, like the `Inspector*` row/section types above, specifically so
/// that file can reuse it without duplicating this control).
///
/// Never fabricates a value the user didn't provide: `nil` and `.unknown`
/// both display as "Unknown" with no further controls; switching to a more
/// specific precision never silently writes a real value until the user
/// supplies the missing component(s) themselves (never today's date, never a
/// guessed year) — see `pendingPrecision` below for how the segmented
/// selection can visually reflect the user's tap before enough information
/// exists to actually construct a `PartialDate`.
struct PartialDateEditor: View {
    @Binding var date: PartialDate?

    enum Precision: String, CaseIterable, Identifiable {
        case exact = "Exact"
        case month = "Month"
        case year = "Year"
        case unknown = "Unknown"
        var id: String { rawValue }
    }

    /// Overrides the derived-from-`date` display only while the user has
    /// tapped a more specific precision than `date` currently carries and
    /// hasn't yet supplied enough information to commit a real value (e.g.
    /// tapped "Exact" but hasn't picked a day, or "Year" with no prior year
    /// known). `nil` whenever `date` alone already reflects the selected
    /// precision, which is true immediately after any real commit — so this
    /// never drifts far from the authoritative `date` binding, and a `date`
    /// that changes out from under this view (a revert, a different
    /// frame/project's draft) always wins over a stale pending guess.
    @State private var pendingPrecision: Precision?
    @State private var draftYear: String = ""
    @State private var draftMonth: Int = 1

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let monthSymbols = DateFormatter().shortMonthSymbols ?? (1...12).map { "\($0)" }

    private var derivedPrecision: Precision {
        switch date {
        case .exact: .exact
        case .monthOnly: .month
        case .yearOnly: .year
        case .unknown, nil: .unknown
        }
    }

    private var precision: Precision { pendingPrecision ?? derivedPrecision }

    private var currentYear: Int? {
        switch date {
        case .exact(let iso): Int(iso.prefix(4))
        case .monthOnly(let year, _): year
        case .yearOnly(let year): year
        default: nil
        }
    }

    private var currentMonth: Int? {
        switch date {
        case .exact(let iso):
            let components = iso.split(separator: "-")
            return components.count > 1 ? Int(components[1]) : nil
        case .monthOnly(_, let month):
            return month
        default:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Date precision", selection: precisionBinding) {
                ForEach(Precision.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch precision {
            case .exact: exactEditor
            case .month: monthEditor
            case .year: yearEditor
            case .unknown: EmptyView()
            }
        }
        .onAppear { resyncDrafts() }
        .onChange(of: date) { resyncDrafts() }
    }

    private func resyncDrafts() {
        draftYear = currentYear.map(String.init) ?? ""
        draftMonth = currentMonth ?? 1
    }

    private var precisionBinding: Binding<Precision> {
        Binding(
            get: { precision },
            set: { newValue in
                switch newValue {
                case .unknown:
                    pendingPrecision = nil
                    date = .unknown
                case .month:
                    // A year already known (even from a lesser- or
                    // greater-precision existing value) is carried straight
                    // over — never re-guessed, never dropped — with month
                    // defaulting to January only when no month is already
                    // known either. No year known at all: defer (below)
                    // rather than inventing one.
                    if let year = currentYear {
                        pendingPrecision = nil
                        date = .monthOnly(year: year, month: currentMonth ?? 1)
                    } else {
                        pendingPrecision = .month
                        resyncDrafts()
                    }
                case .year:
                    if let year = currentYear {
                        pendingPrecision = nil
                        date = .yearOnly(year: year)
                    } else {
                        pendingPrecision = .year
                        resyncDrafts()
                    }
                case .exact:
                    // Always defers, even when year/month are already known:
                    // "Exact" implies a specific day, which is never
                    // inferable from a lesser precision — the user must
                    // pick one via the DatePicker itself (see
                    // `exactDateBinding`'s own doc comment).
                    pendingPrecision = .exact
                    resyncDrafts()
                }
            }
        )
    }

    private var exactEditor: some View {
        DatePicker("Date", selection: exactDateBinding, displayedComponents: .date)
            .labelsHidden()
            .controlSize(.small)
            .datePickerStyle(.compact)
    }

    /// `get` returns today's date purely as the picker widget's own neutral
    /// starting appearance when no exact date is stored yet — displaying it
    /// is not claiming it. Nothing is written to `date` until `set` actually
    /// fires, which SwiftUI only does when the user interacts with the
    /// control itself, satisfying "select Exact and THEN pick a real date"
    /// as two genuinely separate deliberate actions.
    private var exactDateBinding: Binding<Date> {
        Binding(
            get: {
                if case .exact(let iso) = date, let parsed = Self.isoFormatter.date(from: iso) {
                    return parsed
                }
                return Date()
            },
            set: { newValue in
                pendingPrecision = nil
                date = .exact(date: Self.isoFormatter.string(from: newValue))
            }
        )
    }

    private var monthEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("YYYY", text: yearTextBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 68)
            Picker("Month", selection: monthSelectionBinding) {
                ForEach(1...12, id: \.self) { month in
                    Text(Self.monthSymbols[month - 1]).tag(month)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var yearEditor: some View {
        TextField("YYYY", text: yearTextBinding)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .frame(width: 68)
    }

    /// Digits-only, capped at 4 characters, and — critically — never commits
    /// a `PartialDate` until a full 4-digit year actually exists. A partial
    /// typed year (e.g. "2" or "20") stays purely local (`draftYear`) rather
    /// than being pushed into `date` as e.g. year 2 or year 20, which would
    /// misrepresent an in-progress keystroke as a deliberately chosen year.
    private var yearTextBinding: Binding<String> {
        Binding(
            get: { draftYear },
            set: { newValue in
                draftYear = String(newValue.filter(\.isNumber).prefix(4))
                guard draftYear.count == 4, let year = Int(draftYear) else { return }
                switch precision {
                case .month: date = .monthOnly(year: year, month: draftMonth)
                case .year: date = .yearOnly(year: year)
                default: break
                }
                pendingPrecision = nil
            }
        )
    }

    private var monthSelectionBinding: Binding<Int> {
        Binding(
            get: { draftMonth },
            set: { newValue in
                draftMonth = newValue
                guard draftYear.count == 4, let year = Int(draftYear) else { return }
                date = .monthOnly(year: year, month: newValue)
                pendingPrecision = nil
            }
        )
    }
}

// MARK: - Metadata draft mutation helper
//
// Mirrors `FrameDetailWorkspaceView.swift`'s `CaptureRecipe.with(...)`-family
// copy-with-only-named-fields-changed shape, adapted for the fact every
// `MetadataSet` field is already `Optional` itself — a single level of
// Optional can't distinguish "this call didn't touch the field" (keep the
// current value) from "this call explicitly cleared it to nil" (typing then
// deleting free text must send a genuinely absent field on the wire, not an
// empty-string one; see `rollMetadataTextBinding`'s own doc comment above for
// why that distinction matters to the engine's ExifTool argument builder).
// Each parameter below is therefore doubly-optional: omitting it (the
// `= nil` default) keeps the current value; passing a *typed* `T?` variable
// — even one whose runtime value is itself `nil` — always overwrites,
// clearing the field on an inner `nil`. Every call site passes a typed local
// (`String?`, `PartialDate?`, ...), never the bare `nil` literal, which is
// what makes the "clear" branch reachable at all (a bare `nil` literal would
// resolve to the outer, omitted state instead).
//
// Deliberately `internal`, not `private`: `FrameDetailWorkspaceView.swift`'s
// own per-frame Metadata override section (Plan 06-05 Task 2) needs this
// same copy-constructor for its `metadataDraft?.with(field:)` bindings, and a
// `private extension` is file-scoped in Swift — invisible outside this file.
// The rest of this file's own `Inspector*`/`PartialDateEditor` types already
// use plain (implicitly internal) access for exactly this cross-file-reuse
// reason.
extension MetadataSet {
    func with(
        camera: String?? = nil,
        lens: String?? = nil,
        filmStock: String?? = nil,
        process: FilmProcess?? = nil,
        iso: Int?? = nil,
        date: PartialDate?? = nil,
        location: String?? = nil,
        photographer: String?? = nil,
        copyright: String?? = nil,
        rollId: String?? = nil,
        frameNumber: Int?? = nil,
        notes: String?? = nil,
        keywords: [String]? = nil
    ) -> MetadataSet {
        MetadataSet(
            camera: camera ?? self.camera,
            lens: lens ?? self.lens,
            filmStock: filmStock ?? self.filmStock,
            process: process ?? self.process,
            iso: iso ?? self.iso,
            date: date ?? self.date,
            location: location ?? self.location,
            photographer: photographer ?? self.photographer,
            copyright: copyright ?? self.copyright,
            rollId: rollId ?? self.rollId,
            frameNumber: frameNumber ?? self.frameNumber,
            notes: notes ?? self.notes,
            keywords: keywords ?? self.keywords
        )
    }
}

private struct RealHistogramView: View {
    let bins: RGBHistogram

    var body: some View {
        Canvas { context, size in
            let maxCount = max(1, bins.red.max() ?? 0, bins.green.max() ?? 0, bins.blue.max() ?? 0)
            let binWidth = size.width / CGFloat(HistogramMath.binCount)
            for channel in [(Color.red, bins.red), (Color.green, bins.green), (Color.blue, bins.blue)] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, count) in channel.1.enumerated() {
                    let level = CGFloat(count) / CGFloat(maxCount)
                    let x = CGFloat(index) * binWidth
                    path.addLine(to: CGPoint(x: x, y: size.height * (1 - level)))
                    path.addLine(to: CGPoint(x: x + binWidth, y: size.height * (1 - level)))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(channel.0.opacity(0.24)))
                context.stroke(path, with: .color(channel.0.opacity(0.72)), lineWidth: 1)
            }
        }
        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.scanStudioDivider))
    }
}

enum HistogramSampler {
    static func bins(from image: NSImage) -> RGBHistogram? {
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
        var red = [UInt8]()
        var green = [UInt8]()
        var blue = [UInt8]()
        red.reserveCapacity(pixelCount)
        green.reserveCapacity(pixelCount)
        blue.reserveCapacity(pixelCount)
        for pixel in 0..<pixelCount {
            let offset = pixel * bytesPerPixel
            red.append(buffer[offset])
            green.append(buffer[offset + 1])
            blue.append(buffer[offset + 2])
        }

        return RGBHistogram(
            red: HistogramMath.bins(for: red),
            green: HistogramMath.bins(for: green),
            blue: HistogramMath.bins(for: blue)
        )
    }
}

private struct HistogramView: View {
    let seed: Int

    var body: some View {
        Canvas { context, size in
            let colors: [Color] = [.red, .green, .blue]
            for channel in 0..<3 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for point in 0...32 {
                    let x = size.width * CGFloat(point) / 32
                    let wave = sin(Double(point + seed * (channel + 1)) * 0.47)
                    let ridge = sin(Double(point * (channel + 2) + seed) * 0.19)
                    let level = 0.18 + abs(wave * 0.48 + ridge * 0.20)
                    path.addLine(to: CGPoint(x: x, y: size.height * (1 - level)))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(colors[channel].opacity(0.24)))
                context.stroke(path, with: .color(colors[channel].opacity(0.72)), lineWidth: 1)
            }
        }
        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.scanStudioDivider))
    }
}
