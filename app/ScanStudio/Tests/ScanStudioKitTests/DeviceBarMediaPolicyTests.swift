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
            filmPresent: nil,
            refeedRequired: false
        ) == "Detecting film")
    }

    @Test("only authoritative presence readings claim film is physically present")
    func presenceClaimsAreAuthoritativeOnly() {
        #expect(DeviceBarMediaPolicy.label(
            isAcquiringPreviews: false, mediaLoaded: false,
            carrierDisplayName: "35 mm roll", filmPresent: nil,
            refeedRequired: false
        ) == "35 mm roll identified")
        #expect(DeviceBarMediaPolicy.label(
            isAcquiringPreviews: false, mediaLoaded: false,
            carrierDisplayName: "35 mm roll", filmPresent: true,
            refeedRequired: false
        ) == "Film present; preview needed")
    }

    @Test("a transport slip overrides stale loaded media copy")
    func refeedRequiredOverridesStaleLoadedState() {
        #expect(DeviceBarMediaPolicy.label(
            isAcquiringPreviews: false,
            mediaLoaded: true,
            carrierDisplayName: "35 mm strip (6 frames)",
            filmPresent: false,
            refeedRequired: true
        ) == "Refeed required")
    }

    @Test("an explicit no-film sensor reading overrides stale loaded media copy")
    func noFilmOverridesStaleLoadedState() {
        #expect(DeviceBarMediaPolicy.label(
            isAcquiringPreviews: false,
            mediaLoaded: true,
            carrierDisplayName: "35 mm strip (6 frames)",
            filmPresent: false,
            refeedRequired: false
        ) == "No film detected")
    }

    @Test("film-feed interruption hides Eject despite stale media while legacy refeed keeps it")
    func ejectRecoveryDistinguishesPhysicalAbsenceFromLegacyRefeed() {
        #expect(!DeviceBarEjectPolicy.canOffer(
            isConnected: true,
            transportIsIdle: true,
            isJobActive: false,
            mediaLoaded: true,
            filmPresent: nil,
            refeedRequired: true,
            lastErrorMessage: "FILM_FEED_INTERRUPTED: scanner stopped detecting film (02/3A/00)"
        ))
        #expect(DeviceBarEjectPolicy.canOffer(
            isConnected: true,
            transportIsIdle: true,
            isJobActive: false,
            mediaLoaded: false,
            filmPresent: nil,
            refeedRequired: true,
            lastErrorMessage: "REFEED_REQUIRED: eject or refeed the strip"
        ))
    }

    @Test("verified no-film state hides Eject after error dismissal and for legacy refeed")
    func noFilmSensorAlwaysVetoesEject() {
        #expect(!DeviceBarEjectPolicy.canOffer(
            isConnected: true,
            transportIsIdle: true,
            isJobActive: false,
            mediaLoaded: true,
            filmPresent: false,
            refeedRequired: true,
            lastErrorMessage: nil
        ))
        #expect(!DeviceBarEjectPolicy.canOffer(
            isConnected: true,
            transportIsIdle: true,
            isJobActive: false,
            mediaLoaded: true,
            filmPresent: false,
            refeedRequired: true,
            lastErrorMessage: "REFEED_REQUIRED: eject or refeed the strip"
        ))
    }
}
