import Foundation
import Testing
@testable import MarqueeCore

struct RemoteJoystickTests {
    /// Holds the stick at a steady lean on a 1 ms clock and lists the milliseconds it stepped at.
    private func lean(_ stick: inout JoystickRepeater, _ dx: CGFloat, _ dy: CGFloat, from: Int, to: Int) -> [(ms: Int, key: DpadKey)] {
        (from...to).compactMap { ms in
            stick.update(now: Double(ms) / 1000, dx: dx, dy: dy).map { (ms, $0) }
        }
    }

    private func gaps(_ steps: [(ms: Int, key: DpadKey)]) -> [Int] {
        let times = steps.dropFirst().map(\.ms)
        return zip(times, times.dropFirst()).map { $1 - $0 }
    }

    @Test func aLeanStepsAtOnceThenWaitsOutTheTvsHoldDelay() {
        var stick = JoystickRepeater()
        let steps = lean(&stick, 0.5, 0, from: 0, to: 300)

        #expect(steps.map(\.ms) == [0, 300])
        #expect(steps.allSatisfy { $0.key == .right })
    }

    @Test func aFirmLeanWaitsLess() {
        var stick = JoystickRepeater()

        #expect(lean(&stick, 0.8, 0, from: 0, to: 140).map(\.ms) == [0, 140])
    }

    @Test func theRepeatRateRisesWithDeflectionFromCrawlToFull() {
        var stick = JoystickRepeater()
        let light = gaps(lean(&stick, 0.3, 0, from: 0, to: 4000))
        #expect(abs(Double(light.reduce(0, +)) / Double(light.count) - 308.5) < 3)

        stick.release()
        let full = gaps(lean(&stick, 1, 0, from: 5000, to: 9000))
        #expect(abs(Double(full.reduce(0, +)) / Double(full.count) - 80) < 1)
        #expect(full.allSatisfy { $0 >= 78 }, "never faster than the fastest rate")
    }

    @Test func theRepeatPeriodFallsSmoothlyFromSlowToFast() {
        #expect(abs(JoystickRepeater.period(strength: 0) - JoystickRepeater.slow) < 1e-9)
        #expect(abs(JoystickRepeater.period(strength: 1) - JoystickRepeater.fast) < 1e-9)
        let periods = (0...10).map { JoystickRepeater.period(strength: CGFloat($0) / 10) }
        #expect(periods == periods.sorted(by: >))
        #expect(JoystickRepeater.strength(JoystickRepeater.deadIn) == 0)
        #expect(JoystickRepeater.strength(1.5) == 1)
    }

    @Test func aStalledFrameYieldsOneStepNotABurst() throws {
        var stick = JoystickRepeater()
        _ = lean(&stick, 1, 0, from: 0, to: 140)

        #expect(stick.update(now: 1.14, dx: 1, dy: 0) == .right)
        let next = try #require(lean(&stick, 1, 0, from: 1141, to: 1400).first)
        #expect((38...42).contains(next.ms - 1140), "next step came \(next.ms - 1140) ms later")
    }

    @Test func theStickLetsGoOnlyBelowTheInnerDeadZone() {
        var stick = JoystickRepeater()

        #expect(stick.update(now: 0, dx: 0.2, dy: 0) == nil)
        #expect(stick.update(now: 0.01, dx: 0.3, dy: 0) == .right)
        #expect(stick.update(now: 0.02, dx: 0.18, dy: 0) == nil)
        #expect(stick.held == .right)
        #expect(stick.update(now: 0.03, dx: 0.1, dy: 0) == nil)
        #expect(stick.held == nil)
        #expect(stick.update(now: 0.04, dx: 0.3, dy: 0) == .right)
    }

    @Test func theStickChangesAxisOnlyWhenTheNewOneLeads() {
        var stick = JoystickRepeater()

        #expect(stick.update(now: 0, dx: 0.5, dy: 0) == .right)
        #expect(stick.update(now: 0.01, dx: 0.5, dy: 0.55) == nil)
        #expect(stick.held == .right)
        #expect(stick.update(now: 0.02, dx: 0.5, dy: 0.7) == .down)
        #expect(stick.update(now: 0.03, dx: -0.5, dy: 0.1) == .left)
    }

    @Test func flippingToTheOppositeArrowIsImmediate() {
        var stick = JoystickRepeater()

        #expect(stick.update(now: 0, dx: -0.5, dy: 0) == .left)
        #expect(stick.update(now: 0.01, dx: 0.3, dy: 0.2) == .right)
    }

    @Test func releasingTheStickRestartsTheHoldDelay() {
        var stick = JoystickRepeater()
        _ = lean(&stick, 0.5, 0, from: 0, to: 500)
        stick.release()

        #expect(stick.held == nil)
        #expect(stick.update(now: 0.6, dx: 0, dy: -0.5) == .up)
        #expect(stick.update(now: 0.7, dx: 0, dy: -0.5) == nil)
    }

    @Test func theDiscMapsATouchToOkOrTheNearestArrow() {
        let radius: CGFloat = 100

        #expect(dpadKey(at: .zero, radius: radius) == .ok)
        #expect(dpadKey(at: CGPoint(x: 41, y: 0), radius: radius) == .ok)
        #expect(dpadKey(at: CGPoint(x: 43, y: 0), radius: radius) == .right)
        #expect(dpadKey(at: CGPoint(x: 10, y: -60), radius: radius) == .up)
        #expect(dpadKey(at: CGPoint(x: -60, y: 20), radius: radius) == .left)
        #expect(dpadKey(at: CGPoint(x: 0, y: 109), radius: radius) == .down)
        #expect(dpadKey(at: CGPoint(x: 0, y: 111), radius: radius) == nil)
    }

    @Test func theThumbDeflectsTheStickInProportionAndStopsAtFullReach() {
        #expect(abs(stickDeflection(thumb: CGPoint(x: 30, y: 0), reach: 60).x - 0.5) < 1e-6)
        let far = stickDeflection(thumb: CGPoint(x: 300, y: 400), reach: 100)
        #expect(abs(far.x - 0.6) < 1e-6 && abs(far.y - 0.8) < 1e-6)
        #expect(stickDeflection(thumb: CGPoint(x: 5, y: 5), reach: 0) == .zero)
    }
}
