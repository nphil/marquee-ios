import XCTest

/// Sign-in, the plex.tv/link code and the server list against the fake plex.tv, in Rosé Pine and Dawn.
final class AccountScreenshotTests: XCTestCase {
    @MainActor
    func testSignInRosePine() throws {
        try signInFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testSignInDawn() throws {
        try signInFlow(mode: "light", suffix: "dawn")
    }
}

/// The same screens with Increase Contrast on and the text at accessibility size 2; CI runs this class
/// in its own pass.
final class AccountAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testSignIn() throws {
        try signInFlow(mode: "light", suffix: "ax-dawn")
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

    /// Waits until a server row has finished checking its addresses.
    @MainActor
    func waitForReach(_ word: String, on identifier: String, in app: XCUIApplication) {
        let row = element(identifier, in: app)
        let settled = expectation(for: NSPredicate(format: "label CONTAINS %@", word), evaluatedWith: row)
        wait(for: [settled], timeout: 15)
    }
}
