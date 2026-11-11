import Foundation
import Testing
@testable import MarqueeCore

struct FocusGridTests {
    @Test func shelvesKeepEachRowsPlace() {
        var grid = FocusGrid(rows: [5, 5])
        #expect(grid.move(.right) == .moved)
        #expect(grid.move(.right) == .moved)
        #expect(grid.move(.down) == .moved)
        #expect(grid.column == 0)
        #expect(grid.column(inRow: 0) == 2)
        #expect(grid.move(.up) == .moved)
        #expect(grid.column == 2)
    }

    @Test func aGridCarriesTheColumnAndReturnsToItAfterAShortRow() {
        var grid = FocusGrid(rows: FocusGrid.gridRows(count: 9, columns: 4), style: .grid)
        #expect(grid.rows == [4, 4, 1])
        grid.focus(row: 0, column: 3)
        #expect(grid.move(.down) == .moved)
        #expect(grid.column == 3)
        #expect(grid.move(.down) == .moved)
        #expect(grid.column == 0)
        #expect(grid.flatIndex == 8)
        #expect(grid.move(.up) == .moved)
        #expect(grid.column == 3)
    }

    @Test func movesPastTheEndsReportTheEdgeAndStay() {
        var grid = FocusGrid(rows: [2])
        #expect(grid.move(.left) == .edge)
        #expect(grid.move(.up) == .edge)
        #expect(grid.move(.right) == .moved)
        #expect(grid.move(.right) == .edge)
        #expect(grid.column == 1)
        var empty = FocusGrid()
        #expect(empty.move(.down) == .edge)
    }

    @Test func emptyRowsArePassedOver() {
        var grid = FocusGrid(rows: [0, 3, 0, 2])
        #expect(grid.row == 1)
        #expect(grid.move(.down) == .moved)
        #expect(grid.row == 3)
        #expect(grid.move(.up) == .moved)
        #expect(grid.row == 1)
    }

    @Test func newCountsKeepTheFocusWhereItStillFits() {
        var grid = FocusGrid(rows: [6, 6])
        grid.focus(row: 1, column: 5)
        grid.update(rows: [6, 3])
        #expect(grid.row == 1)
        #expect(grid.column == 2)
        grid.update(rows: [4])
        #expect(grid.row == 0)
        #expect(grid.column == 2)
    }
}

struct RemoteGestureTests {
    @Test func theAxisLocksAndEachStepNeedsItsDistance() {
        var swipe = SwipeSteps()
        #expect(swipe.moved(dx: 8, dy: 6).isEmpty)
        #expect(swipe.moved(dx: 14, dy: 10).isEmpty)
        #expect(swipe.axis == .horizontal)
        // Locked across: the thumb drifting down moves nothing.
        #expect(swipe.moved(dx: 110, dy: 90) == [.right, .right])
        #expect(swipe.moved(dx: 40, dy: 0) == [.left, .left])
    }

    @Test func aFlickThatTookNoStepMovesOneAndAHardOneCoasts() {
        var swipe = SwipeSteps()
        _ = swipe.moved(dx: 0, dy: -20)
        let soft = swipe.released(vx: 0, vy: -500)
        #expect(soft.step == .up)
        #expect(soft.coast == nil)
        let hard = swipe.released(vx: 0, vy: -2000)
        #expect(hard.coast?.move == .up)
        #expect(SwipeSteps().released(vx: 100, vy: 0).step == nil)
    }

    @Test func aFlickBackAgainstTheStepsDoesNotThrow() {
        var swipe = SwipeSteps()
        _ = swipe.moved(dx: 120, dy: 0)
        let back = swipe.released(vx: -1500, vy: 0)
        #expect(back.step == nil)
        #expect(back.coast == nil)
    }

    @Test func aCoastSlowsDownAndAHarderFlickGoesFurther() {
        #expect(SwipeSteps.coast(speed: 900, step: 52).isEmpty)
        let gentle = SwipeSteps.coast(speed: 1200, step: 52)
        let hard = SwipeSteps.coast(speed: 6000, step: 52)
        #expect(hard.count > gentle.count)
        #expect(hard.count <= SwipeSteps.longestCoast)
        let gaps = zip(hard.dropFirst(), hard).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= SwipeSteps.shortestGap - 1e-9 })
        #expect(gaps.last! > gaps.first!)
    }

    @Test func scrubbingClicksAtDetentsAndOnceAtTheEnd() {
        var scrub = Scrub(at: 95, duration: 7200)
        #expect(scrub.span == Scrub.widestSpan)
        #expect(scrub.slid(2, of: 400) == .none)
        #expect(scrub.slid(4, of: 400) == .detent)
        #expect(scrub.time == 101)
        #expect(scrub.slid(-400, of: 400) == .end)
        #expect(scrub.time == 0)
        #expect(scrub.slid(-500, of: 400) == .none)
    }

    @Test func tiltNudgesTheScrubAndStopsPushingAtAnEnd() {
        var scrub = Scrub(at: 50, duration: 60)
        #expect(scrub.span == 60)
        #expect(scrub.nudge(by: 30) == .end)
        #expect(scrub.time == 60)
        #expect(scrub.nudge(by: -5) == .detent)
        #expect(scrub.time == 55)
    }

    @Test func tiltDoesNothingInsideTheDeadZoneAndCarriesPartSteps() {
        #expect(TiltDrive.level(0.1) == 0)
        #expect(TiltDrive.level(-1) == -1)
        #expect(TiltDrive.level(0.3) > 0)
        var drive = TiltDrive(topRate: 10)
        #expect(drive.steps(at: 0.6, for: 0.05) == 0)
        #expect(drive.steps(at: 0.6, for: 0.05) == 1)
        #expect(drive.steps(at: 0, for: 1) == 0)
        #expect(drive.amount(at: -0.6, for: 2) == -20)
    }
}

struct GlassesChoicesTests {
    @Test func everyHapticCueHasItsOwnShape() {
        let shapes = Set(HapticCue.allCases.map(\.events))
        #expect(shapes.count == HapticCue.allCases.count)
        for event in HapticCue.allCases.flatMap(\.events) {
            #expect((0...1).contains(event.intensity))
            #expect((0...1).contains(event.sharpness))
        }
    }

    @Test func theLetterBoardTypesSpacesOnceAndDeletes() {
        var text = ""
        for key: GlassesKey in [.space, .character("u"), .character("p"), .space, .space, .delete, .delete] {
            text = GlassesKeyboard.type(key, into: text)
        }
        #expect(text == "u")
        #expect(GlassesKeyboard.rows.flatMap { $0 }.count == 38)
    }
}
