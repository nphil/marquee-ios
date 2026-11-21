import Foundation
import MarqueeCore
import Synchronization

/// Reads the start of a file from the server for `LinkProbe`: at most `LinkProbe.maxBytes`, stopped
/// `LinkProbe.window` after the first byte, timed from the first byte so the answer's wait does not count.
final class LinkProbeRead: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var first: ContinuousClock.Instant?
        var last: ContinuousClock.Instant?
        /// Bytes after the first chunk, which arrived before the clock started.
        var bytes = 0
        var total = 0
        var answer: CheckedContinuation<Int?, Never>?
    }

    private let state = Mutex(State())

    /// The link's rate in kbit/s, or nil when the server did not answer in time or sent too little to judge by.
    static func kbps(of url: URL, headers: [String: String]) async -> Int? {
        let probe = LinkProbeRead()
        var request = URLRequest(url: url, timeoutInterval: LinkProbe.timeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(LinkProbe.maxBytes - 1)", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { answer in
                probe.state.withLock { $0.answer = answer }
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let now = ContinuousClock.now
        let done = state.withLock { state -> Bool in
            if let first = state.first {
                state.bytes += data.count
                state.last = now
                state.total += data.count
                return now - first >= .seconds(LinkProbe.window) || state.total >= LinkProbe.maxBytes
            }
            state.first = now
            state.total = data.count
            return false
        }
        if done { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (answer, kbps) = state.withLock { state -> (CheckedContinuation<Int?, Never>?, Int?) in
            guard let first = state.first, let last = state.last else { return (state.answer, nil) }
            return (state.answer, LinkProbe.kbps(bytes: state.bytes, seconds: (last - first) / .seconds(1)))
        }
        answer?.resume(returning: kbps)
    }
}
