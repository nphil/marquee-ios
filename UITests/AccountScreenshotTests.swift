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

    /// Each Settings page in list order, an invalid SpeechDock address, a licence and the sign-out
    /// confirmation.
    @MainActor
    func settingsFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        open(tab: "Settings", title: "Settings", in: app)
        try snap("acct-04-settings-\(suffix)")

        reveal("settings.video", in: app).tap()
        waitForBar("Video & Playback", in: app)
        try snap("acct-05-video-\(suffix)")
        goBack(from: "Video & Playback", in: app)

        reveal("settings.audio", in: app).tap()
        waitForBar("Audio & Subtitles", in: app)
        try snap("acct-06-audio-\(suffix)")
        tap("audio.language", in: app)
        waitForBar("Audio Language", in: app)
        try snap("acct-07-language-\(suffix)")
        goBack(from: "Audio Language", in: app)
        reveal("subtitles.style", in: app).tap()
        waitForBar("Subtitle Style", in: app)
        try snap("acct-08-subtitle-style-\(suffix)")
        goBack(from: "Subtitle Style", in: app)
        goBack(from: "Audio & Subtitles", in: app)

        reveal("settings.speechDock", in: app).tap()
        waitForBar("SpeechDock", in: app)
        flip("speechDock.enabled", in: app)
        tap("speechDock.address", in: app)
        element("speechDock.address", in: app).typeText("speechdock.local\n")
        waitFor("speechDock.invalid", in: app)
        try snap("acct-09-speechdock-\(suffix)")
        goBack(from: "SpeechDock", in: app)

        reveal("settings.notices", in: app).tap()
        waitForBar("Open-Source Notices", in: app)
        try snap("acct-10-notices-\(suffix)")
        tap("notice.marquee", in: app)
        waitForBar("Marquee", in: app)
        try snap("acct-11-licence-\(suffix)")
        goBack(from: "Marquee", in: app)
        goBack(from: "Open-Source Notices", in: app)

        reveal("settings.signOut", in: app).tap()
        waitFor("signOut.confirm", in: app)
        try snap("acct-12-signout-\(suffix)")
    }

    /// The switcher from Settings, Alex's PIN pad, a wrong PIN, then the right one (1234 in the
    /// fixtures), after which Settings shows Alex.
    @MainActor
    func profileFlow(mode: String, suffix: String) throws {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        open(tab: "Settings", title: "Settings", in: app)
        tap("settings.profile", in: app)
        waitForBar("Profiles", in: app)
        try snap("acct-13-profiles-\(suffix)")

        tap("profile.fake-alex", in: app)
        waitForBar("Alex", in: app)
        try snap("acct-14-pin-\(suffix)")
        for digit in [1, 1, 1, 1] { tap("pin.\(digit)", in: app) }
        waitFor("pin.message", in: app)
        try snap("acct-15-pin-wrong-\(suffix)")

        for digit in [1, 2, 3, 4] { tap("pin.\(digit)", in: app) }
        let row = element("settings.profile", in: app)
        let switched = expectation(for: NSPredicate(format: "label CONTAINS %@", "Alex"), evaluatedWith: row)
        wait(for: [switched], timeout: 10)
        try snap("acct-16-settings-alex-\(suffix)")
    }

    /// Waits until a server row has finished checking its addresses.
    @MainActor
    func waitForReach(_ word: String, on identifier: String, in app: XCUIApplication) {
        let row = element(identifier, in: app)
        let settled = expectation(for: NSPredicate(format: "label CONTAINS %@", word), evaluatedWith: row)
        wait(for: [settled], timeout: 15)
    }
}
