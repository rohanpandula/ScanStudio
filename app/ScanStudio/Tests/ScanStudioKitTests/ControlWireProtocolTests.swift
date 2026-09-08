// Round-trip coverage for ControlWireProtocol.swift's leaf types. Follows
// ProjectWireProtocolTests.swift's fixture-free style: encode with
// JSONEncoder, decode back with JSONDecoder, assert equality — no checked-in
// golden JSON files, since Phase 1 adds no new fixtures.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Control wire protocol")
struct ControlWireProtocolTests {
    @Test("ControlSchema.version is 1")
    func schemaVersionIsOne() {
        #expect(ControlSchema.version == 1)
    }

    @Test("ControlErrorCode raw values pin the exact D-03 strings")
    func errorCodeRawValuesPinD03Strings() {
        #expect(ControlErrorCode.schemaVersionMismatch.rawValue == "SCHEMA_VERSION_MISMATCH")
        #expect(ControlErrorCode.helloRequired.rawValue == "HELLO_REQUIRED")
        #expect(ControlErrorCode.unknownCommand.rawValue == "UNKNOWN_COMMAND")
        #expect(ControlErrorCode.invalidParams.rawValue == "INVALID_PARAMS")
        #expect(ControlErrorCode.controllerBusy.rawValue == "CONTROLLER_BUSY")
        #expect(ControlErrorCode.confirmationRequired.rawValue == "CONFIRMATION_REQUIRED")
        #expect(ControlErrorCode.gateRefused.rawValue == "GATE_REFUSED")
    }

    @Test("ControlErrorPayload round-trips through JSONEncoder/JSONDecoder")
    func errorPayloadRoundTrips() throws {
        let original = ControlErrorPayload(
            .controllerBusy,
            message: "scan.start is already running",
            guidance: "Wait for the current operation to finish.",
            gate: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ControlErrorPayload.self, from: data)
        #expect(decoded == original)
    }

