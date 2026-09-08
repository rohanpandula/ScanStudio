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

    @Test("a physically-present, never-yet-previewed film offers Eject (incident 2026-09-07)")
    func filmPresentWithNoPreviewYetOffersEject() {
        #expect(DeviceBarEjectPolicy.canOffer(
            isConnected: true,
            transportIsIdle: true,
            isJobActive: false,
            mediaLoaded: false,
            filmPresent: true,
            refeedRequired: false,
            lastErrorMessage: nil
        ))
    }

    @Test("the eject gate matches its own rule for every filmPresent × mediaLoaded × refeedRequired × isConnected × transportIsIdle × isJobActive combination (D-11a)")
    func ejectGateMatrixMatchesRuleForEveryCombination() {
        let filmPresentValues: [Bool?] = [true, false, nil]
        let boolValues = [true, false]
        for filmPresent in filmPresentValues {
            for mediaLoaded in boolValues {
                for refeedRequired in boolValues {
                    for isConnected in boolValues {
                        for transportIsIdle in boolValues {
                            for isJobActive in boolValues {
                                // The oracle states the rule independently of `canOffer`'s body:
                                // readiness (connected, idle transport, no active job) AND a
                                // sensor that has not confirmed absence AND (already-previewed
                                // OR a legacy refeed OR a live present reading on its own).
                                let expected = isConnected && transportIsIdle && !isJobActive
                                    && filmPresent != false
                                    && (mediaLoaded || refeedRequired || filmPresent == true)
                                let actual = DeviceBarEjectPolicy.canOffer(
                                    isConnected: isConnected,
                                    transportIsIdle: transportIsIdle,
                                    isJobActive: isJobActive,
                                    mediaLoaded: mediaLoaded,
                                    filmPresent: filmPresent,
                                    refeedRequired: refeedRequired,
                                    lastErrorMessage: nil
                                )
                                #expect(
                                    actual == expected,
                                    """
                                    isConnected: \(isConnected), transportIsIdle: \(transportIsIdle), \
                                    isJobActive: \(isJobActive), mediaLoaded: \(mediaLoaded), \
                                    filmPresent: \(String(describing: filmPresent)), \
                                    refeedRequired: \(refeedRequired) — expected \(expected), got \(actual)
                                    """
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("the card never says film is loaded while Eject is unavailable (EJECT-04)")
    func cardNeverClaimsLoadedWhileEjectIsUnavailable() {
        // HardwareFilmStatus (the readiness card's wording) and
        // DeviceBarEjectPolicy (the Eject gate) both read the same live
        // `filmPresent` sensor value from `sessionModel.status?.filmPresent`
        // (DeviceBarView.swift, HardwareMotionReadinessView.swift). This test
        // ties them to that one signal so they cannot drift apart again the
        // way they did in the 2026-09-07 incident, where the card read "Film
        // is loaded" and no Eject affordance was offered.
        let filmPresentValues: [Bool?] = [true, false, nil]
        for filmPresent in filmPresentValues {
            let filmStatus = HardwareFilmStatus.evaluate(
                isConnected: true,
                isRealDevice: true,
                mediaLoaded: false,
                filmPresent: filmPresent
            )
            let canOffer = DeviceBarEjectPolicy.canOffer(
                isConnected: true,
                transportIsIdle: true,
                isJobActive: false,
                mediaLoaded: false,
                filmPresent: filmPresent,
                refeedRequired: false,
                lastErrorMessage: nil
            )
            #expect(
                filmStatus != .loaded || canOffer,
                "filmPresent: \(String(describing: filmPresent)) — card says \(filmStatus) but canOffer is \(canOffer)"
            )
        }
    }
}
