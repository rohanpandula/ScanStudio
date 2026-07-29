import Testing

@testable import ScanStudioKit

@Suite("Device activity policy")
struct DeviceActivityPolicyTests {
    @Test("preview acquisition is not mislabeled as scanning")
    func labelsPreviewSeparately() {
        #expect(DeviceActivityPolicy.statusWord(
            isJobActive: false,
            isAcquiringPreviews: true,
            deviceKind: "real",
            hardwareMotionReadiness: .ready
        ) == "PREVIEWING")
        #expect(DeviceActivityPolicy.statusWord(
            isJobActive: true,
            isAcquiringPreviews: false,
            deviceKind: "real",
            hardwareMotionReadiness: .ready
        ) == "SCANNING")
    }

    @Test("idle real-device copy reflects whether the scanner can accept commands")
    func labelsRealReadinessTruthfully() {
        #expect(DeviceActivityPolicy.statusWord(
            isJobActive: false,
            isAcquiringPreviews: false,
            deviceKind: "real",
            hardwareMotionReadiness: .ready
        ) == "READY")
        #expect(DeviceActivityPolicy.statusWord(
            isJobActive: false,
            isAcquiringPreviews: false,
            deviceKind: "real",
            hardwareMotionReadiness: .notEnabled
        ) == "NOT READY")
        #expect(DeviceActivityPolicy.statusWord(
            isJobActive: false,
            isAcquiringPreviews: false,
            deviceKind: "real",
            hardwareMotionReadiness: .unknown
        ) == "CHECK SCANNER")
    }

    @Test("idle simulation stays explicit without claiming hardware readiness")
    func labelsSimulationWithoutReadyClaim() {
        #expect(DeviceActivityPolicy.statusWord(
            isJobActive: false,
            isAcquiringPreviews: false,
            deviceKind: "simulated",
            hardwareMotionReadiness: .notApplicable
        ) == "IDLE")
    }
}
