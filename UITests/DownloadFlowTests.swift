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
        let play = app.buttons["downloads.play.101"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Saved download has no Play button")
        XCTAssertTrue(play.label.contains("Original"), "The row does not say how the download was made")
        try snap("downloads-\(mode)")

        tap("downloads.select", in: app)
        tap("downloads.row.101", in: app)
        XCTAssertTrue(app.buttons["Remove 1 download"].waitForExistence(timeout: 10), "Ticking a download did not enable Remove")
        try snap("downloads-select-\(mode)")
        tap("downloads.select", in: app)

        play.tap()
        waitFor("player", in: app)
        // The controls, title included, are up while the player loads and hide 3 s into playback, sooner
        // than a lookup is sure to catch them. Once they have hidden, one tap on the picture brings them
        // back and the next is the pause, with no lookup between the two to outlast them. Paused, they stay
        // up for the title and the close button.
        XCTAssertTrue(element("player.close", in: app).waitForNonExistence(timeout: 15), "The controls did not hide")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        element("player.playPause", in: app).tap()
        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.title' AND label CONTAINS 'Big Buck Bunny'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Saved title is not shown in the player")
        tap("player.close", in: app)
        waitFor("downloads.row.101", in: app)

        app.buttons["More for Big Buck Bunny"].tap()
        app.buttons["Remove Download"].tap()
        XCTAssertTrue(app.staticTexts["Remove Download?"].waitForExistence(timeout: 10))
        app.buttons["Remove Download"].tap()
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: 10))
    }
}
