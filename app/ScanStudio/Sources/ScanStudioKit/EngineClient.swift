// Spawns and speaks NDJSON to the `scanstudio-engine` subprocess
// (protocol/PROTOCOL.md v1) over its stdin/stdout pipes.
//
// `engine.hello` must be the first request on any connection (the engine
// answers everything else with INVALID_PARAMS until it sees one) — that
// handshake is intentionally an internal implementation detail of
// `request(_:params:)` rather than something every caller has to remember,
// so `SessionModel` (and every other caller) can just call
// `request("scanner.list", ...)` etc. directly.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Fixed deadlines for the subprocess boundary. Production responses are
/// prompt acknowledgements (long-running capture work is reported by
/// events), so a response that exceeds `requestTimeout` is no longer allowed
/// to retain a continuation forever. The shorter shutdown phases keep app
/// termination bounded while still giving the engine a chance to clean up.
public struct EngineClientConfiguration: Sendable {
    public var requestTimeout: Duration
    public var gracefulShutdownTimeout: Duration
    public var terminateTimeout: Duration
    public var forceKillTimeout: Duration
    /// Internal test seam for Foundation `Process` observation races. The
    /// production default always reads `Process.isRunning` directly.
    var processIsRunningOverride: (@Sendable (Process) -> Bool)?

    public init(
        requestTimeout: Duration = .seconds(60),
        gracefulShutdownTimeout: Duration = .milliseconds(750),
        terminateTimeout: Duration = .milliseconds(250),
        forceKillTimeout: Duration = .milliseconds(500)
    ) {
        self.requestTimeout = requestTimeout
        self.gracefulShutdownTimeout = gracefulShutdownTimeout
        self.terminateTimeout = terminateTimeout
        self.forceKillTimeout = forceKillTimeout
        self.processIsRunningOverride = nil
    }
}

/// A single already-line-framed byte sequence read from the engine's
/// stdout, buffered independently of everything else so it's directly
/// unit-testable (see `LineFramingTests`) with no process/pipe involved.
public struct LineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Feeds a chunk of raw bytes read from the pipe. Returns zero or more
    /// complete, UTF-8-decoded lines (newline stripped); any trailing
    /// partial line is retained internally for the next `feed` call.
    public mutating func feed(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }
}

/// An unsolicited engine event, still in raw-line form. `name` is the
/// `event` field, decoded eagerly so `SessionModel` can `switch` on it;
/// `rawLine` is the full original line, re-decoded by each consumer against
/// the specific `EventEnvelope<Payload>` shape it expects. Unknown event
/// names are yielded exactly like known ones — recognition/filtering is the
/// consumer's job (this is what makes unknown events inert rather than
/// thrown, per D-14).
public struct EngineEvent: Sendable {
    public let name: String
    public let rawLine: Data
}

/// Minimal engine boundary consumed by `SessionModel`. Keeping this seam
/// protocol-shaped lets lifecycle policy be tested without spawning the
/// production subprocess client.
public protocol EngineClientProtocol: Sendable {
    var events: AsyncStream<EngineEvent> { get }
    var engineVersion: String? { get async }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result
}

