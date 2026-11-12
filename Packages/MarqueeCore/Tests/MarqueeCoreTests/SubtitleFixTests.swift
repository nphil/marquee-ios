import Foundation
import Testing
@testable import MarqueeCore

struct SubtitleFixTests {
    @Test func refreshAsksTheServerToLookAgain() async throws {
        let (library, transport) = PlexLibraryTests.library { _ in PlexHTTPResponse(status: 200, body: Data()) }
        try await library.refresh("5")
        let request = try #require(await transport.requests(to: "/library/metadata/5/refresh").first)
        #expect(request.method == .put)
    }

    @Test func externalIDsComeFromTheItemsGuids() async throws {
        let (library, transport) = PlexLibraryTests.library { _ in
            container(["Metadata": [["ratingKey": "5", "Guid": [["id": "imdb://tt0133093"], ["id": "tmdb://603"]]]]])
        }
        #expect(try await library.externalIDs("5") == ["imdb://tt0133093", "tmdb://603"])
        let request = try #require(await transport.requests(to: "/library/metadata/5").first)
        #expect(request.url.query("includeGuids") == "1")
    }

    @Test func plexSearchListsTheAgentsResultsBestFirst() async throws {
        let (library, transport) = PlexLibraryTests.library { _ in
            container(["size": 3, "Stream": [
                ["id": 11, "key": "/library/streams/11", "streamType": 3, "languageCode": "nld", "title": "Alive.720p", "providerTitle": "OpenSubtitles", "score": "40"],
                ["id": 12, "streamType": 3, "languageCode": "nld", "title": "No key"],
                ["id": 13, "key": "/library/streams/13", "streamType": 3, "languageCode": "nld", "title": "Alive.1080p", "providerTitle": "Podnapisi", "score": "2301"],
            ]])
        }
        let found = try await library.searchSubtitles("5", language: "nl")
        #expect(found.map(\.key) == ["/library/streams/13", "/library/streams/11"])
        #expect(found.first?.provider == "Podnapisi" && found.first?.score == 2301 && found.first?.language == TrackLanguage(tag: "nl"))
        let search = try #require(await transport.requests(to: "/library/metadata/5/subtitles").first)
        #expect(search.url.query("language") == "nl" && search.url.query("hearingImpaired") == "0" && search.url.query("forced") == "0")

        try await library.addSubtitle("5", candidate: found[0])
        let add = try #require(await transport.requests(to: "/library/metadata/5/subtitles").last)
        #expect(add.method == .put && add.url.query("key") == "/library/streams/13")
    }

    @Test func timingStepsInTenthsWithinItsLimits() {
        var timing = SubtitleTiming()
        timing.nudge(1, canGoEarlier: false)
        timing.nudge(1, canGoEarlier: false)
        timing.nudge(1, canGoEarlier: false)
        #expect(timing.tenths == 3 && timing.magnitude == "0.3 s")

        var stream = SubtitleTiming()
        stream.nudge(-1, canGoEarlier: false)
        #expect(stream.isOriginal && !stream.canNudge(-1, canGoEarlier: false))

        var file = SubtitleTiming(seconds: -59.95)
        file.nudge(-1, canGoEarlier: true)
        #expect(file.seconds == -60 && file.magnitude == "1 min" && !file.canNudge(-1, canGoEarlier: true))
        file.fit(canGoEarlier: false)
        #expect(file.isOriginal)
        #expect(SubtitleTiming(seconds: 2).magnitude == "2 s")
    }
}
