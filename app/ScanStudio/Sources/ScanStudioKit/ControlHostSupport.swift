import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// D-03: the on-disk paths owned by a resident headless host.
public enum ControlHostPaths {
    public static func pidfilePath(forSocket socketPath: String) -> String {
        socketPath + ".pid"
    }

    public static func defaultLogPath() -> String {
        ControlSocketPath.directoryURL().appendingPathComponent("logs/host.log").path
    }
}

/// D-03: pidfiles are advisory state. They are owner-only, reject symlinks,
/// and are opened with descriptor-level no-follow protection because an
/// `lstat` followed by an ordinary `open` is racy.
public enum ControlHostPidfile {
    public static func write(pid: Int32, at path: String) throws {
        try validatePath(path)
        guard pid > 1 else { throw ControlSocketError(context: "pidfile(\(path)): invalid pid \(pid)", errnoValue: EINVAL) }
        try ControlSocketPath.prepareDirectory(for: path)
        let descriptor = open(path, O_CREAT | O_WRONLY | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard descriptor >= 0 else { throw ControlSocketError(context: "open(\(path))", errnoValue: errno) }
        defer { _ = close(descriptor) }
        try verifyRegularFile(descriptor, path: path)
        guard try fstatLinkCount(descriptor, path: path) == 1 else {
            throw ControlSocketError(context: "pidfile(\(path)): refusing a hard-linked file", errnoValue: EMLINK)
        }
        guard ftruncate(descriptor, 0) == 0 else {
            throw ControlSocketError(context: "ftruncate(\(path))", errnoValue: errno)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ControlSocketError(context: "fchmod(\(path), 0o600)", errnoValue: errno)
        }
        try writeAll(Data("\(pid)\n".utf8), to: descriptor, path: path)
    }

    public static func read(at path: String) throws -> Int32? {
        try validatePath(path)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            let openErrno = errno
            if openErrno == ENOENT { return nil }
            throw ControlSocketError(context: "open(\(path))", errnoValue: openErrno)
        }
        defer { _ = close(descriptor) }
        try verifyRegularFile(descriptor, path: path)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0 else { throw ControlSocketError(context: "read(\(path))", errnoValue: errno) }
            bytes.append(buffer, count: count)
            guard bytes.count <= 4096 else {
                throw ControlSocketError(context: "read(\(path)): pidfile is too large", errnoValue: EINVAL)
            }
        }
        guard let body = String(data: bytes, encoding: .utf8),
              body.last == "\n",
              let pid = Int32(body.dropLast()),
              pid > 1 else {
            throw ControlSocketError(context: "read(\(path)): invalid pidfile", errnoValue: EINVAL)
        }
        return pid
    }

    public static func remove(at path: String) throws {
        try validatePath(path)
        guard unlink(path) != 0 else { return }
        let unlinkErrno = errno
        guard unlinkErrno == ENOENT else {
            throw ControlSocketError(context: "unlink(\(path))", errnoValue: unlinkErrno)
        }
    }

    /// Removes only this host's pidfile. The resident calls this while it
    /// still owns the socket, before another legitimate host can replace it.
    @discardableResult
    public static func remove(at path: String, ifPIDMatches expectedPID: Int32) throws -> Bool {
        guard try read(at: path) == expectedPID else { return false }
        try remove(at: path)
        return true
    }

    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw ControlSocketError(context: "validate(\(path)): path must be absolute", errnoValue: EINVAL)
        }
        var info = stat()
        if lstat(path, &info) != 0 {
            let lstatErrno = errno
            guard lstatErrno == ENOENT else {
                throw ControlSocketError(context: "lstat(\(path))", errnoValue: lstatErrno)
            }
        } else if (info.st_mode & S_IFMT) == S_IFLNK {
            throw ControlSocketError(context: "validate(\(path)): refusing an existing symlink", errnoValue: ELOOP)
        }
    }

    private static func verifyRegularFile(_ descriptor: Int32, path: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw ControlSocketError(context: "fstat(\(path))", errnoValue: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ControlSocketError(context: "\(path) is not a regular file", errnoValue: EINVAL)
        }
    }

    private static func fstatLinkCount(_ descriptor: Int32, path: String) throws -> nlink_t {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw ControlSocketError(context: "fstat(\(path))", errnoValue: errno)
        }
        return info.st_nlink
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBytes in
            guard let base = rawBytes.baseAddress else { return }
            var offset = 0
            while offset < rawBytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBytes.count - offset)
                guard count > 0 else { throw ControlSocketError(context: "write(\(path))", errnoValue: errno) }
                offset += count
            }
        }
    }
}

/// D-03 / Pitfall 2: a PID is reused by the OS, so a pidfile alone is never
/// authority to signal. Only a live hello reporting the same pid is trusted.
public enum ControlHostStopDecision {
    public enum Outcome: Equatable, Sendable {
        case signal(pid: Int32)
        case noPidfile
        case stalePidfile(recordedPid: Int32, reason: String)
        case refuseGuiHost(hostPid: Int32)
    }

    public static func decide(recordedPid: Int32?, hello: ControlHelloResult?) -> Outcome {
        guard let recordedPid else { return .noPidfile }
        guard let hello else {
            return .stalePidfile(recordedPid: recordedPid, reason: "no host is answering the control socket")
        }
        guard hello.host != .gui else { return .refuseGuiHost(hostPid: hello.hostPid) }
        guard hello.hostPid == recordedPid else {
            return .stalePidfile(
                recordedPid: recordedPid,
                reason: "the live host reports pid \(hello.hostPid), the pidfile records \(recordedPid) — the pid may have been reused"
            )
        }
        return .signal(pid: recordedPid)
    }
}
