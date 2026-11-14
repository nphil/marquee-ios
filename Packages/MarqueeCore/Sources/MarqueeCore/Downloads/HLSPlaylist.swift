import Foundation

/// The parts of a server transcode's HLS playlists a streamed download needs. Plex's media playlist
/// lists every segment of the title from its start, even for a session started at an offset
/// (PMS 1.43.5, 2026-11).
public enum HLSPlaylist {
    public struct Segment: Hashable, Sendable {
        /// As the playlist writes it, relative to the playlist.
        public var uri: String
        /// Seconds from the title's start.
        public var start: Double
        public var duration: Double

        public var end: Double { start + duration }

        public init(uri: String, start: Double, duration: Double) {
            self.uri = uri
            self.start = start
            self.duration = duration
        }
    }

    /// The first variant of a master playlist; nil for anything else.
    public static func variant(in text: String) -> String? {
        var expectsURI = false
        for line in lines(text) {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                expectsURI = true
            } else if expectsURI, !line.hasPrefix("#") {
                return line
            }
        }
        return nil
    }

    /// A media playlist's segments in order; nil when it lists none.
    public static func segments(in text: String) -> [Segment]? {
        var segments: [Segment] = []
        var start = 0.0
        var duration: Double?
        for line in lines(text) {
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
                duration = Double(value.trimmingCharacters(in: .whitespaces))
            } else if !line.hasPrefix("#"), let length = duration {
                segments.append(Segment(uri: line, start: start, duration: length))
                start += length
                duration = nil
            }
        }
        return segments.isEmpty ? nil : segments
    }

    /// The segment to fetch after `saved` seconds: the one that holds that moment, so a new session's
    /// segments, cut at other times than the last one's, leave no gap. Nil once all are saved.
    public static func next(after saved: Double, in segments: [Segment]) -> Int? {
        // A hundredth of a second absorbs the rounding of the playlist's durations.
        segments.firstIndex { $0.end > saved + 0.01 }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
