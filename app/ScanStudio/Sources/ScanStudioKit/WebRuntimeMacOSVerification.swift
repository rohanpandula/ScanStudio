// macOS-only preparation and code-identity services for a verified optional
// runtime DMG. Commands use fixed absolute executables, no shell, bounded time,
// and bounded stdout/stderr. The command seam keeps tests offline and permits
// release integration only after a real manifest public key and Team ID exist.

import Darwin
import Foundation

public struct WebRuntimeCommandResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(
        terminationStatus: Int32,
        standardOutput: Data,
        standardError: Data
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol WebRuntimeCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> WebRuntimeCommandResult

    /// Runs a bounded cleanup command even when the calling task is already
    /// cancelled. This is intentionally separate from `run`: cancellation
    /// must stop ordinary work, but it must not prevent an owned mount from
    /// being detached on the way out.
    func runCleanup(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> WebRuntimeCommandResult
}

public extension WebRuntimeCommandRunning {
    func runCleanup(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> WebRuntimeCommandResult {
        try run(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }
}

public final class FoundationBoundedWebRuntimeCommandRunner: WebRuntimeCommandRunning,
    @unchecked Sendable
{
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> WebRuntimeCommandResult {
        try runCommand(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            honorsTaskCancellation: true
        )
    }

    public func runCleanup(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> WebRuntimeCommandResult {
        try runCommand(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            honorsTaskCancellation: false
        )
    }

    private func runCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        honorsTaskCancellation: Bool
    ) throws -> WebRuntimeCommandResult {
        guard executableURL.path.hasPrefix("/"),
              timeout > 0,
              maximumOutputBytes > 0,
              arguments.count <= 64,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 16_384 }) else {
            throw WebRuntimeDistributionError.invalidRequest
        }
        if honorsTaskCancellation, Task.isCancelled {
            throw WebRuntimeDistributionError.cancelled
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        let collector = BoundedCommandOutputCollector(maximumBytes: maximumOutputBytes)
        let readers = DispatchGroup()
        let processBox = UncheckedProcessBox(process)
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.read(
                from: stdoutPipe.fileHandleForReading,
                stream: .standardOutput,
                process: processBox
            )
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.read(
                from: stderrPipe.fileHandleForReading,
                stream: .standardError,
                process: processBox
            )
            readers.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw WebRuntimeDistributionError.cacheUnavailable
        }
        // `Process` inherits its own descriptors during `run()`. Close the
        // parent's copies now so each reader observes EOF when the child exits
        // or is killed. Retaining either write end can strand the other reader
        // until its grace period and misclassify bounded output as a timeout.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if honorsTaskCancellation, Task.isCancelled {
                Self.stop(
                    process,
                    termination: termination,
                    terminateGrace: 0.1,
                    killGrace: 0.25
                )
                _ = readers.wait(timeout: .now() + 0.25)
                throw WebRuntimeDistributionError.cancelled
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                let grace: TimeInterval = honorsTaskCancellation ? 1 : 0.25
                Self.stop(
                    process,
                    termination: termination,
                    terminateGrace: honorsTaskCancellation ? 0.25 : 0.1,
                    killGrace: grace
                )
                _ = readers.wait(timeout: .now() + grace)
                throw WebRuntimeDistributionError.commandTimedOut
            }
            if termination.wait(timeout: .now() + min(0.05, remaining)) == .success {
                break
            }
        }
        let readerGrace: TimeInterval = honorsTaskCancellation ? 1 : 0.25
        if readers.wait(timeout: .now() + readerGrace) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw WebRuntimeDistributionError.commandTimedOut
        }
        if collector.exceededLimit {
            throw WebRuntimeDistributionError.commandOutputTooLarge
        }
        let output = collector.snapshot()
        return WebRuntimeCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: output.standardOutput,
            standardError: output.standardError
        )
    }

    private static func stop(
        _ process: Process,
        termination: DispatchSemaphore,
        terminateGrace: TimeInterval,
        killGrace: TimeInterval
    ) {
        guard process.isRunning else { return }
        process.terminate()
        if termination.wait(timeout: .now() + terminateGrace) == .timedOut,
           process.isRunning
        {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + killGrace)
        }
    }
}

private final class UncheckedProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private final class BoundedCommandOutputCollector: @unchecked Sendable {
    enum Stream { case standardOutput, standardError }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var overflow = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var exceededLimit: Bool { lock.withLock { overflow } }

    func snapshot() -> (standardOutput: Data, standardError: Data) {
        lock.withLock { (stdout, stderr) }
    }

    func read(from handle: FileHandle, stream: Stream, process: UncheckedProcessBox) {
        defer { try? handle.close() }
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 16_384) ?? Data()
            } catch {
                return
            }
            if chunk.isEmpty { return }
            let shouldStop = lock.withLock { () -> Bool in
                guard !overflow else { return true }
                guard chunk.count <= maximumBytes,
                      stdout.count + stderr.count <= maximumBytes - chunk.count else {
                    overflow = true
                    return true
                }
                switch stream {
                case .standardOutput: stdout.append(chunk)
                case .standardError: stderr.append(chunk)
                }
                return false
            }
            if shouldStop {
                if process.process.isRunning {
                    Darwin.kill(process.process.processIdentifier, SIGKILL)
                }
                return
            }
        }
    }
}

