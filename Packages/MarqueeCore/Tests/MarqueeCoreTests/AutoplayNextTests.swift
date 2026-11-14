import Testing
@testable import MarqueeCore

struct AutoplayNextTests {
    @Test func offIsOnlyOffered() {
        let rule = AutoplayNext(enabled: false, credits: .skipInstantly, delay: 3)
        #expect(rule.atCredits == .offer)
        #expect(!rule.playsNextAtEnd(creditsWatched: false))
    }

    @Test func onCountsDownOrSkipsAtTheCredits() {
        #expect(AutoplayNext(credits: .countdown, delay: 3).atCredits == .countdown(seconds: 3))
        #expect(AutoplayNext(credits: .skipInstantly, delay: 3).atCredits == .playNow)
    }

    @Test func onPlaysNextAtTheEndUnlessCreditsWereWatched() {
        let rule = AutoplayNext()
        #expect(rule.playsNextAtEnd(creditsWatched: false))
        #expect(!rule.playsNextAtEnd(creditsWatched: true))
    }

    @Test func oldDelayKeepsItsBehaviour() {
        #expect(AutoplayNext(legacyDelay: 10) == AutoplayNext(enabled: true, credits: .countdown, delay: 10))
        let off = AutoplayNext(legacyDelay: 0)
        #expect(!off.enabled)
        #expect(off.delay == 5)
    }
}
