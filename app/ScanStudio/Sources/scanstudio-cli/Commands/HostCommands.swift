import ArgumentParser
import Foundation
import ScanStudioKit

#if canImport(Darwin)
import Darwin
#endif

struct Host: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host",
        abstract: "Runs a resident headless ScanStudio host.",
        subcommands: [Run.self, HostStop.self, HostService.self],
        defaultSubcommand: Run.self
    )
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run the headless host.")

    @OptionGroup var options: GlobalOptions
    @Flag(name: .customLong("detach"), help: "Start the host in the background and wait for hello.")
    var detach = false
    @Option(name: .customLong("engine"), help: "Engine executable path (development and tests).")
    var enginePath: String?
    @Option(name: .customLong("log"), help: "Detached host log path.")
    var logPath: String?
    @Flag(name: .customLong("simulator"), help: "Run without a hardware bridge or motion authorization.")
    var simulator = false

    func run() async throws {
        let socket = CommandRunner.socketPath(options)
        if detach {
            try await runDetached(socket: socket)
        } else {
            try await runResident(socket: socket)
        }
    }

    private func runDetached(socket: String) async throws {
        let resolvedLog = logPath ?? ControlHostPaths.defaultLogPath()
        try prepareLogParent(resolvedLog)
        let logDescriptor = open(resolvedLog, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard logDescriptor >= 0 else {
            try failHost(
                command: "host",
                code: ControlCLIErrorCode.internalCode.rawValue,
                message: "Could not open host log at \(resolvedLog): errno \(errno).",
                guidance: "Choose a writable path with --log and retry."
            )
        }
        var logInfo = stat()
        guard fstat(logDescriptor, &logInfo) == 0, (logInfo.st_mode & S_IFMT) == S_IFREG, logInfo.st_nlink == 1 else {
            _ = close(logDescriptor)
            try failHost(command: "host", code: ControlCLIErrorCode.internalCode.rawValue, message: "Refusing unsafe host log path \(resolvedLog).", guidance: "Choose a regular, owner-only log path and retry.")
        }
        guard fchmod(logDescriptor, mode_t(0o600)) == 0 else {
            _ = close(logDescriptor)
            try failHost(command: "host", code: ControlCLIErrorCode.internalCode.rawValue, message: "Could not set owner-only permissions on host log \(resolvedLog).", guidance: "Choose a writable log path and retry.")
        }
        let logHandle = FileHandle(fileDescriptor: logDescriptor, closeOnDealloc: true)

        let child = Process()
        child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["host", "run", "--socket", socket, "--log", resolvedLog]
            + (simulator ? ["--simulator"] : [])
            + (enginePath.map { ["--engine", $0] } ?? [])
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = logHandle
        child.standardError = logHandle
        do {
            try child.run()
        } catch {
            try failHost(command: "host", code: ControlCLIErrorCode.internalCode.rawValue, message: "Could not start the detached host: \(error).", guidance: "Read \(resolvedLog) for details.")
        }

        let expectedPid = child.processIdentifier
        do {
            let hello = try await waitForHello(socket: socket, process: child, timeout: .seconds(10))
            guard hello.hello.host == .headless, hello.hello.hostPid == expectedPid else {
                await hello.client.shutdown()
                try failHost(command: "host", code: ControlCLIErrorCode.hostAlreadyRunning.rawValue, message: "Another host won \(socket) while the detached host was starting.", guidance: "Use the running host or choose another --socket path.")
            }
            await hello.client.shutdown()
            try renderHostResult(socket: socket, logPath: resolvedLog, pid: expectedPid, detached: true)
        } catch let error as ExitCode {
            await terminate(child)
            throw error
        } catch {
            await terminate(child)
            if !child.isRunning, child.terminationStatus == ControlCLIExitCode.busy.rawValue {
                try failHost(command: "host", code: ControlCLIErrorCode.hostAlreadyRunning.rawValue, message: "Another host won \(socket) while the detached host was starting.", guidance: "Use the running host or choose another --socket path.")
            }
            try failHost(command: "host", code: ControlCLIErrorCode.internalCode.rawValue, message: "The detached host did not become ready; read \(resolvedLog).", guidance: "Read the host log and retry.")
        }
    }

    private func runResident(socket: String) async throws {
        if simulator {
            scrubHardwareEnvironment()
        } else {
            try reexecBundledHostThroughLauncherIfNeeded()
        }
        let resolvedEngine: URL
        do {
            resolvedEngine = try BundledEnginePolicy.resolve(
                cliExecutableURL: Bundle.main.executableURL?.resolvingSymlinksInPath(),
                environment: ProcessInfo.processInfo.environment,
                engineOverride: enginePath,
                fileExists: FileManager.default.fileExists(atPath:)
            )
        } catch let refusal as BundledEnginePolicy.BundledEngineRefusal {
            try failHost(command: "host", code: refusal.code, message: refusal.message, guidance: refusal.guidance)
        } catch {
            try failHost(command: "host", code: ControlCLIErrorCode.internalCode.rawValue, message: "Could not resolve the engine: \(error).", guidance: "Retry after checking the engine path.")
        }
        // This guard must precede SessionHost.launch: constructing it would
        // spawn a second engine before the server could reject the socket.
        guard !ControlSocketDialer.probeIsLive(path: socket) else {
            try failHost(command: "host", code: ControlCLIErrorCode.hostAlreadyRunning.rawValue, message: "A host already owns \(socket).", guidance: "Another ScanStudio host — the app or another `scanstudio-cli host` — already owns this socket; quit it or pass --socket.")
        }
        let sessionResult = setsid()
        if sessionResult < 0 {
            fputs("host: setsid failed (errno \(errno)); continuing\n", stderr)
        }

        let handle: SessionHost.Handle
        do {
            handle = try await SessionHost.launch(
                engineURL: resolvedEngine,
                socketPath: socket,
                diagnosticsDirectory: URL(fileURLWithPath: socket).deletingLastPathComponent().appendingPathComponent("diagnostics", isDirectory: true),
                hostKind: .headless
            )
        } catch let error as ControlSocketError where error.errnoValue == EADDRINUSE {
            try failHost(command: "host", code: ControlCLIErrorCode.hostAlreadyRunning.rawValue, message: "A host already owns \(socket).", guidance: "Another ScanStudio host already won this socket; quit it or pass --socket.")
        } catch {
            try failHost(command: "host", code: ControlCLIErrorCode.internalCode.rawValue, message: "Could not start the headless host: \(error).", guidance: "Retry after checking the engine path and host log.")
        }

        let pidfile = ControlHostPaths.pidfilePath(forSocket: socket)
        do {
            try ControlHostPidfile.write(pid: ProcessInfo.processInfo.processIdentifier, at: pidfile)
        } catch {
            await SessionHost.shutdown(handle)
            throw error
        }

        do {
            try renderHostResult(socket: socket, logPath: logPath ?? ControlHostPaths.defaultLogPath(), pid: ProcessInfo.processInfo.processIdentifier, detached: false)
            await waitForTerminationSignal()
            try ControlHostPidfile.remove(at: pidfile, ifPIDMatches: ProcessInfo.processInfo.processIdentifier)
            await SessionHost.shutdown(handle)
        } catch {
            _ = try? ControlHostPidfile.remove(at: pidfile, ifPIDMatches: ProcessInfo.processInfo.processIdentifier)
            await SessionHost.shutdown(handle)
            throw error
        }
    }

    private struct HelloConnection: Sendable {
        let client: ControlChannelClient
        let hello: ControlHelloResult
    }

    private func waitForHello(socket: String, process: Process, timeout: Duration) async throws -> HelloConnection {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !process.isRunning { throw ControlChannelClientError.connectionClosed }
            do {
                let connection = try await openWithTimeout(path: socket, timeout: .seconds(1))
                if let hello = await connection.helloResult {
                    return HelloConnection(client: connection, hello: hello)
                }
                await connection.shutdown()
            } catch {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw ControlChannelClientError.connectionClosed
    }

    private func openWithTimeout(path: String, timeout: Duration) async throws -> ControlChannelClient {
        try await ControlChannelClient.open(
            path: path, clientName: options.resolvedControllerName, helloTimeout: timeout
        )
    }

    private func prepareLogParent(_ path: String) throws {
        let root = ControlSocketPath.directoryURL().path
        if (path as NSString).deletingLastPathComponent == root + "/logs" {
            try ControlSocketPath.prepareDirectory(for: ControlSocketPath.defaultPath())
        }
        try ControlSocketPath.prepareDirectory(for: path)
    }

    private func scrubHardwareEnvironment() {
        for key in [
            "SCANSTUDIO_BRIDGE_CMD", "SCANSTUDIO_HW_MOTION", "SCANSTUDIO_BRIDGE_SOURCE",
            "SCANSTUDIO_BRIDGE_PYTHON", "SCANSTUDIO_BRIDGE_TRANSPORT", "SCANSTUDIO_BRIDGE_BASE_DIR"
        ] {
            unsetenv(key)
        }
    }

    /// A packaged host gets the same bridge and motion setup as the GUI by
    /// re-entering the existing launcher. Loose development binaries keep
    /// their current environment and explicit engine override behavior.
    private func reexecBundledHostThroughLauncherIfNeeded() throws {
        guard ProcessInfo.processInfo.environment["SCANSTUDIO_CLI_BOOTSTRAPPED"] != "1",
              let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return }
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return }

        let launcher = macOS.appendingPathComponent("ScanStudioLauncher").path
        guard FileManager.default.isExecutableFile(atPath: launcher) else {
            throw ControlSocketError(context: "packaged host launcher is missing at \(launcher)", errnoValue: ENOENT)
        }
        let strings = [launcher, "--cli"] + Array(CommandLine.arguments.dropFirst())
        let pointers = strings.map { string in string.withCString { strdup($0) } }
        defer { pointers.forEach { free($0) } }
        var arguments = pointers + [nil]
        launcher.withCString { _ = execv($0, &arguments) }
        throw ControlSocketError(context: "execv(\(launcher))", errnoValue: errno)
    }

    private func renderHostResult(socket: String, logPath: String, pid: Int32, detached: Bool) throws {
        let rendered = try ControlCLIOutput.renderResult(command: "host", resultJSON: [
            "host": "headless", "hostPid": Int(pid), "socketPath": socket, "logPath": logPath, "detached": detached
        ], human: options.human)
        print(rendered, terminator: "")
    }

    private func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }

    private func failHost(command: String, code: String, message: String, guidance: String?) throws -> Never {
        let payload = ControlErrorPayload(code: code, message: message, recoverable: false, guidance: guidance)
        let rendered = try ControlCLIOutput.renderError(command: command, payload: payload, human: options.human)
        print(rendered, terminator: "")
        throw ExitCode(ControlCLIExitCode.forErrorCode(code).rawValue)
    }
}

