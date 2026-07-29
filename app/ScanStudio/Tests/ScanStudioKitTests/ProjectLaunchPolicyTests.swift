import Testing

@testable import ScanStudioKit

@Suite("Project launcher policy")
struct ProjectLaunchPolicyTests {
    @Test("known carrier seeds only the carrier")
    func knownCarrier() {
        #expect(ProjectLaunchPolicy.initialCarrier(loadedCarrier: .strip6) == .strip6)
    }

    @Test("a known real holder skips the manual holder requirement")
    func knownRealHolder() {
        // A real backend's trusted MA-21/SA-21/SA-30 classification reaches
        // this policy through the same ScannerStatus carrier wire value as a
        // simulator. The launcher must seed it rather than require "Choose
        // a film holder" again.
        let carrier = ProjectLaunchPolicy.initialCarrier(loadedCarrier: .strip6)
        let registeredCount = ProjectLaunchPolicy.registeredPreviewFrameCount(
            mediaLoaded: true,
            previewFrameIndices: 1...6,
            statusFrameCount: 6,
            committedFilmProcess: .c41ColorNegative
        )
        #expect(carrier == .strip6)
        #expect(registeredCount == 6)
        #expect(ProjectLaunchPolicy.createDisabledReason(
            name: "Real strip",
            carrier: carrier,
            registeredPreviewFrameCount: registeredCount
        ) == nil)
    }

    @Test("unknown carrier has no fabricated default")
    func unknownCarrier() {
        #expect(ProjectLaunchPolicy.initialCarrier(loadedCarrier: nil) == nil)
        #expect(ProjectLaunchPolicy.createDisabledReason(
            name: "July roll",
            carrier: nil,
            registeredPreviewFrameCount: 6
        ) == "Confirm which film holder is loaded.")
    }

    @Test("create explains its unmet requirement")
    func createRequirement() {
        #expect(ProjectLaunchPolicy.createDisabledReason(
            name: "   ",
            carrier: .mounted,
            registeredPreviewFrameCount: 1
        ) == "Enter a roll name to save it.")
        #expect(ProjectLaunchPolicy.createDisabledReason(
            name: "July roll",
            carrier: .mounted,
            registeredPreviewFrameCount: nil
        ) == "Finish previewing the film before saving so every frame and its film process are registered.")
    }

    @Test("unknown-holder six-frame preview confirms a compatible holder without changing its count")
    func unknownHolderConfirmationPreservesPreviewCount() {
        let registeredCount = ProjectLaunchPolicy.registeredPreviewFrameCount(
            mediaLoaded: true,
            previewFrameIndices: 1...6,
            statusFrameCount: 6,
            committedFilmProcess: .c41ColorNegative
        )
        #expect(registeredCount == 6)

        for carrier in [SimulatedFilmCarrier.strip6, .roll36] {
            let confirmed = ProjectLaunchPolicy.confirmedFrameCount(
                carrier: carrier,
                registeredPreviewFrameCount: registeredCount
            )
            #expect(confirmed == 6)
            #expect(ProjectLaunchPolicy.createDisabledReason(
                name: "Unknown holder preview",
                carrier: carrier,
                registeredPreviewFrameCount: registeredCount
            ) == nil)
        }

        #expect(ProjectLaunchPolicy.confirmedFrameCount(
            carrier: .mounted,
            registeredPreviewFrameCount: registeredCount
        ) == nil)
        #expect(ProjectLaunchPolicy.createDisabledReason(
            name: "Unknown holder preview",
            carrier: .mounted,
            registeredPreviewFrameCount: registeredCount
        ) == "Choose a valid frame count for this film holder.")
    }

    @Test("project confirmation rejects incomplete tile or process registration")
    func confirmationRequiresEveryPreviewSignal() {
        #expect(ProjectLaunchPolicy.registeredPreviewFrameCount(
            mediaLoaded: true,
            previewFrameIndices: 1...5,
            statusFrameCount: 6,
            committedFilmProcess: .c41ColorNegative
        ) == nil)
        #expect(ProjectLaunchPolicy.registeredPreviewFrameCount(
            mediaLoaded: true,
            previewFrameIndices: 1...6,
            statusFrameCount: 6,
            committedFilmProcess: nil
        ) == nil)
    }

    @Test("detected media cannot create a project without complete preview registration")
    func detectedMediaRequiresCompletePreviewRegistration() {
        #expect(ProjectLaunchPolicy.createDisabledReason(
            name: "Stale re-preview",
            carrier: .mounted,
            registeredPreviewFrameCount: nil
        ) == "Finish previewing the film before saving so every frame and its film process are registered.")
        #expect(ProjectLaunchPolicy.createDisabledReason(
            name: "Registered B&W",
            carrier: .mounted,
            registeredPreviewFrameCount: 1
        ) == nil)
    }

    @Test("project compatibility requires both holder and exact preview count")
    func projectCompatibilityRequiresHolderAndCount() {
        #expect(ProjectMediaCompatibilityPolicy.matches(
            projectCarrier: .roll36,
            projectFrameCount: 36,
            previewedCarrier: .roll36,
            previewedFrameCount: 36
        ))
        #expect(ProjectMediaCompatibilityPolicy.matches(
            projectCarrier: .roll36,
            projectFrameCount: 39,
            previewedCarrier: .roll36,
            previewedFrameCount: 39
        ))
        #expect(!ProjectMediaCompatibilityPolicy.matches(
            projectCarrier: .roll36,
            projectFrameCount: 36,
            previewedCarrier: .roll36,
            previewedFrameCount: 39
        ))
        #expect(!ProjectMediaCompatibilityPolicy.matches(
            projectCarrier: .strip6,
            projectFrameCount: 6,
            previewedCarrier: .roll36,
            previewedFrameCount: 6
        ))
    }
}
