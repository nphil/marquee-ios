import Foundation
import Testing
@testable import MarqueeCore

struct StreamKeyTests {
    /// Picking a subtitle the app draws, or one the remux already carries, plays on the running stream;
    /// only burn-in of a picture subtitle needs another.
    @Test func onlyBurnInChangesTheStream() throws {
        let mkv = try PlaybackRouteTests.file("mkv", streams: [
            Fixture.audio(2, "eng", isDefault: true),
            Fixture.subtitle(3, "eng", codec: "pgs"),
            Fixture.subtitle(4, "eng", codec: "ass"),
            Fixture.subtitle(5, "eng", external: true),
            Fixture.subtitle(6, "spa", codec: "pgs", external: true),
        ])
        func key(_ id: Int?, _ source: SubtitleDecision.Source) -> (StreamKey, PlaybackRoute) {
            let decision = id.map { PlaybackRouteTests.subtitle($0, in: mkv, source) } ?? SubtitleDecision(track: nil, source: source)
            let route = PlaybackRouteTests.route(mkv, subtitle: decision)
            return (StreamKey(route), route)
        }
        let (off, offRoute) = key(nil, .handPick)
        let (sidecar, sidecarRoute) = key(5, .handPick)
        let (embedded, embeddedRoute) = key(4, .handPick)
        #expect(offRoute.kind == .remux && offRoute.subtitle == .none)
        #expect(sidecarRoute.subtitle == .sidecar(mkv.tracks.subtitles[2]))
        #expect(embeddedRoute.subtitle == .inStream(mkv.tracks.subtitles[1]))
        #expect(off == sidecar && sidecar == embedded)

        let (burned, burnedRoute) = key(6, .handPick)
        #expect(burnedRoute.subtitle == .burnedIn(mkv.tracks.subtitles[3]))
        #expect(burned != off)
    }
}
