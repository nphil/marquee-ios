import notify
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

    /// The first start shows the file's format for a moment. The hold is lengthened for this launch so a
    /// loaded runner can catch it; Sintel is 4K Dolby Vision with Atmos.
    @MainActor
    func testFormatBadgeShowsOnFirstStart() throws {
        let app = launchPlayer(at: 0, paused: false, mode: "dark", item: "108", badgeSeconds: 6)
        waitFor("player.formatBadge", in: app)
        try snap("player-11-format-badge-rose-pine")
        XCTAssertTrue(element("player.formatBadge", in: app).waitForNonExistence(timeout: 15), "The badge did not fade")
    }

    @MainActor
    func testSkipIntroCountsDownThenSkips() throws {
        try skipIntroFlow(suffix: "rose-pine")
    }

    @MainActor
    func testNetworkWaitOffersALowerQuality() throws {
        try networkWaitFlow(suffix: "rose-pine")
    }

    @MainActor
    func testAutoBuffersInsteadOfDroppingBelowPictureFloor() throws {
        // Paused, the controls stay up, so the first look at the menu cannot race their fade.
        let app = launchPlayer(at: 61, paused: true, mode: "dark", item: "912", linkTest: true)
        openMore(in: app)
        let quality = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Quality'")).firstMatch
        XCTAssertTrue(quality.waitForExistence(timeout: 5))
        func shown() -> String { "\(quality.label) \(quality.value as? String ?? "")" }
        XCTAssertTrue(shown().contains("Auto · Original"), "Auto did not start at Original: \(shown())")
        dismissMenu(in: app)
        tap("player.playPause", in: app)
        XCTAssertTrue(element("player.playPause", in: app).waitForNonExistence(timeout: 10), "Controls did not hide")

        notify_post("marquee.uitest.link.poor")
        let floor = element("player.qualityFloor", in: app)
        XCTAssertTrue(floor.waitForExistence(timeout: 90), "Poor throughput did not surface the floor warning")
        XCTAssertTrue(element("player.playPause", in: app).exists, "The warning did not reveal hidden controls")
        XCTAssertFalse(element("player.lowerQuality", in: app).exists)
        try snap("player-43-auto-quality-floor")
        openMore(in: app)
        let atFloor = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in shown().contains("Auto · 4 Mbps 720p") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [atFloor], timeout: 30), .completed, "Auto did not reach the 720p floor: \(shown())")
        dismissMenu(in: app)

        notify_post("marquee.uitest.link.stall")
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(floor.exists, "The floor warning disappeared while stalled")
        XCTAssertFalse(element("player.lowerQuality", in: app).exists)
        openMore(in: app)
        XCTAssertTrue(shown().contains("Auto · 4 Mbps 720p"), "Auto dropped below the floor while stalled: \(shown())")
        dismissMenu(in: app)

        notify_post("marquee.uitest.link.healthy")
        XCTAssertTrue(floor.waitForNonExistence(timeout: 45), "The floor warning did not clear after recovery")
        openMore(in: app)
        let climbed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = shown()
            return value.contains("Auto ·") && !value.contains("4 Mbps 720p")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [climbed], timeout: 60), .completed, "Auto did not climb after recovery: \(shown())")
    }

    /// "Watch Intro" stops the countdown; Skip Intro stays as a plain button. The offer drops to the
    /// bottom edge when the controls hide 3 s into playback, and a loaded runner can take several
    /// seconds to find the button, so the countdown is 20 s. The intro ends 28 s after the start, so
    /// the check that no skip happened falls between the two.
    @MainActor
    func testWatchIntroStopsTheCountdown() throws {
        let app = launchPlayer(at: 6, paused: false, mode: "dark", introSkipDelay: 20)
        let landed = Date()
        XCTAssertTrue(element("player.playPause", in: app).waitForNonExistence(timeout: 6), "The controls did not hide")
        tap("player.watchIntro", in: app)
        XCTAssertTrue(element("player.watchIntro", in: app).waitForNonExistence(timeout: 3), "Watch Intro is still showing")
        // Past the end of the countdown, which began no later than the player appeared.
        Thread.sleep(forTimeInterval: max(0, 22 - Date().timeIntervalSince(landed)))
        XCTAssertTrue(element("player.skipIntro", in: app).exists, "The intro was skipped after Watch Intro")
        try snap("player-10-watch-intro-rose-pine")
    }

    @MainActor
    func testUpNextCountsDownThenPlaysNext() throws {
        try upNextFlow(suffix: "rose-pine")
    }

    @MainActor
    func testWrongSubtitlesAndBazarr() throws {
        try subtitleFixFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testWrongSubtitlesAndBazarrInLightTheme() throws {
        try subtitleFixFlow(mode: "light", suffix: "paper")
    }

    @MainActor
    func testScrubPreviewFollowsTheThumb() throws {
        try scrubPreviewFlow(suffix: "rose-pine")
    }

    /// The Chromecast plugin's route popover, a hand-off to FakeCast's receiver and back to the phone.
    @MainActor
    func testCastsToAChromecastAndBack() throws {
        let app = launchPlayer(at: 30, paused: true, mode: "dark", cast: true)
        tap("player.route", in: app)
        let receiver = element("route.fake-cast", in: app)
        XCTAssertTrue(receiver.waitForExistence(timeout: 10), "The Chromecast was not listed")
        try snap("player-30-cast-picker-rose-pine")
        receiver.tap()
        let playing = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Playing on Living Room TV")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 15), "The video did not move to the Chromecast")
        try snap("player-31-casting-rose-pine")
        tap("player.route", in: app)
        tap("route.phone", in: app)
        XCTAssertTrue(playing.waitForNonExistence(timeout: 10), "The video did not come back to the phone")
    }
}

