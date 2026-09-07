// Real `AF_UNIX` transport for Phase 1's transport-agnostic
// `ControlChannelDispatcher` (protocol/CONTROL.md is canonical). D-01: raw
// POSIX sockets via `Darwin`, each accepted connection wrapped in
// `FileHandle(fileDescriptor:closeOnDealloc:)` and read through the
// existing `LineFramer` -- no higher-level connection-listener framework,
// no second line-buffering type. D-02: socket path policy (owner-only permissions,
// `sun_path` bound). D-03: stale sockets are reclaimed only after a failed
// connect probe; a live probe refuses `start` with a typed reason.
// D-04: per-connection `hello` state, a bounded request line, and a
// bounded per-connection outbound queue so one slow subscriber can never
// block another connection or the main actor.

import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

/// A typed failure from socket path validation or a socket lifecycle
/// operation (bind/listen/dial/probe). `errnoValue` is the POSIX `errno`
/// captured immediately after the failing call, before any other libc call
/// could clobber it. Thrown to the *host* calling `start(path:)` -- never
/// encoded into a `ControlErrorPayload` sent to a connection (T-02-11).
public struct ControlSocketError: Error, Equatable, Sendable, LocalizedError {
    public let context: String
    public let errnoValue: Int32

    public init(context: String, errnoValue: Int32) {
        self.context = context
        self.errnoValue = errnoValue
    }

    public var errorDescription: String? {
        "\(context): \(String(cString: strerror(errnoValue))) (errno \(errnoValue))"
    }
}

/// D-02: where the control socket lives, and the checks a path must pass
/// before anything binds there.
public enum ControlSocketPath {
    /// `~/.scanstudio/control.sock`. Never called by a test (T-02-*: no
    /// test may touch the real home directory).
    public static func defaultPath() -> String {
        directoryURL().appendingPathComponent("control.sock", isDirectory: false).path
    }

    public static func directoryURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".scanstudio", isDirectory: true)
    }

    /// Creates the containing directory for `path` when absent, then
    /// `chmod`s it to `0o700` unconditionally -- every `start()` call
    /// re-asserts this mode rather than trusting whatever it finds (D-02:
    /// never trust umask, and the directory's mode must not silently drift
    /// even if it already existed).
    public static func prepareDirectory(for path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            guard mkdir(directory, 0o700) == 0 else {
                throw ControlSocketError(context: "mkdir(\(directory))", errnoValue: errno)
            }
        }
        guard chmod(directory, 0o700) == 0 else {
            throw ControlSocketError(context: "chmod(\(directory), 0o700)", errnoValue: errno)
        }
    }

    /// D-02: refuses a path whose `sun_path` would not fit (counting the
    /// NUL terminator), a relative path, or a path where something already
    /// exists as a symlink -- T-02-06: a pre-placed symlink at the socket
    /// path is attacker-influenceable state, and following it would bind
    /// somewhere other than the intended path.
    public static func validate(_ path: String) throws {
        let byteLength = path.utf8.count
        guard byteLength < 104 else {
            throw ControlSocketError(
                context: "validate(\(path)): sun_path must be < 104 bytes incl. NUL, got \(byteLength)",
                errnoValue: ENAMETOOLONG
            )
        }
        guard path.hasPrefix("/") else {
            throw ControlSocketError(context: "validate(\(path)): path must be absolute", errnoValue: EINVAL)
        }
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw ControlSocketError(
                context: "validate(\(path)): refusing to bind through an existing symlink",
                errnoValue: ELOOP
            )
        }
    }
}

