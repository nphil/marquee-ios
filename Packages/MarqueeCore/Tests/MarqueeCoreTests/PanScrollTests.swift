import Foundation
import Testing
@testable import MarqueeCore

@Suite("Pan scroll")
struct PanScrollTests {
    /// Drags down `points` in one go, taking the steps it asks for, and returns them.
    private func drag(_ pan: inout PanScroll, dx: Double = 0, dy: Double) -> Int {
        let count = pan.moved(dx: dx, dy: dy)
        pan.took(count)
        return count
    }

    @Test func nothingMovesBeforeTheAxisLocks() {
        var pan = PanScroll()
        #expect(pan.moved(dx: 5, dy: 6) == 0)
        #expect(pan.axis == nil)
        #expect(pan.fraction == 0)
    }

    @Test func contentFollowsTheFingerInProportion() {
        var pan = PanScroll()
        #expect(drag(&pan, dy: 14) == 0)
        #expect(pan.axis == .vertical)
        #expect(abs(pan.fraction - 14.0 / 70) < 1e-9)
        #expect(drag(&pan, dy: 28) == 0)
        #expect(abs(pan.fraction - 28.0 / 70) < 1e-9)
    }

    @Test func theFocusStepsPastHalfAWayAndTheRestIsTheOffset() {
        var pan = PanScroll()
        _ = drag(&pan, dy: 20)
        #expect(drag(&pan, dy: 35) == 0, "Half a step is not yet past the hysteresis")
        #expect(drag(&pan, dy: 40) == 1)
        #expect(pan.taken == 1)
        // The position the page draws is the finger's: one step taken, the rest negative.
        #expect(abs(pan.taken.asDouble + pan.fraction - 40.0 / 70) < 1e-9)
        #expect(pan.fraction < 0)
    }

    @Test func positionNeverJumpsWhenTheFocusSteps() {
        var pan = PanScroll()
        var last = 13.0 / 70
        for dy in stride(from: 13.0, through: 300, by: 1) {
            let count = drag(&pan, dy: dy)
            let drawn = pan.taken.asDouble + pan.fraction
            #expect(abs(drawn - last) < 0.03, "At \(dy) pt after \(count) steps")
            last = drawn
        }
    }

    @Test func acrossIsCoarserThanDown() {
        var across = PanScroll()
        #expect(across.moved(dx: 38, dy: 0) == 1)
        var down = PanScroll()
        #expect(down.moved(dx: 0, dy: 38) == 0)
    }

    @Test func slidingBackStepsBackWithHysteresis() {
        var pan = PanScroll()
        _ = drag(&pan, dy: 20)
        #expect(drag(&pan, dy: 40) == 1)
        // Just under the boundary the finger came over does not flicker back.
        #expect(drag(&pan, dy: 36) == 0)
        #expect(drag(&pan, dy: 30) == -1)
        #expect(pan.taken == 0)
    }

    @Test func aStepRefusedHoldsTheFocusAtTheEnd() {
        var pan = PanScroll()
        _ = drag(&pan, dy: 20)
        #expect(pan.moved(dx: 0, dy: 80) == 1)
        pan.refused(1)
        #expect(pan.fraction == 0)
        #expect(pan.moved(dx: 0, dy: 200) == 0, "A refused direction is not retried every sample")
        #expect(pan.settling() == 0)
        // Back the other way frees it.
        #expect(pan.moved(dx: 0, dy: -40) == -1)
    }

    @Test func liftingSettlesOnTheNearestItem() {
        var pan = PanScroll()
        _ = drag(&pan, dy: 20)
        _ = drag(&pan, dy: 36)
        #expect(pan.settling() == 1)
        _ = drag(&pan, dy: 34)
        #expect(pan.settling() == 0)
    }

    // MARK: Coast

    @Test func aCoastSlowsAtUIScrollViewsRate() {
        let coast = Coast(from: 0, speed: 10)
        // After 100 ms the speed has fallen by .998^100 and 1000 ms by .998^1000.
        #expect(abs(coast.velocity(at: 0.1) / 10 - pow(0.998, 100)) < 1e-9)
        #expect(abs(coast.velocity(at: 1) / 10 - pow(0.998, 1000)) < 1e-9)
    }

    @Test func aCoastGoesAboutHalfItsSpeedInDistance() {
        let coast = Coast(from: 2, speed: 20)
        #expect(abs(coast.distance(at: 100) - 20 / (-1000 * log(0.998))) < 0.15)
        #expect(abs(coast.end - 12) < 0.25)
    }

    @Test func aCoastMovesBothWaysAndStops() {
        let back = Coast(from: 5, speed: -10)
        #expect(back.end < 5)
        #expect(back.velocity(at: back.duration + 1) == 0)
        #expect(back.distance(at: 1000) == back.distance(at: back.duration))
        #expect(Coast(from: 0, speed: 0.1).duration == 0)
    }

    @Test func aHardThrowStopsWithinTheLongestCoast() {
        let coast = Coast(from: 0, speed: 5000)
        #expect(coast.end <= Coast.longest)
        #expect(coast.end > Coast.longest - 0.5)
    }

