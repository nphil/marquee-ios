import Foundation
#if DEBUG
import LiveEngine
import LiveFixtures
import MarqueeLive
#endif

/// A stand-in tuner for the UI tests. When they launch the app with `MARQUEE_FAKE_TUNER` set, every channel plays on
/// the direct path from a synthetic stream (a slate, then a moving picture with a tone) and nothing reaches the
/// network. Release builds never activate it.
enum FakeTuner {
    static let environmentKey = "MARQUEE_FAKE_TUNER"

    static let isActive: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment[environmentKey] != nil
        #else
        false
        #endif
    }()

    #if DEBUG
    @MainActor static func play(on player: LiveStreamPlayer) {
        let ring = ByteRing()
        player.play(ring)
        SyntheticTuner.feed(ring)
    }
    #endif
}
