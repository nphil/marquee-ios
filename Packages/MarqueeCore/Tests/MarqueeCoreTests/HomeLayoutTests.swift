import Foundation
import Testing
@testable import MarqueeCore

struct HomeLayoutTests {
    private let movies = PlexLibrarySection(key: "1", title: "Movies", type: .movie, uuid: "lib-movies")

    private func hub(_ identifier: String) throws -> PlexHub {
        try decode(PlexHub.self, ["hubIdentifier": identifier, "title": identifier])
    }

    private func rows() throws -> [HomeRow] {
        [
            HomeRow(hub: try hub("home.continue")),
            HomeRow(hub: try hub("home.movies.recent")),
            HomeRow(hub: try hub("home.movies.recent")),
            HomeRow(hub: try hub("movie.toprated.1"), library: movies),
        ]
    }

    @Test func defaultShowsHomeHubsInServerOrderAndHidesLibraryHubs() throws {
        let arranged = HomeLayout().arrange(try rows())

        #expect(arranged.map(\.id) == ["home.continue", "home.movies.recent", "lib-movies/movie.toprated.1"])
        #expect(arranged.map(\.shown) == [true, true, false])
    }

    @Test func placedRowsLeadAndNewHubsFollowWithTheirDefault() throws {
        let layout = HomeLayout(placements: [
            .init(id: "lib-movies/movie.toprated.1", shown: true, library: "lib-movies"),
            .init(id: "home.continue", shown: false),
        ])

        let arranged = layout.arrange(try rows())

        #expect(arranged.map(\.id) == ["lib-movies/movie.toprated.1", "home.continue", "home.movies.recent"])
        #expect(arranged.map(\.shown) == [true, false, true])
        #expect(layout.shownLibraries == ["lib-movies"])
    }

    @Test func savingKeepsAnAbsentRowAfterTheRowItFollowed() throws {
        var layout = HomeLayout(placements: [
            .init(id: "home.continue", shown: true),
            .init(id: "home.ondeck", shown: true),
            .init(id: "home.movies.recent", shown: true),
        ])
        var arranged = layout.arrange(try rows())
        arranged.swapAt(0, 1)
        arranged[2].shown = true

        layout.save(arranged)

        #expect(layout.placements.map(\.id) == [
            "home.movies.recent", "home.continue", "home.ondeck", "lib-movies/movie.toprated.1",
        ])
        #expect(layout.shownLibraries == ["lib-movies"])
    }

    @Test func rotatingHubsKeepOneIDForEveryGenrePersonAndAccount() {
        // The owner and a Home profile get a different genre or person in the same row.
        #expect(HomeLayout.stableID("movie.genre.1.3718") == "movie.genre.1")
        #expect(HomeLayout.stableID("movie.genre.1.6") == "movie.genre.1")
        #expect(HomeLayout.stableID("movie.by.actor.or.director.1.39036") == "movie.by.actor.or.director.1")
        #expect(HomeLayout.stableID("lib-movies/movie.genre.1.32") == "lib-movies/movie.genre.1")
        // Ids that already name one hub stay as the server sends them.
        for id in ["home.continue", "home.ondeck", "movie.recentlyadded.1", "tv.toprated.2", "custom.collection.1.18315.18315"] {
            #expect(HomeLayout.stableID(id) == id)
        }
    }

    @Test func aHiddenGenreRowStaysHiddenWhenTheServerPicksAnotherGenre() throws {
        var layout = HomeLayout()
        var arranged = layout.arrange([HomeRow(hub: try hub("home.continue")), HomeRow(hub: try hub("movie.genre.1.3718"))])
        arranged[1].shown = false
        layout.save(arranged)

        let later = layout.arrange([HomeRow(hub: try hub("home.continue")), HomeRow(hub: try hub("movie.genre.1.6"))])

        #expect(later.map(\.shown) == [true, false])
    }

    @Test func aLayoutSavedByAnOlderVersionStillHidesItsRows() throws {
        // No `library` or `shown` keys, a raw rotating id, a repeat and an entry that is not a placement.
        let json = Data("""
        {"placements":[{"id":"movie.genre.1.3718","shown":false},{"id":"home.ondeck"},7,\
        {"id":"home.continue","shown":true,"future":1},{"id":"movie.genre.1.6","shown":true}]}
        """.utf8)

        let layout = try JSONDecoder().decode(HomeLayout.self, from: json)

        #expect(layout.placements.map(\.id) == ["movie.genre.1", "home.ondeck", "home.continue"])
        #expect(layout.placements.map(\.shown) == [false, true, true])
        let arranged = layout.arrange([HomeRow(hub: try hub("home.continue")), HomeRow(hub: try hub("movie.genre.1.32"))])
        #expect(arranged.map(\.shown) == [false, true])
    }

    @Test func hidingRowsOfTheOwnersHomeSurvivesAnEncodeAndDecode() throws {
        let owner = [
            "home.continue", "home.ondeck", "movie.recentlyadded.1", "movie.genre.1.3718", "custom.collection.1.18315.18315",
            "custom.collection.1.18304.18304", "custom.collection.2.18346.18346", "tv.recentlyadded.2", "home.playlists",
        ]
        var layout = HomeLayout()
        var arranged = layout.arrange(try owner.map { HomeRow(hub: try hub($0)) })
        for index in [1, 3, 5] { arranged[index].shown = false }
        layout.save(arranged)

        let reloaded = try JSONDecoder().decode(HomeLayout.self, from: JSONEncoder().encode(layout))
        let shown = reloaded.arrange(try owner.map { HomeRow(hub: try hub($0)) }).filter(\.shown).map(\.id)

        #expect(shown.count == owner.count - 3)
        #expect(!shown.contains("home.ondeck") && !shown.contains("movie.genre.1") && !shown.contains("custom.collection.1.18304.18304"))
    }
}
