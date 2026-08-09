// Settings scene for the in-app update flow (01-05) and the optional local
// browser preview. Thin SwiftUI renders the two host-owned models and forwards
// actions; update policy and web-process lifecycle stay out of this view.

import AppKit
import ScanStudioKit
import SwiftUI

struct UpdateSettingsView: View {
    @Bindable var model: UpdateFlowModel
    @Bindable var webServerModel: WebServerModel
    @State private var tokenWasCopied = false

    var body: some View {
        Form {
            Section {
                header
            }

            Section("Browser preview") {
                Toggle(
                    "Run browser preview (simulator only)",
                    isOn: Binding(
                        get: { webServerModel.isEnabled },
                        set: { enabled in
                            Task { await webServerModel.setEnabled(enabled) }
                        }
                    )
                )
                .disabled(webServerModel.state == .stopping)

                Text("Starts a local browser UI with its own simulator-only engine. It does not share or control the scanner connected to the native app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                browserStatus

                VStack(alignment: .leading, spacing: 6) {
                    Text("Local address")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(webServerModel.browserURL.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Open in Browser") {
                            NSWorkspace.shared.open(webServerModel.browserURL)
                        }
                        .disabled(webServerModel.state != .running)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Access token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(webServerModel.accessToken)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Browser preview access token")
                        Spacer(minLength: 8)
                        Button(tokenWasCopied ? "Copied" : "Copy Token") {
                            copyAccessToken()
                        }
                    }
                }

                Text("Enter the token in the browser. Only browsers on this Mac can connect, and a new token is created each time Scan Studio launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 560)
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
    private var browserStatus: some View {
        switch webServerModel.state {
        case .off:
            Label("Off", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .starting:
            ProgressView("Starting browser preview…")
        case .running:
            Label("Running locally — simulator only", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.scanStudioGreen)
        case .stopping:
            ProgressView("Stopping browser preview…")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Browser preview unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.scanStudioRed)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyAccessToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(webServerModel.accessToken, forType: .string)
        tokenWasCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            tokenWasCopied = false
        }
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