public struct ReadOnlyDiskImageWebRuntimePayloadPreparer: WebRuntimePayloadPreparing {
    private let commandRunner: any WebRuntimeCommandRunning
    private let payloadVerifier: any WebRuntimePayloadVerifying

    public init(
        commandRunner: any WebRuntimeCommandRunning =
            FoundationBoundedWebRuntimeCommandRunner(),
        payloadVerifier: any WebRuntimePayloadVerifying =
            UnavailableWebRuntimePayloadVerifier()
    ) {
        self.commandRunner = commandRunner
        self.payloadVerifier = payloadVerifier
    }

    public func preparePayload(
        fromVerifiedImage imageURL: URL,
        release: VerifiedWebRuntimeRelease,
        in workingDirectory: URL
    ) throws -> URL {
        try Task.checkCancellation()
        try validateDiskImage(imageURL)
        try Task.checkCancellation()
        let mountPoint = workingDirectory.appendingPathComponent(
            "mount-\(UUID().uuidString)",
            isDirectory: true
        )
        let preparedContainer = workingDirectory.appendingPathComponent(
            "prepared-\(UUID().uuidString)",
            isDirectory: true
        )
        let prepared = preparedContainer.appendingPathComponent(
            "ScanStudioWebRuntime.bundle",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: mountPoint,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw WebRuntimeDistributionError.cacheUnavailable
        }

        var attachAttempted = false
        var attached = false
        do {
            attachAttempted = true
            let attach = try commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: [
                    "attach", "-nobrowse", "-readonly", "-plist",
                    "-mountpoint", mountPoint.path, imageURL.path,
                ],
                timeout: 30,
                maximumOutputBytes: 262_144
            )
            guard attach.terminationStatus == 0 else {
                throw WebRuntimeDistributionError.diskImageMountFailed
            }
            // A successful hdiutil invocation may already have mounted the
            // image even when its plist output is malformed. From this point
            // every exit path must attempt to detach the owned mount point.
            attached = true
            guard Self.plistContainsExactMountPoint(
                      attach.standardOutput,
                      expected: mountPoint
                  ) else {
                throw WebRuntimeDistributionError.diskImageMountFailed
            }
            try Task.checkCancellation()

            let entries = try FileManager.default.contentsOfDirectory(
                at: mountPoint,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            guard entries.count == 1,
                  let bundle = entries.first,
                  bundle.lastPathComponent == "ScanStudioWebRuntime.bundle",
                  bundle.lastPathComponent == release.manifest.payload.bundleName else {
                throw WebRuntimeDistributionError.diskImageLayoutInvalid
            }
            let values = try bundle.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw WebRuntimeDistributionError.diskImageLayoutInvalid
            }

            _ = try payloadVerifier.verifyPayload(at: bundle, against: release.manifest)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: preparedContainer,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.copyItem(at: bundle, to: prepared)
            try Task.checkCancellation()
            _ = try payloadVerifier.verifyPayload(at: prepared, against: release.manifest)
            try Task.checkCancellation()
            try detach(mountPoint)
            attached = false
            try? FileManager.default.removeItem(at: mountPoint)
            return prepared
        } catch let primaryError {
            try? FileManager.default.removeItem(at: preparedContainer)
            if attached {
                do {
                    try detach(mountPoint)
                    attached = false
                } catch {
                    try? FileManager.default.removeItem(at: mountPoint)
                    throw WebRuntimeDistributionError.diskImageDetachFailed
                }
            } else if attachAttempted {
                // A timed-out or non-zero hdiutil invocation can still have
                // mounted before failing. The mount point is private and
                // operation-owned, so always attempt best-effort cleanup.
                try? detach(mountPoint)
            }
            try? FileManager.default.removeItem(at: mountPoint)
            if primaryError is CancellationError {
                throw WebRuntimeDistributionError.cancelled
            }
            if let error = primaryError as? WebRuntimeDistributionError {
                throw error
            }
            throw WebRuntimeDistributionError.diskImageLayoutInvalid
        }
    }

    private func validateDiskImage(_ imageURL: URL) throws {
        let staple: WebRuntimeCommandResult
        let assessment: WebRuntimeCommandResult
        do {
            staple = try commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/stapler"),
                arguments: ["validate", imageURL.path],
                timeout: 30,
                maximumOutputBytes: 131_072
            )
            guard staple.terminationStatus == 0 else {
                throw WebRuntimeDistributionError.notarizationInvalid
            }
            assessment = try commandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
                arguments: [
                    "--assess", "--type", "open", "--context",
                    "context:primary-signature", imageURL.path,
                ],
                timeout: 30,
                maximumOutputBytes: 131_072
            )
        } catch let error as WebRuntimeDistributionError
            where error == .notarizationInvalid
        {
            throw error
        } catch {
            throw WebRuntimeDistributionError.notarizationInvalid
        }
        guard assessment.terminationStatus == 0 else {
            throw WebRuntimeDistributionError.notarizationInvalid
        }
    }

    private func detach(_ mountPoint: URL) throws {
        // App termination allows four seconds for provisioning cleanup. Once
        // cancelled, keep both detach attempts inside that budget; during a
        // normal install, retain the more generous timeout.
        let timeout: TimeInterval = Task.isCancelled ? 0.75 : 15
        let ordinary = try? commandRunner.runCleanup(
            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", mountPoint.path],
            timeout: timeout,
            maximumOutputBytes: 65_536
        )
        if ordinary?.terminationStatus == 0 { return }
        let forced = try? commandRunner.runCleanup(
            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", "-force", mountPoint.path],
            timeout: timeout,
            maximumOutputBytes: 65_536
        )
        guard forced?.terminationStatus == 0 else {
            throw WebRuntimeDistributionError.diskImageDetachFailed
        }
    }

    private static func plistContainsExactMountPoint(
        _ data: Data,
        expected: URL
    ) -> Bool {
        guard data.count <= 262_144,
              let value = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let root = value as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else {
            return false
        }
        let mountPoints = entities.compactMap { $0["mount-point"] as? String }
        return mountPoints == [expected.path]
    }
}

