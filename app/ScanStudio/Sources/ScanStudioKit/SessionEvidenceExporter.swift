import CryptoKit
import Darwin
import Foundation

public struct SessionEvidenceInventoryEntry: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case file(URL, allowedRoot: URL)
        case missing(reason: String)
    }

    public let entryName: String
    public let sourceKind: String
    public let source: Source
    public let expectedSha256: String?

    public init(
        entryName: String,
        sourceKind: String,
        source: Source,
        expectedSha256: String? = nil
    ) {
        self.entryName = entryName
        self.sourceKind = sourceKind
        self.source = source
        self.expectedSha256 = expectedSha256
    }
}

public extension ControlSessionInventoryResult {
    /// Converts the control-wire representation only after enforcing its
    /// exactly-one-of file authority or missing-reason invariant.
    func exportEntries() throws -> [SessionEvidenceInventoryEntry] {
        try entries.map { entry in
            let source: SessionEvidenceInventoryEntry.Source
            switch (entry.path, entry.allowedRoot, entry.missingReason) {
            case let (.some(path), .some(root), .none):
                source = .file(
                    URL(fileURLWithPath: path),
                    allowedRoot: URL(fileURLWithPath: root)
                )
            case let (.none, .none, .some(reason))
                where !reason.isEmpty && entry.expectedSha256 == nil:
                source = .missing(reason: reason)
            default:
                throw SessionEvidenceExportError.invalidInventory(
                    "\(entry.entryName) must contain either path+allowedRoot or missingReason"
                )
            }
            return SessionEvidenceInventoryEntry(
                entryName: entry.entryName,
                sourceKind: entry.sourceKind,
                source: source,
                expectedSha256: entry.expectedSha256
            )
        }
    }
}

public struct SessionEvidenceExportResult: Codable, Equatable, Sendable {
    public let path: String
    public let includedEntryCount: Int
    public let missingEntryCount: Int
}

public enum SessionEvidenceExportError: Error, Equatable, LocalizedError, Sendable {
    case invalidInventory(String)
    case unsafeSource(String)
    case changedSource(String)
    case limitExceeded(String)
    case invalidTranscript(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInventory(let reason): "Invalid session evidence inventory: \(reason)"
        case .unsafeSource(let reason): "Unsafe session evidence source: \(reason)"
        case .changedSource(let reason): "Session evidence source changed during export: \(reason)"
        case .limitExceeded(let reason): "Session evidence export limit exceeded: \(reason)"
        case .invalidTranscript(let reason): "Invalid control transcript snapshot: \(reason)"
        }
    }
}

public enum SessionEvidenceExporter {
    private struct Manifest: Encodable {
        let schemaVersion = 1
        let entries: [ManifestEntry]
    }

    private struct ManifestEntry: Encodable {
        let entryName: String
        let sourceKind: String
        let byteLength: Int?
        let sha256: String?
        let missingReason: String?
    }

