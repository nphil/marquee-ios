import AVFoundation
import MarqueeCore
import SwiftUI

/// The trailer playing in a title's hero (the TV's "Play trailers automatically"). It starts after
/// `TrailerAutoplay.dwell` while `TrailerAutoplay.decide` allows, plays once with the phone's sound rules,
/// and stops the moment the page leaves the screen. It is a preview: no watch state is written and the
/// player's route, remux and transcode machinery stay out of it.
struct TrailerPreview: View {
    let trailer: PlexMetadata

    @Environment(AppSession.self) private var app
    @Environment(\.plexLibrary) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = TrailerPreviewModel()
    @State private var onScreen = true
    @State private var heroVisible = true

    private var verdict: TrailerAutoplay.Verdict {
        TrailerAutoplay.decide(.init(
            enabled: app.settings.playsTrailers,
            lowPowerMode: model.lowPowerMode,
            reduceMotion: reduceMotion,
            metered: model.metered,
            appActive: scenePhase == .active,
            heroVisible: onScreen && heroVisible,
            playerOpen: app.player.presented != nil || app.player.active != nil,
            otherAudioPlaying: model.otherAudioPlaying
        ))
    }

    var body: some View {
        let verdict = verdict
        let plays = verdict != .hold
        let muted = verdict == .play(muted: true)
        ZStack {
            Color.clear
            if model.player != nil || model.still != nil {
                surface
                    .opacity(model.isPlaying ? 1 : 0)
                    .accessibilityLabel("Trailer playing")
                    .accessibilityIdentifier(model.isPlaying ? "detail.trailerPreview" : "detail.trailerLoading")
            }
        }
        .animation(.easeOut(duration: 0.4), value: model.isPlaying)
        .allowsHitTesting(false)
        .onAppear {
            onScreen = true
            model.watchSystem()
        }
        .onDisappear {
            onScreen = false
            model.unwatchSystem()
        }
        .onScrollVisibilityChange(threshold: 0.5) { heroVisible = $0 }
        .onChange(of: muted) { _, muted in model.isMuted = muted }
        .task(id: plays) {
            guard plays else {
                model.stop()
                return
            }
            guard !model.finished else { return }
            try? await Task.sleep(for: TrailerAutoplay.dwell)
            guard !Task.isCancelled else { return }
            await begin(muted: muted)
        }
    }

    @ViewBuilder
    private var surface: some View {
        if let still = model.still {
            Image(uiImage: still).resizable().scaledToFill()
        } else {
            TrailerSurface(model: model)
        }
    }

    private func begin(muted: Bool) async {
        #if DEBUG
        if let root = FakePlex.root {
            model.startStill(root: root)
            return
        }
        #endif
        guard let library else { return }
        let device = await app.player.capabilities.current()
        guard !Task.isCancelled, let part = TrailerAutoplay.directPart(of: trailer.media, capabilities: device),
              let url = try? await library.playbackURL(path: part.key), !Task.isCancelled
        else { return }
        model.start(url, muted: muted)
    }
}

@MainActor
@Observable
final class TrailerPreviewModel {
    /// The first picture is on screen; the art beneath it shows again when the trailer ends or stops.
    private(set) var isPlaying = false
    /// The trailer played to its end or failed; the page does not start it again.
    private(set) var finished = false
    private(set) var player: AVPlayer?
    private(set) var still: UIImage?
    var isMuted = false {
        didSet { player?.isMuted = isMuted }
    }

    /// What the system says now; `watchSystem` keeps them current while the page is on screen.
    private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
    private(set) var metered = false

    @ObservationIgnored private var systemTokens: [any NSObjectProtocol] = []
    @ObservationIgnored private var meteredWatch: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var endToken: (any NSObjectProtocol)?

    func watchSystem() {
        guard systemTokens.isEmpty else { return }
        refreshSystem()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, AVAudioSession.silenceSecondaryAudioHintNotification] {
            systemTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSystem() }
            })
        }
        meteredWatch = Task { [weak self] in
            for await metered in NetworkPath.meteredUpdates() { self?.metered = metered }
        }
    }

    func unwatchSystem() {
        for token in systemTokens { NotificationCenter.default.removeObserver(token) }
        systemTokens = []
        meteredWatch?.cancel()
        meteredWatch = nil
    }

    private func refreshSystem() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    /// Sound mixes with other apps' audio and follows the silent switch, like a muted-by-default
    /// preview would; the full-screen player takes the playback category when it opens.
    func start(_ url: URL, muted: Bool) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        isMuted = muted
        player.allowsExternalPlayback = false
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let playing = player.timeControlStatus == .playing
                Task { @MainActor in self?.isPlaying = playing }
            },
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in self?.end() }
            },
        ]
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        self.player = player
        player.play()
    }

    #if DEBUG
    /// The UI tests' stand-in, since the simulator decodes no video.
    func startStill(root: URL) {
        let frame = UserDefaults.standard.string(forKey: "marquee.uitest.frame") ?? ""
        still = frame.isEmpty ? nil : UIImage(contentsOfFile: root.appending(path: frame).path(percentEncoded: false))
        isPlaying = still != nil
    }
    #endif

    func stop() {
        observations = []
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        endToken = nil
        player?.pause()
        player = nil
        still = nil
        isPlaying = false
    }

    private func end() {
        finished = true
        stop()
    }
}

private struct TrailerSurface: UIViewRepresentable {
    let model: TrailerPreviewModel

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== model.player { view.playerLayer.player = model.player }
    }
}
