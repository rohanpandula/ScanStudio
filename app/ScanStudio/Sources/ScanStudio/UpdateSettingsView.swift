// Settings scene for the in-app update flow (01-05). Thin SwiftUI: renders
// `UpdateFlowModel` state and forwards button taps to its async actions. All
// policy lives in the model (install gated on `jobActive`, up-to-date vs error
// are distinct states, no auto-relaunch). The scene lives in the executable
// target so network/app concerns stay out of the ScanStudioKit library.

import AppKit
import ScanStudioKit
import SwiftUI

struct UpdateSettingsView: View {
    @Bindable var model: UpdateFlowModel

    var body: some View {
        Form {
            Section {
                header
            }

            Section("Release channel") {
                Picker("Channel", selection: $model.channel) {
                    Text("Prerelease").tag(UpdateChannel.alpha)
                    Text("Stable").tag(UpdateChannel.stable)
                }
                Text("Prerelease installs the newest alpha, beta, or release candidate. Stable only installs full releases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates at launch", isOn: $model.launchCheckEnabled)

                Button("Check for Updates") {
                    Task { await model.checkNow() }
                }
                .disabled(model.checkState == .checking)

                stateContent

                if let destination = model.pendingInstallDestination {
                    Text("Install target: \(destination)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if destination != "/Applications" {
                        Text("This installation uses a user-folder target instead of /Applications.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .updateAvailable = model.checkState, model.jobActive {
                    Text("Install is paused while a scan or preview is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.pendingInstallURL != nil {
                    Text("Restart Scan Studio to finish the update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Roll Back to Previous Version") {
                    Task { await model.rollback() }
                }
                .disabled(!model.canRollback)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan Studio")
                    .font(.title3.weight(.semibold))
                Text(installedVersionLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var installedVersionLine: String {
        // Unstamped dev/source builds show "Development" and are treated as
        // always up to date (T-01-05-02) -- never an install target.
        if let stamp = Bundle.main.infoDictionary?["ScanStudioRelease"] as? String,
           !stamp.isEmpty {
            return "Installed version \(stamp)"
        }
        return "Development build"
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.checkState {
        case .idle:
            Text("No update check has run yet.")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView("Checking for updates\u{2026}")
        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle")
        case .updateAvailable(let candidate):
            // Made visually unmissable (field feedback 2026-08-05: a first
            // live update read as "nothing happened" when this was just a
            // plain Text row with a plain-style button). Same amber-card
            // idiom WorkspaceErrorBanner uses for red errors, and the same
            // prominent-tinted-button idiom already used for primary actions
            // elsewhere (Save & Scan, Acquire Previews, device connect).
            VStack(alignment: .leading, spacing: 10) {
                Label("Update available: \(candidate.version.raw)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.scanStudioAmber)

                if model.pendingInstallURL != nil {
                    // The prominent next action once install() has already
                    // swapped the bundle on disk (feat/launch-update-offer,
                    // field fix: this used to be an inert Label).
                    Button {
                        model.relaunchToFinishUpdate()
                    } label: {
                        Label("Relaunch Now", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.scanStudioAmber)
                    .foregroundStyle(.black)
                    .disabled(model.jobActive)
                    .help(model.jobActive
                        ? "Relaunch is disabled while a scan is active."
                        : "Quit and reopen Scan Studio to finish the update.")
                } else if let progress = model.installProgress {
                    ProgressView(
                        value: progress,
                        label: { Text("Installing\u{2026}") }
                    )
                } else {
                    Button("Install Update") {
                        Task { await model.install() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.scanStudioAmber)
                    .foregroundStyle(.black)
                    .disabled(model.jobActive)
                    .help(model.jobActive
                        ? "Install is disabled while a scan is active."
                        : "Download, verify, and install this update.")
                }
            }
            .padding(12)
            .background(
                Color.scanStudioAmber.opacity(0.14),
                in: RoundedRectangle(cornerRadius: ScanStudioMetrics.cardCornerRadius)
            )
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
