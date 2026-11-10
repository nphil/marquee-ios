import AVFoundation
import MarqueeCore
import SwiftUI

/// The theme tune of the show page on screen (DESIGN §8.3). One player serves the whole app, so a season
/// pushed over its show carries the same tune on; pages only say which tune they want.
///
/// A paused tune resumes when its page shows again, starts over once the player has been open, and does
/// not repeat after playing to its end. It plays under the ambient category, like the trailer preview: it
/// mixes with other apps and Silent mode silences it.
@MainActor @Observable
final class ThemeMusicPlayer {
    struct Identity: Equatable {
        let library: ObjectIdentifier
        let key: String
    }

    struct Want {
        let key: String
        let library: PlexLibrary
        var identity: Identity { Identity(library: library.instance, key: key) }
    }

    /// The tune is playing and can be heard; a trailer that starts meanwhile plays silently.
    private(set) var isHeard = false
    /// What the system says now; `refreshOtherAudio` and the system's hint keep it current.
    private(set) var otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
    /// A trailer preview is playing with sound; the tune waits for it.
    var trailerSounding = false
    /// The volume setting, 0 to 1.
    var level = 0.5 {
        didSet { player?.volume = fade.volume(level: level) }
    }

    /// The pages asking for a tune, oldest first; the last one wins.
    @ObservationIgnored private var wants: [(page: UUID, want: Want)] = []
    @ObservationIgnored private var loadedIdentity: Identity?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var finished = false
    /// The player opened: the tune starts over rather than resuming.
    @ObservationIgnored private var forgets = false
    @ObservationIgnored private var fade = ThemeFade()
    @ObservationIgnored private var fading: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var endToken: (any NSObjectProtocol)?
    @ObservationIgnored private var hintToken: (any NSObjectProtocol)?
    @ObservationIgnored private var interruptionToken: (any NSObjectProtocol)?
    /// An interruption began and no end has been seen. iOS does not promise an end notification, so the
    /// latch also clears when the app becomes active and when a different tune is wanted than the one it held back.
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var heldBack: Identity?
    @ObservationIgnored private var activeToken: (any NSObjectProtocol)?

    init() {
        hintToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOtherAudio() }
        }
        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            guard let type else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    self.interrupted = true
                    self.heldBack = self.loadedIdentity
                    self.player?.pause()
                    self.ended()
                } else if type == .ended {
                    self.interrupted = false
                    self.heldBack = nil
                }
            }
        }
        activeToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interrupted = false
                self?.heldBack = nil
            }
        }
    }

    func refreshOtherAudio() {
        otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    /// What `page` wants now: its show's tune, or nothing once it leaves the screen or something else
    /// holds the sound.
    func update(page: UUID, want: Want?) {
        wants.removeAll { $0.page == page }
        if let want { wants.append((page, want)) }
        reconcile()
    }

    func forget() {
        guard loadedIdentity != nil else { return }
        forgets = true
        reconcile()
    }

    private var wantsLoaded: Bool {
        wants.last?.want.identity == loadedIdentity && loadedIdentity != nil && !finished && !forgets
    }

    private func reconcile() {
        guard wantsLoaded else {
            // Silence first; `settled` then loads the tune wanted, if any.
            fade.rising = false
            return runFade()
        }
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        if player.timeControlStatus == .playing {
            started()
        } else {
            player.play()
        }
    }

    /// Sound has begun, so the fade in starts now rather than while the tune buffers.
    private func started() {
        guard wantsLoaded, player?.timeControlStatus == .playing else { return }
        fade.rising = true
        isHeard = true
        runFade()
    }

    private func runFade() {
        guard fading == nil else { return }
        fading = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                if fade.isSettled {
                    fading = nil
                    return settled()
                }
                try? await Task.sleep(for: .milliseconds(30))
                let now = clock.now
                let step = last.duration(to: now).components
                last = now
                fade.advance(by: Double(step.seconds) + Double(step.attoseconds) * 1e-18)
                player?.volume = fade.volume(level: level)
            }
        }
    }

    private func settled() {
        guard !fade.rising else { return }
        player?.pause()
        isHeard = false
        guard let want = wants.last?.want else {
            if forgets { unload() }
            return
        }
        if want.identity != loadedIdentity || forgets { load(want) }
    }

    private func load(_ want: Want) {
        unload()
        loadedIdentity = want.identity
        if interrupted, heldBack == nil || heldBack == want.identity {
            heldBack = want.identity
            finished = true
            return
        }
        interrupted = false
        heldBack = nil
        // The UI tests' fake server has no tunes.
        guard !FakePlex.isActive else { return }
        loading = Task { [weak self] in
            guard let url = try? await want.library.playbackURL(path: want.key), !Task.isCancelled, let self else { return }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.volume = 0
            observations = [
                player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                    Task { @MainActor in
                        guard let self, self.player === player else { return }
                        if player.timeControlStatus == .playing { self.started() }
                        else { self.isHeard = false }
                    }
                },
                item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in self?.ended() }
                },
            ]
            endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended() }
            }
            self.player = player
            reconcile()
        }
    }

    private func ended() {
        finished = true
        isHeard = false
        fading?.cancel()
        fading = nil
        fade = ThemeFade()
        player?.volume = 0
    }

    private func unload() {
        loading?.cancel()
        loading = nil
        observations = []
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        endToken = nil
        player?.pause()
        player = nil
        loadedIdentity = nil
        finished = false
        forgets = false
        fading?.cancel()
        fading = nil
        fade = ThemeFade()
        isHeard = false
    }
}

/// A show or season page's theme tune, while the page is on screen.
private struct ThemeMusicPage: ViewModifier {
    let key: String?

    @Environment(AppSession.self) private var app
    @Environment(\.plexLibrary) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = UUID()
    @State private var onScreen = false

    private var playerOpen: Bool {
        app.player.presented != nil || app.player.active != nil
    }

    private var wanted: String? {
        guard let key, ThemeMusic.plays(.init(
            enabled: app.settings.playsThemeMusic,
            appActive: scenePhase == .active,
            pageVisible: onScreen,
            playerOpen: playerOpen,
            otherAudioPlaying: app.themeMusic.otherAudioPlaying,
            trailerSounding: app.themeMusic.trailerSounding
        )) else { return nil }
        return key
    }

    func body(content: Content) -> some View {
        let music = app.themeMusic
        content
            .onAppear {
                onScreen = true
                music.refreshOtherAudio()
            }
            .onDisappear {
                onScreen = false
                music.update(page: page, want: nil)
            }
            .onChange(of: wanted.flatMap { key in library.map { ThemeMusicPlayer.Identity(library: $0.instance, key: key) } }, initial: true) { _, identity in
                music.update(page: page, want: identity.flatMap { identity in library.map { ThemeMusicPlayer.Want(key: identity.key, library: $0) } })
            }
            .onChange(of: app.settings.themeMusicVolume, initial: true) { _, level in music.level = level }
            .onChange(of: playerOpen) { _, open in
                if open { music.forget() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { music.refreshOtherAudio() }
            }
    }
}

extension View {
    /// Plays `key`, a show's theme tune, while this page is on screen.
    func themeMusic(_ key: String?) -> some View {
        modifier(ThemeMusicPage(key: key))
    }
}
