// OUT-03: proves `ControlErrorPayload.recoverable` carries the engine's own
// flag verbatim on every dispatcher-routed mutating command this plan
// touches, that a stale retained payload is never misattributed to a later,
// differently-coded failure, and that no hardware-diagnostic detail leaks
// through the passthrough. Fixture/stub shape mirrors
// `ControlChannelProjectRoutingTests.swift` (02-PATTERNS.md role-match):
// this suite exercises the same four project-lifecycle commands plus
// `scanner.eject`.
//
// `sim-ls5000-0`-shaped per the phase's hardware-safety constraint: every
// test here drives a fake `EngineClientProtocol` actor. No scanner motion,
// no GUI, no real engine binary.

import Foundation
import Testing

@testable import ScanStudioKit

private enum RecoverablePassthroughStubError: Error {
    case unexpectedMethod(String)
    case unexpectedResultType
}

private let recoverablePassthroughDevice = DeviceInfo(
    deviceId: "sim-ls5000-0",
    model: "LS-5000 ED",
    kind: "simulated",
    firmware: "test",
    connection: "usb",
    supported: true, supportedMultisamplePasses: [4]
)

private let recoverablePassthroughProjectDirectory = "/tmp/recoverable-passthrough-test"

/// A minimal one-frame project fixture, modelled on
/// `ControlChannelProjectRoutingTests.swift`'s `projectRoutingProject(...)`.
private func recoverablePassthroughProject(frameIndex: Int = 1) -> ScanProject {
    ScanProject(
        schemaVersion: 1,
        id: "recoverable-passthrough-project",
        name: "Recoverable passthrough test",
        carrier: .mounted,
        frameCount: 1,
        filmProcess: .c41ColorNegative,
        recipes: OutputRecipe(
            archive: ArchiveRecipe(
                filenameTemplate: "Archive_####",
                destination: "/tmp/recoverable-passthrough/archive"
            ),
            positive: PositiveRecipe(
                enabled: true,
                fileFormat: .tiff,
                colorProfile: .adobeRgb1998,
                filenameTemplate: "Positive_####",
                destination: "/tmp/recoverable-passthrough/positive"
            ),
            preview: PreviewRecipe(
                enabled: true,
                fileFormat: .jpeg,
                maxLongEdgePx: 1_024,
                filenameTemplate: "Preview_####",
                destination: "/tmp/recoverable-passthrough/preview"
            )
        ),
        rollMetadata: MetadataSet(),
        createdAt: "2026-09-07T00:00:00Z",
        frames: [ProjectFrame(index: frameIndex, excluded: false, receipts: [])]
    )
}

/// Fake engine that can be scripted, per method name, to throw a specific
/// `EngineRequestError` exactly once (`failNext` removes its own entry when
/// consumed) -- everything else answers the fixed happy-path response the
/// project-routing/busy-indicator suites already use. No hold/release gate:
/// every failure here is an immediate throw: nothing in this suite needs to
/// observe a request while it is still in flight.
private actor RecoverablePassthroughEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "recoverable-passthrough-stub"

    private(set) var recordedMethods: [String] = []
    private var scriptedFailures: [String: EngineRequestError] = [:]

    func clearLog() {
        recordedMethods.removeAll()
    }

    func failNext(_ method: String, with error: EngineRequestError) {
        scriptedFailures[method] = error
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, params: Params
    ) async throws -> Result {
        recordedMethods.append(method)
        if let failure = scriptedFailures.removeValue(forKey: method) {
            throw failure
        }
        switch method {
        case "scanner.list", "scanner.rescan":
            return try cast(ScannerListResult(devices: [recoverablePassthroughDevice]), as: Result.self)
        case "scanner.connect":
            return try cast(ConnectResult(
                device: recoverablePassthroughDevice,
                status: ScannerStatus(
                    connected: true, adapter: "SA-21", mediaLoaded: false, carrier: nil,
                    frameCount: nil, lamp: "unknown", transport: "idle", activeJobId: nil,
                    filmPresent: nil, motionArmed: true
                )
            ), as: Result.self)
        case "scanner.acquireThumbnails":
            return try cast(AcquireThumbnailsAck(accepted: true, frames: []), as: Result.self)
        case "scanner.eject":
            return try cast(EmptyResult(), as: Result.self)
        case "project.open":
            return try cast(
                ProjectOpenResult(project: recoverablePassthroughProject(), directory: recoverablePassthroughProjectDirectory),
                as: Result.self
            )
        case "project.create":
            return try cast(
                ProjectCreateResult(project: recoverablePassthroughProject(), directory: recoverablePassthroughProjectDirectory),
                as: Result.self
            )
        case "project.list":
            return try cast(ProjectListResult(projects: []), as: Result.self)
        case "project.setFrameExcluded":
            return try cast(SetFrameResult(project: recoverablePassthroughProject()), as: Result.self)
        default:
            throw RecoverablePassthroughStubError.unexpectedMethod(method)
        }
    }

    private func cast<Result: Decodable & Sendable>(_ value: some Sendable, as _: Result.Type) throws -> Result {
        guard let result = value as? Result else { throw RecoverablePassthroughStubError.unexpectedResultType }
        return result
    }
}

