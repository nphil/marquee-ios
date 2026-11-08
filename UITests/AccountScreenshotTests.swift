import XCTest

/// Sign-in, the server list, every Settings page and the profile switcher against the fake Plex, in
/// Rosé Pine and Dawn.
final class AccountScreenshotTests: XCTestCase {
    @MainActor
    func testSignInRosePine() throws {
        try signInFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testSignInDawn() throws {
        try signInFlow(mode: "light", suffix: "dawn")
    }

    @MainActor
    func testSettingsRosePine() throws {
        try settingsFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testSettingsDawn() throws {
        try settingsFlow(mode: "light", suffix: "dawn")
    }

    @MainActor
    func testProfilesRosePine() throws {
        try profileFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testProfilesDawn() throws {
        try profileFlow(mode: "light", suffix: "dawn")
    }
}

/// The same screens with Increase Contrast on and the text at accessibility size 2; CI runs this class
/// in its own pass.
final class AccountAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testSignIn() throws {
        try signInFlow(mode: "light", suffix: "ax-dawn")
    }

    @MainActor
    func testSettings() throws {
        try settingsFlow(mode: "light", suffix: "ax-dawn")
    }

    @MainActor
    func testProfiles() throws {
        try profileFlow(mode: "light", suffix: "ax-dawn")
    }
}

/// The same screens in landscape, in Rosé Pine. Landscape swipes did not scroll the Settings list and
/// UI queries over the landscape switcher timed out on a loaded runner, so Settings and the profiles
/// are walked upright and each page turned for its shot. Every test ends upright, so the classes that
/// follow are not affected.
final class AccountLandscapeScreenshots: XCTestCase {
    @MainActor
    func testSignIn() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try signInFlow(mode: "dark", suffix: "land-rose-pine")
    }

    @MainActor
    func testSettings() throws {
        try settingsFlow(mode: "dark", suffix: "land-rose-pine", turned: true)
    }

    @MainActor
    func testProfiles() throws {
        try profileFlow(mode: "dark", suffix: "land-rose-pine", turned: true)
    }
}

extension XCTestCase {
    /// Sign-in screen, code panel, browser sign-in (the fake approves at once), server list, then Home.
    @MainActor
    func signInFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", arguments: [], waitingFor: nil)
        waitFor("signin.plex", in: app)
        try snap("acct-01-signin-\(suffix)")

        tap("signin.code", in: app)
        waitFor("signin.linkCode", in: app)
        try snap("acct-02-signin-code-\(suffix)")
        tap("signin.cancel", in: app)

        tap("signin.plex", in: app)
        waitForBar("Servers", in: app)
        waitForReach("Offline", on: "server.fake-studio", in: app)
        try snap("acct-03-servers-\(suffix)")

        tap("server.fake-server", in: app)
        waitForBar("Home", in: app)
    }

