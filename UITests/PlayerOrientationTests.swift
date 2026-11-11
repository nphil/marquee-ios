import UIKit
import XCTest

/// Video Orientation: its row in Settings, and the two settings that keep the player on its side, opened
/// on a phone held upright. Every other player test runs under Follow Device.
final class PlayerOrientationTests: XCTestCase {
    @MainActor
    func testSettingListsItsChoices() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        openSettings(in: app)
        reveal("settings.video", in: app).tap()
        waitForBar("Video & Playback", in: app)
        // The row's value, at its trailing end, is what opens the list.
        reveal("video.orientation", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        for choice in ["Follow Device", "Start in Landscape", "Lock to Landscape"] {
            XCTAssertTrue(app.buttons[choice].firstMatch.waitForExistence(timeout: 5), "Video Orientation does not offer \(choice)")
        }
        try snap("video-orientation-01-choices-rose-pine")
        app.buttons["Lock to Landscape"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Start in Landscape"].firstMatch.waitForNonExistence(timeout: 5), "The list stayed open")
        try snap("video-orientation-02-chosen-rose-pine")
    }

    @MainActor
    func testStartInLandscapeFollowsThePhoneAfterItsFirstTurn() {
        let app = openPlayer(under: "startInLandscape")
        XCTAssertTrue(screenTurns(sideways: true, in: app), "The player did not open on its side")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(screenTurns(sideways: true, in: app), "The screen left its side as the phone turned to it")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(screenTurns(sideways: false, in: app), "The screen did not turn upright with the phone")
    }

    @MainActor
    func testLockToLandscapeHoldsUntilThePlayerCloses() {
        let app = openPlayer(under: "lockToLandscape")
        XCTAssertTrue(screenTurns(sideways: true, in: app), "The player did not open on its side")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.orientation = .portrait
        XCTAssertFalse(screenTurns(sideways: false, in: app, within: 2), "The screen turned upright with the phone")
        tap("player.close", in: app)
        XCTAssertTrue(screenTurns(sideways: false, in: app), "Closing the player left the screen on its side")
    }
}

extension PlayerOrientationTests {
    /// Opens the player paused on episode 212 with the phone upright, under the Video Orientation whose
    /// raw value is `setting`.
    @MainActor
    func openPlayer(under setting: String) -> XCUIApplication {
        // A failed step ends the test early; the next test still has to start upright.
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine", arguments: [
            "-marquee.fakeSignedIn", "YES",
            "-marquee.uitest.play", "212",
            "-marquee.uitest.playerTime", "61",
            "-marquee.uitest.paused", "YES",
            "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
            "-marquee.uitest.videoOrientation", setting,
        ], waitingFor: nil)
        XCTAssertTrue(element("player.playPause", in: app).waitForExistence(timeout: 20), "The player did not open")
        return app
    }

    /// Whether the screen comes to lie on its side, or upright, within `seconds`. The window's frame is the
    /// screen's as the interface is turned, however the phone is held.
    @MainActor
    func screenTurns(sideways: Bool, in app: XCUIApplication, within seconds: TimeInterval = 10) -> Bool {
        let window = app.windows.firstMatch
        let deadline = Date.now.addingTimeInterval(seconds)
        repeat {
            let frame = window.frame
            if (frame.width > frame.height) == sideways { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date.now < deadline
        return false
    }
}
