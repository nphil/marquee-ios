import MarqueeCore
import Observation
import SwiftUI

/// One visit to the live player (docs/LIVE-TV.md §6.7-6.9): the channel on screen and the one before it,
/// surfing, stop and play, the controls' timer, and the source that plays.
@MainActor @Observable
final class LivePlaybackModel: Identifiable {
    let store: LiveTVStore
    private(set) var channel: LiveChannel
    /// The channel watched before this one, for Last.
    private(set) var previous: LiveChannel?
    /// Where surfing has got to; it tunes once the surfing settles.
    private(set) var surfing: LiveChannel?
    /// Plays each tune from the tuner itself or through Plex, whichever §2.2 picks.
    let source: LiveRouter
    /// Stop was pressed: the tuner is free and the last picture stays.
    private(set) var isStopped = false
    private(set) var chromeVisible = true
    private(set) var showsGuide = false
    var fillsScreen = false
    var showsDiagnostics = false
    /// VoiceOver or Switch Control is on: the controls stay up.
    private(set) var keepsChrome = false

    @ObservationIgnored private let audio = AudioSession()
    @ObservationIgnored private var surfCommit: Task<Void, Never>?
    @ObservationIgnored private var chromeTimer: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false
    /// A call stopped the stream; it comes back when the call ends.
    @ObservationIgnored private var resumesAfterInterruption = false

    /// A tune waits this long after the last channel passed, so surfing across five channels tunes once.
    static let surfCommitDelay: Duration = .milliseconds(300)

    init(store: LiveTVStore, channel: LiveChannel) {
        self.store = store
        self.channel = channel
        source = LiveRouter(live: store.live, plex: PlexLiveSource(live: store.live))
    }

    var state: LiveState { source.state }

    /// The channel the controls describe: the one surfing has reached, else the one playing.
    var shown: LiveChannel { surfing ?? channel }

    /// What `channel` airs now, and after that.
    func airings(on channel: LiveChannel) -> (now: LiveAiring?, next: LiveAiring?) {
        store.guide.nowAndNext(on: channel.id, at: store.now)
    }

    // MARK: Life

    func start() {
        guard !started, !closed else { return }
        started = true
        audio.onInterruption = { [weak self] began, shouldResume in
            guard let self else { return }
            if began {
                guard !isStopped else { return }
                resumesAfterInterruption = true
                stop()
            } else {
                if resumesAfterInterruption, shouldResume { tune(channel) }
                resumesAfterInterruption = false
            }
        }
        audio.onRouteLost = { [weak self] in self?.stop() }
        audio.activate()
        tune(channel)
    }

    /// Ends the stream and frees the tuner; the player is going away.
    func close() {
        guard !closed else { return }
        closed = true
        surfCommit?.cancel()
        chromeTimer?.cancel()
        source.stop()
        audio.deactivate()
    }

    // MARK: Channels

    func tune(_ next: LiveChannel) {
        guard !closed else { return }
        surfCommit?.cancel()
        surfing = nil
        if next.id != channel.id {
            previous = channel
            channel = next
        }
        isStopped = false
        store.noteWatched(next)
        let source = source
        Task { await source.play(next) }
        showChrome()
    }

    /// The channel `steps` along the lineup from `origin`, wrapping at either end.
    func channel(_ steps: Int, from origin: LiveChannel) -> LiveChannel? {
        let lineup = store.lineup
        guard !lineup.isEmpty else { return nil }
        let index = lineup.firstIndex { $0.id == origin.id } ?? 0
        let count = lineup.count
        return lineup[((index + steps) % count + count) % count]
    }

    /// Next and previous: one channel on from wherever surfing has got to.
    func surf(by steps: Int) {
        guard let target = channel(steps, from: shown) else { return }
        preview(target)
        commitSurf()
    }

    /// Shows `target` on the channel card while a swipe is still moving; nothing tunes yet.
    func preview(_ target: LiveChannel) {
        surfCommit?.cancel()
        guard target.id != shown.id else { return }
        surfing = target
        Haptics.selection()
        showChrome()
    }

    /// Tunes the channel surfing reached once it has rested for `surfCommitDelay`. Surfing back to the
    /// channel playing just puts the card away.
    func commitSurf() {
        surfCommit?.cancel()
        guard let target = surfing else { return }
        if target.id == channel.id, !isStopped {
            surfing = nil
            scheduleHide()
            return
        }
        surfCommit = Task { [weak self] in
            try? await Task.sleep(for: Self.surfCommitDelay)
            guard let self, !Task.isCancelled else { return }
            tune(target)
        }
    }

    /// Back to the channel watched before.
    func lastChannel() {
        guard let previous else { return }
        tune(previous)
    }

    // MARK: Stop and play

    func togglePlay() {
        if isStopped || state == .idle {
            tune(channel)
        } else {
            stop()
        }
    }

    func stop() {
        guard !closed, !isStopped else { return }
        surfCommit?.cancel()
        surfing = nil
        isStopped = true
        source.stop()
        showChrome()
    }

    func retry() {
        tune(channel)
    }

    // MARK: Chrome

    func tapped() {
        if chromeVisible, canHideChrome {
            chromeTimer?.cancel()
            withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false }
        } else {
            showChrome()
        }
    }

    func showChrome() {
        if !chromeVisible {
            withAnimation(.easeOut(duration: 0.12)) { chromeVisible = true }
        }
        scheduleHide()
    }

    /// The Quick Guide over the picture; the controls stay while it shows.
    func setGuide(_ shown: Bool) {
        guard shown != showsGuide else { return }
        showsGuide = shown
        if shown { Haptics.selection() }
        showChrome()
    }

    func setKeepsChrome(_ keeps: Bool) {
        guard keeps != keepsChrome else { return }
        keepsChrome = keeps
        showChrome()
    }

    /// The picture came, went or stopped.
    func stateChanged() {
        if state == .playing { scheduleHide() } else { showChrome() }
    }

    /// The controls stay while nothing plays, while surfing or the guide is open, and for VoiceOver.
    private var canHideChrome: Bool {
        state == .playing && surfing == nil && !showsGuide && !keepsChrome && !isStopped
    }

    /// Fades the controls 3 s after the last touch (DESIGN §8.6).
    private func scheduleHide() {
        chromeTimer?.cancel()
        guard chromeVisible else { return }
        chromeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, canHideChrome else { return }
            withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false }
        }
    }
}