    /// Each Settings page in list order, SpeechDock's and Bazarr's connection tests, a licence and the
    /// sign-out confirmation; `turned` takes each shot in landscape.
    @MainActor
    func settingsFlow(mode: String, suffix: String, turned: Bool = false) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", arguments: [
            "-marquee.fakeSignedIn", "YES", "-marquee.uitest.bazarr", "http://bazarr.local:6767",
            "-marquee.uitest.speechDock", "http://speechdock.local:8765",
        ])
        openSettings(in: app)
        try snap("acct-04-settings-\(suffix)", turned: turned)

        reveal("settings.video", in: app).tap()
        waitForBar("Video & Playback", in: app)
        try snap("acct-05-video-\(suffix)", turned: turned)
        goBack(from: "Video & Playback", in: app)

        reveal("settings.audio", in: app).tap()
        waitForBar("Audio & Subtitles", in: app)
        try snap("acct-06-audio-\(suffix)", turned: turned)
        tap("audio.language", in: app)
        waitForBar("Audio Language", in: app)
        try snap("acct-07-language-\(suffix)", turned: turned)
        goBack(from: "Audio Language", in: app)
        reveal("subtitles.style", in: app).tap()
        waitForBar("Subtitle Style", in: app)
        try snap("acct-08-subtitle-style-\(suffix)", turned: turned)
        tap("style.preset", in: app)
        let highContrast = app.buttons["High Contrast"]
        XCTAssertTrue(highContrast.waitForExistence(timeout: 5), "No High Contrast preset")
        highContrast.tap()
        try snap("acct-08b-subtitle-high-contrast-\(suffix)", turned: turned)
        goBack(from: "Subtitle Style", in: app)
        goBack(from: "Audio & Subtitles", in: app)

        reveal("settings.speechDock", in: app).tap()
        waitForBar("SpeechDock", in: app)
        tap("speechDock.test", in: app)
        let connected = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Connected · SpeechDock 1.0.0'")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 10), "No SpeechDock version after the connection test")
        try snap("acct-09-speechdock-\(suffix)", turned: turned)
        goBack(from: "SpeechDock", in: app)

        reveal("settings.bazarr", in: app).tap()
        waitForBar("Bazarr", in: app)
        tap("bazarr.test", in: app)
        let linked = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Sonarr 4.0.15.2941 and Radarr 5.26.2.10099 are linked'")).firstMatch
        XCTAssertTrue(linked.waitForExistence(timeout: 10), "No linked Sonarr and Radarr after the connection test")
        try snap("acct-09b-bazarr-\(suffix)", turned: turned)
        goBack(from: "Bazarr", in: app)

        reveal("settings.notices", in: app).tap()
        waitForBar("Open-Source Notices", in: app)
        try snap("acct-10-notices-\(suffix)", turned: turned)
        tap("notice.marquee", in: app)
        waitForBar("Marquee", in: app)
        try snap("acct-11-licence-\(suffix)", turned: turned)
        goBack(from: "Marquee", in: app)
        goBack(from: "Open-Source Notices", in: app)

        reveal("settings.signOut", in: app).tap()
        waitFor("signOut.confirm", in: app)
        try snap("acct-12-signout-\(suffix)", turned: turned)
    }

    /// A shot of the screen as it stands, or turned to landscape for the shot and back after it.
    @MainActor
    func snap(_ name: String, turned: Bool) throws {
        guard turned else { return try snap(name) }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try snap(name)
    }

    /// The switcher from Settings, Alex's PIN pad, a wrong PIN, then the right one (1234 in the
    /// fixtures), after which Settings shows Alex; `turned` takes each shot in landscape.
    @MainActor
    func profileFlow(mode: String, suffix: String, turned: Bool = false) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        openSettings(in: app)
        tap("settings.profile", in: app)
        waitForBar("Profiles", in: app)
        try snap("acct-13-profiles-\(suffix)", turned: turned)

        tap("profile.fake-alex", in: app)
        waitForBar("Alex", in: app)
        try snap("acct-14-pin-\(suffix)", turned: turned)
        for digit in [1, 1, 1, 1] { tap("pin.\(digit)", in: app) }
        waitFor("pin.message", in: app)
        try snap("acct-15-pin-wrong-\(suffix)", turned: turned)

        for digit in [1, 2, 3, 4] { tap("pin.\(digit)", in: app) }
        let row = element("settings.profile", in: app)
        let switched = expectation(for: NSPredicate(format: "label CONTAINS %@", "Alex"), evaluatedWith: row)
        wait(for: [switched], timeout: 10)
        try snap("acct-16-settings-alex-\(suffix)", turned: turned)
    }

    /// Waits until a server row has finished checking its addresses.
    @MainActor
    func waitForReach(_ word: String, on identifier: String, in app: XCUIApplication) {
        let row = element(identifier, in: app)
        let settled = expectation(for: NSPredicate(format: "label CONTAINS %@", word), evaluatedWith: row)
        wait(for: [settled], timeout: 15)
    }
}
