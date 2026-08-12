import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Optional browser-runtime HTTP transport")
struct WebRuntimeHTTPClientTests {
    @Test("asset transfer keeps a short inactivity timeout and a finite whole-resource timeout")
    func boundedTimeoutConfiguration() {
        let configuration = URLSessionWebRuntimeHTTPClient.makeConfiguration()

        #expect(
            configuration.timeoutIntervalForRequest
                == URLSessionWebRuntimeHTTPClient.defaultInactivityTimeout
        )
        #expect(
            configuration.timeoutIntervalForResource
                == URLSessionWebRuntimeHTTPClient.defaultResourceTimeout
        )
        #expect(
            configuration.timeoutIntervalForResource
                > configuration.timeoutIntervalForRequest
        )
        #expect(configuration.timeoutIntervalForResource.isFinite)
        #expect(configuration.timeoutIntervalForResource > 0)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
    }
}
