import AVFoundation
import MarqueeCore
import UIKit

/// The volume buttons of the phone that is the remote, taken while its remote shows: each press says louder
/// or quieter to the other phone, and this phone's own level goes back where it was, so pressing never
/// changes what this phone plays at. iOS lets an app only watch the level, so the press is read from the
/// level moving, and the level is parked a step from either end so a press always moves it.
@MainActor
final class VolumeButtons {
    private static let grid = 1 / Float(LinkVolume.steps)

    private let system = SystemVolume.shared
    private var observation: NSKeyValueObservation?
    /// The level before the remote opened, which comes back when it closes.
    private var original: Float?
    /// The level this phone is held at between presses.
    private var parked: Float = 0.5
    private var pressed: ((Int) -> Void)?

    /// `pressed` hears +1 for a press up and -1 for one down.
    func start(pressed: @escaping (Int) -> Void) {
        guard observation == nil else { return }
        self.pressed = pressed
        system.prepareSession()
        let level = system.level
        original = level
        parked = min(max(level, Self.grid), 1 - Self.grid)
        if parked != level, !system.write(parked) { parked = level }
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let level = change.newValue else { return }
            Task { @MainActor in self?.changed(to: level) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        pressed = nil
        if let original { system.write(original) }
        original = nil
    }

    private func changed(to level: Float) {
        guard original != nil, abs(level - parked) > Self.grid / 4 else { return }
        // Control Center and Siri change the level while the app is not active: that is the person's, not a press.
        guard UIApplication.shared.applicationState == .active else {
            original = level
            parked = level
            return
        }
        let step = level > parked ? 1 : -1
        // With no slider to restore the level, later presses are read from where it is now.
        if !system.write(parked) { parked = level }
        pressed?(step)
    }
}
