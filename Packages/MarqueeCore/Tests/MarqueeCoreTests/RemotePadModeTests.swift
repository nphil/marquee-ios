import Testing
@testable import MarqueeCore

struct RemotePadModeTests {
    @Test func savedModesRoundTripAndAnythingElseIsTheDpad() {
        for mode in RemotePadMode.allCases {
            #expect(RemotePadMode(decoding: mode.rawValue) == mode)
        }
        #expect(RemotePadMode(decoding: nil) == .dpad)
        #expect(RemotePadMode(decoding: "") == .dpad)
        #expect(RemotePadMode(decoding: "gyro") == .dpad)
    }
}