/// The route menu with FakeCast's four receivers, on a phone on its side and upright. Besides the standard
/// simulator, CI runs these on the smallest and largest iPhone simulators; the shots carry the screen's size.
final class PlayerRouteMenuScreenshots: XCTestCase {
    @MainActor
    func testRouteMenuLandscape() throws {
        try routeMenuFlow(orientation: .landscapeLeft, suffix: "rose-pine")
    }

    @MainActor
    func testRouteMenuPortrait() throws {
        try routeMenuFlow(orientation: .portrait, suffix: "rose-pine")
    }
}

final class SubtitleSearchScreenshots: XCTestCase {
    @MainActor
    func testSearchPortrait() throws {
        try subtitleSearchFlow(orientation: .portrait, suffix: "portrait")
    }

    @MainActor
    func testSearchLandscape() throws {
        try subtitleSearchFlow(orientation: .landscapeLeft, suffix: "landscape")
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
    func testNetworkWait() throws {
        try networkWaitFlow(suffix: "ax")
    }

    @MainActor
    func testUpNext() throws {
        try upNextFlow(suffix: "ax")
    }

    @MainActor
    func testWrongSubtitlesAndBazarr() throws {
        try subtitleFixFlow(mode: "dark", suffix: "ax")
    }

    @MainActor
    func testRouteMenu() throws {
        try routeMenuFlow(orientation: .landscapeLeft, suffix: "ax")
    }
}

private extension XCTestCase {
    @MainActor
    func subtitleSearchFlow(orientation: UIDeviceOrientation, suffix: String) throws {
        let app = launchPlayer(at: 61, paused: true, mode: "dark", bazarr: true)
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        openSubtitles(in: app)
        scrollList(app.collectionViews["player.subtitles"], to: element("player.tracks.search", in: app)).tap()
        XCTAssertTrue(element("subtitleSearch.language", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("bazarr.result", in: app).waitForExistence(timeout: 10))
        try snap("subtitle-search-\(suffix)")
    }

    /// Paused mid-episode: the controls on the phone's side and upright, the audio and subtitles menu,
    /// the More menu, Playback Info, the episode list and stats for nerds.
    @MainActor
    func pausedFlow(mode: String, suffix: String) throws {
        let app = launchPlayer(at: 61, paused: true, mode: mode)
        assertChrome(in: app)
        try snap("player-01-paused-\(suffix)")

        XCUIDevice.shared.orientation = .portrait
        try snap("player-07-portrait-\(suffix)")
        assertChrome(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft

        tap("player.tracks", in: app)
        XCTAssertNotNil(subtitlesMenuItem(in: app), "No subtitles entry in tracks menu")
        try snap("player-02-tracks-menu-\(suffix)")
        dismissMenu(in: app)

        tap("player.more", in: app)
        let aspect = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Aspect'")).firstMatch
        XCTAssertTrue(aspect.waitForExistence(timeout: 5), "No More menu")
        // Auto is the default; at home it plays the original.
        let quality = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Quality'")).firstMatch
        let shown = "\(quality.label) \(quality.value as? String ?? "")"
        XCTAssertTrue(shown.contains("Auto · Original"), "The More menu shows \(shown), not Auto · Original")
        try snap("player-03-more-menu-\(suffix)")
        dismissMenu(in: app)

        try panels(in: app, suffix: suffix)

        tap("player.more", in: app)
        let stats = moreMenuItem("Stats for Nerds", in: app)
        XCTAssertTrue(stats.exists && stats.isHittable, "No Stats for Nerds item")
        stats.tap()
        waitFor("player.stats", in: app)
        let copy = app.buttons["player.stats.copy"]
        XCTAssertTrue(copy.exists, "No Copy button on the stats overlay")
        for control in ["player.scrubber", "player.playPause", "player.tracks", "player.more"] {
            XCTAssertFalse(copy.frame.intersects(element(control, in: app).frame), "\(control) covers the stats Copy button")
        }
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
        let info = moreMenuItem("Playback Info", in: app)
        XCTAssertTrue(info.exists && info.isHittable, "No Playback Info item")
        info.tap()
        waitFor("player.info", in: app)
        try snap("player-04-playback-info-\(suffix)")
        let copy = scrollList(app.collectionViews["player.info"], to: app.buttons["Copy Diagnostics"])
        XCTAssertTrue(copy.wait(for: \.isHittable, toEqual: true, timeout: 5), "No Copy Diagnostics")
        try snap("player-04-playback-info-diagnostics-\(suffix)")
        app.navigationBars["Playback Info"].buttons["Done"].tap()

        tap("player.episodes", in: app)
        // The list opens on the playing episode, also when large text leaves room for one row.
        let playing = element("player.episode.212", in: app)
        XCTAssertTrue(playing.wait(for: \.isHittable, toEqual: true, timeout: 10), "The list did not open on episode 2")
        try snap("player-05-episodes-\(suffix)")
        // The season menu is pinned in the panel's header, above the list.
        waitFor("player.episodes.close", in: app)
        tap("player.episodes.close", in: app)
        XCTAssertTrue(element("player.episodeSheet", in: app).waitForNonExistence(timeout: 5), "The episode list did not close")
    }

    /// The chrome holds close, title, the route button, the transport, the scrubber, restart, episodes,
    /// next, Tracks and More, every control at least 44 pt at any text size.
    @MainActor
    func assertChrome(in app: XCUIApplication) {
        for control in [
            "player.close", "player.skipBack", "player.playPause", "player.skipForward", "player.previous",
            "player.episodes", "player.next", "player.tracks", "player.more",
        ] {
            let button = element(control, in: app)
            XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable, "\(control) is not on screen")
            XCTAssertGreaterThanOrEqual(min(button.frame.width, button.frame.height), 44, "\(control) is under 44 pt")
        }
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

    /// Playback that waits on data for good at a fixed quality (Auto steps down by itself): "Waiting for the
    /// network" under the ring after 2 s, the lower-quality offer after 10 s (the caption gives way to it), and,
    /// once taken, the new stream's own wait and the More menu showing the quality it took (8 Mbps file → 4 Mbps).
    @MainActor
    func networkWaitFlow(suffix: String) throws {
        let app = launchPlayer(at: 61, paused: false, mode: "dark", stall: true, quality: 0)
        waitFor("player.networkWait", in: app)
        try snap("player-40-network-wait-\(suffix)")
        let offer = element("player.lowerQuality", in: app)
        XCTAssertTrue(offer.waitForExistence(timeout: 15), "No lower-quality offer after 10 s of waiting")
        try snap("player-41-lower-quality-\(suffix)")
        offer.tap()
        // The stream at the lower quality waits too, which keeps the controls up.
        XCTAssertTrue(offer.waitForNonExistence(timeout: 5), "The offer stayed after it was taken")
        waitFor("player.networkWait", in: app)
        tap("player.more", in: app)
        let picked = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '4 Mbps 720p'")).firstMatch
        let quality = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Quality'")).firstMatch
        XCTAssertTrue(quality.waitForExistence(timeout: 5), "No Quality item in the More menu")
        let shown = "\(quality.label) \(quality.value as? String ?? "")"
        XCTAssertTrue(picked.exists || shown.contains("4 Mbps 720p"), "The More menu shows \(shown), not 4 Mbps 720p")
        try snap("player-42-lower-quality-more-\(suffix)")
        dismissMenu(in: app)
    }

    /// The scrub preview with the scrubber held mid-drag at the start, middle and end of the track.
    /// The preview must sit a fixed gap above the thumb, centred on it, and stay `Space.inset` inside
    /// the safe area at both ends. The player is landscape-only on iPhone, so there is no portrait shot.
    @MainActor
    func scrubPreviewFlow(suffix: String) throws {
        for (name, fraction) in [("start", 0.0), ("middle", 0.5), ("end", 1.0)] {
            let app = launchPlayer(at: 61, paused: true, mode: "dark", scrub: fraction)
            let preview = element("player.seekPreview", in: app)
            let drawn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "ready"), object: preview)
            XCTAssertEqual(XCTWaiter().wait(for: [drawn], timeout: 15), .completed, "The scene thumbnail never showed at \(name)")
            try snap("player-13-scrub-\(name)-\(suffix)")

            // The scrubber's ends are the safe area's edges plus `Space.inset`, the margin the preview keeps.
            let scrubber = element("player.scrubber", in: app).frame
            let thumb = element("player.scrubThumb", in: app).frame
            let box = preview.frame
            let lowest = scrubber.minX + box.width / 2
            let highest = scrubber.maxX - box.width / 2
            XCTAssertEqual(box.width, 224, accuracy: 1, "\(name): preview width")
            XCTAssertEqual(box.maxY, thumb.minY - 12, accuracy: 1, "\(name): gap above the thumb")
            XCTAssertEqual(box.midX, min(max(thumb.midX, lowest), highest), accuracy: 1, "\(name): preview centre")
            switch name {
            case "start": XCTAssertLessThan(thumb.midX, lowest, "start: the thumb is not at the start")
            case "end": XCTAssertGreaterThan(thumb.midX, highest, "end: the thumb is not at the end")
            default: XCTAssertTrue((lowest...highest).contains(thumb.midX), "middle: the thumb is not clear of the edges")
            }
            XCTAssertGreaterThanOrEqual(box.minX, scrubber.minX - 1, "\(name): preview past the left edge")
            XCTAssertLessThanOrEqual(box.maxX, scrubber.maxX + 1, "\(name): preview past the right edge")
            app.terminate()
        }
    }

