import Testing

@testable import ScanStudioKit

@Suite("Frame alignment availability")
struct FrameAlignmentAvailabilityPolicyTests {
    @Test("scanner alignment controls are available only for a real device")
    func requiresRealDevice() {
        #expect(FrameAlignmentAvailabilityPolicy.isVisible(deviceKind: "real"))
        #expect(!FrameAlignmentAvailabilityPolicy.isVisible(deviceKind: "simulated"))
        #expect(!FrameAlignmentAvailabilityPolicy.isVisible(deviceKind: nil))
        #expect(!FrameAlignmentAvailabilityPolicy.isVisible(deviceKind: "unknown"))
    }
}
