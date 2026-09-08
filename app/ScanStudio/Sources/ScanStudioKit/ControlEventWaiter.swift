import Foundation

public enum ControlEventWaitFailure: Error, Equatable, Sendable {
    case timeout
    case hostExited
    case streamEnded
}

public enum ControlEventWaiter {
    public static func wait(
        initial: ControlStatusResult,
        events: AsyncStream<Data>,
        condition: ControlWaitCondition,
        timeout: TimeInterval
    ) async throws -> ControlStatusResult {
        if condition.matches(initial) { return initial }
        guard timeout.isFinite, timeout >= 0 else {
            throw ControlEventWaitFailure.timeout
        }
        let nanoseconds = UInt64(timeout * 1_000_000_000)
        return try await withThrowingTaskGroup(of: ControlStatusResult.self) { group in
            group.addTask {
                for await line in events {
                    if eventName(from: line) == "control.hostExited" {
                        throw ControlEventWaitFailure.hostExited
                    }
                    guard let status = ControlChannelClient.decodeStatusSnapshot(fromEventLine: line) else { continue }
                    if condition.matches(status) { return status }
                }
                throw ControlEventWaitFailure.streamEnded
            }
            group.addTask {
                if nanoseconds > 0 {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } else {
                    await Task.yield()
                }
                throw ControlEventWaitFailure.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func eventName(from line: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["event"] as? String
    }
}
