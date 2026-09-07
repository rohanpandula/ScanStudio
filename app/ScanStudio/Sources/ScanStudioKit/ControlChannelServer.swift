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

    private static let listenBacklog: Int32 = 8

    public init(sessionModel: SessionModel) {
        self.sessionModel = sessionModel
        // Matches `EngineClient.init`'s own rationale verbatim: a write to a
        // peer that has already closed its end (a disconnected control
        // client, or -- in a test process that never constructs a real
        // `EngineClient` -- the *first* place SIGPIPE's default
        // process-killing disposition would ever be touched at all) must
        // degrade to an EPIPE error on the write call, not terminate the
        // process. Safe to call repeatedly; a global signal disposition,
        // not per-connection state.
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

    /// `EngineClient.swift:170-179`'s exact shape: only synchronous work
    /// (`accept()`) happens in the event handler; everything else hops into
    /// a `Task` immediately.
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

    /// Task 1 scope: accept and immediately close. Task 2 constructs the
    /// per-connection `ControlChannelDispatcher` and wires line handling
    /// here.
    private func adopt(_ fd: Int32) {
        close(fd)
    }
}
