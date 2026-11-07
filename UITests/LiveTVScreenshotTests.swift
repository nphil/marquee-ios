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

    @MainActor
    func testPlayerRosePine() throws {
        try playerFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testPlayerDawn() throws {
        try playerFlow(mode: "light", suffix: "dawn")
    }
}

/// The guide list and the live player with Increase Contrast on and the text at accessibility size 2;
/// CI runs this class in its own pass.
final class LiveTVAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testGuide() throws {
        try guideFlow(mode: "light", suffix: "ax-dawn")
    }

    @MainActor
    func testPlayer() throws {
        try playerFlow(mode: "light", suffix: "ax-dawn")
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
        tap("livetv.category.genre-/tv.plex.providers.epg.cloud/lineups/dvr/channels?genre=genre_movies", inStrip: "livetv.categories", in: app)
        waitFor("livetv.row.ch-0501", in: app)
        try snap("livetv-02-movies-\(suffix)")
        tap("livetv.category.all", inStrip: "livetv.categories", in: app)
        tap("livetv.slot.2", inStrip: "livetv.times", in: app)
        waitFor("livetv.row.ch-0201", in: app)
        try snap("livetv-03-later-\(suffix)")
        tap("livetv.slot.now", inStrip: "livetv.times", in: app)
        reveal("livetv.row.ch-0901", in: app).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Watch"].waitForExistence(timeout: 5), "No channel menu")
        try snap("livetv-04-menu-\(suffix)")
    }

    /// The category chips and the time strip scroll sideways, which XCUITest does not reliably do for a
    /// tap, and at accessibility sizes most of them start off screen. `isHittable` fails the test for an
    /// element off screen, so this compares frames.
    @MainActor
    func tap(_ identifier: String, inStrip strip: String, in app: XCUIApplication) {
        let target = element(identifier, in: app)
        let row = element(strip, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "No element \(identifier)")
        for _ in 0..<6 where !row.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) {
            if target.frame.midX < row.frame.midX {
                row.swipeRight(velocity: .slow)
            } else {
                row.swipeLeft(velocity: .slow)
            }
        }
        target.tap()
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

    /// The live player over the fake tuner's picture: playing on its side, the Quick Guide, the next
    /// channel, stopped, and the Quick Guide upright; then back to the guide.
    @MainActor
    func playerFlow(mode: String, suffix: String) throws {
        let app = launch(
            matchSystem: false, fixedMode: mode, dark: "rose-pine",
            arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.frame", "art/spring-backdrop.jpg"]
        )
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        open(tab: "Live TV", title: "Live TV", in: app)
        tap("livetv.row.ch-0201", in: app)
        waitFor("liveplayer", in: app)
        // The player turns the screen on its side; turning the phone with it keeps the shots upright.
        XCUIDevice.shared.orientation = .landscapeLeft
        let stop = element("liveplayer.stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Channel 2.1 did not play")
        try snap("livetv-13-player-\(suffix)")

        raiseLiveControls(in: app)
        tap("liveplayer.guide", in: app)
        waitFor("liveplayer.quickguide", in: app)
        try snap("livetv-14-quickguide-\(suffix)")
        tap("liveplayer.recent.ch-0701", in: app)
        XCTAssertTrue(element("liveplayer.quickguide", in: app).waitForNonExistence(timeout: 5), "The Quick Guide stayed open")

        raiseLiveControls(in: app)
        tap("liveplayer.next", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "The next channel did not play")
        try snap("livetv-15-next-\(suffix)")

        raiseLiveControls(in: app)
        stop.tap()
        let play = app.buttons.matching(NSPredicate(format: "identifier == 'liveplayer.stop' AND label == 'Play'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "The stream did not stop")
        try snap("livetv-16-stopped-\(suffix)")

        XCUIDevice.shared.orientation = .portrait
        tap("liveplayer.guide", in: app)
        waitFor("liveplayer.quickguide", in: app)
        try snap("livetv-17-quickguide-upright-\(suffix)")
        tap("liveplayer.guide.close", in: app)
        tap("liveplayer.close", in: app)
        XCTAssertTrue(element("liveplayer", in: app).waitForNonExistence(timeout: 5), "The live player stayed open")
        waitFor("livetv.row.ch-0201", in: app)
    }

    /// While a channel plays, the controls fade 3 s after the last touch and a tap on the picture
    /// toggles them. This waits for the channel to play and the controls to fade, then taps them back,
    /// so the next step has the full 3 s.
    @MainActor
    func raiseLiveControls(in app: XCUIApplication) {
        let stop = element("liveplayer.stop", in: app)
        // Stop shows once the channel plays; false here only means the controls faded unseen.
        _ = stop.waitForExistence(timeout: 10)
        XCTAssertTrue(stop.waitForNonExistence(timeout: 6), "The live player's controls did not fade")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "The live player's controls did not come back")
    }
}
