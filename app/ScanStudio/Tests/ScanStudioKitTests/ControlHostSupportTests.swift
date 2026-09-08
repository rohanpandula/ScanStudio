import Foundation
import Testing
import Darwin

@testable import ScanStudioKit

@Suite("Control host support")
struct ControlHostSupportTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scanstudio-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test("pidfile round-trips with owner-only mode")
    func pidfileRoundTrip() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("host.pid").path
        try ControlHostPidfile.write(pid: 1234, at: path)
        #expect(try ControlHostPidfile.read(at: path) == 1234)
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test("missing and garbage pidfiles are handled distinctly")
    func missingAndGarbage() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("host.pid").path
        #expect(try ControlHostPidfile.read(at: path) == nil)
        try Data("garbage\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: ControlSocketError.self) { try ControlHostPidfile.read(at: path) }
    }

    @Test("pidfile reads and writes refuse symlinks")
    func symlinkRefusal() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target").path
        let path = root.appendingPathComponent("host.pid").path
        try Data("1234\n".utf8).write(to: URL(fileURLWithPath: target))
        #expect(symlink(target, path) == 0)
        #expect(throws: ControlSocketError.self) { try ControlHostPidfile.read(at: path) }
        #expect(throws: ControlSocketError.self) { try ControlHostPidfile.write(pid: 1234, at: path) }
    }

    @Test("removing a missing pidfile is harmless")
    func removeMissing() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try ControlHostPidfile.remove(at: root.appendingPathComponent("missing.pid").path)
    }

    @Test("pidfile cleanup removes only the resident's pid")
    func removeMatchingPID() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("host.pid").path
        try ControlHostPidfile.write(pid: 1234, at: path)
        #expect(try !ControlHostPidfile.remove(at: path, ifPIDMatches: 5678))
        #expect(try ControlHostPidfile.read(at: path) == 1234)
        #expect(try ControlHostPidfile.remove(at: path, ifPIDMatches: 1234))
        #expect(try ControlHostPidfile.read(at: path) == nil)
    }

    @Test("stop decision has no pidfile outcome")
    func noPidfile() {
        #expect(ControlHostStopDecision.decide(recordedPid: nil, hello: nil) == .noPidfile)
    }

    @Test("stop decision rejects an unanswered socket")
    func staleNoHello() {
        #expect(ControlHostStopDecision.decide(recordedPid: 1234, hello: nil) == .stalePidfile(recordedPid: 1234, reason: "no host is answering the control socket"))
    }

    @Test("stop decision refuses a GUI host")
    func guiHost() {
        let hello = ControlHelloResult(schemaVersion: ControlSchema.version, appName: "ScanStudio", host: .gui, hostPid: 1234)
        #expect(ControlHostStopDecision.decide(recordedPid: 1234, hello: hello) == .refuseGuiHost(hostPid: 1234))
    }

    @Test("stop decision rejects a live pid mismatch")
    func pidMismatch() {
        let hello = ControlHelloResult(schemaVersion: ControlSchema.version, appName: "ScanStudio", host: .headless, hostPid: 5678)
        #expect(ControlHostStopDecision.decide(recordedPid: 1234, hello: hello) == .stalePidfile(recordedPid: 1234, reason: "the live host reports pid 5678, the pidfile records 1234 — the pid may have been reused"))
    }

    @Test("stop decision signals only a matching headless host")
    func signal() {
        let hello = ControlHelloResult(schemaVersion: ControlSchema.version, appName: "ScanStudio", host: .headless, hostPid: 1234)
        #expect(ControlHostStopDecision.decide(recordedPid: 1234, hello: hello) == .signal(pid: 1234))
    }

    @Test("host already running maps to busy")
    func hostAlreadyRunningExitCode() {
        #expect(ControlCLIExitCode.forErrorCode("HOST_ALREADY_RUNNING") == .busy)
    }
}
