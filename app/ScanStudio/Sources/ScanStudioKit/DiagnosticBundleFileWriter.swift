import Foundation

public enum DiagnosticBundleSaveError: Error, Equatable, LocalizedError, Sendable {
    case writeFailed(path: String, reason: String)
    case verificationFailed(path: String, expectedBytes: Int, actualBytes: Int?)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let path, let reason):
            return "DIAGNOSTIC_WRITE_FAILED: Could not save \(path): \(reason)"
        case .verificationFailed(let path, let expectedBytes, let actualBytes):
            let actual = actualBytes.map(String.init) ?? "missing or not a regular file"
            return "DIAGNOSTIC_VERIFY_FAILED: Saved bundle at \(path) did not verify "
                + "(expected \(expectedBytes) bytes, found \(actual))."
        }
    }
}

/// Atomic diagnostic publication plus a post-write identity/size check.
/// The injectable overload keeps failure behavior deterministic in tests;
/// production uses the convenience overload and Foundation's atomic write.
public enum DiagnosticBundleFileWriter {
    public static func write(_ data: Data, to url: URL) throws {
        try write(
            data,
            to: url,
            writer: { bytes, destination in
                try bytes.write(to: destination, options: .atomic)
            },
            verifier: { destination in
                let values = try destination.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                )
                guard values.isRegularFile == true else { return nil }
                return values.fileSize
            }
        )
    }

    public static func write(
        _ data: Data,
        to url: URL,
        writer: (Data, URL) throws -> Void,
        verifier: (URL) throws -> Int?
    ) throws {
        do {
            try writer(data, url)
        } catch {
            throw DiagnosticBundleSaveError.writeFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }

        let actualBytes: Int?
        do {
            actualBytes = try verifier(url)
        } catch {
            throw DiagnosticBundleSaveError.verificationFailed(
                path: url.path,
                expectedBytes: data.count,
                actualBytes: nil
            )
        }
        guard actualBytes == data.count else {
            throw DiagnosticBundleSaveError.verificationFailed(
                path: url.path,
                expectedBytes: data.count,
                actualBytes: actualBytes
            )
        }
    }
}
