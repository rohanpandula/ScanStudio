import ScanStudioKit
import SwiftUI

struct SessionSidebarView: View {
    @Environment(SessionModel.self) private var sessionModel
    @State private var isShowingProjectLauncher = false

    private var isConnected: Bool { sessionModel.status?.connected == true }
    private var isRealDevice: Bool { sessionModel.device?.kind == "real" }
    private var hasMedia: Bool { sessionModel.status?.mediaLoaded == true }
    private var isTransportBusy: Bool {
        sessionModel.isAcquiringThumbnails
            || (sessionModel.status?.transport != nil && sessionModel.status?.transport != "idle")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    projectSection
                    sourceSection
                    mediaSection
                    queueSection
                }
                .padding(16)
            }

        }
        .background(Color.scanStudioSidebar)
        .sheet(isPresented: $isShowingProjectLauncher) {
            ProjectLauncherView(session: sessionModel)
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(title: "Project")

            if let project = sessionModel.project {
                SidebarRow(
                    icon: "folder.fill",
                    title: project.name,
                    trailing: project.carrier.displayName,
                    isActive: true,
                    accent: .scanStudioAmber
                )
                SidebarRow(icon: "camera.filters", title: "Film process", trailing: project.filmProcess.rawValue)

                Button("Switch Project…") {
                    isShowingProjectLauncher = true
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .disabled(sessionModel.isJobActive || sessionModel.jobId != nil)
                .padding(.leading, 30)
            } else {
                Button {
                    isShowingProjectLauncher = true
                } label: {
                    Label("New / Open Project…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.scanStudioAmber)
            }
        }
    }

    /// Scanner is the only source surface. Scan, output, film, and project
    /// controls live in their task-specific inspector sections rather than a
    /// separate settings destination.
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(title: "Source")

            SidebarRow(
                icon: "scanner",
                title: "Scanner",
                trailing: nil,
                isActive: true,
                accent: .scanStudioAmber
            )

            if isConnected {
                Button("Disconnect") {
                    Task { await sessionModel.disconnect() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .disabled(sessionModel.isJobActive || isTransportBusy)
                .padding(.leading, 30)
            } else {
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
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No scanners found", systemImage: "cable.connector")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Color.scanStudioSecondaryText)
                        Button("Look Again") {
                            Task { await sessionModel.refreshAvailableDevices() }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                case .directConnect(let device):
                    Button {
                        Task { await sessionModel.connect(deviceId: device.deviceId) }
                    } label: {
                        Label(
                            DeviceSelectionPolicy.connectLabel(for: device),
                            systemImage: "cable.connector"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.scanStudioAmber)
                case .explicitChoice(let devices):
                    Menu {
                        ForEach(devices, id: \.deviceId) { device in
                            Button {
                                Task { await sessionModel.connect(deviceId: device.deviceId) }
                            } label: {
                                Text(DeviceSelectionPolicy.menuLabel(for: device))
                            }
                        }
                    } label: {
                        Label("Connect…", systemImage: "cable.connector")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.scanStudioAmber)
                }
            }
        }
    }

    private func connectionProgress(_ state: DeviceSelectionPolicy.State) -> some View {
        let text = state.progressText ?? ""
        return HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .foregroundStyle(Color.scanStudioSecondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(title: "Media")
            SidebarRow(icon: "film", title: "Film Type", trailing: hasMedia ? "35 mm" : "—")
            // Holder identity is authoritative before preview, but its
            // capacity is not a detected film length. Keep that distinction
            // visible instead of hiding the known real holder until media is
            // preview-established.
            if let adapter = sessionModel.status?.adapter {
                SidebarRow(icon: "rectangle.stack", title: "Film holder", trailing: adapter)
            }

            if hasMedia {
                SidebarRow(
                    icon: "square.stack.3d.up",
                    title: sessionModel.carrierDisplayName.uppercased(),
                    trailing: nil,
                    isActive: true,
                    accent: .scanStudioAmber
                )
                SidebarTagRow(
                    icon: "camera.filters",
                    title: filmProcessLabel.uppercased(),
                    tagText: "Active",
                    tagColor: .scanStudioCyan
                )
            } else if isConnected && isRealDevice {
                // "Simulate inserted adapter" is a `sim.loadMedia`-only
                // affordance (PROTOCOL.md) — a real backend has no
                // load-media call at all (`real_backend.rs` rejects it with
                // an internal-only error), so this row never renders the
                // menu for a real device. Media is detected by feeding film
                // and running a preview instead.
                Text(sessionModel.status?.adapter == nil
                    ? "Feed film into the scanner, then run a preview to detect frames."
                    : "Film holder identified. Run a preview to detect the actual frame count.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isConnected {
                Menu {
                    ForEach(SimulatedFilmCarrier.allCases) { carrier in
                        Button {
                            Task { await sessionModel.loadCarrier(carrier) }
                        } label: {
                            Label(carrier.displayName, systemImage: carrierSymbol(carrier))
                        }
                    }
                } label: {
                    Label("Simulate inserted adapter", systemImage: "plus.rectangle.on.folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isTransportBusy)
            } else {
                Text("Connect the scanner to load a film holder.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(title: "Queue")
            SidebarRow(
                icon: "square.stack.3d.down.right",
                title: "All Frames",
                trailing: sessionModel.status?.frameCount.map(String.init) ?? "—"
            )
            SidebarRow(
                icon: "checkmark.square",
                title: "Selected",
                trailing: "\(sessionModel.selectedFrameCount)",
                accent: sessionModel.selectedFrameCount > 0 ? .scanStudioAmber : .scanStudioSecondaryText
            )
            Button {
                sessionModel.applyArchivePositivePreviewPreset()
            } label: {
                SidebarRow(icon: "square.grid.2x2", title: "Archive + Positive + Preview", trailing: nil)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Sets Archive, Positive, and Preview outputs to their default destinations. Each remains individually editable afterward.")
        }
    }

    private var filmProcessLabel: String {
        switch sessionModel.scanFilmProcess {
        case .positive: "Positive"
        case .c41ColorNegative: "C-41 color negative"
        case .bwNegative: "B&W negative"
        case .kodachrome: "Kodachrome"
        }
    }

    private func carrierSymbol(_ carrier: SimulatedFilmCarrier) -> String {
        switch carrier {
        case .mounted: "photo"
        case .strip6: "rectangle.split.3x1"
        case .roll36: "film.stack"
        }
    }
}

private struct SidebarRow: View {
    let icon: String
    let title: String
    let trailing: String?
    var isActive = false
    var accent: Color = .scanStudioSecondaryText

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(accent)
            Text(title)
                .foregroundStyle(Color.scanStudioRowLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(isActive ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle().fill(accent).frame(width: 2).padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A `SidebarRow`-shaped row whose trailing content is an `InlineTag` pill
/// instead of plain text (the MEDIA section's cyan "Active" film-process
/// tag). Hand-laid-out with the same icon/title/HStack structure as
/// `SidebarRow` rather than adding a generic trailing-view parameter to it,
/// since this is the only row in the app that needs a tag instead of text.
private struct SidebarTagRow: View {
    let icon: String
    let title: String
    let tagText: String
    let tagColor: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(Color.scanStudioSecondaryText)
            Text(title)
                .foregroundStyle(Color.scanStudioRowLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            InlineTag(text: tagText, color: tagColor)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(height: 32)
        .accessibilityElement(children: .combine)
    }
}
