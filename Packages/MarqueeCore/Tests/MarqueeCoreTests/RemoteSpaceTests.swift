import Foundation
import Testing
@testable import MarqueeCore

struct RemoteSpaceTests {
    private let size = CGSize(width: 393, height: 852)

    private func space(chrome: CGFloat = 0, keyboardTop: CGFloat? = nil) -> RemoteSpace {
        RemoteSpace(size: size, top: 59, bottom: 34, chrome: chrome, keyboardTop: keyboardTop)
    }

    @Test func theButtonRestsInsideTheSafeAreaAboveTheBar() {
        let field = space(chrome: 120).orbField

        #expect(field == CGRect(x: 16, y: 75, width: 361, height: 852 - 120 - 16 - 75))
    }

    @Test func aBarShorterThanTheHomeIndicatorLeavesTheIndicatorClear() {
        let clear: CGFloat = 852 - 34 - 16

        #expect(space(chrome: 0).orbField.maxY == clear)
        #expect(space(chrome: 20).orbField.maxY == clear)
    }

    @Test func theKeyboardLiftsTheButtonAndThePanelAboveIt() {
        let up = space(chrome: 120, keyboardTop: 500)
        let above: CGFloat = 500 - 16

        #expect(up.orbField.maxY == above)
        #expect(up.panelBounds.maxY == above)
        #expect(space(chrome: 120, keyboardTop: 852).panelBounds == space(chrome: 120).panelBounds)
    }

    @Test func thePanelMayCoverTheBar() {
        let bounds = space(chrome: 120).panelBounds

        #expect(bounds == CGRect(x: 16, y: 75, width: 361, height: 852 - 34 - 16 - 75))
    }

    @Test func aKeyboardCoveringTheWholeAreaLeavesAnEmptyFieldNotAnInvertedOne() {
        let covered = space(chrome: 120, keyboardTop: 40)

        #expect(covered.orbField.height == 0)
        #expect(covered.panelBounds.height == 0)
    }

    @Test func spotsRunDownTheFieldsTwoEdges() {
        let place = space(chrome: 120)
        let top = place.orbRect(for: RemoteDock(side: .start, row: 0), size: 48)
        let low = place.orbRect(for: RemoteDock(side: .end, row: RemoteDock.rows - 1), size: 48)

        #expect(top == CGRect(x: 16, y: 75, width: 48, height: 48))
        #expect(low == CGRect(x: 377 - 48, y: place.orbField.maxY - 48, width: 48, height: 48))
    }
}
