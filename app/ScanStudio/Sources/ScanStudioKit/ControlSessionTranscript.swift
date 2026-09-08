import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Opts one control-channel connection into the CLI's append-only session log.
/// Other library clients remain memory-only unless they pass this explicitly.
public struct ControlSessionTranscriptOptions: Sendable {
    typealias LineWriter = @Sendable (FileHandle, Data) throws -> Void

    public let invocationID: String
    public let fallbackDirectory: URL
    let lineWriter: LineWriter

    public init(invocationID: String, fallbackDirectory: URL) {
        self.invocationID = invocationID
        self.fallbackDirectory = fallbackDirectory
        self.lineWriter = { handle, data in try handle.write(contentsOf: data) }
    }

    init(
        invocationID: String,
        fallbackDirectory: URL,
        lineWriter: @escaping LineWriter
    ) {
        self.invocationID = invocationID
        self.fallbackDirectory = fallbackDirectory
        self.lineWriter = lineWriter
    }

    public static func cli(invocationID: String = UUID().uuidString.lowercased()) -> Self {
        Self(
            invocationID: invocationID,
            fallbackDirectory: ControlSocketPath.directoryURL()
                .appendingPathComponent("sessions", isDirectory: true)
        )
    }
}

/// A complete-line snapshot suitable for a later evidence export while the
/// owning CLI invocation may still be appending.
public struct ControlSessionTranscriptSnapshot: Sendable, Equatable {
    public let path: String
    public let data: Data
    public let byteCount: Int
}

