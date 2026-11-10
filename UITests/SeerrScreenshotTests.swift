import XCTest

final class SeerrScreenshotTests: XCTestCase {
    @MainActor
    func testRequestsDark() throws {
        try seerrFlow(mode: "dark", suffix: "rose-pine")
    }

    @MainActor
    func testRequestsLight() throws {
        try seerrFlow(mode: "light", suffix: "dawn")
    }

    @MainActor
    func testSearch() {
        let app = launchSeerr(mode: "dark")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Wing")
        waitFor("seerr.poster.movie/9101", in: app)
        tap("seerr.poster.movie/9101", in: app)
        XCTAssertTrue(app.buttons["Request"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testSeasonChoices() {
        let app = launchSeerr(mode: "dark")
        tap("seerr.poster.tv/9201", in: app)
        let request = app.buttons["Request"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.tap()
        let seasonOne = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Season 1")).firstMatch
        let seasonTwo = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Season 2")).firstMatch
        XCTAssertTrue(seasonOne.waitForExistence(timeout: 10))
        XCTAssertFalse(seasonOne.isEnabled)
        XCTAssertTrue(seasonTwo.exists)
        XCTAssertTrue(seasonTwo.isEnabled)
        app.buttons["Cancel"].tap()
    }
}

final class SeerrAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testRequests() throws {
        try seerrFlow(mode: "light", suffix: "ax-dawn")
    }
}

private extension XCTestCase {
    @MainActor
    func launchSeerr(mode: String) -> XCUIApplication {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", arguments: [
            "-marquee.fakeSignedIn", "YES",
            "-marquee.tabs", "(home, library, liveTV, requests, search)",
            "-marquee.uitest.seerr", "http://seerr.local:5055",
        ])
        open(tab: "Requests", title: "Requests", in: app)
        waitFor("seerr.poster.movie/9101", in: app)
        return app
    }

    @MainActor
    func seerrFlow(mode: String, suffix: String) throws {
        let app = launchSeerr(mode: mode)
        try snap("seerr-01-discover-\(suffix)")
        tap("seerr.poster.movie/9101", in: app)
        let request = app.buttons["Request"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        try snap("seerr-02-title-\(suffix)")
        request.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        try snap("seerr-03-request-sheet-\(suffix)")
        app.navigationBars.buttons["Request"].firstMatch.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let myRequests = app.buttons["My Requests"].firstMatch
        XCTAssertTrue(myRequests.waitForExistence(timeout: 10))
        myRequests.tap()
        waitFor("seerr.request.502", in: app)
        try snap("seerr-04-my-requests-\(suffix)")
    }
}
