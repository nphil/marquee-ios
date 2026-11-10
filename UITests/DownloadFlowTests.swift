import XCTest

final class DownloadFlowTests: XCTestCase {
    @MainActor
    func testDownloadAndRemoveOriginal() {
        let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine")
        open(tab: "Library", title: "Movies", in: app)
        reveal("poster.101", in: app).tap()
        tap("detail.download", in: app)
        app.buttons["Original"].tap()
        XCTAssertTrue(app.buttons["Downloaded"].waitForExistence(timeout: 20))

        open(tab: "Home", title: "Home", in: app)
        openSettings(in: app)
        reveal("settings.downloads", in: app).tap()
        tap("downloads.open", in: app)
        waitFor("downloads.row.101", in: app)
        XCTAssertTrue(app.staticTexts["Downloaded · Original"].waitForExistence(timeout: 10))
        app.buttons["Remove Big Buck Bunny"].tap()
        app.buttons["Remove Download"].tap()
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: 10))
    }
}
