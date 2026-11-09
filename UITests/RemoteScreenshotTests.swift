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
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        XCTAssertFalse(element("remote.button", in: app).exists, "The remote is on before Settings turns it on")
        openSettings(in: app)
        reveal("settings.remote", in: app).tap()
        waitForBar("LumaTV Remote", in: app)
        flip("remote.enabled", in: app)
        try snap("settings-remote-rose-pine")
        goBack(from: "LumaTV Remote", in: app)
        tap("settings.done", in: app)
        waitFor("remote.button", in: app)
    }
}

/// The remote with Increase Contrast on and the text at accessibility size 2; CI runs this class in its
/// own pass.
final class RemoteAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testRemote() async throws {
        try await remoteFlow(mode: "light", suffix: "ax-dawn")
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
            arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.remote", "YES"]
        )
        waitFor("remote.button", in: app)
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
