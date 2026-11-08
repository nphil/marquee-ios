import XCTest

final class DeleteMediaTests: XCTestCase {
    /// Deleting Charge from its page closes the page and takes it off Home and out of the Movies grid,
    /// although the fake server, like a real one before its trash is emptied, still lists it.
    @MainActor
    func testDeleteFromDetailRemovesTheTitleEverywhere() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        tap("poster.102", in: app)
        waitFor("detail.title", in: app)
        tap("detail.more", in: app)
        let delete = app.buttons["Delete…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "No Delete in the More menu")
        try snap("delete-01-menu-dark")
        delete.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "No confirmation")
        try snap("delete-02-confirm-dark")
        confirm.tap()

        XCTAssertTrue(element("detail.title", in: app).waitForNonExistence(timeout: 5), "The page stayed open")
        waitFor("poster.110", in: app)
        XCTAssertFalse(element("poster.102", in: app).exists, "Charge is still on Home")
        try snap("delete-03-home-dark")
        open(tab: "Library", title: "Movies", in: app)
        waitFor("poster.103", in: app)
        XCTAssertFalse(element("poster.102", in: app).exists, "Charge is still in Movies")
    }

    /// Cosmos Laundromat is on the Watchlist too. Deleting it also takes it off that screen at once,
    /// although the fake plex.tv, like a lagging one, still lists it.
    @MainActor
    func testDeleteOfAWatchlistedTitleLeavesTheWatchlist() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        open(tab: "Watchlist", title: "Watchlist", in: app)
        waitFor("poster.62a1b2c3d4e5f60718000104", in: app)
        waitFor("poster.62a1b2c3d4e5f60718000105", in: app)

        open(tab: "Library", title: "Movies", in: app)
        tap("poster.104", in: app)
        waitFor("detail.title", in: app)
        tap("detail.more", in: app)
        let delete = app.buttons["Delete…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "No Delete in the More menu")
        delete.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "No confirmation")
        confirm.tap()

        XCTAssertTrue(element("detail.title", in: app).waitForNonExistence(timeout: 5), "The page stayed open")
        XCTAssertFalse(element("poster.104", in: app).exists, "Cosmos Laundromat is still in Movies")

        open(tab: "Watchlist", title: "Watchlist", in: app)
        waitFor("poster.62a1b2c3d4e5f60718000105", in: app)
        XCTAssertTrue(
            element("poster.62a1b2c3d4e5f60718000104", in: app).waitForNonExistence(timeout: 5),
            "Cosmos Laundromat is still on the Watchlist"
        )
        try snap("delete-04-watchlist-dark")
    }
}
