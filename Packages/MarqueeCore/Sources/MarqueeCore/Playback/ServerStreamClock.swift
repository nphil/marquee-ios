import Foundation

/// Where a server stream's item time stands in the title. AVPlayer times a Plex conversion from the first
/// segment it loads, placed where the playlist lists it, but Plex fills a segment from the source's keyframe
/// nearest its listed start. A conversion begun part-way is first loaded at that segment, so its clock runs
/// off by the gap: asked to start at 208.7 s, an episode's segment listed at 200 s began at 198.198 s, and its
/// subtitles showed 1.8 s early (PMS 1.43.5, 2026-11-20). The first frame's timestamp says where the segment
/// truly begins.
public enum ServerStreamClock {
    /// Plex writes the title's time plus 10 s into a conversion's timestamps (`copyts`): a conversion from the
    /// start began at 10.042 for a file whose first frame is at 0.042, copied or re-encoded, and the one begun
    /// at 208.7 s, whose session started at 198.198 s, began at 208.198 (PMS 1.43.5).
    static let timestampBase: Double = 10

    /// The title time of item time 0, for a stream whose segment listed at `segmentStart` (item time) begins
    /// with a frame stamped `firstVideoTime`.
    public static func origin(segmentStart: Double, firstVideoTime: Double) -> Double {
        firstVideoTime - timestampBase - segmentStart
    }

    /// The media playlist of the conversion named `session`, beside its `start.m3u8`. Asking for the start
    /// playlist again would begin another conversion.
    static func playlistURL(master: URL, session: String) -> URL? {
        URL(string: "session/\(session)/base/index.m3u8", relativeTo: master)?.absoluteURL
    }

    /// How much of a segment holds its first frame's timestamp: the first 64 KB did for a 7.4 MB segment.
    static let headBytes = 65_536
}

extension PlexLibrary {
    /// The title time of item time 0 for the conversion `session` (its `start.m3u8` at `master`), which the
    /// player starts at item time `start`. Nil when the segment there holds no frame yet; throws when a read
    /// fails.
    public func serverStreamOrigin(master: URL, session: String, startingAt start: Double) async throws -> Double? {
        guard let playlistURL = ServerStreamClock.playlistURL(master: master, session: session) else { return nil }
        let playlist = try await http.send(PlexRequest(url: playlistURL))
        guard let segments = HLSPlaylist.segments(in: String(decoding: playlist.body, as: UTF8.self)),
              let index = HLSPlaylist.next(after: start, in: segments),
              let segmentURL = URL(string: segments[index].uri, relativeTo: playlistURL)?.absoluteURL
        else { return nil }
        let head = try await http.send(PlexRequest(url: segmentURL, headers: ["Range": "bytes=0-\(ServerStreamClock.headBytes - 1)"]))
        guard let first = TransportStream.firstVideoTime(in: head.body) else { return nil }
        return ServerStreamClock.origin(segmentStart: segments[index].start, firstVideoTime: first)
    }
}
