import Foundation

/// What this run measured of the link to each server address (`RouteReach`, `LinkProbe`). A reading serves the
/// route and Auto's start only while recent and on the network the phone is on now, which tells a tunnel, Wi-Fi
/// and cellular apart; none serves a link the phone failed to read a file over on that network.
public struct LinkMemory: Sendable {
    /// How long a reading serves, in seconds: long enough for the next start of the evening, short enough that
    /// a changed link is measured again.
    public static let maxAge: TimeInterval = 30 * 60

    private struct Reading {
        var kbps: Int
        var at: TimeInterval
        var network: Int
    }

    private var readings: [URL: Reading] = [:]
    private var distrusted: [URL: Int] = [:]

    public init() {}

    /// - Parameters:
    ///   - address: the server address the link reaches.
    ///   - now: a monotonic time, in seconds.
    ///   - network: a count that changes with each change of the phone's network.
    public mutating func record(_ kbps: Int, to address: URL, at now: TimeInterval, network: Int) {
        guard kbps > 0 else { return }
        readings[address] = Reading(kbps: kbps, at: now, network: network)
    }

    /// The reading that serves: no older than `maxAge`, taken on this network, and not distrusted.
    public func recent(to address: URL, at now: TimeInterval, network: Int) -> Int? {
        guard let reading = readings[address], reading.network == network, distrusted[address] != network,
              now - reading.at <= Self.maxAge else { return nil }
        return reading.kbps
    }

    /// The phone failed to read the file over this link: its readings serve no more on this network.
    public mutating func distrust(_ address: URL, network: Int) {
        distrusted[address] = network
    }

    /// Whether the phone failed to read a file over this link on this network.
    public func isDistrusted(_ address: URL, network: Int) -> Bool {
        distrusted[address] == network
    }
}
