import XCTest

/// The player on the fake server's Caminandes episode 2 (intro 0:05–0:35, final credits from 2:10).
/// The simulator decodes no video, so the show's backdrop stands in for the picture, with a clock
/// that runs while playing. Launch arguments open the player straight on the episode.
final class PlayerScreenshotTests: XCTestCase {
    @MainActor
    func testPausedControlsAndPanels() throws {
        try pausedFlow(mode: "dark", suffix: "rose-pine")
    }

    /// The panels keep the app's own light theme while the player stays dark.
    @MainActor
    func testPanelsInLightTheme() throws {
        try panelsFlow(mode: "light", suffix: "paper")
    }

    @MainActor
    func testSkipIntroCountsDownThenSkips() throws {
        try skipIntroFlow(suffix: "rose-pine")
    }

    /// "Watch Intro" stops the countdown; Skip Intro stays as a plain button. The offer drops to the
    /// bottom edge when the controls hide 3 s into playback, so the tap waits for that, with a 10 s
    /// countdown leaving time for it.
    @MainActor
    func testWatchIntroStopsTheCountdown() throws {
        let app = launchPlayer(at: 8, paused: false, mode: "dark", introSkipDelay: 10)
        XCTAssertTrue(element("player.playPause", in: app).waitForNonExistence(timeout: 6), "The controls did not hide")
        tap("player.watchIntro", in: app)
        XCTAssertTrue(element("player.watchIntro", in: app).waitForNonExistence(timeout: 3), "Watch Intro is still showing")
        // Past the end of the 10 s countdown.
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(element("player.skipIntro", in: app).exists, "The intro was skipped after Watch Intro")
        try snap("player-10-watch-intro-rose-pine")
    }

    @MainActor
    func testUpNextCountsDownThenPlaysNext() throws {
        try upNextFlow(suffix: "rose-pine")
    }
}

/// Run by CI with Increase Contrast and an accessibility text size.
final class PlayerAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testPausedControlsAndPanels() throws {
        try pausedFlow(mode: "dark", suffix: "ax")
    }

    @MainActor
    func testSkipIntro() throws {
        try skipIntroFlow(suffix: "ax")
    }

    @MainActor
    func testUpNext() throws {
        try upNextFlow(suffix: "ax")
    }
}

private extension XCTestCase {
    /// Paused mid-episode: the controls, the audio and subtitles menu, the More menu, Playback Info,
    /// the episode list and stats for nerds.
    @MainActor
    func pausedFlow(mode: String, suffix: String) throws {
        let app = launchPlayer(at: 61, paused: true, mode: mode)
        try snap("player-01-paused-\(suffix)")

        tap("player.tracks", in: app)
        XCTAssertTrue(app.buttons["Off"].waitForExistence(timeout: 5), "No audio and subtitles menu")
        try snap("player-02-tracks-menu-\(suffix)")
        dismissMenu(in: app)

        tap("player.more", in: app)
        XCTAssertTrue(app.buttons["Playback Info"].waitForExistence(timeout: 5), "No More menu")
        try snap("player-03-more-menu-\(suffix)")
        dismissMenu(in: app)

        try panels(in: app, suffix: suffix)

        tap("player.more", in: app)
        let stats = app.buttons["Stats for Nerds"]
        XCTAssertTrue(stats.waitForExistence(timeout: 5), "No Stats for Nerds item")
        stats.tap()
        waitFor("player.stats", in: app)
        try snap("player-06-stats-\(suffix)")
    }

    @MainActor
    func panelsFlow(mode: String, suffix: String) throws {
        let app = launchPlayer(at: 61, paused: true, mode: mode)
        try panels(in: app, suffix: suffix)
    }

    /// Playback Info from the More menu, then the episode list.
    @MainActor
    func panels(in app: XCUIApplication, suffix: String) throws {
        tap("player.more", in: app)
        let info = app.buttons["Playback Info"]
        XCTAssertTrue(info.waitForExistence(timeout: 5), "No More menu")
        info.tap()
        waitFor("player.info", in: app)
        try snap("player-04-playback-info-\(suffix)")
        app.navigationBars["Playback Info"].buttons["Done"].tap()

        tap("player.episodes", in: app)
        // The list opens on the playing episode, also when large text leaves room for one row.
        let playing = element("player.episode.212", in: app)
        XCTAssertTrue(playing.wait(for: \.isHittable, toEqual: true, timeout: 10), "The list did not open on episode 2")
        try snap("player-05-episodes-\(suffix)")
        app.navigationBars["Caminandes"].buttons["Done"].tap()
    }

    /// Inside the intro while playing, the pill counts down and then skips by itself.
    @MainActor
    func skipIntroFlow(suffix: String) throws {
        let app = launchPlayer(at: 8, paused: false, mode: "dark")
        let skip = element("player.skipIntro", in: app)
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "No Skip Intro offer")
        XCTAssertTrue(element("player.watchIntro", in: app).exists, "No countdown: Watch Intro is missing")
        try snap("player-09-skip-intro-\(suffix)")
        XCTAssertTrue(skip.waitForNonExistence(timeout: 8), "The intro was not skipped after the countdown")
    }

    /// At the final credits, Up Next counts down and then plays episode 3.
    @MainActor
    func upNextFlow(suffix: String) throws {
        let app = launchPlayer(at: 132, paused: false, mode: "dark")
        let next = element("player.playNext", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: 10), "No Up Next card")
        try snap("player-11-up-next-\(suffix)")
        XCTAssertTrue(next.waitForNonExistence(timeout: 8), "Up Next did not move on")

        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.title' AND label CONTAINS 'Llamigos'")).firstMatch
        if !title.waitForExistence(timeout: 6), !element("player.playPause", in: app).exists {
            // The controls hide while playing; a tap brings them back.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Episode 3 is not playing")
        try snap("player-12-next-episode-\(suffix)")
    }

    /// Opens the player on episode 212 at `seconds` with the phone on its side, and waits until it
    /// has landed there. `introSkipDelay` overrides the profile's intro countdown for this launch.
    @MainActor
    func launchPlayer(at seconds: Double, paused: Bool, mode: String, introSkipDelay: Int? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        // A failed step ends the test early; the next test still has to start upright.
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        var arguments = [
            "-marquee.fakeSignedIn", "YES",
            "-marquee.uitest.play", "212",
            "-marquee.uitest.playerTime", String(seconds),
            "-marquee.uitest.paused", paused ? "YES" : "NO",
            "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
        ]
        if let introSkipDelay { arguments += ["-marquee.uitest.introSkipDelay", String(introSkipDelay)] }
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", light: "paper", arguments: arguments, waitingFor: nil)
        let landed = element("player.playPause", in: app).waitForExistence(timeout: 20)
            || element("player.skipIntro", in: app).exists || element("player.playNext", in: app).exists
        let failure = element("player.failed", in: app)
        XCTAssertTrue(landed, failure.exists ? "Playback failed: \(failure.label)" : "The player did not open")
        return app
    }

    /// A tap away from a menu closes it without reaching the player underneath.
    @MainActor
    func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)
    }
}