/// Builds a `sockaddr_un` for `path`. `ControlSocketPath.validate` is the
/// user-facing `sun_path`-bound refusal; this is only a defensive backstop
/// so this function itself can never overflow the fixed-size buffer.
private func makeSockaddrUn(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < capacity else {
        throw ControlSocketError(
            context: "makeSockaddrUn(\(path)): exceeds sun_path capacity (\(capacity) bytes)",
            errnoValue: ENAMETOOLONG
        )
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { rawPointer in
        let buffer = rawPointer.bindMemory(to: UInt8.self)
        for (index, byte) in pathBytes.enumerated() {
            buffer[index] = byte
        }
        buffer[pathBytes.count] = 0
    }
    return addr
}

/// D-03: dial/probe primitives for the stale-socket lifecycle. Never named
/// `connect`/`bind`/`listen`/`accept`/`close` (RESEARCH Pitfall 4); the one
/// POSIX call that shares a tempting name is qualified `Darwin.connect`.
public enum ControlSocketDialer {
    /// Opens an `AF_UNIX`/`SOCK_STREAM` connection to `path`. Returns the
    /// connected descriptor, or throws with the errno captured immediately
    /// after the failing call.
    public static func dial(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketError(context: "socket()", errnoValue: errno)
        }
        do {
            var addr = try makeSockaddrUn(path)
            let result = withUnsafePointer(to: &addr) { rawAddr -> Int32 in
                rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw ControlSocketError(context: "connect(\(path))", errnoValue: errno)
            }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    /// D-03: `true` means "someone may own this path" -- the only signal
    /// that licenses `start(path:)` to `unlink` a stale path is an explicit
    /// `false` here. `ENOENT` (nothing there) and `ECONNREFUSED` (a dead
    /// listener's abandoned socket file) are the only "provably not live"
    /// cases; every other errno is treated as live, never as license to
    /// unlink.
    public static func probeIsLive(path: String) -> Bool {
        do {
            let fd = try dial(path: path)
            close(fd)
            return true
        } catch let error as ControlSocketError {
            switch error.errnoValue {
            case ENOENT, ECONNREFUSED:
                return false
            default:
                return true
            }
        } catch {
            return true
        }
    }
}

/// One entry in a connection's outbound queue. `droppable == false` for a
/// command response (D-04: a caller's own answer must never be dropped);
/// `droppable == true` for an event line (`control.snapshot`/
/// `control.changed`), the only kind Pitfall 3's bounded queue may discard
/// under pressure.
private struct OutboundEntry {
    let bytes: Data
    let droppable: Bool
}

/// The real transport for Phase 1's `ControlChannelDispatcher`. One
/// dispatcher instance is constructed per accepted connection (all sharing
/// the single `SessionModel` passed to `init`), matching
/// `ControlChannelDispatcher`'s own per-instance `hello`/subscription state
/// (`ControlChannelDispatcher.swift:229-239`). No lock, mutex, or busy flag
/// lives here: `sessionModel.mutatingOperationInFlight` is the one
/// arbitration signal, already shared by construction.
public actor ControlChannelServer {
    private let sessionModel: SessionModel
    private var listenDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var boundPath: String?

    /// One entry per accepted, still-open connection, all keyed by the raw
    /// descriptor. `dispatchers[fd]` is this connection's own
    /// `ControlChannelDispatcher` -- its `hello`/subscription state is per
    /// instance, never shared across connections (Pattern 1).
    private var connections: [Int32: FileHandle] = [:]
    private var framers: [Int32: LineFramer] = [:]
    private var dispatchers: [Int32: ControlChannelDispatcher] = [:]
    /// Bytes accumulated since this connection's last complete line --
    /// D-04's buffer-level bound, checked *before* feeding into
    /// `LineFramer` so a peer that never sends a newline can never grow
    /// that framer's internal buffer past
    /// `ControlChannelDispatcher.maxRequestLineBytes`.
    private var pendingLineBytes: [Int32: Int] = [:]

    /// This connection's outbound queue (Pitfall 3 / locked judgment call
    /// 3): responses are never droppable, event lines always are. Lives on
    /// the server's write side, never inside the dispatcher's own
    /// `AsyncStream` (which is unbounded by design and must stay that way).
    private var outboundQueues: [Int32: [OutboundEntry]] = [:]
    /// A dedicated serial queue per connection that performs the blocking
    /// `FileHandle.write(contentsOf:)` -- never the accept queue, never
    /// `.main` -- so a stalled peer's write only ever blocks its own
    /// connection's drain.
    private var writeQueues: [Int32: DispatchQueue] = [:]
    /// Guards against starting a second concurrent drain loop for the same
    /// connection.
    private var draining: Set<Int32> = []
    /// Events dropped since the last `control.dropped` notice was written
    /// for this connection -- surfaced immediately before the next event
    /// line (the locked judgment call's "surfaced in the next event"); CLI-
    /// side handling of `control.dropped` is OPS-10 (Phase 5).
    private var droppedEventCounts: [Int32: Int] = [:]
    /// At most one relay task per connection (a second `events.subscribe`
    /// on an already-subscribed connection must not start a second one);
    /// cancelling it is what lets its captured dispatcher reference drop,
    /// which is what terminates that dispatcher's event subscription.
    private var relayTasks: [Int32: Task<Void, Never>] = [:]

    /// D-04/Pitfall 3: bounds a single connection's outbound queue. Control
    /// and event lines in this protocol are small JSON objects (well under
    /// 1 KB each in practice), so this entry-count cap keeps one stalled
    /// connection's queue at a few hundred kilobytes at most, never
    /// unbounded.
    static let outboundQueueBound = 256

    private static let listenBacklog: Int32 = 8

    public init(sessionModel: SessionModel) {
        self.sessionModel = sessionModel
        // Matches the subprocess client's own init-time rationale
        // verbatim: a write to a peer that has already closed its end (a
        // disconnected control client, or -- in a test process that never
        // constructs a real subprocess client -- the *first* place
        // SIGPIPE's default process-killing disposition would ever be
        // touched at all) must degrade to an EPIPE error on the write
        // call, not terminate the process. Safe to call repeatedly; a
        // global signal disposition, not per-connection state.
        signal(SIGPIPE, SIG_IGN)
    }

    public var isListening: Bool { listenDescriptor >= 0 }

    /// Binds and listens at `path`, in this exact order: validate the path,
    /// prepare its directory, refuse if a live host already owns the path
    /// (D-03), reclaim a stale path, then `socket`/`bind`/`chmod`/`listen`.
    /// Every failure path closes any descriptor it opened before throwing.
    public func start(path: String) throws {
        try ControlSocketPath.validate(path)
        try ControlSocketPath.prepareDirectory(for: path)
        if ControlSocketDialer.probeIsLive(path: path) {
            throw ControlSocketError(
                context: "start(\(path)): another host is already listening at this path",
                errnoValue: EADDRINUSE
            )
        }
        unlink(path) // safe: the probe above proved nothing live owns this path (D-03)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketError(context: "socket()", errnoValue: errno)
        }
        do {
            try bindListenAndChmod(fd: fd, path: path)
        } catch {
            close(fd)
            throw error
        }
        listenDescriptor = fd
        boundPath = path
        armAcceptSource(fd: fd)
    }

    private func bindListenAndChmod(fd: Int32, path: String) throws {
        var addr = try makeSockaddrUn(path)
        let bindResult = withUnsafePointer(to: &addr) { rawAddr -> Int32 in
            rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw ControlSocketError(context: "bind(\(path))", errnoValue: errno)
        }
        guard chmod(path, 0o600) == 0 else {
            throw ControlSocketError(context: "chmod(\(path), 0o600)", errnoValue: errno)
        }
        guard listen(fd, Self.listenBacklog) == 0 else {
            throw ControlSocketError(context: "listen(\(path))", errnoValue: errno)
        }
    }

    /// Cancels the accept source, closes every connection descriptor,
    /// closes the listening descriptor, and `unlink`s exactly the path this
    /// instance bound. Safe to call on a server that never started.
    public func stop() async {
        for fd in Array(connections.keys) {
            closeConnection(fd)
        }
        acceptSource?.setCancelHandler {}
        acceptSource?.cancel()
        acceptSource = nil
        if listenDescriptor >= 0 {
            close(listenDescriptor)
            listenDescriptor = -1
        }
        if let path = boundPath {
            unlink(path) // stop() is the only caller that unlinks the path it bound
            boundPath = nil
        }
    }

    /// Test-only. RESEARCH Pitfall 2: a `DispatchSource` cancel handler
    /// fires asynchronously, so a probe issued on the very next line could
    /// still observe the old descriptor as live if this relied on that
    /// handler's own timing. Closing the raw descriptor here, synchronously,
    /// is what makes `probeIsLive` see the crash immediately -- and,
    /// deliberately, does NOT unlink `boundPath`, so the file is still on
    /// disk exactly like a real crash would leave it. Production teardown
    /// is `stop()`.
    func simulateHostCrash() {
        acceptSource?.setCancelHandler {}
        acceptSource?.cancel()
        acceptSource = nil
        if listenDescriptor >= 0 {
            close(listenDescriptor)
            listenDescriptor = -1
        }
    }

    /// The weak-self, immediate-`Task`-hop callback shape used elsewhere in
    /// this target for a readability handler around an OS resource: only
    /// synchronous work (`accept()`) happens in the event handler itself;
    /// everything else hops into a `Task` immediately.
    private func armAcceptSource(fd: Int32) {
        let queue = DispatchQueue(label: "com.scanstudio.controlchannel.accept.\(fd)")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            Task { await self?.adopt(clientFD) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    /// Constructs this connection's own `ControlChannelDispatcher` (a
    /// `MainActor` hop, since the dispatcher's initializer is
    /// `MainActor`-isolated -- Pattern 1: one dispatcher per connection, all
    /// sharing the single `sessionModel` this server was handed), wraps the
    /// descriptor in a `FileHandle`, and installs the same weak-self
    /// immediate-`Task`-hop readability shape `armAcceptSource` uses: empty
    /// data means the peer closed, anything else feeds this connection's
    /// `LineFramer`.
    private func adopt(_ fd: Int32) async {
        let dispatcher = await MainActor.run {
            ControlChannelDispatcher(sessionModel: sessionModel)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        connections[fd] = handle
        framers[fd] = LineFramer()
        dispatchers[fd] = dispatcher
        pendingLineBytes[fd] = 0
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard let self else { return }
            if data.isEmpty {
                Task { await self.closeConnection(fd) }
            } else {
                Task { await self.feed(fd: fd, chunk: data) }
            }
        }
    }

    /// Feeds one chunk through this connection's `LineFramer`, in order,
    /// and answers every complete line via `dispatcher.handleLine(_:)`.
    /// Enforces D-04's byte bound at the buffer level -- before framing,
    /// not only inside `decode(_:)` -- so a peer that never sends a newline
    /// is refused and closed instead of buffered to exhaustion (T-02-08).
    private func feed(fd: Int32, chunk: Data) async {
        guard var framer = framers[fd], let dispatcher = dispatchers[fd] else { return }
        let totalPending = (pendingLineBytes[fd] ?? 0) + chunk.count
        guard totalPending <= ControlChannelDispatcher.maxRequestLineBytes else {
            await refuseOversizedLine(fd: fd)
            return
        }

        let lines = framer.feed(chunk)
        framers[fd] = framer
        // Bytes consumed by the lines just extracted (content + the
        // stripped newline byte each); whatever remains is this
        // connection's new unterminated-partial-line residue.
        let consumed = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        pendingLineBytes[fd] = max(0, totalPending - consumed)

        for line in lines {
            await processLine(fd: fd, dispatcher: dispatcher, line: line)
        }
    }

    /// Answers one framed line via `dispatcher.handleLine(_:)` -- the
    /// single call a transport makes per request line -- and, only for a
    /// *successful* `events.subscribe`, starts this connection's event
    /// relay. The method-name and success sniffs are cheap, generic JSON
    /// shape checks (never a re-derivation of routing/gate logic, which
    /// stays entirely inside the dispatcher).
    private func processLine(fd: Int32, dispatcher: ControlChannelDispatcher, line: String) async {
        let lineData = Data(line.utf8)
        let isEventsSubscribeRequest = Self.methodName(of: lineData) == Self.eventsSubscribeMethod
        let responseData = await dispatcher.handleLine(lineData)
        if isEventsSubscribeRequest, Self.isSuccessResponse(responseData) {
            startEventRelay(fd: fd, dispatcher: dispatcher)
        }
        var out = responseData
        out.append(0x0A)
        enqueue(fd: fd, bytes: out, droppable: false)
    }

    private static let eventsSubscribeMethod = "events.subscribe"

    private static func methodName(of line: Data) -> String? {
        (try? JSONDecoder().decode(ControlMethodSniff.self, from: line))?.method
    }

    private static func isSuccessResponse(_ data: Data) -> Bool {
        struct ResponseKindSniff: Decodable { let error: ControlErrorPayload? }
        guard let sniff = try? JSONDecoder().decode(ResponseKindSniff.self, from: data) else { return false }
        return sniff.error == nil
    }

    /// D-04/T-02-08: writes one `INVALID_PARAMS` line naming the limit,
    /// then closes the connection and drops all its state -- never keeps
    /// buffering, never waits for a newline that may never come.
    ///
    /// Writes directly via `write(fd:bytes:)` and `await`s it, rather than
    /// `enqueue`-ing onto the outbound queue: `closeConnection` immediately
    /// after would otherwise discard this connection's queue (including
    /// the entry just appended) before the drain loop's own `Task` ever
    /// gets a turn to run it -- this refusal is the one write that must be
    /// on the wire *before* the descriptor closes, not merely queued.
    private func refuseOversizedLine(fd: Int32) async {
        let payload = ControlErrorPayload(
            .invalidParams,
            message: "Request line exceeded \(ControlChannelDispatcher.maxRequestLineBytes) bytes before a newline was seen."
        )
        if let data = try? JSONEncoder().encode(ControlResponseErrorEnvelope(id: 0, error: payload)) {
            var out = data
            out.append(0x0A)
            await write(fd: fd, bytes: out)
        }
        closeConnection(fd)
    }

    // MARK: Event relay (Task 3)

    /// After a connection's dispatcher answers `events.subscribe`
    /// successfully, iterates the dispatcher's own event stream (snapshot
    /// first, then changes -- D-06) and enqueues each element as a
    /// droppable outbound entry. At most one relay task per connection.
    private func startEventRelay(fd: Int32, dispatcher: ControlChannelDispatcher) {
        guard relayTasks[fd] == nil else { return }
        relayTasks[fd] = Task { [weak self] in
            let stream = await dispatcher.subscribeToEvents()
            for await eventData in stream {
                guard let self else { return }
                var out = eventData
                out.append(0x0A)
                await self.enqueue(fd: fd, bytes: out, droppable: true)
            }
        }
    }

    /// Appends to this connection's outbound queue and kicks its drain
    /// loop. When the queue exceeds `outboundQueueBound`, removes the
    /// *oldest droppable* entry (never a response) and counts it as
    /// dropped for this connection.
    private func enqueue(fd: Int32, bytes: Data, droppable: Bool) {
        guard connections[fd] != nil else { return }
        var queue = outboundQueues[fd] ?? []
        queue.append(OutboundEntry(bytes: bytes, droppable: droppable))
        while queue.count > Self.outboundQueueBound {
            guard let dropIndex = queue.firstIndex(where: { $0.droppable }) else { break }
            queue.remove(at: dropIndex)
            droppedEventCounts[fd, default: 0] += 1
        }
        outboundQueues[fd] = queue
        kickDrain(fd: fd)
    }

    private func kickDrain(fd: Int32) {
        guard !draining.contains(fd) else { return }
        draining.insert(fd)
        Task { await self.drainLoop(fd: fd) }
    }

    /// Pops one entry at a time, on the actor, then suspends on a
    /// continuation resumed from the connection's own write queue once the
    /// blocking write completes -- so a stalled peer suspends only its own
    /// connection's drain, never the actor and never another connection.
    private func drainLoop(fd: Int32) async {
        while connections[fd] != nil {
            guard var queue = outboundQueues[fd], !queue.isEmpty else { break }
            let entry = queue.removeFirst()
            outboundQueues[fd] = queue

            if entry.droppable {
                let dropped = droppedEventCounts[fd] ?? 0
                if dropped > 0 {
                    droppedEventCounts[fd] = 0
                    if var notice = Self.encodedDroppedNotice(droppedEvents: dropped) {
                        notice.append(0x0A)
                        await write(fd: fd, bytes: notice)
                    }
                }
            }
            await write(fd: fd, bytes: entry.bytes)
        }
        draining.remove(fd)
    }

    /// The actual blocking `FileHandle.write(contentsOf:)`, performed on
    /// this connection's own dedicated serial queue -- never the actor,
    /// never `.main`. The actor only suspends on the continuation; it does
    /// not block.
    private func write(fd: Int32, bytes: Data) async {
        guard let handle = connections[fd] else { return }
        let queue = outboundWriteQueue(for: fd)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                try? handle.write(contentsOf: bytes)
                continuation.resume()
            }
        }
    }

    private func outboundWriteQueue(for fd: Int32) -> DispatchQueue {
        if let existing = writeQueues[fd] { return existing }
        let queue = DispatchQueue(label: "com.scanstudio.controlchannel.write.\(fd)")
        writeQueues[fd] = queue
        return queue
    }

    private static func encodedDroppedNotice(droppedEvents: Int) -> Data? {
        struct DroppedEventPayload: Encodable { let droppedEvents: Int }
        return try? JSONEncoder().encode(
            ControlEventEnvelope(event: "control.dropped", payload: DroppedEventPayload(droppedEvents: droppedEvents))
        )
    }

    /// Closes a connection exactly once -- peer EOF, an oversized line, or
    /// `stop()` -- clearing the readability handler, closing the
    /// descriptor, and dropping every piece of this connection's state.
    /// Cancelling the relay task drops its captured dispatcher reference,
    /// which is what terminates that dispatcher's event subscription.
    ///
    /// Closes through `handle.close()`, never a raw POSIX `close(fd)`: a
    /// readability-handler invocation the kernel already queued before
    /// `readabilityHandler` was cleared can still run with a stale
    /// reference to this same descriptor number. Closing the raw fd out
    /// from under `FileHandle`'s own dispatch source races that queued
    /// invocation (`availableData` raises an uncatchable
    /// `NSFileHandleOperationException` on a bad descriptor, and under a
    /// busy suite a just-closed fd number is often already reassigned to
    /// an unrelated connection). Routing the close through the handle lets
    /// Foundation coordinate its own source teardown first.
    private func closeConnection(_ fd: Int32) {
        guard let handle = connections.removeValue(forKey: fd) else { return }
        handle.readabilityHandler = nil
        try? handle.close()
        framers.removeValue(forKey: fd)
        dispatchers.removeValue(forKey: fd)
        pendingLineBytes.removeValue(forKey: fd)
        outboundQueues.removeValue(forKey: fd)
        droppedEventCounts.removeValue(forKey: fd)
        writeQueues.removeValue(forKey: fd)
        draining.remove(fd)
        relayTasks.removeValue(forKey: fd)?.cancel()
    }
}
