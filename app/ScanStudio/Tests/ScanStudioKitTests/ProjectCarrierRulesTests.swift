// Proves ProjectCarrierRules — the single source of truth for
// carrier-to-frame-count validity — matches PROTOCOL.md's project.create
// validation exactly for all three simulated carriers, so the app can
// compute the correct range and default before ever calling the engine.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Project carrier rules")
struct ProjectCarrierRulesTests {
    @Test("the legacy roll36 token represents a variable 1-40 SA-30 roll")
    func roll36AllowsOneThroughForty() {
        #expect(ProjectCarrierRules.isFrameCountFixed(.roll36) == false)
        #expect(ProjectCarrierRules.validFrameCountRange(.roll36) == 1...40)
        #expect(ProjectCarrierRules.defaultFrameCount(.roll36) == 36)
        for count in [1, 36, 39, 40] {
            #expect(ProjectCarrierRules.validFrameCountRange(.roll36).contains(count))
        }
        #expect(!ProjectCarrierRules.validFrameCountRange(.roll36).contains(0))
        #expect(!ProjectCarrierRules.validFrameCountRange(.roll36).contains(41))
    }

    @Test("strip6 allows a variable 1-6 frame count, defaulting to 6")
    func strip6AllowsOneToSix() {
        #expect(ProjectCarrierRules.isFrameCountFixed(.strip6) == false)
        #expect(ProjectCarrierRules.validFrameCountRange(.strip6) == 1...6)
        #expect(ProjectCarrierRules.defaultFrameCount(.strip6) == 6)
    }

    @Test("mounted is a fixed 1-frame carrier")
    func mountedIsFixedAtOne() {
        #expect(ProjectCarrierRules.isFrameCountFixed(.mounted) == true)
        #expect(ProjectCarrierRules.validFrameCountRange(.mounted) == 1...1)
        #expect(ProjectCarrierRules.defaultFrameCount(.mounted) == 1)
    }
}
