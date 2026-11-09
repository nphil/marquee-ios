import XCTest

/// Home Rows against the fake Plex: the row menu on Home, the editor in a sheet over Home and pushed
/// from Settings, a Home row switched off, a library row switched on, a row hidden from its menu and
/// the default restored.
final class HomeRowsScreenshotTests: XCTestCase {
    @MainActor
    func testHomeRowsRosePine() throws {
        try homeRowsFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testHomeRowsDawn() throws {
        try homeRowsFlow(mode: "light", suffix: "dawn")
    }
}

/// The same with Increase Contrast on and the text at accessibility size 2; CI runs this class in its
/// own pass.
final class HomeRowsAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testHomeRows() throws {
        try homeRowsFlow(mode: "light", suffix: "ax-dawn")
    }
}

extension XCTestCase {
    @MainActor
    func homeRowsFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        let topRated = "homeRows.fake-movies/movie.toprated.1"

        reveal("shelf.Recently Added Movies", in: app).press(forDuration: 1)
        let edit = app.buttons["Edit Home"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "No Edit Home in the row menu")
        XCTAssertTrue(app.buttons["Hide This Row"].exists, "No Hide This Row in the row menu")
        try snap("home-rows-01-menu-\(suffix)")
        edit.tap()
        waitForBar("Home Rows", in: app)
        waitFor("homeRows.home.continue", in: app)
        try snap("home-rows-02-sheet-\(suffix)")

        // Home above the half-height sheet loses the row at once. The sheet's list scrolls without
        // growing the sheet.
        let list = app.collectionViews.firstMatch
        for id in ["homeRows.home.movies.recent", topRated] {
            let row = element(id, in: app)
            for _ in 0..<8 where !(row.exists && row.isHittable) {
                list.swipeUp(velocity: .slow)
            }
            flip(id, in: app)
        }
        try snap("home-rows-03-edited-\(suffix)")

        tap("homeRows.done", in: app)
        waitForBar("Home", in: app)
        XCTAssertFalse(element("shelf.Recently Added Movies", in: app).exists, "The switched-off row is still on Home")
        XCTAssertTrue(reveal("shelf.Top Rated in Movies", in: app).exists)
        try snap("home-rows-04-home-\(suffix)")

        reveal("shelf.Recently Added TV", in: app).press(forDuration: 1)
        let hide = app.buttons["Hide This Row"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "No Hide This Row in the row menu")
        hide.tap()
        XCTAssertTrue(app.staticTexts["Recently Added TV hidden"].waitForExistence(timeout: 5), "No toast for the hidden row")
        try snap("home-rows-05-hidden-\(suffix)")

        openSettings(in: app)
        let rows = reveal("settings.homeRows", in: app)
        XCTAssertTrue(rows.label.contains("Custom"), "Settings does not report custom rows")
        rows.tap()
        waitForBar("Home Rows", in: app)
        try snap("home-rows-06-settings-\(suffix)")

        reveal("homeRows.reset", in: app).tap()
        let reset = reveal(topRated, in: app)
        let switchedOff = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: reset)
        XCTAssertEqual(XCTWaiter().wait(for: [switchedOff], timeout: 5), .completed, "Reset left the library row on")
        try snap("home-rows-07-reset-\(suffix)")
    }
}
