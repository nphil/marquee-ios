import Foundation

/// A short read of the file itself, timing the link the remux would read it over, for a start with no recent
/// reading (`RouteReach`, `LinkMemory`). Readings come from streams that play and last only this run, 30 minutes
/// and one network, so the place decided the first start after each launch: at home with Tailscale on, the
/// phone reaches the server through the tunnel, the place says away, and the server converted files the link
/// carried at 160 Mbit/s (2026-11-20).
public enum LinkProbe {
    /// The most read: the first 4 MB of the file.
    public static let maxBytes = 4 << 20
    /// How long the read runs from its first byte at most.
    public static let window: TimeInterval = 0.5
    /// How long the server has to answer before the probe gives up and the place decides.
    public static let timeout: TimeInterval = 3
    /// The least that says anything of a fast link; a read cut short by the window says the link is slow.
    static let minBytes = 512 * 1024

    /// Whether to probe before a start: the place, with no recent reading, would send a file the phone can read to
    /// the server. Plex's relay caps bandwidth whatever it measures, and a link the phone failed to read the file
    /// over on this network stays given up on.
    public static func isNeeded(route: PlaybackRoute, place: NetworkPlace?, connection: PlexConnection?, distrusted: Bool) -> Bool {
        guard route.reasons.contains(.remoteConnection), let connection, !connection.isRelay, !distrusted else { return false }
        return place != .away(.relay)
    }

    /// The link's rate in kbit/s from `bytes` received over `seconds` after the first: nil when the read stopped
    /// early with too little to judge by.
    public static func kbps(bytes: Int, seconds: TimeInterval) -> Int? {
        guard bytes > 0, seconds > 0, bytes >= minBytes || seconds >= window * 0.9 else { return nil }
        return Int(Double(bytes) * 8 / 1000 / seconds)
    }
}
