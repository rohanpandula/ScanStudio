// Proves ScanTelemetryHonesty — the single source of truth for which live
// scan telemetry a device kind may honestly display — suppresses every
// fabricated field on real hardware while keeping the simulator's genuine
// telemetry visible. Mirrors real_backend.rs' hardcoded `frame_percent`/
// `eta_seconds` (0.0) and `pass` (1) against sim.rs' genuine timers.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Scan telemetry honesty")
struct ScanTelemetryHonestyTests {
    private let real = ScanTelemetryHonesty(isRealDevice: true)
    private let simulated = ScanTelemetryHonesty(isRealDevice: false)

    @Test("Completed scan count uses user-facing frame wording and correct plurality")
    func scannedFramesLabelUsesCorrectPlurality() {
        #expect(ScanTelemetryHonesty.scannedFramesLabel(0) == "0 frames scanned")
        #expect(ScanTelemetryHonesty.scannedFramesLabel(1) == "1 frame scanned")
        #expect(ScanTelemetryHonesty.scannedFramesLabel(2) == "2 frames scanned")
    }

    @Test("Simulator surfaces its genuine per-frame fraction on the in-flight frame")
    func simulatorShowsLiveFramePercent() {
        #expect(simulated.liveFramePercent(reported: 42, isInFlightFrame: true) == 42)
    }

    @Test("Simulator still suppresses the fraction for a frame that is not in flight")
    func simulatorHidesFramePercentWhenNotInFlight() {
        #expect(simulated.liveFramePercent(reported: 42, isInFlightFrame: false) == nil)
    }

    @Test("Real hardware never shows a per-frame percentage, even for the in-flight frame")
    func realHardwareNeverShowsFramePercent() {
        #expect(real.liveFramePercent(reported: 42, isInFlightFrame: true) == nil)
        #expect(real.liveFramePercent(reported: 0, isInFlightFrame: true) == nil)
    }

    @Test("Live pass count is simulator-only")
    func passCountIsSimulatorOnly() {
        #expect(simulated.showsLivePassCount == true)
        #expect(real.showsLivePassCount == false)
    }

    @Test("Live ETA is simulator-only")
    func etaIsSimulatorOnly() {
        #expect(simulated.showsLiveEta == true)
        #expect(real.showsLiveEta == false)
    }

    @Test("The simulated histogram is never shown on real hardware")
    func histogramIsSimulatorOnly() {
        #expect(simulated.showsSimulatedHistogram == true)
        #expect(real.showsSimulatedHistogram == false)
    }

    @Test("real hardware has neither measured frame position nor determinate batch progress")
    func realBatchPositionIsUnknown() {
        #expect(simulated.hasMeasuredCurrentFramePosition)
        #expect(simulated.hasDeterminateBatchProgress)
        #expect(!real.hasMeasuredCurrentFramePosition)
        #expect(!real.hasDeterminateBatchProgress)
    }

    @Test("real current frame ignores the pre-motion report and requires an explicit active state")
    func realCurrentFrameRequiresActiveState() {
        #expect(
            real.currentFrameIndex(
                reported: 39,
                frameStates: [:]
            ) == nil
        )
        #expect(
            real.currentFrameIndex(
                reported: 39,
                frameStates: [7: .active]
            ) == 7
        )
        #expect(
            real.currentFrameIndex(
                reported: 39,
                frameStates: [7: .active, 8: .active]
            ) == nil
        )
        #expect(
            simulated.currentFrameIndex(
                reported: 4,
                frameStates: [:]
            ) == 4
        )
    }
}
