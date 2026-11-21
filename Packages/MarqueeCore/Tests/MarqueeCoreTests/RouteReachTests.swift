import Foundation
import Testing
@testable import MarqueeCore

struct RouteReachTests {
    static let lan = PlexConnection(uri: URL(string: "https://192-168-5-10.abc.plex.direct:32400")!, isLocal: true)
    static let wan = PlexConnection(uri: URL(string: "https://81-2-3-4.abc.plex.direct:32400")!, isLocal: false)
    static let relay = PlexConnection(uri: URL(string: "https://5-6-7-8.abc.plex.direct:8443")!, isLocal: false, isRelay: true)

    static func reach(_ connection: PlexConnection?, media: Int? = 1_800, link: Int?) -> RouteReach {
        RouteReach.decide(connection: connection, mediaKbps: media, linkKbps: link)
    }

    /// Isabel's phone at home reached the server through Tailscale at 160 Mbit/s: the link decides, whatever
    /// the address, and a fast 5G link counts the same.
    @Test func theMeasuredLinkDecidesWhateverTheAddress() {
        for connection in [Self.lan, Self.wan] {
            #expect(Self.reach(connection, link: 160_000) == .nearByLink(kbps: 160_000))
            #expect(Self.reach(connection, link: 15_000) == .remoteByLink(kbps: 15_000, needs: 20_000))
        }
    }

    @Test func theLinkNeedsThreeTimesTheFileAndTwentyMegabits() {
        #expect(Self.reach(Self.lan, media: 1_800, link: 20_000) == .nearByLink(kbps: 20_000))
        #expect(Self.reach(Self.lan, media: 1_800, link: 19_999) == .remoteByLink(kbps: 19_999, needs: 20_000))
        #expect(Self.reach(Self.lan, media: 25_000, link: 75_000) == .nearByLink(kbps: 75_000))
        #expect(Self.reach(Self.lan, media: 25_000, link: 74_999) == .remoteByLink(kbps: 74_999, needs: 75_000))
        // A file of unknown rate needs the floor.
        #expect(Self.reach(Self.lan, media: nil, link: 20_000) == .nearByLink(kbps: 20_000))
    }

    @Test func withoutAReadingTheLinkIsUnmeasuredAndTheRelayAlwaysConverts() {
        #expect(Self.reach(Self.lan, link: nil) == .unmeasured)
        #expect(Self.reach(nil, link: nil) == .unmeasured)
        #expect(Self.reach(Self.relay, link: 500_000) == .relay)
        #expect(Self.reach(Self.relay, link: nil) == .relay)
    }
}

struct LinkMemoryTests {
    static let address = URL(string: "https://192-168-5-10.abc.plex.direct:32400")!

    @Test func aReadingServesOnItsNetworkForHalfAnHour() {
        var memory = LinkMemory()
        memory.record(130_800, to: Self.address, at: 100, network: 3)

        #expect(memory.recent(to: Self.address, at: 100 + LinkMemory.maxAge, network: 3) == 130_800)
        #expect(memory.recent(to: Self.address, at: 100 + LinkMemory.maxAge + 1, network: 3) == nil)
        #expect(memory.recent(to: Self.address, at: 110, network: 4) == nil)
    }

    @Test func aLinkTheFileFailedOverIsNotTrustedOnThatNetwork() {
        var memory = LinkMemory()
        memory.record(130_800, to: Self.address, at: 0, network: 3)

        memory.distrust(Self.address, network: 3)
        #expect(memory.isDistrusted(Self.address, network: 3))
        #expect(memory.recent(to: Self.address, at: 10, network: 3) == nil)
        memory.record(140_000, to: Self.address, at: 20, network: 3)
        #expect(memory.recent(to: Self.address, at: 21, network: 3) == nil)

        memory.record(140_000, to: Self.address, at: 30, network: 4)
        #expect(!memory.isDistrusted(Self.address, network: 4))
        #expect(memory.recent(to: Self.address, at: 31, network: 4) == 140_000)
    }
}

struct ServerLimitTests {
    static func media(video: Int?, whole: Int?) throws -> PlexMedia {
        var stream: [String: Any] = ["id": 1, "streamType": 1, "codec": "hevc"]
        if let video { stream["bitrate"] = video }
        var object: [String: Any] = ["id": 1, "container": "mkv", "Part": [["id": 7, "container": "mkv", "Stream": [stream]]]]
        if let whole { object["bitrate"] = whole }
        return try decode(PlexMedia.self, object)
    }

    @Test func aPictureMadeBelowNineTenthsOfTheFilesRateIsHeldBack() throws {
        let file = try Self.media(video: 1_800, whole: 2_000)

        #expect(!ServerLimit.holdsBack(output: try Self.media(video: 1_620, whole: nil), source: file))
        #expect(ServerLimit.holdsBack(output: try Self.media(video: 1_619, whole: nil), source: file))
        #expect(ServerLimit.holdsBack(output: try Self.media(video: 1_000, whole: 1_100), source: file))
    }

    @Test func aReEncodeAboveTheFilesRateIsNotALimit() throws {
        // 2026-11-19: the server made 7.5 Mbit/s of a 1.8 Mbit/s HEVC file, from the 8 Mbit/s the app asked.
        let file = try Self.media(video: 1_800, whole: 2_000)

        #expect(!ServerLimit.holdsBack(output: try Self.media(video: 7_500, whole: 7_800), source: file))
        #expect(!ServerLimit.holdsBack(output: try Self.media(video: 1_800, whole: 1_900), source: file))
    }

    @Test func theWholeMediasRateStandsInWhenAVideoRateIsMissing() throws {
        let file = try Self.media(video: nil, whole: 10_000)

        #expect(ServerLimit.holdsBack(output: try Self.media(video: nil, whole: 4_000), source: file))
        #expect(ServerLimit.holdsBack(output: try Self.media(video: 3_000, whole: 4_000), source: file))
        #expect(!ServerLimit.holdsBack(output: try Self.media(video: nil, whole: 9_500), source: file))
    }

    @Test func missingRatesAreNotALimit() throws {
        let file = try Self.media(video: 8_000, whole: 8_500)
        let unknown = try Self.media(video: nil, whole: nil)

        #expect(!ServerLimit.holdsBack(output: unknown, source: file))
        #expect(!ServerLimit.holdsBack(output: file, source: unknown))
        #expect(!ServerLimit.holdsBack(output: try Self.media(video: 100, whole: nil), source: try Self.media(video: nil, whole: 8_500)))
    }
}
