import Foundation
import Testing
@testable import ScanStudioKit

@Suite("Doctor report")
struct DoctorReportTests {
    @Test("aggregates every independent row and is stable apart from its timestamp")
    func completeStableAggregation() throws {
        let observations: [DoctorObservation] = [
            .available(id: "bundle.version", value: "0.8.0", detail: "Signed release stamp."),
            .warning(
                id: "bridge.liveVersion", value: nil, detail: "No host is running.",
                fix: "Start ScanStudio to expose the cached bridge identity."
            ),
            .invalid(
                id: "cli.signature", value: "invalid", detail: "Signature validation failed.",
                fix: "Reinstall the signed ScanStudio bundle."
            ),
        ]
        let first = DoctorReport(generatedAt: "2026-09-08T00:00:00Z", observations: observations)
        let second = DoctorReport(generatedAt: "2026-09-08T00:00:01Z", observations: observations)

        #expect(first.checks == second.checks)
        #expect(first.checks.map(\.id) == ["bundle.version", "bridge.liveVersion", "cli.signature"])
        #expect(first.passCount == 1)
        #expect(first.warnCount == 1)
        #expect(first.failCount == 1)
        #expect(first.hasFailures)
        #expect(first.checks[0].fix == nil)
        #expect(first.checks[1].fix != nil)
        #expect(first.checks[2].status == .fail)

        let roundTrip = try JSONDecoder().decode(DoctorReport.self, from: JSONEncoder().encode(first))
        #expect(roundTrip == first)
    }
}
