import Foundation
import Synchronization

/// What the app's requests to each host showed of the path there, for `NetworkPlace` (docs/adaptive-playback.md):
/// the phone's address they left from, which is a tunnel's when a VPN carries them, and how long the server took
/// to start answering.
final class PathMetrics: NSObject, URLSessionTaskDelegate, Sendable {
    struct Path: Sendable {
        var localAddress: String?
        /// The last few waits between a request's end and its answer's start.
        var waits: [TimeInterval] = []

        /// The shortest recent wait: about one round trip, without the server's own time on a slow request.
        var roundTrip: TimeInterval? { waits.min() }
    }

    private let paths = Mutex<[String: Path]>([:])

    func path(to host: String) -> Path? {
        paths.withLock { $0[host] }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let host = task.originalRequest?.url?.host(),
              let transaction = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad })
        else { return }
        var wait: TimeInterval?
        if let sent = transaction.requestEndDate, let answered = transaction.responseStartDate {
            wait = answered.timeIntervalSince(sent)
        }
        paths.withLock { paths in
            var path = paths[host] ?? Path()
            // Another address on the phone is another network: what the old one measured no longer applies.
            if let local = transaction.localAddress, local != path.localAddress {
                path = Path(localAddress: local)
            }
            if let wait { path.waits = Array((path.waits + [wait]).suffix(8)) }
            paths[host] = path
        }
    }
}