    @Test func aCoastNeverStepsBackward() {
        let coast = Coast(from: 0, speed: 12)
        var last = -1.0
        for tick in 0...400 {
            let position = coast.position(at: Double(tick) / 120)
            #expect(position >= last)
            last = position
        }
    }

    // MARK: Spring

    @Test func theSpringArrivesWithoutOvershoot() {
        var spring = CriticalSpring(0)
        var highest = 0.0
        for _ in 0..<240 {
            spring.step(toward: 1, omega: 24, dt: 1.0 / 120)
            highest = max(highest, spring.value)
        }
        #expect(highest <= 1 + 1e-9)
        #expect(spring.isSettled(at: 1))
    }

    @Test func theSpringIsTheSameAtAnyFrameRate() {
        var coarse = CriticalSpring(0)
        var fine = CriticalSpring(0)
        coarse.step(toward: 1, omega: 30, dt: 0.1)
        for _ in 0..<100 { fine.step(toward: 1, omega: 30, dt: 0.001) }
        #expect(abs(coarse.value - fine.value) < 1e-6)
        #expect(abs(coarse.velocity - fine.velocity) < 1e-6)
    }

    @Test func aSteadyDriftIsFollowedTwoOverOmegaBehind() {
        var spring = CriticalSpring(0)
        let omega = 60.0
        var target = 0.0
        for _ in 0..<600 {
            target += 3.0 / 120
            spring.step(toward: target, omega: omega, dt: 1.0 / 120)
        }
        #expect(abs((target - spring.value) / 3 - 2 / omega) < 0.006)
    }

    // MARK: Finger prediction

    @Test func theGuessReachesAheadOfAMovingFinger() {
        var track = FingerTrack()
        for tick in 0..<10 { track.add(Double(tick) * 0.1, at: Double(tick) / 120) }
        let last = 0.9
        #expect(abs(track.speed - 12) < 1e-6)
        let guess = track.predicted(at: 9.0 / 120 + 1.0 / 120, lead: 1.0 / 120)!
        #expect(abs(guess - (last + 12 * 2.0 / 120)) < 1e-9)
    }

    @Test func theGuessIsCappedAndStopsWhenReadingsStopComing() {
        var track = FingerTrack()
        track.add(0, at: 0)
        track.add(1, at: 0.01)
        let guess = track.predicted(at: 0.06, lead: 0)!
        #expect(abs(guess - (1 + 100 * FingerTrack.reach)) < 1e-9)
        #expect(track.predicted(at: 5, lead: 0) == 1)
    }

    @Test func aPauseIsNotASlowDrag() {
        var track = FingerTrack()
        track.add(0, at: 0)
        track.add(1, at: 0.01)
        track.add(1.0001, at: 1)
        #expect(abs(track.speed) < 60)
        #expect(FingerTrack().predicted(at: 0, lead: 0) == nil)
    }

    @Test func readingsOutOfOrderAreDropped() {
        var track = FingerTrack()
        track.add(1, at: 1)
        track.add(5, at: 0.5)
        #expect(track.position == 1)
    }

    // MARK: Latency and clocks

    @Test func latencyPercentilesComeFromTheSortedSamples() {
        var stats = LatencyStats()
        #expect(stats.summary == nil)
        for ms in 1...100 { stats.add(Double(ms) / 1000) }
        #expect(stats.median == 0.051)
        #expect(stats.p95 == 0.095)
        #expect(stats.summary == "p50 51 ms · p95 95 ms")
    }

    @Test func latencyKeepsTheLastHundredsOnly() {
        var stats = LatencyStats()
        for _ in 0..<LatencyStats.capacity { stats.add(1) }
        for _ in 0..<LatencyStats.capacity { stats.add(0.01) }
        #expect(stats.p95 == 0.01)
        #expect(stats.count == 2 * LatencyStats.capacity)
        stats.add(-1)
        stats.add(.nan)
        #expect(stats.count == 2 * LatencyStats.capacity)
    }

    @Test func aPingAnswerGivesTheClockOffset() {
        var clock = ClockOffset()
        #expect(clock.hostTime(10) == nil)
        // Sent at 100 by one phone, read at 5000.030 by the other, back at 100.060: half of 60 ms each way.
        clock.add(sent: 100, remote: 5000.030, received: 100.060)
        #expect(abs(clock.offset! - 4900) < 1e-9)
        #expect(abs(clock.hostTime(100)! - 5000) < 1e-9)
    }

    @Test func aDelayedAnswerDoesNotMoveTheOffset() {
        var clock = ClockOffset()
        clock.add(sent: 0, remote: 1000.005, received: 0.010)
        let good = clock.offset!
        clock.add(sent: 1, remote: 1001.5, received: 1.400)
        #expect(clock.offset == good)
        clock.add(sent: 2, remote: 1002.0045, received: 2.009)
        #expect(abs(clock.offset! - 1000) < 1e-9)
    }
}

private extension Int {
    var asDouble: Double { Double(self) }
}
