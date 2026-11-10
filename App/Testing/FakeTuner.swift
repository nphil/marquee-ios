import Foundation
#if DEBUG
import LiveEngine
import LiveFixtures
import MarqueeLive
#endif

/// A stand-in tuner for the UI tests. When they launch the app with `-marquee.uitest.fakeTuner YES`, every channel
/// plays on the direct path from a synthetic stream (a slate, then a moving picture with a tone) and nothing reaches
/// the tuner's address. Release builds never activate it.
enum FakeTuner {
    static let isActive: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "marquee.uitest.fakeTuner")
        #else
        false
        #endif
    }()

    #if DEBUG
    @MainActor static func play(on player: LiveStreamPlayer) {
        let buffer = TimeshiftBuffer(folder: nil, limits: .inMemory)
        player.play(buffer)
        SyntheticTuner.feed(buffer)
    }
    #endif
}
