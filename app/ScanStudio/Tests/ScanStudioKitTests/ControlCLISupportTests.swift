// Unit proofs for ControlCLISupport.swift: the D-10 exit-code table, the
// D-09/OUT-01 output envelope, and (Task 3) the D-12 CUPS frame-range
// parser. Follows ControlWireProtocolTests.swift's fixture-free style:
// build inputs directly, assert on the observable shape -- no checked-in
// golden JSON files.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Control CLI support")
struct ControlCLISupportTests {
    // MARK: - ControlCLIExitCode.forErrorCode -- one assertion per
    // ControlErrorCode case (a table change names the case it broke)

    @Test("SCHEMA_VERSION_MISMATCH maps to exit 78")
    func schemaVersionMismatchExitCode() {
        #expect(ControlCLIExitCode.forErrorCode("SCHEMA_VERSION_MISMATCH") == .schemaVersionMismatch)
    }

    @Test("HELLO_REQUIRED maps to exit 78")
    func helloRequiredExitCode() {
        #expect(ControlCLIExitCode.forErrorCode("HELLO_REQUIRED") == .schemaVersionMismatch)
    }

    @Test("UNKNOWN_COMMAND maps to exit 70")
    func unknownCommandExitCode() {
        #expect(ControlCLIExitCode.forErrorCode("UNKNOWN_COMMAND") == .internalError)
    }

    @Test("INVALID_PARAMS maps to exit 64")
    func invalidParamsExitCode() {
        #expect(ControlCLIExitCode.forErrorCode("INVALID_PARAMS") == .usage)
    }

    @Test("CONTROLLER_BUSY maps to exit 75")
    func controllerBusyExitCode() {
        #expect(ControlCLIExitCode.forErrorCode("CONTROLLER_BUSY") == .busy)
    }

    @Test("CONFIRMATION_REQUIRED maps to exit 77")
    func confirmationRequiredExitCode() {
        #expect(ControlCLIExitCode.forErrorCode("CONFIRMATION_REQUIRED") == .confirmationRequired)
    }

    @Test("GATE_REFUSED maps to exit 65")
    func gateRefusedExitCode() {
        #expect(ControlCLIExitCode.forErrorCode("GATE_REFUSED") == .engineOrGateError)
    }

    @Test("an unrecognized code defaults to exit 65 (engine/bridge passthrough)")
    func unknownCodeDefaultsToPassthroughExitCode() {
        #expect(ControlCLIExitCode.forErrorCode("SOME_FUTURE_ENGINE_CODE") == .engineOrGateError)
    }

    // MARK: - ControlCLIErrorCode -- one assertion per case

    @Test("ControlCLIErrorCode.confirmationRequired maps to exit 77")
    func cliConfirmationRequiredExitCode() {
        #expect(ControlCLIExitCode.forErrorCode(ControlCLIErrorCode.confirmationRequired.rawValue) == .confirmationRequired)
    }

    @Test("ControlCLIErrorCode.hostUnreachable maps to exit 69")
    func cliHostUnreachableExitCode() {
        #expect(ControlCLIExitCode.forErrorCode(ControlCLIErrorCode.hostUnreachable.rawValue) == .noHostReachable)
    }

    @Test("ControlCLIErrorCode.invalidRange maps to exit 64")
    func cliInvalidRangeExitCode() {
        #expect(ControlCLIExitCode.forErrorCode(ControlCLIErrorCode.invalidRange.rawValue) == .usage)
    }

    @Test("ControlCLIErrorCode.jobNotFound maps to exit 65")
    func cliJobNotFoundExitCode() {
        #expect(ControlCLIExitCode.forErrorCode(ControlCLIErrorCode.jobNotFound.rawValue) == .engineOrGateError)
    }

    @Test("ControlCLIErrorCode.internalCode maps to exit 70")
    func cliInternalCodeExitCode() {
        #expect(ControlCLIExitCode.forErrorCode(ControlCLIErrorCode.internalCode.rawValue) == .internalError)
    }

    // MARK: - ControlCLIOutput

