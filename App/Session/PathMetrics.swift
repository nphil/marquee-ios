import Foundation
import Synchronization

/// Evidence from the actual URLSession transaction, not from a separate route probe.
final class PathMetrics: NSObject, URLSessionTaskDelegate, Sendable {
    struct Path: Sendable {
        var localAddress: String?
        var remoteAddress: String?
        var isProxy: Bool = false
        var isCellular: Bool = false
        var isMultipath: Bool = false
        var isReused: Bool = false
        var waits: [TimeInterval] = []
        var roundTrip: TimeInterval? { waits.min() }
    }

    private struct Origin: Hashable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    private struct State {
        var revision = 0
        // Until the first network update, no observation can establish current evidence.
        var changedAt = Date.distantFuture
        var newestStart: [Origin: Date] = [:]
        var paths: [Origin: Path] = [:]
    }

    private let state = Mutex(State())

    /// Called synchronously with every network revision, before reading evidence for that revision.
    func networkChanged(to revision: Int, at time: Date = Date()) {
        state.withLock { state in
            state.revision = revision
            state.changedAt = time
            state.paths.removeAll()
            state.newestStart.removeAll()
        }
    }

    func path(to url: URL, revision: Int) -> Path? {
        guard let origin = Origin(url) else { return nil }
        return state.withLock { state in
            guard revision == state.revision else { return nil }
            return state.paths[origin]
        }
    }


    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }),
              let url = transaction.request.url, let origin = Origin(url), let started = transaction.fetchStartDate
        else { return }
        let wait: TimeInterval?
        if let sent = transaction.requestEndDate, let answered = transaction.responseStartDate {
            wait = answered.timeIntervalSince(sent)
        } else {
            wait = nil
        }
        state.withLock { state in
            // A callback from a request started before the latest network change cannot refill the new epoch.
            guard started >= state.changedAt else { return }
            guard state.newestStart[origin].map({ started >= $0 }) ?? true else { return }
            state.newestStart[origin] = started
            var path = state.paths[origin] ?? Path()
            if path.localAddress != transaction.localAddress || path.remoteAddress != transaction.remoteAddress {
                path = Path()
            }
            path.localAddress = transaction.localAddress
            path.remoteAddress = transaction.remoteAddress
            path.isProxy = transaction.isProxyConnection
            path.isCellular = transaction.isCellular
            path.isMultipath = transaction.isMultipath
            path.isReused = transaction.isReusedConnection
            if let wait { path.waits = Array((path.waits + [wait]).suffix(8)) }
            state.paths[origin] = path
        }
    }
}
