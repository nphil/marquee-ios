import Foundation

/// Which of a server's addresses to use: local before remote before relay, and https (plex.direct)
/// before plain http, so a working LAN address always wins over the capped relay.
public enum ConnectionRanking {
    /// Best first: local direct, remote direct, relay. Within each, https before http and IPv4 before IPv6.
    /// Plain http is dropped when the server requires secure connections.
    public static func ordered(_ connections: [PlexConnection], httpsRequired: Bool) -> [PlexConnection] {
        var seen = Set<URL>()
        let usable = connections.filter { (!httpsRequired || $0.isHTTPS) && seen.insert($0.uri).inserted }
        return usable.enumerated().sorted { lhs, rhs in
            let a = sortKey(lhs.element), b = sortKey(rhs.element)
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
    }

    public enum ProbeOutcome: Sendable, Equatable {
        case reachable, failed
    }

    public enum Pick: Sendable, Equatable {
        case use(Int)
        /// A better-ranked address has not answered yet.
        case wait
        case noneReachable
    }

    /// Decides from the probe results so far, indexed like the ordered list (nil = still probing). The
    /// best-ranked reachable address wins once every better one has failed. After `graceExpired`, the best
    /// reachable address so far wins without waiting for slower, better-ranked ones.
    public static func pick(_ outcomes: [ProbeOutcome?], graceExpired: Bool = false) -> Pick {
        if graceExpired, let index = outcomes.firstIndex(of: .reachable) { return .use(index) }
        for (index, outcome) in outcomes.enumerated() {
            switch outcome {
            case .reachable: return .use(index)
            case nil: return .wait
            case .failed: continue
            }
        }
        return .noneReachable
    }

    /// Whether a remembered address may be tried alone, before probing the rest: only a local one. A
    /// remote address can have won only because the LAN probe failed while iOS was still asking for Local
    /// Network access, or while a VPN was on, and trusting it would keep the phone off the LAN for good.
    public static func triesAlone(_ remembered: PlexConnection) -> Bool {
        tier(remembered) == 0
    }

    /// The addresses in a better tier than `current` (local over remote, direct over relay), best first,
    /// from a list in `ordered` order. Empty while a local address is in use.
    public static func upgrades(from current: PlexConnection, in ordered: [PlexConnection]) -> [PlexConnection] {
        ordered.filter { tier($0) < tier(current) }
    }

    private static func tier(_ connection: PlexConnection) -> Int {
        connection.isRelay ? 2 : connection.isLocal ? 0 : 1
    }

    private static func sortKey(_ connection: PlexConnection) -> (Int, Int, Int) {
        (tier(connection), connection.isHTTPS ? 0 : 1, connection.isIPv6 ? 1 : 0)
    }
}
