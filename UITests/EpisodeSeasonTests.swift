import UIKit
import XCTest

final class EpisodeSeasonTests: XCTestCase {
    @MainActor
    func testSwitchingSeasonsShowsOnlySelectedEpisodes() {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine", arguments: [
            "-marquee.fakeSignedIn", "YES",
            "-marquee.uitest.play", "212",
            "-marquee.uitest.playerTime", "61",
            "-marquee.uitest.paused", "YES",
            "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
        ], waitingFor: nil)
        tap("player.episodes", in: app)
        waitFor("player.episode.212", in: app)
        tap("player.episodes.season", in: app)
        let second = app.buttons["Season 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        second.tap()
        waitFor("player.episode.221", in: app)
        XCTAssertFalse(element("player.episode.212", in: app).exists)
        tap("player.episodes.season", in: app)
        let first = app.buttons["Season 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        waitFor("player.episode.212", in: app)
        XCTAssertFalse(element("player.episode.221", in: app).exists)
    }
}
