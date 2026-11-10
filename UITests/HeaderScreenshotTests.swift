import XCTest

/// The header styles (DESIGN §7.1) on Home, the Library and Live TV, at rest and scrolled; the tab bar's
/// scroll behaviours (§7) with the Tab Bar page that chooses them; and the A–Z rail held mid-scrub
/// (§8.2), which CI also shoots on the smallest and largest iPhone, so its shots carry the screen's size.
/// In Rosé Pine and Dawn.
final class HeaderScreenshotTests: XCTestCase {
    @MainActor
    func testSoftRosePine() throws {
        try headerFlow(style: "soft", mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testSoftDawn() throws {
        try headerFlow(style: "soft", mode: "light", suffix: "dawn")
    }

    @MainActor
    func testHardRosePine() throws {
        try headerFlow(style: "hard", mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testHardDawn() throws {
        try headerFlow(style: "hard", mode: "light", suffix: "dawn")
    }

    @MainActor
    func testBlurRosePine() throws {
        try headerFlow(style: "blur", mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testBlurDawn() throws {
        try headerFlow(style: "blur", mode: "light", suffix: "dawn")
    }

    @MainActor
    func testTabBarRosePine() throws {
        try tabBarFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testTabBarDawn() throws {
        try tabBarFlow(mode: "light", suffix: "dawn")
    }

    @MainActor
    func testAlphabetRailRosePine() throws {
        try alphabetRailFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testAlphabetRailDawn() throws {
        try alphabetRailFlow(mode: "light", suffix: "dawn")
    }
}

/// The same with Increase Contrast on and the text at accessibility size 2; CI runs this class in its own
/// pass.
final class HeaderAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testBlur() throws {
        try headerFlow(style: "blur", mode: "light", suffix: "ax-dawn")
    }

    @MainActor
    func testTabBar() throws {
        try tabBarFlow(mode: "light", suffix: "ax-dawn")
    }

    @MainActor
    func testAlphabetRail() throws {
        try alphabetRailFlow(mode: "light", suffix: "ax-dawn")
    }
}

extension XCTestCase {
    /// Home, the Movies grid and the Live TV guide under one header style, each at rest and scrolled. Each
    /// page scrolls back up before the next tab, so the tab bar is full size again.
    @MainActor
    func headerFlow(style: String, mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", headerStyle: style)
        waitFor("poster.102", in: app)
        try snap("header-\(style)-01-home-\(suffix)")
        app.swipeUp(velocity: .slow)
        try snap("header-\(style)-02-home-scrolled-\(suffix)")
        app.swipeDown(velocity: .fast)
        open(tab: "Library", title: "Movies", in: app)
        waitFor("poster.101", in: app)
        try snap("header-\(style)-03-library-\(suffix)")
        app.swipeUp(velocity: .slow)
        try snap("header-\(style)-04-library-scrolled-\(suffix)")
        app.swipeDown(velocity: .fast)
        open(tab: "Live TV", title: "Live TV", in: app)
        waitFor("livetv.row.ch-0201", in: app)
        try snap("header-\(style)-05-livetv-\(suffix)")
        app.swipeUp(velocity: .slow)
        try snap("header-\(style)-06-livetv-scrolled-\(suffix)")
    }

    /// Hide on Scroll chosen in Settings › Appearance › Tab Bar, then Home scrolled down with the tab bar away
    /// and back up with it returned; then Home scrolled under Always Show and Minimise on Scroll.
    @MainActor
    func tabBarFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        waitFor("poster.102", in: app)
        openSettings(in: app)
        tap("settings.appearance", in: app)
        waitForBar("Appearance", in: app)
        tap("appearance.tabBar", in: app)
        waitForBar("Tab Bar", in: app)
        try snap("tabbar-00-tabs-\(suffix)")
        reveal("appearance.tabBar.hide", in: app).tap()
        try snap("tabbar-01-on-scroll-\(suffix)")
        goBack(from: "Tab Bar", in: app)
        waitForBar("Appearance", in: app)
        goBack(from: "Appearance", in: app)
        tap("settings.done", in: app)
        XCTAssertTrue(element("settings.done", in: app).waitForNonExistence(timeout: 5), "Settings stayed open")
        app.swipeUp(velocity: .slow)
        app.swipeUp(velocity: .slow)
        try snap("tabbar-02-hide-scrolled-\(suffix)")
        app.swipeDown(velocity: .slow)
        try snap("tabbar-03-hide-scrolled-back-\(suffix)")

        let always = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", tabBar: "always")
        waitFor("poster.102", in: always)
        always.swipeUp(velocity: .slow)
        try snap("tabbar-04-always-scrolled-\(suffix)")

        let minimise = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", tabBar: "minimise")
        waitFor("poster.102", in: minimise)
        minimise.swipeUp(velocity: .slow)
        try snap("tabbar-05-minimise-scrolled-\(suffix)")
    }

    /// The Movies grid with the A–Z rail held on G, as a finger scrubbing it would leave it: the lens and
    /// the callout beside it.
    @MainActor
    func alphabetRailFlow(mode: String, suffix: String) throws {
        let app = launch(
            matchSystem: false,
            fixedMode: mode,
            dark: "rose-pine",
            arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.railScrub", "G"]
        )
        open(tab: "Library", title: "Movies", in: app)
        waitFor("library.alphabetRail", in: app)
        let screen = app.windows.firstMatch.frame
        try snap("library-rail-scrub-\(Int(screen.width))x\(Int(screen.height))-\(suffix)")
    }
}
