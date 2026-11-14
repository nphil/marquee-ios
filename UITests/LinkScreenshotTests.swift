import XCTest

/// Linked Phones (DESIGN §8.10) against a stand-in phone, "Anna’s iPhone": Settings and the link code, a
/// scan (`-marquee.uitest.linkScan` stands in for the camera), unlinking, and Home's Control button with
/// what it opens. `-marquee.uitest.linkPeer` links the stand-in, in reach, driving a TV, playing on its own
/// screen, or showing nothing.
final class LinkScreenshotTests: XCTestCase {
    @MainActor
    func testSettingsAndCode() throws {
        try linkSettingsFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testScanConfirmsBeforeLinking() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine",
                         arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.link", "YES",
                                     "-marquee.uitest.linkScan", "YES"])
        openLinkSettings(in: app)
        XCTAssertFalse(element("link.phone", in: app).exists, "A phone is listed before the scan")
        reveal("link.scan", in: app).tap()
        waitFor("link.confirm", in: app)
        XCTAssertEqual(element("link.confirm.title", in: app).label, "Link with Anna’s iPhone?")
        try snap("link-03-confirm")
        tap("link.confirm", in: app)
        waitFor("link.linked", in: app)
        try snap("link-04-linked")
        tap("link.scan.close", in: app)
        let row = element("link.phone", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The new link is not listed")
        XCTAssertEqual(row.label, "Anna’s iPhone, Not connected")
        try snap("link-05-list")
    }

    @MainActor
    func testUnlink() throws {
        let app = launchLinked("idle")
        openLinkSettings(in: app)
        let row = element("link.phone", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The linked phone is not listed")
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Anna’s iPhone, Connected"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [connected], timeout: 10), .completed, "The stand-in did not connect")
        XCTAssertFalse(element("link.control", in: app).exists, "A phone showing nothing offers control")
        row.swipeLeft()
        let unlink = app.buttons["Unlink"].firstMatch
        XCTAssertTrue(unlink.waitForExistence(timeout: 5), "No Unlink action")
        unlink.tap()
        waitFor("link.unlink.confirm", in: app)
        try snap("link-06-unlink")
        tap("link.unlink.confirm", in: app)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "The phone stayed listed")
    }

    /// A swipe on the remote moves the other phone's focus, and its answer comes back as the new title.
    @MainActor
    func testControlATV() throws {
        let app = launchLinked("tv")
        let button = element("link.button", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Home offers no Control button")
        XCTAssertEqual(button.label, "Control Anna’s iPhone")
        try snap("link-07-home-button")
        button.tap()
        let remote = element("glasses.remote", in: app)
        XCTAssertTrue(remote.waitForExistence(timeout: 10), "The remote did not open")
        XCTAssertEqual(remote.label, "Big Buck Bunny")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Big Buck Bunny"), object: remote)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed, "A swipe did not move the other phone's focus")
        try snap("link-08-remote")
        tap("link.done", in: app)
        XCTAssertTrue(remote.waitForNonExistence(timeout: 5), "The remote stayed open")
    }

    @MainActor
    func testControlAPhonePlaying() throws {
        try linkPlayerFlow(mode: "dark", suffix: "rose-pine")
    }
}

/// The same screens with Increase Contrast on and the text at accessibility size 2; CI runs this class
/// in its own pass.
final class LinkAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testSettingsAndCode() throws {
        try linkSettingsFlow(mode: "light", suffix: "ax-dawn")
    }

    @MainActor
    func testControlAPhonePlaying() throws {
        try linkPlayerFlow(mode: "light", suffix: "ax-dawn")
    }
}

private extension XCTestCase {
    /// Signed in with the stand-in phone linked and in reach.
    @MainActor
    func launchLinked(_ mode: String, fixedMode: String = "dark") -> XCUIApplication {
        launch(matchSystem: false, fixedMode: fixedMode, dark: "rose-pine",
               arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.linkPeer", mode])
    }

    @MainActor
    func openLinkSettings(in app: XCUIApplication) {
        openSettings(in: app)
        reveal("settings.link", in: app).tap()
        waitForBar("Linked Phones", in: app)
    }

    @MainActor
    func linkSettingsFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        XCTAssertFalse(element("link.button", in: app).exists, "Home offers control with the plugin off")
        openLinkSettings(in: app)
        XCTAssertFalse(element("link.show", in: app).exists, "The plugin is on before Settings turns it on")
        flip("link.enabled", in: app)
        let show = reveal("link.show", in: app)
        try snap("link-01-settings-\(suffix)")
        show.tap()
        waitFor("link.code", in: app)
        try snap("link-02-code-\(suffix)")
    }

    /// The stand-in plays Sintel on its own screen, so the remote is its few player controls; a pause
    /// comes back from it as Play.
    @MainActor
    func linkPlayerFlow(mode: String, suffix: String) throws {
        let app = launchLinked("phone", fixedMode: mode)
        tap("link.button", in: app)
        let playPause = element("link.playPause", in: app)
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), "The player controls did not open")
        XCTAssertEqual(element("link.title", in: app).label, "Sintel")
        XCTAssertEqual(playPause.label, "Pause")
        waitFor("link.subtitles", in: app)
        waitFor("link.next", in: app)
        let volume = element("link.volume", in: app)
        XCTAssertTrue(volume.waitForExistence(timeout: 10), "The player controls have no volume")
        XCTAssertEqual(volume.value as? String, "50 percent")
        tap("link.volumeUp", in: app)
        let louder = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "56 percent"), object: volume)
        XCTAssertEqual(XCTWaiter().wait(for: [louder], timeout: 5), .completed, "The volume step did not reach the other phone")
        try snap("link-09-player-\(suffix)")
        playPause.tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: playPause)
        XCTAssertEqual(XCTWaiter().wait(for: [paused], timeout: 5), .completed, "The pause did not reach the other phone")
        tap("link.done", in: app)
        XCTAssertTrue(playPause.waitForNonExistence(timeout: 5), "The controls stayed open")
    }
}
