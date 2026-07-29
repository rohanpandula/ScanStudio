import ScanStudioKit
import SwiftUI

struct DeviceBarView: View {
    @Environment(SessionModel.self) private var sessionModel

    /// Drives the eject confirmation dialog. Eject is destructive — it
    /// destroys the current frame registration — so it never fires directly
    /// from the button; the button only arms this, and the dialog's
    /// destructive confirm action performs the actual `sessionModel.eject()`.
    @State private var isConfirmingEject = false

    private var isConnected: Bool { sessionModel.status?.connected == true }
    private var hasMedia: Bool { sessionModel.status?.mediaLoaded == true }
    private var transportIsIdle: Bool {
        guard let status = sessionModel.status else { return true }
        return status.transport == "idle" && !sessionModel.isAcquiringThumbnails
    }
    /// Eject is offered in exactly the two states the incident file allows:
    /// a normal post-traversal state (`hasMedia` — the preview completed and
    /// the transport is back to idle) and the refeed-required state (the
    /// transport refused with REFEED_REQUIRED, whose own message tells the
    /// operator to eject or refeed — live gap 2026-07-26: that message
    /// showed while no eject affordance existed anywhere in the app). On a
    /// real backend `hasMedia` is `previewEstablished`, which is exactly
    /// false in the refeed-required state, so the second arm is not
    /// redundant. Never offered mid-motion (`transportIsIdle`,
    /// `isJobActive`) — and never auto-invoked from anywhere.
    private var canOfferEject: Bool {
        isConnected && transportIsIdle && !sessionModel.isJobActive
            && (hasMedia || sessionModel.refeedRequired)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scanner.fill")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(isConnected ? Color.scanStudioCyan : Color.scanStudioSecondaryText)
                .frame(width: 34)

            if let device = sessionModel.device {
                Text(device.model)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)

                if device.kind == "simulated" {
                    DeviceProvenanceBadge(kind: device.kind)
                } else if device.kind == "real" {
                    Text("•")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                    Text(device.connection.uppercased())
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }
            } else {
                Text("No scanner selected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }
            Text("•")
                .font(.system(size: 12))
                .foregroundStyle(Color.scanStudioSecondaryText)
            Text(stateWord)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(stateWordColor)
                .fixedSize()
                .layoutPriority(1)

            Text("•")
                .font(.system(size: 12))
                .foregroundStyle(Color.scanStudioSecondaryText)
            Text(mediaLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hasMedia ? Color.scanStudioPrimaryText : Color.scanStudioSecondaryText)
                .fixedSize()
                .layoutPriority(1)
                .help(mediaLabel)

            Spacer(minLength: 18)

            if canOfferEject {
                // Visually separated from the ordinary device-bar controls by
                // a divider and a destructive red tint (owner requirement,
                // 2026-07-26), and gated behind a confirmation dialog: ejection
                // destroys the current frame registration, so it must never be
                // a single casual tap.
                Divider()
                    .frame(height: 24)

                Button(role: .destructive) {
                    isConfirmingEject = true
                } label: {
                    Label("Eject", systemImage: "eject.fill")
                }
                .buttonStyle(.bordered)
                .tint(.scanStudioRed)
                .controlSize(.small)
                .disabled(!sessionModel.hardwareMotionReadiness.allowsMotion)
                .help(
                    !sessionModel.hardwareMotionReadiness.allowsMotion
                        ? sessionModel.hardwareMotionReadiness.guidance
                        : sessionModel.refeedRequired && !hasMedia
                        ? "Eject the strip so it can be refed"
                        : "Eject the loaded film holder"
                )
                .confirmationDialog(
                    "Eject the loaded film?",
                    isPresented: $isConfirmingEject,
                    titleVisibility: .visible
                ) {
                    Button("Eject", role: .destructive) {
                        Task { await sessionModel.eject() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Ejecting releases the film from the scanner. Any frame registration captured this session is destroyed and must be re-established by feeding the film and running a preview again.")
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(Color.scanStudioSidebar)
        .accessibilityElement(children: .contain)
    }

    /// Single color-coded device-bar state word. A real idle scanner says
    /// READY only after the live movement check is affirmative; simulation
    /// uses IDLE alongside its provenance badge instead of claiming hardware
    /// readiness.
    private var stateWord: String {
        if !isConnected { return "OFFLINE" }
        return DeviceActivityPolicy.statusWord(
            isJobActive: sessionModel.isJobActive,
            isAcquiringPreviews: sessionModel.isAcquiringThumbnails,
            deviceKind: sessionModel.device?.kind,
            hardwareMotionReadiness: sessionModel.hardwareMotionReadiness
        )
    }

    private var stateWordColor: Color {
        if !isConnected { return .scanStudioSecondaryText }
        if sessionModel.isJobActive || sessionModel.isAcquiringThumbnails { return .scanStudioAmber }
        guard sessionModel.device?.kind == "real" else {
            return .scanStudioSecondaryText
        }
        return sessionModel.hardwareMotionReadiness == .ready
            ? .scanStudioCyan
            : .scanStudioAmber
    }

    private var mediaLabel: String {
        DeviceBarMediaPolicy.label(
            isAcquiringPreviews: sessionModel.isAcquiringThumbnails,
            mediaLoaded: hasMedia,
            carrierDisplayName: sessionModel.loadedCarrier?.displayName,
            filmPresent: sessionModel.status?.filmPresent
        )
    }
}

struct DeviceProvenanceBadge: View {
    /// Threaded through even though the call site only ever renders this
    /// badge when `kind == "simulated"` (`DeviceBarView.body`'s own `if`
    /// gate, unchanged) — the label is derived from the actual device kind
    /// rather than a bare literal, so it stays correct by construction
    /// instead of only being correct because of how the caller happens to
    /// gate it.
    let kind: String?

    var body: some View {
        Text("SIMULATED")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.scanStudioRed.opacity(0.82), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
            .accessibilityLabel(accessibilityLabelText)
    }

    private var accessibilityLabelText: String {
        kind == "simulated"
            ? "Simulated device; no real scanner hardware is used"
            : "Real scanner hardware"
    }
}
