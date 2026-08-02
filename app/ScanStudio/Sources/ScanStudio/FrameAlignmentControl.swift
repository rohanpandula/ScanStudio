import ScanStudioKit
import SwiftUI

/// A live scanner-position control, deliberately separate from preview-only
/// zoom/pan and saved derivative rotation/mirroring. Each nudge asks the active preview
/// session for a freshly re-cropped thumbnail, so the image above this row is
/// evidence of the position that the scanner will use rather than a cosmetic
/// SwiftUI offset.
struct FrameAlignmentControl: View {
    let session: SessionModel
    let frameIndex: Int
    var compact = false

    private var offset: Int {
        session.alignmentOffset(for: frameIndex)
    }

    private var isUpdating: Bool {
        session.isAdjustingFrameAlignment(frameIndex)
    }

    private var needsRecovery: Bool {
        session.failedFrameAlignmentRestoreIndices.contains(frameIndex)
    }

    private var positionDescription: String {
        switch offset {
        case 1:
            "Image moved 1 row left"
        case let value where value > 1:
            "Image moved \(value) rows left"
        case -1:
            "Image moved 1 row right"
        case let value where value < -1:
            "Image moved \(abs(value)) rows right"
        default:
            "Original position"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan alignment")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    Text(positionDescription)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(
                            offset == 0
                                ? Color.scanStudioSecondaryText
                                : Color.scanStudioAmber
                        )
                }

                Spacer()

                if isUpdating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating preview…")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.scanStudioSecondaryText)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Offset \(offset >= 0 ? "+" : "")\(offset)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.scanStudioSecondaryText)
                        .accessibilityLabel("Scanner offset \(offset) rows")
                }
            }

            HStack(spacing: 8) {
                nudgeButton(
                    title: "Move Image Left",
                    symbol: "arrow.left.to.line",
                    delta: 1
                )

                nudgeButton(
                    title: "Move Image Right",
                    symbol: "arrow.right.to.line",
                    delta: -1
                )

                Button {
                    nudge(by: -offset)
                } label: {
                    Label("Original Position", systemImage: "dot.scope")
                        .frame(minHeight: ScanStudioMetrics.minimumInteractiveTarget)
                }
                .buttonStyle(.bordered)
                .disabled(offset == 0 || isUpdating)
                .help("Return this frame to its originally detected position")
                .accessibilityHint("Returns the scanner alignment to zero.")

                Spacer(minLength: 0)
            }

            if needsRecovery {
                HStack(alignment: .center, spacing: 10) {
                    Label(
                        "This alignment is not safely restored or saved yet.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.scanStudioAmber)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    Button {
                        Task {
                            await session.retryFrameAlignment(
                                frameIndex: frameIndex
                            )
                        }
                    } label: {
                        Label("Retry Alignment", systemImage: "arrow.clockwise")
                            .frame(
                                minHeight:
                                    ScanStudioMetrics.minimumInteractiveTarget
                            )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.scanStudioAmber)
                    .foregroundStyle(.black)
                    .disabled(isUpdating)
                    .help(
                        "Restore this frame’s chosen scanner position and save it to the current roll."
                    )
                }
                .padding(.horizontal, 10)
                .background(
                    Color.scanStudioAmber.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }

            Text(
                "Changes where the scanner reads this frame. It is not preview panning or post-scan cropping, and the film does not move now."
            )
            .font(.system(size: 10))
            .foregroundStyle(Color.scanStudioSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 12 : 14)
        .background(
            Color.scanStudioInspector.opacity(compact ? 0.62 : 0.5),
            in: RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scan alignment for frame \(frameIndex)")
    }

    private func nudgeButton(
        title: String,
        symbol: String,
        delta: Int
    ) -> some View {
        Button {
            nudge(by: delta)
        } label: {
            Label(title, systemImage: symbol)
                .frame(minHeight: ScanStudioMetrics.minimumInteractiveTarget)
        }
        .buttonStyle(.bordered)
        .disabled(
            isUpdating
                || !session.canNudgeFrameAlignment(frameIndex, by: delta)
        )
        .help(nudgeHelp(title: title, delta: delta))
        .accessibilityHint(
            "Changes the scanner position by one native preview row and updates this thumbnail."
        )
    }

    private func nudgeHelp(title: String, delta: Int) -> String {
        if isUpdating {
            return "Wait for the updated preview."
        }
        if !session.canNudgeFrameAlignment(frameIndex, by: delta) {
            return "This frame is at the scanner’s alignment limit."
        }
        return "\(title) by one scanner preview row"
    }

    private func nudge(by delta: Int) {
        guard delta != 0 else { return }
        Task {
            await session.nudgeFrameAlignment(
                frameIndex: frameIndex,
                by: delta
            )
        }
    }
}
