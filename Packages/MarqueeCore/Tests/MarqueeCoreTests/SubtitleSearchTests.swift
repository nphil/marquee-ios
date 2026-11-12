import Foundation
import Testing
@testable import MarqueeCore

struct SubtitleSearchTests {
    static let lookup = BazarrLookup(title: "Alive", year: 2020, externalIDs: ["imdb://tt10620868"], file: nil)

    /// A Bazarr that knows the movie and offers `offers`, after `delay`.
    static func bazarr(_ offers: [[String: Any]], delay: Duration? = nil) -> BazarrClient {
        let body = try! JSONSerialization.data(withJSONObject: ["data": offers])
        return BazarrClient(config: BazarrTests.config, transport: FakeTransport { request, _ in
            switch request.url.path {
            case "/bazarr/api/system/searches": return json([["title": "Alive", "radarrId": 3]])
            case "/bazarr/api/movies": return json(["data": [["radarrId": 3, "title": "Alive", "year": 2020, "imdbId": "tt10620868"]]])
            default:
                if request.method == .post { return PlexHTTPResponse(status: 204, body: Data()) }
                if let delay { try await Task.sleep(for: delay) }
                return PlexHTTPResponse(status: 200, body: body)
            }
        })
    }

    static func offer(_ provider: String, _ score: Double, hi: Bool = false, forced: Bool = false, language: String = "en") -> [String: Any] {
        [
            "provider": provider, "subtitle": "\(provider)-\(score)", "language": language, "score": score,
            "hearing_impaired": hi ? "True" : "False", "forced": forced ? "True" : "False", "original_format": false,
            "release_info": ["Alive.2020.1080p.\(provider)"],
        ]
    }

    /// A server whose agents offer one English file and add it when asked.
    static func plex() -> (PlexLibrary, FakeTransport) {
        PlexLibraryTests.library { request in
            guard request.method == .get else { return PlexHTTPResponse(status: 200, body: Data()) }
            return container(["Stream": [[
                "id": 40, "key": "/library/streams/40", "streamType": 3, "languageCode": "eng",
                "title": "Alive.2020.1080p", "providerTitle": "OpenSubtitles", "score": "90",
            ]]])
        }
    }

    func run(_ bazarr: BazarrClient?, library: PlexLibrary, budget: Duration = .seconds(20)) async -> (SubtitleSearch.Outcome, [SubtitleSearch.Step]) {
        let search = SubtitleSearch(bazarr: bazarr, library: library, ratingKey: "5", language: .english, bazarrBudget: budget)
        let steps = Steps()
        let outcome = await search.run(lookup: { Self.lookup }, target: nil, tracks: nil, tried: SubtitleSearch.Tried()) { await steps.add($0) }
        return (outcome, await steps.all)
    }

    @Test func bazarrGoesFirstAndItsFileEndsTheSearch() async throws {
        let (library, plex) = Self.plex()
        let bazarr = Self.bazarr([Self.offer("opensubtitlescom", 95, hi: true), Self.offer("podnapisi", 90)])

        let (outcome, steps) = await run(bazarr, library: library)

        #expect(steps == [.searching(.bazarr), .downloading(.bazarr)])
        #expect(outcome.added?.source == .bazarr && outcome.bazarrMiss == nil && outcome.target == .movie(radarrID: 3))
        #expect(await plex.requests.allSatisfy { $0.method == .get })
    }

    @Test func plexStepsInWhenBazarrFails() async throws {
        let cases: [(SubtitleSearch.BazarrMiss, BazarrClient, Duration)] = [
            (.unreachable, BazarrClient(config: BazarrTests.config, transport: FakeTransport { _, _ in throw NetworkFailure.offline }), .seconds(20)),
            (.slow, Self.bazarr([Self.offer("podnapisi", 90)], delay: .seconds(5)), .milliseconds(50)),
            (.nothing, Self.bazarr([Self.offer("whisperai", 100), Self.offer("subdl", 90, language: "fr")]), .seconds(20)),
        ]
        for (miss, bazarr, budget) in cases {
            let (library, plex) = Self.plex()

            let (outcome, steps) = await run(bazarr, library: library, budget: budget)

            #expect(outcome.bazarrMiss == miss && outcome.added?.source == .plex && !outcome.plexFailed)
            #expect(steps == [.searching(.bazarr), .searching(.plex, after: miss), .downloading(.plex)])
            let add = try #require(await plex.requests(to: "/library/metadata/5/subtitles").last)
            #expect(add.method == .put && add.url.query("key") == "/library/streams/40")
        }
    }

    @Test func bazarrsPickIsTheBestRegularFileNearTheTop() {
        func pick(_ offers: [[String: Any]], tried: SubtitleSearch.Tried = SubtitleSearch.Tried()) -> String? {
            SubtitleSearch.pick(offers.map(Self.subtitle), in: .english, skipping: tried)?.provider
        }

        #expect(pick([Self.offer("opensubtitlescom", 95, hi: true), Self.offer("podnapisi", 90)]) == "podnapisi")
        #expect(pick([Self.offer("opensubtitlescom", 95, hi: true), Self.offer("podnapisi", 80)]) == "opensubtitlescom")
        #expect(pick([Self.offer("whisperai", 100), Self.offer("gestdown", 99, forced: true), Self.offer("subdl", 70)]) == "subdl")

        var tried = SubtitleSearch.Tried()
        tried.insert(.bazarr(Self.subtitle(Self.offer("podnapisi", 90))))
        #expect(pick([Self.offer("opensubtitlescom", 95, hi: true), Self.offer("podnapisi", 90)], tried: tried) == "opensubtitlescom")
    }

    static func subtitle(_ offer: [String: Any]) -> BazarrSubtitle {
        BazarrSubtitle(
            provider: offer["provider"] as! String, subtitle: offer["subtitle"] as! String, language: offer["language"] as! String,
            isHearingImpaired: offer["hearing_impaired"] as? String == "True", isForced: offer["forced"] as? String == "True",
            score: offer["score"] as! Double, releases: offer["release_info"] as! [String], usesOriginalFormat: false
        )
    }
}

private actor Steps {
    private(set) var all: [SubtitleSearch.Step] = []

    func add(_ step: SubtitleSearch.Step) {
        all.append(step)
    }
}
