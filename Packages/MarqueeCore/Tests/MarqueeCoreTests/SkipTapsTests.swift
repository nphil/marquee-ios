import Testing
@testable import MarqueeCore

struct SkipTapsTests {
    @Test func aDoubleTapSkipsInEveryMode() {
        for mode in SkipTapMode.allCases {
            var taps = SkipTaps(mode: mode)
            #expect(taps.tap(.forward, at: 0) == .single)
            #expect(taps.tap(.forward, at: 0.2) == .skip(.forward))
        }
    }

    @Test func inDoubleTapModeASingleTapAfterASkipOnlyTogglesTheControls() {
        var taps = SkipTaps(mode: .doubleTap)
        _ = taps.tap(.back, at: 0)
        #expect(taps.tap(.back, at: 0.2) == .skip(.back))
        #expect(taps.tap(.back, at: 0.8) == .single)
        #expect(taps.tap(.back, at: 1.4) == .single)
    }

    @Test func inDoubleTapModeTwoPairsSkipTwice() {
        var taps = SkipTaps(mode: .doubleTap)
        _ = taps.tap(.forward, at: 0)
        #expect(taps.tap(.forward, at: 0.2) == .skip(.forward))
        #expect(taps.tap(.forward, at: 0.7) == .single)
        #expect(taps.tap(.forward, at: 0.9) == .skip(.forward))
    }

    @Test func inChainedModeTapsAfterASkipKeepSkippingWithinTheWindow() {
        var taps = SkipTaps(mode: .chained)
        _ = taps.tap(.forward, at: 0)
        #expect(taps.tap(.forward, at: 0.2) == .skip(.forward))
        #expect(taps.tap(.forward, at: 1.0) == .skip(.forward))
        // The window runs from the last skip.
        #expect(taps.tap(.forward, at: 2.4) == .skip(.forward))
        #expect(taps.tap(.forward, at: 4.0) == .single)
    }

    @Test func aChainBelongsToOneSide() {
        var taps = SkipTaps(mode: .chained)
        _ = taps.tap(.forward, at: 0)
        _ = taps.tap(.forward, at: 0.2)
        #expect(taps.tap(.back, at: 0.5) == .single)
    }

    @Test func aDoubleTapInTheMiddleTogglesTheAspectAndNeverChains() {
        var taps = SkipTaps(mode: .chained)
        _ = taps.tap(.centre, at: 0)
        #expect(taps.tap(.centre, at: 0.2) == .toggleAspect)
        #expect(taps.tap(.centre, at: 0.6) == .single)
    }

    @Test func tapsTooFarApartAreSingles() {
        var taps = SkipTaps(mode: .doubleTap)
        #expect(taps.tap(.forward, at: 0) == .single)
        #expect(taps.tap(.forward, at: 0.4) == .single)
    }

    @Test func resetForgetsAPendingTapAndTheChain() {
        var taps = SkipTaps(mode: .chained)
        _ = taps.tap(.forward, at: 0)
        _ = taps.tap(.forward, at: 0.2)
        taps.reset()
        #expect(taps.tap(.forward, at: 0.5) == .single)
    }
}
