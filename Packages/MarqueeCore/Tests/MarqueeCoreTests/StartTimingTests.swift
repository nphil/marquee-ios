import Foundation
import Testing
@testable import MarqueeCore

struct StartTimingTests {
    @Test func listsStepsInTheOrderReachedAndKeepsTheFirstArrival() {
        let start = ContinuousClock.now
        var timing = StartTiming(start: start)
        #expect(timing.summary == "–")
        timing.mark(.metadata, at: start + .milliseconds(12))
        timing.mark(.queue, at: start + .milliseconds(95))
        timing.mark(.route, at: start + .milliseconds(15))
        timing.mark(.stream, at: start + .milliseconds(15))
        timing.mark(.playing, at: start + .milliseconds(52))
        timing.mark(.metadata, at: start + .milliseconds(400))
        timing.handOff = "lead"

        #expect(timing.milliseconds(.metadata) == 12)
        #expect(timing.milliseconds(.ready) == nil)
        #expect(timing.summary == "metadata 12 · route 15 · stream 15 · playing 52 · queue 95 ms · lead")
    }
}
