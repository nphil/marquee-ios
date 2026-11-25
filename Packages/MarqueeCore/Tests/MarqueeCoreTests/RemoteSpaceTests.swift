import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import MarqueeCore

struct RemoteSpaceTests {
    private let size = CGSize(width: 393, height: 852)

    private func space(keyboardTop: CGFloat? = nil) -> RemoteSpace {
        RemoteSpace(size: size, top: 59, bottom: 34, keyboardTop: keyboardTop)
    }

    @Test func thePanelStaysInsideTheSafeArea() {
        #expect(space().panelBounds == CGRect(x: 16, y: 75, width: 361, height: 852 - 34 - 16 - 75))
    }

    @Test func theKeyboardLiftsThePanelAboveIt() {
        #expect(space(keyboardTop: 500).panelBounds.maxY == 500 - 16)
        #expect(space(keyboardTop: 852).panelBounds == space().panelBounds)
    }

    @Test func aKeyboardCoveringTheWholeAreaLeavesAnEmptyBoundsNotAnInvertedOne() {
        #expect(space(keyboardTop: 40).panelBounds.height == 0)
    }
}