    @Test("a rendered result envelope round-trips schemaVersion, command, and mode")
    func resultEnvelopeRoundTrips() throws {
        let rendered = try ControlCLIOutput.renderResult(command: "status", resultJSON: ["connected": true], human: false)
        let data = try #require(rendered.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == ControlSchema.version)
        #expect(object["command"] as? String == "status")
        #expect(object["mode"] as? String == "unreached")
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["connected"] as? Bool == true)
    }

    @Test("a rendered error envelope round-trips all five ControlErrorPayload fields")
    func errorEnvelopeRoundTripsAllFields() throws {
        let payload = ControlErrorPayload(
            code: "FEED_JAM",
            message: "feed jam detected",
            recoverable: true,
            guidance: "Clear the jam and retry.",
            gate: "hardwareMotionReadiness"
        )
        let rendered = try ControlCLIOutput.renderError(command: "scan", payload: payload, human: false)
        let data = try #require(rendered.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(error["code"] as? String == "FEED_JAM")
        #expect(error["message"] as? String == "feed jam detected")
        #expect(error["recoverable"] as? Bool == true)
        #expect(error["guidance"] as? String == "Clear the jam and retry.")
        #expect(error["gate"] as? String == "hardwareMotionReadiness")
    }

    @Test("a rendered error envelope omits nil guidance and gate rather than encoding null")
    func errorEnvelopeOmitsNilOptionalKeys() throws {
        let payload = ControlErrorPayload(.helloRequired, message: "hello required")
        let rendered = try ControlCLIOutput.renderError(command: "status", payload: payload, human: false)
        let data = try #require(rendered.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(error["guidance"] == nil)
        #expect(error["gate"] == nil)
        #expect(Set(error.keys) == Set(["code", "message", "recoverable"]))
    }

    @Test("a rendered event envelope nests eventJSON under \"event\"")
    func eventEnvelopeNestsPayload() throws {
        let rendered = try ControlCLIOutput.renderEvent(command: "events", eventJSON: ["kind": "control.snapshot"], human: false)
        let data = try #require(rendered.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let event = try #require(object["event"] as? [String: Any])

        #expect(event["kind"] as? String == "control.snapshot")
    }

    @Test("rendering the same input twice produces identical bytes")
    func renderingIsIdempotentAndSorted() throws {
        let first = try ControlCLIOutput.renderResult(command: "frames.list", resultJSON: ["b": 2, "a": 1], human: false)
        let second = try ControlCLIOutput.renderResult(command: "frames.list", resultJSON: ["b": 2, "a": 1], human: false)
        #expect(first == second)
    }

    @Test("JSON rendering ends with exactly one trailing newline")
    func jsonRenderingEndsWithTrailingNewline() throws {
        let rendered = try ControlCLIOutput.renderResult(command: "status", resultJSON: [:], human: false)
        #expect(rendered.hasSuffix("\n"))
        #expect(!rendered.hasSuffix("\n\n"))
    }

    @Test("human rendering contains the message text and no JSON braces")
    func humanRenderingHasNoBraces() throws {
        let payload = ControlErrorPayload(.controllerBusy, message: "scan.start is already running")
        let rendered = try ControlCLIOutput.renderError(command: "scan", payload: payload, human: true)

        #expect(rendered.contains("scan.start is already running"))
        #expect(!rendered.contains("{"))
    }

    // MARK: - ControlFrameRangeParser -- accepted shapes

    @Test("\"1-36,38\" yields 1...36 plus 38")
    func rangeWithTrailingSingleValue() throws {
        #expect(try ControlFrameRangeParser.parse("1-36,38") == Array(1...36) + [38])
    }

    @Test("\"7\" yields [7]")
    func singleIndex() throws {
        #expect(try ControlFrameRangeParser.parse("7") == [7])
    }

    @Test("\"7-7\" yields [7] (single-value range)")
    func singleValueRange() throws {
        #expect(try ControlFrameRangeParser.parse("7-7") == [7])
    }

    @Test("\"3,1-2,2\" yields [1,2,3] (deduplicated, sorted)")
    func deduplicatedAndSorted() throws {
        #expect(try ControlFrameRangeParser.parse("3,1-2,2") == [1, 2, 3])
    }

    @Test("the parser never returns a value less than 1")
    func neverReturnsBelowOne() throws {
        let allResults = try ["1-36,38", "7", "7-7", "3,1-2,2"].flatMap { try ControlFrameRangeParser.parse($0) }
        #expect(allResults.allSatisfy { $0 >= 1 })
    }

    // MARK: - ControlFrameRangeParser -- rejected shapes (one input per assertion)

    @Test("empty string is rejected")
    func rejectsEmptyString() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("") }
    }

    @Test("a whitespace-only string is rejected")
    func rejectsWhitespaceOnlyString() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse(" ") }
    }

    @Test("\"0\" is rejected (frame indices are 1-based)")
    func rejectsZero() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("0") }
    }

    @Test("\"-3\" is rejected (negative)")
    func rejectsNegative() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("-3") }
    }

    @Test("\"1-\" is rejected (missing upper bound)")
    func rejectsMissingUpperBound() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("1-") }
    }

    @Test("\"1,,2\" is rejected (doubled comma)")
    func rejectsDoubledComma() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("1,,2") }
    }

    @Test("\"1,\" is rejected (trailing comma)")
    func rejectsTrailingComma() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("1,") }
    }

    @Test("\",1\" is rejected (leading comma)")
    func rejectsLeadingComma() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse(",1") }
    }

    @Test("\"a\" is rejected (non-numeric)")
    func rejectsNonNumeric() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("a") }
    }

    @Test("\"1-a\" is rejected (non-numeric upper bound)")
    func rejectsNonNumericUpperBound() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("1-a") }
    }

    @Test("\"5-2\" is rejected (descending range)")
    func rejectsDescendingRange() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("5-2") }
    }

    @Test("a value overflowing Int is rejected")
    func rejectsIntOverflow() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("99999999999999999999") }
    }

    // MARK: - ControlFrameRangeParser -- T-02-13/T-02-28 span/total ceiling

    @Test("\"1-100000000\" is rejected instantly, never materializing a hundred-million-element Set")
    func rejectsOversizedSingleRangeWithoutMaterializing() {
        let start = Date()
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("1-100000000") }
        // A bound on wall-clock time, not just the thrown-error type: if the
        // fix regressed to checking the span only after `formUnion`, this
        // would take multiple seconds (or exhaust memory first) rather than
        // failing via pure arithmetic before any Set mutation.
        #expect(Date().timeIntervalSince(start) < 1.0, "must reject via arithmetic, never by materializing the range")
    }

    @Test("many individually-small ranges that sum past 1,000 total are rejected")
    func rejectsManyRangesSummingPastTheCeiling() {
        // Three 500-index ranges: the first two land exactly at the 1,000
        // ceiling; the third pushes the running total to 1,500.
        #expect(throws: ControlFrameRangeError.self) {
            try ControlFrameRangeParser.parse("1-500,501-1000,1001-1500")
        }
    }

    @Test("exactly 1,000 indices (the ceiling itself) is accepted")
    func acceptsExactlyTheCeiling() throws {
        let result = try ControlFrameRangeParser.parse("1-1000")
        #expect(result.count == 1_000)
        #expect(result.first == 1)
        #expect(result.last == 1_000)
    }

    @Test("1,001 indices (one past the ceiling) is rejected")
    func rejectsOneIndexPastTheCeiling() {
        #expect(throws: ControlFrameRangeError.self) { try ControlFrameRangeParser.parse("1-1001") }
    }

    // MARK: - ControlProgressLine (D-17)

    private static func progress(etaSeconds: Double) -> ControlScanProgress {
        ControlScanProgress(
            jobId: "job-1",
            frameIndex: 3,
            frameOrdinal: 3,
            totalFrames: 36,
            pass: 1,
            totalPasses: 4,
            framePercent: 50.0,
            jobPercent: 8.0,
            etaSeconds: etaSeconds
        )
    }

    @Test("render produces the literal 'frame 3/36 pass 1/4 eta 1h52m' shape")
    func renderProducesTheDocumentedLiteralShape() {
        // 1h52m == 6_720s (1*3600 + 52*60); an exact minute boundary keeps
        // the assertion unambiguous about rounding.
        let line = ControlProgressLine.render(Self.progress(etaSeconds: 6_720))
        #expect(line == "frame 3/36 pass 1/4 eta 1h52m")
    }

    @Test("renderDuration formats at or above an hour as <h>h<mm>m, minutes zero-padded")
    func renderDurationHourTier() {
        #expect(ControlProgressLine.renderDuration(6_720) == "1h52m")
        // 1h00m05s rounds down to the hour tier's own shape (no seconds
        // component at this tier) with zero-padded single-digit minutes.
        #expect(ControlProgressLine.renderDuration(3_605) == "1h00m")
    }

    @Test("renderDuration formats at or above a minute as <m>m<ss>s, seconds zero-padded")
    func renderDurationMinuteTier() {
        #expect(ControlProgressLine.renderDuration(65) == "1m05s")
        #expect(ControlProgressLine.renderDuration(59.9) == "1m00s")
    }

    @Test("renderDuration formats below a minute as <s>s")
    func renderDurationSecondTier() {
        #expect(ControlProgressLine.renderDuration(1) == "1s")
        #expect(ControlProgressLine.renderDuration(59) == "59s")
    }

    @Test("renderDuration never fabricates a duration: zero, negative, NaN, and infinite all render 'unknown'")
    func renderDurationNeverFabricates() {
        #expect(ControlProgressLine.renderDuration(0) == "unknown")
        #expect(ControlProgressLine.renderDuration(-1) == "unknown")
        #expect(ControlProgressLine.renderDuration(.nan) == "unknown")
        #expect(ControlProgressLine.renderDuration(.infinity) == "unknown")
    }
}
