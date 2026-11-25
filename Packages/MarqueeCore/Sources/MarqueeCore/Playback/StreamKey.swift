import Foundation

/// What of a route the playing stream is made of. A route with the same key plays on the stream already
/// running; only a different key needs a new one.
///
/// A subtitle the app draws (a separate text file, a track the remux already lists) is not part of it:
/// picking one stopped the remux and restarted it at the playhead, and the fresh run then stalled
/// (The Office S6E1, 0.1.88). Only burn-in changes the stream.
public struct StreamKey: Equatable, Sendable {
    var kind: PlaybackRoute.Kind
    var audio: Int?
    var burnedIn: Int?
    var reencodes: Bool
    var bitrate: Int?
    var resolution: String?

    public init(_ route: PlaybackRoute) {
        kind = route.kind
        audio = route.kind == .directPlay ? nil : route.audio?.id
        reencodes = route.reencodesVideo
        bitrate = route.maxVideoBitrateKbps
        resolution = route.videoResolution
        if case .burnedIn(let track) = route.subtitle { burnedIn = track.id }
    }
}
