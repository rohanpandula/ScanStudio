import Foundation
import Darwin

public enum ControlHostMode: String, Codable, Sendable, Equatable {
    case attachGUI = "attach-gui"
    case attachHeadless = "attach-headless"
    case unreached = "unreached"
}

public enum ControlHostPreference: Sendable, Equatable {
    case auto
    case attachOnly
    case headlessOnly
}

public struct ControlHostLaunchRecord: Sendable, Equatable {
    public let hostPid: Int32
    public let logPath: String

    public init(hostPid: Int32, logPath: String) {
        self.hostPid = hostPid
        self.logPath = logPath
    }
}

public protocol ControlHostProbing: Sendable {
    func probe(path: String) async -> ControlHelloResult?
}

public protocol ControlHostLaunching: Sendable {
    func launchDetachedHeadlessHost(socketPath: String, logPath: String?) async throws -> ControlHostLaunchRecord
}

public struct ControlHostResolution: Sendable, Equatable {
    public let mode: ControlHostMode
    public let hostStarted: Bool
    public let hostPid: Int32?
    public let logPath: String?
}

public struct ControlHostDecisionError: Error, Sendable, Equatable {
    public let payload: ControlErrorPayload
    public let exitCode: ControlCLIExitCode

    public init(payload: ControlErrorPayload, exitCode: ControlCLIExitCode) {
        self.payload = payload
        self.exitCode = exitCode
    }
}

public enum ControlHostDecision {
    public enum Action: Equatable, Sendable {
        case attach(ControlHostMode)
        case refuseUnreachable(startable: Bool)
        case refuseGUIHostUnderHeadless(hostPid: Int32)
        case autoStart
    }

    // `job.get` is an internal status follow-up, while status --refresh keeps
    // the public command label "status". These commands never create a host.
    public static let readOnlyCommands: Set<String> = [
        "status", "events", "wait", "frames.list", "settings.get", "outputs.get",
        "roll.list", "diagnostics.export", "job.get", "scan.preflight", "link.health", "session.export"
    ]

    public static func isReadOnly(_ command: String) -> Bool {
        readOnlyCommands.contains(command)
    }

    public static func plan(
        command: String,
        preference: ControlHostPreference,
        hello: ControlHelloResult?
    ) -> Action {
        if let hello {
            if preference == .headlessOnly, hello.host == .gui {
                return .refuseGUIHostUnderHeadless(hostPid: hello.hostPid)
            }
            return .attach(hello.host == .gui ? .attachGUI : .attachHeadless)
        }
        if preference == .attachOnly || isReadOnly(command) {
            return .refuseUnreachable(startable: true)
        }
        return .autoStart
    }

    public static func resolve(
        command: String,
        socketPath: String,
        preference: ControlHostPreference,
        logPath: String? = nil,
        prober: any ControlHostProbing = LiveControlHostProber(),
        launcher: any ControlHostLaunching = LiveControlHostLauncher()
    ) async throws -> ControlHostResolution {
        let initial = await probe(path: socketPath, using: prober)
        switch plan(command: command, preference: preference, hello: initial) {
        case .attach(let mode):
            return ControlHostResolution(mode: mode, hostStarted: false, hostPid: initial?.hostPid, logPath: nil)
        case .refuseGUIHostUnderHeadless(let pid):
            throw ControlHostDecisionError(
                payload: ControlErrorPayload(
                    code: ControlCLIErrorCode.hostAlreadyRunning.rawValue,
                    message: "A GUI host is already running (pid \(pid)).",
                    recoverable: false,
                    guidance: "Use the running app or quit it before using --headless."
                ),
                exitCode: .busy
            )
        case .refuseUnreachable:
            throw ControlHostDecisionError(
                payload: ControlErrorPayload(
                    code: ControlCLIErrorCode.hostUnreachable.rawValue,
                    message: "No ScanStudio host answered at \(socketPath).",
                    recoverable: false,
                    guidance: "Run scanstudio-cli host first, or use a mutating command to start one."
                ),
                exitCode: .noHostReachable
            )
        case .autoStart:
            do {
                let launched = try await launcher.launchDetachedHeadlessHost(socketPath: socketPath, logPath: logPath)
                guard let hello = await probe(path: socketPath, using: prober) else {
                    throw ControlHostDecisionError(
                        payload: ControlErrorPayload(
                            code: ControlCLIErrorCode.internalCode.rawValue,
                            message: "The headless host did not answer after launch.",
                            recoverable: false,
                            guidance: "Check the host log at \(launched.logPath)."
                        ),
                        exitCode: .internalError
                    )
                }
                guard hello.host == .headless, hello.hostPid == launched.hostPid else {
                    throw ControlHostDecisionError(
                        payload: ControlErrorPayload(
                            code: ControlCLIErrorCode.internalCode.rawValue,
                            message: "The launched host did not answer as the expected headless process (pid \(launched.hostPid)).",
                            recoverable: false,
                            guidance: "Check the host log at \(launched.logPath)."
                        ),
                        exitCode: .internalError
                    )
                }
                return ControlHostResolution(
                    mode: .attachHeadless,
                    hostStarted: true,
                    hostPid: launched.hostPid,
                    logPath: launched.logPath
                )
            } catch let error as ControlHostDecisionError {
                throw error
            } catch {
                throw ControlHostDecisionError(
                    payload: ControlErrorPayload(
                        code: ControlCLIErrorCode.internalCode.rawValue,
                        message: "Could not start the headless host: \(error).",
                        recoverable: false,
                        guidance: logPath.map { "Check the host log at \($0)." }
                    ),
                    exitCode: .internalError
                )
            }
        }
    }

    private static func probe(path: String, using prober: any ControlHostProbing) async -> ControlHelloResult? {
        for attempt in 0..<3 {
            if let hello = await prober.probe(path: path) { return hello }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return nil
    }
}

public struct LiveControlHostProber: ControlHostProbing {
    public init() {}

    public func probe(path: String) async -> ControlHelloResult? {
        do {
            let client = try await ControlChannelClient.open(path: path, clientName: "scanstudio-cli probe")
            let hello = await client.helloResult
            await client.shutdown()
            return hello
        } catch {
            return nil
        }
    }
}

public struct LiveControlHostLauncher: ControlHostLaunching {
    public init() {}

    public func launchDetachedHeadlessHost(socketPath: String, logPath: String?) async throws -> ControlHostLaunchRecord {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let log = logPath ?? "\(socketPath).host.log"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["host", "--detach", "--socket", socketPath, "--log", log]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = ContinuousClock.now + .seconds(15)
        do {
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !process.isRunning else {
                throw NSError(domain: "ScanStudioHost", code: 70, userInfo: [NSLocalizedDescriptionKey: "Host launcher timed out; see \(log)."])
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            if let refusal = Self.decisionError(from: data) { throw refusal }
            throw NSError(domain: "ScanStudioHost", code: Int(process.terminationStatus))
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = object["result"] as? [String: Any],
            let pid = result["hostPid"] as? Int,
            let reportedLog = result["logPath"] as? String
        else {
            throw NSError(domain: "ScanStudioHost", code: 1)
        }
        return ControlHostLaunchRecord(hostPid: Int32(pid), logPath: reportedLog)
    }

    static func decisionError(from data: Data) -> ControlHostDecisionError? {
        struct Failure: Decodable { let error: ControlErrorPayload }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: data) else { return nil }
        return ControlHostDecisionError(
            payload: failure.error,
            exitCode: .forErrorCode(failure.error.code)
        )
    }
}
