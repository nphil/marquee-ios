import XCTest

/// Diagnostic Logs (DESIGN §8.12) against the fake ntfy at `https://ntfy.local`: the page empty and set
/// up, the floating report button over Settings, and Report a Problem from it, sent. In Rosé Pine.
final class DiagnosticsScreenshotTests: XCTestCase {
    @MainActor
    func testDiagnosticLogsAndReport() throws {
        let app = try diagnosticsSetUp(mode: "dark", suffix: "rose-pine")
        flip("diagnostics.button", in: app)
        let button = element("report.floating", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No floating report button")
        try snap("diagnostics-03-floating-button-rose-pine")
        button.tap()
        let note = element("report.note", in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 10), "No Report a Problem sheet")
        note.tap()
        note.typeText("The intro kept playing after the countdown.")
        try snap("diagnostics-04-report-rose-pine")
        tap("report.send", in: app)
        XCTAssertTrue(label(containing: "Sent as report", in: app).waitForExistence(timeout: 15), "The report was not sent")
        try snap("diagnostics-05-sent-rose-pine")
    }
}

/// The page with Increase Contrast on and the text at accessibility size 2; CI runs this class in its own
/// pass.
final class DiagnosticsAccessibilityScreenshots: XCTestCase {
    @MainActor
    func testDiagnosticLogs() throws {
        _ = try diagnosticsSetUp(mode: "light", suffix: "ax-dawn")
    }
}

extension XCTestCase {
    /// Opens Diagnostic Logs, snaps it empty, then sets it up with the fake ntfy; Return in the token field
    /// saves and sends the test message.
    @MainActor
    func diagnosticsSetUp(mode: String, suffix: String) throws -> XCUIApplication {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        openSettings(in: app)
        reveal("settings.diagnostics", in: app).tap()
        waitForBar("Diagnostic Logs", in: app)
        try snap("diagnostics-01-empty-\(suffix)")
        for (identifier, text) in [("diagnostics.server", "https://ntfy.local"), ("diagnostics.topic", "marquee-test"), ("diagnostics.token", "\n")] {
            let field = reveal(identifier, in: app)
            field.tap()
            field.typeText(text)
        }
        XCTAssertTrue(
            label(containing: "A test message went to the topic", in: app).waitForExistence(timeout: 15),
            "The test message was not sent"
        )
        try snap("diagnostics-02-set-up-\(suffix)")
        return app
    }

    func label(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}