    private struct FileState: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let links: UInt64
        let blocks: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ info: stat) {
            device = UInt64(bitPattern: Int64(info.st_dev))
            inode = UInt64(info.st_ino)
            size = info.st_size
            links = UInt64(info.st_nlink)
            blocks = info.st_blocks
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    private struct ReadSnapshot {
        let source: URL
        let data: Data
        let state: FileState
        let canonicalPath: String
        let handle: FileHandle
        let allowedRoot: DirectoryAuthority
    }

    private struct DirectoryAuthority {
        let url: URL
        let canonicalPath: String
        let device: UInt64
        let inode: UInt64
        let handle: FileHandle
    }

    private struct OutputProof {
        let handle: FileHandle
        let state: FileState
        let sha256: String
    }

    private static let transcriptEntryName = "control-transcript.ndjson"
    private static let maximumEntries = 1_024
    // ponytail: StoredZipWriter is in-memory, so keep this export at 64 MiB
    // per source and 256 MiB total; add a streaming ZIP writer only when a
    // real session evidence set exceeds these bounds.
    private static let maximumSourceBytes: Int64 = 64 * 1024 * 1024
    private static let maximumAggregateBytes: Int64 = 256 * 1024 * 1024

    public static func export(
        inventory: [SessionEvidenceInventoryEntry],
        transcript: ControlSessionTranscriptSnapshot?,
        to destination: URL
    ) throws -> SessionEvidenceExportResult {
        try export(
            inventory: inventory,
            transcript: transcript,
            to: destination,
            sourceDidRead: nil
        )
    }

    /// Reads one optional inventory source through the same held-root and
    /// held-file checks used by export. The returned bytes are the verified
    /// immutable snapshot; a declared-missing optional returns `nil`.
    public static func verifiedSnapshot(
        of entry: SessionEvidenceInventoryEntry
    ) throws -> Data? {
        switch entry.source {
        case .missing:
            return nil
        case .file(let source, let allowedRoot):
            let snapshot = try readStableFile(source, allowedRoot: allowedRoot)
            defer {
                try? snapshot.handle.close()
                try? snapshot.allowedRoot.handle.close()
            }
            try verifyStableFile(snapshot)
            try verifyExpectedHash(entry.expectedSha256, data: snapshot.data, name: entry.entryName)
            return snapshot.data
        }
    }

    static func export(
        inventory: [SessionEvidenceInventoryEntry],
        transcript: ControlSessionTranscriptSnapshot?,
        to destination: URL,
        sourceDidRead: ((URL) throws -> Void)?
    ) throws -> SessionEvidenceExportResult {
        guard inventory.count <= maximumEntries else {
            throw SessionEvidenceExportError.limitExceeded("more than \(maximumEntries) inventory entries")
        }

        var archiveEntries: [StoredZipWriter.Entry] = []
        var manifestEntries: [ManifestEntry] = []
        var seenNames = Set<String>()
        var aggregateBytes: Int64 = 0
        var heldSources: [ReadSnapshot] = []
        defer {
            for source in heldSources {
                try? source.handle.close()
                try? source.allowedRoot.handle.close()
            }
        }

        for item in inventory {
            try validate(entryName: item.entryName, sourceKind: item.sourceKind)
            guard item.entryName != "manifest.json", item.entryName != transcriptEntryName,
                  seenNames.insert(item.entryName).inserted else {
                throw SessionEvidenceExportError.invalidInventory(
                    "duplicate or reserved entry name \(item.entryName)"
                )
            }
            switch item.source {
            case .file(let source, let allowedRoot):
                let snapshot = try readStableFile(source, allowedRoot: allowedRoot)
                do {
                    try sourceDidRead?(source)
                    try verifyStableFile(snapshot)
                    try verifyExpectedHash(item.expectedSha256, data: snapshot.data, name: item.entryName)
                    heldSources.append(snapshot)
                } catch {
                    try? snapshot.handle.close()
                    try? snapshot.allowedRoot.handle.close()
                    throw error
                }
                aggregateBytes = try adding(snapshot.data.count, to: aggregateBytes)
                archiveEntries.append(.init(name: item.entryName, data: snapshot.data))
                manifestEntries.append(includedManifestEntry(
                    name: item.entryName,
                    kind: item.sourceKind,
                    data: snapshot.data
                ))
            case .missing(let reason):
                let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reason.isEmpty else {
                    throw SessionEvidenceExportError.invalidInventory(
                        "missing entry \(item.entryName) has no reason"
                    )
                }
                manifestEntries.append(ManifestEntry(
                    entryName: item.entryName,
                    sourceKind: item.sourceKind,
                    byteLength: nil,
                    sha256: nil,
                    missingReason: String(reason.prefix(512))
                ))
            }
        }

        guard seenNames.insert(transcriptEntryName).inserted else {
            throw SessionEvidenceExportError.invalidInventory(
                "duplicate or reserved entry name \(transcriptEntryName)"
            )
        }
        if let transcript {
            guard transcript.byteCount == transcript.data.count else {
                throw SessionEvidenceExportError.invalidTranscript("byteCount does not match snapshot data")
            }
            guard transcript.data.isEmpty || transcript.data.last == 0x0A else {
                throw SessionEvidenceExportError.invalidTranscript("snapshot does not end at a complete line")
            }
            guard transcript.data.count <= Int(maximumSourceBytes) else {
                throw SessionEvidenceExportError.limitExceeded("control transcript exceeds the source limit")
            }
            aggregateBytes = try adding(transcript.data.count, to: aggregateBytes)
            archiveEntries.append(.init(name: transcriptEntryName, data: transcript.data))
            manifestEntries.append(includedManifestEntry(
                name: transcriptEntryName,
                kind: "controlTranscript",
                data: transcript.data
            ))
        } else {
            manifestEntries.append(ManifestEntry(
                entryName: transcriptEntryName,
                sourceKind: "controlTranscript",
                byteLength: nil,
                sha256: nil,
                missingReason: "no complete-line transcript snapshot was available"
            ))
        }

        archiveEntries.sort { $0.name < $1.name }
        manifestEntries.sort {
            ($0.entryName, $0.sourceKind) < ($1.entryName, $1.sourceKind)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = try encoder.encode(Manifest(entries: manifestEntries))
        aggregateBytes = try adding(manifest.count, to: aggregateBytes)
        archiveEntries.append(.init(name: "manifest.json", data: manifest))
        let archive = StoredZipWriter.write(archiveEntries)
        for source in heldSources { try verifyStableFile(source) }
        let destinationParent = try openDirectoryAuthority(destination.deletingLastPathComponent())
        defer { try? destinationParent.handle.close() }
        let destinationName = destination.lastPathComponent
        guard isPortableComponent(Substring(destinationName)) else {
            throw SessionEvidenceExportError.invalidInventory("unsafe destination filename")
        }
        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(temporaryName)
        var temporaryWasRenamed = false
        defer {
            if !temporaryWasRenamed {
                _ = unlinkat(destinationParent.handle.fileDescriptor, temporaryName, 0)
            }
        }
        var outputProof: OutputProof?
        defer { try? outputProof?.handle.close() }
        try DiagnosticBundleFileWriter.write(
            archive,
            to: temporary,
            writer: { bytes, _ in
                outputProof = try writeHeld(
                    bytes,
                    named: temporaryName,
                    in: destinationParent
                )
            },
            verifier: { _ in
                guard let proof = outputProof,
                      try verifyOutput(
                        proof,
                        named: temporaryName,
                        in: destinationParent,
                        expected: archive,
                        requireStableMetadata: true
                      ) else {
                    return nil
                }
                return Int(proof.state.size)
            }
        )
        for source in heldSources { try verifyStableFile(source) }
        try verifyDirectoryAuthority(destinationParent)
        let renameResult = temporaryName.withCString { temporaryPath in
            destinationName.withCString { destinationPath in
                renameatx_np(
                    destinationParent.handle.fileDescriptor,
                    temporaryPath,
                    destinationParent.handle.fileDescriptor,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            throw DiagnosticBundleSaveError.writeFailed(
                path: destination.path,
                reason: String(cString: strerror(errno))
            )
        }
        temporaryWasRenamed = true
        guard let proof = outputProof,
              try verifyOutput(
                proof,
                named: destinationName,
                in: destinationParent,
                expected: archive,
                requireStableMetadata: false
              ) else {
            throw DiagnosticBundleSaveError.verificationFailed(
                path: destination.path,
                expectedBytes: archive.count,
                actualBytes: nil
            )
        }
        return SessionEvidenceExportResult(
            path: destination.path,
            includedEntryCount: archiveEntries.count - 1,
            missingEntryCount: manifestEntries.lazy.filter { $0.missingReason != nil }.count
        )
    }

    private static func validate(entryName: String, sourceKind: String) throws {
        let components = entryName.split(separator: "/", omittingEmptySubsequences: false)
        guard !entryName.isEmpty,
              !entryName.hasPrefix("/"),
              entryName.utf8.count <= 255,
              components.allSatisfy(isPortableComponent),
              !sourceKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceKind.utf8.count <= 64 else {
            throw SessionEvidenceExportError.invalidInventory(
                "unsafe entry name or source kind for \(entryName)"
            )
        }
    }

    private static func isPortableComponent(_ component: Substring) -> Bool {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.hasSuffix("."),
              !component.hasSuffix(" "),
              !component.unicodeScalars.contains(where: { scalar in
                  scalar.value <= 0x1F || #"<>:"/\|?*"#.unicodeScalars.contains(scalar)
              }) else { return false }
        let base = component.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        let upper = base.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).uppercased()
        if ["CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"].contains(upper) {
            return false
        }
        if upper.count == 4,
           (upper.hasPrefix("COM") || upper.hasPrefix("LPT")),
           upper.last.map({ ("1"..."9").contains(String($0)) }) == true {
            return false
        }
        return true
    }

    private static func readStableFile(_ source: URL, allowedRoot: URL) throws -> ReadSnapshot {
        let root = try openDirectoryAuthority(allowedRoot)
        let canonicalSource: String
        do {
            try verifyDirectoryAuthority(root)
            canonicalSource = try canonicalPath(source)
        } catch {
            try? root.handle.close()
            throw error
        }
        guard canonicalSource.hasPrefix(
            root.canonicalPath.hasSuffix("/") ? root.canonicalPath : root.canonicalPath + "/"
        ) else {
            try? root.handle.close()
            throw SessionEvidenceExportError.unsafeSource(
                "\(source.path) is outside its allowed root"
            )
        }

        let descriptor = Darwin.open(
            source.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            try? root.handle.close()
            throw SessionEvidenceExportError.unsafeSource(
                "could not open \(source.path) without following links: \(String(cString: strerror(errno)))"
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let before = try validatedState(descriptor, source: source)
            try validateNamespace(source, expected: before)
            var data = Data(count: Int(before.size))
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeMutableBytes { bytes in
                    Darwin.pread(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset,
                        off_t(offset)
                    )
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw SessionEvidenceExportError.changedSource(
                        "\(source.path) became shorter while being read"
                    )
                }
                offset += count
            }
            let after = try validatedState(descriptor, source: source)
            guard after == before, try canonicalPath(source) == canonicalSource else {
                throw SessionEvidenceExportError.changedSource(source.path)
            }
            try validateNamespace(source, expected: before)
            return ReadSnapshot(
                source: source,
                data: data,
                state: before,
                canonicalPath: canonicalSource,
                handle: handle,
                allowedRoot: root
            )
        } catch {
            try? handle.close()
            try? root.handle.close()
            throw error
        }
    }

    private static func verifyStableFile(_ snapshot: ReadSnapshot) throws {
        try verifyDirectoryAuthority(snapshot.allowedRoot)
        let state = try validatedState(snapshot.handle.fileDescriptor, source: snapshot.source)
        guard state == snapshot.state,
              try canonicalPath(snapshot.source) == snapshot.canonicalPath else {
            throw SessionEvidenceExportError.changedSource(snapshot.source.path)
        }
        try validateNamespace(snapshot.source, expected: state)
    }

    private static func validatedState(_ descriptor: Int32, source: URL) throws -> FileState {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else {
            throw SessionEvidenceExportError.unsafeSource(
                "source is not a single-link regular file: \(source.path)"
            )
        }
        let state = FileState(info)
        guard state.size >= 0, state.size <= maximumSourceBytes else {
            throw SessionEvidenceExportError.limitExceeded("source exceeds the per-file limit: \(source.path)")
        }
        guard state.size == 0 || state.blocks * 512 >= state.size else {
            throw SessionEvidenceExportError.unsafeSource("sparse source: \(source.path)")
        }
        return state
    }

    private static func validateNamespace(_ source: URL, expected: FileState) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              FileState(info).device == expected.device,
              FileState(info).inode == expected.inode else {
            throw SessionEvidenceExportError.changedSource(source.path)
        }
    }

    private static func canonicalPath(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else {
            throw SessionEvidenceExportError.unsafeSource(
                "could not resolve \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func openDirectoryAuthority(_ url: URL) throws -> DirectoryAuthority {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SessionEvidenceExportError.unsafeSource(
                "could not open directory authority \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else {
                throw SessionEvidenceExportError.unsafeSource(
                    "directory authority is not a directory: \(url.path)"
                )
            }
            let authority = DirectoryAuthority(
                url: url,
                canonicalPath: try heldPath(descriptor),
                device: UInt64(bitPattern: Int64(info.st_dev)),
                inode: UInt64(info.st_ino),
                handle: handle
            )
            try verifyDirectoryAuthority(authority)
            return authority
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func verifyDirectoryAuthority(_ authority: DirectoryAuthority) throws {
        var heldInfo = stat()
        var pathInfo = stat()
        guard fstat(authority.handle.fileDescriptor, &heldInfo) == 0,
              (heldInfo.st_mode & S_IFMT) == S_IFDIR,
              UInt64(bitPattern: Int64(heldInfo.st_dev)) == authority.device,
              UInt64(heldInfo.st_ino) == authority.inode,
              lstat(authority.url.path, &pathInfo) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFDIR,
              UInt64(bitPattern: Int64(pathInfo.st_dev)) == authority.device,
              UInt64(pathInfo.st_ino) == authority.inode,
              try heldPath(authority.handle.fileDescriptor) == authority.canonicalPath else {
            throw SessionEvidenceExportError.changedSource(
                "directory authority changed: \(authority.url.path)"
            )
        }
    }

    private static func heldPath(_ descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            fcntl(descriptor, F_GETPATH, pointer.baseAddress!)
        }
        guard result == 0 else {
            throw SessionEvidenceExportError.unsafeSource(
                "could not resolve held directory: \(String(cString: strerror(errno)))"
            )
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private static func adding(_ count: Int, to total: Int64) throws -> Int64 {
        let (next, overflow) = total.addingReportingOverflow(Int64(count))
        guard !overflow, next <= maximumAggregateBytes else {
            throw SessionEvidenceExportError.limitExceeded("aggregate source bytes")
        }
        return next
    }

    private static func includedManifestEntry(
        name: String,
        kind: String,
        data: Data
    ) -> ManifestEntry {
        ManifestEntry(
            entryName: name,
            sourceKind: kind,
            byteLength: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            missingReason: nil
        )
    }

    private static func writeHeld(
        _ data: Data,
        named name: String,
        in directory: DirectoryAuthority
    ) throws -> OutputProof {
        try verifyDirectoryAuthority(directory)
        let descriptor = Darwin.openat(
            directory.handle.fileDescriptor,
            name,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            var info = stat()
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                  fstat(descriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EACCES : errno))
            }
            return OutputProof(
                handle: handle,
                state: FileState(info),
                sha256: sha256(data)
            )
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func verifyOutput(
        _ proof: OutputProof,
        named name: String,
        in directory: DirectoryAuthority,
        expected: Data,
        requireStableMetadata: Bool
    ) throws -> Bool {
        try verifyDirectoryAuthority(directory)
        var descriptorInfo = stat()
        guard fstat(proof.handle.fileDescriptor, &descriptorInfo) == 0 else { return false }
        let current = FileState(descriptorInfo)
        guard (!requireStableMetadata || current == proof.state),
              current.device == proof.state.device,
              current.inode == proof.state.inode,
              current.links == proof.state.links,
              current.size == expected.count else { return false }
        var namespaceInfo = stat()
        guard fstatat(
                directory.handle.fileDescriptor,
                name,
                &namespaceInfo,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              (namespaceInfo.st_mode & S_IFMT) == S_IFREG,
              FileState(namespaceInfo).device == current.device,
              FileState(namespaceInfo).inode == current.inode else { return false }
        let heldData = try readExact(
            descriptor: proof.handle.fileDescriptor,
            count: expected.count,
            changed: SessionEvidenceExportError.changedSource(name)
        )
        return sha256(heldData) == proof.sha256 && heldData == expected
    }

    private static func readExact(
        descriptor: Int32,
        count: Int,
        changed: Error
    ) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else { throw changed }
            offset += readCount
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func verifyExpectedHash(
        _ expected: String?,
        data: Data,
        name: String
    ) throws {
        guard let expected else { return }
        let normalized = expected.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              sha256(data) == normalized else {
            throw SessionEvidenceExportError.changedSource(
                "\(name) did not match its retained SHA-256"
            )
        }
    }
}
