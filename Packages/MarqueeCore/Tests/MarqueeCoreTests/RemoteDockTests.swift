import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import MarqueeCore

struct RemoteDockTests {
    private let field = CGRect(x: 16, y: 16, width: 1000, height: 800)
    private let size: CGFloat = 56

    @Test func docksSurviveSavingAndBadValuesAreRejected() {
        #expect(RemoteDock.all.count == 2 * RemoteDock.rows)
        for dock in RemoteDock.all {
            #expect(RemoteDock(decoding: dock.encoded) == dock)
        }
        #expect(RemoteDock.default.encoded == "end:3")
        for text in [nil, "", "middle:2", "end", "end:9", "start:-1", "end:x", "sidebar"] {
            #expect(RemoteDock(decoding: text) == nil, "\(text ?? "nil")")
        }
    }

    @Test func edgeSpotsRunDownTheTwoEdges() {
        #expect(edgeOrigin(field: field, dock: RemoteDock(side: .start, row: 0), size: size) == CGPoint(x: 16, y: 16))
        #expect(edgeOrigin(field: field, dock: RemoteDock(side: .end, row: RemoteDock.rows - 1), size: size)
            == CGPoint(x: 1016 - size, y: 816 - size))
        let middle = edgeOrigin(field: field, dock: RemoteDock(side: .end, row: 2), size: size)
        #expect(abs(middle.y - (16 + (800 - size) / 2)) < 0.01)
    }

    @Test func aDropLandsOnTheNearestSpot() {
        #expect(nearestDock(center: CGPoint(x: 100, y: 790), field: field, size: size) == RemoteDock(side: .start, row: 4))
        #expect(nearestDock(center: CGPoint(x: 900, y: 44), field: field, size: size) == RemoteDock(side: .end, row: 0))
        #expect(nearestDock(center: CGPoint(x: 900, y: 416), field: field, size: size) == RemoteDock(side: .end, row: 2))
    }

    @Test func aDropOutsideTheFieldStaysOnAnEdgeSpot() {
        #expect(nearestDock(center: CGPoint(x: -500, y: -500), field: field, size: size) == RemoteDock(side: .start, row: 0))
        #expect(nearestDock(center: CGPoint(x: 5000, y: 5000), field: field, size: size) == RemoteDock(side: .end, row: 4))
        #expect(nearestDock(center: CGPoint(x: 5000, y: 5000), field: CGRect(x: 0, y: 0, width: 400, height: 40), size: size)
            == RemoteDock(side: .end, row: 0))
    }

    @Test func aFlingProjectsWhereTheOrbWouldRest() {
        let rest = projectedCenter(center: CGPoint(x: 100, y: 100), velocity: CGPoint(x: 1000, y: -500))

        #expect(abs(rest.x - 280) < 0.01)
        #expect(abs(rest.y - 10) < 0.01)
    }

    @Test func aFlungOrbDocksWhereTheProjectionLands() {
        let rest = projectedCenter(center: CGPoint(x: 900, y: 600), velocity: CGPoint(x: -4000, y: 0))

        #expect(nearestDock(center: rest, field: field, size: size) == RemoteDock(side: .start, row: 3))
    }
}
