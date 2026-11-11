import Testing
@testable import MarqueeCore

struct VideoOrientationTests {
    @Test func followDeviceNeverHoldsTheScreen() {
        var hold = OrientationHold(.followDevice, screenSideways: false, held: .upright)
        hold.turned(to: .sideways)
        hold.turned(to: .upright)
        #expect(!hold.holdsLandscape && !hold.turnsUprightOnClose)
    }

    @Test func startInLandscapeHoldsUntilThePhoneIsOnItsSide() {
        var hold = OrientationHold(.startInLandscape, screenSideways: false, held: .upright)
        #expect(hold.holdsLandscape && hold.turnsUprightOnClose)
        // Laid flat and picked up again: the hold it opened in, not a turn.
        hold.turned(to: .upright)
        #expect(hold.holdsLandscape)
        hold.turned(to: .sideways)
        #expect(!hold.holdsLandscape)
        hold.turned(to: .upright)
        #expect(!hold.holdsLandscape && !hold.turnsUprightOnClose)

        #expect(!OrientationHold(.startInLandscape, screenSideways: true, held: .sideways).holdsLandscape)
    }

    @Test func lockToLandscapeHoldsThroughoutAndTurnsBackForAnUprightPhone() {
        var hold = OrientationHold(.lockToLandscape, screenSideways: false, held: .upright)
        hold.turned(to: .sideways)
        #expect(hold.holdsLandscape && !hold.turnsUprightOnClose)
        hold.turned(to: .upright)
        #expect(hold.holdsLandscape && hold.turnsUprightOnClose)
    }
}
