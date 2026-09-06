import ScanStudioKit
import SwiftUI

private enum LauncherTab: Hashable {
    case newProject
    case openRecent
}

private struct LauncherAttemptError: Equatable {
    let title: String
    let guidance: String
}

enum ProjectLauncherPurpose: Equatable {
    case manageProjects
    case saveRollAndScan
}

/// New Project / Open Recent flow, presented as a sheet from
/// `SessionSidebarView`. Takes the app's single `SessionModel` instance as
/// an explicit `@Bindable` parameter (rather than `@Environment`) so this
/// sheet's own dismiss-on-success logic can read `session.lastErrorMessage`
/// right after each action completes — the caller passes the exact same
/// instance flowing through the rest of the app, never a second one.
struct ProjectLauncherView: View {
    @Bindable var session: SessionModel
    @Environment(\.dismiss) private var dismiss

    let purpose: ProjectLauncherPurpose
    var onProjectSaved: (() -> Void)? = nil

    @State private var name = ""
    @State private var carrier: SimulatedFilmCarrier?
    @State private var selectedTab: LauncherTab = .newProject
    @State private var createAttemptError: LauncherAttemptError?
    @State private var openRecentAttemptError: LauncherAttemptError?
    @State private var isSubmitting = false
    @State private var isLoadingRecentProjects = true

    init(
        session: SessionModel,
        purpose: ProjectLauncherPurpose = .manageProjects,
        onProjectSaved: (() -> Void)? = nil
    ) {
        self.session = session
        self.purpose = purpose
        self.onProjectSaved = onProjectSaved
        let detectedCarrier = ProjectLaunchPolicy.initialCarrier(loadedCarrier: session.loadedCarrier)
        _carrier = State(initialValue: detectedCarrier)
    }

