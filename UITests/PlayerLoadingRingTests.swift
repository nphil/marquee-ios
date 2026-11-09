import XCTest

/// The player's loading screen held at one stage: the arc turning while the wait has no measure, the
/// ring filled while a remux builds its start, and the caption at an accessibility text size.
final class PlayerLoadingRingTests: XCTestCase {
    @MainActor
    func testRingTurnsWhileConnecting() throws {
        try holdLoading(at: "connecting", mode: "dark", caption: "Connecting to ", name: "player-ring-connecting-rose-pine")
    }

    @MainActor
    func testRingFillsWhileBuffering() throws {
        try holdLoading(at: "buffering:0.42", mode: "light", caption: "Buffering 42%", name: "player-ring-buffering-paper")
    }

    @MainActor
    func testCaptionAtAccessibilitySize() throws {
        try holdLoading(at: "preparing", mode: "dark", caption: "is preparing the video", name: "player-ring-preparing-ax", largeText: true)
    }
}

private extension XCTestCase {
    @MainActor
    func holdLoading(at stage: String, mode: String, caption: String, name: String, largeText: Bool = false) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        var arguments = [
            "-marquee.fakeSignedIn", "YES",
            "-marquee.uitest.play", "212",
            "-marquee.uitest.loadStage", stage,
            "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
        ]
        if largeText { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        let app = launch(matchSystem: false, fixedMode: mode, dark: "rose-pine", light: "paper", arguments: arguments, waitingFor: nil)
        let loading = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Loading")).firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 20), "The player did not open on its loading screen")
        let value = loading.value as? String ?? ""
        XCTAssertTrue(value.contains(caption), "The caption read \"\(value)\"")
        try snap(name)
    }
}
