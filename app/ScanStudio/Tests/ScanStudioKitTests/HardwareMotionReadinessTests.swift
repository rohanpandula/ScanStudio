import Testing

@testable import ScanStudioKit

@Suite("Hardware motion readiness")
struct HardwareMotionReadinessTests {
    @Test("simulator is not applicable while real true, false, and nil stay distinct")
    func readinessMatrix() {
        #expect(
            HardwareMotionReadiness.evaluate(
                isRealDevice: false,
                motionArmed: nil
            ) == .notApplicable
        )
        #expect(
            HardwareMotionReadiness.evaluate(
                isRealDevice: true,
                motionArmed: true
            ) == .ready
        )
        #expect(
            HardwareMotionReadiness.evaluate(
                isRealDevice: true,
                motionArmed: false
            ) == .notEnabled
        )
        #expect(
            HardwareMotionReadiness.evaluate(
                isRealDevice: true,
                motionArmed: nil
            ) == .unknown
        )
    }

    @Test("operator copy is plain language and only real ready permits motion")
    func operatorCopyAndGate() {
        #expect(HardwareMotionReadiness.ready.allowsMotion)
        #expect(!HardwareMotionReadiness.notEnabled.allowsMotion)
        #expect(!HardwareMotionReadiness.unknown.allowsMotion)
        #expect(HardwareMotionReadiness.ready.title == "Scanner is ready")
        #expect(HardwareMotionReadiness.notEnabled.title == "Scanner isn’t ready yet")
        #expect(HardwareMotionReadiness.unknown.title == "Scanner status hasn’t been checked")
        #expect(!HardwareMotionReadiness.notEnabled.guidance.contains("SCANSTUDIO"))
        #expect(!HardwareMotionReadiness.notEnabled.guidance.localizedCaseInsensitiveContains("latch"))
        #expect(!HardwareMotionReadiness.notEnabled.guidance.localizedCaseInsensitiveContains("movement"))
    }

    @Test("status refresh copy distinguishes a first check from a later refresh")
    func statusRefreshCopy() {
        #expect(HardwareMotionReadiness.ready.statusRefreshTitle == "Refresh status")
        #expect(HardwareMotionReadiness.notEnabled.statusRefreshTitle == "Check scanner")
        #expect(HardwareMotionReadiness.unknown.statusRefreshTitle == "Check scanner")
    }

    @Test("combined scanner copy only promises scanning when every prerequisite is ready")
    func combinedScannerCopy() {
        #expect(
            ScannerReadinessPresentation.evaluate(
                hardwareReadiness: .ready,
                filmStatus: .notDetected,
                hasPreviewedMedia: false,
                scanReadiness: .projectRequired
            ).title == "Scanner is ready for film"
        )

        let loadedBeforePreview = ScannerReadinessPresentation.evaluate(
            hardwareReadiness: .ready,
            filmStatus: .loaded,
            hasPreviewedMedia: false,
            scanReadiness: .projectRequired
        )
        #expect(loadedBeforePreview.title == "Film is loaded")
        #expect(loadedBeforePreview.guidance == "Preview the film before scanning.")

        let readyToScan = ScannerReadinessPresentation.evaluate(
            hardwareReadiness: .ready,
            filmStatus: .loaded,
            hasPreviewedMedia: true,
            scanReadiness: .ready
        )
        #expect(readyToScan.title == "Scanner is ready to scan")
        #expect(readyToScan.guidance == "The selected frames are ready.")

        #expect(
            ScannerReadinessPresentation.evaluate(
                hardwareReadiness: .ready,
                filmStatus: .unknown,
                hasPreviewedMedia: false,
                scanReadiness: .projectRequired
            ).title == "Scanner is ready"
        )
        #expect(
            ScannerReadinessPresentation.evaluate(
                hardwareReadiness: .notEnabled,
                filmStatus: .unknown,
                hasPreviewedMedia: false,
                scanReadiness: .hardwareMotionNotReady
            ).title == "Scanner isn’t ready yet"
        )
    }
}
