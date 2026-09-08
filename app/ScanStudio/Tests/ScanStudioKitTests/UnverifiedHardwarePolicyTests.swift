import Testing
@testable import ScanStudioKit

struct UnverifiedHardwarePolicyTests {
    private let unsupported = DeviceInfo(
        deviceId: "ls50", model: "SUPER COOLSCAN  LS-50", kind: "real",
        firmware: "unknown", connection: "usb", supported: false,
        unverifiedAllowed: true, hardwareVerification: "unverified"
    )
    private let simulator = DeviceInfo(
        deviceId: "sim", model: "LS-5000 ED", kind: "simulated",
        firmware: "sim", connection: "in-process", supported: true
    )

    @Test func optInAddsRecognizedUnverifiedRealDevice() {
        #expect(UnverifiedHardwarePolicy.connectCandidates(from: [simulator, unsupported], allowUnverified: false) == [simulator])
        #expect(UnverifiedHardwarePolicy.connectCandidates(from: [simulator, unsupported], allowUnverified: true) == [unsupported])
        #expect(DeviceSelectionPolicy.resolveNilTarget(devices: [simulator, unsupported]) == nil)
        #expect(DeviceSelectionPolicy.resolveNilTarget(devices: [simulator, unsupported], previousDeviceId: simulator.deviceId) == simulator.deviceId)
        #expect(DeviceSelectionPolicy.resolveNilTarget(devices: [simulator, unsupported], previousDeviceId: "missing") == nil)
        #expect(DeviceSelectionPolicy.resolveNilTarget(devices: [simulator], previousDeviceId: unsupported.deviceId) == nil)
    }

    @Test func badgeAndDiagnosticOfferAreTypedAndOneShot() {
        #expect(UnverifiedHardwarePolicy.badge(model: unsupported.model, verification: "unverified") == "Unverified scanner — SUPER COOLSCAN  LS-50")
        #expect(UnverifiedHardwarePolicy.badge(model: unsupported.model, verification: "verified") == nil)
        #expect(UnverifiedHardwarePolicy.shouldOfferDiagnosticBundle(errorCode: "UNSUPPORTED_DEVICE", verification: "unverified", alreadyOffered: false))
        #expect(!UnverifiedHardwarePolicy.shouldOfferDiagnosticBundle(errorCode: "UNSUPPORTED_DEVICE", verification: "unverified", alreadyOffered: true))
        #expect(!UnverifiedHardwarePolicy.shouldOfferDiagnosticBundle(errorCode: "UNSUPPORTED_DEVICE", verification: "verified", alreadyOffered: false))
    }

    @Test func connectedUnverifiedScannerRequiresPerRunOptIn() {
        #expect(UnverifiedHardwarePolicy.shouldRefuseConnectedUnverified(verification: "unverified", allowUnverified: false))
        #expect(!UnverifiedHardwarePolicy.shouldRefuseConnectedUnverified(verification: "unverified", allowUnverified: true))
        #expect(!UnverifiedHardwarePolicy.shouldRefuseConnectedUnverified(verification: "verified", allowUnverified: false))
    }
}
