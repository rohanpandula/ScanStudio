import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Optional web runtime macOS verification")
struct WebRuntimeMacOSVerificationTests {
    @Test("read-only DMG preparation copies exactly one verified bundle and detaches")
    func readOnlyPreparationSucceeds() throws {
        let fixture = try MacOSVerificationFixture()
        defer { fixture.cleanUp() }
        let runner = fixture.diskImageRunner()
        let verifier = CountingPayloadVerifier()
        let preparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: runner,
            payloadVerifier: verifier
        )

        let prepared = try preparer.preparePayload(
            fromVerifiedImage: fixture.imageURL,
            release: fixture.release,
            in: fixture.root
        )

        #expect(prepared.lastPathComponent == "ScanStudioWebRuntime.bundle")
        #expect(FileManager.default.fileExists(atPath: prepared.path))
        #expect(verifier.callCount == 2)
        let calls = runner.recordedCalls
        let attach = try #require(calls.first { $0.arguments.first == "attach" })
        #expect(attach.executableURL.path == "/usr/bin/hdiutil")
        #expect(attach.arguments.prefix(4) == ["attach", "-nobrowse", "-readonly", "-plist"])
        #expect(calls.prefix(3).map(\.executableURL.path) == [
            "/usr/bin/stapler", "/usr/sbin/spctl", "/usr/bin/hdiutil",
        ])
        #expect(calls[0].arguments == ["validate", fixture.imageURL.path])
        #expect(calls[1].arguments == [
            "--assess", "--type", "open", "--context",
            "context:primary-signature", fixture.imageURL.path,
        ])
        #expect(calls.contains { $0.arguments.first == "detach" })
    }

    @Test("DMG notarization and primary-signature assessment fail before mount")
    func diskImageTrustFailsBeforeMount() throws {
        let stapleFixture = try MacOSVerificationFixture()
        defer { stapleFixture.cleanUp() }
        let stapleRunner = stapleFixture.diskImageRunner(staplerStatus: 1)
        let staplePreparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: stapleRunner,
            payloadVerifier: CountingPayloadVerifier()
        )
        #expect(throws: WebRuntimeDistributionError.notarizationInvalid) {
            try staplePreparer.preparePayload(
                fromVerifiedImage: stapleFixture.imageURL,
                release: stapleFixture.release,
                in: stapleFixture.root
            )
        }
        #expect(stapleRunner.recordedCalls.map(\.executableURL.path) == [
            "/usr/bin/stapler",
        ])

        let assessmentFixture = try MacOSVerificationFixture()
        defer { assessmentFixture.cleanUp() }
        let assessmentRunner = assessmentFixture.diskImageRunner(spctlStatus: 1)
        let assessmentPreparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: assessmentRunner,
            payloadVerifier: CountingPayloadVerifier()
        )
        #expect(throws: WebRuntimeDistributionError.notarizationInvalid) {
            try assessmentPreparer.preparePayload(
                fromVerifiedImage: assessmentFixture.imageURL,
                release: assessmentFixture.release,
                in: assessmentFixture.root
            )
        }
        #expect(assessmentRunner.recordedCalls.map(\.executableURL.path) == [
            "/usr/bin/stapler", "/usr/sbin/spctl",
        ])
    }

    @Test("a successful mount with malformed plist is still detached")
    func malformedMountReceiptStillDetaches() throws {
        let fixture = try MacOSVerificationFixture()
        defer { fixture.cleanUp() }
        let runner = fixture.diskImageRunner(attachOutput: Data("not a plist".utf8))
        let preparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: runner,
            payloadVerifier: CountingPayloadVerifier()
        )

        do {
            _ = try preparer.preparePayload(
                fromVerifiedImage: fixture.imageURL,
                release: fixture.release,
                in: fixture.root
            )
            Issue.record("malformed hdiutil output unexpectedly succeeded")
        } catch let error as WebRuntimeDistributionError {
            #expect(error == .diskImageMountFailed)
        }
        #expect(runner.recordedCalls.contains { $0.arguments.first == "detach" })
    }

    @Test("a non-zero attach still performs best-effort detach")
    func failedAttachStillDetaches() throws {
        let fixture = try MacOSVerificationFixture()
        defer { fixture.cleanUp() }
        let runner = fixture.diskImageRunner(attachStatus: 1)
        let preparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: runner,
            payloadVerifier: CountingPayloadVerifier()
        )

        #expect(throws: WebRuntimeDistributionError.diskImageMountFailed) {
            try preparer.preparePayload(
                fromVerifiedImage: fixture.imageURL,
                release: fixture.release,
                in: fixture.root
            )
        }
        #expect(runner.recordedCalls.contains { $0.arguments.first == "detach" })
    }

    @Test("cancelling an active attach kills the command and still detaches")
    func cancelledAttachStillDetaches() async throws {
        let fixture = try MacOSVerificationFixture()
        defer { fixture.cleanUp() }
        let attachStarted = DispatchSemaphore(value: 0)
        let productionRunner = FoundationBoundedWebRuntimeCommandRunner()
        let runner = TestCommandRunner { call in
            if call.executableURL.path == "/usr/bin/stapler"
                || call.executableURL.path == "/usr/sbin/spctl"
            {
                return .success()
            }
            guard call.executableURL.path == "/usr/bin/hdiutil",
                  let operation = call.arguments.first else {
                throw WebRuntimeDistributionError.invalidRequest
            }
            if operation == "attach" {
                attachStarted.signal()
                return try productionRunner.run(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["10"],
                    timeout: 20,
                    maximumOutputBytes: 1_024
                )
            }
            if operation == "detach" { return .success() }
            throw WebRuntimeDistributionError.invalidRequest
        }
        let preparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: runner,
            payloadVerifier: CountingPayloadVerifier()
        )
        let operation = Task.detached {
            try preparer.preparePayload(
                fromVerifiedImage: fixture.imageURL,
                release: fixture.release,
                in: fixture.root
            )
        }
        let attachDidStart = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: attachStarted.wait(timeout: .now() + 2) == .success
                )
            }
        }
        #expect(attachDidStart)
        let clock = ContinuousClock()
        let cancellationStarted = clock.now
        operation.cancel()

        await #expect(throws: WebRuntimeDistributionError.cancelled) {
            try await operation.value
        }
        #expect(cancellationStarted.duration(to: clock.now) < .seconds(4))
        let detachCalls = runner.recordedCalls.filter {
            $0.arguments.first == "detach"
        }
        #expect(detachCalls.count == 1)
        #expect(detachCalls.allSatisfy { $0.timeout <= 0.75 })
    }

    @Test("cancellation after mount detaches and preserves cancellation result")
    func cancelledMountedVerificationStillDetaches() async throws {
        let fixture = try MacOSVerificationFixture()
        defer { fixture.cleanUp() }
        let runner = fixture.diskImageRunner()
        let preparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: runner,
            payloadVerifier: SelfCancellingPayloadVerifier()
        )
        let operation = Task.detached {
            try preparer.preparePayload(
                fromVerifiedImage: fixture.imageURL,
                release: fixture.release,
                in: fixture.root
            )
        }

        await #expect(throws: WebRuntimeDistributionError.cancelled) {
            try await operation.value
        }
        let detachCalls = runner.recordedCalls.filter {
            $0.arguments.first == "detach"
        }
        #expect(detachCalls.count == 1)
        #expect(detachCalls.allSatisfy { $0.timeout <= 0.75 })
    }

    @Test("unexpected mounted contents fail closed and detach")
    func unexpectedLayoutStillDetaches() throws {
        let fixture = try MacOSVerificationFixture()
        defer { fixture.cleanUp() }
        let runner = fixture.diskImageRunner(bundleName: "Unexpected.bundle")
        let preparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: runner,
            payloadVerifier: CountingPayloadVerifier()
        )

        do {
            _ = try preparer.preparePayload(
                fromVerifiedImage: fixture.imageURL,
                release: fixture.release,
                in: fixture.root
            )
            Issue.record("unexpected DMG layout was accepted")
        } catch let error as WebRuntimeDistributionError {
            #expect(error == .diskImageLayoutInvalid)
        }
        #expect(runner.recordedCalls.contains { $0.arguments.first == "detach" })
    }

    @Test("detach failure retries with force and remains fail closed")
    func detachRetriesAndFailsClosed() throws {
        let successfulFixture = try MacOSVerificationFixture()
        defer { successfulFixture.cleanUp() }
        let successfulRunner = successfulFixture.diskImageRunner(
            ordinaryDetachStatus: 1,
            forcedDetachStatus: 0
        )
        let preparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: successfulRunner,
            payloadVerifier: CountingPayloadVerifier()
        )
        _ = try preparer.preparePayload(
            fromVerifiedImage: successfulFixture.imageURL,
            release: successfulFixture.release,
            in: successfulFixture.root
        )
        #expect(successfulRunner.recordedCalls.contains {
            $0.arguments.prefix(2) == ["detach", "-force"]
        })

        let failingFixture = try MacOSVerificationFixture()
        defer { failingFixture.cleanUp() }
        let failingRunner = failingFixture.diskImageRunner(
            ordinaryDetachStatus: 1,
            forcedDetachStatus: 1
        )
        let failingPreparer = ReadOnlyDiskImageWebRuntimePayloadPreparer(
            commandRunner: failingRunner,
            payloadVerifier: CountingPayloadVerifier()
        )
        do {
            _ = try failingPreparer.preparePayload(
                fromVerifiedImage: failingFixture.imageURL,
                release: failingFixture.release,
                in: failingFixture.root
            )
            Issue.record("an undetached image unexpectedly succeeded")
        } catch let error as WebRuntimeDistributionError {
            #expect(error == .diskImageDetachFailed)
        }
    }

    @Test("system assessor uses fixed tools and extracts one exact code identity")
    func systemAssessorVerifiesIdentity() throws {
        let runner = TestCommandRunner { call in
            switch (call.executableURL.path, call.arguments.first) {
            case ("/usr/bin/codesign", "--verify"):
                return .success()
            case ("/usr/bin/codesign", "--display"):
                return .success(error: Data("""
                    Executable=/tmp/ScanStudioWebRuntime.bundle/Contents/MacOS/scanstudio-web-runtime
                    Identifier=dev.scanstudio.live.web-runtime
                    Authority=Developer ID Application: Scan Studio (ABCDE12345)
                    TeamIdentifier=ABCDE12345
                    """.utf8))
            case ("/usr/sbin/spctl", "--assess"),
                 ("/usr/bin/stapler", "validate"):
                return .success()
            default:
                throw WebRuntimeDistributionError.invalidRequest
            }
        }
        let root = URL(fileURLWithPath: "/tmp/ScanStudioWebRuntime.bundle", isDirectory: true)
        let executable = root.appendingPathComponent(
            "Contents/MacOS/scanstudio-web-runtime"
        )

        let assertion = try SystemWebRuntimeCodeAssessor(
            commandRunner: runner
        ).assessPayload(at: root, executableURL: executable)

        #expect(assertion.bundleIdentifier == "dev.scanstudio.live.web-runtime")
        #expect(assertion.teamIdentifier == "ABCDE12345")
        #expect(assertion.developerIDSigned)
        #expect(assertion.notarized)
        #expect(runner.recordedCalls.map(\.executableURL.path) == [
            "/usr/bin/codesign", "/usr/bin/codesign", "/usr/sbin/spctl",
        ])
        #expect(runner.recordedCalls[0].arguments == [
            "--verify", "--deep", "--strict", root.path,
        ])
    }

    @Test("ambiguous codesign identity output is rejected")
    func duplicateIdentityRejects() throws {
        let runner = TestCommandRunner { call in
            if call.arguments.first == "--verify" { return .success() }
            return .success(error: Data("""
                Identifier=dev.scanstudio.live.web-runtime
                Identifier=dev.scanstudio.live.other
                TeamIdentifier=ABCDE12345
                Authority=Developer ID Application: Scan Studio (ABCDE12345)
                """.utf8))
        }
        let root = URL(fileURLWithPath: "/tmp/ScanStudioWebRuntime.bundle", isDirectory: true)
        let executable = root.appendingPathComponent("Contents/MacOS/scanstudio-web-runtime")

        #expect(throws: WebRuntimeDistributionError.codeSignatureInvalid) {
            try SystemWebRuntimeCodeAssessor(commandRunner: runner).assessPayload(
                at: root,
                executableURL: executable
            )
        }
        #expect(runner.recordedCalls.count == 2)
    }

    @Test("Gatekeeper rejection cannot assert Developer ID or notarization")
    func gatekeeperRejectionClearsTrustAssertions() throws {
        let runner = TestCommandRunner { call in
            if call.executableURL.path == "/usr/bin/codesign",
               call.arguments.first == "--verify" {
                return .success()
            }
            if call.executableURL.path == "/usr/bin/codesign" {
                return .success(error: Data("""
                    Identifier=dev.scanstudio.live.web-runtime
                    Authority=Developer ID Application: Scan Studio (ABCDE12345)
                    TeamIdentifier=ABCDE12345
                    """.utf8))
            }
            return WebRuntimeCommandResult(
                terminationStatus: 1,
                standardOutput: Data(),
                standardError: Data("rejected".utf8)
            )
        }
        let root = URL(fileURLWithPath: "/tmp/ScanStudioWebRuntime.bundle", isDirectory: true)
        let executable = root.appendingPathComponent("Contents/MacOS/scanstudio-web-runtime")

        let assertion = try SystemWebRuntimeCodeAssessor(
            commandRunner: runner
        ).assessPayload(at: root, executableURL: executable)

        #expect(!assertion.developerIDSigned)
        #expect(!assertion.notarized)
        #expect(!runner.recordedCalls.contains { $0.executableURL.path == "/usr/bin/stapler" })
    }

    @Test("production command runner bounds time and combined output")
    func productionRunnerIsBounded() throws {
        let runner = FoundationBoundedWebRuntimeCommandRunner()
        #expect(throws: WebRuntimeDistributionError.commandOutputTooLarge) {
            try runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: [String(repeating: "x", count: 2_048)],
                timeout: 10,
                maximumOutputBytes: 1_024
            )
        }
        #expect(throws: WebRuntimeDistributionError.commandTimedOut) {
            try runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.05,
                maximumOutputBytes: 1_024
            )
        }
    }

    @Test("production command runner terminates a child when its task is cancelled")
    func productionRunnerHonorsTaskCancellation() async throws {
        let runner = FoundationBoundedWebRuntimeCommandRunner()
        let operation = Task.detached {
            try runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 20,
                maximumOutputBytes: 1_024
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let started = clock.now
        operation.cancel()

        await #expect(throws: WebRuntimeDistributionError.cancelled) {
            try await operation.value
        }
        #expect(started.duration(to: clock.now) < .seconds(2))
    }

    @Test("production cleanup command still runs from a cancelled task")
    func productionCleanupIgnoresCallerCancellation() async throws {
        let runner = FoundationBoundedWebRuntimeCommandRunner()
        let gate = DispatchSemaphore(value: 0)
        let operation = Task.detached {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    _ = gate.wait(timeout: .now() + 2)
                    continuation.resume()
                }
            }
            return try runner.runCleanup(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                timeout: 1,
                maximumOutputBytes: 1_024
            )
        }
        operation.cancel()
        gate.signal()

        let result = try await operation.value
        #expect(result.terminationStatus == 0)
    }
}