struct HostStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the resident headless host.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let socket = CommandRunner.socketPath(options)
        let pidfile = ControlHostPaths.pidfilePath(forSocket: socket)
        let recordedPid: Int32?
        do {
            recordedPid = try ControlHostPidfile.read(at: pidfile)
        } catch {
            try fail(code: ControlCLIErrorCode.hostUnreachable.rawValue, message: "Could not read host pidfile \(pidfile): \(error).", guidance: "Start a host, then retry.")
        }

        let client: ControlChannelClient?
        do { client = try await openWithTimeout(path: socket, timeout: .seconds(1)) } catch { client = nil }
        let hello = await client?.helloResult
        let decision = ControlHostStopDecision.decide(recordedPid: recordedPid, hello: hello)
        switch decision {
        case .noPidfile:
            try fail(code: ControlCLIErrorCode.hostUnreachable.rawValue, message: "No host pidfile exists at \(pidfile).", guidance: "Start a host, then retry.")
        case .stalePidfile(let pid, let reason):
            await client?.shutdown()
            try fail(code: ControlCLIErrorCode.hostUnreachable.rawValue, message: "Stale pidfile for pid \(pid): \(reason).", guidance: "Start or stop the host that owns this socket, then retry.")
        case .refuseGuiHost(let pid):
            await client?.shutdown()
            try fail(code: ControlCLIErrorCode.hostAlreadyRunning.rawValue, message: "The socket is served by the ScanStudio app (pid \(pid)); quit the app instead.", guidance: "Quit ScanStudio, then retry.")
        case .signal(let pid):
            await client?.shutdown()
            guard kill(pid, SIGTERM) == 0 else {
                try fail(code: ControlCLIErrorCode.hostUnreachable.rawValue, message: "Could not signal host pid \(pid): errno \(errno).", guidance: "Inspect the pidfile and retry.")
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while ControlSocketDialer.probeIsLive(path: socket), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !ControlSocketDialer.probeIsLive(path: socket) else {
                try fail(code: ControlCLIErrorCode.internalCode.rawValue, message: "Host pid \(pid) did not release \(socket).", guidance: "Read the host log and retry.")
            }
            let rendered = try ControlCLIOutput.renderResult(command: "host stop", resultJSON: ["stopped": true, "hostPid": Int(pid)], human: options.human)
            print(rendered, terminator: "")
        }
    }

    private func openWithTimeout(path: String, timeout: Duration) async throws -> ControlChannelClient {
        try await ControlChannelClient.open(
            path: path, clientName: options.resolvedControllerName, helloTimeout: timeout
        )
    }

    private func fail(code: String, message: String, guidance: String?) throws -> Never {
        let payload = ControlErrorPayload(code: code, message: message, recoverable: false, guidance: guidance)
        let rendered = try ControlCLIOutput.renderError(command: "host stop", payload: payload, human: options.human)
        print(rendered, terminator: "")
        throw ExitCode(ControlCLIExitCode.forErrorCode(code).rawValue)
    }
}

private final class SignalLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []

    func install(_ continuation: CheckedContinuation<Void, Never>, sources: [DispatchSourceSignal]) {
        lock.lock(); self.continuation = continuation; self.sources = sources; lock.unlock()
    }

    func fire() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let sources = self.sources
        self.sources.removeAll()
        lock.unlock()
        sources.forEach { $0.cancel() }
        continuation?.resume()
    }
}

private func waitForTerminationSignal() async {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let latch = SignalLatch()
        let sources = [SIGTERM, SIGINT].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { latch.fire() }
            return source
        }
        latch.install(continuation, sources: sources)
        sources.forEach { $0.resume() }
    }
}