    var body: some View {
        VStack(spacing: 0) {
            if purpose == .saveRollAndScan {
                saveRollHeader
                newProjectForm
            } else {
                Picker("", selection: $selectedTab) {
                    Text("New Project").tag(LauncherTab.newProject)
                    Text("Open Recent").tag(LauncherTab.openRecent)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top])
                .accessibilityLabel("Project launcher tab")
                .disabled(isSubmitting)

                Group {
                    if selectedTab == .newProject {
                        if registeredPreviewFrameCount == nil {
                            ContentUnavailableView(
                                "Preview a roll first",
                                systemImage: "photo.stack",
                                description: Text("Return to the film workspace, connect your scanner, and acquire previews. Then save the roll as a new project.")
                            )
                        } else {
                            newProjectForm
                        }
                    } else {
                        openRecentSection
                    }
                }
            }
            Divider()
                .padding(.top, 12)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
            }
            .padding(.top, 12)
        }
        .frame(width: 420, height: 460)
        .padding(20)
        .interactiveDismissDisabled(isSubmitting)
    }

    private var saveRollHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Save Roll & Scan")
                .font(.system(size: 20, weight: .semibold))
            Text(saveRollGuidance)
                .font(.system(size: 12))
                .foregroundStyle(Color.scanStudioSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var newProjectForm: some View {
        Form {
            TextField("Project name", text: $name)

            if let detectedHolder = session.loadedCarrier {
                LabeledContent("Film holder", value: session.status?.adapter ?? "Detected holder")
                if session.status?.adapter != nil {
                    LabeledContent("Film type", value: detectedHolder.displayName)
                }
            } else {
                Picker("Film holder", selection: $carrier) {
                    Text("Choose a film holder").tag(SimulatedFilmCarrier?.none)
                    ForEach(SimulatedFilmCarrier.allCases) { option in
                        Text(option.displayName).tag(Optional(option))
                    }
                }
            }

            if let carrier {
                if let confirmedFrameCount {
                    LabeledContent("Detected frame count", value: framePluralized(confirmedFrameCount))
                } else if let registeredPreviewFrameCount {
                    Text("\(framePluralized(registeredPreviewFrameCount)) cannot use the selected \(carrier.displayName.lowercased()) holder. Choose a compatible holder.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.scanStudioRed)
                } else {
                    Text("Preview the film before saving so Scan Studio can detect its frame count.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.scanStudioSecondaryText)
                }
            } else {
                Text(
                    registeredPreviewFrameCount == nil
                        ? "Finish previewing the film, then confirm which film holder is loaded."
                        : "Confirm the film holder. The completed preview already set the frame count."
                )
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }

            if session.loadedCarrier == nil {
                Text("Film holder is unknown. Confirm the holder before saving the roll.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }

            if let previewProcess = session.previewFilmProcess, registeredPreviewFrameCount != nil {
                LabeledContent("Film process", value: filmProcessLabel(previewProcess))
                Text("Matches the process used for this preview. Re-preview the film to change it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            } else {
                Text("Finish previewing the film to register its film process before saving.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }

            if let error = createAttemptError {
                VStack(alignment: .leading, spacing: 3) {
                    Text(error.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(error.guidance)
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.scanStudioRed)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let disabledReason {
                Text(disabledReason)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
            }

            Button(submitButtonTitle) {
                Task {
                    guard let carrier,
                          let frameCount = confirmedFrameCount,
                          let previewProcess = session.previewFilmProcess,
                          registeredPreviewFrameCount != nil
                    else { return }
                    guard !isSubmitting else { return }
                    createAttemptError = nil
                    isSubmitting = true
                    let completed: Bool
                    switch purpose {
                    case .manageProjects:
                        await session.createProject(
                            name: name,
                            carrier: carrier,
                            frameCount: frameCount,
                            filmProcess: previewProcess
                        )
                        completed = session.lastErrorMessage == nil
                    case .saveRollAndScan:
                        completed = await session.saveRollAndScanSelectedFrames(
                            name: name,
                            carrier: carrier,
                            frameCount: frameCount,
                            filmProcess: previewProcess
                        )
                    }
                    isSubmitting = false

                    if completed {
                        if purpose == .manageProjects {
                            onProjectSaved?()
                        }
                        dismiss()
                    } else if purpose == .saveRollAndScan,
                              session.project != nil {
                        // The roll is safely saved, but scan startup failed.
                        // Return to the project and leave its error banner
                        // intact; retrying project creation would be wrong.
                        dismiss()
                    } else {
                        // Curated title, not the raw `lastErrorMessage` --
                        // this sheet is the primary new-project flow, not a
                        // developer pane.
                        if let presentation = session.errorPresentation {
                            createAttemptError = LauncherAttemptError(
                                title: presentation.title,
                                guidance: presentation.guidance
                            )
                        } else {
                            createAttemptError = LauncherAttemptError(
                                title: "Couldn’t save this roll.",
                                guidance: "Review the project details and try again."
                            )
                        }
                    }
                }
            }
            .disabled(disabledReason != nil || isSubmitting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 12)
        .disabled(isSubmitting)
    }

    private var registeredPreviewFrameCount: Int? {
        ProjectLaunchPolicy.registeredPreviewFrameCount(
            mediaLoaded: session.status?.mediaLoaded == true,
            previewFrameIndices: session.thumbnails.keys,
            statusFrameCount: session.status?.frameCount,
            committedFilmProcess: session.previewFilmProcess
        )
    }

    private var confirmedFrameCount: Int? {
        ProjectLaunchPolicy.confirmedFrameCount(
            carrier: carrier,
            registeredPreviewFrameCount: registeredPreviewFrameCount
        )
    }

    private var selectedFrameCount: Int {
        session.selectedFrameCount
    }

    private var selectedReviewCount: Int {
        session.selectedFrames.filter { frameIndex in
            session.thumbnails[frameIndex]?.needsApproval == true
                && session.manualReviewDecision(for: frameIndex) != .useFrameAnyway
        }.count
    }

    private var submitButtonTitle: String {
        if isSubmitting {
            return purpose == .saveRollAndScan ? "Saving Roll…" : "Creating…"
        }
        guard purpose == .saveRollAndScan else { return "Create" }
        let noun = selectedFrameCount == 1 ? "Frame" : "Frames"
        return selectedReviewCount > 0
            ? "Save & Review \(selectedFrameCount) \(noun)"
            : "Save & Scan \(selectedFrameCount) \(noun)"
    }

    private var saveRollGuidance: String {
        let noun = selectedFrameCount == 1 ? "frame" : "frames"
        if selectedReviewCount > 0 {
            let reviewNoun = selectedReviewCount == 1
                ? "boundary check"
                : "boundary checks"
            return "\(selectedReviewCount) of the \(selectedFrameCount) selected \(noun) need \(reviewNoun). Save the roll now; ScanStudio will show those reviews next, then scan the selection once."
        }
        return "The \(selectedFrameCount) selected \(noun) will start scanning as soon as this roll is saved."
    }

    private var disabledReason: String? {
        if let reason = session.projectChangeDisabledReason {
            return reason
        }
        if purpose == .saveRollAndScan, selectedFrameCount == 0 {
            return "Select at least one frame before saving and scanning."
        }
        return ProjectLaunchPolicy.createDisabledReason(
            name: name,
            carrier: carrier,
            registeredPreviewFrameCount: registeredPreviewFrameCount
        )
    }

    private var openRecentSection: some View {
        Group {
            if isLoadingRecentProjects {
                ProgressView("Loading projects…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.recentProjects.isEmpty {
                ContentUnavailableView(
                    openRecentAttemptError == nil ? "No projects yet" : "Couldn’t load projects",
                    systemImage: "tray"
                )
            } else {
                List(session.recentProjects) { summary in
                    Button {
                        Task {
                            guard !isSubmitting else { return }
                            isSubmitting = true
                            defer { isSubmitting = false }
                            openRecentAttemptError = nil
                            await session.openProject(directory: summary.directory)
                            if session.lastErrorMessage == nil {
                                onProjectSaved?()
                                dismiss()
                            } else {
                                // Curated title, not the raw `lastErrorMessage`
                                // -- same reasoning as `createAttemptError`.
                                if let presentation = session.errorPresentation {
                                    openRecentAttemptError = LauncherAttemptError(
                                        title: presentation.title,
                                        guidance: presentation.guidance
                                    )
                                }
                            }
                        }
                    } label: {
                        recentProjectRow(summary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting || session.projectChangeDisabledReason != nil)
                }
            }

            if isSubmitting {
                ProgressView("Opening project…")
            } else if let reason = session.projectChangeDisabledReason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scanStudioSecondaryText)
                    .padding(.horizontal)
            }

            if let error = openRecentAttemptError {
                VStack(alignment: .leading, spacing: 3) {
                    Text(error.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(error.guidance)
                        .font(.system(size: 11))
                }
                    .foregroundStyle(Color.scanStudioRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                Button("Reload Projects") {
                    Task { await loadRecentProjects() }
                }
                .disabled(isSubmitting || isLoadingRecentProjects)
            }
        }
        .task { await loadRecentProjects() }
    }

    private func loadRecentProjects() async {
        isLoadingRecentProjects = true
        openRecentAttemptError = nil
        await session.refreshRecentProjects()
        if let error = session.errorPresentation {
            openRecentAttemptError = LauncherAttemptError(title: error.title, guidance: error.guidance)
        }
        isLoadingRecentProjects = false
    }

    private func recentProjectRow(_ summary: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.name)
                .font(.system(size: 12, weight: .semibold))
            Text("\(summary.carrier.displayName) · \(filmProcessLabel(summary.filmProcess)) · \(projectDate(summary.createdAt))")
                .font(.system(size: 10))
                .foregroundStyle(Color.scanStudioSecondaryText)
        }
        .padding(.vertical, 2)
    }

    private func projectDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func framePluralized(_ count: Int) -> String {
        "\(count) frame\(count == 1 ? "" : "s")"
    }

    private func filmProcessLabel(_ process: FilmProcess) -> String {
        switch process {
        case .positive: "Positive"
        case .c41ColorNegative: "C-41 Color Negative"
        case .bwNegative: "B&W Negative"
        case .kodachrome: "Kodachrome"
        }
    }
}