    /// At the final credits, Up Next counts down and then plays episode 3.
    @MainActor
    func upNextFlow(suffix: String) throws {
        let app = launchPlayer(at: 132, paused: false, mode: "dark")
        let next = element("player.playNext", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: 10), "No Up Next card")
        if element("player.close", in: app).exists {
            XCTAssertFalse(element("player.playPause", in: app).exists, "The transport shows under the Up Next card")
        }
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

    /// "Wrong Subtitles?" on the episode's own English track, Bazarr's results, a download that Plex
    /// lists and the player shows, that file removed from Plex again, then one Plex's own agents add.
    @MainActor
    func subtitleFixFlow(mode: String, suffix: String) throws {
        let app = launchPlayer(at: 61, paused: true, mode: mode, bazarr: true, speechDock: true)

        openSubtitles(in: app)
        let english = app.buttons.matching(NSPredicate(format: "label == 'English'"))
        scrollList(app.collectionViews["player.subtitles"], to: english.firstMatch).tap()
        tap("subtitleFix.done", in: app)
        openWrongSubtitles(in: app)
        let removal = element("subtitleFix.removal", in: app)
        XCTAssertTrue(removal.waitForExistence(timeout: 5), "No removal line")
        XCTAssertEqual(removal.label, "Part of the video file, so it can't be removed.", "An embedded track offers removal")
        try snap("player-13-wrong-subtitles-\(suffix)")

        scrollList(app.collectionViews["subtitleFix.wrong"], to: element("subtitleFix.findAnother", in: app)).tap()
        // The language picker comes with the results; at accessibility sizes they start below it.
        XCTAssertTrue(element("subtitleSearch.language", in: app).waitForExistence(timeout: 10), "No subtitle search")
        try snap("player-14-bazarr-results-\(suffix)")

        scrollList(app.collectionViews["subtitleFix.search"], to: element("bazarr.result", in: app)).tap()
        let state = element("bazarr.state", in: app)
        XCTAssertTrue(state.waitForExistence(timeout: 5), "The download did not start")
        XCTAssertTrue(state.wait(for: \.label, toEqual: "Active in player", timeout: 20), "The download did not show: \(state.label)")
        try snap("player-15-bazarr-downloaded-\(suffix)")

        tap("subtitleFix.done", in: app)
        XCTAssertTrue(element("subtitleFix.search", in: app).waitForNonExistence(timeout: 5), "The sheet did not close")
        try snap("player-16-downloaded-subtitle-\(suffix)")

        openWrongSubtitles(in: app)
        let showing = element("subtitleFix.showing", in: app)
        XCTAssertTrue(showing.waitForExistence(timeout: 5), "Nothing is named as showing")
        XCTAssertTrue(showing.label.hasSuffix("A separate file next to the video"), "The download is not the subtitle showing: \(showing.label)")
        scrollList(app.collectionViews["subtitleFix.wrong"], to: element("subtitleFix.remove", in: app)).tap()
        let confirm = labelled("Remove Subtitle", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Removal was not confirmed first")
        try snap("player-17-remove-subtitle-\(suffix)")

        confirm.tap()
        XCTAssertTrue(removal.wait(for: \.label, toEqual: "Removed from Plex.", timeout: 10), "No word that the file was removed: \(removal.label)")
        try snap("player-18-subtitle-removed-\(suffix)")

        scrollList(app.collectionViews["subtitleFix.wrong"], to: element("subtitleFix.findAnother", in: app)).tap()
        scrollList(app.collectionViews["subtitleFix.search"], to: element("subtitleSearch.more", in: app)).tap()
        let plexResult = element("plex.result", in: app)
        XCTAssertTrue(plexResult.waitForExistence(timeout: 10), "No Plex results")
        try snap("player-19-plex-results-\(suffix)")

        scrollList(app.collectionViews["subtitleFix.search"], to: plexResult).tap()
        let plexState = element("plex.state", in: app)
        XCTAssertTrue(plexState.waitForExistence(timeout: 5), "The Plex download did not start")
        XCTAssertTrue(plexState.wait(for: \.label, toEqual: "Active in player", timeout: 20), "The Plex download did not show: \(plexState.label)")
        try snap("player-20-plex-added-\(suffix)")

        // Reveal as Spoken on the file Plex added: SpeechDock times its English lines.
        tap("subtitleFix.done", in: app)
        XCTAssertTrue(element("subtitleFix.search", in: app).waitForNonExistence(timeout: 5), "The sheet did not close")
        openSubtitles(in: app)
        scrollList(app.collectionViews["player.subtitles"], to: element("player.tracks.style", in: app)).tap()
        waitForBar("Subtitle Style", in: app)
        // A landscape sheet ignores app.swipeUp, so the style list is dragged to the row.
        scrollList(app.collectionViews["style.list"], to: element("style.moreOptions", in: app)).tap()
        waitForBar("More options", in: app)
        reveal("style.reveal", in: app).tap()
        let word = app.buttons["Word by Word"]
        XCTAssertTrue(word.waitForExistence(timeout: 5), "No Word by Word reveal")
        word.tap()
        tap("subtitleFix.done", in: app)
        XCTAssertTrue(app.navigationBars["Subtitle Style"].waitForNonExistence(timeout: 5), "The style sheet did not close")
        try snap("player-21-reveal-as-spoken-\(suffix)")
    }

    @MainActor
    func openWrongSubtitles(in app: XCUIApplication) {
        openSubtitles(in: app)
        scrollList(app.collectionViews["player.subtitles"], to: element("player.tracks.wrong", in: app)).tap()
        waitFor("subtitleFix.wrong", in: app)
    }

    @MainActor
    func openSubtitles(in app: XCUIApplication) {
        tap("player.tracks", in: app)
        guard let subtitles = subtitlesMenuItem(in: app) else {
            XCTFail("No subtitles entry in tracks menu")
            return
        }
        subtitles.tap()
        waitFor("player.subtitles", in: app)
    }

    @MainActor
    func subtitlesMenuItem(in app: XCUIApplication) -> XCUIElement? {
        scrollMenu(in: app) {
            let item = labelled("Subtitles…", in: app)
            return item.exists && item.isHittable ? item : nil
        }
    }

    /// Opens the More menu and returns once its Quality row shows. Playing chrome fades 3 s after the last
    /// touch and a loaded runner can take longer than that to answer one query, so the button is resolved
    /// once and tapped at that frame; when it is gone a tap on the picture brings the chrome back first.
    @MainActor
    func openMore(in app: XCUIApplication) {
        let more = element("player.more", in: app)
        let quality = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Quality'")).firstMatch
        for _ in 0..<4 {
            if let button = try? more.snapshot() {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: button.frame.midX, dy: button.frame.midY)).tap()
                if quality.waitForExistence(timeout: 3) { return }
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                _ = more.waitForExistence(timeout: 3)
            }
        }
        XCTFail("The More menu did not open")
    }

