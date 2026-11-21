import Foundation

/// How near the server is for the route (docs/adaptive-playback.md): whether the phone may read a file that
/// needs the remux from the server itself, or the server packages it. Direct play does not depend on it.
///
/// The measured link alone decides, wherever the phone is. Where it was guessed from the address and the
/// tunnel, a phone at home that reached its server through Tailscale counted as away, and the server
/// converted files the link carried at 160 Mbit/s (2026-11-20); a fast 5G link carries a file as well as
/// the LAN. Plex's relay, which caps bandwidth, always converts.
public enum RouteReach: Sendable, Hashable {
    /// The link carries the file with room to spare: it measured `kbps`.
    case nearByLink(kbps: Int)
    /// No recent reading of the link: the start measures it (`LinkProbe`), and streams from the server
    /// while it cannot.
    case unmeasured
    /// Plex's relay.
    case relay
    /// The link measured `kbps`, short of the `needs` the phone wants for reading the file.
    case remoteByLink(kbps: Int, needs: Int)
    /// The server holds the stream below the original (`ServerLimit`); its decision wins over the link.
    case remoteByServer

    /// The link has to carry the file this many times over, and at least `floorKbps`: the phone reads the
    /// file in requests of its own, with the player's buffer to fill beside them.
    public static let headroom = 3
    public static let floorKbps = 20_000

    /// The link rate, in kbit/s, that counts as fast for a file of `mediaKbps`; the floor for a file whose
    /// rate is unknown.
    public static func needs(forMediaKbps mediaKbps: Int?) -> Int {
        max(floorKbps, (mediaKbps ?? 0) * headroom)
    }

    /// - Parameters:
    ///   - connection: the address the server is reached at.
    ///   - mediaKbps: the file's bitrate.
    ///   - linkKbps: a recent measurement of the link to the server (`LinkMemory.recent`), if any.
    public static func decide(connection: PlexConnection?, mediaKbps: Int?, linkKbps: Int?) -> RouteReach {
        if connection?.isRelay == true { return .relay }
        guard let linkKbps, linkKbps > 0 else { return .unmeasured }
        let needs = needs(forMediaKbps: mediaKbps.flatMap { $0 > 0 ? $0 : nil })
        return linkKbps >= needs ? .nearByLink(kbps: linkKbps) : .remoteByLink(kbps: linkKbps, needs: needs)
    }
}

/// The server's own limits win over the measured link. Plex can hold remote streams to a bitrate (in its
/// settings or the user's), and a file the phone reads itself never meets that limit. Before the phone reads
/// the original over a link that only the measurement calls near, the server is asked for the video as it is
/// (`PlexLibrary.transcodeDecision`); a picture it would make at under nine tenths of the file's rate says it
/// holds the stream down, and the stream then comes from the server.
public enum ServerLimit {
    /// - Parameters:
    ///   - output: what the server's decision says it would make.
    ///   - source: the file.
    public static func holdsBack(output: PlexMedia, source: PlexMedia) -> Bool {
        // The video's own rates when both are known, else the whole media's.
        let rates: (made: Int, original: Int)?
        if let made = output.parts.first?.videoStream?.bitrate, let original = source.parts.first?.videoStream?.bitrate {
            rates = (made, original)
        } else if let made = output.bitrate, let original = source.bitrate {
            rates = (made, original)
        } else {
            rates = nil
        }
        guard let rates, rates.original > 0 else { return false }
        return rates.made * 10 < rates.original * 9
    }
}
