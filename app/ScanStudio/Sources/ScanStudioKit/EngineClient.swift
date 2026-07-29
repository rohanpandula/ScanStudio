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
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle

    private var lineFramer = LineFramer()
    private var nextRequestId: UInt64 = 0
    private var pendingContinuations: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var handshakeTask: Task<Void, Error>?
    private var terminationHandled = false

    /// The engine's self-reported version from `engine.hello`, retained so
    /// callers (e.g. `SessionModel`) can surface it instead of the connect
    /// flow discarding data the engine already sends on every connection.
    public private(set) var engineVersion: String?

    private let eventsContinuation: AsyncStream<EngineEvent>.Continuation
    public nonisolated let events: AsyncStream<EngineEvent>

    public init(engineURL: URL) throws {
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
        nextRequestId += 1
        let id = nextRequestId
        let envelope = RequestEnvelope(id: id, method: method, params: params)

        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[id] = continuation
            do {
                var line = try JSONEncoder().encode(envelope)
                line.append(0x0A)
                try stdinHandle.write(contentsOf: line)
            } catch {
                pendingContinuations.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }

        let envelope2 = try JSONDecoder().decode(ResponseEnvelope<Result>.self, from: responseData)
        return envelope2.result
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
        guard let continuation = pendingContinuations.removeValue(forKey: id) else { return }

        // Attempt the error shape first; fall back to treating the line as
        // a success response otherwise (either resolves unambiguously since
        // a response is always exactly one or the other).
        if let errorEnvelope = try? JSONDecoder().decode(ResponseErrorEnvelope.self, from: data) {
            continuation.resume(throwing: EngineRequestError(
                code: errorEnvelope.error.code,
                message: errorEnvelope.error.message,
                recoverable: errorEnvelope.error.recoverable
            ))
        } else {
            continuation.resume(returning: data)
        }
    }

    private func handleProcessTermination() {
        guard !terminationHandled else { return }
        terminationHandled = true
        stdoutHandle.readabilityHandler = nil

        // T-02-02: pending continuations must be resumed with an error, not
        // leaked, if the child process exits unexpectedly.
        let error = EngineRequestError(
            code: "ENGINE_TERMINATED",
            message: "The scanstudio-engine process exited unexpectedly.",
            recoverable: false
        )
        for (_, continuation) in pendingContinuations {
            continuation.resume(throwing: error)
        }
        pendingContinuations.removeAll()
        let terminationEvent = Data(
            #"{"event":"engine.terminated","payload":{"code":"ENGINE_TERMINATED","message":"The scanstudio-engine process exited unexpectedly."}}"#.utf8
        )
        eventsContinuation.yield(EngineEvent(name: "engine.terminated", rawLine: terminationEvent))
        eventsContinuation.finish()
    }

    /// Best-effort cleanup so the subprocess doesn't outlive the app.
    /// Safe to call multiple times.
    public func terminate() {
        stdoutHandle.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

extension EngineClient: EngineClientProtocol {}
