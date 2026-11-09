import Foundation
import Testing
@testable import MarqueeCore

/// The player waits with its playhead at 774.5 s; checks come every half second on a made-up clock.
struct StallWatchTests {
    static let idle = StallWatch.Run(produced: 780, fetching: false)

    @Test func aRunThatNeitherReadsNorWritesForASecondIsStuck() {
        var watch = StallWatch()
        #expect(watch.check(now: 100, position: 774.5, run: Self.idle) == .network(seconds: 0))
        #expect(watch.check(now: 100.5, position: 774.5, run: Self.idle) == .network(seconds: 0.5))
        #expect(watch.check(now: 101, position: 774.5, run: Self.idle) == .stuck(ahead: 5.5, cause: .idle))
    }

    @Test func aRunStillReadingOrWritingWaitsOnTheNetwork() {
        var watch = StallWatch()
        var verdicts: [StallWatch.Verdict] = []
        for step in 0...20 {
            let now = Double(step) / 2
            // A read waiting on the link for five seconds, then output trickling in between reads.
            let run = step <= 10
                ? StallWatch.Run(produced: 780, fetching: true)
                : StallWatch.Run(produced: 780 + now, fetching: false)
            verdicts.append(watch.check(now: now, position: 774.5, run: run))
        }
        #expect(verdicts == (0...20).map { .network(seconds: Double($0) / 2) })
    }

    @Test func aPlayerSittingOnThirtySecondsOfOutputIsStuck() {
        var watch = StallWatch()
        let run = StallWatch.Run(produced: 810, fetching: true)
        #expect(watch.check(now: 0, position: 774.5, run: run) == .network(seconds: 0))
        #expect(watch.check(now: 0.5, position: 774.5, run: run) == .network(seconds: 0.5))
        #expect(watch.check(now: 1, position: 774.5, run: run) == .stuck(ahead: 35.5, cause: .unplayed))
    }

    @Test func stuckAgainWhereItRestartedGivesUp() {
        var watch = StallWatch()
        _ = watch.check(now: 0, position: 774.5, run: Self.idle)
        #expect(watch.check(now: 1, position: 774.5, run: Self.idle) == .stuck(ahead: 5.5, cause: .idle))
        // The new run played on, then stopped further along: restarted there too.
        let later = StallWatch.Run(produced: 795, fetching: false)
        _ = watch.check(now: 20, position: 790, run: later)
        #expect(watch.check(now: 21, position: 790, run: later) == .stuck(ahead: 5, cause: .idle))
        // The run started there played half a second and stopped.
        watch.resume()
        _ = watch.check(now: 30, position: 790.5, run: later)
        #expect(watch.check(now: 31, position: 790.5, run: later) == .giveUp)
    }

    @Test func aStreamFromTheServerOnlyWaitsOnTheNetwork() {
        var watch = StallWatch()
        #expect(watch.check(now: 0, position: 774.5, run: nil) == .network(seconds: 0))
        #expect(watch.check(now: 30, position: 774.5, run: nil) == .network(seconds: 30))
        watch.resume()
        #expect(watch.check(now: 40, position: 800, run: nil) == .network(seconds: 0))
    }
}
