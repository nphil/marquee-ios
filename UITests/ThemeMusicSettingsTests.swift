import XCTest

/// Play Theme Music (DESIGN §8.3, §8.7) is on by default with its volume under it; switched off, the volume
/// goes. In Rosé Pine and Dawn.
final class ThemeMusicSettingsTests: XCTestCase {
    @MainActor
    func testThemeMusicSettingRosePine() throws {
        try themeMusicSettingFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testThemeMusicSettingDawn() throws {
        try themeMusicSettingFlow(mode: "light", suffix: "dawn")
    }
}

/// The same with Increase Contrast on and the text at accessibility size 2; CI runs this class in its own
/// pass.
final class ThemeMusicAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testThemeMusicSetting() throws {
        try themeMusicSettingFlow(mode: "light", suffix: "ax-dawn")
    }
}

extension XCTestCase {
    @MainActor
    func themeMusicSettingFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        openSettings(in: app)
        reveal("settings.video", in: app).tap()
        waitForBar("Video & Playback", in: app)
        XCTAssertEqual(reveal("video.playsThemeMusic", in: app).switches.firstMatch.value as? String, "1")
        XCTAssertTrue(reveal("video.themeMusicVolume", in: app).exists, "No volume under Play Theme Music")
        try snap("theme-music-01-setting-\(suffix)")
        flip("video.playsThemeMusic", in: app)
        XCTAssertTrue(
            element("video.themeMusicVolume", in: app).waitForNonExistence(timeout: 5),
            "The volume stayed with theme music off"
        )
        try snap("theme-music-02-off-\(suffix)")
    }
}
