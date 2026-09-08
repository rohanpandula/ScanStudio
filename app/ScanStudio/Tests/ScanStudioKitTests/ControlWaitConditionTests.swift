import Foundation
import Testing
@testable import ScanStudioKit

private func waitStatus(
    device: DeviceInfo? = nil,
    scanner: ScannerStatus? = ScannerStatus(
        connected: true,
        adapter: "SA-21",
        mediaLoaded: false,
        carrier: nil,
        frameCount: nil,
        lamp: "unknown",
        transport: "idle",
        activeJobId: nil,
        filmPresent: false,
        motionArmed: true
    ),
    jobState: JobState? = nil,
    previewComplete: Bool = false,
    refeedRequired: Bool = false
) -> ControlStatusResult {
    ControlStatusResult(
        device: device,
        scanner: scanner,
        jobState: jobState,
        previewComplete: previewComplete,
        refeedRequired: refeedRequired,
        hardwareMotionReadiness: "ready",
        motionAllowed: true,
        selectedFrames: [],
        scanReadiness: "ready"
    )
}

@Suite("control wait conditions")
struct ControlWaitConditionTests {
    @Test("wait conditions use explicit status evidence")
    func matchesExplicitEvidence() {
        let present = waitStatus(scanner: ScannerStatus(
            connected: true,
            adapter: "SA-21",
            mediaLoaded: true,
            carrier: "mounted",
            frameCount: 36,
            lamp: "ready",
            transport: "idle",
            activeJobId: nil,
            filmPresent: true,
            motionArmed: true
        ))
        #expect(ControlWaitCondition.filmPresent.matches(present))
        #expect(!ControlWaitCondition.filmAbsent.matches(present))
        #expect(ControlWaitCondition.idle.matches(present))

        #expect(ControlWaitCondition.filmAbsent.matches(waitStatus()))
        let simulatedPresent = waitStatus(
            device: DeviceInfo(
                deviceId: "sim-ls5000-0", model: "LS-5000", kind: "simulated",
                firmware: "sim", connection: "simulator", supported: true
            ),
            scanner: ScannerStatus(
                connected: true, adapter: "sim", mediaLoaded: true, carrier: "mounted",
                frameCount: 1, lamp: "ready", transport: "idle", activeJobId: nil,
                filmPresent: nil, motionArmed: true
            )
        )
        #expect(ControlWaitCondition.filmPresent.matches(simulatedPresent))
        let realStaleMedia = waitStatus(
            device: DeviceInfo(
                deviceId: "ls5000-0", model: "LS-5000", kind: "real",
                firmware: "1", connection: "usb", supported: true
            ),
            scanner: ScannerStatus(
                connected: true, adapter: "real", mediaLoaded: true, carrier: "mounted",
                frameCount: 1, lamp: "ready", transport: "idle", activeJobId: nil,
                filmPresent: false, motionArmed: true
            )
        )
        #expect(!ControlWaitCondition.filmPresent.matches(realStaleMedia))
        #expect(ControlWaitCondition.jobDone.matches(waitStatus(jobState: .completed)))
        #expect(ControlWaitCondition.registered.matches(waitStatus(previewComplete: true)))
        #expect(!ControlWaitCondition.registered.matches(waitStatus(previewComplete: true, refeedRequired: true)))
        #expect(!ControlWaitCondition.registered.matches(waitStatus()))
    }

    @Test("event wait returns on success, timeout, and host loss")
    func eventOutcomes() async throws {
        let initial = waitStatus()
        let registered = waitStatus(previewComplete: true)
        let registeredLine = try JSONEncoder().encode(ControlEventEnvelope(
            event: "control.changed",
            payload: registered
        ))
        let success = try await ControlEventWaiter.wait(
            initial: initial,
            events: AsyncStream { continuation in
                continuation.yield(registeredLine)
                continuation.finish()
            },
            condition: .registered,
            timeout: 1
        )
        #expect(success == registered)

        do {
            _ = try await ControlEventWaiter.wait(
                initial: initial,
                events: AsyncStream { _ in },
                condition: .registered,
                timeout: 0.001
            )
            Issue.record("expected wait timeout")
        } catch let error as ControlEventWaitFailure {
            #expect(error == .timeout)
        }

        let hostExitedLine = try JSONEncoder().encode(ControlEventEnvelope(
            event: "control.hostExited",
            payload: ControlHostExitedPayload(hostPid: 42)
        ))
        do {
            _ = try await ControlEventWaiter.wait(
                initial: initial,
                events: AsyncStream { continuation in
                    continuation.yield(hostExitedLine)
                    continuation.finish()
                },
                condition: .registered,
                timeout: 1
            )
            Issue.record("expected host loss")
        } catch let error as ControlEventWaitFailure {
            #expect(error == .hostExited)
        }

        for invalidTimeout in [-1, .infinity, .nan] {
            do {
                _ = try await ControlEventWaiter.wait(
                    initial: initial,
                    events: AsyncStream { _ in },
                    condition: .registered,
                    timeout: invalidTimeout
                )
                Issue.record("expected invalid timeout to fail")
            } catch let error as ControlEventWaitFailure {
                #expect(error == .timeout)
            }
        }
    }
}
