import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The versioned, named JSON document stored by `ScanRecipePresetStore`.
/// It contains only scan/output recipes; confirmations, scanner identity and
/// unverified-hardware authorization are intentionally not representable.
public struct ScanRecipePresetDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let name: String
    public let capture: CaptureRecipe
    public let processing: ProcessingRecipe
    public let output: OutputRecipe

    public init(
        name: String,
        capture: CaptureRecipe,
        processing: ProcessingRecipe,
        output: OutputRecipe,
        version: Int = ScanRecipePresetDocument.currentVersion
    ) {
        self.version = version
        self.name = name
        self.capture = capture
        self.processing = processing
        self.output = output
    }
}

public enum ScanRecipePresetStoreError: Error, Equatable, Sendable {
    case invalidName(String)
    case unsupportedVersion(Int)
    case invalidRecipe(String)
    case unsafeDirectory(String)
    case unsafeFile(String)
    case notFound(String)
    case invalidJSON(String)
    case io(String)
}

/// Owner-only versioned JSON presets. The directory is injectable so tests
/// never touch a user's home directory; production defaults to
/// `~/.scanstudio/presets`.
public struct ScanRecipePresetStore: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".scanstudio", isDirectory: true)
            .appendingPathComponent("presets", isDirectory: true)
    }

    private let directory: URL

    public init(directory: URL = ScanRecipePresetStore.defaultDirectory) {
        self.directory = directory.standardizedFileURL
    }

    public func save(_ preset: ScanRecipePresetDocument) throws {
        try Self.validate(preset)
        let descriptor = try openStoreDirectory(create: true)
        defer { _ = Darwin.close(descriptor) }

        let filename = "\(preset.name).json"
        let existing = Darwin.openat(descriptor, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if existing >= 0 {
            do { try validateRegularFile(fd: existing, name: filename) }
            catch { _ = Darwin.close(existing); throw error }
            _ = Darwin.close(existing)
        } else if errno != ENOENT {
            throw ioError("openat", name: filename)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(preset)
        let temporary = ".\(preset.name).\(UUID().uuidString).tmp"
        let fd = Darwin.openat(
            descriptor,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard fd >= 0 else { throw ioError("openat", name: temporary) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard Darwin.renameat(descriptor, temporary, descriptor, filename) == 0 else {
                throw ioError("renameat", name: filename)
            }
        } catch {
            _ = Darwin.unlinkat(descriptor, temporary, 0)
            throw error
        }
    }

    public func load(named name: String) throws -> ScanRecipePresetDocument {
        try Self.validateName(name)
        let descriptor = try openStoreDirectory(create: false)
        defer { _ = Darwin.close(descriptor) }
        let filename = "\(name).json"
        let fd = Darwin.openat(descriptor, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            guard errno == ENOENT else { throw ioError("openat", name: filename) }
            throw ScanRecipePresetStoreError.notFound(name)
        }
        var handle: FileHandle?
        defer {
            if let handle { try? handle.close() }
            else { _ = Darwin.close(fd) }
        }
        try validateRegularFile(fd: fd, name: filename)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size <= 1_048_576 else {
            throw ScanRecipePresetStoreError.unsafeFile(filename)
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle!.readToEnd() ?? Data()
        let preset: ScanRecipePresetDocument
        do {
            preset = try JSONDecoder().decode(ScanRecipePresetDocument.self, from: data)
        } catch {
            throw ScanRecipePresetStoreError.invalidJSON(filename)
        }
        try Self.validate(preset)
        guard preset.name == name else {
            throw ScanRecipePresetStoreError.invalidJSON(filename)
        }
        return preset
    }

    public func list() throws -> [String] {
        let descriptor: Int32
        do {
            descriptor = try openStoreDirectory(create: false)
        } catch ScanRecipePresetStoreError.notFound {
            return []
        }
        defer { _ = Darwin.close(descriptor) }
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw ScanRecipePresetStoreError.io("list \(directory.path)")
        }
        var names: [String] = []
        for entry in entries where entry.hasSuffix(".json") {
            let name = String(entry.dropLast(5))
            try Self.validateName(name)
            _ = try load(named: name)
            names.append(name)
        }
        return names.sorted()
    }

    private func openStoreDirectory(create: Bool) throws -> Int32 {
        if create && !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
            } catch {
                throw ScanRecipePresetStoreError.io("create \(directory.path)")
            }
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            guard !create, errno == ENOENT else { throw ioError("open", name: directory.path) }
            throw ScanRecipePresetStoreError.notFound(directory.path)
        }
        do {
            try validateDirectory(fd: descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func validateDirectory(fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o700 else {
            throw ScanRecipePresetStoreError.unsafeDirectory(directory.path)
        }
    }

    private func validateRegularFile(fd: Int32, name: String) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            throw ScanRecipePresetStoreError.unsafeFile(name)
        }
    }

    private static func validate(_ preset: ScanRecipePresetDocument) throws {
        try validateName(preset.name)
        guard preset.version == ScanRecipePresetDocument.currentVersion else {
            throw ScanRecipePresetStoreError.unsupportedVersion(preset.version)
        }
        try validateRecipes(capture: preset.capture, output: preset.output)
    }

    public static func validateRecipes(capture: CaptureRecipe, output: OutputRecipe) throws {
        let exposureOverrideIsValid = capture.exposureOverride10ns.map {
            $0.count == 3 && $0.allSatisfy { (50_000...400_000).contains($0) }
        } ?? true
        guard (1...100_000).contains(capture.resolutionDpi),
              capture.bitDepth == 8 || capture.bitDepth == 16,
              (1...64).contains(capture.multisamplePasses),
              capture.channels == "rgb" || capture.channels == "rgbi",
              exposureOverrideIsValid else {
            throw ScanRecipePresetStoreError.invalidRecipe("capture")
        }
        try validateOutput(output)
    }

    private static func validateOutput(_ output: OutputRecipe) throws {
        let recipes = [
            (output.archive.enabled, output.archive.filenameTemplate, output.archive.destination),
            (output.rawExport.enabled, output.rawExport.filenameTemplate, output.rawExport.destination),
            (output.positive.enabled, output.positive.filenameTemplate, output.positive.destination),
            (output.preview.enabled, output.preview.filenameTemplate, output.preview.destination)
        ]
        guard recipes.allSatisfy({ enabled, template, destination in
            !enabled || (!template.isEmpty && !destination.isEmpty &&
            !template.contains("/") && !template.contains("\\") &&
            destination.hasPrefix("/") &&
            !destination.split(separator: "/").contains("..") &&
            !template.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }))
        }),
        output.preview.maxLongEdgePx >= 0 else {
            throw ScanRecipePresetStoreError.invalidRecipe("output")
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 64,
              name != ".", name != "..",
              name.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) ||
                  ($0.value >= 65 && $0.value <= 90) ||
                  ($0.value >= 97 && $0.value <= 122) ||
                  $0 == "-" || $0 == "_" || $0 == "."
              }),
              !name.hasPrefix("."), !name.hasSuffix(".") else {
            throw ScanRecipePresetStoreError.invalidName(name)
        }
    }

    private func ioError(_ operation: String, name: String) -> ScanRecipePresetStoreError {
        ScanRecipePresetStoreError.io("\(operation) \(name): \(String(cString: strerror(errno)))")
    }
}
