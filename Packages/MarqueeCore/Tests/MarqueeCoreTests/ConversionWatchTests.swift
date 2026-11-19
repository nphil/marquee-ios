import Testing
@testable import MarqueeCore

struct ConversionWatchTests {
    @Test func aMissWithLittleBufferedMeansTheSessionIsGone() {
        // 2026-11-19: after a 3 min 40 s pause 9.7 s was buffered when the first 404 came.
        var watch = ConversionWatch()

        #expect(watch.notFound(at: 0, bufferAhead: 9.7) == .recover(.thinBuffer, missed: 1))
    }

    @Test func aMissWithRoomToWaitIsLostWhenItRepeatsWithinTheWindow() {
        var watch = ConversionWatch()

        #expect(watch.notFound(at: 0, bufferAhead: 30) == .wait)
        #expect(watch.notFound(at: 3, bufferAhead: 27) == .recover(.repeated, missed: 2))
    }

    @Test func missesFurtherApartThanTheWindowAreSlowSegments() {
        var watch = ConversionWatch()

        #expect(watch.notFound(at: 0, bufferAhead: 30) == .wait)
        #expect(watch.notFound(at: 7, bufferAhead: 25) == .wait)
        #expect(watch.notFound(at: 14, bufferAhead: 20) == .wait)
    }

    @Test func anUnknownBufferCountsAsNone() {
        var watch = ConversionWatch()

        #expect(watch.notFound(at: 0, bufferAhead: nil) == .recover(.thinBuffer, missed: 1))
    }

    @Test func anItemThatFailedWithANotFoundIsLost() {
        var watch = ConversionWatch()

        #expect(watch.failed(at: 0) == .recover(.failed, missed: 1))
    }

    @Test func aNewStreamForgetsTheMissesOfTheOldOne() {
        var watch = ConversionWatch()
        _ = watch.notFound(at: 0, bufferAhead: 30)

        watch.streamStarted()

        #expect(watch.notFound(at: 2, bufferAhead: 30) == .wait)
    }

    @Test func aSessionLostAgainAndAgainIsLeftToTheStartRecovery() {
        var watch = ConversionWatch()

        #expect(watch.notFound(at: 0, bufferAhead: 5) == .recover(.thinBuffer, missed: 1))
        watch.recovered(at: 1)
        #expect(watch.notFound(at: 20, bufferAhead: 5) == .recover(.thinBuffer, missed: 1))
        watch.recovered(at: 21)
        #expect(watch.notFound(at: 40, bufferAhead: 5) == .giveUp)
        #expect(watch.failed(at: 41) == .giveUp)

        // The budget returns once the recoveries are further back than `settle`.
        let later = watch.notFound(at: 82, bufferAhead: 5)
        guard case .recover(.thinBuffer, _) = later else {
            Issue.record("expected a recovery, got \(later)")
            return
        }
    }

    @Test func aRecoveryNeedsNoNewMissesToCountAgainstTheBudget() {
        var watch = ConversionWatch()
        watch.recovered(at: 0)
        watch.recovered(at: 30)

        #expect(watch.failed(at: 45) == .giveUp)
    }

    @Test func readsAVPlayersNotFoundWords() {
        #expect(ConversionWatch.isNotFound(domain: "CoreMediaErrorDomain", code: -12938, comment: "HTTP 404: File Not Found"))
        #expect(ConversionWatch.isNotFound(domain: "NSURLErrorDomain", code: -1100))
        #expect(ConversionWatch.isNotFound(domain: nil, code: 0, comment: "http 404: file not found"))
        #expect(!ConversionWatch.isNotFound(domain: "CoreMediaErrorDomain", code: -12889, comment: "No response for map"))
        #expect(!ConversionWatch.isNotFound(domain: "NSURLErrorDomain", code: -1001, comment: "The request timed out."))
        #expect(!ConversionWatch.isNotFound(domain: "CoreMediaErrorDomain", code: -12660, comment: "HTTP 403: Forbidden"))
    }
}
