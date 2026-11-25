import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import MarqueeCore

struct RemoteLayoutTests {
    private func laidOut(_ width: CGFloat, _ height: CGFloat, visible: Set<RemoteModule> = .all, tray: CGFloat = 0) -> RemoteLayout {
        RemoteLayout(width: width, height: height, visible: visible, tray: tray)
    }

    /// Touching edges do not overlap.
    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    @Test func aTallPanelStacksTheStripsBelowThePad() {
        let layout = laidOut(380, 660)

        #expect(layout.shape == .column)
        #expect(layout.strips.map(\.strip) == RemoteStrip.allCases)
        #expect(layout.strips.first?.rect.minY == layout.pad.maxY + RemoteMetrics.gap)
        #expect(layout.dropped.isEmpty)
    }

    @Test func aWidePanelPutsTheStripsBesideThePadInColumns() {
        let layout = laidOut(700, 340)

        #expect(layout.shape == .row)
        #expect(layout.strips.map(\.strip) == RemoteStrip.allCases)
        #expect(layout.strips.allSatisfy { $0.rect.minX >= layout.pad.maxX + RemoteMetrics.gap })
        #expect(Set(layout.strips.map(\.rect.minX)).count == 2)
    }

    @Test func aSmallPanelShowsOnlyThePad() {
        let layout = laidOut(232, 232)

        #expect(layout.shape == .compact)
        #expect(layout.area == layout.pad)
        #expect(layout.strips.isEmpty)
        #expect(layout.dropped == RemoteModule.allCases.filter { $0 != .pad })
    }

    @Test func theShapeFollowsTheWorkingAreaAtItsThresholds() {
        // A column needs 212 pt below the header: the pad's minimum, a gap and one row of keys.
        #expect(laidOut(300, 280).shape == .compact)
        #expect(laidOut(300, 284).shape == .column)
        // A row needs the area 1.25 times wider than tall, and a pad beside a strip.
        #expect(laidOut(388, 348).shape == .row)
        #expect(laidOut(388, 352).shape == .column)
    }

    @Test func stripsLeaveLeastUsedFirstAsThePanelGetsShorter() {
        let expected: [(CGFloat, [RemoteStrip])] = [
            (560, [.nav, .volume, .channel, .playback, .launchers]),
            (492, [.nav, .volume, .playback, .launchers]),
            (424, [.nav, .volume, .launchers]),
            (356, [.nav, .volume]),
            (288, [.nav]),
        ]

        for (height, strips) in expected {
            #expect(laidOut(300, height).strips.map(\.strip) == strips, "height \(height)")
        }
        #expect(laidOut(300, 424).dropped == [.channel, .playback])
    }

    @Test func onlyTheChosenModulesAreLaidOut() throws {
        let layout = laidOut(380, 660, visible: [.pad, .keyboard, .more])
        let launchers = try #require(layout.strips.first)

        #expect(layout.strips.count == 1)
        #expect(launchers.strip == .launchers)
        #expect(launchers.modules == [.keyboard, .more])
        #expect(launchers.keyRects.count == 2)
        #expect(launchers.moduleRects.map(\.module) == launchers.modules)
        #expect(layout.dropped.isEmpty)
        #expect(laidOut(380, 660, visible: [.pad]).pad == layout.area)
    }

    @Test func aSingleModuleStripOutlinesTheWholeStrip() throws {
        let strip = try #require(laidOut(380, 660).strips.first)

        #expect(strip.keys == 3)
        #expect(strip.keyRects.count == 3)
        #expect(strip.moduleRects == [ModuleRect(module: .nav, rect: strip.rect)])
    }

    @Test func modulesThatDoNotFitAreReportedAsDropped() {
        #expect(laidOut(232, 232, visible: [.pad, .volume]).dropped == [.volume])
    }

    @Test func theTrayTakesRoomFromTheBottom() {
        let plain = laidOut(380, 660)
        let withTray = laidOut(380, 660, tray: RemoteMetrics.tray)

        #expect(withTray.area.maxY == plain.area.maxY - RemoteMetrics.tray)
    }

    @Test func everythingStaysInsideTheAreaOnTheGridWithoutOverlap() {
        for width in stride(from: 232, through: 800, by: 28) {
            for height in stride(from: 232, through: 900, by: 36) {
                for tray in [0, RemoteMetrics.tray] {
                    let layout = laidOut(CGFloat(width), CGFloat(height), tray: tray)
                    let label: Comment = "\(width)x\(height) tray \(tray)"
                    let placed = [layout.pad] + layout.strips.map(\.rect)

                    for rect in placed {
                        #expect(rect.minX >= layout.area.minX && rect.minY >= layout.area.minY, label)
                        #expect(rect.maxX <= layout.area.maxX && rect.maxY <= layout.area.maxY, label)
                    }
                    for strip in layout.strips {
                        for edge in [strip.rect.minX, strip.rect.minY, strip.rect.maxX, strip.rect.maxY] {
                            #expect(edge.truncatingRemainder(dividingBy: RemoteMetrics.grid) == 0, label)
                        }
                    }
                    for a in placed.indices {
                        for b in placed.indices where b > a {
                            #expect(!overlaps(placed[a], placed[b]), label)
                        }
                    }
                }
            }
        }
    }

    @Test func splitDividesARectIntoKeysWithGaps() {
        let strip = CGRect(x: 0, y: 0, width: 192, height: 56)

        #expect(strip.split(3, gap: 12) == [
            CGRect(x: 0, y: 0, width: 56, height: 56),
            CGRect(x: 68, y: 0, width: 56, height: 56),
            CGRect(x: 136, y: 0, width: 56, height: 56),
        ])
        #expect(strip.split(0, gap: 12).isEmpty)
    }

    @Test func savedModulesRoundTripAndAlwaysKeepThePad() {
        #expect(decodeRemoteModules(nil) == .all)
        #expect(decodeRemoteModules("") == [.pad])
        #expect(decodeRemoteModules("volume,nav,bogus") == [.pad, .nav, .volume])
        #expect(encodeRemoteModules([.volume, .pad, .nav]) == "nav,volume")
        #expect(decodeRemoteModules(encodeRemoteModules(.all)) == .all)
    }

    @Test func modulesKeepTheirSavedIdsAndLabels() {
        #expect(RemoteModule.allCases.map(\.rawValue) == ["pad", "nav", "volume", "channel", "playback", "keyboard", "apps", "more"])
        #expect(RemoteModule.nav.label == "Back & home")
        #expect(RemoteStrip.launchers.modules == [.keyboard, .apps, .more])
    }
}