private final class MacOSVerificationFixture: @unchecked Sendable {
    let root: URL
    let imageURL: URL
    let release: VerifiedWebRuntimeRelease

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebRuntimeMacOSTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        imageURL = root.appendingPathComponent("runtime.dmg")
        try Data("test image".utf8).write(to: imageURL)
        release = try RuntimeDistributionFixture().verifiedRelease()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func diskImageRunner(
        attachOutput: Data? = nil,
        bundleName: String = "ScanStudioWebRuntime.bundle",
        attachStatus: Int32 = 0,
        staplerStatus: Int32 = 0,
        spctlStatus: Int32 = 0,
        ordinaryDetachStatus: Int32 = 0,
        forcedDetachStatus: Int32 = 0
    ) -> TestCommandRunner {
        TestCommandRunner { call in
            if call.executableURL.path == "/usr/bin/stapler" {
                return WebRuntimeCommandResult(
                    terminationStatus: staplerStatus,
                    standardOutput: Data(),
                    standardError: Data()
                )
            }
            if call.executableURL.path == "/usr/sbin/spctl" {
                return WebRuntimeCommandResult(
                    terminationStatus: spctlStatus,
                    standardOutput: Data(),
                    standardError: Data()
                )
            }
            guard call.executableURL.path == "/usr/bin/hdiutil",
                  let operation = call.arguments.first else {
                throw WebRuntimeDistributionError.invalidRequest
            }
            if operation == "attach" {
                guard let marker = call.arguments.firstIndex(of: "-mountpoint"),
                      call.arguments.indices.contains(marker + 1) else {
                    throw WebRuntimeDistributionError.invalidRequest
                }
                let mountPath = call.arguments[marker + 1]
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: mountPath).appendingPathComponent(
                        bundleName,
                        isDirectory: true
                    ),
                    withIntermediateDirectories: false
                )
                let output = try attachOutput ?? PropertyListSerialization.data(
                    fromPropertyList: [
                        "system-entities": [["mount-point": mountPath]],
                    ],
                    format: .xml,
                    options: 0
                )
                return WebRuntimeCommandResult(
                    terminationStatus: attachStatus,
                    standardOutput: output,
                    standardError: Data()
                )
            }
            if operation == "detach" {
                return WebRuntimeCommandResult(
                    terminationStatus: call.arguments.contains("-force")
                        ? forcedDetachStatus : ordinaryDetachStatus,
                    standardOutput: Data(),
                    standardError: Data()
                )
            }
            throw WebRuntimeDistributionError.invalidRequest
        }
    }
}

