import Testing

@testable import ScanStudioKit

@Suite("Hardware film status")
struct HardwareFilmStatusTests {
    @Test("a connected real scanner only reports loaded from its live film-presence reading")
    func realScannerReportsLoaded() {
        #expect(
            HardwareFilmStatus.evaluate(
                isConnected: true,
                isRealDevice: true,
                mediaLoaded: false,
                filmPresent: true
            ) == .loaded
        )
    }

    @Test("a connected real scanner reports not detected from an explicit negative reading")
    func realScannerReportsNotDetected() {
        #expect(
            HardwareFilmStatus.evaluate(
                isConnected: true,
                isRealDevice: true,
                mediaLoaded: true,
                filmPresent: false
            ) == .notDetected
        )
    }

    @Test("a real scanner without a current presence reading never guesses from preview registration")
    func realScannerWithoutReadingIsUnknown() {
        #expect(
            HardwareFilmStatus.evaluate(
                isConnected: true,
                isRealDevice: true,
                mediaLoaded: true,
                filmPresent: nil
            ) == .unknown
        )
        #expect(
            HardwareFilmStatus.evaluate(
                isConnected: false,
                isRealDevice: true,
                mediaLoaded: true,
                filmPresent: true
            ) == .unknown
        )
    }

    @Test("simulation uses its own explicit loaded-media state")
    func simulationUsesMediaLoaded() {
        #expect(
            HardwareFilmStatus.evaluate(
                isConnected: true,
                isRealDevice: false,
                mediaLoaded: true,
                filmPresent: nil
            ) == .loaded
        )
        #expect(
            HardwareFilmStatus.evaluate(
                isConnected: true,
                isRealDevice: false,
                mediaLoaded: false,
                filmPresent: nil
            ) == .notDetected
        )
        #expect(
            HardwareFilmStatus.evaluate(
                isConnected: true,
                isRealDevice: false,
                mediaLoaded: nil,
                filmPresent: nil
            ) == .unknown
        )
    }

    @Test("operator copy is a short, explicit tri-state")
    func operatorCopy() {
        #expect(HardwareFilmStatus.loaded.title == "Loaded")
        #expect(HardwareFilmStatus.notDetected.title == "Not detected")
        #expect(HardwareFilmStatus.unknown.title == "Unknown")
    }
}
