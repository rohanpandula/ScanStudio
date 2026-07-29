import Testing

@testable import ScanStudioKit

@Suite("Device bar media state")
struct DeviceBarMediaPolicyTests {
    @Test("previewing takes precedence over an unestablished media status")
    func previewingIsNeverNoMedia() {
        #expect(DeviceBarMediaPolicy.label(
            isAcquiringPreviews: true,
            mediaLoaded: false,
            carrierDisplayName: "35 mm roll",
            filmPresent: nil
        ) == "Detecting film")
    }

    @Test("only authoritative presence readings claim film is physically present")
    func presenceClaimsAreAuthoritativeOnly() {
        #expect(DeviceBarMediaPolicy.label(
            isAcquiringPreviews: false, mediaLoaded: false,
            carrierDisplayName: "35 mm roll", filmPresent: nil
        ) == "35 mm roll identified")
        #expect(DeviceBarMediaPolicy.label(
            isAcquiringPreviews: false, mediaLoaded: false,
            carrierDisplayName: "35 mm roll", filmPresent: true
        ) == "Film present; preview needed")
    }
}
