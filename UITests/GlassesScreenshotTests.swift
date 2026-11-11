import UIKit
import XCTest

/// The XR glasses plugin against stand-in glasses (`-marquee.uitest.glasses`). The glasses' screen is laid
/// out at 1920×1080, drawn a quarter turn round over the phone and saved upright at that size. The phone's
/// side: the first-connection question, the remote, Home's glasses button and the Settings page.
final class GlassesScreenshotTests: XCTestCase {
    @MainActor
    func testHome() throws {
        let app = launchGlasses()
        waitFor("glasses.rows", in: app)
        try snapGlasses("glasses-01-home")
    }

    @MainActor
    func testHomeEmber() throws {
        let app = launchGlasses(dark: "ember")
        waitFor("glasses.rows", in: app)
        try snapGlasses("glasses-01-home-ember")
    }

    @MainActor
    func testLibrary() throws {
        try pageFlow("library", shot: "glasses-02-library")
    }

    @MainActor
    func testMovie() throws {
        try pageFlow("detail", shot: "glasses-03-movie")
    }

    @MainActor
    func testShow() throws {
        try pageFlow("show", shot: "glasses-04-show")
    }

    @MainActor
    func testSeason() throws {
        try pageFlow("season", shot: "glasses-05-season")
    }

    @MainActor
    func testSearch() throws {
        try pageFlow("search", shot: "glasses-06-search")
    }

    @MainActor
    func testRequests() throws {
        try pageFlow("requests", shot: "glasses-07-requests", arguments: seerr)
    }

    @MainActor
    func testRequest() throws {
        try pageFlow("request", shot: "glasses-08-request", arguments: seerr)
    }

    /// Nothing is downloaded in a UI test, so the page shows its empty state.
    @MainActor
    func testDownloads() throws {
        try pageFlow("downloads", shot: "glasses-09-downloads", loadsRows: false)
    }

    @MainActor
    func testLiveTV() throws {
        try pageFlow("live", shot: "glasses-10-live-tv")
    }

    @MainActor
    func testPlayer() throws {
        let app = launchGlasses(arguments: player)
        waitFor("glasses.player.timeline", in: app)
        try snapGlasses("glasses-11-player")
    }

    @MainActor
    func testTracks() throws {
        let app = launchGlasses(page: "tracks", arguments: player)
        waitFor("glasses.panel", in: app)
        try snapGlasses("glasses-12-tracks")
    }

    @MainActor
    func testOptions() throws {
        let app = launchGlasses(page: "options")
        waitFor("glasses.panel", in: app)
        try snapGlasses("glasses-13-options")
    }

    /// The preview lets every touch through to the remote below it, so the screen drives the glasses as the
    /// thumb would: a swipe moves the focus and a tap opens or plays the focused title.
    @MainActor
    func testRemoteSwipeAndTap() {
        let app = launchGlasses()
        waitFor("glasses.rows", in: app)
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'glasses.tile.' AND selected == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 10), "Nothing has the focus")
        let first = focused.identifier
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        let moved = NSPredicate(format: "exists == true AND identifier != %@", first)
        wait(for: [XCTNSPredicateExpectation(predicate: moved, object: focused)], timeout: 5)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let opened = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'glasses.page.2' OR identifier == 'glasses.player'")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 10), "A tap did not open the focused title")
    }

    @MainActor
    func testFirstConnectionAsks() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine",
                         arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.glasses", "ask"])
        let alert = app.alerts["Use as XR Glasses?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The first connection did not ask")
        try snap("glasses-phone-01-ask")
        alert.buttons["Use as XR Glasses"].tap()
        waitFor("glasses.remote", in: app)
        try snap("glasses-phone-02-remote")
    }

    @MainActor
    func testHomeButtonOpensTheRemote() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine",
                         arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.glasses", "phone"])
        waitFor("glasses.button", in: app)
        XCTAssertFalse(element("glasses.remote", in: app).exists, "The remote is up after the phone app was picked")
        try snap("glasses-phone-03-home-button")
        tap("glasses.button", in: app)
        waitFor("glasses.remote", in: app)
    }

    @MainActor
    func testSettings() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        XCTAssertFalse(element("glasses.button", in: app).exists, "The glasses button shows with no glasses")
        openSettings(in: app)
        reveal("settings.glasses", in: app).tap()
        waitForBar("XR Glasses", in: app)
        XCTAssertFalse(element("glasses.use", in: app).exists, "The plugin is on before Settings turns it on")
        flip("glasses.enabled", in: app)
        waitFor("glasses.use", in: app)
        waitFor("glasses.tilt", in: app)
        try snap("glasses-phone-04-settings")
    }

    private var seerr: [String] { ["-marquee.uitest.seerr", "http://seerr.local:5055"] }

    private var player: [String] {
        [
            "-marquee.uitest.play", "101",
            "-marquee.uitest.playerTime", "1800",
            "-marquee.uitest.paused", "YES",
            "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
        ]
    }

    /// The glasses connect with their screen drawn over the phone; `page` opens one of theirs
    /// (`GlassesNavigator.openForUITest`).
    @MainActor
    private func launchGlasses(page: String? = nil, arguments: [String] = [], dark: String = "rose-pine") -> XCUIApplication {
        var all = ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.glasses", "canvas"] + arguments
        if let page { all += ["-marquee.uitest.glassesPage", page] }
        let app = launch(matchSystem: false, fixedMode: "dark", dark: dark, arguments: all, waitingFor: nil)
        waitFor("glasses.canvas", in: app)
        return app
    }

    /// A page opened over Home, once its rows have loaded.
    @MainActor
    private func pageFlow(_ page: String, shot: String, arguments: [String] = [], loadsRows: Bool = true) throws {
        let app = launchGlasses(page: page, arguments: arguments)
        let opened = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'glasses.page.' AND identifier != 'glasses.page.1'")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 20), "The glasses did not open \(page)")
        if loadsRows { waitFor("glasses.rows", in: app) }
        try snapGlasses(shot)
    }

    /// The preview fits the glasses' screen to the phone's width, centred and turned a quarter clockwise
    /// (`GlassesPreview`); this cuts it out of the phone's screen and turns it upright at 1920×1080.
    @MainActor
    private func snapGlasses(_ name: String) throws {
        Thread.sleep(forTimeInterval: 0.8)
        let screen = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let fit = min(CGFloat(screen.width) / 1080, CGFloat(screen.height) / 1920)
        let box = CGSize(width: (1080 * fit).rounded(), height: (1920 * fit).rounded())
        let crop = CGRect(
            x: ((CGFloat(screen.width) - box.width) / 2).rounded(),
            y: ((CGFloat(screen.height) - box.height) / 2).rounded(),
            width: box.width, height: box.height
        )
        let cut = try XCTUnwrap(screen.cropping(to: crop))
        let image = UIImage(cgImage: cut, scale: 1, orientation: .left)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 1920, height: 1080)
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENS_DIR"] {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
