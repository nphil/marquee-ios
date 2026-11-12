import Testing
@testable import MarqueeCore

struct StartRecoveryTests {
    @Test func failedStartIsTriedTwiceMoreThenShownAsFailed() {
        var recovery = StartRecovery()

        let steps = (1...3).map { _ in recovery.failed() }

        #expect(steps == [.retry(after: .seconds(2)), .retry(after: .seconds(5)), .giveUp])
        #expect(StartRecovery.readyDeadline == .seconds(30))
    }

    @Test func playingStartsTheCountOver() {
        var recovery = StartRecovery()
        _ = recovery.failed()
        _ = recovery.failed()

        recovery.reset()

        #expect(recovery.failed() == .retry(after: .seconds(2)))
    }
}
