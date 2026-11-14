import Foundation
import MarqueeCore

/// The driving phone's side of a link: what it tells a controlling phone, and how it takes that phone's
/// input. The input goes to the big screen's navigator exactly as this phone's own remote would send it.
@MainActor
enum LinkHost {
    static func status(of session: AppSession) -> LinkStatus {
        var status = LinkStatus()
        if session.glasses.isConnected, let navigator = session.glasses.navigator {
            status.screen = session.glasses.layoutKind == .tv ? .tv : .glasses
            status.focus = navigator.focusTitle
            status.focusDetail = navigator.focusDetail
            status.inPlayer = navigator.player != nil
        }
        if let model = session.player.active {
            status.nowPlaying = nowPlaying(model)
        }
        status.volume = Double(OutputVolume.shared.level)
        return status
    }

    private static func nowPlaying(_ model: PlayerModel) -> LinkNowPlaying {
        let subtitle: Int? = if case .track(let id) = model.subtitleChoice { id } else { nil }
        return LinkNowPlaying(
            title: model.title,
            detail: model.subtitleLine,
            isPlaying: model.isPlaying,
            position: seconds(model.time),
            duration: seconds(model.duration),
            hasNext: model.hasNext,
            subtitles: (model.tracks?.visibleSubtitles ?? []).map { LinkSubtitle(id: $0.id, label: $0.label) },
            subtitle: subtitle
        )
    }

    /// JSON has no NaN or infinity; a player that does not know yet says 0.
    private static func seconds(_ value: TimeInterval) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    /// A press on the controlling phone's remote, `at` when the touch happened by this phone's clock. Its cue
    /// goes back to that phone: returned, or through `cues` when a pan's steps come later, a frame at a time.
    static func handle(_ input: LinkInput, at time: TimeInterval?, in session: AppSession, cues: @escaping GlassesScroller.Cue) -> HapticCue? {
        guard session.glasses.isConnected, let navigator = session.glasses.navigator, let input = GlassesInput(input, at: time) else { return nil }
        return navigator.handle(input, cues: cues)
    }

    /// A control for the player on this phone's own screen, or the volume it plays at.
    static func handle(_ command: LinkCommand, in session: AppSession) {
        switch command {
        case .volume(let step):
            return OutputVolume.shared.step(step)
        case .setVolume(let level):
            return OutputVolume.shared.set(level)
        case .playPause, .skip, .next, .subtitle:
            break
        }
        guard let model = session.player.active else { return }
        switch command {
        case .playPause:
            model.togglePlay()
        case .skip(let seconds):
            model.skip(by: seconds)
        case .next:
            if model.hasNext { model.next() }
        case .subtitle(let id):
            guard let id else { return model.pickSubtitle(.off) }
            guard model.tracks?.visibleSubtitles.contains(where: { $0.id == id }) == true else { return }
            model.pickSubtitle(.track(id))
        case .volume, .setVolume:
            break
        }
    }
}
