// Decodes all 12 golden fixtures in `protocol/fixtures/` into their typed
// shapes (D-14). Fixture-to-type mapping mirrors Plan 01-01's
// `golden_fixtures.rs`: 01/04/07/10 are requests, 02/03 are success
// responses, 05/06/08/09/11 are events, 12 is an error response.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Fixture decoding")
struct FixtureDecodingTests {
    @Test("Exactly 12 golden fixtures are present")
    func exactlyTwelveFixtures() throws {
        let files = try fixtureFiles()
        #expect(
            files.count == 12,
            "expected exactly 12 fixtures, found \(files.count): \(files.map(\.lastPathComponent))"
        )
    }

    @Test("01: engine.hello request decodes")
    func helloRequest() throws {
        let envelope: DecodedRequestEnvelope<HelloParams> = try decodeFixture("01-hello-request.json")
        #expect(envelope.id == 1)
        #expect(envelope.method == "engine.hello")
        #expect(envelope.params.clientName == "ScanStudio")
        #expect(envelope.params.protocolVersion == 1)
    }

    @Test("02: engine.hello response decodes")
    func helloResponse() throws {
        let envelope: ResponseEnvelope<HelloResult> = try decodeFixture("02-hello-response.json")
        #expect(envelope.result.engineName == "scanstudio-engine")
        #expect(envelope.result.protocolVersion == 1)
        #expect(envelope.result.capabilities == ["simulated-ls5000"])
    }

    @Test("03: scanner.list response decodes")
    func listResponse() throws {
        let envelope: ResponseEnvelope<ScannerListResult> = try decodeFixture("03-list-response.json")
        #expect(envelope.result.devices.count == 1)
        #expect(envelope.result.devices.first?.deviceId == "sim-ls5000-0")
        #expect(envelope.result.devices.first?.model == "SUPER COOLSCAN 5000 ED")
    }

    @Test("04: scanner.connect request decodes")
    func connectRequest() throws {
        let envelope: DecodedRequestEnvelope<ConnectParams> = try decodeFixture("04-connect-request.json")
        #expect(envelope.params.deviceId == "sim-ls5000-0")
        #expect(envelope.params.options.timeScale == 1.0)
        #expect(envelope.params.options.faultInjection == "none")
    }

    @Test("05: scanner.status event decodes")
    func statusEvent() throws {
        let envelope: EventEnvelope<ScannerStatusPayload> = try decodeFixture("05-status-event.json")
        #expect(envelope.event == "scanner.status")
        #expect(envelope.payload.status.connected == true)
        #expect(envelope.payload.status.frameCount == 36)
        #expect(envelope.payload.status.carrier == "roll36")
    }

    @Test("06: scanner.thumbnail event decodes and matches the frame-1 determinism golden")
    func thumbnailEvent() throws {
        let envelope: EventEnvelope<ThumbnailPayload> = try decodeFixture("06-thumbnail-event.json")
        #expect(envelope.payload.frameIndex == 1)
        // This fixture is a simulator-shaped thumbnail: brightness/tint are
        // always set, imagePath is always omitted (Phase 10's one-of wire
        // contract) — force-unwrapped per this suite's own established
        // idiom (see EventAndStateMappingTests.swift's `sniff.event!`).
        #expect(abs(envelope.payload.thumbnail.brightness! - 0.573579766536965) < 1e-9)
        #expect(abs(envelope.payload.thumbnail.tint! - 0.37058823529411766) < 1e-9)
        #expect(envelope.payload.thumbnail.imagePath == nil)
    }

    @Test("07: scan.start request decodes")
    func scanStartRequest() throws {
        let envelope: DecodedRequestEnvelope<ScanStartParams> = try decodeFixture("07-scan-start-request.json")
        #expect(envelope.params.frames == [1, 2, 3])
        #expect(envelope.params.recipe.resolutionDpi == 4000)
        #expect(envelope.params.recipe.multisamplePasses == 2)
        #expect(envelope.params.recipe.channels == "rgbi")
    }

    @Test("08: scan.progress event decodes")
    func progressEvent() throws {
        let envelope: EventEnvelope<ScanProgressPayload> = try decodeFixture("08-progress-event.json")
        #expect(envelope.payload.jobId == "job-1")
        #expect(envelope.payload.frameIndex == 2)
        #expect(envelope.payload.totalFrames == 3)
        #expect(envelope.payload.jobPercent == 47.5)
    }

    @Test("09: scan.frameCompleted event decodes and matches the settingsFingerprint golden")
    func frameCompletedEvent() throws {
        let envelope: EventEnvelope<FrameCompletedPayload> = try decodeFixture("09-frame-completed-event.json")
        #expect(envelope.payload.receipt.settingsFingerprint == "1a3d265e0b54bbd2")
        #expect(envelope.payload.receipt.simulated == true)
        #expect(envelope.payload.receipt.deviceId == "sim-ls5000-0")
    }

    @Test("10: scan.stop request decodes")
    func stopRequest() throws {
        let envelope: DecodedRequestEnvelope<ScanStopParams> = try decodeFixture("10-stop-request.json")
        #expect(envelope.params.jobId == "job-1")
        #expect(envelope.params.mode == "afterCurrentFrame")
    }

    @Test("11: scan.frameState event decodes with a FEED_JAM/recoverable:true error attached")
    func feedJamFrameStateEvent() throws {
        let envelope: EventEnvelope<FrameStatePayload> = try decodeFixture("11-feed-jam-frame-state-event.json")
        #expect(envelope.payload.frameIndex == 13)
        #expect(envelope.payload.state == .failed)
        #expect(envelope.payload.error?.code == "FEED_JAM")
        #expect(envelope.payload.error?.recoverable == true)
    }

    @Test("12: scanner.eject SCANNER_BUSY error response decodes")
    func ejectBusyError() throws {
        let envelope: ResponseErrorEnvelope = try decodeFixture("12-eject-busy-error.json")
        #expect(envelope.error.code == "SCANNER_BUSY")
        #expect(envelope.error.recoverable == false)
    }
}

/// Same trick `EngineLocator` uses to find the package root: strip this
/// file's trailing `FixtureDecodingTests.swift`, `ScanStudioKitTests`, and
/// `Tests` path components, then descend into `protocol/fixtures`.
private func fixturesDirectory(fromTestFile testFilePath: String = #filePath) -> URL {
    URL(fileURLWithPath: testFilePath)
        .deletingLastPathComponent() // FixtureDecodingTests.swift -> ScanStudioKitTests/
        .deletingLastPathComponent() // ScanStudioKitTests/ -> Tests/
        .deletingLastPathComponent() // Tests/ -> package root
        .appendingPathComponent("protocol")
        .appendingPathComponent("fixtures")
}

private func fixtureFiles() throws -> [URL] {
    let directory = fixturesDirectory()
    let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return contents
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func decodeFixture<T: Decodable>(_ filename: String) throws -> T {
    let url = fixturesDirectory().appendingPathComponent(filename)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(T.self, from: data)
}
