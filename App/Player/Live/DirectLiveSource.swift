import LiveEngine
import MarqueeCore
import MarqueeLive
import Observation
import UIKit

/// Live TV read straight from the tuner (docs/LIVE-TV.md §2): `<device>/auto/v<number>` played on MarqueeLive's
/// sample-buffer player. The tuner's slates are ordinary pictures, so nothing covers the picture; the status label
/// speaks only while nothing of the new channel is on screen ("Tuning 7.1"; H.264 and HEVC stations come without a
/// slate).
///
/// A tune while another plays is a takeover by the same client: the tuner moves this phone's stream to the new
/// channel, and the old picture stays until the new one's first. A refusal (503, or 805 when the TV is in use) ends
/// the tune with the tuner's own sentence.
@MainActor @Observable
final class DirectLiveSource: LiveVideoSource {
    let player = LiveStreamPlayer()
    private(set) var channel: LiveChannel?

    /// A tune failed with a network error, no data, an end, or a stream the phone cannot decode, before its first
    /// picture or while it played; the router carries on through Plex (§2.2 rule 8). A tuner's refusal is not passed
    /// on, since Plex would be refused the same way.
    @ObservationIgnored var onFailed: ((LiveChannel, LiveError) -> Void)?

    init() {
        player.onStateChange = { [weak self] state in self?.stateChanged(state) }
    }

    var videoView: UIView { player.view }

    var state: LiveState { Self.liveState(player.state) }

    var status: String? {
        guard player.state == .opening, let channel else { return nil }
        return "Tuning \(channel.number)"
    }

    /// "2.1 direct · slate 0.72 s · picture 3.52 s · sound 4.86 s · MPEG-2 1280×720p · AC-3 5.1→2.0 · J 0.30 s · …"
    var diagnosticsLine: String? {
        guard let channel else { return nil }
        return "\(channel.number) direct · \(player.diagnostics.line)"
    }

    func play(_ channel: LiveChannel) async {
        self.channel = channel
        #if DEBUG
        if FakeTuner.isActive { return FakeTuner.play(on: player) }
        #endif
        player.open(channel.device.streamURL(channel))
    }

    func stop() {
        player.close()
    }

    private func stateChanged(_ state: LiveStreamPlayer.State) {
        guard case .failed(let failure) = state, let channel else { return }
        switch failure {
        case .noPicture, .lost, .unreadable, .ended:
            onFailed?(channel, Self.error(failure))
        case .refused:
            break
        }
    }

    static func liveState(_ state: LiveStreamPlayer.State) -> LiveState {
        switch state {
        case .idle: .idle
        case .opening: .opening
        case .slate: .slate
        case .picture: .picture
        case .playing: .playing
        case .stalled: .stalled
        case .failed(let failure): .failed(error(failure))
        }
    }

    static func error(_ failure: LiveStreamPlayer.Failure) -> LiveError {
        switch failure {
        case .refused(let refusal) where refusal.isProtected: .protectedChannel
        case .refused(let refusal): .refused(code: refusal.code, message: refusal.text)
        case .noPicture: .noData
        case .lost(let message): .network(message)
        case .unreadable(let message): .unsupported(message)
        // LumaTuner ends a stream with a last slate when the TV takes its tuner or the signal goes.
        case .ended: .refused(code: nil, message: "The tuner ended the stream.")
        }
    }
}