/// Actor wrapping `Foundation.Process` + `Pipe`s: async
/// `request(method:params:)` matched by id via continuations, plus an
/// `AsyncStream` of decoded events (D-04).
public actor EngineClient {
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let configuration: EngineClientConfiguration

    private var lineFramer = LineFramer()
    private var nextRequestId: UInt64 = 0
    private var pendingRequests: [UInt64: PendingRequest] = [:]
    private var handshakeTask: Task<Void, Error>?
    private var terminationHandled = false
    private var stdinClosed = false
    private var terminationTask: Task<Void, Never>?

    /// The engine's self-reported version from `engine.hello`, retained so
    /// callers (e.g. `SessionModel`) can surface it instead of the connect
    /// flow discarding data the engine already sends on every connection.
    public private(set) var engineVersion: String?

    private let eventsContinuation: AsyncStream<EngineEvent>.Continuation
    public nonisolated let events: AsyncStream<EngineEvent>

    public init(
        engineURL: URL,
        configuration: EngineClientConfiguration = EngineClientConfiguration()
    ) throws {
        // `Process`/`Pipe` do not ignore SIGPIPE for you: a write to
        // `stdinHandle` that races the child process exiting (e.g. a
        // request in flight when `terminate()` tears the process down, or
        // any caller writing after an unexpected exit) hits a broken pipe
        // and, with SIGPIPE at its default disposition, kills this whole
        // process rather than surfacing as a normal thrown error from
        // `FileHandle.write(contentsOf:)`. Ignoring it process-wide (safe
        // to call repeatedly — a global signal disposition, not per-client
        // state) is the standard fix so a broken-pipe write degrades to an
        // EPIPE error `performRequest`'s existing `do`/`catch` already
        // handles, instead of a process-level crash.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = engineURL
        process.arguments = []

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        var continuation: AsyncStream<EngineEvent>.Continuation!
        let stream = AsyncStream<EngineEvent> { cont in
            continuation = cont
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.configuration = configuration
        self.events = stream
        self.eventsContinuation = continuation

        try process.run()

        // All stored properties are set at this point, so `self` may now be
        // captured (weakly, to avoid a retain cycle through
        // stdoutPipe -> readabilityHandler -> self -> stdoutPipe).
        let stdoutHandleForClosure = self.stdoutHandle
        stdoutHandleForClosure.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                Task { await self.handleProcessTermination() }
            } else {
                Task { await self.feedIncoming(data) }
            }
        }
    }

    /// Sends `{id, method, params}` and awaits the matching `{id, result}` /
    /// `{id, error}` response. Every call (other than `engine.hello` itself)
    /// first ensures the handshake has completed, so callers never need to
    /// think about connection bootstrapping.
    public func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params: Params
    ) async throws -> Result {
        guard !terminationHandled, terminationTask == nil else {
            throw Self.clientTerminatedError
        }
        if method != "engine.hello" {
            try await ensureHandshake()
        }
        return try await performRequest(method, params: params)
    }

    // MARK: - Handshake

    private func ensureHandshake() async throws {
        if let handshakeTask {
            try await handshakeTask.value
            return
        }
        let task = Task<Void, Error> {
            let params = HelloParams(clientName: "ScanStudio", protocolVersion: 1)
            let result: HelloResult = try await self.performRequest("engine.hello", params: params)
            try Self.validateHandshake(result)
            self.engineVersion = result.engineVersion
        }
        handshakeTask = task
        try await task.value
    }

    private static func validateHandshake(_ result: HelloResult) throws {
        guard result.protocolVersion == 1 else {
            throw EngineCompatibilityError(
                reason: "This app supports protocol version 1, but the engine reports version \(result.protocolVersion)."
            )
        }
        guard result.engineName == "scanstudio-engine" else {
            throw EngineCompatibilityError(
                reason: "Expected the Scan Studio engine, but received \"\(result.engineName)\"."
            )
        }
        guard result.capabilities.contains("simulated-ls5000") else {
            throw EngineCompatibilityError(
                reason: "The engine does not provide the required simulated-ls5000 capability."
            )
        }
    }

    // MARK: - Request/response plumbing

    private func performRequest<Params: Encodable, Result: Decodable>(_ method: String, params: Params) async throws -> Result {
        guard !terminationHandled, terminationTask == nil else {
            throw Self.clientTerminatedError
        }
        nextRequestId += 1
        let id = nextRequestId
        let envelope = RequestEnvelope(id: id, method: method, params: params)

        let responseData: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let requestTimeout = configuration.requestTimeout
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: requestTimeout)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self?.timeoutRequest(id: id, method: method)
                }
                pendingRequests[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                do {
                    var line = try JSONEncoder().encode(envelope)
                    line.append(0x0A)
                    try stdinHandle.write(contentsOf: line)
                } catch {
                    if let pending = pendingRequests.removeValue(forKey: id) {
                        pending.timeoutTask.cancel()
                        pending.continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }

        let envelope2 = try JSONDecoder().decode(ResponseEnvelope<Result>.self, from: responseData)
        return envelope2.result
    }

    /// Removes before resuming so a response, timeout, cancellation, and
    /// process exit can race without ever double-resuming a continuation.
    private func timeoutRequest(id: UInt64, method: String) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: EngineRequestError(
            code: "ENGINE_REQUEST_TIMEOUT",
            message: "Engine request \"\(method)\" (id \(id)) exceeded its response deadline.",
            recoverable: true
        ))
    }

    private func cancelRequest(id: UInt64) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: CancellationError())
    }

    // MARK: - Incoming data handling

    private func feedIncoming(_ data: Data) {
        let lines = lineFramer.feed(data)
        for line in lines {
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return }

        // Malformed/unrecognized lines must never crash the read loop or
        // the app (T-02-01) — decode failures here are simply dropped.
        guard let sniff = try? JSONDecoder().decode(WireSniff.self, from: data) else {
            return
        }

        if let eventName = sniff.event {
            eventsContinuation.yield(EngineEvent(name: eventName, rawLine: data))
            return
        }

        guard let id = sniff.id else { return }
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()

        // Attempt the error shape first; fall back to treating the line as
        // a success response otherwise (either resolves unambiguously since
        // a response is always exactly one or the other).
        if let errorEnvelope = try? JSONDecoder().decode(ResponseErrorEnvelope.self, from: data) {
            pending.continuation.resume(throwing: EngineRequestError(
                code: errorEnvelope.error.code,
                message: errorEnvelope.error.message,
                recoverable: errorEnvelope.error.recoverable
            ))
        } else {
            pending.continuation.resume(returning: data)
        }
    }

    private func handleProcessTermination() {
        guard !terminationHandled else { return }
        terminationHandled = true
        stdoutHandle.readabilityHandler = nil

        // T-02-02: pending continuations must be resumed with an error, not
        // leaked, if the child process exits unexpectedly.
        failAllPendingRequests(with: EngineRequestError(
            code: "ENGINE_TERMINATED",
            message: "The scanstudio-engine process exited unexpectedly.",
            recoverable: false
        ))
        let terminationEvent = Data(
            #"{"event":"engine.terminated","payload":{"code":"ENGINE_TERMINATED","message":"The scanstudio-engine process exited unexpectedly."}}"#.utf8
        )
        eventsContinuation.yield(EngineEvent(name: "engine.terminated", rawLine: terminationEvent))
        eventsContinuation.finish()
    }

    private func failAllPendingRequests(with error: Error) {
        let requests = pendingRequests
        pendingRequests.removeAll()
        for pending in requests.values {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    private static let clientTerminatedError = EngineRequestError(
        code: "ENGINE_CLIENT_TERMINATED",
        message: "The engine client is shutting down.",
        recoverable: false
    )

    /// Shuts down once, even when multiple callers race to terminate. The
    /// detached task is intentionally not a child of the caller: cancelling
    /// a UI task cannot abandon subprocess cleanup midway through.
    public func terminate() async {
        if let terminationTask {
            await terminationTask.value
            return
        }

        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.performTermination()
        }
        terminationTask = task
        await task.value
    }

    private func performTermination() async {
        terminationHandled = true
        stdoutHandle.readabilityHandler = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        failAllPendingRequests(with: Self.clientTerminatedError)
        eventsContinuation.finish()

        guard isProcessRunning else {
            closeStdin()
            return
        }

        // `engine.shutdown` is the cooperative path: it cancels workers,
        // flushes its response, and exits. There is deliberately no pending
        // continuation for this final request; process exit is the ack that
        // matters and is independently deadline-bounded below.
        sendShutdownRequest()
        closeStdin()
        if await waitForProcessExit(timeout: configuration.gracefulShutdownTimeout) {
            return
        }

        // A wedged engine gets one bounded SIGTERM phase before the
        // non-cooperative SIGKILL fallback.
        process.terminate()
        if await waitForProcessExit(timeout: configuration.terminateTimeout) {
            return
        }

        #if canImport(Darwin)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        #endif
        _ = await waitForProcessExit(timeout: configuration.forceKillTimeout)
    }

    private func sendShutdownRequest() {
        guard !stdinClosed, process.isRunning else { return }
        nextRequestId += 1
        let envelope = RequestEnvelope(
            id: nextRequestId,
            method: "engine.shutdown",
            params: EmptyParams()
        )
        do {
            var line = try JSONEncoder().encode(envelope)
            line.append(0x0A)
            try stdinHandle.write(contentsOf: line)
        } catch {
            // The escalation path below handles a closed/broken pipe.
        }
    }

    private func closeStdin() {
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdinHandle.close()
    }

    private var isProcessRunning: Bool {
        configuration.processIsRunningOverride?(process) ?? process.isRunning
    }

    /// Polls only Foundation's non-blocking state against a monotonic
    /// deadline. `Process` owns observation/reaping for children it launches;
    /// calling `waitUntilExit` after `isRunning` flips false is still unsafe
    /// because Foundation can lag internally and block past this deadline.
    private func waitForProcessExit(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while isProcessRunning {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                // Termination is non-cancellable once started. Continue to
                // the fixed deadline even if an enclosing task is cancelled.
            }
        }
        return true
    }
}

extension EngineClient: EngineClientProtocol {}
