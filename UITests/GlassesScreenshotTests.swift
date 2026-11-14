import UIKit
import XCTest

/// The big-screen plugin against a stand-in display (`-marquee.uitest.glasses`, glasses unless
/// `-marquee.uitest.glassesDisplay` says `tv:3840x2160`). The screen is laid out on a canvas 1080 high,
/// drawn a quarter turn round over the phone and saved upright at the canvas's size: a 3840×2160 TV lays out
/// as the 1920×1080 canvas it scales from. The phone's side: the first-connection question, the remote,
/// Home's button and the Settings page.
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

    /// The TV's canvas is the theme's own dark one, with 5 % safe margins.
    @MainActor
    func testTVHome() throws {
        let app = launchGlasses(display: tv4K)
        waitFor("glasses.rows", in: app)
        try snapGlasses("tv-01-home")
    }

    @MainActor
    func testTVHomeEmber() throws {
        let app = launchGlasses(dark: "ember", display: tv4K)
        waitFor("glasses.rows", in: app)
        try snapGlasses("tv-01-home-ember")
    }

    /// A wider TV gets a wider canvas of the same height.
    @MainActor
    func testTVUltrawide() throws {
        let app = launchGlasses(display: "tv:2560x1080")
        waitFor("glasses.rows", in: app)
        try snapGlasses("tv-02-ultrawide", canvas: CGSize(width: 2560, height: 1080))
    }

    @MainActor
    func testTVMovie() throws {
        try pageFlow("detail", shot: "tv-03-movie", display: tv4K)
    }

    @MainActor
    func testTVPlayer() throws {
        let app = launchGlasses(arguments: player, display: tv4K)
        waitFor("glasses.player.timeline", in: app)
        try snapGlasses("tv-04-player")
    }

    @MainActor
    func testTVOptions() throws {
        let app = launchGlasses(page: "options", display: tv4K)
        waitFor("glasses.panel", in: app)
        try snapGlasses("tv-05-options")
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
        let app = launchGlasses(page: "search")
        let found = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'glasses.tile.' AND NOT (identifier BEGINSWITH 'glasses.tile.key.')"))
            .firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 20), "The search found nothing")
        try snapGlasses("glasses-06-search")
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
        let alert = app.alerts["Use Marquee on this 1920 × 1080 display?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The first connection did not ask")
        try snap("glasses-phone-01-ask")
        alert.buttons["Use as XR Glasses"].tap()
        waitFor("glasses.remote", in: app)
        try snap("glasses-phone-02-remote")
    }

    /// A TV is asked about by its size, and answering Use as TV puts the remote up for it.
    @MainActor
    func testFirstConnectionAsksOnATV() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine",
                         arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.glasses", "ask",
                                     "-marquee.uitest.glassesDisplay", tv4K])
        let alert = app.alerts["Use Marquee on this 3840 × 2160 display?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The first connection did not ask")
        try snap("tv-phone-01-ask")
        alert.buttons["Use as TV"].tap()
        waitFor("glasses.remote", in: app)
        try snap("tv-phone-02-remote")
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
        waitForBar("Big Screen: XR Glasses & TV", in: app)
        XCTAssertFalse(element("glasses.use", in: app).exists, "The plugin is on before Settings turns it on")
        flip("glasses.enabled", in: app)
        waitFor("glasses.use", in: app)
        waitFor("glasses.kind", in: app)
        waitFor("glasses.tilt", in: app)
        try snap("glasses-phone-04-settings")
    }

    private var tv4K: String { "tv:3840x2160" }

    private var seerr: [String] { ["-marquee.uitest.seerr", "http://seerr.local:5055"] }

    private var player: [String] {
        [
            "-marquee.uitest.play", "212",
            "-marquee.uitest.playerTime", "61",
            "-marquee.uitest.paused", "YES",
            "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
        ]
    }

    /// The glasses connect with their screen drawn over the phone; `page` opens one of theirs
    /// (`GlassesNavigator.openForUITest`).
    @MainActor
    private func launchGlasses(page: String? = nil, arguments: [String] = [], dark: String = "rose-pine", display: String? = nil) -> XCUIApplication {
        var all = ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.glasses", "canvas"] + arguments
        if let display { all += ["-marquee.uitest.glassesDisplay", display] }
        if let page { all += ["-marquee.uitest.glassesPage", page] }
        let app = launch(matchSystem: false, fixedMode: "dark", dark: dark, arguments: all, waitingFor: nil)
        waitFor("glasses.canvas", in: app)
        return app
    }

    /// A page opened over Home, once its rows have loaded.
    @MainActor
    private func pageFlow(_ page: String, shot: String, arguments: [String] = [], loadsRows: Bool = true, display: String? = nil) throws {
        let app = launchGlasses(page: page, arguments: arguments, display: display)
        let opened = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'glasses.page.' AND identifier != 'glasses.page.1'")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 20), "The glasses did not open \(page)")
        if loadsRows { waitFor("glasses.rows", in: app) }
        try snapGlasses(shot)
    }

    /// The preview fits the screen's canvas to the phone's width, centred and turned a quarter clockwise
    /// (`GlassesPreview`); this cuts it out of the phone's screen and turns it upright at the canvas's size.
    @MainActor
    private func snapGlasses(_ name: String, canvas: CGSize = CGSize(width: 1920, height: 1080)) throws {
        Thread.sleep(forTimeInterval: 0.8)
        let screen = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let fit = min(CGFloat(screen.width) / canvas.height, CGFloat(screen.height) / canvas.width)
        let box = CGSize(width: (canvas.height * fit).rounded(), height: (canvas.width * fit).rounded())
        let crop = CGRect(
            x: ((CGFloat(screen.width) - box.width) / 2).rounded(),
            y: ((CGFloat(screen.height) - box.height) / 2).rounded(),
            width: box.width, height: box.height
        )
        let cut = try XCTUnwrap(screen.cropping(to: crop))
        let image = UIImage(cgImage: cut, scale: 1, orientation: .left)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: canvas, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: canvas))
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
