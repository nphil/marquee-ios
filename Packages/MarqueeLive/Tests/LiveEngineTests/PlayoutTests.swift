import Testing
@testable import LiveEngine

struct PlayoutTests {
    @Test func jitterTargetGrowsOnUnderrunsAndDecaysWithoutThem() {
        var target = JitterTarget()
        target.underrun(at: 0)
        #expect(abs(target.seconds - 0.45) < 1e-9)
        for i in 1...5 { target.underrun(at: Double(i)) }
        #expect(target.seconds == JitterTarget.ceiling)
        target.update(at: 30)
        #expect(target.seconds == JitterTarget.ceiling)
        target.update(at: 65)
        #expect(abs(target.seconds - 1.35) < 1e-9)
        for minute in 2...30 { target.update(at: 5 + Double(minute) * 60) }
        #expect(target.seconds == JitterTarget.floor)
    }

    @Test func servoStaysWithinItsBounds() {
        var servo = ClockServo()
        #expect(servo.update(buffered: 0.3, target: 0.3) == .keep)
        servo.reset()
        #expect(rate(servo.update(buffered: 0.35, target: 0.3)) == 1.0025)
        servo.reset()
        #expect(rate(servo.update(buffered: 0.7, target: 0.3)) == 1.005)
        servo.reset()
        #expect(rate(servo.update(buffered: 1.8, target: 0.3)) == 1.02)
        servo.reset()
        #expect(rate(servo.update(buffered: 0.0, target: 0.3)) == 0.995)
        servo.reset()
        #expect(servo.update(buffered: 2.5, target: 0.3) == .reanchor)
    }

    @Test func servoSmoothsAndIgnoresNoise() {
        var servo = ClockServo()
        _ = servo.update(buffered: 0.3, target: 0.3)
        // One late sample moves the smoothed depth a tenth of the way.
        #expect(servo.update(buffered: 0.35, target: 0.3) == .keep)
        #expect(abs((servo.buffered ?? 0) - 0.305) < 1e-9)
    }
}

/// The rate a decision sets, to a millionth.
private func rate(_ decision: ClockServo.Decision) -> Double? {
    guard case .rate(let rate) = decision else { return nil }
    return (rate * 1_000_000).rounded() / 1_000_000
}
