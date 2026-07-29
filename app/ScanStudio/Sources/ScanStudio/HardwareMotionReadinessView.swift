import ScanStudioKit
import SwiftUI

/// Read-only presentation of the bridge's current movement readiness.
/// The only action here re-reads `scanner.status`; it never enables movement.
struct HardwareMotionReadinessView: View {
    @Environment(SessionModel.self) private var sessionModel
    var compact = false

    var body: some View {
        if readiness != .notApplicable {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: readiness == .ready
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill")
                    .foregroundStyle(readiness == .ready
                        ? Color.scanStudioGreen
                        : Color.scanStudioAmber)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.system(size: compact ? 10 : 12, weight: .semibold))

                    HStack(spacing: 4) {
                        Text("Film:")
                            .foregroundStyle(Color.scanStudioSecondaryText)
                        Text(filmStatus.title)
                            .fontWeight(.semibold)
                            .foregroundStyle(filmStatusColor)
                    }
                    .font(.system(size: compact ? 9 : 11))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Film status: \(filmStatus.title)")

                    if !compact || readiness != .ready {
                        Text(presentation.guidance)
                            .font(.system(size: compact ? 9 : 11))
                            .foregroundStyle(Color.scanStudioSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !compact {
                    Button(readiness.statusRefreshTitle) {
                        Task { await sessionModel.refreshScannerStatus() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sessionModel.isRefreshingScannerStatus)
                    .overlay {
                        if sessionModel.isRefreshingScannerStatus {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .accessibilityHint("Refreshes scanner and film status without feeding, advancing, or ejecting film.")
                }
            }
            .padding(.horizontal, compact ? 0 : 12)
            .padding(.vertical, compact ? 0 : 10)
            .background(
                compact ? Color.clear : Color.black.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .accessibilityElement(children: .contain)
        }
    }

    private var readiness: HardwareMotionReadiness {
        sessionModel.hardwareMotionReadiness
    }

    private var filmStatus: HardwareFilmStatus {
        HardwareFilmStatus.evaluate(
            isConnected: sessionModel.status?.connected == true,
            isRealDevice: sessionModel.device?.kind == "real",
            mediaLoaded: sessionModel.status?.mediaLoaded,
            filmPresent: sessionModel.status?.filmPresent
        )
    }

    private var presentation: ScannerReadinessPresentation {
        ScannerReadinessPresentation.evaluate(
            hardwareReadiness: readiness,
            filmStatus: filmStatus,
            hasPreviewedMedia: sessionModel.status?.mediaLoaded == true,
            scanReadiness: sessionModel.scanReadiness(
                for: sessionModel.selectedFrames
            )
        )
    }

    private var filmStatusColor: Color {
        switch filmStatus {
        case .loaded: .scanStudioGreen
        case .notDetected: .scanStudioAmber
        case .unknown: .scanStudioSecondaryText
        }
    }
}