public struct SystemWebRuntimeCodeAssessor: WebRuntimeCodeAssessing {
    private let commandRunner: any WebRuntimeCommandRunning

    public init(
        commandRunner: any WebRuntimeCommandRunning =
            FoundationBoundedWebRuntimeCommandRunner()
    ) {
        self.commandRunner = commandRunner
    }

    public func assessPayload(
        at rootURL: URL,
        executableURL: URL
    ) throws -> WebRuntimeCodeIdentityAssertion {
        guard rootURL.lastPathComponent == "ScanStudioWebRuntime.bundle",
              executableURL.standardizedFileURL.path.hasPrefix(
                  rootURL.standardizedFileURL.path + "/"
              ) else {
            throw WebRuntimeDistributionError.codeSignatureInvalid
        }
        let codesignURL = URL(fileURLWithPath: "/usr/bin/codesign")
        let verification = try commandRunner.run(
            executableURL: codesignURL,
            arguments: ["--verify", "--deep", "--strict", rootURL.path],
            timeout: 15,
            maximumOutputBytes: 131_072
        )
        guard verification.terminationStatus == 0 else {
            throw WebRuntimeDistributionError.codeSignatureInvalid
        }
        let details = try commandRunner.run(
            executableURL: codesignURL,
            arguments: ["--display", "--verbose=4", rootURL.path],
            timeout: 15,
            maximumOutputBytes: 131_072
        )
        guard details.terminationStatus == 0 else {
            throw WebRuntimeDistributionError.codeSignatureInvalid
        }
        let detailText = Self.utf8(details.standardOutput + details.standardError)
        let identifier = try Self.uniqueValue(prefix: "Identifier=", in: detailText)
        let rawTeam = try Self.uniqueValue(prefix: "TeamIdentifier=", in: detailText)
        let teamIdentifier = rawTeam == "not set" ? "" : rawTeam
        let hasDeveloperIDAuthority = detailText.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces)
                .hasPrefix("Authority=Developer ID Application:")
        }

        let assessment = try commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", "--verbose=4", rootURL.path],
            timeout: 15,
            maximumOutputBytes: 131_072
        )
        let developerIDSigned = hasDeveloperIDAuthority && assessment.terminationStatus == 0

        return WebRuntimeCodeIdentityAssertion(
            bundleIdentifier: identifier,
            teamIdentifier: teamIdentifier,
            developerIDSigned: developerIDSigned,
            // Notarization is established on the containing DMG before it is
            // mounted. At launch, strict codesign plus Gatekeeper acceptance
            // of this extracted executable payload is the retained proof.
            // This transitivity also depends on the launch path re-hashing
            // the cached tree against the authenticated manifest first.
            notarized: developerIDSigned
        )
    }

    private static func utf8(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func uniqueValue(prefix: String, in text: String) throws -> String {
        let values = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { return nil }
            return String(trimmed.dropFirst(prefix.count))
        }
        guard values.count == 1,
              let value = values.first,
              !value.isEmpty,
              value.utf8.count <= 255,
              value.utf8.allSatisfy({
                  ($0 >= 0x30 && $0 <= 0x39)
                      || ($0 >= 0x41 && $0 <= 0x5A)
                      || ($0 >= 0x61 && $0 <= 0x7A)
                      || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F || $0 == 0x20
              }) else {
            throw WebRuntimeDistributionError.codeSignatureInvalid
        }
        return value
    }
}