    /// An open menu lays out only the rows that fit on screen. The tracks menu hangs from the right of
    /// the screen with its first rows at the top, so drags up its middle bring the rest in, held still
    /// before letting go so it stops where the drag ends, until `row` finds one that can be tapped.
    @MainActor
    func scrollMenu(in app: XCUIApplication, to row: () -> XCUIElement?) -> XCUIElement? {
        for _ in 0..<12 {
            if let found = row() { return found }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.85)).press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
        return row()
    }

    /// app.swipeUp() leaves a landscape sheet's list unscrolled, so the drags run between two points of
    /// the list. At accessibility sizes a row is hittable while only its top shows, so they go on until
    /// `row` is whole on screen.
    @MainActor
    func scrollList(_ list: XCUIElement, to row: XCUIElement) -> XCUIElement {
        XCTAssertTrue(list.waitForExistence(timeout: 10), "No list to scroll")
        var drags = 0
        while !(row.exists && row.isHittable && list.frame.contains(row.frame)), drags < 15 {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(
                forDuration: 0.1,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
            drags += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "Scrolling did not bring the row on screen")
        return row
    }

    /// A button by its label alone, whatever identifier it carries.
    @MainActor
    func labelled(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Opens the player on episode 212 at `seconds` with the phone on its side, and waits until it
    /// has landed there. `introSkipDelay` overrides the profile's intro countdown for this launch;
    /// `bazarr` sets up the fake Bazarr; `scrub` holds the scrubber at that fraction; `cast` turns the
    /// Chromecast plugin on with FakeCast's receiver; `stall` keeps playback waiting on data.
    @MainActor
    func launchPlayer(
        at seconds: Double, paused: Bool, mode: String, introSkipDelay: Int? = nil, bazarr: Bool = false, speechDock: Bool = false,
        scrub: Double? = nil, cast: Bool = false, stall: Bool = false, quality: Int? = nil, item: String = "212",
        badgeSeconds: Double? = nil, linkTest: Bool = false
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        // A failed step ends the test early; the next test still has to start upright.
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        var arguments = [
            "-marquee.fakeSignedIn", "YES",
            "-marquee.uitest.play", item,
            "-marquee.uitest.playerTime", String(seconds),
            "-marquee.uitest.paused", paused ? "YES" : "NO",
            "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
        ]
        if let introSkipDelay { arguments += ["-marquee.uitest.introSkipDelay", String(introSkipDelay)] }
        if speechDock { arguments += ["-marquee.uitest.speechDock", "http://speechdock.local:8765"] }
        if bazarr { arguments += ["-marquee.uitest.bazarr", "http://bazarr.local:6767"] }
        if let scrub { arguments += ["-marquee.uitest.scrub", String(scrub)] }
        if cast { arguments += ["-marquee.uitest.cast", "YES"] }
        if stall { arguments += ["-marquee.uitest.stall", "YES"] }
        if let quality { arguments += ["-marquee.uitest.quality", String(quality)] }
        if let badgeSeconds { arguments += ["-marquee.uitest.badgeSeconds", String(badgeSeconds)] }
        if linkTest { arguments += ["-marquee.uitest.linkTest", "YES"] }
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", light: "paper", arguments: arguments, waitingFor: nil)
        // Up Next hides the transport, so whichever control shows first means the player is up.
        // The scrub hold hides the transport, so the preview stands for it.
        let landed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", scrub == nil
                ? ["player.playPause", "player.skipIntro", "player.playNext"] : ["player.seekPreview"]))
            .firstMatch.waitForExistence(timeout: 20)
        let failure = element("player.failed", in: app)
        XCTAssertTrue(landed, failure.exists ? "Playback failed: \(failure.label)" : "The player did not open")
        return app
    }

    /// The route menu open: every row inside the screen with a margin, the first row reachable, and the
    /// last reachable by scrolling when the rows are taller than the room. The shots show the icons in one
    /// column, the labels on one line and the check at the trailing margin.
    @MainActor
    func routeMenuFlow(orientation: UIDeviceOrientation, suffix: String) throws {
        let app = launchPlayer(at: 61, paused: true, mode: "dark", cast: true)
        XCUIDevice.shared.orientation = orientation
        assertChrome(in: app)
        tap("player.route", in: app)
        let menu = element("route.menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "The route menu did not open")
        let phone = element("route.phone", in: app)
        XCTAssertTrue(phone.waitForExistence(timeout: 10), "No This iPhone row")
        for id in ["route.fake-cast", "route.fake-cast-2", "route.fake-cast-3", "route.fake-cast-4"] {
            XCTAssertTrue(element(id, in: app).exists, "The Chromecast \(id) was not listed")
        }

        let screen = app.windows.firstMatch.frame
        let box = menu.frame
        let margin: CGFloat = 8
        XCTAssertGreaterThanOrEqual(box.minX, screen.minX + margin, "The menu runs off the leading edge: \(box) in \(screen)")
        XCTAssertLessThanOrEqual(box.maxX, screen.maxX - margin, "The menu runs off the trailing edge: \(box) in \(screen)")
        XCTAssertGreaterThanOrEqual(box.minY, screen.minY + margin, "The menu runs off the top: \(box) in \(screen)")
        XCTAssertLessThanOrEqual(box.maxY, screen.maxY - margin, "The menu runs off the bottom: \(box) in \(screen)")
        XCTAssertTrue(phone.isHittable, "The first row is under the menu's edge")
        XCTAssertGreaterThanOrEqual(phone.frame.minY, box.minY - 1, "The first row starts above the menu")

        let width = Int(min(screen.width, screen.height)), height = Int(max(screen.width, screen.height))
        let place = orientation.isLandscape ? "landscape" : "portrait"
        try snap("player-32-route-menu-\(place)-\(width)x\(height)-\(suffix)")

        // The last row: in view, or one drag brings it in.
        let airplay = element("route.airplay", in: app)
        XCTAssertTrue(airplay.exists, "No AirPlay & Bluetooth row")
        if !airplay.isHittable {
            menu.swipeUp()
            XCTAssertTrue(airplay.isHittable, "The last row cannot be scrolled into view")
            try snap("player-32-route-menu-\(place)-\(width)x\(height)-\(suffix)-end")
        }
    }

    /// A tap away from a menu closes it without reaching the player underneath.
    @MainActor
    func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// An item of the More menu, which scrolls at accessibility sizes. The menu opens upward with
    /// its first item nearest the button, so the last items start above its top edge; drags down
    /// the menu bring them in.
    @MainActor
    func moreMenuItem(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let item = app.buttons[label]
        _ = item.waitForExistence(timeout: 3)
        var drags = 0
        while !(item.exists && item.isHittable), drags < 4 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.25))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.85)))
            drags += 1
        }
        return item
    }
}
