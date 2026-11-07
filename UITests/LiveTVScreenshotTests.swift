import XCTest

/// The Live TV guide of the fake server's antenna, drawn at 9:41 PM (UITests/FakePlex/README.md).
final class LiveTVScreenshotTests: XCTestCase {
    @MainActor
    func testGuideRosePine() throws {
        try guideFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testGuideDawn() throws {
        try guideFlow(mode: "light", suffix: "dawn")
    }

    @MainActor
    func testGridRosePine() throws {
        try gridFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testGridDawn() throws {
        try gridFlow(mode: "light", suffix: "dawn")
    }
}

/// The list with Increase Contrast on and the text at accessibility size 2; CI runs this class in its
/// own pass.
final class LiveTVAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testGuide() throws {
        try guideFlow(mode: "light", suffix: "ax-dawn")
    }
}

extension XCTestCase {
    /// Now and next on every channel, the Movies genre, the guide at 10:30 PM, then a channel's menu.
    @MainActor
    func guideFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        open(tab: "Live TV", title: "Live TV", in: app)
        waitFor("livetv.row.ch-0201", in: app)
        try snap("livetv-01-guide-\(suffix)")
        tap("livetv.category.genre-/tv.plex.providers.epg.cloud/lineups/dvr/channels?genre=genre_movies", in: app)
        waitFor("livetv.row.ch-0501", in: app)
        try snap("livetv-02-movies-\(suffix)")
        // Tapping Movies scrolled the chips; All sits off the leading edge until they scroll back.
        element("livetv.categories", in: app).swipeRight()
        tap("livetv.category.all", in: app)
        tap("livetv.slot.2", in: app)
        waitFor("livetv.row.ch-0201", in: app)
        try snap("livetv-03-later-\(suffix)")
        tap("livetv.slot.now", in: app)
        reveal("livetv.row.ch-0901", in: app).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Watch"].waitForExistence(timeout: 5), "No channel menu")
        try snap("livetv-04-menu-\(suffix)")
    }

    /// The time grid with the phone on its side, at now and further on.
    @MainActor
    func gridFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        XCUIDevice.shared.orientation = .landscapeLeft
        // A failed step ends the test early; the next test still has to start upright.
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        open(tab: "Live TV", title: "Live TV", in: app)
        waitFor("livetv.grid", in: app)
        try snap("livetv-05-grid-\(suffix)")
        element("livetv.grid", in: app).swipeLeft(velocity: .slow)
        waitFor("livetv.jumpToNow", in: app)
        try snap("livetv-06-grid-later-\(suffix)")
    }
}
