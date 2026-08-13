import ScanStudioKit
import SwiftUI

struct ScanPanelView: View {
    @Environment(SessionModel.self) private var sessionModel
    @State private var refreshPreviewToken: PreviewIntentToken?

    private var hasMedia: Bool { sessionModel.status?.mediaLoaded == true }
    private var transportIsIdle: Bool {
        sessionModel.status?.transport == "idle" && !sessionModel.isAcquiringThumbnails
    }
    private var hasSelection: Bool { sessionModel.selectedFrameCount > 0 }
    private var scanReadiness: ScanReadinessPolicy.Decision {
        sessionModel.scanReadiness(for: sessionModel.selectedFrames)
    }
    private var resumeReadiness: ScanReadinessPolicy.Decision {
        sessionModel.scanReadiness(for: sessionModel.pendingFrames)
    }

    private var isRealDevice: Bool { sessionModel.device?.kind == "real" }

    /// Which live scan telemetry this device may honestly display — see
    /// `ScanTelemetryHonesty` (ScanStudioKit) for the engine-side root cause
    /// (real_backend.rs hardcodes frame_percent/eta_seconds/pass for a real
    /// LS-5000; only the simulator computes them genuinely).
    private var telemetryHonesty: ScanTelemetryHonesty { .init(isRealDevice: isRealDevice) }

    /// Whether a preview pass can be started right now.
    ///
    /// The simulator reports `mediaLoaded` from its own load-media call, so
    /// `hasMedia` is the right gate there. A real backend has no load-media
    /// call at all: it reports `mediaLoaded` from `preview_established`
    /// (real_backend.rs), which only becomes true *after* a preview runs.
    /// Gating the preview on `hasMedia` therefore deadlocks real hardware —
    /// the one action that can detect media is disabled until media is
    /// detected. The center preview gate owns the first real preview before
    /// a project exists; this footer only refreshes previews for a saved roll.
    private var canAcquireThumbnails: Bool {
        guard sessionModel.project != nil else { return false }
        guard transportIsIdle else { return false }
        guard sessionModel.hardwareMotionReadiness.allowsMotion else {
            return false
        }
        if hasMedia { return true }
        return sessionModel.device?.kind == "real"
    }

    /// A genuinely partial roll — at least one frame already has a
    /// receipt, and at least one is still pending. This is the only signal
    /// `scanSummary?.stopped` can't see at all: it's `nil` on a freshly
    /// reopened project even though the manifest already proves partial
    /// completion (PERSIST-02).
    ///
    /// Deliberately gated through `ResumeBatchPolicy` (completed-vs-pending,
    /// both sourced from the project's own manifest) rather than comparing
    /// `pendingFrameCount` against `status?.frameCount` — that comparison
    /// is exactly what made a brand-new, zero-receipt project misread as
    /// "Resume Batch (36 remaining)" when a real roll's preview detected
    /// more physical frames (39) than the project's own nominal count
    /// (36), verified live 2026-07-25. See `ResumeBatchPolicy`'s own doc
    /// comment (SessionModel.swift) for the full root cause.
    private var showResumeBatch: Bool {
        ResumeBatchPolicy.shouldShowResumeBatch(
            completedCount: sessionModel.completedFrameCount,
            pendingCount: sessionModel.pendingFrameCount
        )
    }

