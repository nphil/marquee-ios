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

    @MainActor
    func testRecordingsRosePine() throws {
        try recordingsFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testRecordingsDawn() throws {
        try recordingsFlow(mode: "light", suffix: "dawn")
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

    /// The programme sheet of a series airing, of an airing not set to record with its options at full
    /// height, and of a single recording with art; then Recordings: the schedule, a series' settings and
    /// what was recorded.
    @MainActor
    func recordingsFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        open(tab: "Live TV", title: "Live TV", in: app)
        waitFor("livetv.row.ch-0201", in: app)
        let sheet = element("livetv.programme", in: app)

        tap("livetv.slot.1", in: app)
        tap("livetv.row.ch-0201", in: app)
        waitFor("livetv.programme.status", in: app)
        try snap("livetv-07-series-\(suffix)")
        tap("livetv.programme.close", in: app)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "The programme sheet stayed open")

        tap("livetv.slot.2", in: app)
        tap("livetv.row.ch-0401", in: app)
        tap("livetv.programme.options", in: app)
        waitFor("livetv.setting.startOffsetMinutes", in: app)
        sheet.swipeUp(velocity: .slow)
        try snap("livetv-08-record-\(suffix)")
        tap("livetv.programme.close", in: app)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "The programme sheet stayed open")

        tap("livetv.slot.1", in: app)
        reveal("livetv.row.ch-1301", in: app).tap()
        waitFor("livetv.programme.unschedule", in: app)
        try snap("livetv-09-single-\(suffix)")
        tap("livetv.programme.close", in: app)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "The programme sheet stayed open")

        tap("livetv.recordings", in: app)
        waitFor("livetv.scheduled.grab-42", in: app)
        try snap("livetv-10-scheduled-\(suffix)")
        tap("livetv.rule.42", in: app)
        waitFor("livetv.rule.delete", in: app)
        try snap("livetv-11-series-\(suffix)")
        tap("livetv.rule.cancel", in: app)
        XCTAssertTrue(element("livetv.rule.delete", in: app).waitForNonExistence(timeout: 5), "The series sheet stayed open")
        let recorded = app.buttons["Recorded"].firstMatch
        XCTAssertTrue(recorded.waitForExistence(timeout: 5), "No Recorded page")
        recorded.tap()
        waitFor("livetv.recorded.2102", in: app)
        try snap("livetv-12-recorded-\(suffix)")
    }
}
