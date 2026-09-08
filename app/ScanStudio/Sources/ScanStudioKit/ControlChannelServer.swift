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
    ///
    /// CF-02: `mkdir` is attempted unconditionally rather than gated behind
    /// a `fileExists` pre-check -- two first-ever starts at a brand-new
    /// directory used to race the check-then-`mkdir` window, and the loser
    /// got `EEXIST` and threw. `errno == EEXIST` (captured immediately
    /// after the `mkdir` call, into a local, before any other libc call
    /// -- including the `chmod` below -- can clobber the global `errno`)
    /// is success: something is already there, which is exactly what this
    /// function wants, and the unconditional `chmod` re-asserts its mode
    /// regardless of which racer actually created it.
    public static func prepareDirectory(for path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) != 0 {
            let mkdirErrno = errno
            guard mkdirErrno == EEXIST else {
                throw ControlSocketError(context: "mkdir(\(directory))", errnoValue: mkdirErrno)
            }
        }
        var info = stat()
        guard lstat(directory, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw ControlSocketError(context: "prepareDirectory(\(directory)): refusing a non-owned directory", errnoValue: EACCES)
        }
        guard chmod(directory, 0o700) == 0 else {
            throw ControlSocketError(context: "chmod(\(directory), 0o700)", errnoValue: errno)
        }
    }

    /// Claims the bind-time lock and proves no live listener owns `path`.
    /// The descriptor stays held while a headless host constructs its engine
    /// and model, then transfers to `ControlChannelServer.start`.
    static func claim(_ path: String) throws -> Int32 {
        try validate(path)
        try prepareDirectory(for: path)
        let descriptor = try acquireBindLock(forSocketPath: path)
        if ControlSocketDialer.probeIsLive(path: path) {
            releaseBindLock(descriptor)
            throw ControlSocketError(
                context: "start(\(path)): another host is already listening at this path",
                errnoValue: EADDRINUSE
            )
        }
        return descriptor
    }

    static func acquireBindLock(forSocketPath path: String) throws -> Int32 {
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw ControlSocketError(context: "open(\(lockPath))", errnoValue: errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1 else {
            close(fd)
            throw ControlSocketError(context: "start(\(path)): refusing unsafe bind lock", errnoValue: EACCES)
        }
        guard fchmod(fd, 0o600) == 0 else {
            let chmodErrno = errno
            close(fd)
            throw ControlSocketError(context: "fchmod(\(lockPath), 0o600)", errnoValue: chmodErrno)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ControlSocketError(
                context: "start(\(path)): another host is already starting at this path (lock \(lockPath) held)",
                errnoValue: EADDRINUSE
            )
        }
        return fd
    }

    static func releaseBindLock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
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

/// CF-01: a connection's ordered inbound FIFO. The old code spawned one
/// independent `Task { feed(...) }` per readable chunk, with no ordering
/// guarantee relative to arrival order -- several chunks arriving in quick
/// succession could feed `LineFramer` out of order, corrupting its buffer
/// and producing spurious `id: 0`/`INVALID_PARAMS` responses
/// (`02-REVIEW-FIX.md` item 5). `append`/`markClosed` run synchronously
/// *inside* the readability handler, which Foundation serializes per
/// `FileHandle` -- that is the one place ordering is actually guaranteed;
/// an `NSLock` (not actor isolation) guards the shared state because the
/// handler closure is a plain synchronous callback, not an `async`
/// context. `SingleResumeGuard` (`ControlSocketEndToEndTests.swift`) is
/// this repository's existing `NSLock`-guarded `@unchecked Sendable`
/// precedent for a small helper shared between a synchronous callback and
/// an async caller.
final class ControlConnectionInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var bufferedBytes = 0
    private var closed = false
    private var overflowed = false
    private let maxBufferedBytes: Int

    init(maxBufferedBytes: Int = ControlChannelDispatcher.maxRequestLineBytes * 4) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    @discardableResult
    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard data.count <= maxBufferedBytes - bufferedBytes else {
            overflowed = true
            return false
        }
        chunks.append(data)
        bufferedBytes += data.count
        return true
    }

    func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// Drains everything buffered so far and reports the close flag under
    /// one lock acquisition. The actor's drain loop calls this repeatedly
    /// until it reports back empty-and-still-open, which is the only
    /// condition that means "nothing left to do right now."
    func take() -> (chunks: [Data], closed: Bool, overflowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let drained = chunks
        chunks.removeAll()
        bufferedBytes = 0
        return (drained, closed, overflowed)
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
    /// CF-01: marks this entry as a close request rather than bytes to
    /// write. `drainInbound(fd:)` enqueues one of these -- instead of
    /// calling `closeConnection(fd)` directly -- once it observes EOF with
    /// nothing left to feed, so the close is ordered *after* every
    /// response already enqueued as a result of everything fed so far,
    /// reusing this queue's own existing FIFO guarantee rather than a
    /// second, independent synchronization mechanism. Never `droppable`,
    /// so the overflow-eviction loop in `enqueue(fd:bytes:droppable:)` can
    /// never discard it.
    var isCloseSentinel = false
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
    private let hostKind: ControlHostKind
    private var listenDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var boundPath: String?
    private var boundSocketIdentity: SocketIdentity?
    /// WR-03: set at the very start of `stop()`, before it closes any
    /// existing connection -- `adopt(_:)` re-checks this after registering
    /// a newly-accepted connection so one that slips in after `stop()` has
    /// already drained `connections` is closed too, rather than outliving
    /// the server's declared-stopped state.
    private var isStopped = false

    /// One entry per accepted, still-open connection, all keyed by the raw
    /// descriptor. `dispatchers[fd]` is this connection's own
    /// `ControlChannelDispatcher` -- its `hello`/subscription state is per
    /// instance, never shared across connections (Pattern 1).
    private var connections: [Int32: FileHandle] = [:]
    /// Generation token prevents an old in-flight dispatch from touching a
    /// replacement connection that reuses the same descriptor number.
    private var connectionTokens: [Int32: UUID] = [:]
    private var framers: [Int32: LineFramer] = [:]
    private var dispatchers: [Int32: ControlChannelDispatcher] = [:]
    /// Bytes accumulated since this connection's last complete line --
    /// D-04's buffer-level bound, checked *before* feeding into
    /// `LineFramer` so a peer that never sends a newline can never grow
    /// that framer's internal buffer past
    /// `ControlChannelDispatcher.maxRequestLineBytes`.
    private var pendingLineBytes: [Int32: Int] = [:]
    /// CF-01: this connection's ordered inbound FIFO -- appended to
    /// synchronously inside the readability handler, drained in order by
    /// `drainInbound(fd:)`.
    private var inboxes: [Int32: ControlConnectionInbox] = [:]
    /// CF-01: guards against starting a second concurrent drain loop for
    /// the same connection's inbox, mirroring the outbound side's own
    /// `draining` set.
    private var feedingInbound: Set<UUID> = []
    /// CF-01: how many already-framed lines have been dispatched
    /// (`dispatchLineConcurrently`) but have not yet finished enqueueing
    /// their response, per connection. Framing finishing (EOF, nothing
    /// left to frame) does not by itself mean every response owed for
    /// what was framed has been written -- dispatch is intentionally
    /// concurrent, not serialized behind framing.
    private var inFlightDispatchCount: [UUID: Int] = [:]
    /// CF-01: set by `drainInbound(fd:)` when framing alone finished (EOF
    /// observed, inbox drained) while `inFlightDispatchCount[fd]` was
    /// still non-zero. `finishDispatch(fd:)` is the only reader/consumer:
    /// once the count it is independently tracking reaches zero, it
    /// removes this and performs the actual close.
    private var framingDoneAwaitingDispatch: Set<UUID> = []

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
    private var draining: Set<UUID> = []
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
    static let inFlightRequestBound = 1_024

    private static let listenBacklog: Int32 = 8

    /// `hostKind` defaults to `.gui` so existing in-process servers keep
    /// their wire identity; the resident CLI host passes `.headless` (D-04).
    public init(sessionModel: SessionModel, hostKind: ControlHostKind = .gui) {
        self.sessionModel = sessionModel
        self.hostKind = hostKind
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
    /// prepare its directory, acquire the WR-02 bind-time lock, refuse if a
    /// live host already owns the path (D-03), reclaim a stale path, then
    /// `socket`/`bind`/`chmod`/`listen`. Every failure path closes any
    /// descriptor it opened before throwing.
    ///
    /// WR-02: the probe -> unlink -> bind sequence below has no atomicity
    /// of its own -- two processes racing `start(path:)` within the same
    /// narrow window could both observe `probeIsLive == false` (neither
    /// has bound yet), both `unlink` (harmless when nothing exists), and
    /// both attempt `bind()`; whichever binds first is live, but the
    /// second one's own `unlink` (issued before it ever tried to bind)
    /// could delete the first one's just-bound socket file, and the
    /// second's own subsequent `bind()` then succeeds too -- both report
    /// success, silently violating "a live probe refuses start" for the
    /// pair. An exclusive, non-blocking advisory `flock` on `<path>.lock`
    /// serializes this whole critical section across processes: whichever
    /// starter wins the lock proceeds exactly as before; the loser is
    /// refused immediately with the same `EADDRINUSE`-shaped error a
    /// live-probe refusal already uses, never left to race the winner for
    /// `unlink`/`bind` itself. This is a bind-time serializer only, held
    /// just for the duration of this call (released via `defer` on every
    /// exit path) -- it is never a liveness signal; liveness is, and
    /// remains, connect+hello only (documented in `CONTROL.md`).
    public func start(path: String) throws {
        try start(path: path, bindLock: nil)
    }

    func start(path: String, bindLock: Int32?) throws {
        if bindLock == nil {
            try ControlSocketPath.validate(path)
            try ControlSocketPath.prepareDirectory(for: path)
        }
        let lockFD = try bindLock ?? ControlSocketPath.acquireBindLock(forSocketPath: path)
        defer { ControlSocketPath.releaseBindLock(lockFD) }

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
            boundSocketIdentity = try Self.socketIdentity(at: path)
        } catch {
            close(fd)
            throw error
        }
        listenDescriptor = fd
        boundPath = path
        armAcceptSource(fd: fd)
    }

    /// Opens (creating if absent) `<path>.lock` at `0600` and takes an
    /// exclusive, non-blocking `flock` on it. The lock file is never
    /// `unlink`ed -- only released, via `close()` in `releaseBindLock` --
    /// so every future starter for the same socket path locks the same
    /// inode, never a since-deleted-and-recreated one (unlinking a lock
    /// file while another process might still be opening it is a classic
    /// way to make two "exclusive" locks refer to two different files).
    /// Failure to take the lock is reported with the identical
    /// `EADDRINUSE` shape `probeIsLive` already uses, so a caller cannot
    /// distinguish "lost the bind-time race" from "a live host already
    /// owns this path" -- both mean the same thing to `start(path:)`'s
    /// own caller: this attempt did not win the path.
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
    ///
    /// WR-03: `isStopped` is set first, before closing any connection
    /// present right now -- `adopt(_:)`'s own after-registration re-check
    /// is what catches a connection accepted concurrently with this call.
    public func stop() async {
        isStopped = true
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
        if let path = boundPath,
           let expected = boundSocketIdentity,
           let current = try? Self.socketIdentity(at: path),
           current == expected {
            unlink(path)
        }
        if boundPath != nil {
            boundPath = nil
            boundSocketIdentity = nil
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
    ///
    /// WR-04: if `self` has already been deallocated by the time this
    /// `Task` actually runs, `self?.adopt(clientFD)` alone would be a
    /// silent no-op -- `clientFD`, a real, already-`accept()`-ed
    /// descriptor, would never be closed. `self` is captured once into a
    /// local `let` so the `nil` branch can still close the leaked
    /// descriptor explicitly.
    private func armAcceptSource(fd: Int32) {
        let queue = DispatchQueue(label: "com.scanstudio.controlchannel.accept.\(fd)")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            Task { [weak self] in
                guard let self else {
                    close(clientFD)
                    return
                }
                await self.adopt(clientFD)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    /// Constructs this connection's own `ControlChannelDispatcher` (a
    /// `MainActor` hop, since the dispatcher's initializer is
    /// `MainActor`-isolated -- Pattern 1: one dispatcher per connection, all
    /// sharing the single `sessionModel` this server was handed), wraps the
    /// descriptor in a `FileHandle`, and installs an ordered-inbound
    /// readability handler: empty data means the peer closed, anything else
    /// is this connection's next chunk.
    ///
    /// CF-01: the handler itself does only synchronous work --
    /// `availableData`, then `inbox.append`/`markClosed` -- before hopping
    /// into a `Task` to drain. Foundation serializes a `FileHandle`'s own
    /// readability callbacks, so those appends are strictly ordered; the
    /// old code instead spawned an independent `Task { feed(...) }` per
    /// chunk, and the `Task` hop (not the callback) is exactly where
    /// ordering was lost under a burst. See `drainInbound(fd:)` for the
    /// FIFO drain this feeds.
    ///
    /// WR-03: `stop()` and this function can race -- `armAcceptSource`'s
    /// event handler spawns this function's own `Task` on a successful
    /// `accept()`, but if `stop()` reaches and drains the actor first, it
    /// closes only the connections present in `connections` *at that
    /// moment*, before this function ever runs. The `MainActor.run` hop
    /// just below is itself a suspension point `stop()` could interleave
    /// through even if this function checked `isStopped` only at its own
    /// start -- so the check instead runs *after* every registration
    /// statement (and after installing the live `readabilityHandler`),
    /// undoing the whole registration via the same `closeConnection(_:)`
    /// every other teardown path uses if the server stopped meanwhile.
    private func adopt(_ fd: Int32) async {
        let dispatcher = await MainActor.run {
            ControlChannelDispatcher(sessionModel: sessionModel, hostKind: hostKind)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let inbox = ControlConnectionInbox()
        let token = UUID()
        connections[fd] = handle
        connectionTokens[fd] = token
        framers[fd] = LineFramer()
        dispatchers[fd] = dispatcher
        pendingLineBytes[fd] = 0
        inboxes[fd] = inbox
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard let self else { return }
            if data.isEmpty {
                // EOF keeps a read source readable forever; disarm it before
                // queuing the ordered close so EOF cannot flood Tasks while
                // already-framed responses drain.
                fileHandle.readabilityHandler = nil
                inbox.markClosed()
            } else {
                inbox.append(data)
            }
            Task { await self.drainInbound(fd: fd, token: token, inbox: inbox) }
        }
        if isStopped {
            closeConnection(fd)
        }
    }

    /// CF-01: drains this connection's inbox in FIFO order, one `take()` at
    /// a time, `await feed(fd:chunk:)`-ing every chunk before looping back
    /// to check for more -- so a chunk appended *while* this loop is
    /// awaiting an earlier `feed` call is still picked up by this same
    /// loop's next iteration, never orphaned. `feedingInbound` admits only
    /// one concurrently-running drain per connection: a second readability
    /// firing while a drain is already in flight just appends and returns,
    /// trusting the in-flight loop to notice on its own next `take()`.
    ///
    /// Requests a close only when a `take()` reports both an empty queue
    /// and `closed == true` -- an EOF observed by the readability handler
    /// can therefore never overtake request bytes that arrived (and were
    /// appended) before it, even if both were coalesced into the same
    /// `take()` call. The close itself is a sentinel on the *outbound*
    /// queue (`enqueueCloseAfterOutboundDrains(fd:)`), not an immediate
    /// `closeConnection(fd)` call: enqueueing a response and writing it
    /// are two different asynchronous steps (`feed` only enqueues), so
    /// closing immediately here could tear the connection down before the
    /// outbound drain loop has actually written the last response out.
    /// `while let inbox = inboxes[fd]` re-checks liveness every iteration,
    /// so a connection `feed` itself closes (the oversized-line refusal
    /// path) simply ends this loop on the next check -- no separate guard
    /// needed, and `feedingInbound` is cleared on every exit via the one
    /// `defer` below.
    private func drainInbound(fd: Int32, token: UUID, inbox: ControlConnectionInbox) async {
        guard connectionTokens[fd] == token, !feedingInbound.contains(token) else { return }
        feedingInbound.insert(token)
        defer { feedingInbound.remove(token) }
        while connectionTokens[fd] == token {
            let (chunks, closed, overflowed) = inbox.take()
            if overflowed {
                closeConnection(fd, token: token)
                return
            }
            if chunks.isEmpty {
                if closed {
                    // Framing itself is done (nothing left to frame, EOF
                    // observed) -- but dispatch of whatever *was* framed
                    // runs concurrently, not sequentially inside this loop
                    // (see `feed(fd:chunk:)`), so it may not have finished
                    // yet. Close immediately only once it has; otherwise
                    // defer to whichever dispatch finishes last
                    // (`finishDispatch(fd:)`).
                    if (inFlightDispatchCount[token] ?? 0) > 0 {
                        framingDoneAwaitingDispatch.insert(token)
                    } else {
                        enqueueCloseAfterOutboundDrains(fd: fd, token: token)
                    }
                }
                return
            }
            for chunk in chunks {
                await feed(fd: fd, token: token, chunk: chunk)
            }
        }
    }

    /// Feeds one chunk through this connection's `LineFramer`, in order,
    /// and answers every complete line via `dispatcher.handleLine(_:)`.
    /// Enforces D-04's byte bound at the buffer level -- before framing,
    /// not only inside `decode(_:)` -- so a peer that never sends a newline
    /// is refused and closed instead of buffered to exhaustion (T-02-08).
    ///
    /// WR-01: the bound is checked two ways, neither of which is the raw
    /// incoming chunk size alone (the original bug: `LineFramer.feed` can
    /// extract several complete lines from one chunk, and a single `read()`
    /// that happens to contain many small, complete, well-formed lines
    /// whose combined raw bytes exceed the bound must never be refused --
    /// no individual line came anywhere close to it).
    ///
    /// Checking only the post-framing *residual*, on its own, has its own
    /// bug (found writing this fix's own regression test, which took 55s
    /// on the *existing* single-oversized-line test instead of refusing
    /// immediately): a line that itself exceeds the bound but happens to
    /// receive its closing newline in the same chunk that completes it
    /// gets fully *consumed* by that chunk's framing, so the residual
    /// arithmetic (`pending + chunk - consumed`) drops back to ~0 and never
    /// reflects that the line it just consumed was itself too long -- the
    /// guard would silently let the entire oversized line buffer to
    /// completion before `decode(_:)`'s own, separate bound ever catches
    /// it, defeating the whole point of a *buffer-level* bound (T-02-08).
    ///
    /// So: every individually-completed line's own length is checked
    /// first (catches a line that is itself oversized, regardless of how
    /// many chunks it arrived across or what completed it); only then is
    /// the still-unterminated residual -- the tail this chunk leaves
    /// buffered with no newline yet -- checked against the same bound
    /// (catches a not-yet-terminated line that has already grown too big
    /// before it ever completes, the original, still-correct case this
    /// guard has always covered).
    private func feed(fd: Int32, token: UUID, chunk: Data) async {
        guard connectionTokens[fd] == token,
              var framer = framers[fd],
              let dispatcher = dispatchers[fd] else { return }
        let lines = framer.feed(chunk)
        framers[fd] = framer
        guard !lines.contains(where: { $0.utf8.count > ControlChannelDispatcher.maxRequestLineBytes }) else {
            await refuseOversizedLine(fd: fd, token: token, dispatcher: dispatcher)
            return
        }
        // Bytes consumed by the lines just extracted (content + the
        // stripped newline byte each); whatever remains is this
        // connection's new unterminated-partial-line residue.
        let consumed = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        let totalPending = max(0, (pendingLineBytes[fd] ?? 0) + chunk.count - consumed)
        guard totalPending <= ControlChannelDispatcher.maxRequestLineBytes else {
            await refuseOversizedLine(fd: fd, token: token, dispatcher: dispatcher)
            return
        }
        pendingLineBytes[fd] = totalPending

        // CF-01: framing (above) must stay strictly ordered -- it is the
        // shared `LineFramer`/`pendingLineBytes` state a burst could
        // corrupt -- but *dispatching* an already-framed line must not be.
        // `dispatcher.handleLine(_:)` can take arbitrarily long (a held or
        // slow `SessionModel` call); a later, independent request on this
        // same connection must still resolve while an earlier one is still
        // in flight, matched by id, not by arrival order
        // (`ControlChannelClientTests
        // .concurrentRequestsMatchByIdNotArrivalOrder`, pre-existing and
        // unrelated to this fix). Once a line exists as an independent,
        // immutable `String`, dispatching it concurrently touches none of
        // the framing state above, so this cannot reintroduce CF-01.
        var remainingLines = lines
        // A first hello establishes per-connection state used by every
        // following request. Complete it before dispatching pipelined lines;
        // later independent requests remain concurrent as before.
        if let first = remainingLines.first,
           Self.methodName(of: Data(first.utf8)) == "hello" {
            await processLine(fd: fd, token: token, dispatcher: dispatcher, line: first)
            remainingLines.removeFirst()
        }
        for line in remainingLines {
            dispatchLineConcurrently(fd: fd, token: token, dispatcher: dispatcher, line: line)
        }
    }

    /// CF-01: dispatches one already-framed line as its own `Task`, tracked
    /// by `inFlightDispatchCount` so `drainInbound(fd:)` can tell the
    /// difference between "framing is done" and "every response owed for
    /// what was framed has actually been enqueued" -- see
    /// `finishDispatch(fd:)`, the only place that count is decremented.
    private func dispatchLineConcurrently(fd: Int32, token: UUID, dispatcher: ControlChannelDispatcher, line: String) {
        guard connectionTokens[fd] == token else { return }
        guard (inFlightDispatchCount[token] ?? 0) < Self.inFlightRequestBound else {
            closeConnection(fd, token: token)
            return
        }
        inFlightDispatchCount[token, default: 0] += 1
        Task {
            guard await self.connectionTokens[fd] == token else { return }
            await self.processLine(fd: fd, token: token, dispatcher: dispatcher, line: line)
            await self.finishDispatch(fd: fd, token: token)
        }
    }

    /// Runs after one dispatched line's response has been enqueued.
    /// `drainInbound(fd:)` defers the close-after-EOF sentinel to here
    /// (via `framingDoneAwaitingDispatch`) when framing finished while
    /// dispatch was still catching up, so a connection can never close
    /// while a response it already owes is still in flight.
    private func finishDispatch(fd: Int32, token: UUID) {
        guard connectionTokens[fd] == token else {
            inFlightDispatchCount.removeValue(forKey: token)
            framingDoneAwaitingDispatch.remove(token)
            return
        }
        let remaining = (inFlightDispatchCount[token] ?? 1) - 1
        if remaining <= 0 {
            inFlightDispatchCount.removeValue(forKey: token)
        } else {
            inFlightDispatchCount[token] = remaining
            return
        }
        if framingDoneAwaitingDispatch.remove(token) != nil {
            enqueueCloseAfterOutboundDrains(fd: fd, token: token)
        }
    }

    /// Answers one framed line via `dispatcher.handleLine(_:)` -- the
    /// single call a transport makes per request line -- and, only for a
    /// *successful* `events.subscribe`, starts this connection's event
    /// relay. The method-name and success sniffs are cheap, generic JSON
    /// shape checks (never a re-derivation of routing/gate logic, which
    /// stays entirely inside the dispatcher).
    private func processLine(fd: Int32, token: UUID, dispatcher: ControlChannelDispatcher, line: String) async {
        guard connectionTokens[fd] == token else { return }
        let lineData = Data(line.utf8)
        let isEventsSubscribeRequest = Self.methodName(of: lineData) == Self.eventsSubscribeMethod
        let responseData = await dispatcher.handleLine(lineData)
        if isEventsSubscribeRequest, Self.isSuccessResponse(responseData) {
            startEventRelay(fd: fd, token: token, dispatcher: dispatcher)
        }
        var out = responseData
        out.append(0x0A)
        enqueue(fd: fd, bytes: out, droppable: false, token: token)
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
    private func refuseOversizedLine(fd: Int32, token: UUID, dispatcher: ControlChannelDispatcher) async {
        guard connectionTokens[fd] == token else { return }
        let payload = ControlErrorPayload(
            .invalidParams,
            message: "Request line exceeded \(ControlChannelDispatcher.maxRequestLineBytes) bytes before a newline was seen."
        )
        if let data = try? JSONEncoder().encode(ControlResponseErrorEnvelope(id: 0, error: payload, hardwareVerification: await dispatcher.currentHardwareVerification)) {
            var out = data
            out.append(0x0A)
            await write(fd: fd, token: token, bytes: out)
        }
        closeConnection(fd, token: token)
    }

    // MARK: Event relay (Task 3)

    /// After a connection's dispatcher answers `events.subscribe`
    /// successfully, iterates the dispatcher's own event stream (snapshot
    /// first, then changes -- D-06) and enqueues each element as a
    /// droppable outbound entry. At most one relay task per connection.
    private func startEventRelay(fd: Int32, token: UUID, dispatcher: ControlChannelDispatcher) {
        guard relayTasks[fd] == nil else { return }
        relayTasks[fd] = Task { [weak self] in
            let stream = await dispatcher.subscribeToEvents()
            for await eventData in stream {
                guard let self else { return }
                var out = eventData
                out.append(0x0A)
                await self.enqueue(fd: fd, bytes: out, droppable: true, token: token)
            }
        }
    }

    /// Appends to this connection's outbound queue and kicks its drain
    /// loop. When the queue exceeds `outboundQueueBound`, removes the
    /// *oldest droppable* entry (never a response) and counts it as
    /// dropped for this connection.
    private func enqueue(fd: Int32, bytes: Data, droppable: Bool, token: UUID? = nil) {
        guard connections[fd] != nil,
              token == nil || connectionTokens[fd] == token else { return }
        var queue = outboundQueues[fd] ?? []
        queue.append(OutboundEntry(bytes: bytes, droppable: droppable))
        while queue.count > Self.outboundQueueBound {
            guard let dropIndex = queue.firstIndex(where: { $0.droppable }) else {
                closeConnection(fd, token: token)
                return
            }
            queue.remove(at: dropIndex)
            droppedEventCounts[fd, default: 0] += 1
        }
        outboundQueues[fd] = queue
        kickDrain(fd: fd)
    }

    /// CF-01: appends the close sentinel described on `OutboundEntry`
    /// rather than closing directly -- see `drainInbound(fd:)`, the only
    /// caller.
    private func enqueueCloseAfterOutboundDrains(fd: Int32, token: UUID) {
        guard connections[fd] != nil, connectionTokens[fd] == token else { return }
        var queue = outboundQueues[fd] ?? []
        queue.append(OutboundEntry(bytes: Data(), droppable: false, isCloseSentinel: true))
        outboundQueues[fd] = queue
        kickDrain(fd: fd)
    }

    private func kickDrain(fd: Int32) {
        guard let token = connectionTokens[fd], !draining.contains(token) else { return }
        draining.insert(token)
        Task { await self.drainLoop(fd: fd, token: token) }
    }

    /// Pops one entry at a time, on the actor, then suspends on a
    /// continuation resumed from the connection's own write queue once the
    /// blocking write completes -- so a stalled peer suspends only its own
    /// connection's drain, never the actor and never another connection.
    ///
    /// CF-01: a popped close sentinel closes the connection right there
    /// and returns, *before* attempting to write it (it carries no real
    /// bytes) -- by the time it reaches the front of this FIFO queue,
    /// every response enqueued before it has already been written.
    private func drainLoop(fd: Int32, token: UUID) async {
        defer { draining.remove(token) }
        while connectionTokens[fd] == token, connections[fd] != nil {
            guard var queue = outboundQueues[fd], !queue.isEmpty else { break }
            let entry = queue.removeFirst()
            outboundQueues[fd] = queue

            if entry.isCloseSentinel {
                closeConnection(fd, token: token)
                return
            }

            if entry.droppable {
                let dropped = droppedEventCounts[fd] ?? 0
                if dropped > 0 {
                    droppedEventCounts[fd] = 0
                    let verification = await dispatchers[fd]?.currentHardwareVerification ?? "notConnected"
                    if var notice = Self.encodedDroppedNotice(droppedEvents: dropped, hardwareVerification: verification) {
                        notice.append(0x0A)
                        await write(fd: fd, token: token, bytes: notice)
                    }
                }
            }
            await write(fd: fd, token: token, bytes: entry.bytes)
        }
    }

    /// The actual blocking `FileHandle.write(contentsOf:)`, performed on
    /// this connection's own dedicated serial queue -- never the actor,
    /// never `.main`. The actor only suspends on the continuation; it does
    /// not block.
    private func write(fd: Int32, token: UUID? = nil, bytes: Data) async {
        guard token == nil || connectionTokens[fd] == token,
              let handle = connections[fd] else { return }
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

    private static func encodedDroppedNotice(droppedEvents: Int, hardwareVerification: String) -> Data? {
        struct DroppedEventPayload: Encodable { let droppedEvents: Int }
        return try? JSONEncoder().encode(
            ControlEventEnvelope(event: "control.dropped", payload: DroppedEventPayload(droppedEvents: droppedEvents), hardwareVerification: hardwareVerification)
        )
    }

    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func socketIdentity(at path: String) throws -> SocketIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw ControlSocketError(context: "lstat(\(path))", errnoValue: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw ControlSocketError(context: "\(path) is not a socket", errnoValue: EINVAL)
        }
        return SocketIdentity(device: info.st_dev, inode: info.st_ino)
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
    private func closeConnection(_ fd: Int32, token: UUID? = nil) {
        if let token, connectionTokens[fd] != token { return }
        guard let handle = connections.removeValue(forKey: fd) else { return }
        let currentToken = connectionTokens.removeValue(forKey: fd)
        handle.readabilityHandler = nil
        try? handle.close()
        framers.removeValue(forKey: fd)
        dispatchers.removeValue(forKey: fd)
        pendingLineBytes.removeValue(forKey: fd)
        inboxes.removeValue(forKey: fd)
        if let currentToken {
            feedingInbound.remove(currentToken)
            inFlightDispatchCount.removeValue(forKey: currentToken)
            framingDoneAwaitingDispatch.remove(currentToken)
        }
        outboundQueues.removeValue(forKey: fd)
        droppedEventCounts.removeValue(forKey: fd)
        writeQueues.removeValue(forKey: fd)
        if let currentToken { draining.remove(currentToken) }
        relayTasks.removeValue(forKey: fd)?.cancel()
    }
}
