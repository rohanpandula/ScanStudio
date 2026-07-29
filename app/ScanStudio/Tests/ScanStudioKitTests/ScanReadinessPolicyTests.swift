import Testing

@testable import ScanStudioKit

@Suite("Scan readiness policy")
struct ScanReadinessPolicyTests {
    private let ready = ScanReadinessPolicy.Input(
        isConnected: true,
        hasPreviewedMedia: true,
        hasOpenProject: true,
        hasValidTarget: true,
        hasTargetPreviews: true,
        transportIsIdle: true,
        isAcquiringPreviews: false,
        hasActiveJob: false
    )

    @Test("all scan prerequisites must be satisfied")
    func allPrerequisites() {
        #expect(ScanReadinessPolicy.evaluate(ready) == .ready)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: false, hasPreviewedMedia: true, hasOpenProject: true,
            hasValidTarget: true, hasTargetPreviews: true, transportIsIdle: true, isAcquiringPreviews: false,
            hasActiveJob: false
        )) == .scannerDisconnected)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: false, hasOpenProject: true,
            hasValidTarget: true, hasTargetPreviews: true, transportIsIdle: true, isAcquiringPreviews: false,
            hasActiveJob: false
        )) == .previewsUnavailable)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: false,
            hasValidTarget: true, hasTargetPreviews: true, transportIsIdle: true, isAcquiringPreviews: false,
            hasActiveJob: false
        )) == .projectRequired)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: true,
            hasValidTarget: false, hasTargetPreviews: false, transportIsIdle: true, isAcquiringPreviews: false,
            hasActiveJob: false
        )) == .targetRequired)
    }

    @Test("saving the roll takes precedence over a missing preview")
    func projectPrecedesPreview() {
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: false, hasOpenProject: false,
            hasValidTarget: false, hasTargetPreviews: false, transportIsIdle: true, isAcquiringPreviews: false,
            hasActiveJob: false
        )) == .projectRequired)
    }

    @Test("structural targets and their previews report distinct readiness")
    func targetValidityAndPreviews() {
        let valid: Set<Int> = [1, 2, 3]
        let previewed: Set<Int> = [1, 2]
        #expect(ScanReadinessPolicy.allTargetsAreStructurallyValid(
            [1, 2], validFrameIndices: valid, excludedFrameIndices: []
        ))
        #expect(ScanReadinessPolicy.allTargetPreviewsAreAvailable([1, 2], previewedFrameIndices: previewed))
        #expect(!ScanReadinessPolicy.allTargetsAreStructurallyValid(
            [1, 4], validFrameIndices: valid, excludedFrameIndices: []
        ))
        #expect(!ScanReadinessPolicy.allTargetPreviewsAreAvailable([1, 3], previewedFrameIndices: previewed))
        #expect(!ScanReadinessPolicy.allTargetsAreStructurallyValid(
            [1, 2], validFrameIndices: valid, excludedFrameIndices: [2]
        ))
        #expect(!ScanReadinessPolicy.allTargetsAreStructurallyValid(
            [], validFrameIndices: valid, excludedFrameIndices: []
        ))
    }

    @Test("global previews distinguish empty, invalid, and unpreviewed targets")
    func targetDecisionSpecificity() {
        let base = ScanReadinessPolicy.Input(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: true,
            hasValidTarget: true, hasTargetPreviews: true, transportIsIdle: true,
            isAcquiringPreviews: false, hasActiveJob: false
        )
        func decision(hasValidTarget: Bool, hasTargetPreviews: Bool) -> ScanReadinessPolicy.Decision {
            ScanReadinessPolicy.evaluate(.init(
                isConnected: base.isConnected, hasPreviewedMedia: base.hasPreviewedMedia,
                hasOpenProject: base.hasOpenProject, hasValidTarget: hasValidTarget,
                hasTargetPreviews: hasTargetPreviews, transportIsIdle: base.transportIsIdle,
                isAcquiringPreviews: base.isAcquiringPreviews, hasActiveJob: base.hasActiveJob
            ))
        }
        // No selection, an out-of-range selection, and an excluded selection
        // all lack a structural target and use the same corrective wording.
        #expect(decision(hasValidTarget: false, hasTargetPreviews: false) == .targetRequired)
        #expect(!ScanReadinessPolicy.allTargetsAreStructurallyValid(
            [4], validFrameIndices: [1, 2], excludedFrameIndices: []
        ))
        #expect(decision(hasValidTarget: false, hasTargetPreviews: false) == .targetRequired)
        #expect(!ScanReadinessPolicy.allTargetsAreStructurallyValid(
            [2], validFrameIndices: [1, 2], excludedFrameIndices: [2]
        ))
        #expect(decision(hasValidTarget: false, hasTargetPreviews: false) == .targetRequired)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: base.isConnected, hasPreviewedMedia: base.hasPreviewedMedia,
            hasOpenProject: base.hasOpenProject, hasValidTarget: true,
            hasTargetPreviews: false, transportIsIdle: base.transportIsIdle,
            isAcquiringPreviews: base.isAcquiringPreviews, hasActiveJob: base.hasActiveJob
        )) == .targetPreviewsUnavailable)
        #expect(ScanReadinessPolicy.evaluate(base) == .ready)
    }

    @Test("active work wins over an otherwise idle-looking transport")
    func activeWork() {
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: true,
            hasValidTarget: true, hasTargetPreviews: true, transportIsIdle: true, isAcquiringPreviews: true,
            hasActiveJob: false
        )) == .previewsInProgress)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: true,
            hasValidTarget: true, hasTargetPreviews: true, transportIsIdle: true, isAcquiringPreviews: false,
            hasActiveJob: true
        )) == .scanInProgress)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: true,
            hasValidTarget: true, hasTargetPreviews: true, transportIsIdle: false, isAcquiringPreviews: false,
            hasActiveJob: false
        )) == .transportBusy)
    }

    @Test("real hardware scan readiness requires an affirmative motion check")
    func hardwareMotionGate() {
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: true,
            hardwareMotionReadiness: .ready,
            hasValidTarget: true, hasTargetPreviews: true, transportIsIdle: true,
            isAcquiringPreviews: false, hasActiveJob: false
        )) == .ready)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: true,
            hardwareMotionReadiness: .notEnabled,
            hasValidTarget: true, hasTargetPreviews: true, transportIsIdle: true,
            isAcquiringPreviews: false, hasActiveJob: false
        )) == .hardwareMotionNotReady)
        #expect(
            ScanReadinessPolicy.Decision.hardwareMotionNotReady.reason
                == "Check the scanner before scanning."
        )
    }

    @Test("disabled decisions have concise recovery language")
    func disabledReasons() {
        #expect(ScanReadinessPolicy.Decision.projectRequired.reason == "Save the roll before scanning.")
        #expect(
            ScanReadinessPolicy.Decision.fineScanUnsupported.reason
                == "Live B&W fine scanning is unsupported by the current scanner bridge. Preview remains available."
        )
        #expect(ScanReadinessPolicy.Decision.ready.reason == nil)
    }

    @Test("real B&W fine scan is blocked after preview prerequisites while real color and simulated B&W remain ready")
    func realBlackAndWhiteCapabilityGate() {
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: true,
            fineScanUnsupported: true, hasValidTarget: true, hasTargetPreviews: true,
            transportIsIdle: true, isAcquiringPreviews: false, hasActiveJob: false
        )) == .fineScanUnsupported)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: true, hasOpenProject: true,
            fineScanUnsupported: false, hasValidTarget: true, hasTargetPreviews: true,
            transportIsIdle: true, isAcquiringPreviews: false, hasActiveJob: false
        )) == .ready, "real color and simulated B&W both supply fineScanUnsupported=false")

        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: false, hasPreviewedMedia: true, hasOpenProject: true,
            fineScanUnsupported: true, hasValidTarget: true, hasTargetPreviews: true,
            transportIsIdle: true, isAcquiringPreviews: false, hasActiveJob: false
        )) == .scannerDisconnected)
        #expect(ScanReadinessPolicy.evaluate(.init(
            isConnected: true, hasPreviewedMedia: false, hasOpenProject: true,
            fineScanUnsupported: true, hasValidTarget: true, hasTargetPreviews: true,
            transportIsIdle: true, isAcquiringPreviews: false, hasActiveJob: false
        )) == .previewsUnavailable, "preview remains an available prerequisite")
    }
}
