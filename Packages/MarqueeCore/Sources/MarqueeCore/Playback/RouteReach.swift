import Foundation

/// How near the server is for the route (docs/adaptive-playback.md): whether the phone may read a file that
/// needs the remux from the server itself, or the server packages it. Direct play does not depend on it.
///
/// The measured link decides, since a tunnel, a VPN or a public address can carry as much as the LAN and a
/// weak Wi-Fi as little as the internet. The place (`NetworkPlace`) decides only while the link has not
/// been measured lately. Plex's relay, which caps bandwidth, always converts.
public enum RouteReach: Sendable, Hashable {
    /// Near by the place, or by nothing measured that says otherwise.
    case near
    /// Away by the place, near by the link: it carries the file with room to spare.
    case nearByLink(kbps: Int)
    /// Away by the place or the relay, with no recent measurement to say otherwise.
    case remote
    /// Away by the link: it measured `kbps`, short of the `needs` the phone wants for reading the file.
    case remoteByLink(kbps: Int, needs: Int)
    /// The server holds remote streams below the original (`ServerLimit`); its decision wins over the link.
    case remoteByServer

    /// The link has to carry the file this many times over, and at least `floorKbps`: the phone reads the
    /// file in requests of its own, with the player's buffer to fill beside them.
    public static let headroom = 3
    public static let floorKbps = 20_000

    /// The link rate, in kbit/s, that counts as fast for a file of `mediaKbps`.
    public static func needs(forMediaKbps mediaKbps: Int) -> Int {
        max(floorKbps, mediaKbps * headroom)
    }

    /// A file that needs the remux streams from the server.
    public var isRemote: Bool {
        switch self {
        case .near, .nearByLink: false
        case .remote, .remoteByLink, .remoteByServer: true
        }
    }

    /// - Parameters:
    ///   - place: where the phone is from the server, if known.
    ///   - connection: the address the server is reached at.
    ///   - mediaKbps: the file's bitrate.
    ///   - linkKbps: a recent measurement of the link to the server (`LinkMemory.recent`), if any.
    public static func decide(place: NetworkPlace?, connection: PlexConnection?, mediaKbps: Int?, linkKbps: Int?) -> RouteReach {
        // Plex calls a LAN address reached through a VPN local; the place knows better.
        let awayByPlace = place.map { !$0.isHome } ?? connection.map { !$0.isLocal } ?? false
        if place == .away(.relay) || connection?.isRelay == true { return .remote }
        guard let mediaKbps, mediaKbps > 0, let linkKbps, linkKbps > 0 else { return awayByPlace ? .remote : .near }
        let needs = needs(forMediaKbps: mediaKbps)
        guard linkKbps >= needs else { return .remoteByLink(kbps: linkKbps, needs: needs) }
        return awayByPlace ? .nearByLink(kbps: linkKbps) : .near
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
