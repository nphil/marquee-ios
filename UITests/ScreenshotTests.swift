import XCTest

/// Walks the app in several themes and keeps a screenshot of each screen, so the look can be
/// reviewed without a Mac. Each shot is attached to the results and, when the runner has
/// SCREENS_DIR set (CI passes TEST_RUNNER_SCREENS_DIR), also written there as a PNG.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func testRosePineAndLiveSwitch() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        try snap("01-home-rose-pine")
        open(tab: "Library", title: "Library", in: app)
        try snap("02-library-rose-pine")
        open(tab: "Watchlist", title: "Watchlist", in: app)
        try snap("03-watchlist-rose-pine")
        open(tab: "Search", title: "Search", in: app)
        try snap("04-search-rose-pine")
        open(tab: "Settings", title: "Settings", in: app)
        try snap("05-settings-rose-pine")

        tap("settings.theme", in: app)
        waitForBar("Appearance", in: app)
        try snap("06-appearance-fixed-dark")

        let light = app.segmentedControls.buttons["Light"].firstMatch
        XCTAssertTrue(light.waitForExistence(timeout: 5), "No Dark | Light switch")
        light.tap()
        try snap("07-appearance-fixed-light-grid")

        tap("theme.paper", in: app)
        XCTAssertTrue(element("theme.paper", in: app).isSelected)
        try snap("08-live-switch-paper")

        app.navigationBars["Appearance"].buttons.element(boundBy: 0).tap()
        waitForBar("Settings", in: app)
        try snap("09-settings-paper")
        open(tab: "Home", title: "Home", in: app)
        try snap("10-home-paper")
    }

    @MainActor
    func testEmber() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "ember")
        try snap("11-home-ember")
        open(tab: "Settings", title: "Settings", in: app)
        try snap("12-settings-ember")
        tap("settings.theme", in: app)
        waitForBar("Appearance", in: app)
        try snap("13-appearance-ember")
    }

    /// Matching the system on a light simulator: Rosé Pine Dawn on screen, both slot grids.
    @MainActor
    func testMatchSystemSlots() throws {
        let app = launch(matchSystem: true, fixedMode: "dark", dark: "rose-pine")
        try snap("14-home-dawn")
        open(tab: "Settings", title: "Settings", in: app)
        try snap("15-settings-dawn")
        tap("settings.theme", in: app)
        waitForBar("Appearance", in: app)
        try snap("16-appearance-match-dawn")

        tap("appearance.dark", in: app)
        waitForBar("Dark Themes", in: app)
        try snap("17-grid-dark-on-dawn")
        app.navigationBars["Dark Themes"].buttons.element(boundBy: 0).tap()
        waitForBar("Appearance", in: app)

        tap("appearance.light", in: app)
        waitForBar("Light Themes", in: app)
        try snap("18-grid-light-dawn")
    }

    /// CI runs this on its own in a second pass, with Increase Contrast on and the text size at
    /// accessibility 2, where the theme grid drops to two columns.
    @MainActor
    func testAccessibilitySettings() throws {
        let app = launch(matchSystem: false, fixedMode: "light", dark: "rose-pine")
        try snap("19-ax-home-dawn")
        open(tab: "Settings", title: "Settings", in: app)
        try snap("20-ax-settings-dawn")
        tap("settings.theme", in: app)
        waitForBar("Appearance", in: app)
        try snap("21-ax-appearance-dawn")
        app.swipeUp()
        try snap("22-ax-grid-dawn")
    }

    // MARK: - Steps

    /// Launches with the theme settings given as launch arguments, which override the saved ones, and
    /// with the fake Plex of `UITests/FakePlex` in place of plex.tv and the server.
    @MainActor
    private func launch(matchSystem: Bool, fixedMode: String, dark: String, light: String = "rose-pine-dawn") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-marquee.theme.matchSystem", matchSystem ? "YES" : "NO",
            "-marquee.theme.fixedMode", fixedMode,
            "-marquee.theme.dark", dark,
            "-marquee.theme.light", light,
        ]
        let fixtures = Bundle(for: ScreenshotTests.self).url(forResource: "FakePlex", withExtension: nil)
        XCTAssertNotNil(fixtures, "The test bundle has no FakePlex fixtures")
        app.launchEnvironment["MARQUEE_FAKE_PLEX"] = fixtures?.path
        app.launch()
        waitForBar("Home", in: app)
        return app
    }

    /// The search tab sits apart from the other tabs in its own glass button, which may not be
    /// reported inside the tab bar; hence the fallback to any button with that name.
    @MainActor
    private func open(tab: String, title: String, in app: XCUIApplication) {
        var button = app.tabBars.buttons[tab].firstMatch
        if !button.waitForExistence(timeout: 5) {
            button = app.buttons[tab].firstMatch
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "No \(tab) tab")
        button.tap()
        waitForBar(title, in: app)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let target = element(identifier, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "No element \(identifier)")
        target.tap()
    }

    @MainActor
    private func waitForBar(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "No \(title) screen")
    }

    /// Lets the push or tab transition finish before the shot.
    @MainActor
    private func snap(_ name: String) throws {
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
