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
            VStack(alignment: .leading, spacing: 8) {
                Text("Update available: \(candidate.version.raw)")
                if model.pendingInstallURL != nil {
                    Label("Restart to finish", systemImage: "arrow.triangle.2.circlepath")
                } else if let progress = model.installProgress {
                    ProgressView(
                        value: progress,
                        label: { Text("Installing\u{2026}") }
                    )
                } else {
                    Button("Install Update") {
                        Task { await model.install() }
                    }
                    .disabled(model.jobActive)
                    .help(model.jobActive
                        ? "Install is disabled while a scan is active."
                        : "Download, verify, and install this update.")
                }
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
