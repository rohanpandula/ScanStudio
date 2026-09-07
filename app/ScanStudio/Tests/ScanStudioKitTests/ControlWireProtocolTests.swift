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
}
