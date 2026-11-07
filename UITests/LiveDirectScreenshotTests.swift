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
        let stop = element("liveplayer.stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Channel 2.1 did not play from the tuner")
        try snap("livetv-direct-01-playing-rose-pine")
        XCTAssertTrue(stop.waitForNonExistence(timeout: 6), "The live player's controls did not fade")
        try snap("livetv-direct-02-picture-rose-pine")
    }
}
