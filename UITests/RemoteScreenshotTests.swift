import LumaRemoteFakeTV
import XCTest

/// The LumaTV remote against a fake TV that the test runner serves on loopback: the Settings switch, then
/// pairing by the TV's QR link and the remote itself, in Rosé Pine and Dawn.
final class RemoteScreenshotTests: XCTestCase {
    @MainActor
    func testRemoteRosePine() async throws {
        try await remoteFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testRemoteDawn() async throws {
        try await remoteFlow(mode: "light", suffix: "dawn")
    }

    @MainActor
    func testSettingsSwitch() throws {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine",
                         arguments: ["-marquee.fakeSignedIn", "YES", "--ui-testing-place-home"])
        XCTAssertFalse(element("remote.button", in: app).exists, "The remote is on before Settings turns it on")
        XCTAssertFalse(element("remote.miniBar", in: app).exists)
        openSettings(in: app)
        reveal("settings.remote", in: app).tap()
        waitForBar("LumaTV Remote", in: app)
        flip("remote.enabled", in: app)
        try snap("settings-remote-rose-pine")
        goBack(from: "LumaTV Remote", in: app)
        tap("settings.done", in: app)
        waitFor("remote.miniBar", in: app)
    }

    @MainActor
    func testMiniBarTap() async throws {
        try await remoteAccessFlow(swipe: false)
    }

    @MainActor
    func testMiniBarSwipe() async throws {
        try await remoteAccessFlow(swipe: true)
    }

    @MainActor
    func testHomeButtonChoice() async throws {
        let tv = FakeTV()
        let listener = try await FakeTVListener(tv: tv)
        defer { listener.stop() }
        let link = await tv.pairingLink(host: "127.0.0.1", port: listener.port)
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine",
                         arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.remote", "YES",
                                     "--ui-testing-place-home"])
        waitFor("remote.miniBar", in: app)
        openRemoteSettings(in: app)
        selectRemoteAccess("Home Button", in: app)
        try snap("settings-remote-home-button")
        goBack(from: "LumaTV Remote", in: app)
        tap("settings.done", in: app)
        waitFor("remote.button", in: app)
        XCTAssertFalse(element("remote.miniBar", in: app).exists)
        openRemoteSettings(in: app)
        selectRemoteAccess("Mini Bar", in: app)
        goBack(from: "LumaTV Remote", in: app)
        tap("settings.done", in: app)
        waitFor("remote.miniBar", in: app)
        XCTAssertFalse(element("remote.button", in: app).exists)
        openRemoteSettings(in: app)
        selectRemoteAccess("Home Button", in: app)
        goBack(from: "LumaTV Remote", in: app)
        tap("settings.done", in: app)
        waitFor("remote.button", in: app)
        try snap("remote-home-button")
        tap("remote.button", in: app)
        try await pairAndPressHome(link: link, tv: tv, in: app)
    }

    @MainActor
    func testRemoteHiddenAwayAndWhenPresenceUnknown() {
        for place in ["--ui-testing-place-away", "--ui-testing-place-unknown"] {
            let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine",
                             arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.remote", "YES", place])
            XCTAssertFalse(element("remote.miniBar", in: app).exists, place)
            XCTAssertFalse(element("remote.button", in: app).exists, place)
            openRemoteSettings(in: app)
            waitFor("remote.setup", in: app)
            selectRemoteAccess("Home Button", in: app)
            goBack(from: "LumaTV Remote", in: app)
            tap("settings.done", in: app)
            XCTAssertFalse(element("remote.button", in: app).exists, place)
            app.terminate()
        }
    }
}

