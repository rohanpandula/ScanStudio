import Foundation
import Testing
@testable import ScanStudioKit

@Suite("Control host decision")
struct HostDecisionTests {
    private let gui = ControlHelloResult(schemaVersion: 1, appName: "ScanStudio", host: .gui, hostPid: 11)
    private let headless = ControlHelloResult(schemaVersion: 1, appName: "ScanStudio", host: .headless, hostPid: 12)

    @Test("live hello selects the host mode")
    func liveModes() {
        #expect(ControlHostDecision.plan(command: "scan.start", preference: .auto, hello: gui) == .attach(.attachGUI))
        #expect(ControlHostDecision.plan(command: "scan.start", preference: .auto, hello: headless) == .attach(.attachHeadless))
    }

    @Test("headless refuses a live GUI")
    func headlessGuiRefusal() {
        #expect(ControlHostDecision.plan(command: "scan.start", preference: .headlessOnly, hello: gui) == .refuseGUIHostUnderHeadless(hostPid: 11))
    }

    @Test("read-only commands never auto-start")
    func readOnlyCommands() {
        for command in ["status", "events", "frames.list", "settings.get", "outputs.get", "roll.list", "diagnostics.export", "job.get", "wait", "scan.preflight", "link.health", "session.export"] {
            #expect(ControlHostDecision.isReadOnly(command))
            #expect(ControlHostDecision.plan(command: command, preference: .auto, hello: nil) == .refuseUnreachable(startable: true))
        }
        // `status --refresh` still reaches the runner as the public `status` label.
        #expect(ControlHostDecision.isReadOnly("status"))
    }

    @Test("attach-only never launches")
    func attachOnly() {
        #expect(ControlHostDecision.plan(command: "scan.start", preference: .attachOnly, hello: nil) == .refuseUnreachable(startable: true))
    }

    @Test("mutating command starts only when no host answers")
    func mutatingAutoStarts() {
        #expect(ControlHostDecision.plan(command: "scan.start", preference: .auto, hello: nil) == .autoStart)
    }

    @Test("resolution launches once and reports the launched host")
    func launcherCount() async throws {
        let prober = FakeProber(results: [nil, nil, nil, ControlHelloResult(schemaVersion: 1, appName: "ScanStudio", host: .headless, hostPid: 99)])
        let launcher = FakeLauncher()
        let result = try await ControlHostDecision.resolve(command: "scan.start", socketPath: "/tmp/test.sock", preference: .auto, prober: prober, launcher: launcher)
        #expect(result.mode == .attachHeadless)
        #expect(result.hostStarted)
        #expect(result.hostPid == 99)
        #expect(launcher.count == 1)
    }

    @Test("launcher preserves a typed refusal from its child")
    func typedChildRefusal() throws {
        let data = Data(#"{"error":{"code":"HOST_ALREADY_RUNNING","message":"busy","recoverable":false}}"#.utf8)
        let error = try #require(LiveControlHostLauncher.decisionError(from: data))
        #expect(error.payload.code == ControlCLIErrorCode.hostAlreadyRunning.rawValue)
        #expect(error.exitCode == ControlCLIExitCode.busy)
    }

    private final class FakeProber: ControlHostProbing, @unchecked Sendable {
        var results: [ControlHelloResult?]
        init(results: [ControlHelloResult?]) { self.results = results }
        func probe(path: String) async -> ControlHelloResult? { results.isEmpty ? nil : results.removeFirst() }
    }

    private final class FakeLauncher: ControlHostLaunching, @unchecked Sendable {
        var count = 0
        func launchDetachedHeadlessHost(socketPath: String, logPath: String?) async throws -> ControlHostLaunchRecord {
            count += 1
            return ControlHostLaunchRecord(hostPid: 99, logPath: logPath ?? "/tmp/host.log")
        }
    }
}
