// Bounded URLSession transport for optional web-runtime release assets. Every
// redirect hop is checked by the task delegate; merely validating the final URL
// would permit an attacker-controlled intermediate host to receive a request.

import Foundation

public final class URLSessionWebRuntimeHTTPClient: WebRuntimeHTTPClient, @unchecked Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func download(
        from url: URL,
        to destination: URL,
        maximumBytes: Int64,
        redirectPolicy: WebRuntimeGitHubURLPolicy
    ) async throws -> WebRuntimeHTTPPayload {
        guard maximumBytes > 0,
              redirectPolicy.originalURL == url,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw WebRuntimeDistributionError.invalidRequest
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false

        let delegate = WebRuntimeTransferDelegate(
            redirectPolicy: redirectPolicy,
            maximumBytes: maximumBytes
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(from: url)
        } catch is CancellationError {
            throw WebRuntimeDistributionError.cancelled
        } catch {
            if let failure = delegate.failure { throw failure }
            throw WebRuntimeDistributionError.transportFailed
        }
        if let failure = delegate.failure { throw failure }
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url,
              redirectPolicy.permitsFinalURL(finalURL) else {
            throw WebRuntimeDistributionError.redirectRejected
        }

        let byteCount: Int64
        do {
            byteCount = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                .map(Int64.init) ?? -1
        } catch {
            throw WebRuntimeDistributionError.transportFailed
        }
        guard byteCount >= 0, byteCount <= maximumBytes else {
            throw WebRuntimeDistributionError.responseTooLarge
        }

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw WebRuntimeDistributionError.transportFailed
        }
        return WebRuntimeHTTPPayload(
            fileURL: destination,
            finalURL: finalURL,
            statusCode: http.statusCode,
            byteCount: byteCount
        )
    }
}

private final class WebRuntimeTransferDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let redirectPolicy: WebRuntimeGitHubURLPolicy
    private let maximumBytes: Int64
    private let lock = NSLock()
    private var redirectCount = 0
    private var storedFailure: WebRuntimeDistributionError?

    init(redirectPolicy: WebRuntimeGitHubURLPolicy, maximumBytes: Int64) {
        self.redirectPolicy = redirectPolicy
        self.maximumBytes = maximumBytes
    }

    var failure: WebRuntimeDistributionError? {
        lock.withLock { storedFailure }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = lock.withLock { () -> Bool in
            redirectCount += 1
            guard let candidate = request.url,
                  redirectPolicy.permitsRedirect(to: candidate, hop: redirectCount) else {
                storedFailure = .redirectRejected
                return false
            }
            return true
        }
        completionHandler(allowed ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes
            || (totalBytesExpectedToWrite > maximumBytes && totalBytesExpectedToWrite > 0)
        {
            lock.withLock { storedFailure = .responseTooLarge }
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
