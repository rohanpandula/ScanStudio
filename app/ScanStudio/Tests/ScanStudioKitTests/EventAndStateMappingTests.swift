// (a) Unknown-event tolerance and (b) JobState/FrameState raw-value mapping
// (D-14). Per D-14's own heading these Swift tests need "no engine process"
// — so unknown-event tolerance is exercised at exactly the layer
// `EngineClient.handleLine` itself relies on for it: `WireSniff` decoding
// and the `AsyncStream<EngineEvent>` yield mechanism, both directly, with
// no `Process`/pipe/subprocess anywhere in this file. `WireSniff` decoding
// is name-agnostic by construction (it only ever asks "is `event` present,"
// never "which event") — recognition/filtering happens downstream in
// `SessionModel`'s `switch`, whose `default: break` is what makes an
// unrecognized case inert rather than thrown; that half is a plain
// language-level guarantee for an exhaustive switch with a `default` arm,
// not something that needs a live subprocess to demonstrate.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Unknown-event tolerance")
struct UnknownEventToleranceTests {
    @Test("a well-formed but unrecognized event name decodes via WireSniff without throwing")
    func unknownEventNameSniffsCleanly() throws {
        let line = Data(#"{"event": "some.future.event", "payload": {}}"#.utf8)

        let sniff = try JSONDecoder().decode(WireSniff.self, from: line)

        #expect(sniff.event == "some.future.event")
        #expect(sniff.id == nil)
    }

    @Test("an event line with an unrecognized name still yields a normal EngineEvent through the AsyncStream")
    func unknownEventStillYieldsThroughTheStream() async throws {
        // Exercises the exact same `AsyncStream<EngineEvent>` mechanism
        // `EngineClient.events` uses, with no `EngineClient`/process
        // involved — `EngineEvent` and its `AsyncStream` are both plain,
        // dependency-free public types.
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream()

        let line = Data(#"{"event": "some.future.event", "payload": {}}"#.utf8)
        let sniff = try JSONDecoder().decode(WireSniff.self, from: line)
        continuation.yield(EngineEvent(name: sniff.event!, rawLine: line))
        continuation.finish()

        var received: [EngineEvent] = []
        for await event in stream {
            received.append(event)
        }

        #expect(received.count == 1)
        #expect(received.first?.name == "some.future.event")
    }

    @Test("an unrecognized event line does not corrupt LineFramer's buffered state for the next, known-good line")
    func unknownEventDoesNotCorruptFramerState() {
        var framer = LineFramer()
        let unknownEventLine = #"{"event": "some.future.event", "payload": {}}"#
        let knownGoodLine = #"{"event": "scanner.status", "payload": {}}"#
        let chunk = Data("\(unknownEventLine)\n\(knownGoodLine)\n".utf8)

        let lines = framer.feed(chunk)

        #expect(lines == [unknownEventLine, knownGoodLine])
    }

    @Test("attempting a typed payload decode against an unrecognized event's own shape does not throw for callers using try?")
    func typedDecodeOfUnknownPayloadFailsSoftly() throws {
        // Downstream consumers (SessionModel's event switch) never attempt
        // a typed decode for a name they don't recognize in the first
        // place (that's the `default: break` case) — but even if a shape
        // mismatch occurred, `try?`-based decoding (used throughout
        // EngineClient/SessionModel) degrades to `nil`, never a thrown
        // error propagating out of the dispatch path.
        struct UnexpectedPayload: Decodable { let mustBePresent: String }
        let line = Data(#"{"event": "some.future.event", "payload": {}}"#.utf8)

        let decoded = try? JSONDecoder().decode(EventEnvelope<UnexpectedPayload>.self, from: line)

        #expect(decoded == nil)
    }
}

@Suite("JobState / FrameState raw-value mapping")
struct StateRawValueMappingTests {
    @Test("JobState raw values equal the exact PROTOCOL.md wire string for every case, both ways")
    func jobStateRawValues() throws {
        let expectations: [(JobState, String)] = [
            (.queued, "queued"),
            (.scanning, "scanning"),
            (.completed, "completed"),
            (.failed, "failed"),
            (.stoppingAfterCurrentFrame, "stoppingAfterCurrentFrame"),
            (.stoppingImmediately, "stoppingImmediately"),
            (.stopped, "stopped"),
        ]

        #expect(expectations.count == 7, "every JobState case must be covered")

        for (state, wire) in expectations {
            #expect(state.rawValue == wire)
            let decoded = try JSONDecoder().decode(JobState.self, from: Data("\"\(wire)\"".utf8))
            #expect(decoded == state)
        }
    }

    @Test("FrameState raw values equal the exact PROTOCOL.md wire string for every case, both ways")
    func frameStateRawValues() throws {
        let expectations: [(FrameState, String)] = [
            (.waiting, "waiting"),
            (.active, "active"),
            (.completed, "completed"),
            (.failed, "failed"),
            (.skipped, "skipped"),
        ]

        #expect(expectations.count == 5, "every FrameState case must be covered")

        for (state, wire) in expectations {
            #expect(state.rawValue == wire)
            let decoded = try JSONDecoder().decode(FrameState.self, from: Data("\"\(wire)\"".utf8))
            #expect(decoded == state)
        }
    }

    @Test("JobState.isTerminal is true only for completed/failed/stopped")
    func jobStateIsTerminal() {
        #expect(JobState.completed.isTerminal)
        #expect(JobState.failed.isTerminal)
        #expect(JobState.stopped.isTerminal)
        #expect(!JobState.queued.isTerminal)
        #expect(!JobState.scanning.isTerminal)
        #expect(!JobState.stoppingAfterCurrentFrame.isTerminal)
        #expect(!JobState.stoppingImmediately.isTerminal)
    }
}

// Phase 10's `Thumbnail` one-of contract (WireProtocol.swift ~line 231,
// protocol.rs:251) has a golden fixture (06) for the simulator's own shape
// (brightness/tint populated, imagePath omitted) but none for the mirror
// image a real backend actually sends — this suite covers that shape
// in-line, matching `ScanReceiptTelemetryTests` below's own precedent for
// covering a wire shape the 12 golden fixtures don't.
@Suite("Real-backend Thumbnail decode (Phase 10 imagePath contract)")
struct RealBackendThumbnailDecodeTests {
    @Test("a real-backend-shaped scanner.thumbnail event decodes imagePath and omits brightness/tint")
    func realBackendThumbnailDecodesImagePath() throws {
        let line = Data(
            #"{"event":"scanner.thumbnail","payload":{"frameIndex":7,"thumbnail":{"imagePath":"/tmp/scanstudio-test-previews/9c2b7e10-preview/slot-0007.tif"}}}"#.utf8
        )

        let envelope = try JSONDecoder().decode(EventEnvelope<ThumbnailPayload>.self, from: line)

        #expect(envelope.event == "scanner.thumbnail")
        #expect(envelope.payload.frameIndex == 7)
        #expect(envelope.payload.thumbnail.imagePath == "/tmp/scanstudio-test-previews/9c2b7e10-preview/slot-0007.tif")
        #expect(envelope.payload.thumbnail.brightness == nil)
        #expect(envelope.payload.thumbnail.tint == nil)
    }

    @Test("a real thumbnail preserves its pre-scan approval requirement and warnings")
    func realBackendThumbnailDecodesManualReviewEvidence() throws {
        let line = Data(
            #"{"event":"scanner.thumbnail","payload":{"frameIndex":5,"thumbnail":{"imagePath":"/tmp/slot-0005.tif","needsApproval":true,"warnings":["ambiguous-content-tail-boundary"]}}}"#.utf8
        )

        let envelope = try JSONDecoder().decode(
            EventEnvelope<ThumbnailPayload>.self,
            from: line
        )

        #expect(envelope.payload.thumbnail.needsApproval)
        #expect(
            envelope.payload.thumbnail.warnings
                == ["ambiguous-content-tail-boundary"]
        )
    }

    @Test("a Thumbnail never decodes both imagePath and brightness/tint from a well-formed event, matching the one-of contract's two established shapes")
    func thumbnailShapesRemainMutuallyExclusiveAcrossBothBackends() throws {
        let simulatorShaped = try JSONDecoder().decode(
            Thumbnail.self,
            from: Data(#"{"brightness":0.5,"tint":0.1}"#.utf8)
        )
        #expect(simulatorShaped.imagePath == nil)

        let realBackendShaped = try JSONDecoder().decode(
            Thumbnail.self,
            from: Data(#"{"imagePath":"/tmp/slot-0001.tif"}"#.utf8)
        )
        #expect(realBackendShaped.brightness == nil)
        #expect(realBackendShaped.tint == nil)
    }
}

@Suite("ScanReceipt telemetry decode")
struct ScanReceiptTelemetryTests {
    private let baseReceiptFields = #""jobId":"job-1","frameIndex":1,"startedAt":"2024-01-01T00:00:00Z","durationMs":1200,"passes":1,"resolutionDpi":4000,"bitDepth":16,"channels":"rgbi","engineVersion":"0.1.0","deviceId":"real-ls5000-0","simulated":false,"settingsFingerprint":"abc123""#

    @Test("a real-backend-shaped ScanReceipt decodes all Phase 10 telemetry fields")
    func realBackendReceiptDecodesTelemetry() throws {
        let json = Data("""
        {
            \(baseReceiptFields),
            "rgbPath": "/tmp/rgb.tif",
            "irPath": "/tmp/ir.tif",
            "meterRgbiPath": "/tmp/meter.json",
            "hardwareTelemetry": {
                "exposure": {"focusPosition": 1000, "exposureMultiplier": 1.0, "redExposureUs": 1000, "greenExposureUs": 1000, "blueExposureUs": 1000},
                "clipping": {"fractions": [0.1, 0.2, 0.3], "clipLevel": 0.99, "warningFraction": 0.05, "warning": false},
                "focusDetail": {"method": "contrast", "verdict": "sharp", "score": 0.95, "textureSpan": 0.8},
                "transportSmear": {"verdict": "smear", "startRow": 100, "suffixRows": 50, "minimumMatches": 10, "tailMedianRms": 1.2, "tailMinCorr": 0.3, "preTailMedianRms": 0.5, "textureSpan": 0.7, "reason": "trailing texture matched"}
            }
        }
        """.utf8)

        let receipt = try JSONDecoder().decode(ScanReceipt.self, from: json)
        #expect(receipt.rgbPath == "/tmp/rgb.tif")
        #expect(receipt.irPath == "/tmp/ir.tif")
        #expect(receipt.meterRgbiPath == "/tmp/meter.json")
        #expect(receipt.hardwareTelemetry?.transportSmear.verdict == "smear")
        #expect(receipt.hardwareTelemetry?.transportSmear.reason == "trailing texture matched")
        #expect(receipt.hardwareTelemetry?.clipping.fractions == [0.1, 0.2, 0.3])
    }

    @Test("a simulator-shaped ScanReceipt missing the real-backend fields decodes cleanly with nils")
    func simulatedReceiptDecodesWithNils() throws {
        let json = Data("""
        {
            \(baseReceiptFields),
            "processing": null,
            "output": null,
            "outputs": null
        }
        """.utf8)

        let receipt = try JSONDecoder().decode(ScanReceipt.self, from: json)
        #expect(receipt.rgbPath == nil)
        #expect(receipt.irPath == nil)
        #expect(receipt.meterRgbiPath == nil)
        #expect(receipt.hardwareTelemetry == nil)
    }
}
