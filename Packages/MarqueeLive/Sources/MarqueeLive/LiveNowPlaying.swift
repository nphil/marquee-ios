import MediaPlayer
import UIKit

/// The Lock Screen and Control Center entry of a live stream: programme and channel, marked live, with play (opens
/// the stream again), pause (stops it and frees the tuner) and next and previous channel. Skip and seek stay off:
/// live has no timeline to move on.
@MainActor
public final class LiveNowPlaying {
    public struct Actions {
        public var play: () -> Void
        public var pause: () -> Void
        public var next: (() -> Void)?
        public var previous: (() -> Void)?

        public init(play: @escaping () -> Void, pause: @escaping () -> Void, next: (() -> Void)? = nil, previous: (() -> Void)? = nil) {
            self.play = play
            self.pause = pause
            self.next = next
            self.previous = previous
        }
    }

    private var targets: [(MPRemoteCommand, Any)] = []
    private var info: [String: Any] = [:]
    private var isPlaying = false

    public init(actions: Actions) {
        let commands = MPRemoteCommandCenter.shared()
        add(commands.playCommand, actions.play)
        add(commands.pauseCommand, actions.pause)
        add(commands.togglePlayPauseCommand) { [weak self] in
            if self?.isPlaying == true { actions.pause() } else { actions.play() }
        }
        if let next = actions.next { add(commands.nextTrackCommand, next) }
        if let previous = actions.previous { add(commands.previousTrackCommand, previous) }
        for command in [
            commands.nextTrackCommand, commands.previousTrackCommand, commands.skipForwardCommand,
            commands.skipBackwardCommand, commands.seekForwardCommand, commands.seekBackwardCommand,
            commands.changePlaybackPositionCommand,
        ] where !targets.contains(where: { $0.0 === command }) {
            command.isEnabled = false
        }
    }

    /// `title`: the programme, or the station when the guide has none; `channel`: "2.1 WXXX".
    public func setItem(title: String, channel: String, artwork: UIImage? = nil) {
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = channel
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPMediaItemPropertyArtwork] = artwork.map(Self.artwork)
        publish()
    }

    public func setPlaying(_ playing: Bool) {
        isPlaying = playing
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        publish()
    }

    public func end() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func publish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            action()
            return .success
        }
        targets.append((command, target))
    }

    /// Nonisolated, so the image handler is not tied to the main actor: the system calls it on its own queue.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
