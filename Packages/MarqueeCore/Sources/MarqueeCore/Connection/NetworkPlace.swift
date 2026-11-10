import Foundation

/// Where the phone is from the server it plays from (docs/adaptive-playback.md). Plex's local flag says only
/// which address answered: away from home, a VPN that routes the home subnet makes the LAN address answer
/// through the tunnel.
public enum NetworkPlace: Sendable, Hashable, CustomStringConvertible {
    /// On the server's own network, reaching it directly.
    case home
    case away(Away)

    public enum Away: String, Sendable {
        /// Plex's relay, which caps bandwidth.
        case relay
        /// The server's public address.
        case remote
        /// A VPN tunnel such as Tailscale's.
        case tunnel
    }

    /// A host name counts as home only when Plex calls it local and a round trip is shorter than this.
    public static let homeRoundTrip: TimeInterval = 0.025

    public var isHome: Bool { self == .home }

    /// "Home", "Away (tunnel)".
    public var description: String {
        switch self {
        case .home: "Home"
        case .away(let reason): "Away (\(reason.rawValue))"
        }
    }

    /// The place of a phone that reaches the server at `connection`.
    /// - Parameters:
    ///   - onPhoneNetwork: whether the server's IP is on a network one of the phone's own interfaces is
    ///     attached to, tunnels excluded; nil when the address is a host name.
    ///   - localAddress: the phone's address the last request to the server left from.
    ///   - roundTrip: that request's round trip.
    public static func of(
        _ connection: PlexConnection, onPhoneNetwork: Bool?, localAddress: String?, roundTrip: TimeInterval?
    ) -> NetworkPlace {
        if connection.isRelay { return .away(.relay) }
        if [localAddress, connection.ipAddress].contains(where: { $0.map(isTunnel) ?? false }) { return .away(.tunnel) }
        switch onPhoneNetwork {
        case true?:
            return .home
        case false?:
            // A LAN address that answers from off the phone's networks comes through a VPN's route.
            return .away(connection.isLocal ? .tunnel : .remote)
        case nil:
            return connection.isLocal && (roundTrip ?? 0) < homeRoundTrip ? .home : .away(.remote)
        }
    }

    /// Tailscale's addresses: carrier-grade NAT space and its IPv6 prefix, fd7a:115c:a1e0::/48.
    static func isTunnel(_ address: String) -> Bool {
        let address = address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if address.contains(":") { return address.hasPrefix("fd7a:115c:a1e0:") }
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}
