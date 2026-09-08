import Foundation
import Testing

@testable import ScanStudioKit

private actor SessionHostEngineStub: EngineClientProtocol {
    nonisolated let events: AsyncStream<EngineEvent> = AsyncStream { _ in }
    var engineVersion: String? = "session-host-stub"
    private(set) var requestCount = 0

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        params _: Params
    ) async throws -> Result {
        requestCount += 1
        guard method == "scanner.list" || method == "scanner.rescan" else {
            throw ControlSocketError(context: "stub request \(method)", errnoValue: EINVAL)
        }
        let result = ScannerListResult(devices: [])
        guard let result = result as? Result else {
            throw ControlSocketError(context: "stub result \(method)", errnoValue: EINVAL)
        }
        return result
    }
}

private func sessionHostSocketPath(_ label: String) -> String {
    let directory = "/tmp/ss-host-\(label)-\(UUID().uuidString)"
    let path = directory + "/control.sock"
    precondition(path.utf8.count < 104)
    return path
}

private func removeSessionHostSocket(_ path: String) {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

private func isolatedSessionHostPreferences() -> (UserDefaults, String) {
    let suite = "scanstudio.session-host-tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite) ?? .standard, suite)
}

private func sessionHostDiagnostics(for path: String) -> URL {
    URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("diagnostics")
}

@Suite("Session host")
@MainActor
struct SessionHostTests {
    @Test("attach serves a socket and reports its host kind")
    func attachServesTheSocketAndReportsItsHostKind() async throws {
        let path = sessionHostSocketPath("attach")
        defer { removeSessionHostSocket(path) }
        let engine = SessionHostEngineStub()
        let (preferences, suite) = isolatedSessionHostPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let handle = try await SessionHost.attach(
            engineClient: engine,
            socketPath: path,
            diagnosticsDirectory: sessionHostDiagnostics(for: path),
            preferences: preferences,
            hostKind: .headless
        )
        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        #expect(await client.helloResult?.host == .headless)
        #expect(await client.helloResult?.hostPid == ProcessInfo.processInfo.processIdentifier)
        await client.shutdown()
        await SessionHost.shutdown(handle)
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test("a second host at a live socket is refused before discovery")
    func aSecondHostAtALiveSocketPathIsRefused() async throws {
        let path = sessionHostSocketPath("second")
        defer { removeSessionHostSocket(path) }
        let (preferences, suite) = isolatedSessionHostPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = try await SessionHost.attach(
            engineClient: SessionHostEngineStub(),
            socketPath: path,
            diagnosticsDirectory: sessionHostDiagnostics(for: path),
            preferences: preferences,
            hostKind: .headless
        )
        let secondEngine = SessionHostEngineStub()
        do {
            _ = try await SessionHost.attach(
                engineClient: secondEngine,
                socketPath: path,
                diagnosticsDirectory: sessionHostDiagnostics(for: path),
                preferences: preferences,
                hostKind: .headless
            )
            Issue.record("expected a live socket refusal")
        } catch let error as ControlSocketError {
            #expect(error.errnoValue == EADDRINUSE)
        }
        #expect(await secondEngine.requestCount == 0)

        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        let response = try await client.requestWithoutParams(method: "status")
        if case .failure(let error) = response {
            Issue.record("first host refused status: \(error.code)")
        }
        await client.shutdown()
        await SessionHost.shutdown(first)
    }

    @Test("shared preferences reach outputs.get")
    func preferencesDomainIsSharedSoAWireVisibleFieldCannotDiverge() async throws {
        let sharedPreferences = SessionHost.sharedPreferences()
        if Bundle.main.bundleIdentifier != "dev.scanstudio.live" {
            #expect(sharedPreferences !== UserDefaults.standard)
        }
        let (preferences, suite) = isolatedSessionHostPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let key = "ScanStudio.filenameTemplateDefault.v1"
        let distinctive = "session-host-\(UUID().uuidString)-{frame}"
        preferences.set(distinctive, forKey: key)

        let path = sessionHostSocketPath("preferences")
        defer { removeSessionHostSocket(path) }
        let handle = try await SessionHost.attach(
            engineClient: SessionHostEngineStub(),
            socketPath: path,
            diagnosticsDirectory: sessionHostDiagnostics(for: path),
            preferences: preferences,
            hostKind: .headless
        )
        let client = try await ControlChannelClient.open(path: path, clientName: "test")
        let response = try await client.requestWithoutParams(method: "outputs.get")
        guard case .result(let data) = response,
              let result = try? JSONDecoder().decode(ControlOutputsResult.self, from: data) else {
            Issue.record("outputs.get did not return a result")
            await client.shutdown()
            await SessionHost.shutdown(handle)
            return
        }
        #expect(result.outputs.archive.filenameTemplate == distinctive)
        await client.shutdown()
        await SessionHost.shutdown(handle)
    }
}
