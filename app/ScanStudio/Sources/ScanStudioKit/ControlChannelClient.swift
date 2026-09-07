// The client half of the ScanStudio control channel (protocol/CONTROL.md is
// canonical, D-01). Dials one AF_UNIX connection, completes `hello`, and
// demultiplexes id-matched responses from unsolicited events arriving on
// that same connection -- the transport `scanstudio-cli` (and this suite's
// own tests) use to attach to a running app.
//
// D-14/OUT-03: a typed refusal from the dispatcher (`ControlErrorPayload`)
// always comes back as a `ControlClientResponse.failure` *value*, never
// thrown and never reworded, so a `catch` at a call site can never
// accidentally swallow one. D-15: this is attach-mode discovery only --
// dial a path, fail if nothing answers; headless auto-start is Phase 3.
//
// SAFE-02 is structural here, not a convention: nothing in this file dials
// a second time after a failure, sends an already-sent request a second
// time, or waits and tries again. A dropped connection or a refused
// command is reported to the caller exactly once.
//
// RESEARCH Pitfall 4: no method here is named `connect`, `close`, `read`,
// or `write` -- the one POSIX dial this file needs is `ControlSocketDialer`'s
// own `dial(path:)` (plan 02-02), never a second, hand-rolled socket call.

import Foundation

// MARK: - Client-facing errors

/// Transport-level failures owned by this connection itself, distinct from
/// a typed `ControlErrorPayload` refusal the host answered with
/// (`ControlClientResponse.failure`, D-14). Never retried, never remapped
/// (SAFE-02).
public enum ControlChannelClientError: Error, Equatable, Sendable {
    /// `hello` was refused (e.g. a schema-version mismatch) -- the
    /// dispatcher's own `ControlErrorPayload`, carried untouched.
    case helloRefused(ControlErrorPayload)
    /// The connection closed -- `shutdown()` was called, or the peer went
    /// away -- while this request was still awaiting a response.
    case connectionClosed
    /// A response line matched a pending request's id but decoded as
    /// neither a success nor an error envelope.
    case malformedResponse
}

// MARK: - Response

/// One command's answer. `.failure` carries the dispatcher's typed
/// `ControlErrorPayload` as a plain value -- never thrown -- so nothing
/// between the dispatcher and the caller (a CLI command's own `catch`) can
/// accidentally swallow a refusal the caller must act on (D-14/OUT-03).
public enum ControlClientResponse: Sendable {
    /// The raw JSON bytes of the response's `result` object -- exactly the
    /// shape `protocol/CONTROL.md` documents for whichever `method` was
    /// sent. Left undecoded here since this actor has no per-command
    /// knowledge of which `Control*Result` type fits; the caller decodes.
    case result(Data)
    case failure(ControlErrorPayload)
}

