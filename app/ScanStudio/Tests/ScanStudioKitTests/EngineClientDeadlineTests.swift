import Darwin
import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Engine client deadlines", .serialized)
struct EngineClientDeadlineTests {
    @Test("a silent engine request fails with a typed deadline error")
    func silentRequestTimesOut() async throws {
        let fixture = try SilentEngineFixture()
        defer { fixture.remove() }

        let client = try EngineClient(
            engineURL: fixture.executableURL,
            configuration: EngineClientConfiguration(
                requestTimeout: .milliseconds(100),
                gracefulShutdownTimeout: .milliseconds(50),
                terminateTimeout: .milliseconds(50),
                forceKillTimeout: .seconds(1)
            )
        )
        let clock = ContinuousClock()
        let started = clock.now

        do {
            let _: HelloResult = try await client.request(
                "engine.hello",
                params: HelloParams(clientName: "deadline-test", protocolVersion: 1)
            )
            Issue.record("Expected the silent engine request to time out")
        } catch let error as EngineRequestError {
            #expect(error.code == "ENGINE_REQUEST_TIMEOUT")
            #expect(error.recoverable)
            #expect(error.message.contains("engine.hello"))
        } catch {
            Issue.record("Expected EngineRequestError, received \(error)")
        }

        let elapsed = started.duration(to: clock.now)
        #expect(elapsed >= .milliseconds(50))
        #expect(elapsed < .seconds(2))
        await client.terminate()
    }

    @Test("shutdown kills and reaps an engine that ignores graceful shutdown and SIGTERM")
    func forcedShutdownIsBoundedAndReaped() async throws {
        let fixture = try SilentEngineFixture()
        defer { fixture.remove() }

        let client = try EngineClient(
            engineURL: fixture.executableURL,
            configuration: EngineClientConfiguration(
                requestTimeout: .seconds(5),
                gracefulShutdownTimeout: .milliseconds(100),
                terminateTimeout: .milliseconds(100),
                forceKillTimeout: .seconds(1)
            )
        )
        let pid = try await fixture.waitForPID()
        #expect(Darwin.kill(pid, 0) == 0, "the fake engine must be alive before shutdown")

        let clock = ContinuousClock()
        let started = clock.now
        await client.terminate()
        let elapsed = started.duration(to: clock.now)

        errno = 0
        let probe = Darwin.kill(pid, 0)
        let probeErrno = errno
        #expect(probe == -1)
        #expect(probeErrno == ESRCH, "a reaped child must no longer have a process-table entry")
        #expect(elapsed >= .milliseconds(150), "the fake must survive both cooperative phases")
        #expect(elapsed < .seconds(2), "shutdown must stay within its fixed escalation bound")

        // Idempotence is part of safe app teardown: a second caller waits on
        // the completed termination task rather than touching the reaped PID.
        await client.terminate()
    }

    @Test("a stopped observation never enters a blocking secondary wait")
    func stoppedObservationDoesNotBlockTermination() async throws {
        let fixture = try SilentEngineFixture()
        defer { fixture.remove() }

        var configuration = EngineClientConfiguration(
            requestTimeout: .seconds(5),
            gracefulShutdownTimeout: .milliseconds(50),
            terminateTimeout: .milliseconds(50),
            forceKillTimeout: .milliseconds(100)
        )
        // Model the observed Foundation race: `isRunning` has flipped false,
        // but a subsequent `waitUntilExit` would still block waiting for a
        // delayed internal exit notification.
        configuration.processIsRunningOverride = { _ in false }
        let client = try EngineClient(
            engineURL: fixture.executableURL,
            configuration: configuration
        )
        let pid = try await fixture.waitForPID()
        let cleanup = Task.detached {
            try? await Task.sleep(for: .milliseconds(750))
            _ = Darwin.kill(pid, SIGKILL)
        }

        let clock = ContinuousClock()
        let started = clock.now
        await client.terminate()
        let elapsed = started.duration(to: clock.now)
        await cleanup.value
        try await fixture.waitUntilReaped(pid: pid)

        #expect(
            elapsed < .milliseconds(250),
            "a stopped observation must not cross into an unbounded Foundation wait"
        )
    }

    @Test("shutdown stays bounded when Process never reports exit")
    func neverStoppedObservationStillHonorsDeadlines() async throws {
        let fixture = try SilentEngineFixture()
        defer { fixture.remove() }

        var configuration = EngineClientConfiguration(
            requestTimeout: .seconds(5),
            gracefulShutdownTimeout: .milliseconds(50),
            terminateTimeout: .milliseconds(50),
            forceKillTimeout: .milliseconds(100)
        )
        configuration.processIsRunningOverride = { _ in true }
        let client = try EngineClient(
            engineURL: fixture.executableURL,
            configuration: configuration
        )
        let pid = try await fixture.waitForPID()

        let clock = ContinuousClock()
        let started = clock.now
        await client.terminate()
        let elapsed = started.duration(to: clock.now)

        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(1), "all three shutdown phases must remain deadline-bounded")
        try await fixture.waitUntilReaped(pid: pid)
    }
}

/// A hardware-free executable that reads (and ignores) every NDJSON request,
/// ignores SIGTERM, and remains alive after stdin closes. `EngineClient` can
/// stop it only by reaching its SIGKILL fallback.
private struct SilentEngineFixture {
    let directoryURL: URL
    let executableURL: URL
    let pidURL: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScanStudio-EngineClientDeadlineTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let executable = directory.appendingPathComponent("silent-engine")
        let script = """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' "$$" > "${0}.pid"
        while IFS= read -r ignored; do
            :
        done
        exec /usr/bin/tail -f /dev/null
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        directoryURL = directory
        executableURL = executable
        pidURL = URL(fileURLWithPath: executable.path + ".pid")
    }

    func waitForPID() async throws -> pid_t {
        for _ in 0..<200 {
            if let contents = try? String(contentsOf: pidURL, encoding: .utf8),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureError.pidWasNotPublished
    }

    func waitUntilReaped(pid: pid_t) async throws {
        for _ in 0..<200 {
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureError.processWasNotReaped
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    enum FixtureError: Error {
        case pidWasNotPublished
        case processWasNotReaped
    }
}
