import Foundation

/// A short read of the file itself, timing the link to the server, for a start with no recent reading
/// (`RouteReach`, `LinkMemory`). Readings from streams that play last only this run, 30 minutes and one network;
/// without one, the first start after each launch was decided on a guess, and at home through Tailscale the
/// server converted files the link carried at 160 Mbit/s (2026-11-20).
public enum LinkProbe {
    /// The most read: the first 4 MB of the file.
    public static let maxBytes = 4 << 20
    /// How long the read runs from its first byte at most.
    public static let window: TimeInterval = 0.5
    /// How long the server has to answer before the probe gives up and the server streams the file.
    public static let timeout: TimeInterval = 3
    /// The least that says anything of a fast link; a read cut short by the window says the link is slow.
    static let minBytes = 512 * 1024

    /// Whether to probe before a start: the file does not simply play as it is, and nothing measured the link
    /// lately (`reach` is unmeasured). Plex's relay caps bandwidth whatever it measures.
    public static func isNeeded(route: PlaybackRoute, reach: RouteReach?) -> Bool {
        route.kind != .directPlay && reach == .unmeasured
    }

    /// The link's rate in kbit/s from `bytes` received over `seconds` after the first: nil when the read stopped
    /// early with too little to judge by.
    public static func kbps(bytes: Int, seconds: TimeInterval) -> Int? {
        guard bytes > 0, seconds > 0, bytes >= minBytes || seconds >= window * 0.9 else { return nil }
        return Int(Double(bytes) * 8 / 1000 / seconds)
    }
}
