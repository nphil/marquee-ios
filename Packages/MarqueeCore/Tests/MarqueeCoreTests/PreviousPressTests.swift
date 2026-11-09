import Testing
@testable import MarqueeCore

struct PreviousPressTests {
    @Test func theFirstPressMidEpisodeGoesToTheStart() {
        #expect(PreviousPress.action(position: 600, sincePreviousPress: nil, hasPreviousItem: true) == .restart)
        #expect(PreviousPress.action(position: 600, sincePreviousPress: 10, hasPreviousItem: true) == .restart)
    }

    @Test func aSecondPressSoonAfterGoesToThePreviousEpisode() {
        #expect(PreviousPress.action(position: 600, sincePreviousPress: 2, hasPreviousItem: true) == .previousItem)
    }

    @Test func aPressInTheFirstSecondsGoesToThePreviousEpisode() {
        #expect(PreviousPress.action(position: 2, sincePreviousPress: nil, hasPreviousItem: true) == .previousItem)
        #expect(PreviousPress.action(position: 3, sincePreviousPress: nil, hasPreviousItem: true) == .previousItem)
        #expect(PreviousPress.action(position: 3.5, sincePreviousPress: nil, hasPreviousItem: true) == .restart)
    }

    @Test func withNothingBeforeItAlwaysRestarts() {
        #expect(PreviousPress.action(position: 1, sincePreviousPress: 1, hasPreviousItem: false) == .restart)
    }
}
