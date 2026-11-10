import Foundation
import Synchronization

/// Evidence from the actual URLSession transaction, not from a separate route probe.
final class PathMetrics: NSObject, URLSessionTaskDelegate, Sendable {
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
        var localAddresses: [Origin: String] = [:]
    }

    private let state = Mutex(State())

    /// Called synchronously with every network revision, before reading evidence for that revision.
    func networkChanged(to revision: Int, at time: Date = Date()) {
        state.withLock { state in
            state.revision = revision
            state.changedAt = time
            state.localAddresses.removeAll()
            state.newestStart.removeAll()
        }
    }

    /// The phone's address the newest request to `url`'s origin left from, in this network revision.
    func localAddress(to url: URL, revision: Int) -> String? {
        guard let origin = Origin(url) else { return nil }
        return state.withLock { state in
            guard revision == state.revision else { return nil }
            return state.localAddresses[origin]
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }),
              let url = transaction.request.url, let origin = Origin(url), let started = transaction.fetchStartDate
        else { return }
        let local = transaction.localAddress
        state.withLock { state in
            // A callback from a request started before the latest network change cannot refill the new epoch.
            guard started >= state.changedAt else { return }
            guard state.newestStart[origin].map({ started >= $0 }) ?? true else { return }
            state.newestStart[origin] = started
            state.localAddresses[origin] = local
        }
    }
}
