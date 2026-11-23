import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import MarqueeCore

struct RemotePanelGeometryTests {
    private let bounds = CGRect(left: 8, top: 8, right: 808, bottom: 608)
    private let panel = CGRect(left: 100, top: 100, right: 400, bottom: 500)

    @Test func aMoveStopsAtTheBounds() {
        #expect(movePanel(panel, by: CGPoint(x: 10, y: 20), in: bounds) == CGRect(left: 110, top: 120, right: 410, bottom: 520))
        #expect(movePanel(panel, by: CGPoint(x: 1000, y: 0), in: bounds) == CGRect(left: 508, top: 100, right: 808, bottom: 500))
        #expect(movePanel(panel, by: CGPoint(x: -1000, y: -1000), in: bounds) == CGRect(left: 8, top: 8, right: 308, bottom: 408))
    }

    @Test func aResizeMovesOnlyTheHandlesEdgesAndKeepsTheMinimum() {
        let topLeft = PanelHandle(left: true, top: true)
        #expect(resizePanel(panel, handle: topLeft, delta: CGPoint(x: -500, y: -500), bounds: bounds, minSize: 232)
            == CGRect(left: 8, top: 8, right: 400, bottom: 500))
        #expect(resizePanel(panel, handle: topLeft, delta: CGPoint(x: 500, y: 500), bounds: bounds, minSize: 232)
            == CGRect(left: 168, top: 268, right: 400, bottom: 500))
        let bottomRight = PanelHandle(right: true, bottom: true)
        #expect(resizePanel(panel, handle: bottomRight, delta: CGPoint(x: 900, y: 900), bounds: bounds, minSize: 232)
            == CGRect(left: 100, top: 100, right: 808, bottom: 608))
        #expect(resizePanel(panel, handle: bottomRight, delta: CGPoint(x: -900, y: -900), bounds: bounds, minSize: 232)
            == CGRect(left: 100, top: 100, right: 332, bottom: 332))
        #expect(resizePanel(panel, handle: PanelHandle(bottom: true), delta: CGPoint(x: 40, y: 40), bounds: bounds, minSize: 232)
            == CGRect(left: 100, top: 100, right: 400, bottom: 540))
    }

    @Test func theEightHandlesCoverEveryEdgeAndCorner() {
        let corners = PanelHandle.all.filter { [$0.left, $0.top, $0.right, $0.bottom].filter { $0 }.count == 2 }

        #expect(PanelHandle.all.count == 8)
        #expect(PanelHandle.all.allSatisfy { handle in PanelHandle.all.filter { $0 == handle }.count == 1 })
        #expect(corners.count == 4)
    }

    @Test func theOpeningPanelGrowsAwayFromTheOrbIntoTheLargerSide() {
        let bottomRight = CGRect(left: 740, top: 540, right: 796, bottom: 596)
        #expect(defaultPanel(bounds: bounds, orb: bottomRight, width: 380, height: 660) == CGRect(left: 416, top: 8, right: 796, bottom: 608))
        let topLeft = CGRect(left: 16, top: 16, right: 72, bottom: 72)
        #expect(defaultPanel(bounds: bounds, orb: topLeft, width: 380, height: 660) == CGRect(left: 16, top: 8, right: 396, bottom: 608))
        #expect(defaultPanel(bounds: bounds, orb: bottomRight, width: 380, height: 288) == CGRect(left: 416, top: 308, right: 796, bottom: 596))
    }

    @Test func fitPanelPullsARectBackInsideAndGrowsATinyOneToTheMinimum() {
        #expect(fitPanel(CGRect(left: 600, top: 100, right: 980, bottom: 500), in: bounds, minSize: 232)
            == CGRect(left: 428, top: 100, right: 808, bottom: 500))
        #expect(fitPanel(CGRect(left: 100, top: 100, right: 150, bottom: 150), in: bounds, minSize: 232)
            == CGRect(left: 100, top: 100, right: 332, bottom: 332))
        #expect(fitPanel(CGRect(left: 0, top: 0, right: 2000, bottom: 2000), in: bounds, minSize: 232) == bounds)
    }

    @Test func snappingKeepsEveryEdgeOnTheGridAndTheRectNonEmpty() {
        #expect(snapPanel(CGRect(left: 101, top: 103, right: 399, bottom: 501), step: 4) == CGRect(left: 100, top: 104, right: 400, bottom: 500))
        #expect(snapPanel(CGRect(left: 100, top: 100, right: 101, bottom: 101), step: 4) == CGRect(left: 100, top: 100, right: 104, bottom: 104))
    }

    @Test func savedFractionsFollowTheWindowAndRoundTripThroughText() throws {
        let fractions = PanelFractions(rect: panel, in: bounds)
        let back = fractions.rect(in: bounds)
        #expect(abs(back.minX - panel.minX) < 0.01 && abs(back.maxY - panel.maxY) < 0.01)

        let decoded = try #require(PanelFractions(decoding: fractions.encoded))
        #expect(abs(decoded.x - fractions.x) < 1e-4 && abs(decoded.h - fractions.h) < 1e-4)

        let rotated = fractions.rect(in: CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(abs(rotated.width - fractions.w * 600) < 0.01)

        for text in [nil, "", "0.1,0.2,0.3", "a,b,c,d", "0.1,0.1,0,0.5", "0.1,0.1,0.5,-1", "0.1,0.1,inf,0.5"] {
            #expect(PanelFractions(decoding: text) == nil, "\(text ?? "nil")")
        }
    }

    @Test func fractionsAreWrittenWithFourDecimalsAndADot() {
        #expect(PanelFractions(x: 0.5, y: 0.25, w: 0.123456, h: 1).encoded == "0.5000,0.2500,0.1235,1.0000")
    }
}
