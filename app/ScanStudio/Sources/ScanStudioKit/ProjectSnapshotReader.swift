import Foundation

/// Best-effort local manifest refresh, invoked only from a detached task.
/// Oversized/unreadable snapshots keep the existing dirty-state warning.
enum ProjectSnapshotReader {
    static let maximumBytes = 16 * 1_024 * 1_024

    static func read(_ url: URL) -> ScanProject? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.seekToEnd() <= UInt64(maximumBytes) else { return nil }
            try handle.seek(toOffset: 0)
            guard let data = try handle.read(upToCount: maximumBytes + 1),
                  data.count <= maximumBytes else { return nil }
            return try JSONDecoder().decode(ScanProject.self, from: data)
        } catch {
            return nil
        }
    }
}
