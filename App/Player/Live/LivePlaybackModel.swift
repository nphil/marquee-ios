import MarqueeCore
import Observation
import SwiftUI

/// One visit to the live player (docs/LIVE-TV.md §6.7-6.9): the channel on screen and the one before it,
/// surfing, pause and going back within the buffer, the controls' timer, and the source that plays.
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
    /// Seconds a skip moves: the app's skip interval.
    let skipInterval: Double
    private(set) var chromeVisible = true
    private(set) var showsGuide = false
    /// The recording that has taken the tuner the failed channel needs.
    private(set) var tunerHolder: ScheduledRecording?
    private(set) var isStoppingHolder = false
    private(set) var holderProblem: String?
    var fillsScreen = false
    var showsDiagnostics = false
    /// VoiceOver or Switch Control is on: the controls stay up.
    private(set) var keepsChrome = false

    @ObservationIgnored private let audio = AudioSession()
    @ObservationIgnored private let playbackActive: @MainActor @Sendable (Bool) -> Void
    @ObservationIgnored private var surfCommit: Task<Void, Never>?
    @ObservationIgnored private var chromeTimer: Task<Void, Never>?
    @ObservationIgnored private var holderCheck: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false
    /// A call paused the stream; it plays on when the call ends.
    @ObservationIgnored private var resumesAfterInterruption = false

    /// A tune waits this long after the last channel passed, so surfing across five channels tunes once.
    static let surfCommitDelay: Duration = .milliseconds(300)

    init(store: LiveTVStore, channel: LiveChannel, readsTunerDirectly: Bool, skipInterval: Double, playbackActive: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.store = store
        self.channel = channel
        self.skipInterval = skipInterval
        self.playbackActive = playbackActive
        source = LiveRouter(live: store.live, plex: PlexLiveSource(live: store.live))
        source.prefersPlex = !readsTunerDirectly
    }

    var state: LiveState { source.state }
    var timeshift: LiveTimeshift { source.timeshift }

    /// The status line: the source's, else on a one-tuner device while paused, that the tuner is still taken.
    var status: String? {
        if let said = source.status { return said }
        guard timeshift.isPaused, channel.device.tunerCount == 1 else { return nil }
        return "Paused · the tuner stays in use"
    }

    /// The channel the controls describe: the one surfing has reached, else the one playing.
    var shown: LiveChannel { surfing ?? channel }

    /// What `channel` airs now, and after that; for the channel playing, at the moment on screen.
    func airings(on channel: LiveChannel) -> (now: LiveAiring?, next: LiveAiring?) {
        store.guide.nowAndNext(on: channel.id, at: moment(on: channel))
    }

    /// The moment `channel` shows: behind live by the timeshift for the channel playing, else now.
    func moment(on channel: LiveChannel) -> Date {
        channel.id == self.channel.id ? store.now.addingTimeInterval(-timeshift.behindLive) : store.now
    }

    // MARK: Life

    func start() {
        guard !started, !closed else { return }
        started = true
        playbackActive(true)
        audio.onInterruption = { [weak self] began, shouldResume in
            guard let self else { return }
            if began {
                guard state != .idle, !timeshift.isPaused else { return }
                resumesAfterInterruption = true
                pause()
            } else {
                if resumesAfterInterruption, shouldResume { playOn() }
                resumesAfterInterruption = false
            }
        }
        audio.onRouteLost = { [weak self] in self?.pause() }
        audio.activate()
        tune(channel)
    }

    /// Ends the stream and frees the tuner; the player is going away.
    func close() {
        guard !closed else { return }
        closed = true
        holderCheck?.cancel()
        surfCommit?.cancel()
        chromeTimer?.cancel()
        source.stop()
        let wasStarted = started
        let playbackActive = playbackActive
        audio.deactivate {
            if wasStarted { playbackActive(false) }
        }
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
        if target.id == channel.id, state != .idle {
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

    // MARK: Pause and the buffer

    func togglePlay() {
        if timeshift.isPaused || state == .idle {
            playOn()
        } else {
            pause()
        }
    }

    /// Holds the picture; the stream goes on into the buffer and the tuner stays in use.
    func pause() {
        guard !closed, state != .idle else { return }
        source.pause()
        showChrome()
    }

    /// Plays on from a pause, or tunes again after the stream ended.
    private func playOn() {
        if state == .idle { tune(channel) } else { source.resume() }
        showChrome()
    }

    /// Moves `seconds` within the buffer (negative goes back); a skip that would land near live goes live.
    func skip(by seconds: Double) {
        guard !closed else { return }
        source.seek(behindLive: timeshift.skipped(by: seconds))
        showChrome()
    }

    func goLive() {
        guard !closed else { return }
        source.seek(behindLive: 0)
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
        if case .failed(let error) = state, error != .protectedChannel {
            findHolder()
        } else if !isStoppingHolder {
            holderCheck?.cancel()
            tunerHolder = nil
        }
    }

    // MARK: Recording holds the tuner

    /// Asks the server which recording, if any, has the tuner the failed channel needs.
    private func findHolder() {
        holderCheck?.cancel()
        let failed = channel
        holderCheck = Task { [weak self] in
            guard let self else { return }
            let holder = await store.tunerHolder(for: failed)
            guard !Task.isCancelled, case .failed = state, channel.id == failed.id else { return }
            tunerHolder = holder
            holderProblem = nil
        }
    }

    /// Stops the recording holding the tuner, and the series rule too when asked, then tunes again once
    /// the server has let go (deleting the grab frees the tuner in about 0.5 s).
    func stopHolder(deletingSeries: Bool) {
        guard let recording = tunerHolder, !isStoppingHolder else { return }
        isStoppingHolder = true
        holderProblem = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.unschedule(recording, deletingSeries: deletingSeries)
                try? await Task.sleep(for: .milliseconds(700))
                tunerHolder = nil
                isStoppingHolder = false
                guard !closed else { return }
                tune(channel)
            } catch {
                holderProblem = LiveText.recordingProblem(error, server: store.serverName)
                isStoppingHolder = false
            }
        }
    }

    /// The controls stay while nothing plays or it is paused, while surfing or the guide is open, and for VoiceOver.
    private var canHideChrome: Bool {
        state == .playing && !timeshift.isPaused && surfing == nil && !showsGuide && !keepsChrome
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
