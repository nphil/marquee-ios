import Foundation

/// Where the phone is from the server it plays from (docs/adaptive-playback.md). Plex's local flag says only
/// which address answered: away from home, a VPN that routes the home subnet makes the LAN address answer
/// through the tunnel.
public enum NetworkPlace: Sendable, Hashable, CustomStringConvertible {
    /// On the server's own network, reaching it directly.
    case home
    /// The available evidence does not establish where the phone is.
    case unknown
    case away(Away)

    public enum Away: String, Sendable {
        /// Plex's relay, which caps bandwidth.
        case relay
        /// The server's public address.
        case remote
        /// A VPN tunnel such as Tailscale's.
        case tunnel
    }

    public var isHome: Bool { self == .home }

    /// "Home", "Away (tunnel)".
    public var description: String {
        switch self {
        case .home: "Home"
        case .unknown: "Unknown"
        case .away(let reason): "Away (\(reason.rawValue))"
        }
    }

    /// The place of a phone that reaches the server at `connection`.
    /// - Parameters:
    ///   - onPhoneNetwork: whether the server's IP is on an attached non-tunnel network, or nil if unknown.
    ///   - localAddress: the phone's address the last request to the server left from.
    ///   - roundTrip: that request's round trip; latency does not prove presence at home.
    public static func of(
        _ connection: PlexConnection, onPhoneNetwork: Bool?, localAddress: String?, roundTrip: TimeInterval?
    ) -> NetworkPlace {
        if connection.isRelay { return .away(.relay) }
        if [localAddress, connection.ipAddress].contains(where: { $0.map(isTunnel) ?? false }) { return .away(.tunnel) }
        return .unknown
    }

    /// Tailscale's addresses: carrier-grade NAT space and its IPv6 prefix, fd7a:115c:a1e0::/48.
    static func isTunnel(_ address: String) -> Bool {
        let address = address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if address.contains(":") { return address.hasPrefix("fd7a:115c:a1e0:") }
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}

/// Presence established by an independent proof, rather than connection characteristics.
public struct HomePresence: Sendable {
    public enum Verdict: Sendable, Equatable {
        case unknown, home, away
    }

    public private(set) var verdict: Verdict = .unknown
    private let gracePeriod: TimeInterval
    private var lastProof: Date?
    private var failed = false

    public init(gracePeriod: TimeInterval) {
        precondition(gracePeriod.isFinite && gracePeriod >= 0)
        self.gracePeriod = gracePeriod
    }

    /// Records a successful home proof at the supplied time.
    public mutating func proofSucceeded(at time: Date) {
        lastProof = time
        failed = false
        verdict = .home
    }

    /// A failure retains home only until the grace period from the last successful proof expires.
    public mutating func proofFailed(at time: Date) {
        failed = true
        _ = verdict(at: time)
    }

    /// Re-evaluates the grace period after a failed proof.
    @discardableResult
    public mutating func verdict(at time: Date) -> Verdict {
        if failed {
            if let lastProof {
                let elapsed = time.timeIntervalSince(lastProof)
                if elapsed < 0 || elapsed >= gracePeriod { verdict = .away }
            } else {
                verdict = .away
            }
        }
        return verdict
    }

    /// Discards proof from the previous network immediately.
    public mutating func invalidate() {
        lastProof = nil
        failed = false
        verdict = .unknown
    }
}
