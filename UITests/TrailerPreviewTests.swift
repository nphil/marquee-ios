import XCTest

final class TrailerPreviewTests: XCTestCase {
    /// Elephants Dream has a trailer on the fake server. After the dwell it plays over the hero; the
    /// simulator decodes no video, so the fixture frame stands in for it.
    @MainActor
    func testTrailerPlaysInTheHero() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine", arguments: [
            "-marquee.fakeSignedIn", "YES", "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
        ])
        open(tab: "Library", title: "Movies", in: app)
        reveal("poster.105", in: app).tap()
        waitFor("detail.title", in: app)
        XCTAssertFalse(element("detail.trailerPreview", in: app).exists, "The trailer played before the dwell")
        waitFor("detail.trailerPreview", in: app)
        try snap("trailer-01-hero-dark")
    }

    /// The setting is on by default and can be turned off under Video & Playback.
    @MainActor
    func testTheSettingTurnsItOff() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        openSettings(in: app)
        reveal("settings.video", in: app).tap()
        waitForBar("Video & Playback", in: app)
        let toggle = element("video.playsTrailers", in: app)
        XCTAssertEqual(reveal("video.playsTrailers", in: app).switches.firstMatch.value as? String, "1")
        try snap("trailer-02-setting-dark")
        flip("video.playsTrailers", in: app)
        XCTAssertEqual(toggle.switches.firstMatch.value as? String, "0")
    }
}
