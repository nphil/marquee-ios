import XCTest

extension XCTestCase {
    /// Launches with the theme settings given as launch arguments, which override the saved ones, and
    /// with the fake Plex of `UITests/FakePlex` in place of plex.tv and the server. `arguments` choose
    /// where the app starts: by default signed in on the fake server, waiting for `bar`.
    @MainActor
    func launch(
        matchSystem: Bool,
        fixedMode: String,
        dark: String,
        light: String = "rose-pine-dawn",
        arguments: [String] = ["-marquee.fakeSignedIn", "YES"],
        waitingFor bar: String? = "Home"
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-marquee.theme.matchSystem", matchSystem ? "YES" : "NO",
            "-marquee.theme.fixedMode", fixedMode,
            "-marquee.theme.dark", dark,
            "-marquee.theme.light", light,
        ] + arguments
        let fixtures = Bundle(for: type(of: self)).url(forResource: "FakePlex", withExtension: nil)
        XCTAssertNotNil(fixtures, "The test bundle has no FakePlex fixtures")
        app.launchEnvironment["MARQUEE_FAKE_PLEX"] = fixtures?.path
        app.launch()
        if let bar { waitForBar(bar, in: app) }
        return app
    }

    /// The search tab sits apart from the other tabs in its own glass button, which may not be
    /// reported inside the tab bar; hence the fallback to any button with that name.
    @MainActor
    func open(tab: String, title: String, in app: XCUIApplication) {
        var button = app.tabBars.buttons[tab].firstMatch
        if !button.waitForExistence(timeout: 5) {
            button = app.buttons[tab].firstMatch
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "No \(tab) tab")
        button.tap()
        waitForBar(title, in: app)
    }

    @MainActor
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func tap(_ identifier: String, in app: XCUIApplication) {
        let target = element(identifier, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "No element \(identifier)")
        target.tap()
    }

    @MainActor
    func waitFor(_ identifier: String, in app: XCUIApplication) {
        XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 10), "No element \(identifier)")
    }

    @MainActor
    func waitForBar(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "No \(title) screen")
    }

    /// Lets the push or tab transition finish before the shot. Each shot is attached to the results
    /// and, when the runner has SCREENS_DIR set (CI passes TEST_RUNNER_SCREENS_DIR), written there.
    @MainActor
    func snap(_ name: String) throws {
        Thread.sleep(forTimeInterval: 0.8)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENS_DIR"] {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
