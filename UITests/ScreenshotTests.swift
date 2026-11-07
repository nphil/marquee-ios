import XCTest

/// Walks the app in several themes and keeps a screenshot of each screen, so the look can be
/// reviewed without a Mac. Steps and `snap(_:)` are in UITestSupport.swift.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func testRosePineAndLiveSwitch() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        try snap("01-home-rose-pine")
        open(tab: "Library", title: "Movies", in: app)
        try snap("02-library-rose-pine")
        open(tab: "Watchlist", title: "Watchlist", in: app)
        try snap("03-watchlist-rose-pine")
        open(tab: "Search", title: "Search", in: app)
        try snap("04-search-rose-pine")
        open(tab: "Home", title: "Home", in: app)
        openSettings(in: app)
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
        tap("settings.done", in: app)
        waitForBar("Home", in: app)
        try snap("10-home-paper")
    }

    @MainActor
    func testEmber() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "ember")
        try snap("11-home-ember")
        openSettings(in: app)
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
        openSettings(in: app)
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
        openSettings(in: app)
        try snap("20-ax-settings-dawn")
        tap("settings.theme", in: app)
        waitForBar("Appearance", in: app)
        try snap("21-ax-appearance-dawn")
        app.swipeUp()
        try snap("22-ax-grid-dawn")
    }
}
