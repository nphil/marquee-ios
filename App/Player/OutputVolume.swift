import AVFoundation
import MarqueeCore
import MediaPlayer
import UIKit

/// Something that plays sound and takes a volume of its own: a video player or the live tuner's renderer.
@MainActor
protocol GainSink: AnyObject {
    func apply(gain: Float)
}

/// The players' own volume, 0 to 1, which every player registered here follows. It is the fallback for a
/// system output volume the app cannot set.
@MainActor
final class PlaybackGain {
    static let shared = PlaybackGain()

    private struct Entry {
        weak var sink: (any GainSink)?
    }

    private(set) var level: Float = 1
    private var sinks: [Entry] = []

    /// A new player takes the level at once.
    func register(_ sink: any GainSink) {
        sinks.removeAll { $0.sink == nil }
        sinks.append(Entry(sink: sink))
        if level != 1 { sink.apply(gain: level) }
    }

    func set(_ level: Float) {
        self.level = level
        sinks.removeAll { $0.sink == nil }
        for entry in sinks { entry.sink?.apply(gain: level) }
    }
}

/// The system output volume, which is what drives HDMI and Bluetooth audio. iOS lets an app set it only
/// through the slider of a `MPVolumeView`, so a hidden one sits in the phone's window. The same view keeps
/// the system's volume panel from covering the picture while it is on screen.
@MainActor
final class SystemVolume {
    static let shared = SystemVolume()

    /// A level this close to the target counts as reached.
    private static let tolerance = 0.5 / Float(LinkVolume.steps)

    private let view: MPVolumeView = {
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 40, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }()
    private var preparedSession = false

    var level: Float { AVAudioSession.sharedInstance().outputVolume }

    private var slider: UISlider? {
        view.subviews.lazy.compactMap { $0 as? UISlider }.first
    }

    /// The level is only reported, and its changes only observed, while the audio session is active. A
    /// phone that plays nothing gets the ambient one, which mixes with whatever else plays.
    func prepareSession() {
        guard !preparedSession else { return }
        preparedSession = true
        let audio = AVAudioSession.sharedInstance()
        if audio.category == .soloAmbient { try? audio.setCategory(.ambient) }
        audio.activate { _, _ in }
    }

    /// Puts the hidden view in a window that shows; false when the phone has none.
    private func attach() -> Bool {
        if let window = view.window, !window.isHidden { return true }
        guard let scene = GlassesCenter.phoneScene(),
              let window = scene.keyWindow ?? scene.windows.last(where: { !$0.isHidden }) else { return false }
        view.removeFromSuperview()
        window.addSubview(view)
        view.layoutIfNeeded()
        return true
    }

    /// Hands the level to the slider, without waiting to see it take; false when there is no slider.
    @discardableResult
    func write(_ level: Float) -> Bool {
        prepareSession()
        guard attach(), let slider else { return false }
        slider.setValue(min(max(level, 0), 1), animated: false)
        slider.sendActions(for: .valueChanged)
        return true
    }

    /// Sets the level and waits to see it reached, for up to a third of a second; false when it did not.
    func set(_ target: Float) async -> Bool {
        var written = write(target)
        if !written {
            // The slider joins the view a moment after the view joins a window.
            try? await Task.sleep(for: .milliseconds(80))
            written = write(target)
        }
        guard written else { return false }
        for _ in 0..<7 {
            if abs(level - target) <= Self.tolerance { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return abs(level - target) <= Self.tolerance
    }
}

/// What a linked phone's remote changes on the phone that plays. On HDMI, a line out or a USB audio
/// device the players' own volume is the one used, since iOS may send those at a fixed level whatever the
/// system volume says; on the speaker, headphones and Bluetooth it is the system output volume, and the
/// players' own when that cannot be set. Changes run one after another, so presses in quick succession add up.
@MainActor
final class OutputVolume {
    static let shared = OutputVolume()

    private enum Change: Sendable {
        case step(Int)
        case set(Float)
    }

    /// Whether sound leaves by a digital or line output.
    static var onFixedLevelRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.HDMI, .displayPort, .lineOut, .usbAudio].contains($0.portType)
        }
    }

    private let system = SystemVolume.shared
    private let gain = PlaybackGain.shared
    /// The system volume could not be set the last time, so the players' own is in use.
    private(set) var usesGain = false
    private var wasFixedLevel = OutputVolume.onFixedLevelRoute
    private var queue: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        }
    }

    /// The level the phone plays at, 0 to 1.
    var level: Float { usesGain || Self.onFixedLevelRoute ? gain.level : system.level }

    func step(_ steps: Int) {
        enqueue(.step(steps))
    }

    func set(_ level: Double) {
        enqueue(.set(Float(LinkVolume.clamped(level))))
    }

    /// Back on the speaker or headphones the system volume rules again, so the players' own goes back to full.
    private func routeChanged() {
        let fixed = Self.onFixedLevelRoute
        defer { wasFixedLevel = fixed }
        guard wasFixedLevel, !fixed, !usesGain, gain.level != 1 else { return }
        gain.set(1)
    }

    private func enqueue(_ change: Change) {
        let previous = queue
        queue = Task {
            await previous?.value
            await run(change)
        }
    }

    private func run(_ change: Change) async {
        let gainTarget: Float
        let systemTarget: Float
        switch change {
        case .step(let steps):
            gainTarget = Float(LinkVolume.stepped(Double(gain.level), by: steps))
            systemTarget = Float(LinkVolume.stepped(Double(system.level), by: steps))
        case .set(let level):
            gainTarget = level
            systemTarget = level
        }
        if Self.onFixedLevelRoute {
            setGain(gainTarget)
        } else if await system.set(systemTarget) {
            usesGain = false
            if gain.level != 1 { gain.set(1) }
        } else {
            usesGain = true
            setGain(gainTarget)
        }
    }

    /// The system level bar does not move for the players' own volume, so the big screen is told.
    private func setGain(_ level: Float) {
        gain.set(level)
        GlassesCenter.live?.showVolume(level)
    }
}
