import UIKit
import XCTest

extension XCTestCase {
    /// Launches with the theme settings, header style and tab bar behaviour given as launch arguments, which
    /// override the saved ones, and with the fake Plex of `UITests/FakePlex` in place of plex.tv and the
    /// server. `arguments` choose where the app starts: by default signed in on the fake server, waiting for
    /// `bar`.
    @MainActor
    func launch(
        matchSystem: Bool,
        fixedMode: String,
        dark: String,
        light: String = "rose-pine-dawn",
        headerStyle: String = "soft",
        tabBar: String = "minimise",
        arguments: [String] = ["-marquee.fakeSignedIn", "YES"],
        waitingFor bar: String? = "Home"
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-marquee.theme.matchSystem", matchSystem ? "YES" : "NO",
            "-marquee.theme.fixedMode", fixedMode,
            "-marquee.theme.dark", dark,
            "-marquee.theme.light", light,
            "-marquee.headerStyle", headerStyle,
            "-marquee.tabBar", tabBar,
        ] + arguments
        let fixtures = Bundle(for: type(of: self)).url(forResource: "FakePlex", withExtension: nil)
        XCTAssertNotNil(fixtures, "The test bundle has no FakePlex fixtures")
        app.launchEnvironment["MARQUEE_FAKE_PLEX"] = fixtures?.path
        app.launch()
        if let bar { waitForBar(bar, in: app) }
        return app
    }

    /// The search tab sits apart from the other tabs in its own glass button, which may not be
    /// reported inside the tab bar; hence the fallback to any button with that name.
    @MainActor
    func open(tab: String, title: String, in app: XCUIApplication) {
        var button = app.tabBars.buttons[tab].firstMatch
        if !button.waitForExistence(timeout: 5) {
            button = app.buttons[tab].firstMatch
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "No \(tab) tab")
        button.tap()
        waitForBar(title, in: app)
    }

    /// Settings opens in a sheet from the profile button on Home.
    @MainActor
    func openSettings(in app: XCUIApplication) {
        tap("profile.button", in: app)
        waitForBar("Settings", in: app)
    }

    @MainActor
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func tap(_ identifier: String, in app: XCUIApplication) {
        let target = element(identifier, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "No element \(identifier)")
        target.tap()
    }

    @MainActor
    func waitFor(_ identifier: String, in app: XCUIApplication) {
        XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 10), "No element \(identifier)")
    }

    /// Lists create rows only as they scroll in, so this drags the content until the row can be tapped. The
    /// drag stays above the floating tab bar: in landscape `swipeUp` starts under it and scrolls nothing.
    @MainActor
    func reveal(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let target = element(identifier, in: app)
        let viewport = app.frame.insetBy(dx: 0, dy: 44)
        func isVisible() -> Bool {
            guard target.exists, target.isHittable else { return false }
            let frame = target.frame
            let visible = frame.intersection(viewport)
            return !visible.isNull && visible.width >= min(44, frame.width / 2)
                && visible.height >= min(44, frame.height / 2)
        }
        // One drag covers the span between the navigation bar and the tab bar, so the row count a drag
        // moves does not depend on the screen's height (an inline theme grid is ~20 rows at AX2).
        let tabBar = app.tabBars.firstMatch
        let navBar = app.navigationBars.firstMatch
        let bottom = tabBar.exists ? tabBar.frame.minY - 8 : app.frame.height * 0.9
        let top = (navBar.exists ? navBar.frame.maxY : app.frame.height * 0.15) + 12
        let span = bottom > top + 200 ? (top: top, bottom: bottom) : (top: app.frame.height * 0.25, bottom: app.frame.height * 0.7)
        func point(_ y: CGFloat) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y / app.frame.height))
        }
        for _ in 0..<8 {
            if isVisible() { return target }
            let up = !(target.exists && target.frame.midY < viewport.midY)
            let from = point(up ? span.bottom : span.top)
            let to = point(up ? span.top : span.bottom)
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5), "No element \(identifier)")
        XCTAssertTrue(isVisible(), "Element \(identifier) is not visible in the viewport")
        return target
    }

    /// The back button leads the bar of the page being left.
    @MainActor
    func goBack(from title: String, in app: XCUIApplication) {
        app.navigationBars[title].buttons.element(boundBy: 0).tap()
    }

    /// A tap on a toggle row's label does nothing, so this taps the switch at its trailing end. A tap
    /// while the page is still sliding in can miss, so it taps again until the value changes. A busy
    /// test machine has taken over two seconds to read the new value back.
    @MainActor
    func flip(_ identifier: String, in app: XCUIApplication) {
        let row = element(identifier, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "No element \(identifier)")
        let control = row.switches.firstMatch.exists ? row.switches.firstMatch : row
        let before = control.value as? String ?? ""
        for _ in 0..<3 {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let flipped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: control)
            if XCTWaiter().wait(for: [flipped], timeout: 5) == .completed { return }
        }
        XCTFail("\(identifier) did not flip")
    }

    @MainActor
    func waitForBar(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "No \(title) screen")
    }

    /// Lets the push or tab transition finish before the shot. Each shot is attached to the results
    /// and, when the runner has SCREENS_DIR set (CI passes TEST_RUNNER_SCREENS_DIR), written there.
    @MainActor
    func snap(_ name: String) throws {
        Thread.sleep(forTimeInterval: 0.8)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENS_DIR"] {
            try upright(shot).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// The screen's pixels stay portrait with the phone on its side, so a landscape shot is turned
    /// upright before it is written.
    @MainActor
    private func upright(_ shot: XCUIScreenshot) -> Data {
        let orientation: UIImage.Orientation
        switch XCUIDevice.shared.orientation {
        case .landscapeLeft: orientation = .left
        case .landscapeRight: orientation = .right
        default: return shot.pngRepresentation
        }
        guard let pixels = shot.image.cgImage else { return shot.pngRepresentation }
        let image = UIImage(cgImage: pixels, scale: 1, orientation: orientation)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in image.draw(at: .zero) }
    }
}