/// Bounded `Task.yield()` polling, per this codebase's established idiom,
/// for waiting out `SessionModel.init`'s fire-and-forget initial discovery
/// call without a fixed sleep.
@MainActor
private func makeIdleModel(_ stub: RecoverablePassthroughEngineStub) async -> SessionModel {
    let model = SessionModel(engineClient: stub)
    for _ in 0..<30 where model.isDiscoveringDevices {
        await Task.yield()
    }
    return model
}

@MainActor
private func makeDispatcher() async -> (model: SessionModel, stub: RecoverablePassthroughEngineStub, dispatcher: ControlChannelDispatcher) {
    let stub = RecoverablePassthroughEngineStub()
    let model = await makeIdleModel(stub)
    await stub.clearLog()
    let dispatcher = ControlChannelDispatcher(sessionModel: model)
    return (model, stub, dispatcher)
}

@MainActor
@discardableResult
private func greet(_ dispatcher: ControlChannelDispatcher) async -> ControlResponse {
    await dispatcher.handle(.hello(
        id: 0,
        params: ControlHelloParams(schemaVersion: ControlSchema.version, clientName: "recoverable-passthrough-tests")
    ))
}

/// Connects and injects a synthetic `scanner.status` carrying
/// `filmPresent: true` -- the minimal eject-offerable state, modelled on
/// `ControlBusyIndicatorTests.swift`'s `makeEjectableModel`.
@MainActor
private func driveToEjectReady(_ model: SessionModel) async {
    await model.connect(deviceId: recoverablePassthroughDevice.deviceId)
    model.handle(event: EngineEvent(
        name: "scanner.status",
        rawLine: Data(
            #"""
            {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"SA-21","mediaLoaded":false,"carrier":null,"frameCount":null,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
            """#.utf8
        )
    ))
}

/// Connects and completes a pre-project preview with one plain thumbnail,
/// then selects frame 1 -- the live state `roll.save`'s internal
/// `createProject` needs to actually run, modelled on
/// `ControlChannelProjectRoutingTests.swift`'s `prepareForRollSaveReadiness`.
@MainActor
private func driveToRollSaveReady(_ model: SessionModel) async {
    await model.connect(deviceId: recoverablePassthroughDevice.deviceId)
    model.handle(event: EngineEvent(
        name: "scanner.status",
        rawLine: Data(
            #"""
            {"event":"scanner.status","payload":{"status":{"connected":true,"adapter":"MA-21","mediaLoaded":true,"carrier":"mounted","frameCount":1,"lamp":"stable","transport":"idle","activeJobId":null,"filmPresent":true,"motionArmed":true}}}
            """#.utf8
        )
    ))
    let token = PreviewIntentToken()
    _ = await model.requestPreview(.initial(token: token))
    model.handle(event: EngineEvent(
        name: "scanner.thumbnail",
        rawLine: Data(
            #"""
            {"event":"scanner.thumbnail","payload":{"operationId":"\#(token.id.uuidString)","frameIndex":1,"thumbnail":{"brightness":0.5,"tint":0.0}}}
            """#.utf8
        )
    ))
    model.handle(event: EngineEvent(
        name: "scanner.thumbnailsComplete",
        rawLine: Data(
            #"""
            {"event":"scanner.thumbnailsComplete","payload":{"operationId":"\#(token.id.uuidString)","count":1}}
            """#.utf8
        )
    ))
    model.toggleFrameSelection(1)
}

@Suite("Control channel recoverable passthrough", .timeLimit(.minutes(1)))
struct ControlRecoverablePassthroughTests {
    @Test("A recoverable FEED_JAM thrown from scanner.eject reaches the caller as recoverable: true")
    @MainActor
    func feedJamFromEjectPassesThroughAsRecoverable() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await driveToEjectReady(model)
        await stub.clearLog()
        await stub.failNext("scanner.eject", with: EngineRequestError(
            code: "FEED_JAM", message: "film jammed mid-feed", recoverable: true
        ))

        let response = await dispatcher.handle(.scannerEject(id: 1, params: ControlScannerEjectParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected a failure response, got \(response)")
            return
        }
        #expect(id == 1)
        #expect(error.code == "FEED_JAM")
        #expect(error.recoverable == true)
        #expect(await stub.recordedMethods.contains("scanner.eject"))
    }

    @Test("A recoverable FEED_JAM thrown from project.setFrameExcluded reaches the caller as recoverable: true through frames.exclude")
    @MainActor
    func feedJamFromSetFrameExcludedPassesThroughAsRecoverable() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await model.openProject(directory: recoverablePassthroughProjectDirectory)
        await stub.clearLog()
        await stub.failNext("project.setFrameExcluded", with: EngineRequestError(
            code: "FEED_JAM", message: "film jammed mid-feed", recoverable: true
        ))

        let response = await dispatcher.handle(.framesExclude(id: 1, params: ControlFrameSelectionParams(frameIndex: 1)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected a failure response, got \(response)")
            return
        }
        #expect(id == 1)
        #expect(error.code == "FEED_JAM")
        #expect(error.recoverable == true)
    }

    @Test("A recoverable FEED_JAM thrown from project.open reaches the caller as recoverable: true through roll.open")
    @MainActor
    func feedJamFromProjectOpenPassesThroughAsRecoverable() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await stub.failNext("project.open", with: EngineRequestError(
            code: "FEED_JAM", message: "film jammed mid-feed", recoverable: true
        ))

        let response = await dispatcher.handle(.rollOpen(id: 1, params: ControlRollOpenParams(directory: recoverablePassthroughProjectDirectory)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected a failure response, got \(response)")
            return
        }
        #expect(id == 1)
        #expect(error.code == "FEED_JAM")
        #expect(error.recoverable == true)
    }

    @Test("A recoverable FEED_JAM thrown from project.list reaches the caller as recoverable: true through roll.list")
    @MainActor
    func feedJamFromProjectListPassesThroughAsRecoverable() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await stub.failNext("project.list", with: EngineRequestError(
            code: "FEED_JAM", message: "film jammed mid-feed", recoverable: true
        ))

        let response = await dispatcher.handle(.rollList(id: 1))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected a failure response, got \(response)")
            return
        }
        #expect(id == 1)
        #expect(error.code == "FEED_JAM")
        #expect(error.recoverable == true)
    }

    @Test("A recoverable FEED_JAM thrown from project.create reaches the caller as recoverable: true through roll.save")
    @MainActor
    func feedJamFromProjectCreatePassesThroughAsRecoverable() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await driveToRollSaveReady(model)
        await stub.clearLog()
        await stub.failNext("project.create", with: EngineRequestError(
            code: "FEED_JAM", message: "film jammed mid-feed", recoverable: true
        ))

        let response = await dispatcher.handle(.rollSave(id: 1, params: ControlRollSaveParams(
            name: "Test roll", carrier: .mounted, frameCount: 1, filmProcess: .c41ColorNegative
        )))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected a failure response, got \(response)")
            return
        }
        #expect(id == 1)
        #expect(error.code == "FEED_JAM")
        #expect(error.recoverable == true)
    }

    @Test("A non-recoverable NOT_CONNECTED thrown from project.open reaches the caller as recoverable: false")
    @MainActor
    func notConnectedFromProjectOpenPassesThroughAsNonRecoverable() async {
        let (_, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await stub.failNext("project.open", with: EngineRequestError(
            code: "NOT_CONNECTED", message: "no scanner connected", recoverable: false
        ))

        let response = await dispatcher.handle(.rollOpen(id: 1, params: ControlRollOpenParams(directory: recoverablePassthroughProjectDirectory)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected a failure response, got \(response)")
            return
        }
        #expect(id == 1)
        #expect(error.code == "NOT_CONNECTED")
        #expect(error.recoverable == false)
    }

    @Test("A second, differently-coded hooked failure reports its own recoverable value, never a stale one from a prior failure")
    @MainActor
    func secondFailureReportsItsOwnRecoverableNeverAStaleOne() async {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await driveToEjectReady(model)
        await stub.clearLog()
        await stub.failNext("scanner.eject", with: EngineRequestError(
            code: "FEED_JAM", message: "film jammed mid-feed", recoverable: true
        ))
        let firstResponse = await dispatcher.handle(.scannerEject(id: 1, params: ControlScannerEjectParams(motionConfirmed: true)))
        guard case .failure(_, let firstError) = firstResponse else {
            Issue.record("expected the first failure to report FEED_JAM, got \(firstResponse)")
            return
        }
        #expect(firstError.code == "FEED_JAM")
        #expect(firstError.recoverable == true)

        await stub.failNext("project.open", with: EngineRequestError(
            code: "PROJECT_NOT_FOUND", message: "no manifest at that directory", recoverable: false
        ))
        let secondResponse = await dispatcher.handle(.rollOpen(id: 2, params: ControlRollOpenParams(directory: recoverablePassthroughProjectDirectory)))
        guard case .failure(let id, let secondError) = secondResponse else {
            Issue.record("expected the second failure to report PROJECT_NOT_FOUND, got \(secondResponse)")
            return
        }
        #expect(id == 2)
        #expect(secondError.code == "PROJECT_NOT_FOUND")
        #expect(secondError.recoverable == false)
    }

    @Test("The encoded failure response never carries evidence, diagnosticEvidence, or details, even when the thrown error carries them")
    @MainActor
    func recoverableFailureNeverLeaksHardwareDiagnosticDetail() async throws {
        let (model, stub, dispatcher) = await makeDispatcher()
        await greet(dispatcher)
        await driveToEjectReady(model)
        await stub.clearLog()
        await stub.failNext("scanner.eject", with: EngineRequestError(
            code: "FEED_JAM",
            message: "film jammed mid-feed",
            recoverable: true,
            evidence: DiagnosticEvidenceReference(
                schemaVersion: 1,
                evidenceId: "leak-test-evidence",
                operationId: "leak-test-op",
                sessionEpoch: "leak-test-epoch"
            ),
            diagnosticEvidenceUnavailableReason: "leak-test unavailable reason"
        ))

        let response = await dispatcher.handle(.scannerEject(id: 1, params: ControlScannerEjectParams(motionConfirmed: true)))
        guard case .failure(let id, let error) = response else {
            Issue.record("expected a failure response, got \(response)")
            return
        }
        #expect(id == 1)
        #expect(error.recoverable == true)
        let encoded = try response.encoded()
        let json = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!json.contains("evidence"))
        #expect(!json.contains("diagnosticEvidence"))
        #expect(!json.contains("details"))
    }
}
