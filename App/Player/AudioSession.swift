import AVFoundation

/// The audio session for video: the playback category in movie mode, so sound keeps going with the
/// silent switch on, behind the Lock Screen and in Picture in Picture; and the pauses the system asks
/// for.
@MainActor
final class AudioSession {
    /// A call or another app took the audio; `true` when it ended and asked for playback to resume.
    var onInterruption: ((_ began: Bool, _ shouldResume: Bool) -> Void)?
    /// Headphones or a speaker went away; playback pauses rather than carrying on aloud.
    var onRouteLost: (() -> Void)?

    private var tokens: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
                guard let type else { return }
                MainActor.assumeIsolated {
                    self?.onInterruption?(type == .began, options.contains(.shouldResume))
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
                guard reason == .oldDeviceUnavailable else { return }
                MainActor.assumeIsolated { self?.onRouteLost?() }
            },
        ]
    }

    /// Activation is asynchronous: the blocking `setActive` stalls the main thread while the system
    /// settles audio with other apps, and iOS 27 warns about calling it there.
    func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        session.activate { _, _ in }
    }

    /// Lets the music another app paused resume.
    func deactivate() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
        AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) { _, _ in }
    }
}
