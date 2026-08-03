// Ordering + parsing tests for UpdateVersion (AUT-02-CMP, AUT-02-TEST).
// Keep pure: no network, no filesystem.

import XCTest

@testable import ScanStudioKit

final class UpdateVersionTests: XCTestCase {
    private func parse(_ raw: String) -> UpdateVersion {
        guard let version = UpdateVersion(raw: raw) else {
            XCTFail("Expected to parse \(raw)")
            return UpdateVersion(raw: "0.0")!
        }
        return version
    }

    func testOrderingTable() {
        XCTAssertLessThan(parse("0.3.0-alpha.9"), parse("0.3.0-alpha.11"))
        XCTAssertLessThan(parse("0.3.0-alpha.11"), parse("0.3.0"))
        XCTAssertLessThan(parse("0.3.0-alpha.1"), parse("0.3.0-beta.1"))
        XCTAssertLessThan(parse("0.3.0-beta.1"), parse("0.3.0-rc.1"))
        XCTAssertLessThan(parse("0.3.0-rc.1"), parse("0.3.0"))
        XCTAssertEqual(parse("0.3.0"), parse("0.3.0"))

        let padded = UpdateVersion(raw: "0.3.0.0")
        XCTAssertNil(padded, "Core is 2 or 3 dot-separated integers; 4 components are rejected")
        XCTAssertEqual(parse("0.3"), parse("0.3.0"), "Patch-less core defaults patch to 0")

        XCTAssertGreaterThan(parse("1.0.0"), parse("0.9.9"))
    }

    func testCrossMajorOrdering() {
        XCTAssertGreaterThan(parse("2.0.0-alpha.1"), parse("1.9.9"))
    }

    func testParseFailures() {
        for raw in ["", "abc", "1.2.x", "1.2.3-alpha.", "1..2", "1.2.3--bad"] {
            XCTAssertNil(UpdateVersion(raw: raw), "Expected \(String(reflecting: raw)) to be rejected")
        }
    }

    func testIsPrerelease() {
        XCTAssertTrue(parse("0.3.0-alpha.11").isPrerelease)
        XCTAssertTrue(parse("0.3.0-rc.1").isPrerelease)
        XCTAssertFalse(parse("0.3.0").isPrerelease)
    }

    func testCodableRoundTrip() {
        let original = parse("0.3.0-alpha.11")
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(UpdateVersion.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.raw, original.raw)
    }

    func testVPrefixStability() {
        XCTAssertEqual(parse("v0.3.0"), parse("0.3.0"))
    }
}
