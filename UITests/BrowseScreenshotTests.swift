import XCTest

/// Home, Library, a movie, a show, Search and the Watchlist against the fake Plex, in Rosé Pine and Dawn.
final class BrowseScreenshotTests: XCTestCase {
    @MainActor
    func testLibraryRosePine() throws {
        try libraryFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testLibraryDawn() throws {
        try libraryFlow(mode: "light", suffix: "dawn")
    }

    @MainActor
    func testSearchRosePine() throws {
        try searchFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testSearchDawn() throws {
        try searchFlow(mode: "light", suffix: "dawn")
    }

    @MainActor
    func testWatchlistRosePine() throws {
        try watchlistFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testWatchlistDawn() throws {
        try watchlistFlow(mode: "light", suffix: "dawn")
    }

    @MainActor
    func testLandscapeRosePine() throws {
        try landscapeFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testLandscapeDawn() throws {
        try landscapeFlow(mode: "light", suffix: "dawn")
    }
}

/// The same screens with Increase Contrast on and the text at accessibility size 2; CI runs this class
/// in its own pass.
final class BrowseAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testLibrary() throws {
        try libraryFlow(mode: "light", suffix: "ax-dawn")
    }

    @MainActor
    func testSearch() throws {
        try searchFlow(mode: "light", suffix: "ax-dawn")
    }

    @MainActor
    func testWatchlist() throws {
        try watchlistFlow(mode: "light", suffix: "ax-dawn")
    }
}

extension XCTestCase {
    /// Home, the Movies grid with its A–Z rail, then Sintel: the top of its page, then its tracks and cast.
    @MainActor
    func libraryFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        waitFor("poster.102", in: app)
        try snap("browse-01-home-\(suffix)")
        open(tab: "Library", title: "Movies", in: app)
        waitFor("poster.101", in: app)
        try snap("browse-02-library-\(suffix)")
        reveal("poster.108", in: app).tap()
        waitFor("detail.title", in: app)
        try snap("browse-03-movie-\(suffix)")
        app.swipeUp(velocity: .slow)
        try snap("browse-04-movie-more-\(suffix)")
    }

    /// A search that finds nothing, one while typing, then the show it finds with its episodes.
    @MainActor
    func searchFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        open(tab: "Search", title: "Search", in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No search field")
        field.tap()
        field.typeText("Totoro")
        waitFor("search.noResults", in: app)
        try snap("browse-05-search-empty-\(suffix)")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "an")
        waitFor("search.result.201", in: app)
        try snap("browse-06-search-\(suffix)")
        tap("search.result.201", in: app)
        waitFor("detail.title", in: app)
        try snap("browse-07-show-\(suffix)")
        _ = reveal("episode.213", in: app)
        try snap("browse-08-show-episodes-\(suffix)")
    }

    /// The watchlist, a saved title the server does not have, then the Live TV tab.
    @MainActor
    func watchlistFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        open(tab: "Watchlist", title: "Watchlist", in: app)
        waitFor("poster.62a1b2c3d4e5f60718000112", in: app)
        try snap("browse-09-watchlist-\(suffix)")
        tap("poster.62a1b2c3d4e5f60718000112", in: app)
        waitFor("detail.notOnServer", in: app)
        try snap("browse-10-watchlist-title-\(suffix)")
        open(tab: "Live TV", title: "Live TV", in: app)
        waitFor("livetv.placeholder", in: app)
        try snap("browse-15-livetv-\(suffix)")
    }

    /// Home, the Movies grid, Sintel and the show's episodes with the phone on its side.
    @MainActor
    func landscapeFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        XCUIDevice.shared.orientation = .landscapeLeft
        // A failed step ends the test early; the next test still has to start upright.
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        waitFor("poster.102", in: app)
        try snap("browse-11-home-landscape-\(suffix)")
        open(tab: "Library", title: "Movies", in: app)
        waitFor("poster.101", in: app)
        try snap("browse-12-library-landscape-\(suffix)")
        reveal("poster.108", in: app).tap()
        waitFor("detail.title", in: app)
        try snap("browse-13-movie-landscape-\(suffix)")
        open(tab: "Search", title: "Search", in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No search field")
        field.tap()
        field.typeText("Camin")
        waitFor("search.result.201", in: app)
        tap("search.result.201", in: app)
        waitFor("detail.title", in: app)
        // Swipes do not scroll the page with the phone on its side, so the shot shows the top of the
        // show with its first episodes.
        waitFor("episode.211", in: app)
        try snap("browse-14-show-landscape-\(suffix)")
    }
}
