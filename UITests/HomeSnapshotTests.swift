import XCTest

/// Home on a relaunch (DESIGN §11): the titles of the last run appear from disk while the server, made
/// slow here, has not answered yet.
final class HomeSnapshotTests: XCTestCase {
    @MainActor
    func testRelaunchShowsLastHomeBeforeTheServerAnswers() throws {
        let signedIn = ["-marquee.fakeSignedIn", "YES", "-marquee.uitest.homeSnapshot", "YES"]
        let first = launch(
            matchSystem: false, fixedMode: "dark", dark: "rose-pine",
            arguments: signedIn + ["-marquee.uitest.homeSnapshotReset", "YES"]
        )
        waitFor("continue.108", in: first)
        // The snapshot is written in the background once the answer decodes.
        Thread.sleep(forTimeInterval: 2)
        first.terminate()

        let second = launch(
            matchSystem: false, fixedMode: "dark", dark: "rose-pine",
            arguments: signedIn + ["-marquee.uitest.serverLatency", "8000"]
        )
        XCTAssertTrue(
            element("continue.108", in: second).waitForExistence(timeout: 4),
            "Home showed no titles before the server answered"
        )
        try snap("home-snapshot-01-relaunch")
        second.terminate()
    }
}
