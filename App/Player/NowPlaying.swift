import MediaPlayer
import UIKit

/// The Lock Screen and Control Center entry: title, poster and position, with play, pause, skip and
/// seek. Published by hand because a remux restarted by a long seek begins its item timeline at the
/// seek point, so the player's own clock is not the movie's.
@MainActor
final class NowPlaying {
    struct Actions {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        /// Seconds forward (positive) or back (negative).
        var skip: (TimeInterval) -> Void
        /// A movie time.
        var seek: (TimeInterval) -> Void
        var next: () -> Void
        var previous: () -> Void
    }

    private var targets: [(MPRemoteCommand, Any)] = []
    private var info: [String: Any] = [:]

    init(skipInterval: Int, actions: Actions) {
        let commands = MPRemoteCommandCenter.shared()
        add(commands.playCommand) { _ in actions.play() }
        add(commands.pauseCommand) { _ in actions.pause() }
        add(commands.togglePlayPauseCommand) { _ in actions.toggle() }
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        add(commands.skipForwardCommand) { event in
            actions.skip((event as? MPSkipIntervalCommandEvent)?.interval ?? TimeInterval(skipInterval))
        }
        add(commands.skipBackwardCommand) { event in
            actions.skip(-((event as? MPSkipIntervalCommandEvent)?.interval ?? TimeInterval(skipInterval)))
        }
        add(commands.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            actions.seek(event.positionTime)
        }
        add(commands.nextTrackCommand) { _ in actions.next() }
        add(commands.previousTrackCommand) { _ in actions.previous() }
    }

    func setItem(title: String, subtitle: String?, duration: TimeInterval) {
        info[MPMediaItemPropertyTitle] = title
        if let subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtist)
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPMediaItemPropertyArtwork] = nil
        publish()
    }

    func setArtwork(_ image: UIImage) {
        info[MPMediaItemPropertyArtwork] = Self.artwork(image)
        publish()
    }

    /// Next and Previous follow the play queue.
    func setQueue(hasNext: Bool, hasPrevious: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = hasNext
        commands.previousTrackCommand.isEnabled = hasPrevious
    }

    /// The system runs the clock on from here at `rate`, so this is called on changes, not every tick.
    func update(time: TimeInterval, rate: Double) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        publish()
    }

    func end() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func publish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { event in
            action(event)
            return .success
        }
        targets.append((command, target))
    }

    /// Nonisolated, so the image handler is not tied to the main actor: the system calls it on its own
    /// queue.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