/// The remote with Increase Contrast on and the text at accessibility size 2; CI runs this class in its
/// own pass.
final class RemoteAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testRemote() async throws {
        try await remoteFlow(mode: "light", suffix: "ax-dawn")
    }

    @MainActor
    func testMiniBar() async throws {
        try await remoteAccessFlow(swipe: true, suffix: "ax-dawn")
    }

    @MainActor
    func testHomeButton() async throws {
        let tv = FakeTV()
        let listener = try await FakeTVListener(tv: tv)
        defer { listener.stop() }
        let link = await tv.pairingLink(host: "127.0.0.1", port: listener.port)
        let app = launch(matchSystem: false, fixedMode: "light", dark: "rose-pine",
                         arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.remote", "YES",
                                     "--ui-testing-place-home"])
        openRemoteSettings(in: app)
        selectRemoteAccess("Home Button", in: app)
        try snap("settings-remote-home-button-ax-dawn")
        goBack(from: "LumaTV Remote", in: app)
        tap("settings.done", in: app)
        waitFor("remote.button", in: app)
        XCTAssertFalse(element("remote.miniBar", in: app).exists)
        try snap("remote-home-button-ax-dawn")
        tap("remote.button", in: app)
        try await pairAndPressHome(link: link, tv: tv, in: app)
    }
}

extension XCTestCase {
    /// Opens the TV's pairing link in the app as the Camera would, pairs, presses Home and checks that the
    /// TV received it, then opens More.
    @MainActor
    func remoteFlow(mode: String, suffix: String) async throws {
        let tv = FakeTV()
        let listener = try await FakeTVListener(tv: tv)
        defer { listener.stop() }
        let link = await tv.pairingLink(host: "127.0.0.1", port: listener.port)

        let app = launch(
            matchSystem: false, fixedMode: mode, dark: "rose-pine",
            arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.remote", "YES",
                        "--ui-testing-place-home"]
        )
        waitFor("remote.miniBar", in: app)
        try snap("remote-home-\(suffix)")

        app.open(link)
        waitFor("pairing.pair", in: app)
        try snap("remote-pair-\(suffix)")
        tap("pairing.pair", in: app)
        await waitUntil(tv, received: "pair")

        waitFor("remote.dpad", in: app)
        try snap("remote-\(suffix)")
        tap("remote.key.home", in: app)
        await waitUntil(tv, received: "key home tap")

        tap("remote.more", in: app)
        try snap("remote-more-\(suffix)")
    }


    @MainActor
    func openRemoteSettings(in app: XCUIApplication) {
        openSettings(in: app)
        reveal("settings.remote", in: app).tap()
        waitForBar("LumaTV Remote", in: app)
    }

    @MainActor
    func selectRemoteAccess(_ choice: String, in app: XCUIApplication) {
        tap("remote.access", in: app)
        let option = app.buttons[choice].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "No remote access choice \(choice)")
        option.tap()
    }

    @MainActor
    func remoteAccessFlow(swipe: Bool, suffix: String = "rose-pine") async throws {
        let tv = FakeTV()
        let listener = try await FakeTVListener(tv: tv)
        defer { listener.stop() }
        let link = await tv.pairingLink(host: "127.0.0.1", port: listener.port)
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine",
                         arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.remote", "YES",
                                     "--ui-testing-place-home"])
        let bar = element("remote.miniBar", in: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertFalse(element("remote.button", in: app).exists)
        try snap("remote-mini-bar-\(swipe ? "swipe" : "tap")-\(suffix)")
        if swipe { bar.swipeUp() } else { bar.tap() }
        waitFor("remote.close", in: app)
        let grabber = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Sheet Grabber")).firstMatch
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        // The sheet has only the large detent, so a short pull springs back up (a 300 pt pull of the
        // 812 pt sheet did); the grabber goes most of the way down the window.
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(element("remote.close", in: app).waitForNonExistence(timeout: 5))
        waitFor("remote.miniBar", in: app)
        bar.tap()
        try await pairAndPressHome(link: link, tv: tv, in: app)
    }

    @MainActor
    func pairAndPressHome(link: URL, tv: FakeTV, in app: XCUIApplication) async throws {
        waitFor("remote.pair", in: app)
        app.open(link)
        tap("pairing.pair", in: app)
        await waitUntil(tv, received: "pair")
        waitFor("remote.dpad", in: app)
        tap("remote.key.home", in: app)
        await waitUntil(tv, received: "key home tap")
    }
    /// The TV's log is polled rather than awaited, so an entry that never comes fails the test instead
    /// of hanging it.
    @MainActor
    func waitUntil(_ tv: FakeTV, received prefix: String) async {
        var log: [String] = []
        for _ in 0..<100 {
            log = await tv.log
            if log.contains(where: { $0.hasPrefix(prefix) }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The TV never received \"\(prefix)\"; it logged \(log)")
    }
}
