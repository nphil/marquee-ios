import UIKit
import XCTest

/// The mini player bar (DESIGN §8.6.1) on the fake server: a film or a live channel minimised from its
/// player, the bar's button and swipes, and the way back. The simulator decodes no video, so the film's
/// backdrop stands in for the picture in the bar as in the player.
final class MiniPlayerTests: XCTestCase {
    @MainActor
    func testFilmMinimisesToTheBarAndOpensAgain() throws {
        try filmFlow(suffix: "rose-pine")
    }

    /// A swipe up on the bar opens the player, a pull down on the picture minimises it again, and a swipe
    /// sideways on the bar stops the playback.
    @MainActor
    func testSwipesOnThePlayerAndTheBar() throws {
        let app = playFilm()
        tap("player.minimise", in: app)
        let bar = element("miniplayer", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Minimising left no bar")

        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: -3)))
        waitFor("player", in: app)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertTrue(element("player", in: app).waitForNonExistence(timeout: 10), "A pull down did not minimise the player")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "The pull down left no bar")

        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "A swipe sideways did not stop the playback")
    }

    /// A channel minimised from the live player plays on in the bar, on every tab; Close stops it and the
    /// guide tunes it again.
    @MainActor
    func testLiveChannelMinimisesToTheBar() throws {
        let app = launch(
            matchSystem: false, fixedMode: "dark", dark: "rose-pine",
            arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.frame", "art/spring-backdrop.jpg"]
        )
        open(tab: "Live TV", title: "Live TV", in: app)
        tap("livetv.row.ch-0201", in: app)
        waitFor("liveplayer", in: app)
        // The controls are up as the channel opens and fade 3 s after it plays; a tap on the picture brings them back.
        if !element("liveplayer.minimise", in: app).waitForExistence(timeout: 5) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        tap("liveplayer.minimise", in: app)
        let bar = element("miniplayer", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Minimising left no bar")
        XCTAssertTrue(element("liveplayer", in: app).waitForNonExistence(timeout: 10), "The live player stayed on screen")
        XCTAssertTrue(
            element("miniplayer.control", in: app).wait(for: \.label, toEqual: "Pause", timeout: 20),
            "The channel did not play on in the bar"
        )
        assertBar(in: app)
        try snap("miniplayer-03-live-rose-pine")

        open(tab: "Home", title: "Home", in: app)
        XCTAssertTrue(bar.exists, "The bar did not follow to the Home tab")
        tap("miniplayer.close", in: app)
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10), "Close left the bar")

        open(tab: "Live TV", title: "Live TV", in: app)
        tap("livetv.row.ch-0201", in: app)
        waitFor("liveplayer", in: app)
    }
}

/// Run by CI with Increase Contrast and an accessibility text size.
final class MiniPlayerAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testBar() throws {
        try filmFlow(suffix: "ax")
    }
}

private extension XCTestCase {
    /// Opens the player paused on Caminandes episode 2, Gran Dillama (`212`), with the phone upright.
    @MainActor
    func playFilm() -> XCUIApplication {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine", arguments: [
            "-marquee.fakeSignedIn", "YES",
            "-marquee.uitest.play", "212",
            "-marquee.uitest.playerTime", "61",
            "-marquee.uitest.paused", "YES",
            "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
        ], waitingFor: nil)
        XCTAssertTrue(element("player.playPause", in: app).waitForExistence(timeout: 20), "The player did not open")
        return app
    }

    /// Minimise leaves the episode in the bar, named and paused where it was; the bar plays it, follows to
    /// another tab, pauses it and opens the player again with a tap, controls up.
    @MainActor
    func filmFlow(suffix: String) throws {
        let app = playFilm()
        tap("player.minimise", in: app)
        let bar = element("miniplayer", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Minimising left no bar")
        XCTAssertTrue(element("player", in: app).waitForNonExistence(timeout: 10), "The player stayed on screen")
        XCTAssertTrue(element("miniplayer.expand", in: app).label.contains("Gran Dillama"), "The bar does not name the episode")
        assertBar(in: app)
        try snap("miniplayer-01-bar-\(suffix)")

        let control = element("miniplayer.control", in: app)
        XCTAssertEqual(control.label, "Play", "The episode did not stay paused")
        control.tap()
        XCTAssertTrue(control.wait(for: \.label, toEqual: "Pause", timeout: 5), "The bar's button did not play the episode")

        open(tab: "Library", title: "Movies", in: app)
        XCTAssertTrue(bar.exists, "The bar did not follow to the Library tab")
        try snap("miniplayer-02-library-\(suffix)")

        // Paused, as a playing picture fades the controls 3 s after the player opens, which can come before
        // the check below.
        control.tap()
        XCTAssertTrue(control.wait(for: \.label, toEqual: "Play", timeout: 5), "The bar's button did not pause the episode")
        tap("miniplayer.expand", in: app)
        waitFor("player", in: app)
        XCTAssertTrue(element("player.minimise", in: app).waitForExistence(timeout: 5), "The player came back without its controls")
    }

    /// The bar sits inside the screen and every button in it is 44 pt or more at any text size.
    @MainActor
    func assertBar(in app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        let frame = element("miniplayer", in: app).frame
        XCTAssertTrue(screen.insetBy(dx: -1, dy: -1).contains(frame), "The bar is not inside the screen: \(frame)")
        for control in ["miniplayer.expand", "miniplayer.control", "miniplayer.close"] {
            let button = element(control, in: app)
            XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable, "\(control) is not on screen")
            XCTAssertGreaterThanOrEqual(min(button.frame.width, button.frame.height), 44, "\(control) is under 44 pt")
        }
    }
}
