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
        #expect(object["mode"] as? String == "attach")
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
}
