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

    /// The first start shows the file's format for a moment, but only once the controls have faded, in the
    /// top trailing corner inside the controls' own margins. The hold is lengthened for this launch so a
    /// loaded runner can catch it; Sintel is 4K Dolby Vision with Atmos.
    @MainActor
    func testFormatBadgeShowsOnFirstStart() throws {
        let app = launchPlayer(at: 0, paused: false, mode: "dark", item: "108", badgeSeconds: 6)
        // The controls are up at first and fade 3 s into the playing picture; the badge waits for that.
        let controls = element("player.playPause", in: app)
        let badge = element("player.formatBadge", in: app)
        XCTAssertTrue(badge.waitForExistence(timeout: 20), "No format badge")
        XCTAssertFalse(controls.exists, "The badge showed while the controls were up")
        let screen = app.windows.firstMatch.frame
        // A wide badge in an upright player can reach past the middle, so its trailing edge is what is checked.
        XCTAssertGreaterThan(badge.frame.maxX, screen.maxX - 48, "The badge is not on the trailing side")
        XCTAssertLessThan(badge.frame.minY, screen.minY + screen.height * 0.25, "The badge is not at the top")
        XCTAssertLessThanOrEqual(badge.frame.maxX, screen.maxX - 16, "The badge is inside the screen margin")
        try snap("player-11-format-badge-rose-pine")
        XCTAssertTrue(badge.waitForNonExistence(timeout: 15), "The badge did not fade")
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
        let quality = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Quality'")).firstMatch
        func shown() -> String { "\(quality.label) \(quality.value as? String ?? "")" }
        let more = element("player.more", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 10), "No More button")
        let moreFrame = more.frame
        // Playing, the controls fade 3 s after a touch, or after a move to a new stream has started playing.
        // From hidden, a tap on the picture brings them back once the double-tap window has passed; the next
        // tap lands where More stands, and the open menu then holds them up.
        func openMoreFromHidden() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(more.waitForExistence(timeout: 3), "The controls did not come back")
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: moreFrame.midX, dy: moreFrame.midY)).tap()
            XCTAssertTrue(quality.waitForExistence(timeout: 5), "The More menu did not open")
        }
        openMore(in: app)
        XCTAssertTrue(shown().contains("Auto · Original"), "Auto did not start at Original: \(shown())")
        dismissMenu(in: app)
        tap("player.playPause", in: app)
        let playPause = element("player.playPause", in: app)
        XCTAssertTrue(playPause.waitForNonExistence(timeout: 10), "Controls did not hide after the menu closed")

        // A poor link still plays, so Auto goes down to the floor with nothing said and the controls fade as ever.
        notify_post("marquee.uitest.link.poor")
        openMoreFromHidden()
        let atFloor = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in shown().contains("Auto · 4 Mbps 720p") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [atFloor], timeout: 90), .completed, "Auto did not reach the 720p floor: \(shown())")
        dismissMenu(in: app)
        XCTAssertTrue(playPause.waitForNonExistence(timeout: 10), "Controls did not hide at the floor")

        // A wait on the network at the floor is where the warning shows.
        notify_post("marquee.uitest.link.stall")
        let floor = element("player.qualityFloor", in: app)
        XCTAssertTrue(floor.waitForExistence(timeout: 10), "A stall at the floor did not surface the floor warning")
        XCTAssertTrue(playPause.exists, "The warning did not reveal hidden controls")
        XCTAssertFalse(element("player.lowerQuality", in: app).exists)
        try snap("player-43-auto-quality-floor")
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(floor.exists, "The floor warning disappeared while stalled")
        XCTAssertFalse(element("player.lowerQuality", in: app).exists)
        openMore(in: app)
        XCTAssertTrue(shown().contains("Auto · 4 Mbps 720p"), "Auto dropped below the floor while stalled: \(shown())")
        dismissMenu(in: app)

        notify_post("marquee.uitest.link.healthy")
        XCTAssertTrue(floor.waitForNonExistence(timeout: 45), "The floor warning did not clear after recovery")
        XCTAssertTrue(element("player.close", in: app).waitForNonExistence(timeout: 15), "Controls did not hide after recovery")
        openMoreFromHidden()
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
    func testFindSubtitlesFromBazarr() throws {
        try findSubtitlesFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testFindSubtitlesFromBazarrInLightTheme() throws {
        try findSubtitlesFlow(mode: "light", suffix: "paper")
    }

    /// Bazarr out of reach: the same Find English Subtitles goes on to Plex's own agents by itself.
    @MainActor
    func testFindSubtitlesFallsBackToPlex() throws {
        let app = launchPlayer(at: 61, paused: true, mode: "dark", bazarr: "http://bazarr-offline.local:6767")
        tracksMenuRow("Find English Subtitles", in: app).tap()
        let found = subtitleSearch("English subtitles on", in: app)
        XCTAssertTrue(found.waitForExistence(timeout: 30), "Plex's file did not come on: \(element("player.subtitleSearch", in: app).label)")
        XCTAssertTrue(found.label.contains("From Plex"), "The file did not come from Plex: \(found.label)")
        try snap("player-15-subtitles-from-plex-rose-pine")
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

/// Subtitle Style open in the Tracks menu, on a phone on its side and upright. Besides the standard
/// simulator, CI runs these on the smallest and largest iPhone simulators; the shots carry the screen's size.
final class SubtitleStyleMenuScreenshots: XCTestCase {
    @MainActor
    func testStyleMenuLandscape() throws {
        try subtitleStyleMenuFlow(orientation: .landscapeLeft)
    }

    @MainActor
    func testStyleMenuPortrait() throws {
        try subtitleStyleMenuFlow(orientation: .portrait)
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
    func testFindSubtitles() throws {
        try findSubtitlesFlow(mode: "dark", suffix: "ax")
    }

    @MainActor
    func testRouteMenu() throws {
        try routeMenuFlow(orientation: .landscapeLeft, suffix: "ax")
    }
}

private extension XCTestCase {
    /// The Subtitle Style submenu over the picture: its rows inside the screen, and no sheet.
    @MainActor
    func subtitleStyleMenuFlow(orientation: UIDeviceOrientation) throws {
        let app = launchPlayer(at: 61, paused: true, mode: "dark")
        XCUIDevice.shared.orientation = orientation
        defer { XCUIDevice.shared.orientation = .portrait }
        openSubtitleStyle(in: app)
        let screen = app.windows.firstMatch.frame
        for row in ["Look", "Size", "Colour", "Position", "Reveal as Spoken"] {
            let item = menuRow(row, in: app, hasValue: true)
            XCTAssertTrue(item.map { screen.contains($0.frame) } ?? false, "The \(row) row is not on the screen")
        }
        let width = Int(min(screen.width, screen.height)), height = Int(max(screen.width, screen.height))
        let place = orientation.isLandscape ? "landscape" : "portrait"
        try snap("player-33-subtitle-style-\(place)-\(width)x\(height)-rose-pine")
    }

    /// Paused mid-episode: the controls on the phone's side and upright, the audio and subtitles menu
    /// with the subtitle choices on it, the More menu, Playback Info, the episode list and stats for nerds.
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
        XCTAssertTrue(labelled("Off", in: app).waitForExistence(timeout: 5), "The tracks menu does not open on the subtitle choices")
        XCTAssertFalse(labelled("Subtitles…", in: app).exists, "The subtitle choices are behind a row of their own")
        try snap("player-02-tracks-menu-\(suffix)")
        for row in ["English", "Find English Subtitles"] {
            XCTAssertNotNil(menuRow(row, in: app), "No \(row) row in the tracks menu")
        }
        XCTAssertNotNil(menuRow("Subtitle Style", in: app, hasValue: true), "No Subtitle Style row in the tracks menu")
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
        // The rows run to the screen's edge on the side away from the Dynamic Island, with no empty strip.
        XCTAssertGreaterThanOrEqual(playing.frame.maxX, app.windows.firstMatch.frame.maxX - 20, "The rows stop short of the screen edge")
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
    /// the safe area at both ends.
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

    /// Find English Subtitles with Bazarr set up: only Off and English to choose from, Bazarr's best
    /// English file downloaded, listed by Plex and put on screen with the outcome in a banner, then
    /// Reveal as Spoken from Subtitle Style in the same menu, SpeechDock timing the file's lines.
    @MainActor
    func findSubtitlesFlow(mode: String, suffix: String) throws {
        let app = launchPlayer(at: 61, paused: true, mode: mode, bazarr: "http://bazarr.local:6767", speechDock: true)

        tap("player.tracks", in: app)
        XCTAssertTrue(labelled("Off", in: app).waitForExistence(timeout: 5), "The tracks menu did not open")
        let others = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Spanish' OR label BEGINSWITH 'Español' OR label CONTAINS 'SDH'"))
        XCTAssertFalse(others.firstMatch.exists, "The subtitle choices list the file's other tracks")
        let find = menuRow("Find English Subtitles", in: app)
        XCTAssertNotNil(find, "No Find English Subtitles row")
        find?.tap()
        XCTAssertTrue(element("player.subtitleSearch", in: app).waitForExistence(timeout: 5), "No search status over the picture")
        let found = subtitleSearch("English subtitles on", in: app)
        XCTAssertTrue(found.waitForExistence(timeout: 30), "Bazarr's file did not come on: \(element("player.subtitleSearch", in: app).label)")
        XCTAssertTrue(found.label.contains("From Bazarr"), "The file did not come from Bazarr: \(found.label)")
        try snap("player-13-subtitles-found-\(suffix)")

        openSubtitleStyle(in: app)
        try snap("player-14-subtitle-style-\(suffix)")
        let reveal = menuRow("Reveal as Spoken", in: app, hasValue: true)
        XCTAssertNotNil(reveal, "No Reveal as Spoken row")
        reveal?.tap()
        let word = labelled("Word by Word", in: app)
        XCTAssertTrue(word.waitForExistence(timeout: 5), "No Word by Word reveal")
        word.tap()
        XCTAssertTrue(word.waitForExistence(timeout: 2), "Choosing a reveal closed the menu")
        dismissMenu(in: app)
        try snap("player-21-reveal-as-spoken-\(suffix)")
    }

    /// Opens Subtitle Style from the tracks menu: a submenu over the picture, never a sheet.
    @MainActor
    func openSubtitleStyle(in app: XCUIApplication) {
        tap("player.tracks", in: app)
        let style = menuRow("Subtitle Style", in: app, hasValue: true)
        XCTAssertNotNil(style, "No Subtitle Style row in the tracks menu")
        style?.tap()
        XCTAssertNotNil(menuRow("Reveal as Spoken", in: app, hasValue: true), "Subtitle Style did not open in the menu")
        // The page under the player keeps its bar in the tree, so only a bar named for the style would be a sheet.
        XCTAssertFalse(app.navigationBars["Subtitle Style"].exists, "Subtitle Style opened a sheet")
    }

    /// The Find Subtitles banner once its words begin with `title`.
    @MainActor
    func subtitleSearch(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "player.subtitleSearch", title)).firstMatch
    }

    /// Opens the tracks menu and brings the row with `label` into reach.
    @MainActor
    func tracksMenuRow(_ label: String, in app: XCUIApplication) -> XCUIElement {
        tap("player.tracks", in: app)
        let row = menuRow(label, in: app)
        XCTAssertNotNil(row, "No \(label) row in the tracks menu")
        return row ?? labelled(label, in: app)
    }

    /// A row of the open menu by its label, once it can be tapped. A row that `hasValue` may read its
    /// value as part of the label, so only the start is matched.
    @MainActor
    func menuRow(_ label: String, in app: XCUIApplication, hasValue: Bool = false) -> XCUIElement? {
        let row = hasValue ? app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch : labelled(label, in: app)
        // A menu still opening has no rows yet; a drag then would land on the player.
        _ = row.waitForExistence(timeout: 3)
        return scrollMenu(in: app) { row.exists && row.isHittable ? row : nil }
    }

    /// Opens the More menu and returns once its Quality row shows, while the controls are held up: paused,
    /// or waiting on the network.
    @MainActor
    func openMore(in app: XCUIApplication) {
        tap("player.more", in: app)
        let quality = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Quality'")).firstMatch
        XCTAssertTrue(quality.waitForExistence(timeout: 5), "The More menu did not open")
    }

    /// An open menu lays out only the rows that fit on screen. The tracks and More menus hang from the
    /// right of the screen with their first rows at the top, so drags up the middle bring the rest in, held
    /// still before letting go so the menu stops where the drag ends, until `row` finds one that can be tapped.
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
    /// `bazarr` sets up Bazarr at that address; `scrub` holds the scrubber at that fraction; `cast` turns the
    /// Chromecast plugin on with FakeCast's receiver; `stall` keeps playback waiting on data.
    @MainActor
    func launchPlayer(
        at seconds: Double, paused: Bool, mode: String, introSkipDelay: Int? = nil, bazarr: String? = nil, speechDock: Bool = false,
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
        if let bazarr { arguments += ["-marquee.uitest.bazarr", bazarr] }
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

    /// An item of the More menu, which scrolls on a phone on its side and at accessibility sizes.
    @MainActor
    func moreMenuItem(_ label: String, in app: XCUIApplication) -> XCUIElement {
        menuRow(label, in: app) ?? labelled(label, in: app)
    }
}
