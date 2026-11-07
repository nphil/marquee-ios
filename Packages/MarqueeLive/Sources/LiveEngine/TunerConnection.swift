import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Monotonic seconds, for timings.
@inline(__always) func monotonicNow() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

/// A stream the tuner would not start: the HTTP status, the `X-HDHomeRun-Error` code and text, and the
/// sentence in the body (LumaTuner says why there, for example "the TV is in use: Live TV is in front").
public struct TunerRefusal: Error, Sendable, Equatable {
    public var status: Int
    public var code: Int?
    public var reason: String?
    public var message: String?

    public init(status: Int, errorHeader: String?, body: Data) {
        self.status = status
        if let header = errorHeader?.trimmingCharacters(in: .whitespaces), !header.isEmpty {
            let parts = header.split(separator: " ", maxSplits: 1)
            code = parts.first.flatMap { Int($0) }
            let text = code == nil ? header : parts.dropFirst().first.map(String.init)
            reason = text?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        }
        message = Self.sentence(body)
    }

    /// Every tuner is taken, by the TV or another client (805), or the device has no free connection.
    public var isBusy: Bool { code == 805 || (code == nil && status == 503) }
    /// 811: the channel is protected (DRM).
    public var isProtected: Bool { code == 811 }

    /// What to show: the tuner's own sentence when it sent one.
    public var text: String {
        message ?? reason ?? (status == 503 ? "The tuner is busy." : "The tuner answered \(status).")
    }

    /// The first line of a plain-text body, without markup, at most 200 characters.
    private static func sentence(_ body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        var text = String(decoding: body.prefix(4096), as: UTF8.self)
        if text.contains("<") {
            text = text.replacingOccurrences(of: "<[^>]*>", with: "\n", options: .regularExpression)
        }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { String($0.prefix(200)) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// One HTTP request for a channel's stream. A 200's body goes into `ring`; any other status is collected
/// and reported as a `TunerRefusal`. Events arrive on the connection's own serial queue.
public final class TunerConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public enum Event: Sendable {
        /// The response headers, with seconds since the request went out.
        case response(status: Int, after: Double)
        case firstByte(after: Double)
        case refused(TunerRefusal)
        /// The stream stopped: nil when the server closed it, else the network error.
        case ended(String?)
    }

    public let url: URL
    public let ring: ByteRing
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    // Guarded by `lock`.
    private var session: URLSession?
    private var startedAt = 0.0
    private var status = 0
    private var errorHeader: String?
    private var body = Data()
    private var sawByte = false
    private var cancelled = false

    public init(url: URL, ring: ByteRing, onEvent: @escaping @Sendable (Event) -> Void) {
        self.url = url
        self.ring = ring
        self.onEvent = onEvent
        super.init()
    }

    public func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // The longest wait for the next bytes; the pipeline's own watchdog acts much sooner.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // The pipeline's reader and the main thread wait on the ring's lock this queue writes under; any lower and
        // they would wait on a lower-priority thread.
        queue.qualityOfService = .userInteractive
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        #if !canImport(FoundationNetworking)
        request.networkServiceType = .avStreaming
        #endif
        lock.withLock {
            self.session = session
            startedAt = monotonicNow()
        }
        session.dataTask(with: request).resume()
    }

    /// Closes the request; the tuner sees the connection drop and lets the channel go.
    public func cancel() {
        let session = lock.withLock {
            cancelled = true
            defer { self.session = nil }
            return self.session
        }
        session?.invalidateAndCancel()
        ring.cancel()
    }

    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        noteResponse(response)
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let response = dataTask.response { noteResponse(response) }
        let (status, first, after) = lock.withLock {
            let first = !sawByte
            sawByte = true
            if status != 200, body.count < 4096 { body.append(data.prefix(4096 - body.count)) }
            return (status, first, monotonicNow() - startedAt)
        }
        guard status == 200 else { return }
        if first { onEvent(.firstByte(after: after)) }
        ring.write(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let response = task.response { noteResponse(response) }
        let (status, header, body, cancelled) = lock.withLock { (status, errorHeader, body, self.cancelled) }
        session.finishTasksAndInvalidate()
        guard !cancelled else { return }
        if status != 0, status != 200 {
            onEvent(.refused(TunerRefusal(status: status, errorHeader: header, body: body)))
        } else {
            ring.finish()
            onEvent(.ended(error.map { $0.localizedDescription }))
        }
    }

    /// Records the status once, from whichever callback sees the response first.
    private func noteResponse(_ response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return }
        let after: Double? = lock.withLock {
            guard status == 0 else { return nil }
            status = http.statusCode
            errorHeader = http.value(forHTTPHeaderField: "X-HDHomeRun-Error")
            return monotonicNow() - startedAt
        }
        if let after { onEvent(.response(status: http.statusCode, after: after)) }
    }
}