/// The client half of the control channel: dials `~/.scanstudio/control.sock`
/// (or a caller-supplied path via `open(path:)`), completes `hello`, and
/// demultiplexes id-matched responses from unsolicited events on the same
/// connection.
///
/// Mirrors `EngineClient`'s actor-around-OS-resource shape (weak-self
/// readability handler, immediate `Task` hop, id-matched
/// `CheckedContinuation`s) -- the same idiom, dialing a Unix socket instead
/// of spawning a subprocess. Deliberately does **not** mirror
/// `EngineClient.ensureHandshake()`'s lazy, per-request handshake check:
/// `open(path:)` completes `hello` exactly once, up front, so every
/// `ControlChannelClient` a caller holds has already been greeted.
public actor ControlChannelClient {
    private let handle: FileHandle
    private var framer = LineFramer()
    private var nextRequestId: UInt64 = 0
    private var pendingRequests: [UInt64: CheckedContinuation<ControlClientResponse, Error>] = [:]

    private var eventStream: AsyncStream<Data>?
    private var eventContinuation: AsyncStream<Data>.Continuation?
    /// Event lines received before the first `events()` call -- the server
    /// sends `control.snapshot` as soon as `events.subscribe` succeeds
    /// (plan 02-02), which can race a caller that has not yet called
    /// `events()` on this actor. Bounded, drop-oldest, matching the
    /// server's own outbound-queue policy
    /// (`ControlChannelServer.outboundQueueBound`) rather than growing
    /// without limit.
    private var preSubscriptionEvents: [Data] = []
    static let preSubscriptionBufferBound = 64

    private var isShutDown = false

    /// The negotiated `hello` result, retained so a caller (or a test) can
    /// read the app's schema version and name after `open(path:)` returns,
    /// without re-deriving it from a second request.
    public private(set) var helloResult: ControlHelloResult?

    private init(handle: FileHandle) {
        self.handle = handle
    }

    /// Dials `path` via `ControlSocketDialer`'s own `dial(path:)` -- the
    /// same primitive the server's own stale-socket probe uses, so this
    /// file contains no second dial implementation -- wraps the descriptor,
    /// installs its readability handler, and completes `hello` with
    /// `ControlSchema.version` before returning.
    ///
    /// A dial failure throws the underlying `ControlSocketError` untouched
    /// (the caller maps `ENOENT`/`ECONNREFUSED` to `HOST_UNREACHABLE`, per
    /// D-15). A refused greeting throws
    /// `ControlChannelClientError.helloRefused` carrying the dispatcher's
    /// own `ControlErrorPayload`. Either failure closes the descriptor
    /// before rethrowing, so a caller that never receives a client never
    /// leaks one.
    public static func open(
        path: String,
        clientName: String,
        clientBuild: String? = nil
    ) async throws -> ControlChannelClient {
        let fd = try ControlSocketDialer.dial(path: path)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let client = ControlChannelClient(handle: handle)
        await client.installReadabilityHandler()
        do {
            try await client.sendHello(clientName: clientName, clientBuild: clientBuild)
        } catch {
            await client.shutdown()
            throw error
        }
        return client
    }

    /// The weak-self, immediate-`Task`-hop shape used everywhere else in
    /// this target for a readability handler around an OS resource
    /// (`EngineClient.swift:170-179`, `ControlChannelServer.adopt(_:)`):
    /// only synchronous work (`availableData`) happens in the handler
    /// itself; everything else hops into a `Task` immediately.
    private func installReadabilityHandler() {
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard let self else { return }
            if data.isEmpty {
                Task { await self.shutdown() }
            } else {
                Task { await self.feed(data) }
            }
        }
    }

    private func sendHello(clientName: String, clientBuild: String?) async throws {
        let params = ControlHelloParams(
            schemaVersion: ControlSchema.version,
            clientName: clientName,
            clientBuild: clientBuild
        )
        switch try await performRequest(method: "hello", params: params) {
        case .result(let data):
            helloResult = try? JSONDecoder().decode(ControlHelloResult.self, from: data)
        case .failure(let payload):
            throw ControlChannelClientError.helloRefused(payload)
        }
    }

    // MARK: - Requests

    /// Sends `{"id", "method", "params"}` and awaits the matching
    /// `{"id", "result"}` / `{"id", "error"}` line on this connection. A
    /// typed refusal is returned as `.failure`, never thrown (D-14).
    public func request<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> ControlClientResponse {
        try await performRequest(method: method, params: params)
    }

    /// For the channel's no-params commands. Still sends `"params": {}` on
    /// the wire -- `ControlChannelDispatcher.decode(_:)` expects a params
    /// object even for an empty one.
    public func requestWithoutParams(method: String) async throws -> ControlClientResponse {
        try await performRequest(method: method, params: EmptyParams())
    }

    /// Deliberately implements **no** request timeout. D-13's `--wait`
    /// blocks on the event stream for as long as a scan takes; a
    /// client-side timeout here would fire while a real scan was still in
    /// progress and hand the caller a local timeout error -- exactly the
    /// condition that would tempt a caller into sending the request again,
    /// which SAFE-02 forbids this file from doing anywhere. A stalled
    /// request only ever ends because the caller cancels its own `Task`
    /// (`withTaskCancellationHandler` below) or the connection closes
    /// (`shutdown()`).
    private func performRequest<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> ControlClientResponse {
        guard !isShutDown else {
            throw ControlChannelClientError.connectionClosed
        }
        nextRequestId += 1
        let id = nextRequestId
        let envelope = RequestEnvelope(id: id, method: method, params: params)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ControlClientResponse, Error>) in
                pendingRequests[id] = continuation
                do {
                    var line = try JSONEncoder().encode(envelope)
                    line.append(0x0A)
                    try handle.write(contentsOf: line)
                } catch {
                    pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    /// Removes before resuming so a response, a cancellation, and
    /// `shutdown()` can race without ever double-resuming a continuation.
    private func cancelRequest(id: UInt64) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    // MARK: - Incoming bytes

    private func feed(_ chunk: Data) {
        let lines = framer.feed(chunk)
        for line in lines {
            route(Data(line.utf8))
        }
    }

    /// Decodes `{"id":…}` first (reusing `WireSniff`, the same lenient
    /// id-or-event sniff `EngineClient` reads its own incoming lines
    /// with): a line carrying an id resolves the matching pending
    /// request; a line with no id is an event. T-02-19: an id this
    /// connection never issued must never resolve an unrelated waiter, so
    /// a response for an id with no pending continuation is dropped, with
    /// a diagnostic, rather than guessed at.
    private func route(_ lineData: Data) {
        guard let sniff = try? JSONDecoder().decode(WireSniff.self, from: lineData) else {
            return
        }
        guard let id = sniff.id else {
            routeEvent(lineData)
            return
        }
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            try? FileHandle.standardError.write(
                contentsOf: Data("ControlChannelClient: dropped a response for unknown request id \(id)\n".utf8)
            )
            return
        }
        if let errorEnvelope = try? JSONDecoder().decode(ControlResponseErrorEnvelope.self, from: lineData) {
            continuation.resume(returning: .failure(errorEnvelope.error))
            return
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
            let resultValue = object["result"],
            let resultData = try? JSONSerialization.data(withJSONObject: resultValue)
        else {
            continuation.resume(throwing: ControlChannelClientError.malformedResponse)
            return
        }
        continuation.resume(returning: .result(resultData))
    }

    // MARK: - Events

    /// Yields every event line (`control.snapshot`/`control.changed`/
    /// `control.dropped`, full object, no trailing newline) received on
    /// this connection after the caller issues `events.subscribe` itself
    /// -- this actor never sends that request on the caller's behalf, it
    /// only routes what arrives.
    ///
    /// Created lazily and shared: a second call returns the same stream
    /// rather than starting a second one, since a connection has exactly
    /// one inbound byte source and two independent streams would split
    /// events between them unpredictably. Buffered `.unbounded` (the
    /// default) -- this actor is the terminal consumer and the server
    /// already bounds and drops on the socket side (D-04/Pitfall 3), so a
    /// second bound here would only drop the same events a second time.
    /// Finishes when the connection closes, so an `events --follow` loop
    /// ends rather than hanging.
    public func events() -> AsyncStream<Data> {
        if let eventStream {
            return eventStream
        }
        var streamContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation in
            streamContinuation = continuation
        }
        eventStream = stream
        eventContinuation = streamContinuation
        for buffered in preSubscriptionEvents {
            streamContinuation.yield(buffered)
        }
        preSubscriptionEvents.removeAll()
        if isShutDown {
            streamContinuation.finish()
        }
        return stream
    }

    private func routeEvent(_ lineData: Data) {
        if let eventContinuation {
            eventContinuation.yield(lineData)
            return
        }
        preSubscriptionEvents.append(lineData)
        if preSubscriptionEvents.count > Self.preSubscriptionBufferBound {
            preSubscriptionEvents.removeFirst()
        }
    }

    /// Returns the `payload` of a `control.snapshot`/`control.changed`
    /// event line as a `ControlStatusResult`, or `nil` for any other event
    /// name (including `control.dropped`, whose payload shape does not
    /// decode as one) -- the one place `--wait` and `status --job` both
    /// read a status snapshot out of an event line, so neither
    /// re-implements this decode itself. Pure and `nonisolated`: no actor
    /// hop needed to call it.
    public nonisolated static func decodeStatusSnapshot(fromEventLine line: Data) -> ControlStatusResult? {
        guard let envelope = try? JSONDecoder().decode(EventEnvelope<ControlStatusResult>.self, from: line) else {
            return nil
        }
        guard envelope.event == snapshotEventName || envelope.event == changedEventName else {
            return nil
        }
        return envelope.payload
    }

    private static let snapshotEventName = "control.snapshot"
    private static let changedEventName = "control.changed"

    // MARK: - Shutdown

    /// Clears the readability handler, closes the descriptor exactly once,
    /// finishes the event stream, and resumes every still-pending request
    /// with `.connectionClosed` so no caller hangs forever. Safe to call
    /// more than once (peer EOF and an explicit caller `shutdown()` can
    /// both reach here) and safe to call from the readability handler
    /// itself.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        handle.readabilityHandler = nil
        try? handle.close()
        eventContinuation?.finish()
        let stillPending = pendingRequests
        pendingRequests.removeAll()
        for continuation in stillPending.values {
            continuation.resume(throwing: ControlChannelClientError.connectionClosed)
        }
    }
}
