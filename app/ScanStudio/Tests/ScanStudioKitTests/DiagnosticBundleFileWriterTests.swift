import Foundation
import Testing

@testable import ScanStudioKit

struct DiagnosticBundleFileWriterTests {
    private struct Denied: LocalizedError {
        var errorDescription: String? { "permission denied" }
    }

    @Test("a failed destination reports a typed error and never reaches success")
    func failedWriteDoesNotReportSuccess() {
        let destination = URL(fileURLWithPath: "/unwritable/diagnostics.zip")
        var reportedSuccess = false

        do {
            try DiagnosticBundleFileWriter.write(
                Data([1, 2, 3]),
                to: destination,
                writer: { _, _ in throw Denied() },
                verifier: { _ in 3 }
            )
            reportedSuccess = true
        } catch let error as DiagnosticBundleSaveError {
            #expect(
                error == .writeFailed(
                    path: destination.path,
                    reason: "permission denied"
                )
            )
            #expect(error.localizedDescription.contains("DIAGNOSTIC_WRITE_FAILED"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        #expect(!reportedSuccess)
    }

    @Test("success requires the verified byte count to match")
    func sizeMismatchIsRejected() {
        let destination = URL(fileURLWithPath: "/tmp/diagnostics.zip")

        #expect(throws: DiagnosticBundleSaveError.self) {
            try DiagnosticBundleFileWriter.write(
                Data([1, 2, 3]),
                to: destination,
                writer: { _, _ in },
                verifier: { _ in 2 }
            )
        }
    }
}
