import XCTest

/// The live player on the direct path: the app reads the synthetic tuner of App/Testing/FakeTuner.swift into its own
/// sample-buffer layers, a slate first and then a moving picture with a tone.
final class LiveDirectScreenshotTests: XCTestCase {
    @MainActor
    func testDirectPlayerRosePine() throws {
        let app = launch(
            matchSystem: false, fixedMode: "dark", dark: "rose-pine",
            arguments: ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.fakeTuner", "YES"]
        )
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        open(tab: "Live TV", title: "Live TV", in: app)
        tap("livetv.row.ch-0201", in: app)
        waitFor("liveplayer", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let pause = element("liveplayer.playPause", in: app)
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "Channel 2.1 did not play from the tuner")
        try snap("livetv-direct-01-playing-rose-pine")
        XCTAssertTrue(pause.waitForNonExistence(timeout: 6), "The live player's controls did not fade")
        try snap("livetv-direct-02-picture-rose-pine")

        // Paused, the tuner's stream goes on into the buffer: LIVE offers the way back, and skip back goes
        // back within what the buffer holds.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 3), "The live player's controls did not come back")
        pause.tap()
        let goLive = element("liveplayer.goLive", in: app)
        XCTAssertTrue(goLive.waitForExistence(timeout: 3), "Pause did not leave live")
        try snap("livetv-direct-03-paused-rose-pine")
        goLive.tap()
        XCTAssertTrue(goLive.waitForNonExistence(timeout: 5), "LIVE did not go back to live")
        // LIVE rearms the 3 s fade, so the controls are left to fade and brought back. One snapshot of the
        // screen then answers for skip back and LIVE together, and skip back is tapped where it stood: each
        // further lookup takes over a second of the 3 s on the CI runner.
        XCTAssertTrue(pause.waitForNonExistence(timeout: 6), "The live player's controls did not fade")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let controls = try app.snapshot()
        let skipBack = try XCTUnwrap(frame(of: "liveplayer.skipBack", in: controls), "The live player's controls did not come back")
        XCTAssertNil(frame(of: "liveplayer.goLive", in: controls), "LIVE did not go back to live")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: skipBack.midX, dy: skipBack.midY)).tap()
        XCTAssertTrue(goLive.waitForExistence(timeout: 5), "Skip back did not go back in the buffer")
        try snap("livetv-direct-04-behind-rose-pine")
    }

    /// Where the element with `identifier` stands in a snapshot, if it holds one.
    @MainActor
    private func frame(of identifier: String, in snapshot: any XCUIElementSnapshot) -> CGRect? {
        if snapshot.identifier == identifier { return snapshot.frame }
        for child in snapshot.children {
            if let found = frame(of: identifier, in: child) { return found }
        }
        return nil
    }
}