private struct TestCommandCall: Sendable {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval
    let maximumOutputBytes: Int
}

private final class TestCommandRunner: WebRuntimeCommandRunning, @unchecked Sendable {
    typealias Handler = (TestCommandCall) throws -> WebRuntimeCommandResult

    private let lock = NSLock()
    private var calls: [TestCommandCall] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var recordedCalls: [TestCommandCall] {
        lock.withLock { calls }
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> WebRuntimeCommandResult {
        let call = TestCommandCall(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
        lock.withLock { calls.append(call) }
        return try handler(call)
    }
}

private extension WebRuntimeCommandResult {
    static func success(
        output: Data = Data(),
        error: Data = Data()
    ) -> WebRuntimeCommandResult {
        WebRuntimeCommandResult(
            terminationStatus: 0,
            standardOutput: output,
            standardError: error
        )
    }
}

private final class CountingPayloadVerifier: WebRuntimePayloadVerifying,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func verifyPayload(
        at rootURL: URL,
        against manifest: WebRuntimeManifest
    ) throws -> WebRuntimePayloadVerification {
        lock.withLock { calls += 1 }
        return WebRuntimePayloadVerification(
            codeIdentity: WebRuntimeCodeIdentityAssertion(
                bundleIdentifier: manifest.payload.bundleIdentifier,
                teamIdentifier: manifest.payload.teamIdentifier,
                developerIDSigned: manifest.payload.developerIDSigned,
                notarized: manifest.payload.notarized
            ),
            fileCount: manifest.payload.fileCount,
            installedSize: manifest.payload.installedSize,
            treeSHA256: manifest.payload.treeSHA256
        )
    }
}

private final class SelfCancellingPayloadVerifier: WebRuntimePayloadVerifying,
    @unchecked Sendable
{
    func verifyPayload(
        at rootURL: URL,
        against manifest: WebRuntimeManifest
    ) throws -> WebRuntimePayloadVerification {
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return WebRuntimePayloadVerification(
            codeIdentity: WebRuntimeCodeIdentityAssertion(
                bundleIdentifier: manifest.payload.bundleIdentifier,
                teamIdentifier: manifest.payload.teamIdentifier,
                developerIDSigned: manifest.payload.developerIDSigned,
                notarized: manifest.payload.notarized
            ),
            fileCount: manifest.payload.fileCount,
            installedSize: manifest.payload.installedSize,
            treeSHA256: manifest.payload.treeSHA256
        )
    }
}