    var body: some View {
        Group {
            if sessionModel.isJobActive {
                activeActions
            } else if sessionModel.isAcquiringThumbnails {
                carrierLoadingActions
            } else {
                setupActions
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 72)
        .background(Color.scanStudioSidebar)
        .sheet(item: $refreshPreviewToken) { token in
            SavedProjectRefreshSheet(session: sessionModel, intentToken: token)
        }
        // Keeps `pendingFrameCount` current without a manual refresh action —
        // re-runs whenever `hasMedia` flips (a carrier load/eject), not just
        // once on first appearance.
        .task(id: "\(hasMedia)-\(sessionModel.projectDirectory ?? "no-project")") {
            if hasMedia, sessionModel.project != nil { await sessionModel.refreshPendingFrames() }
        }
    }

    private var setupActions: some View {
        HStack(spacing: 14) {
            Button {
                sessionModel.clearFrameSelection()
            } label: {
                Label("Clear Selection", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(!hasSelection)

            Text(selectionSummary)
                .font(.system(size: 12))
                .foregroundStyle(Color.scanStudioSecondaryText)

            if let summary = sessionModel.scanSummary {
                Label(
                    batchSummary(summary),
                    systemImage: summary.stopped ? "pause.circle.fill" : (summary.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                )
                .font(.system(size: 11))
                .foregroundStyle(summary.stopped ? Color.scanStudioAmber : (summary.failed.isEmpty ? Color.scanStudioCyan : Color.scanStudioRed))
                .help(batchSummaryHelp(summary))
            }

            Spacer()

            if isRealDevice {
                HardwareMotionReadinessView(compact: true)
                    .frame(maxWidth: 280, alignment: .trailing)
            }

            if ScanPanelVisibilityPolicy.showsFooterPreviewAction(hasThumbnails: !sessionModel.thumbnails.isEmpty) {
                Button {
                    refreshPreviewToken = PreviewIntentToken()
                } label: {
                    Label(previewButtonLabel, systemImage: "photo.stack")
                }
                .buttonStyle(.bordered)
                .disabled(!canAcquireThumbnails)
            }

            if showResumeBatch {
                Button {
                    Task { await sessionModel.resumeBatch() }
                } label: {
                    Label("Resume Batch (\(sessionModel.pendingFrameCount) remaining)", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.scanStudioAmber)
                .disabled(!resumeReadiness.isReady)
                .help(resumeReadiness.reason ?? "Resume the pending frames")
                if let reason = resumeReadiness.reason {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 170, alignment: .leading)
                }
            }

            Button {
                Task { await sessionModel.startMockScan() }
            } label: {
                Label(scanButtonLabel, systemImage: "scanner.fill")
                    .frame(minWidth: 132)
            }
            .buttonStyle(.borderedProminent)
            .tint(.scanStudioAmber)
            .foregroundStyle(.black)
            .disabled(!scanReadiness.isReady)
            .help(scanReadiness.reason ?? "Scan the selected frames")
            .keyboardShortcut(.return, modifiers: .command)

            if let reason = scanReadiness.reason {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 170, alignment: .leading)
            }
        }
    }

    private var activeActions: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(frameAndPassLabel)
                    .font(.system(size: 12, weight: .medium))
                if telemetryHonesty.hasDeterminateBatchProgress {
                    ProgressView(
                        value: sessionModel.progress?.jobPercent ?? 0,
                        total: 100
                    )
                    .tint(.scanStudioAmber)
                    .frame(width: 260)
                } else {
                    ProgressView()
                        .tint(.scanStudioAmber)
                        .frame(width: 260)
                }
            }

            // Relocated from the removed `ActiveScanWorkspaceView`
            // (2026-07-26 — see ContentView.swift's redesign comment):
            // `jobStateLabel`/`etaLabel` had no other home. Every other
            // Capture Monitor readout already had a live duplicate
            // elsewhere: this bar's simulator-only "Frame N of M" above,
            // `SessionSidebarView`'s activity card (elapsed, completed/
            // remaining, last frame), and `BatchInspectorView
            // .activeInspector`'s "Pass" row and per-outcome counts.
            VStack(alignment: .leading, spacing: 2) {
                Text(jobStateLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.scanStudioAmber)
                Text(receiptsAndEtaLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }

            Spacer()

            Button {
                Task { await sessionModel.stopAfterCurrentFrame() }
            } label: {
                Label("Pause after frame", systemImage: "pause.circle")
            }
            .buttonStyle(.bordered)
            .disabled(sessionModel.jobState == .stoppingAfterCurrentFrame || sessionModel.jobState == .stoppingImmediately)

            Button {
                Task { await sessionModel.skipCurrentFrame() }
            } label: {
                Label("Skip Frame", systemImage: "forward.frame")
            }
            .buttonStyle(.bordered)
            .disabled(sessionModel.jobState == .stoppingAfterCurrentFrame || sessionModel.jobState == .stoppingImmediately || sessionModel.device?.kind == "real")
            .help(skipFrameHelpText)

            Button(role: .destructive) {
                Task { await sessionModel.stopImmediately() }
            } label: {
                Label("Stop Scan", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.bordered)
            .tint(.scanStudioRed)
            .disabled(sessionModel.jobState == .stoppingImmediately)
        }
    }

    private var carrierLoadingActions: some View {
        let knownFrameCount = sessionModel.status?.frameCount.flatMap { $0 > 0 ? $0 : nil }
        let frameCount = knownFrameCount ?? max(sessionModel.thumbnailCount, 1)
        let loadedCount = min(sessionModel.thumbnailCount, frameCount)
        let currentFrame = min(loadedCount + 1, frameCount)

        return HStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.scanStudioAmber)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(knownFrameCount == nil
                        ? "Loading \(sessionModel.carrierDisplayName.lowercased()) · detecting frame count"
                        : "Loading \(sessionModel.carrierDisplayName.lowercased()) · frame \(currentFrame) of \(frameCount)")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(loadedCount) ready")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }
                if let knownFrameCount {
                    ProgressView(value: Double(loadedCount), total: Double(knownFrameCount))
                        .tint(.scanStudioAmber)
                } else {
                    ProgressView()
                        .tint(.scanStudioAmber)
                }
            }
            .frame(maxWidth: 520)

            Spacer()

            Label("Keep the film holder inserted", systemImage: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.scanStudioSecondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(knownFrameCount == nil
            ? "Loading \(sessionModel.carrierDisplayName), \(loadedCount) frames found so far; total not established"
            : "Loading \(sessionModel.carrierDisplayName), \(loadedCount) of \(frameCount) frames ready")
    }

    private var selectionSummary: String {
        guard hasMedia else { return "No media loaded" }
        if let frameCount = sessionModel.status?.frameCount {
            return "\(sessionModel.selectedFrameCount) of \(frameCount) selected"
        }
        return "\(sessionModel.selectedFrameCount) selected · frame count not established"
    }

    private var scanButtonLabel: String {
        let count = sessionModel.selectedFrameCount
        let verb = sessionModel.scanSummary?.stopped == true ? "Resume" : "Scan"
        return "\(verb) \(count) frame\(count == 1 ? "" : "s")"
    }

    private var previewButtonLabel: String {
        "Refresh previews"
    }

    private func batchSummary(_ summary: ScanSummary) -> String {
        if summary.stopped {
            return "Paused · \(sessionModel.selectedFrameCount) remaining"
        }
        return "Last batch: \(summary.completed.count) completed"
    }

    /// Issue #76/#24: "Last batch: 0 completed" alone hid the driver's own
    /// refusal reason (e.g. the unattended-binding confidence gate failing
    /// every frame before any capture). This footer label has no room for a
    /// second line, so the reason surfaces as a tooltip instead --
    /// `BatchInspectorView.batchResultSummary` shows the same reason inline
    /// for the fuller Batch inspector. The reason is appended after the
    /// visible label text, never substituted for it: a reason no curated
    /// matcher recognizes still gets its generic guidance, and the count
    /// stays visible either way.
    private func batchSummaryHelp(_ summary: ScanSummary) -> String {
        guard summary.completed.isEmpty,
              let error = summary.failed.lazy.compactMap({ sessionModel.frameErrors[$0] }).first(where: {
                  $0.code != FrameFailureLabel.manualReviewCode
              })
        else {
            return batchSummary(summary)
        }
        let guidance = ErrorPresentationPolicy.make(
            lastErrorMessage: "\(error.code): \(error.message)"
        ).guidance
        return "\(batchSummary(summary)) — \(guidance)"
    }

    private var skipFrameHelpText: String {
        if sessionModel.device?.kind == "real" {
            return "Skip Frame is not available on real hardware: the in-flight frame always finishes. To leave an upcoming frame unscanned, deselect it in the contact sheet and scan the remaining frames."
        }
        return "Skip the currently scanning frame"
    }

    /// Relocated verbatim from the removed `ActiveScanWorkspaceView`
    /// (2026-07-26 — see ContentView.swift): the one Capture Monitor
    /// readout that distinguished "queued," "actively scanning," "pausing
    /// after this frame," and "stopping" — every other surface that shows
    /// job state (`SessionSidebarView.scannerStatusTitle`) only ever says
    /// the coarser "Scanning in progress."
    private var jobStateLabel: String {
        guard let state = sessionModel.jobState else { return "Preparing scan" }
        switch state {
        case .queued: return "Preparing scan"
        case .scanning: return "Capture in progress"
        case .stoppingAfterCurrentFrame: return "Pausing after this frame"
        case .stoppingImmediately: return "Stopping batch"
        case .completed: return "Batch complete"
        case .failed: return "Batch failed"
        case .stopped: return "Batch stopped"
        }
    }

    /// Relocated verbatim from the removed `ActiveScanWorkspaceView` —
    /// `etaSeconds` had no other display anywhere in the app. Only surfaced
    /// when `telemetryHonesty.showsLiveEta` (simulator only): a real backend
    /// hardcodes `eta_seconds` to 0.0 — its own honest "unknown," never a real
    /// estimate — which would otherwise render as a fabricated "ETA 0.0s".
    private var etaLabel: String {
        guard let seconds = sessionModel.progress?.etaSeconds else { return "Estimating…" }
        return String(format: "ETA %.1fs", seconds)
    }

    /// Real hardware cannot measure a current frame or attempted-batch total:
    /// its progress burst arrives before motion and the bridge may later
    /// shrink the attempted subset. Simulation retains its measured position.
    private var frameAndPassLabel: String {
        guard telemetryHonesty.hasMeasuredCurrentFramePosition else {
            return "Capture in progress"
        }
        let frame = "Frame \(sessionModel.progress?.frameOrdinal ?? 1) of \(sessionModel.progress?.totalFrames ?? sessionModel.selectedFrameCount)"
        guard telemetryHonesty.showsLivePassCount else { return frame }
        return "\(frame) · Pass \(sessionModel.progress?.pass ?? 1) of \(sessionModel.progress?.totalPasses ?? 2)"
    }

    /// Completed-frame count (backed by receipts, but expressed in user
    /// language) plus " · ETA …" only when honest (simulator only — see
    /// `etaLabel`/`telemetryHonesty`).
    private var receiptsAndEtaLabel: String {
        let framesScanned = ScanTelemetryHonesty.scannedFramesLabel(
            sessionModel.receiptCount
        )
        guard telemetryHonesty.showsLiveEta else { return framesScanned }
        return "\(framesScanned) · \(etaLabel)"
    }
}

/// A presentation-scoped confirmation is the authorization boundary for a
/// saved project's additional hardware traversal. Reopening the sheet is a
/// genuinely new explicit action and therefore receives a new token; replaying
/// this sheet's already-consumed confirmation keeps the same token and is
/// rejected by `SessionModel`.
private struct SavedProjectRefreshSheet: View {
    @Bindable var session: SessionModel
    let intentToken: PreviewIntentToken
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Refresh previews?")
                .font(.headline)
            Text("This moves the film through the scanner again and replaces the current preview images.")
                .font(.footnote)
                .foregroundStyle(Color.scanStudioSecondaryText)
            HardwareMotionReadinessView()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Refresh Previews") {
                    let intent = PreviewIntent.refreshSavedProject(token: intentToken)
                    Task {
                        _ = await session.requestPreview(intent)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.hardwareMotionReadiness.allowsMotion)
                .help(session.hardwareMotionReadiness.allowsMotion
                    ? "Refresh previews"
                    : session.hardwareMotionReadiness.guidance)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
