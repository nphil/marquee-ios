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
}
