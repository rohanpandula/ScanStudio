import Foundation

/// Decides which pieces of LIVE scan telemetry a given device kind may
/// honestly display, based on what each backend actually reports over the
/// wire. The rule this encodes: the interface must never assert more than
/// the engine knows.
///
/// The simulator (`sim.rs`) computes every telemetry field genuinely from its
/// own elapsed/total timers — per-frame fraction, current pass, ETA, all of
/// it. A real LS-5000 (`real_backend.rs`) does not: its entire `scan.progress`
/// burst fires up front, before hardware ever moves, so the engine
/// deliberately hardcodes the fields it cannot know — `frame_percent` and
/// `eta_seconds` to `0.0`, `pass` to `1` (with `total_passes` merely echoing
/// the request recipe rather than a real per-pass count). Its upfront burst
/// also names frames before motion, while the bridge may later shrink the
/// attempted subset. Consequently, the real backend has neither a measured
/// current-frame position nor a determinate live batch percentage. Rendering
/// any of those fields as live measurements would fabricate progress.
///
/// Lives in ScanStudioKit (not the app target) so the contract is unit-tested
/// directly (`ScanTelemetryHonestyTests`) rather than only exercisable through
/// SwiftUI views. Pure and `Sendable`: no SwiftUI, no engine I/O.
public struct ScanTelemetryHonesty: Equatable, Sendable {
    /// `true` for a real LS-5000 (`device.kind == "real"`), `false` for the
    /// simulator. Every decision below keys off this single fact.
    public let isRealDevice: Bool

    public init(isRealDevice: Bool) {
        self.isRealDevice = isRealDevice
    }

    /// A genuine, continuously live per-frame completion fraction exists only
    /// on the simulator. `isInFlightFrame` must already encode "this tile is
    /// the one `scan.progress` currently names" (`frameState == .active` and
    /// matching `frameIndex`). Returns `nil` — meaning "render coarse state
    /// only," never "assume zero" — whenever the value would be fabricated.
    public func liveFramePercent(reported: Double, isInFlightFrame: Bool) -> Double? {
        guard !isRealDevice, isInFlightFrame else { return nil }
        return reported
    }

    /// A live "Pass N of M" counter is genuine only on the simulator. A real
    /// backend hardcodes `pass` to `1` and echoes the request recipe for
    /// `total_passes`, so "1 of 2" would assert a current-pass position the
    /// engine never tracks.
    public var showsLivePassCount: Bool { !isRealDevice }

    /// A live ETA is genuine only on the simulator. A real backend hardcodes
    /// `eta_seconds` to `0.0` — its own "honest unknown" convention, never a
    /// real estimate — so displaying it would read as "0 seconds remaining."
    public var showsLiveEta: Bool { !isRealDevice }

    /// A real progress burst names requested slots before physical movement;
    /// it cannot establish which frame is currently under the scan head.
    public var hasMeasuredCurrentFramePosition: Bool { !isRealDevice }

    /// Simulation trusts its measured progress index. Real hardware ignores
    /// the pre-motion report and names a frame only when an explicit
    /// `scan.frameState(.active)` event proves it.
    public func currentFrameIndex(
        reported: Int?,
        frameStates: [Int: FrameState]
    ) -> Int? {
        if hasMeasuredCurrentFramePosition {
            return reported
        }
        let activeFrames = frameStates.compactMap { entry in
            entry.value == .active ? entry.key : nil
        }
        guard activeFrames.count == 1 else { return nil }
        return activeFrames[0]
    }

    /// A real batch's attempted subset may shrink after the request, so its
    /// original requested total is not a determinate physical progress total.
    public var hasDeterminateBatchProgress: Bool { !isRealDevice }

    /// The live histogram is fabricated procedural art on EVERY device (no
    /// pixel pipeline reads real scanner pixels into a waveform). It is still
    /// truthful-to-simulator to label and show it there, but it must never be
    /// shown on real hardware.
    public var showsSimulatedHistogram: Bool { !isRealDevice }
}
