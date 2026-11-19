import Foundation

/// What this run's streams measured of each link to a server (`RouteReach`). Auto's start reads the last
/// reading of a link whatever its age. The route reads only a recent one from the network the phone is on
/// now, and none for a link the phone failed to read the file over on that network.
public struct LinkMemory: Sendable {
    /// A link is an address reached from a place: a tunnel that routes the home network reaches the same
    /// LAN address at another speed.
    public struct Link: Hashable, Sendable {
        public var address: URL
        public var place: NetworkPlace

        public init(address: URL, place: NetworkPlace) {
            self.address = address
            self.place = place
        }
    }

    /// How long a reading serves the route, in seconds: long enough for the next start of the evening,
    /// short enough that a changed link is measured again.
    public static let maxAge: TimeInterval = 30 * 60

    private struct Reading {
        var kbps: Int
        var at: TimeInterval
        var network: Int
    }

    private var readings: [Link: Reading] = [:]
    private var distrusted: [Link: Int] = [:]

    public init() {}

    /// - Parameters:
    ///   - now: a monotonic time, in seconds.
    ///   - network: a count that changes with each change of the phone's network.
    public mutating func record(_ kbps: Int, over link: Link, at now: TimeInterval, network: Int) {
        guard kbps > 0 else { return }
        readings[link] = Reading(kbps: kbps, at: now, network: network)
    }

    /// The last reading of the link, however old.
    public func latest(over link: Link) -> Int? {
        readings[link]?.kbps
    }

    /// The reading the route may use: no older than `maxAge`, taken on this network, and not distrusted.
    public func recent(over link: Link, at now: TimeInterval, network: Int) -> Int? {
        guard let reading = readings[link], reading.network == network, distrusted[link] != network,
              now - reading.at <= Self.maxAge else { return nil }
        return reading.kbps
    }

    /// The phone failed to read the file over this link: the route ignores its readings on this network.
    public mutating func distrust(_ link: Link, network: Int) {
        distrusted[link] = network
    }
}
