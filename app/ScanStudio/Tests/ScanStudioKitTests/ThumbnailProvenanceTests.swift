// Proves Thumbnail.isSimulatorShaped — the single source of truth for whether
// a thumbnail carries affirmative simulator provenance — keys off the
// simulator's positively-populated fields (brightness/tint), never off the
// mere absence of an imagePath. Mirrors PROTOCOL.md's strict one-of contract
// and the owner's 2026-07-26 requirement that bundled simulator art appear
// only from affirmative simulator provenance, never from absence of a real
// device (including while device identity is nil/connecting/unknown).

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Thumbnail simulator provenance")
struct ThumbnailProvenanceTests {
    @Test("A simulator thumbnail (brightness + tint, no imagePath) is simulator-shaped")
    func simulatorBrightnessAndTint() {
        #expect(Thumbnail(brightness: 0.12, tint: -0.04, imagePath: nil).isSimulatorShaped == true)
    }

    @Test("A thumbnail carrying only brightness is still affirmatively simulator-shaped")
    func brightnessAlone() {
        #expect(Thumbnail(brightness: 0.5, tint: nil, imagePath: nil).isSimulatorShaped == true)
    }

    @Test("A thumbnail carrying only tint is still affirmatively simulator-shaped")
    func tintAlone() {
        #expect(Thumbnail(brightness: nil, tint: 0.2, imagePath: nil).isSimulatorShaped == true)
    }

    @Test("A real backend thumbnail (imagePath, no brightness/tint) is never simulator-shaped")
    func realImagePath() {
        #expect(Thumbnail(brightness: nil, tint: nil, imagePath: "/tmp/preview-01.tif").isSimulatorShaped == false)
    }

    @Test("A malformed/unknown thumbnail with every field nil is NOT simulator-shaped — provenance, not absence")
    func allNilIsNotSimulator() {
        #expect(Thumbnail(brightness: nil, tint: nil, imagePath: nil).isSimulatorShaped == false)
    }

    @Test("A contract-violating thumbnail that carries brightness AND an imagePath still reads as simulator-shaped (provenance present)")
    func bothPopulatedDefensive() {
        #expect(Thumbnail(brightness: 0.1, tint: nil, imagePath: "/tmp/x.tif").isSimulatorShaped == true)
    }
}
