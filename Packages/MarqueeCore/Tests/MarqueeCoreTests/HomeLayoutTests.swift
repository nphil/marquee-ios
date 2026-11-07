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
}
