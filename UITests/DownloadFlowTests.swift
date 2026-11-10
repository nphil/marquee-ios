import XCTest

final class DownloadFlowTests: XCTestCase {
    @MainActor
    func testDownloadPlaybackDark() throws {
        try downloadPlayback(mode: "dark")
    }

    @MainActor
    func testDownloadPlaybackLight() throws {
        try downloadPlayback(mode: "light")
    }

    @MainActor
    private func downloadPlayback(mode: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        open(tab: "Library", title: "Movies", in: app)
        reveal("poster.101", in: app).tap()
        tap("detail.download", in: app)
        app.buttons["Original"].tap()
        XCTAssertTrue(app.buttons["Downloaded"].waitForExistence(timeout: 20))

        open(tab: "Home", title: "Home", in: app)
        openSettings(in: app)
        reveal("settings.downloads", in: app).tap()
        tap("downloads.open", in: app)
        waitFor("downloads.row.101", in: app)
        XCTAssertTrue(app.staticTexts["Downloaded · Original"].waitForExistence(timeout: 10))
        try snap("downloads-\(mode)")

        let play = app.buttons["downloads.play.101"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Saved download has no Play button")
        play.tap()
        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.title' AND label CONTAINS 'Big Buck Bunny'")).firstMatch
        if !title.waitForExistence(timeout: 6), !element("player.playPause", in: app).exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Saved title is not shown in the player")
        waitFor("player.playPause", in: app)
        tap("player.close", in: app)
        waitFor("downloads.row.101", in: app)

        app.buttons["Remove Big Buck Bunny"].tap()
        app.buttons["Remove Download"].tap()
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: 10))
    }
}
