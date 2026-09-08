import Foundation
import Testing
@testable import ScanStudioKit

@Suite("Retained link health")
struct LinkHealthReportTests {
    @Test("counts only recent reported failures and never treats absent evidence as healthy")
    func retainedWindowAndMissingEvidence() {
        let now = Date(timeIntervalSince1970: 1_000)
        let records = """
        {"timestamp":"1970-01-01T00:15:00Z","outcome":"error","message":"bulk READ failed"}
        {"timestamp":"1970-01-01T00:16:00Z","outcome":"error","message":"LIBUSB_ERROR_NO_DEVICE"}
        {"timestamp":"1970-01-01T00:01:00Z","outcome":"error","message":"bulk READ failed"}
        {"timestamp":"1970-01-01T00:16:10Z","outcome":"ok"}
        """ + "\n"
        let report = LinkHealthReport.summarize(Data(records.utf8), now: now, windowSeconds: 100)
        #expect(report.status == "attention")
        #expect(report.recentRecordCount == 3)
        #expect(report.bulkReadFailureCount == 1)
        #expect(report.disconnectIndicatorCount == 1)
        #expect(report.lastOccurrence == "1970-01-01T00:16:00.000Z")
        #expect(LinkHealthReport.summarize(nil, now: now).status == "unknown")
        #expect(LinkHealthReport.summarize(Data("partial".utf8), now: now).malformedRecordCount == 1)
    }
}
