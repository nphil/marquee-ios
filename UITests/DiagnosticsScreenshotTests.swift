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
        enter("The intro kept playing after the countdown.", into: note)
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
    /// Opens Diagnostic Logs, snaps it empty, then sets it up with the fake ntfy; Return in each field moves to
    /// the next, and in the token field saves and sends the test message.
    @MainActor
    func diagnosticsSetUp(mode: String, suffix: String) throws -> XCUIApplication {
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine")
        openSettings(in: app)
        reveal("settings.diagnostics", in: app).tap()
        waitForBar("Diagnostic Logs", in: app)
        try snap("diagnostics-01-empty-\(suffix)")
        for (identifier, text) in [("diagnostics.server", "https://ntfy.local\n"), ("diagnostics.topic", "marquee-test\n"), ("diagnostics.token", "\n")] {
            enter(text, into: reveal(identifier, in: app))
        }
        // The status is the footer at the end of the list, which exists only once it scrolls in.
        let status = reveal("diagnostics.status", in: app)
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "A test message went to the topic"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 15), .completed, "The test message was not sent: \(status.label)")
        try snap("diagnostics-02-set-up-\(suffix)")
        return app
    }

    /// Types into `field`, tapping it first only when it lacks the keyboard. A tap can land while the list is
    /// still settling and leave the focus where it was, so it is tried twice.
    @MainActor
    func enter(_ text: String, into field: XCUIElement) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<2 where !focused.evaluate(with: field) {
            field.tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 2)
        }
        field.typeText(text)
    }

    func label(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}
