import Darwin
import Foundation
import ScanStudioKit

struct ActiveJobMarker: Codable, Equatable {
    static let filename = ".scanstudio-active-job.json"
    private static let lockFilename = ".scanstudio-active-job.lock"

    let schemaVersion: Int
    let jobId: String
    let socketPath: String
    let hostPid: Int32
    let diagnosticSessionId: String
    let projectDirectory: String
    let createdAt: String
    let correlationToken: String?
    var hookDeliveries: [HookDelivery]

    struct HookDelivery: Codable, Equatable {
        let key: String
        let kind: String
        let frameIndex: Int?
        let receiptKey: String?
        let receiptPath: String?
        let errorJSON: String?
        let recordedAt: String
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, jobId, socketPath, hostPid, diagnosticSessionId
        case projectDirectory, createdAt, correlationToken, hookDeliveries
    }

    init(
        schemaVersion: Int,
        jobId: String,
        socketPath: String,
        hostPid: Int32,
        diagnosticSessionId: String,
        projectDirectory: String,
        createdAt: String,
        correlationToken: String?,
        hookDeliveries: [HookDelivery]
    ) {
        self.schemaVersion = schemaVersion
        self.jobId = jobId
        self.socketPath = socketPath
        self.hostPid = hostPid
        self.diagnosticSessionId = diagnosticSessionId
        self.projectDirectory = projectDirectory
        self.createdAt = createdAt
        self.correlationToken = correlationToken
        self.hookDeliveries = hookDeliveries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        jobId = try values.decode(String.self, forKey: .jobId)
        socketPath = try values.decode(String.self, forKey: .socketPath)
        hostPid = try values.decode(Int32.self, forKey: .hostPid)
        diagnosticSessionId = try values.decode(String.self, forKey: .diagnosticSessionId)
        projectDirectory = try values.decode(String.self, forKey: .projectDirectory)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        correlationToken = try values.decodeIfPresent(String.self, forKey: .correlationToken)
        hookDeliveries = try values.decodeIfPresent([HookDelivery].self, forKey: .hookDeliveries) ?? []
    }

    struct Context {
        let socketPath: String
        let hostPid: Int32
        let diagnosticSessionId: String
        let projectDirectory: String

        var url: URL {
            URL(fileURLWithPath: projectDirectory).appendingPathComponent(ActiveJobMarker.filename)
        }

        var lockURL: URL {
            URL(fileURLWithPath: projectDirectory).appendingPathComponent(ActiveJobMarker.lockFilename)
        }
    }

    enum Invalid: Error, LocalizedError {
        case context
        case document(String)

        var errorDescription: String? {
            switch self {
            case .context:
                return "The control host did not provide the project and diagnostic identity required for a job marker."
            case .document(let message):
                return message
            }
        }
    }

    static func context(
        client: ControlChannelClient,
        socketPath: String,
        projectDirectory override: String? = nil
    ) async throws -> Context? {
        guard let hello = await client.helloResult else { throw Invalid.context }
        guard let projectDirectory = override ?? hello.projectDirectory else { return nil }
        guard let diagnosticSessionId = hello.diagnosticSessionId, !diagnosticSessionId.isEmpty else {
            throw Invalid.context
        }
        return Context(
            socketPath: socketPath,
            hostPid: hello.hostPid,
            diagnosticSessionId: diagnosticSessionId,
            projectDirectory: projectDirectory
        )
    }

    static func load(from context: Context) throws -> Self? {
        try withLock(context) { try loadUnlocked(from: context) }
    }

    private static func loadUnlocked(from context: Context) throws -> Self? {
        let descriptor = Darwin.open(
            context.url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= 65_536 else {
            throw Invalid.document("The active-job marker must be one owned regular file of at most 64 KiB.")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while data.count <= 65_536 {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, 65_537 - data.count))
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= 65_536 else { throw Invalid.document("The active-job marker exceeds 64 KiB.") }
        let marker = try JSONDecoder().decode(Self.self, from: data)
        guard marker.schemaVersion == 1, !marker.jobId.isEmpty else {
            throw Invalid.document("The active-job marker has an unsupported schema or empty job ID.")
        }
        return marker
    }

    func matches(_ context: Context) -> Bool {
        socketPath == context.socketPath
            && hostPid == context.hostPid
            && diagnosticSessionId == context.diagnosticSessionId
            && projectDirectory == context.projectDirectory
    }

    static func write(jobId: String, context: Context, correlationToken: String? = nil) throws -> Self {
        let marker = Self(
            schemaVersion: 1,
            jobId: jobId,
            socketPath: context.socketPath,
            hostPid: context.hostPid,
            diagnosticSessionId: context.diagnosticSessionId,
            projectDirectory: context.projectDirectory,
            createdAt: ControlRunReceipt.isoTimestamp(),
            correlationToken: correlationToken,
            hookDeliveries: []
        )
        return try withLock(context) {
            if let existing = try loadUnlocked(from: context) {
                guard existing.sameJob(as: marker) else {
                    throw Invalid.document("A different active job is already recorded for this project.")
                }
                return existing
            }
            try writeUnlocked(marker, to: context.url)
            return marker
        }
    }

    static func retire(_ marker: Self, from context: Context) throws {
        try withLock(context) {
            guard let current = try loadUnlocked(from: context), current.sameJob(as: marker) else { return }
            let archive = URL(fileURLWithPath: context.projectDirectory)
                .appendingPathComponent(".scanstudio-job-marker-\(UUID().uuidString).json")
            try writeExclusive(try encoded(current), to: archive)
            try FileManager.default.removeItem(at: context.url)
        }
    }

    static func reserveDelivery(
        _ delivery: HookDelivery,
        for marker: Self,
        context: Context
    ) throws -> Bool {
        try withLock(context) {
            guard var current = try loadUnlocked(from: context), current.sameJob(as: marker) else {
                throw Invalid.document("The active job changed before hook delivery could be recorded.")
            }
            guard !current.hookDeliveries.contains(where: { $0.key == delivery.key }) else { return false }
            current.hookDeliveries.append(delivery)
            try writeUnlocked(current, to: context.url)
            return true
        }
    }

    private func sameJob(as other: Self) -> Bool {
        jobId == other.jobId
            && socketPath == other.socketPath
            && hostPid == other.hostPid
            && diagnosticSessionId == other.diagnosticSessionId
            && projectDirectory == other.projectDirectory
            && createdAt == other.createdAt
    }

    private static func withLock<T>(_ context: Context, _ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(
            context.lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw Invalid.document("The active-job lock is not one owned regular file.")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func encoded(_ marker: Self) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        guard data.count <= 65_536 else { throw Invalid.document("The active-job marker exceeds 64 KiB.") }
        return data
    }

    private static func writeUnlocked(_ marker: Self, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try writeExclusive(try encoded(marker), to: temporary)
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