    @Test("a ControlErrorPayload with nil guidance and gate omits those keys instead of encoding null")
    func errorPayloadOmitsNilOptionalKeys() throws {
        let payload = ControlErrorPayload(.helloRequired, message: "hello required")
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["guidance"] == nil, "an omitted guidance must not serialize as a null key")
        #expect(object["gate"] == nil, "an omitted gate must not serialize as a null key")
        #expect(object["code"] as? String == "HELLO_REQUIRED")
        #expect(object["recoverable"] as? Bool == false)
    }

    @Test("ControlErrorPayload never encodes a hardware evidence field, from either init")
    func errorPayloadCarriesNoEvidenceFields() throws {
        let passthrough = ControlErrorPayload(
            code: "FEED_JAM",
            message: "feed jam",
            recoverable: true,
            guidance: "Clear the jam.",
            gate: nil
        )
        let data = try JSONEncoder().encode(passthrough)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["evidence"] == nil)
        #expect(object["diagnosticEvidence"] == nil)
        #expect(object["details"] == nil)
        #expect(object["code"] as? String == "FEED_JAM", "an engine-originated code passes through verbatim")
        #expect(object["recoverable"] as? Bool == true)
    }

    @Test("ControlHelloParams round-trips through JSONEncoder/JSONDecoder")
    func helloParamsRoundTrips() throws {
        let original = ControlHelloParams(schemaVersion: 1, clientName: "scanstudio-cli", clientBuild: "0.7.1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ControlHelloParams.self, from: data)
        #expect(decoded == original)
    }

    @Test("ControlHelloParams omits clientBuild entirely when nil")
    func helloParamsOmitsClientBuildWhenNil() throws {
        let params = ControlHelloParams(schemaVersion: 1, clientName: "scanstudio-cli")
        let data = try JSONEncoder().encode(params)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["clientBuild"] == nil, "an omitted clientBuild must not serialize as a null key")
    }

    @Test("ControlMethodSniff decodes id and method out of a line carrying an undeclared params object")
    func methodSniffIgnoresUndeclaredParams() throws {
        let line = #"{"id":7,"method":"scan.start","params":{"motionConfirmed":true}}"#
        let sniff = try JSONDecoder().decode(ControlMethodSniff.self, from: Data(line.utf8))
        #expect(sniff.id == 7)
        #expect(sniff.method == "scan.start")
    }

    // MARK: - Round-trip helper

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Params round-trips (all 25 D-05 commands)

    @Test("ControlPreviewAcquireParams round-trips")
    func previewAcquireParamsRoundTrips() throws {
        let original = ControlPreviewAcquireParams(
            filmLoadedConfirmed: true,
            intent: "replaceFilmProcess",
            filmProcess: .c41ColorNegative
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlScanStartParams round-trips")
    func scanStartParamsRoundTrips() throws {
        let original = ControlScanStartParams(motionConfirmed: true)
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlScanResumeParams round-trips")
    func scanResumeParamsRoundTrips() throws {
        let original = ControlScanResumeParams(motionConfirmed: true)
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlScannerEjectParams round-trips")
    func scannerEjectParamsRoundTrips() throws {
        let original = ControlScannerEjectParams(motionConfirmed: true)
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlReviewApproveParams round-trips")
    func reviewApproveParamsRoundTrips() throws {
        let original = ControlReviewApproveParams(motionConfirmed: true)
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlScannerConnectParams round-trips")
    func scannerConnectParamsRoundTrips() throws {
        let original = ControlScannerConnectParams(deviceId: "sim-ls5000-0")
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlFrameSelectionParams round-trips")
    func frameSelectionParamsRoundTrips() throws {
        let original = ControlFrameSelectionParams(frameIndex: 12)
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlFramesPlaceParams round-trips and defaults replay closed")
    func framesPlaceParamsRoundTrips() throws {
        let original = ControlFramesPlaceParams(
            rows: [0, 100, 200],
            placements: [ControlFramePlacement(slot: 2, rowOffset: -4)]
        )
        #expect(try roundTrip(original) == original)

        let legacyShape = try JSONDecoder().decode(
            ControlFramesPlaceParams.self,
            from: Data(#"{"placements":[{"slot":1,"rowOffset":4}]}"#.utf8)
        )
        #expect(legacyShape.replay == false)
    }

    @Test("ControlScanStopParams round-trips")
    func scanStopParamsRoundTrips() throws {
        let original = ControlScanStopParams(mode: "immediate")
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlRollSaveParams round-trips")
    func rollSaveParamsRoundTrips() throws {
        let original = ControlRollSaveParams(
            name: "Kitchen Table Roll",
            carrier: .roll36,
            frameCount: 36,
            filmProcess: .c41ColorNegative,
            motionConfirmed: true
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlRollOpenParams round-trips")
    func rollOpenParamsRoundTrips() throws {
        let original = ControlRollOpenParams(directory: "/Users/test/ScanStudio Projects/roll-1")
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlSettingsSetParams round-trips")
    func settingsSetParamsRoundTrips() throws {
        let original = ControlSettingsSetParams(
            capture: CaptureRecipe(resolutionDpi: 4000, bitDepth: 16, multisamplePasses: 4, channels: "rgbi"),
            processing: ProcessingRecipe(
                filmProcess: .c41ColorNegative,
                autofocusEachFrame: true,
                autoExposureEachFrame: true,
                digitalIceEnabled: true,
                digitalIceMode: .legacy
            )
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlOutputsSetParams round-trips")
    func outputsSetParamsRoundTrips() throws {
        let original = ControlOutputsSetParams(outputs: Self.sampleOutputRecipe)
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlDiagnosticsExportParams round-trips")
    func diagnosticsExportParamsRoundTrips() throws {
        let original = ControlDiagnosticsExportParams(directory: "/Users/test/Diagnostics")
        #expect(try roundTrip(original) == original)
    }

    // MARK: - Result round-trips

    @Test("ControlScanProgress round-trips")
    func scanProgressRoundTrips() throws {
        let original = ControlScanProgress(
            jobId: "job-1",
            frameIndex: 3,
            frameOrdinal: 2,
            totalFrames: 36,
            pass: 1,
            totalPasses: 4,
            framePercent: 50.0,
            jobPercent: 12.5,
            etaSeconds: 240.0
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlProjectSummary round-trips")
    func projectSummaryRoundTrips() throws {
        let original = ControlProjectSummary(
            id: "proj-1",
            name: "Kitchen Table Roll",
            carrier: .roll36,
            frameCount: 36,
            filmProcess: .c41ColorNegative,
            createdAt: "2026-07-22T09:00:00Z",
            directory: "/Users/test/ScanStudio Projects/roll-1"
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlStatusResult round-trips")
    func statusResultRoundTrips() throws {
        let original = ControlStatusResult(
            device: DeviceInfo(
                deviceId: "sim-ls5000-0",
                model: "LS-5000 ED",
                kind: "simulated",
                firmware: "1.03",
                connection: "usb",
                supported: true,
                supportedMultisamplePasses: [4]
            ),
            scanner: ScannerStatus(
                connected: true,
                adapter: "SA-30",
                mediaLoaded: false,
                carrier: "roll36",
                frameCount: 36,
                lamp: "stable",
                transport: "idle",
                activeJobId: nil,
                filmPresent: true,
                motionArmed: true
            ),
            projectName: "Kitchen Table Roll",
            projectDirectory: "/Users/test/ScanStudio Projects/roll-1",
            jobId: nil,
            jobState: nil,
            refeedRequired: false,
            hardwareMotionReadiness: "ready",
            motionAllowed: true,
            motionGuidance: nil,
            mutatingOperationInFlight: nil,
            selectedFrames: [1, 2, 3],
            scanReadiness: "previewsUnavailable",
            scanReadinessReason: "Preview the loaded film before scanning.",
            lastErrorMessage: nil
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlFrameSummary round-trips")
    func frameSummaryRoundTrips() throws {
        let original = ControlFrameSummary(
            index: 4,
            excluded: false,
            selected: true,
            hasThumbnail: true,
            state: "completed",
            manualReviewDecision: nil,
            errorCode: nil
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlFramesListResult round-trips")
    func framesListResultRoundTrips() throws {
        let original = ControlFramesListResult(
            frames: [
                ControlFrameSummary(index: 1, excluded: false, selected: true, hasThumbnail: true),
                ControlFrameSummary(index: 2, excluded: true, selected: false, hasThumbnail: false),
            ],
            selectedFrames: [1]
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlJobResult round-trips")
    func jobResultRoundTrips() throws {
        let original = ControlJobResult(
            jobId: "job-1",
            jobState: .scanning,
            progress: ControlScanProgress(
                jobId: "job-1",
                frameIndex: 3,
                frameOrdinal: 2,
                totalFrames: 36,
                pass: 1,
                totalPasses: 4,
                framePercent: 50.0,
                jobPercent: 12.5,
                etaSeconds: 240.0
            ),
            completedFrameCount: 2,
            pendingFrameCount: 34,
            receiptCount: 2,
            frameErrorCodes: ["5": "FEED_JAM"]
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlSettingsResult round-trips")
    func settingsResultRoundTrips() throws {
        let original = ControlSettingsResult(
            capture: CaptureRecipe(resolutionDpi: 4000, bitDepth: 16, multisamplePasses: 4, channels: "rgbi"),
            processing: ProcessingRecipe(
                filmProcess: .c41ColorNegative,
                autofocusEachFrame: true,
                autoExposureEachFrame: true,
                digitalIceEnabled: true,
                digitalIceMode: .legacy
            )
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlOutputsResult round-trips")
    func outputsResultRoundTrips() throws {
        let original = ControlOutputsResult(outputs: Self.sampleOutputRecipe)
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlScannerListResult round-trips")
    func scannerListResultRoundTrips() throws {
        let original = ControlScannerListResult(devices: [
            DeviceInfo(
                deviceId: "sim-ls5000-0",
                model: "LS-5000 ED",
                kind: "simulated",
                firmware: "1.03",
                connection: "usb",
                supported: true,
                supportedMultisamplePasses: nil
            )
        ])
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlRollListResult round-trips")
    func rollListResultRoundTrips() throws {
        let original = ControlRollListResult(projects: [
            ControlProjectSummary(
                id: "proj-1",
                name: "Kitchen Table Roll",
                carrier: .roll36,
                frameCount: 36,
                filmProcess: .c41ColorNegative,
                createdAt: "2026-07-22T09:00:00Z",
                directory: "/Users/test/ScanStudio Projects/roll-1"
            )
        ])
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlRollSaveResult round-trips")
    func rollSaveResultRoundTrips() throws {
        let original = ControlRollSaveResult(
            saved: true,
            projectName: "Kitchen Table Roll",
            projectDirectory: "/Users/test/ScanStudio Projects/roll-1"
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlPreviewAcquireResult round-trips")
    func previewAcquireResultRoundTrips() throws {
        let original = ControlPreviewAcquireResult(outcome: "started", intentToken: "intent-1")
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlDiagnosticsExportResult round-trips")
    func diagnosticsExportResultRoundTrips() throws {
        let original = ControlDiagnosticsExportResult(
            path: "/Users/test/Diagnostics/bundle.zip",
            entries: ["telemetry.jsonl", "diagnostics.jsonl"]
        )
        #expect(try roundTrip(original) == original)
    }

    @Test("ControlEventsSubscribeResult round-trips")
    func eventsSubscribeResultRoundTrips() throws {
        let original = ControlEventsSubscribeResult(
            subscribed: true,
            snapshot: ControlStatusResult(
                refeedRequired: false,
                hardwareMotionReadiness: "notApplicable",
                motionAllowed: true,
                selectedFrames: [],
                scanReadiness: "scannerDisconnected"
            )
        )
        #expect(try roundTrip(original) == original)
    }

    // MARK: - D-08: confirmation flags decode nil when absent

    @Test("D-08: motionConfirmed decodes nil when the key is absent from JSON")
    func motionConfirmedDecodesNilWhenAbsent() throws {
        let empty = Data("{}".utf8)
        let scanStart = try JSONDecoder().decode(ControlScanStartParams.self, from: empty)
        let scanResume = try JSONDecoder().decode(ControlScanResumeParams.self, from: empty)
        let eject = try JSONDecoder().decode(ControlScannerEjectParams.self, from: empty)
        let reviewApprove = try JSONDecoder().decode(ControlReviewApproveParams.self, from: empty)

        #expect(scanStart.motionConfirmed == nil, "D-08: an absent key must decode to nil, never a confirmed default")
        #expect(scanResume.motionConfirmed == nil, "D-08: an absent key must decode to nil, never a confirmed default")
        #expect(eject.motionConfirmed == nil, "D-08: an absent key must decode to nil, never a confirmed default")
        #expect(reviewApprove.motionConfirmed == nil, "D-08: an absent key must decode to nil, never a confirmed default")
    }

    @Test("D-08: filmLoadedConfirmed decodes nil when the key is absent from JSON")
    func filmLoadedConfirmedDecodesNilWhenAbsent() throws {
        let params = try JSONDecoder().decode(ControlPreviewAcquireParams.self, from: Data("{}".utf8))
        #expect(params.filmLoadedConfirmed == nil, "D-08: an absent key must decode to nil, never a confirmed default")
        #expect(params.intent == nil)
        #expect(params.filmProcess == nil)
    }

    // MARK: - T-01-05: frame/job failures carry bare codes only

    @Test("ControlFrameSummary encodes no hardware-diagnostic key")
    func frameSummaryCarriesNoDiagnosticFields() throws {
        let summary = ControlFrameSummary(index: 1, excluded: false, selected: false, hasThumbnail: false, errorCode: "FEED_JAM")
        let data = try JSONEncoder().encode(summary)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["errorCode"] as? String == "FEED_JAM")
        #expect(object["evidence"] == nil)
        #expect(object["diagnosticEvidence"] == nil)
    }

    @Test("ControlJobResult encodes no hardware-diagnostic key")
    func jobResultCarriesNoDiagnosticFields() throws {
        let result = ControlJobResult(completedFrameCount: 1, pendingFrameCount: 2, receiptCount: 1, frameErrorCodes: ["3": "FEED_JAM"])
        let data = try JSONEncoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["frameErrorCodes"] as? [String: String])?["3"] == "FEED_JAM")
        #expect(object["evidence"] == nil)
        #expect(object["diagnosticEvidence"] == nil)
    }

    // MARK: - Fixtures

    private static let sampleOutputRecipe = OutputRecipe(
        archive: ArchiveRecipe(filenameTemplate: "Archive_####", destination: "/Scans/Archive"),
        positive: PositiveRecipe(
            enabled: true,
            fileFormat: .tiff,
            colorProfile: .sRgb,
            filenameTemplate: "Positive_####",
            destination: "/Scans/Positive"
        ),
        preview: PreviewRecipe(
            enabled: true,
            fileFormat: .jpeg,
            maxLongEdgePx: 1024,
            filenameTemplate: "Preview_####",
            destination: "/Scans/Preview"
        )
    )
}
