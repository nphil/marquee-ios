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

struct BigScreenTests {
    private let glassesScreen = DisplayIdentity(pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
    private let tvScreen = DisplayIdentity(pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60, name: "  LG OLED  ")

    @Test func glassesKeepTheirCanvasAndWideMargins() {
        let layout = BigScreenLayout(kind: .glasses, pixelWidth: 3840, pixelHeight: 1080)
        #expect(layout == .glasses)
        #expect(layout.width == 1920 && layout.height == 1080)
        #expect(layout.marginX == 144 && layout.marginY == 88)
        #expect(layout.usesBlackCanvas)
    }

    @Test func aTVKeepsFivePercentSafeMarginsAtAnyResolution() {
        let uhd = BigScreenLayout(kind: .tv, pixelWidth: 3840, pixelHeight: 2160)
        let hd = BigScreenLayout(kind: .tv, pixelWidth: 1920, pixelHeight: 1080)
        #expect(uhd == hd)
        #expect(uhd.width == 1920 && uhd.marginX == 96 && uhd.marginY == 54)
        #expect(!uhd.usesBlackCanvas)
        #expect(uhd.scale(fitting: 3840, 2160) == 2)
    }

    @Test func aTVOfAnotherShapeFillsItWithinLimits() {
        let ultrawide = BigScreenLayout(kind: .tv, pixelWidth: 2560, pixelHeight: 1080)
        #expect(ultrawide.width == 2560)
        #expect(ultrawide.marginX == (ultrawide.width * 0.05).rounded())
        #expect(BigScreenLayout(kind: .tv, pixelWidth: 3440, pixelHeight: 1440).width == 2560)
        #expect(BigScreenLayout(kind: .tv, pixelWidth: 5000, pixelHeight: 1000).width == 2560)
        #expect(BigScreenLayout(kind: .tv, pixelWidth: 1000, pixelHeight: 1000).width == 1440)
        #expect(BigScreenLayout(kind: .tv, pixelWidth: 0, pixelHeight: 0).width == 1920)
    }

    @Test func theQuestionNamesTheDisplayByNameThenSize() {
        #expect(tvScreen.question == "Use Marquee on “LG OLED”?")
        #expect(glassesScreen.question == "Use Marquee on this 1920 × 1080 display?")
        #expect(DisplayIdentity(pixelWidth: 0, pixelHeight: 0, refreshRate: 0).question == "Use Marquee on this display?")
        #expect(DisplayIdentity(pixelWidth: 1080, pixelHeight: 1920, refreshRate: 60).sizeLabel == "1920 × 1080")
    }

    @Test func aRememberedDisplayOverridesThePagesChoice() {
        var memory = DisplayMemory()
        #expect(DisplayOutcome.decide(for: tvScreen, memory: memory, use: .ask, defaultKind: .glasses) == .ask)
        #expect(DisplayOutcome.decide(for: tvScreen, memory: memory, use: .marquee, defaultKind: .tv) == .marquee(.tv))
        #expect(DisplayOutcome.decide(for: tvScreen, memory: memory, use: .mirror, defaultKind: .tv) == .mirror)

        memory.remember(tvScreen, kind: .tv, use: .marquee)
        memory.remember(glassesScreen, kind: .glasses, use: .mirror)
        #expect(DisplayOutcome.decide(for: tvScreen, memory: memory, use: .mirror, defaultKind: .glasses) == .marquee(.tv))
        #expect(DisplayOutcome.decide(for: glassesScreen, memory: memory, use: .marquee, defaultKind: .tv) == .mirror)
    }

    @Test func rememberingReplacesAnAnswerAndNeverKeepsAsk() throws {
        var memory = DisplayMemory()
        memory.remember(tvScreen, kind: .glasses, use: .marquee)
        memory.remember(tvScreen, kind: .tv, use: .marquee)
        memory.remember(glassesScreen, kind: .glasses, use: .ask)
        #expect(memory.displays.count == 1)
        #expect(memory.entry(for: tvScreen)?.kind == .tv)
        #expect(memory.entry(for: tvScreen)?.summary == "TV · Marquee’s screen")

        let copy = try JSONDecoder().decode(DisplayMemory.self, from: JSONEncoder().encode(memory))
        #expect(copy == memory)
        memory.forget(key: tvScreen.key)
        #expect(memory.displays.isEmpty)
    }

    @Test func theSavedGlassesAnswerStillReads() {
        #expect(BigScreenUse(rawValue: "glasses") == .marquee)
        #expect(BigScreenUse.allCases.map(\.title) == ["Ask", "Use Marquee’s TV Screen", "Mirror"])
    }
}
