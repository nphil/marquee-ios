import XCTest

/// Places off the tab bar (DESIGN §7): with Watchlist and Search off it, Home carries a Watchlist row, the
/// Library's title menu opens the watchlist and its Search button opens Search ready to type; with the
/// Library off it, Home's title menu opens the Library. In Rosé Pine and Dawn.
final class TabLayoutScreenshotTests: XCTestCase {
    @MainActor
    func testPlacesOffTheBarRosePine() throws {
        try placesOffTheBarFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testPlacesOffTheBarDawn() throws {
        try placesOffTheBarFlow(mode: "light", suffix: "dawn")
    }
}

/// The same with Increase Contrast on and the text at accessibility size 2; CI runs this class in its own
/// pass.
final class TabLayoutAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testPlacesOffTheBar() throws {
        try placesOffTheBarFlow(mode: "light", suffix: "ax-dawn")
    }
}

extension XCTestCase {
    @MainActor
    func placesOffTheBarFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", arguments: [
            "-marquee.fakeSignedIn", "YES", "-marquee.tabs", "(home, library, liveTV)",
        ])
        XCTAssertFalse(app.tabBars.buttons["Watchlist"].exists, "Watchlist is still a tab")
        // The Watchlist shelf loads with Home, not when it scrolls into the lazy stack.
        waitFor("continue.212", in: app)
        // Wing It! is on the watchlist only, so its poster on Home is the Watchlist row's.
        _ = reveal("poster.62a1b2c3d4e5f60718000112", in: app)
        try snap("places-01-home-watchlist-row-\(suffix)")

        open(tab: "Library", title: "Movies", in: app)
        openTitleMenu("Movies", in: app)
        let watchlist = app.buttons["Watchlist"].firstMatch
        XCTAssertTrue(watchlist.waitForExistence(timeout: 5), "No Watchlist in the Library's title menu")
        try snap("places-02-library-menu-\(suffix)")
        watchlist.tap()
        waitForBar("Watchlist", in: app)
        try snap("places-03-watchlist-pushed-\(suffix)")
        goBack(from: "Watchlist", in: app)
        waitForBar("Movies", in: app)

        tap("library.search", in: app)
        let field = app.searchFields.element(matching: NSPredicate(format: "hasKeyboardFocus == true"))
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Search opened without its field ready to type")
        try snap("places-04-search-pushed-\(suffix)")

        let noLibrary = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", arguments: [
            "-marquee.fakeSignedIn", "YES", "-marquee.tabs", "(home, liveTV, watchlist, search)",
        ])
        openTitleMenu("Home", in: noLibrary)
        let library = noLibrary.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5), "No Library in Home's title menu")
        try snap("places-05-home-menu-\(suffix)")
        library.tap()
        waitForBar("Movies", in: noLibrary)
        try snap("places-06-library-pushed-\(suffix)")
    }

    /// A title menu draws the bar's title as a button.
    @MainActor
    private func openTitleMenu(_ title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        let button = bar.buttons[title].firstMatch
        (button.waitForExistence(timeout: 5) ? button : bar.staticTexts[title].firstMatch).tap()
    }
}