/// One connection's ordered NDJSON authority. The enclosing
/// `ControlChannelClient` actor serializes access; this type only owns the
/// create-only append descriptor and the pre-hello buffer.
struct ControlSessionTranscript {
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ info: stat) {
            device = UInt64(bitPattern: Int64(info.st_dev))
            inode = UInt64(info.st_ino)
        }
    }

    private struct FileState: Equatable {
        let identity: FileIdentity
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ info: stat) {
            identity = FileIdentity(info)
            size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    private static let maximumSnapshotBytes: Int64 = 64 * 1024 * 1024

    private let options: ControlSessionTranscriptOptions
    private var bufferedLines: [Data] = []
    private var handle: FileHandle?
    private var sourceIdentity: FileIdentity?
    private(set) var fileURL: URL?
    private var startedInProject = false

    init(options: ControlSessionTranscriptOptions) {
        self.options = options
    }

    mutating func record(
        direction: String,
        requestID: UInt64?,
        method: String,
        hardwareVerification: String,
        originalJSON: Data
    ) throws {
        let original = try JSONSerialization.jsonObject(with: originalJSON)
        let record: [String: Any] = [
            "schemaVersion": 1,
            "timestamp": ControlRunReceipt.isoTimestamp(),
            "invocationId": options.invocationID,
            "controlRequestId": requestID.map { NSNumber(value: $0) } ?? NSNull(),
            "method": method,
            "direction": direction,
            "hardwareVerification": hardwareVerification,
            "original": original,
        ]
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        line.append(0x0A)
        if let handle {
            try options.lineWriter(handle, line)
        } else {
            bufferedLines.append(line)
        }
    }

    mutating func activate(diagnosticSessionID: String?, projectDirectory: String?) throws {
        guard handle == nil, fileURL == nil else { return }
        let project = projectDirectory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = project ?? options.fallbackDirectory
        startedInProject = project != nil
        let directoryDescriptor = try prepare(directory: directory, mayCreate: project == nil)
        defer { _ = Darwin.close(directoryDescriptor) }

        let session = safeComponent(diagnosticSessionID ?? "unknown-session")
        let invocation = safeComponent(options.invocationID)
        let filename = "cli-session-\(session)-\(invocation).ndjson"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        let (newHandle, identity) = try createOwnerOnlyFile(
            named: filename,
            in: directoryDescriptor,
            displayURL: url
        )
        do {
            for line in bufferedLines { try options.lineWriter(newHandle, line) }
            bufferedLines.removeAll(keepingCapacity: false)
            handle = newHandle
            sourceIdentity = identity
            fileURL = url
        } catch {
            try? newHandle.close()
            throw error
        }
    }

    func snapshot() throws -> ControlSessionTranscriptSnapshot? {
        guard let fileURL, let handle, let sourceIdentity else { return nil }
        try handle.synchronize()
        let descriptor = handle.fileDescriptor
        let before = try validatedState(of: descriptor, path: fileURL.path)
        guard before.identity == sourceIdentity else {
            throw posixError("validate", path: fileURL.path, code: ESTALE)
        }
        try validateNamespace(path: fileURL.path, identity: sourceIdentity)
        guard before.size >= 0, before.size <= Self.maximumSnapshotBytes else {
            throw posixError("snapshot", path: fileURL.path, code: EFBIG)
        }

        var bytes = Data(count: Int(before.size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw posixError("pread", path: fileURL.path, code: count == 0 ? EIO : errno)
            }
            offset += count
        }

        let after = try validatedState(of: descriptor, path: fileURL.path)
        guard after == before else {
            throw posixError("snapshot", path: fileURL.path, code: EBUSY)
        }
        try validateNamespace(path: fileURL.path, identity: sourceIdentity)
        let complete = bytes.lastIndex(of: 0x0A).map { Data(bytes.prefix(through: $0)) } ?? Data()
        return ControlSessionTranscriptSnapshot(
            path: fileURL.path,
            data: complete,
            byteCount: complete.count
        )
    }

    mutating func close(copyToProjectDirectory projectDirectory: String? = nil) throws {
        let copySnapshot: ControlSessionTranscriptSnapshot?
        if !startedInProject,
           let projectDirectory,
           !projectDirectory.isEmpty {
            copySnapshot = try snapshot()
        } else {
            copySnapshot = nil
        }

        if let handle {
            try handle.synchronize()
            try handle.close()
            self.handle = nil
        }
        guard let copySnapshot, let projectDirectory else { return }

        let directory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        let directoryDescriptor = try prepare(directory: directory, mayCreate: false)
        defer { _ = Darwin.close(directoryDescriptor) }
        let filename = URL(fileURLWithPath: copySnapshot.path).lastPathComponent
        let destination = directory.appendingPathComponent(filename)
        let (destinationHandle, _) = try createOwnerOnlyFile(
            named: filename,
            in: directoryDescriptor,
            displayURL: destination
        )
        do {
            try destinationHandle.write(contentsOf: copySnapshot.data)
            try destinationHandle.synchronize()
            try destinationHandle.close()
        } catch {
            try? destinationHandle.close()
            throw error
        }
    }

    private func prepare(directory: URL, mayCreate: Bool) throws -> Int32 {
        guard directory.path.hasPrefix("/") else {
            throw posixError("prepareDirectory", path: directory.path, code: EINVAL)
        }
        if mayCreate {
            let parent = directory.deletingLastPathComponent()
            if parent.path == ControlSocketPath.directoryURL().path {
                try ControlSocketPath.prepareDirectory(for: ControlSocketPath.defaultPath())
            }
            let parentDescriptor = try openDirectory(at: parent)
            defer { _ = Darwin.close(parentDescriptor) }
            try validateOwnedDirectory(parentDescriptor, path: parent.path)
            if mkdirat(parentDescriptor, directory.lastPathComponent, mode_t(0o700)) != 0 {
                let code = errno
                guard code == EEXIST else {
                    throw posixError("mkdirat", path: directory.path, code: code)
                }
            }
            let descriptor = try openDirectory(
                named: directory.lastPathComponent,
                in: parentDescriptor,
                path: directory.path
            )
            do {
                try validateOwnedDirectory(descriptor, path: directory.path)
                guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                    throw posixError("fchmod", path: directory.path)
                }
                return descriptor
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }

        let descriptor = try openDirectory(at: directory)
        do {
            try validateOwnedDirectory(descriptor, path: directory.path)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func openDirectory(at directory: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError("open", path: directory.path) }
        return descriptor
    }

    private func openDirectory(named name: String, in parent: Int32, path: String) throws -> Int32 {
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError("openat", path: path) }
        return descriptor
    }

    private func validateOwnedDirectory(_ descriptor: Int32, path: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw posixError("fstat", path: path)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
            throw posixError("validateDirectory", path: path, code: EACCES)
        }
    }

    private func safeComponent(_ value: String) -> String {
        let filtered = value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return filtered.isEmpty ? "unknown" : filtered
    }

    private func createOwnerOnlyFile(
        named name: String,
        in directory: Int32,
        displayURL: URL
    ) throws -> (FileHandle, FileIdentity) {
        let descriptor = Darwin.openat(
            directory,
            name,
            O_CREAT | O_EXCL | O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw posixError("openat", path: displayURL.path) }
        do {
            let state = try validatedState(of: descriptor, path: displayURL.path)
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw posixError("fchmod", path: displayURL.path)
            }
            return (
                FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                state.identity
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func validatedState(of descriptor: Int32, path: String) throws -> FileState {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw posixError("fstat", path: path)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1 else {
            throw posixError("validate", path: path, code: EACCES)
        }
        return FileState(info)
    }

    private func validateNamespace(path: String, identity: FileIdentity) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              FileIdentity(info) == identity else {
            throw posixError("validateNamespace", path: path, code: ESTALE)
        }
    }

    private func posixError(_ operation: String, path: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation)(\(path)): \(String(cString: strerror(code)))"]
        )
    }
}
