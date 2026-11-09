import XCTest

final class WatchedShowTests: XCTestCase {
    /// A long press on an episode in Continue Watching offers Mark Show Watched, which takes every card of
    /// that show off the row at once.
    @MainActor
    func testMarkShowWatchedFromContinueWatching() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        waitFor("continue.212", in: app)
        element("continue.212", in: app).press(forDuration: 1.2)
        let mark = app.buttons["Mark Show Watched"].firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "No Mark Show Watched in the menu")
        try snap("watched-01-continue-menu-dark")
        mark.tap()
        XCTAssertTrue(
            element("continue.212", in: app).waitForNonExistence(timeout: 5),
            "The episode is still in Continue Watching"
        )
        waitFor("continue.108", in: app)
        try snap("watched-02-continue-after-dark")
    }

    /// Mark Season Watched in the season's menu, then Mark Show Watched on the show's page; Continue
    /// Watching on Home follows.
    @MainActor
    func testMarkShowAndSeasonWatchedFromDetail() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        waitFor("continue.212", in: app)
        open(tab: "Search", title: "Search", in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No search field")
        field.tap()
        field.typeText("Caminandes")
        tap("search.result.201", in: app)
        waitFor("detail.title", in: app)

        tap("detail.seasonMore", in: app)
        let season = app.buttons["Mark Season Watched"].firstMatch
        XCTAssertTrue(season.waitForExistence(timeout: 5), "No Mark Season Watched in the menu")
        try snap("watched-03-season-menu-dark")
        season.tap()
        XCTAssertTrue(
            app.staticTexts["Season marked watched"].firstMatch.waitForExistence(timeout: 5),
            "No confirmation of the season"
        )

        let watched = element("detail.watched", in: app)
        XCTAssertTrue(watched.waitForExistence(timeout: 5), "No watched button")
        XCTAssertEqual(watched.label, "Mark Show Watched")
        watched.tap()
        let undone = NSPredicate(format: "label == %@", "Mark Show Unwatched")
        expectation(for: undone, evaluatedWith: watched)
        waitForExpectations(timeout: 5)
        try snap("watched-04-show-marked-dark")

        open(tab: "Home", title: "Home", in: app)
        XCTAssertTrue(
            element("continue.212", in: app).waitForNonExistence(timeout: 10),
            "The show's episode is still in Continue Watching"
        )
    }
}
