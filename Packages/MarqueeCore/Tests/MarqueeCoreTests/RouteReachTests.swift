import Foundation
import Testing
@testable import MarqueeCore

struct RouteReachTests {
    static let lan = NetworkPlaceTests.lan
    static let wan = NetworkPlaceTests.wan
    static let relay = NetworkPlaceTests.relay

    static func reach(_ place: NetworkPlace?, _ connection: PlexConnection?, media: Int? = 1_800, link: Int?) -> RouteReach {
        RouteReach.decide(place: place, connection: connection, mediaKbps: media, linkKbps: link)
    }

    @Test func aFastLinkIsNearWhereverThePlaceSaysAway() {
        let away: [(NetworkPlace?, PlexConnection)] = [
            (.away(.tunnel), Self.lan), (.away(.tunnel), Self.wan), (.unknown, Self.wan), (.unknown, Self.lan), (nil, Self.wan),
        ]
        for (place, connection) in away {
            #expect(Self.reach(place, connection, link: 130_800) == .nearByLink(kbps: 130_800))
        }
    }

    @Test func aFastLinkAtHomeStaysNear() {
        #expect(Self.reach(.home, Self.lan, link: 130_800) == .near)
        #expect(Self.reach(nil, Self.lan, link: 130_800) == .near)
    }

    @Test func aShortLinkIsRemoteWhereverThePhoneIs() {
        let short = RouteReach.remoteByLink(kbps: 15_000, needs: 20_000)
        for place in [NetworkPlace.home, .unknown, .away(.tunnel)] {
            #expect(Self.reach(place, Self.lan, link: 15_000) == short)
        }
        #expect(Self.reach(nil, Self.wan, link: 15_000) == short)
    }

    @Test func theLinkNeedsThreeTimesTheFileAndTwentyMegabits() {
        func reach(media: Int, link: Int) -> RouteReach {
            Self.reach(.away(.tunnel), Self.lan, media: media, link: link)
        }
        #expect(reach(media: 1_800, link: 20_000) == .nearByLink(kbps: 20_000))
        #expect(reach(media: 1_800, link: 19_999) == .remoteByLink(kbps: 19_999, needs: 20_000))
        #expect(reach(media: 25_000, link: 75_000) == .nearByLink(kbps: 75_000))
        #expect(reach(media: 25_000, link: 74_999) == .remoteByLink(kbps: 74_999, needs: 75_000))
        #expect(RouteReach.needs(forMediaKbps: 6_000) == 20_000)
        #expect(RouteReach.needs(forMediaKbps: 8_000) == 24_000)
    }

    @Test func thePlaceKeepsDecidingWithoutARecentReading() {
        #expect(Self.reach(.home, Self.lan, link: nil) == .near)
        #expect(Self.reach(nil, Self.lan, link: nil) == .near)
        #expect(Self.reach(.away(.tunnel), Self.lan, link: nil) == .remote)
        #expect(Self.reach(.unknown, Self.wan, link: nil) == .remote)
        #expect(Self.reach(nil, Self.wan, link: nil) == .remote)
        #expect(Self.reach(nil, nil, link: nil) == .near)
    }

    @Test func aFileOfUnknownRateCannotBeMeasuredAgainst() {
        #expect(Self.reach(.away(.tunnel), Self.lan, media: nil, link: 130_800) == .remote)
        #expect(Self.reach(.home, Self.lan, media: nil, link: 130_800) == .near)
    }

    @Test func thePlexRelayAlwaysConverts() {
        #expect(Self.reach(.away(.relay), Self.relay, link: 500_000) == .remote)
        #expect(Self.reach(nil, Self.relay, link: 500_000) == .remote)
        #expect(Self.reach(.away(.relay), Self.relay, link: nil) == .remote)
    }

    @Test func onlyTheRemoteKindsAreRemote() {
        #expect(!RouteReach.near.isRemote && !RouteReach.nearByLink(kbps: 50_000).isRemote)
        #expect(RouteReach.remote.isRemote && RouteReach.remoteByLink(kbps: 1, needs: 2).isRemote && RouteReach.remoteByServer.isRemote)
    }
}

struct LinkMemoryTests {
    static let link = LinkMemory.Link(address: URL(string: "https://192-168-5-10.abc.plex.direct:32400")!, place: .away(.tunnel))

    @Test func aRecentReadingServesTheRoute() {
        var memory = LinkMemory()
        memory.record(130_800, over: Self.link, at: 100, network: 3)

        #expect(memory.recent(over: Self.link, at: 100 + LinkMemory.maxAge, network: 3) == 130_800)
        #expect(memory.recent(over: Self.link, at: 100 + LinkMemory.maxAge + 1, network: 3) == nil)
        #expect(memory.latest(over: Self.link) == 130_800)
    }

    @Test func aReadingFromAnotherNetworkOrPlaceDoesNotServe() {
        var memory = LinkMemory()
        memory.record(130_800, over: Self.link, at: 0, network: 3)
        let home = LinkMemory.Link(address: Self.link.address, place: .home)

        #expect(memory.recent(over: Self.link, at: 10, network: 4) == nil)
        #expect(memory.recent(over: home, at: 10, network: 3) == nil)
        #expect(memory.latest(over: home) == nil)
    }

    @Test func aLinkTheFileFailedOverIsNotTrustedOnThatNetwork() {
        var memory = LinkMemory()
        memory.record(130_800, over: Self.link, at: 0, network: 3)

        memory.distrust(Self.link, network: 3)
        #expect(memory.recent(over: Self.link, at: 10, network: 3) == nil)
        memory.record(140_000, over: Self.link, at: 20, network: 3)
        #expect(memory.recent(over: Self.link, at: 21, network: 3) == nil)

        memory.record(140_000, over: Self.link, at: 30, network: 4)
        #expect(memory.recent(over: Self.link, at: 31, network: 4) == 140_000)
    }

    @Test func aNewReadingReplacesTheOldAndAnEmptyOneIsIgnored() {
        var memory = LinkMemory()
        memory.record(50_000, over: Self.link, at: 0, network: 1)
        memory.record(0, over: Self.link, at: 5, network: 1)
        #expect(memory.latest(over: Self.link) == 50_000)

        memory.record(80_000, over: Self.link, at: 9, network: 1)
        #expect(memory.latest(over: Self.link) == 80_000)
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
