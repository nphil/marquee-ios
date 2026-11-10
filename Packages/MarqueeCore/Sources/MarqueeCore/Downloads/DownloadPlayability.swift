import Foundation

/// Whether the phone can play a downloaded original on its own. Offline there is no server to
/// re-encode, so a file only the server could play fails at the first Play, long after the download.
public enum DownloadPlayability {
    /// A short sentence for an Original download of `media` the phone cannot decode itself, naming a
    /// converted quality as the way out; nil when it plays (directly or through the on-device remux).
    public static func refusal(media: PlexMedia, part: PlexPart, capabilities: DeviceCapabilities) -> String? {
        let tracks = MediaTracks(part: part)
        let route = PlaybackRouteDecider.decide(
            media: media, part: part, tracks: tracks, audio: tracks.audio.first,
            subtitle: SubtitleDecision(track: nil, source: .setting), capabilities: capabilities
        )
        let undecodable = route.reasons.first {
            switch $0 {
            case .videoCodec, .videoFormat, .dolbyVision: true
            default: false
            }
        }
        guard route.kind == .serverTranscode, let undecodable else { return nil }
        return "This iPhone can't play \(undecodable) from the original file. Choose a converted quality."
    }
}
