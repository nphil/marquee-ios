import Testing
@testable import MarqueeCore

struct StreamReconnectTests {
    @Test func backsOffThenGivesUpAtTheBudget() {
        var reconnect = StreamReconnect()

        var steps: [StreamReconnect.Step] = []
        var now = 100.0
        for _ in 0..<8 {
            let step = reconnect.failed(now: now)
            steps.append(step)
            guard case .reconnect(_, let after) = step else { break }
            now += Double(after.components.seconds) + Double(after.components.attoseconds) / 1e18 + 0.5
        }

        #expect(steps.prefix(5) == [
            .reconnect(attempt: 1, after: .seconds(1)), .reconnect(attempt: 2, after: .seconds(2)),
            .reconnect(attempt: 3, after: .seconds(4)), .reconnect(attempt: 4, after: .seconds(8)),
            .reconnect(attempt: 5, after: .seconds(8)),
        ])
        #expect(steps.last == .giveUp)
        #expect(now - 100 < 40)
    }

    @Test func aSlowAttemptUsesUpTheBudget() {
        var reconnect = StreamReconnect()
        _ = reconnect.failed(now: 0)

        #expect(reconnect.failed(now: 31) == .giveUp)
    }

    @Test func theLastWaitIsCutToTheBudget() {
        var reconnect = StreamReconnect()
        _ = reconnect.failed(now: 0)

        #expect(reconnect.failed(now: 28) == .reconnect(attempt: 2, after: .seconds(2)))
    }

    @Test func playingForAWhileStartsTheCountOver() {
        var reconnect = StreamReconnect()
        _ = reconnect.failed(now: 0)
        _ = reconnect.failed(now: 2)
        reconnect.landed(at: 600)

        reconnect.playing(at: 610)
        #expect(reconnect.attempts == 2)
        reconnect.playing(at: 621)

        #expect(reconnect.failed(now: 500) == .reconnect(attempt: 1, after: .seconds(1)))
    }

    @Test func aFailureBeforeSettlingKeepsTheCount() {
        var reconnect = StreamReconnect()
        _ = reconnect.failed(now: 0)
        reconnect.landed(at: 600)

        #expect(reconnect.failed(now: 3) == .reconnect(attempt: 2, after: .seconds(2)))
    }

    @Test func onlyRefusalsThatStayAreNotRetried() {
        for status in [401, 403, 404, 410] { #expect(!StreamReconnect.isRetryable(status: status)) }
        for status in [nil, 408, 429, 500, 502, 503] { #expect(StreamReconnect.isRetryable(status: status)) }

        #expect(StreamReconnect.isRetryable(domain: "NSURLErrorDomain", code: -1005))
        #expect(StreamReconnect.isRetryable(domain: "NSPOSIXErrorDomain", code: 5))
        #expect(StreamReconnect.isRetryable(domain: "CoreMediaErrorDomain", code: -12889, comment: "HTTP 503"))
        #expect(!StreamReconnect.isRetryable(domain: "CoreMediaErrorDomain", code: -12938))
        #expect(!StreamReconnect.isRetryable(domain: "NSURLErrorDomain", code: -1100))
        #expect(!StreamReconnect.isRetryable(domain: nil, code: 0, comment: "HTTP 403: Forbidden"))
        #expect(!StreamReconnect.isRetryable(domain: "AVFoundationErrorDomain", code: -11828))
    }
}
