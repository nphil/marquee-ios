import AVFoundation
import MarqueeCore
import Observation
import SwiftUI
import UIKit
import VideoEngine

/// What Play asked for.
struct PlaybackRequest {
    var item: PlexMetadata
    var mediaIndex = 0
    var fromStart = false
    /// A movie time to start at instead of the resume point.
    var startAt: TimeInterval?
    var startsPaused = false
}

/// One playback, for the player screen and the system's surfaces: the route and the stream it chose,
/// the tracks, the timeline, the offers and the play queue. Outlives the screen while Picture in
/// Picture shows it. Times are on the movie's timeline; a stream that starts part-way (a remux run, a
/// server stream from an offset) maps onto it through `origin`.
@MainActor @Observable
final class PlayerModel: Identifiable {
    enum Phase: Equatable {
        case loading
        case playing
        case finished
        case failed(String)
    }

    enum Offer: Equatable {
        case skipIntro(end: TimeInterval)
        case upNext(PlexMetadata)

        static func == (lhs: Offer, rhs: Offer) -> Bool {
            switch (lhs, rhs) {
            case let (.skipIntro(a), .skipIntro(b)): a == b
            case let (.upNext(a), .upNext(b)): a.ratingKey == b.ratingKey
            default: false
            }
        }
    }

    struct Countdown: Equatable {
        var start: Date
        var length: TimeInterval
    }

    /// The running total of quick skips, shown over the picture.
    struct SkipFlash: Equatable {
        var forward: Bool
        var seconds: Int
        var serial: Int
    }

    nonisolated let id = UUID()

    private(set) var item: PlexMetadata
    private(set) var phase: Phase = .loading
    /// A second into loading the stage word shows.
    private(set) var showsStage = false
    private(set) var route: PlaybackRoute?
    /// Why the phone's own route was given up for the server's.
    private(set) var fallback: String?
    private(set) var tracks: MediaTracks?
    /// The audio playing: the pick, or the track standing in for it.
    private(set) var audio: AudioTrack?
    private(set) var subtitle: SubtitleDecision?
    /// Why the chosen subtitle is not on screen.
    private(set) var subtitleProblem: String?
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var presentationSize: CGSize = .zero
    private(set) var isExternalPlayback = false
    private(set) var canPictureInPicture = false
    private(set) var trickplay: Trickplay?
    private(set) var offer: Offer?
    private(set) var countdown: Countdown?
    private(set) var cueText: AttributedString?
    private(set) var bitmaps: [SubtitleBitmap] = []
    private(set) var skipFlash: SkipFlash?
    private(set) var mediaInfo: MediaInfo?
    private(set) var hasNext = false
    private(set) var hasPreviousItem = false
    private(set) var chromeVisible = true
    private(set) var isScrubbing = false
    private(set) var aspect: VideoAspect
    var showsInfo = false
    var showsStyle = false
    var showsStats = false
    var showsEpisodes = false

    let layerView = PlayerLayerView()
    /// The UI tests' stand-in for the picture.
    let stillImage: UIImage?
    let pictureInPicture: PictureInPicture?

    private unowned let session: AppSession
    let library: PlexLibrary
    private let capabilities: PlaybackCapabilities
    private let backend: any VideoBackend
    private let audioSession = AudioSession()

    private enum Stream {
        case direct
        case remux(RemuxSession)
        case transcode(String)
    }

    /// What a track change can switch inside the playing stream; anything else needs a new stream.
    private struct StreamKey: Equatable {
        var kind: PlaybackRoute.Kind
        var audio: Int?
        var burnedIn: Int?
        var remuxText: Int?
        var reencodes: Bool

        init(_ route: PlaybackRoute) {
            kind = route.kind
            audio = route.kind == .directPlay ? nil : route.audio?.id
            reencodes = route.reencodesVideo
            switch route.subtitle {
            case .burnedIn(let track): burnedIn = track.id
            case .sidecar(let track) where route.kind == .remux && !track.isImageBased: remuxText = track.id
            default: break
            }
        }
    }

    @ObservationIgnored private var request: PlaybackRequest
    @ObservationIgnored private var isFirstItem = true
    @ObservationIgnored private var mediaIndex = 0
    @ObservationIgnored private var nowPlaying: NowPlaying?
    @ObservationIgnored private var queue: PlexPlayQueue?
    @ObservationIgnored private(set) var media: PlexMedia?
    @ObservationIgnored private(set) var part: PlexPart?
    @ObservationIgnored private var handAudio: Int?
    @ObservationIgnored private var handSubtitle: SubtitleChoice?
    @ObservationIgnored private var onDeviceFailed = false
    @ObservationIgnored private var wroteBack = false
    @ObservationIgnored private var serverAudio: Int?
    @ObservationIgnored private var serverSubtitle: Int?
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var introCancelled = false
    @ObservationIgnored private var creditsDismissed = false
    @ObservationIgnored private var countdownStopped = false
    @ObservationIgnored private var markedWatched = false
    @ObservationIgnored private var nextFromStart = false
    @ObservationIgnored private var wantsPlay: Bool
    @ObservationIgnored private var resumesAfterInterruption = false
    @ObservationIgnored private var stream: Stream?
    @ObservationIgnored private var streamKey: StreamKey?
    @ObservationIgnored private var origin: TimeInterval?
    @ObservationIgnored private var landing: TimeInterval?
    @ObservationIgnored private var itemReady = false
    @ObservationIgnored private var farSeeking = false
    @ObservationIgnored private var transcodeOffset: TimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seekSerial = 0
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var reporter: TimelineReporter?
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var sidecarID: Int?
    @ObservationIgnored private var sidecar: SidecarContents?
    @ObservationIgnored private var overlayTrack: SubtitleOverlayTrack?
    @ObservationIgnored private var textCues: [TextCue] = []
    @ObservationIgnored private var lastSkip: (target: TimeInterval, at: Date, total: TimeInterval)?
    @ObservationIgnored private var menusOpen = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var stageTask: Task<Void, Never>?
    @ObservationIgnored private var sideTasks: [Task<Void, Never>] = []

    init(request: PlaybackRequest, session: AppSession, library: PlexLibrary, capabilities: PlaybackCapabilities) {
        self.request = request
        self.session = session
        self.library = library
        self.capabilities = capabilities
        item = request.item
        aspect = session.settings.aspect
        wantsPlay = !request.startsPaused
        #if DEBUG
        if let root = FakePlex.root {
            let still = StillFrameBackend(root: root)
            backend = still
            stillImage = still.image
        } else {
            backend = AVPlayerBackend()
            stillImage = nil
        }
        #else
        backend = AVPlayerBackend()
        stillImage = nil
        #endif
        // The surface is sized to the picture for every aspect, so the layer only has to fill it.
        layerView.playerLayer.videoGravity = .resize
        layerView.playerLayer.player = backend.player
        pictureInPicture = backend.player == nil ? nil : PictureInPicture(layer: layerView.playerLayer)
    }

    // MARK: Display

    /// The show for an episode, else the title.
    var title: String {
        item.type == .episode ? (item.grandparentTitle ?? item.title) : item.title
    }

    /// "S2 · E5 · Name" for an episode, the year for a film.
    var subtitleLine: String? {
        if item.type == .episode { return [item.episodeCode, item.title].compactMap { $0 }.joined(separator: " · ") }
        return item.year.map(String.init)
    }

    var stageText: String { route == nil ? "Connecting" : "Preparing" }

    var isWaiting: Bool { phase == .loading || isBuffering || landing != nil }

    /// Previous restarts the item past its first five seconds.
    var canGoBack: Bool { time >= 5 || hasPreviousItem }

    var introAutoSkips: Bool { session.settings.introSkipDelay > 0 && !introCancelled }

    var skipInterval: TimeInterval { TimeInterval(session.settings.skipInterval) }

    /// Intro and credits, as the scrubber marks them.
    var markers: [PlexMarker] {
        (item.markers(.intro) + item.markers(.credits)).sorted { $0.start < $1.start }
    }

    var subtitleChoice: SubtitleChoice {
        guard let subtitle else { return .off }
        if subtitle.isOnScreenTextOnly { return .onScreenTextOnly }
        return subtitle.track.map { .track($0.id) } ?? .off
    }

    /// Image subtitles are drawn as the file has them.
    var subtitleIsImage: Bool { subtitle?.track?.isImageBased ?? false }

    var preferredSubtitleLanguage: TrackLanguage { session.settings.subtitles.language }

    var preferredAudioLanguage: TrackLanguage? { session.settings.audioLanguage }

    /// The playing audio track's id, for the tracks menu; setting it is a hand pick.
    var audioPick: Int? {
        get { audio?.id }
        set {
            guard let newValue, let track = tracks?.audioTrack(id: newValue) else { return }
            Haptics.impact(.light)
            pickAudio(track)
        }
    }

    var subtitlePick: SubtitleChoice {
        get { subtitleChoice }
        set {
            Haptics.impact(.light)
            pickSubtitle(newValue)
        }
    }

    var aspectPick: VideoAspect {
        get { aspect }
        set { setAspect(newValue) }
    }

    var isEpisode: Bool { item.type == .episode }

    var player: AVPlayer? { backend.player }

    var remux: RemuxSession? {
        if case .remux(let remux) = stream { return remux }
        return nil
    }

    var transcodeSession: String? {
        if case .transcode(let session) = stream { return session }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        backend.onEvent = { [weak self] event in self?.handle(event) }
        pictureInPicture?.onPossibleChange = { [weak self] possible in self?.canPictureInPicture = possible }
        audioSession.onInterruption = { [weak self] began, shouldResume in self?.interrupted(began: began, shouldResume: shouldResume) }
        audioSession.onRouteLost = { [weak self] in self?.pause() }
        audioSession.activate()
        nowPlaying = NowPlaying(skipInterval: session.settings.skipInterval, actions: NowPlaying.Actions(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlay() },
            skip: { [weak self] seconds in self?.skip(by: seconds, flash: false) },
            seek: { [weak self] seconds in self?.seek(to: seconds) },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() }
        ))
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteringForeground() }
            },
        ]
        loadItem(request.item.ratingKey)
    }

    func close() {
        guard !closed else { return }
        closed = true
        report(.stopped)
        generation += 1
        for task in [loadTask, seekTask, eventsTask, countdownTask, hideTask, stageTask] { task?.cancel() }
        sideTasks.forEach { $0.cancel() }
        stopStream()
        backend.tearDown()
        pictureInPicture?.tearDown()
        layerView.playerLayer.player = nil
        nowPlaying?.end()
        audioSession.deactivate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    func retry() {
        retries = 0
        if route == nil {
            loadItem(item.ratingKey)
        } else {
            enterLoading()
            restart(at: time)
        }
    }

    // MARK: Transport

    func play() {
        wantsPlay = true
        if phase == .finished {
            replay()
        } else if phase == .playing {
            backend.play()
        }
    }

    func pause() {
        wantsPlay = false
        backend.pause()
        interruptCountdown()
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func replay() {
        phase = .playing
        creditsDismissed = false
        countdownStopped = false
        wantsPlay = true
        seek(to: 0)
        backend.play()
    }

    /// Quick skips within a second and a half add up from the last target.
    func skip(by seconds: TimeInterval, flash: Bool = true) {
        let now = Date.now
        var base = time
        var total = seconds
        if let last = lastSkip, now.timeIntervalSince(last.at) < 1.5 {
            base = last.target
            if (last.total > 0) == (seconds > 0) { total = last.total + seconds }
        }
        let target = clamp(base + seconds)
        lastSkip = (target, now, total)
        if flash {
            skipFlash = SkipFlash(forward: seconds > 0, seconds: Int(abs(total).rounded()), serial: (skipFlash?.serial ?? 0) + 1)
            userActed()
        }
        seek(to: target)
    }

    func seek(to requested: TimeInterval) {
        guard phase == .playing || phase == .finished else { return }
        if phase == .finished { phase = .playing }
        let target = clamp(requested)
        time = target
        if landing != nil {
            if farSeeking, case .remux(let remux) = stream { farSeek(remux, to: target) } else { landing = target }
            return
        }
        guard let origin else { return }
        let local = target - origin
        switch stream {
        case .remux(let remux):
            if local >= 0, local <= remux.progress.mediaSeconds - 1 { seekItem(local) } else { farSeek(remux, to: target) }
        case .transcode:
            if local >= 0, let length = backend.itemDuration, local <= length - 1 { seekItem(local) } else { restart(at: target) }
        case .direct, nil:
            seekItem(max(0, local))
        }
        publishPosition()
        report()
    }

    func previous() {
        guard !(time >= 5 || !hasPreviousItem), let target = queue?.item(before: item) else {
            seek(to: 0)
            return
        }
        go(to: target)
    }

    func next() {
        guard let target = queue?.item(after: item) else { return }
        go(to: target)
    }

    /// An episode picked in the player. One outside the play queue starts a queue of its own.
    func play(episode: PlexMetadata, fromStart: Bool) {
        guard episode.ratingKey != item.ratingKey else {
            if fromStart { seek(to: 0) }
            return
        }
        if queue?.items.contains(where: { $0.ratingKey == episode.ratingKey }) != true { queue = nil }
        nextFromStart = fromStart
        go(to: episode)
    }

    // MARK: Screen

    func toggleChrome() {
        if chromeVisible { setChrome(false) } else { showChrome() }
    }

    func showChrome() {
        if !chromeVisible { setChrome(true) }
        scheduleHide()
    }

    /// A tap on the picture: the first one only brings the controls back. A tap reaching the picture
    /// means no menu is open, whatever the menus reported.
    func tapped() {
        menusOpen = 0
        userActed()
        toggleChrome()
    }

    /// Input stops the Up Next countdown for good.
    func userActed() {
        interruptCountdown()
        scheduleHide()
    }

    func beginScrub() {
        isScrubbing = true
        hideTask?.cancel()
        interruptCountdown()
    }

    func endScrub(at target: TimeInterval) {
        isScrubbing = false
        seek(to: target)
        scheduleHide()
    }

    func menuOpened() {
        menusOpen += 1
        hideTask?.cancel()
        interruptCountdown()
    }

    func menuClosed() {
        menusOpen = max(0, menusOpen - 1)
        scheduleHide()
    }

    func setAspect(_ aspect: VideoAspect) {
        self.aspect = aspect
        scheduleHide()
    }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isActive { pictureInPicture.stop() } else { pictureInPicture.start() }
    }

    /// The profile's subtitle style changed.
    func styleChanged() {
        applyTextStyle()
    }

    // MARK: Offers

    func skipIntro() {
        guard case .skipIntro(let end)? = offer else { return }
        cancelCountdown()
        withAnimation(.easeOut(duration: 0.18)) { offer = nil }
        seek(to: end)
    }

    func watchIntro() {
        introCancelled = true
        cancelCountdown()
    }

    func watchCredits() {
        creditsDismissed = true
        cancelCountdown()
        withAnimation(.easeOut(duration: 0.18)) { offer = nil }
    }

    // MARK: Tracks

    func pickAudio(_ track: AudioTrack) {
        guard track.id != audio?.id else { return }
        handAudio = track.id
        remember()
        reroute(handPick: true)
    }

    func pickSubtitle(_ choice: SubtitleChoice) {
        guard choice != subtitleChoice else { return }
        handSubtitle = choice
        remember()
        reroute(handPick: true)
    }

    // MARK: Loading

    private func loadItem(_ ratingKey: String) {
        stopStream()
        generation += 1
        let generation = generation
        enterLoading()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                var full = try await library.metadata(ratingKey)
                guard generation == self.generation else { return }
                if queue == nil { queue = try? await library.createPlayQueue(for: full) }
                guard generation == self.generation else { return }
                if let queued = queue?.items.first(where: { $0.ratingKey == full.ratingKey }) {
                    full.playQueueItemID = queued.playQueueItemID
                }
                await begin(full, generation: generation)
            } catch {
                guard generation == self.generation, !(error is CancellationError) else { return }
                fail(Self.message(error))
            }
        }
    }

    private func begin(_ full: PlexMetadata, generation: Int) async {
        item = full
        mediaIndex = isFirstItem ? request.mediaIndex : 0
        guard let media = full.media.indices.contains(mediaIndex) ? full.media[mediaIndex] : full.media.first,
              let part = media.parts.first else {
            fail("This item has no file to play.")
            return
        }
        self.media = media
        self.part = part
        duration = Double(full.duration > 0 ? full.duration : media.duration > 0 ? media.duration : part.duration) / 1000
        let tracks = MediaTracks(part: part)
        self.tracks = tracks
        serverAudio = tracks.audio.first(where: \.isSelectedOnServer)?.id
        serverSubtitle = tracks.subtitles.first(where: \.isSelectedOnServer)?.id
        hasNext = queue?.item(after: full) != nil
        hasPreviousItem = queue?.item(before: full) != nil
        let start: TimeInterval
        if isFirstItem, let at = request.startAt {
            start = at
        } else if (isFirstItem && request.fromStart) || nextFromStart {
            start = 0
        } else {
            let offset = Double(full.viewOffset) / 1000
            start = offset > 0 && (duration == 0 || offset < duration * 0.95) ? offset : 0
        }
        isFirstItem = false
        time = start
        publishItem()
        nextFromStart = false
        loadTrickplay(part)
        await decideRoute()
        guard generation == self.generation else { return }
        await startStream(at: start, generation: generation)
    }

    private func routeLimits() -> RouteLimits {
        switch session.settings.directPlay {
        case .force: RouteLimits(phoneOnly: true)
        case .disabled: RouteLimits(serverReason: .directPlayOff)
        case .auto: RouteLimits(serverReason: onDeviceFailed ? .onDeviceFailed : nil)
        }
    }

    private func decideRoute() async {
        guard let tracks, let media, let part else { return }
        let settings = session.settings
        let memory = settings.remembersTracks ? session.trackMemory(for: item) : nil
        let picked = AudioPicker.pick(in: tracks, handPick: handAudio, remembered: memory?.audio, preferredLanguage: settings.audioLanguage)
        let device = await capabilities.current()
        var limits = routeLimits()
        func decide(drawsImages: Bool) -> (SubtitleDecision, PlaybackRoute) {
            let decision = SubtitlePicker.decide(
                tracks: tracks, audio: picked, handPick: handSubtitle, remembered: memory?.subtitle,
                settings: settings.subtitles, canDrawImageSubtitles: drawsImages
            )
            let route = PlaybackRouteDecider.decide(
                media: media, part: part, tracks: tracks, audio: picked, subtitle: decision, capabilities: device, limits: limits
            )
            return (decision, route)
        }
        var (decision, route) = decide(drawsImages: true)
        if route.kind == .remux, isExternalPlayback, settings.directPlay != .force {
            limits.serverReason = .airPlay
            (decision, route) = decide(drawsImages: true)
        }
        // A server stream shows embedded image subtitles only burned in, which an automatic pick never
        // asks for; it moves to a text track instead.
        if route.kind == .serverTranscode, decision.source != .handPick, decision.source != .remembered,
           let track = decision.track, track.isImageBased, !track.isExternal {
            (decision, route) = decide(drawsImages: false)
        }
        subtitle = decision
        self.route = route
        audio = route.audio
        subtitleProblem = nil
        switch route.subtitle {
        case .notShown(let track):
            subtitleProblem = "\(track.label) needs the server to burn it in; pick it again to allow that."
        case .sidecar(let track):
            await loadSidecar(track)
        default:
            break
        }
    }

    private func loadSidecar(_ track: SubtitleTrack) async {
        guard sidecarID != track.id else { return }
        sidecar = nil
        sidecarID = nil
        let key = part?.streams.first(where: { $0.id == track.id })?.key ?? "/library/streams/\(track.id)"
        do {
            sidecar = try await SidecarLoader.load(track, key: key, library: library, session: session.transport.session)
            sidecarID = track.id
        } catch {
            subtitleProblem = "\(track.label): \(Self.message(error))"
        }
    }

    // MARK: Streams

    private func startStream(at target: TimeInterval, generation: Int) async {
        guard let route, let part else { return }
        stopStream()
        landing = target
        origin = nil
        streamKey = StreamKey(route)
        do {
            let url: URL
            switch route.kind {
            case .directPlay:
                url = try await library.playbackURL(path: part.key)
                stream = .direct
                origin = 0
                reporter = TimelineReporter(library: library, item: item)
            case .remux:
                let base = try await library.connection.connection().uri
                guard generation == self.generation else { return }
                guard let source = PlexURL.make(base: base, path: part.key) else { throw URLError(.badURL) }
                let remux = makeRemux(source: source, part: part, route: route)
                stream = .remux(remux)
                listen(to: remux)
                reporter = TimelineReporter(library: library, item: item)
                url = try await remux.start(at: target)
            case .serverTranscode:
                try await selectForServer(route, part: part)
                let session = UUID().uuidString
                stream = .transcode(session)
                transcodeOffset = target
                reporter = TimelineReporter(library: library, item: item, sessionIdentifier: session)
                url = try await library.transcodeURL(
                    TranscodeRequest(item: item, mediaIndex: mediaIndex, route: route, offset: target, session: session)
                )
            }
            guard generation == self.generation else { return }
            applySubtitleSources()
            load(url)
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            streamFailed(Self.message(error))
        }
    }

    private func load(_ url: URL) {
        let playerItem = AVPlayerItem(asset: AVURLAsset(url: url))
        if case .remux = stream { playerItem.preferredForwardBufferDuration = RemuxSession.recommendedForwardBufferDuration }
        playerItem.textStyleRules = CaptionStyle.rules(for: session.settings.subtitleStyle, lifted: chromeVisible)
        playerItem.externalMetadata = metadataItems()
        itemReady = false
        backend.load(playerItem)
    }

    private func makeRemux(source: URL, part: PlexPart, route: PlaybackRoute) -> RemuxSession {
        var options = RemuxOptions()
        if let audio = route.audio, let index = streamIndex(audio.id) { options.audio = AudioPolicy(preferredIndex: index) }
        if let vision = part.videoStream?.dolbyVision {
            options.setDolbyVisionFallback(
                profile: vision.profile, level: vision.level ?? 0,
                compatibilityID: vision.baseLayerCompatibility ?? 0, hasEnhancementLayer: vision.hasEnhancementLayer
            )
        }
        if case .sidecar(let track) = route.subtitle, sidecarID == track.id, let sidecar, sidecar.bitmaps == nil {
            options.sidecarSubtitles = [sidecar.sidecar]
        }
        let headers = library.authorizationHeaders()
        let length = part.size.map(Int64.init)
        return RemuxSession(
            sourceFactory: { HTTPRangeSource(url: source, headers: headers, knownLength: length) },
            options: options,
            logger: EngineLog.logger
        )
    }

    /// The server streams the part's selected audio, and burns in its selected subtitle when asked to.
    private func selectForServer(_ route: PlaybackRoute, part: PlexPart) async throws {
        let audioID = route.audio?.id ?? serverAudio
        var subtitleID = serverSubtitle
        if case .burnedIn(let track) = route.subtitle { subtitleID = track.id }
        guard audioID != serverAudio || subtitleID != serverSubtitle else { return }
        try await library.selectStreams(partID: part.id, audioStreamID: audioID, subtitleStreamID: subtitleID)
        serverAudio = audioID
        serverSubtitle = subtitleID
    }

    private func listen(to remux: RemuxSession) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in remux.events {
                guard let self, case .remux(let current) = stream, current === remux else { return }
                switch event {
                case .opened(let info):
                    mediaInfo = info
                case .timeline(let origin):
                    if self.origin == nil {
                        self.origin = origin
                        land()
                    }
                case .failed(let error, _):
                    streamFailed(error.localizedDescription)
                default:
                    break
                }
            }
        }
    }

    private func stopStream() {
        eventsTask?.cancel()
        eventsTask = nil
        seekTask?.cancel()
        seekTask = nil
        backend.load(nil)
        itemReady = false
        farSeeking = false
        switch stream {
        case .remux(let remux):
            remux.stop()
        case .transcode(let session):
            let library = library
            Task { try? await library.stopTranscode(session: session) }
        case .direct, nil:
            break
        }
        stream = nil
        mediaInfo = nil
    }

    /// A new stream at `target` on the same route, keeping the screen as it is.
    private func restart(at target: TimeInterval) {
        generation += 1
        let generation = generation
        loadTask?.cancel()
        isBuffering = true
        loadTask = Task { [weak self] in await self?.startStream(at: target, generation: generation) }
    }

    /// A track change: decides again, then switches inside the stream or starts a new one.
    private func reroute(handPick: Bool) {
        generation += 1
        let generation = generation
        loadTask?.cancel()
        let at = time
        loadTask = Task { [weak self] in
            guard let self else { return }
            let previous = streamKey
            await decideRoute()
            guard generation == self.generation, let route else { return }
            if StreamKey(route) != previous || stream == nil {
                isBuffering = true
                await startStream(at: at, generation: generation)
            } else {
                applySubtitleSources()
                await applySelection()
            }
            if handPick { writeBack() }
        }
    }

    private func streamFailed(_ message: String) {
        guard !closed, phase != .finished, let route else {
            fail(message)
            return
        }
        let at = time
        generation += 1
        let generation = generation
        loadTask?.cancel()
        switch route.kind {
        case .directPlay, .remux:
            guard session.settings.directPlay != .force, !onDeviceFailed else {
                fail(message)
                return
            }
            onDeviceFailed = true
            fallback = message
            stopStream()
            enterLoading()
            loadTask = Task { [weak self] in
                guard let self else { return }
                await decideRoute()
                guard generation == self.generation else { return }
                await startStream(at: at, generation: generation)
            }
        case .serverTranscode:
            // The server can refuse a new session for a minute or more after a quick stop.
            let delays: [TimeInterval] = [2, 5, 10, 20, 30]
            guard retries < delays.count else {
                fail(message)
                return
            }
            let delay = delays[retries]
            retries += 1
            stopStream()
            enterLoading()
            loadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                await startStream(at: at, generation: generation)
            }
        }
    }

    private func fail(_ message: String) {
        stopStream()
        report(.stopped)
        stageTask?.cancel()
        showsStage = false
        cancelCountdown()
        offer = nil
        landing = nil
        isBuffering = false
        phase = .failed(message)
        chromeVisible = true
    }

    private func enterLoading() {
        phase = .loading
        showsStage = false
        stageTask?.cancel()
        stageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, phase == .loading else { return }
            showsStage = true
        }
    }

    private func go(to target: PlexMetadata) {
        report(.stopped)
        stopStream()
        handAudio = nil
        handSubtitle = nil
        onDeviceFailed = false
        fallback = nil
        wroteBack = false
        retries = 0
        introCancelled = false
        creditsDismissed = false
        countdownStopped = false
        markedWatched = false
        cancelCountdown()
        offer = nil
        sidecar = nil
        sidecarID = nil
        route = nil
        subtitle = nil
        subtitleProblem = nil
        trickplay = nil
        reporter = nil
        lastSkip = nil
        wantsPlay = true
        applySubtitleSources()
        loadItem(target.ratingKey)
    }

    // MARK: Landing

    private func handle(_ event: BackendEvent) {
        switch event {
        case .time(let itemTime):
            tick(itemTime)
        case .state(let playing, let buffering):
            stateChanged(playing: playing, buffering: buffering)
        case .ready:
            itemReady = true
            if case .transcode = stream, origin == nil {
                // Some servers list the whole film whatever the offset; the stream then starts at zero.
                if let length = backend.itemDuration, duration > 0, length >= duration - 30 { origin = 0 } else { origin = transcodeOffset }
            }
            land()
        case .failed(let message):
            streamFailed(message)
        case .ended:
            ended()
        case .externalPlayback(let active):
            externalPlaybackChanged(active)
        case .presentationSize(let size):
            presentationSize = size
        }
    }

    /// Moves a new stream to where playback should be, once it is ready and its origin known.
    private func land() {
        guard itemReady, let origin, let target = landing else { return }
        if farSeeking, case .remux(let remux) = stream, target < origin - 0.5 {
            farSeek(remux, to: target)
            return
        }
        let local = max(0, target - origin)
        seekSerial += 1
        let serial = seekSerial
        let generation = generation
        seekTask = Task { [weak self] in
            guard let self else { return }
            if local > 0.5 { _ = await backend.seek(to: local, precise: true) }
            guard generation == self.generation, serial == seekSerial else { return }
            landing = nil
            farSeeking = false
            isBuffering = false
            await arrived()
        }
    }

    private func arrived() async {
        retries = 0
        let wasLoading = phase != .playing
        phase = .playing
        stageTask?.cancel()
        showsStage = false
        await applySelection()
        if !wroteBack {
            wroteBack = true
            writeBack()
        }
        if wantsPlay { backend.play() }
        if let origin { time = backend.itemTime + origin }
        publishPosition()
        report()
        if wasLoading { scheduleHide() }
    }

    private func seekItem(_ local: TimeInterval) {
        seekSerial += 1
        let serial = seekSerial
        isSeeking = true
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            guard let self else { return }
            _ = await backend.seek(to: local, precise: true)
            guard serial == seekSerial else { return }
            isSeeking = false
            publishPosition()
        }
    }

    /// A seek outside what the remux has written restarts it there; quick repeats wait for the last.
    private func farSeek(_ remux: RemuxSession, to target: TimeInterval) {
        landing = target
        farSeeking = true
        isBuffering = true
        seekSerial += 1
        let serial = seekSerial
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, serial == seekSerial, !Task.isCancelled, case .remux(let current) = stream, current === remux else { return }
            // The old item is let go first, so its end does not count as a failure.
            backend.load(nil)
            itemReady = false
            origin = nil
            do {
                let url = try await remux.seek(to: target)
                guard serial == seekSerial, case .remux(let current) = stream, current === remux else { return }
                load(url)
            } catch {
                guard serial == seekSerial, !(error is CancellationError) else { return }
                streamFailed(Self.message(error))
            }
        }
    }

    private func tick(_ itemTime: TimeInterval) {
        guard let origin, landing == nil else { return }
        if case .remux(let remux) = stream { remux.updatePlayhead(itemTime) }
        guard !isSeeking else { return }
        let movie = itemTime + origin
        if !isScrubbing { time = movie }
        updateSubtitles(at: movie)
        updateOffers(at: movie)
        if !markedWatched, duration > 0, movie >= duration * 0.9 { markWatched() }
        if Date.now.timeIntervalSince(lastReport) >= 1 { report() }
    }

    private func stateChanged(playing: Bool, buffering: Bool) {
        isPlaying = playing
        isBuffering = buffering || landing != nil
        if !playing || buffering {
            if case .upNext? = offer { interruptCountdown() } else { cancelCountdown() }
        } else {
            startCountdownIfDue()
        }
        report()
        publishPosition()
        if playing { scheduleHide() } else { hideTask?.cancel() }
    }

    private func ended() {
        if case .upNext? = offer, countdown != nil {
            next()
            return
        }
        if !markedWatched { markWatched() }
        report(.stopped)
        cancelCountdown()
        offer = nil
        isPlaying = false
        phase = .finished
        publishPosition()
    }

    private func externalPlaybackChanged(_ active: Bool) {
        isExternalPlayback = active
        PlaybackCapabilities.externalPlaybackActive = active
        // An AirPlay receiver cannot reach the remux's address on the phone.
        guard active, case .remux = stream, session.settings.directPlay != .force else { return }
        reroute(handPick: false)
    }

    // MARK: Subtitles

    private func applySubtitleSources() {
        textCues = []
        overlayTrack = nil
        cueText = nil
        bitmaps = []
        guard let route else { return }
        switch route.subtitle {
        case .sidecar(let track):
            guard sidecarID == track.id, let sidecar else { return }
            if let images = sidecar.bitmaps {
                overlayTrack = images
            } else if route.kind != .remux {
                textCues = sidecar.cues
            }
        case .inStream(let track) where route.kind == .remux && track.isImageBased:
            guard case .remux(let remux) = stream, let index = streamIndex(track.id) else { return }
            overlayTrack = remux.subtitleStreams.first { $0.streamIndex == index }?.overlay
        default:
            break
        }
    }

    /// Picks the audio and text tracks AVPlayer plays from the stream.
    private func applySelection() async {
        guard let player = backend.player, let playerItem = player.currentItem, let route, let tracks else { return }
        if case .inStream(let track) = route.subtitle, route.kind == .remux, track.isImageBased {
            applySubtitleSources()
        }
        let asset = playerItem.asset
        if route.kind == .directPlay, let audio = route.audio, let position = tracks.audio.firstIndex(where: { $0.id == audio.id }) {
            await MediaSelection.select(audioPosition: position, language: audio.language.code, in: playerItem, asset: asset)
        }
        await MediaSelection.select(legible(for: route, tracks: tracks), in: playerItem, asset: asset)
    }

    private func legible(for route: PlaybackRoute, tracks: MediaTracks) -> MediaSelection.Legible {
        switch route.subtitle {
        case .inStream(let track):
            if track.isInVideoStream { return .closedCaptions }
            if route.kind == .remux {
                guard !track.isImageBased, case .remux(let remux) = stream, let index = streamIndex(track.id),
                      let rendition = remux.subtitleStreams.first(where: { $0.streamIndex == index }) else { return .none }
                return .named(rendition.name)
            }
            let embedded = tracks.subtitles.filter { !$0.isExternal && !$0.isInVideoStream }
            return .position(embedded.firstIndex { $0.id == track.id } ?? 0, language: track.language.code)
        case .sidecar(let track) where route.kind == .remux && !track.isImageBased && sidecar?.bitmaps == nil:
            return .named(SidecarLoader.name(track))
        default:
            return .none
        }
    }

    private func updateSubtitles(at movie: TimeInterval) {
        if let overlayTrack {
            let shown = overlayTrack.bitmaps(at: movie)
            if shown.map(\.start) != bitmaps.map(\.start) || shown.map(\.y) != bitmaps.map(\.y) { bitmaps = shown }
        }
        guard !textCues.isEmpty else { return }
        var text: AttributedString?
        for cue in textCues where cue.start <= movie && movie < cue.end {
            if var joined = text {
                joined += AttributedString("\n")
                joined += cue.text
                text = joined
            } else {
                text = cue.text
            }
        }
        if text != cueText { cueText = text }
    }

    private func applyTextStyle() {
        backend.player?.currentItem?.textStyleRules = CaptionStyle.rules(for: session.settings.subtitleStyle, lifted: chromeVisible)
    }

    // MARK: Offers

    private var finalCredits: PlexMarker? {
        let credits = item.markers(.credits)
        return credits.first(where: \.isFinal) ?? credits.last
    }

    private func updateOffers(at movie: TimeInterval) {
        let ms = Int(movie * 1000)
        var next: Offer?
        if let intro = item.markers(.intro).first(where: { $0.contains(ms) }), Double(intro.end) / 1000 - movie > 1 {
            next = .skipIntro(end: Double(intro.end) / 1000)
        } else if !creditsDismissed, let credits = finalCredits, ms >= credits.start, let upcoming = queue?.item(after: item) {
            next = .upNext(upcoming)
        }
        guard next != offer else { return }
        cancelCountdown()
        withAnimation(.easeOut(duration: 0.22)) { offer = next }
        startCountdownIfDue()
    }

    private func startCountdownIfDue() {
        guard countdown == nil, phase == .playing, isPlaying, !isBuffering else { return }
        let settings = session.settings
        switch offer {
        case .skipIntro?:
            guard settings.introSkipDelay > 0, !introCancelled else { return }
            runCountdown(TimeInterval(settings.introSkipDelay)) { [weak self] in self?.skipIntro() }
        case .upNext?:
            guard settings.nextEpisodeDelay > 0, !countdownStopped, menusOpen == 0, !isScrubbing else { return }
            runCountdown(TimeInterval(settings.nextEpisodeDelay)) { [weak self] in self?.next() }
        case nil:
            break
        }
    }

    private func runCountdown(_ length: TimeInterval, then action: @escaping @MainActor () -> Void) {
        countdown = Countdown(start: .now, length: length)
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length))
            guard let self, !Task.isCancelled, countdown != nil else { return }
            countdown = nil
            action()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    /// Pause, buffering, menus and any input stop the Up Next countdown until the next episode.
    private func interruptCountdown() {
        guard case .upNext? = offer, countdown != nil else { return }
        cancelCountdown()
        countdownStopped = true
    }

    // MARK: Server

    private func report(_ state: PlaybackState? = nil) {
        guard let reporter, duration > 0 else { return }
        lastReport = .now
        let state = state ?? (isBuffering ? .buffering : isPlaying ? .playing : .paused)
        let time = Int(self.time * 1000), length = Int(duration * 1000)
        Task { await reporter.update(state, time: time, duration: length) }
    }

    private func markWatched() {
        markedWatched = true
        let library = library, key = item.ratingKey
        Task { try? await library.markWatched(key) }
    }

    /// Saves the playing tracks as the part's selection, once per fresh playback on the phone and per
    /// hand pick. Server streams set it before they start.
    private func writeBack() {
        guard let route, route.kind != .serverTranscode, let part else { return }
        let audioID = route.audioIsStandIn ? serverAudio : route.audio?.id ?? serverAudio
        let subtitleID: Int? = switch route.subtitle {
        case .sidecar(let track), .inStream(let track): track.id
        case .none, .burnedIn, .notShown: nil
        }
        guard audioID != serverAudio || subtitleID != serverSubtitle else { return }
        serverAudio = audioID
        serverSubtitle = subtitleID
        let library = library
        Task { try? await library.selectStreams(partID: part.id, audioStreamID: audioID, subtitleStreamID: subtitleID) }
    }

    private func remember() {
        guard session.settings.remembersTracks, let tracks else { return }
        var memory = session.trackMemory(for: item) ?? TrackMemory()
        if let id = handAudio, let track = tracks.audioTrack(id: id) { memory.audio = RememberedAudio(track) }
        if let choice = handSubtitle { memory.subtitle = RememberedSubtitle(choice, in: tracks) }
        session.remember(memory, for: item)
    }

    // MARK: System

    private func publishItem() {
        nowPlaying?.setItem(title: title, subtitle: subtitleLine, duration: duration)
        nowPlaying?.setQueue(hasNext: hasNext, hasPrevious: hasPreviousItem)
        let path = item.type == .episode ? (item.grandparentThumb ?? item.thumb) : item.thumb
        guard let path else { return }
        let request = ArtRequest(source: path, pointSize: CGSize(width: 300, height: 450), scale: 2, server: library.server.id)
        let library = library
        sideTasks.append(Task { [weak self] in
            guard let image = try? await ImagePipeline.shared.image(request, library: library) else { return }
            self?.nowPlaying?.setArtwork(image)
        })
    }

    private func publishPosition() {
        nowPlaying?.update(time: time, rate: isPlaying && !isBuffering ? 1 : 0)
    }

    private func loadTrickplay(_ part: PlexPart) {
        trickplay = nil
        guard part.hasSceneThumbnails else { return }
        let library = library, urlSession = session.transport.session, key = item.ratingKey
        sideTasks.append(Task { [weak self] in
            guard let data = try? await PlexFetch.data("/library/parts/\(part.id)/indexes/sd", library: library, session: urlSession),
                  let self, item.ratingKey == key else { return }
            trickplay = Trickplay(data: data)
        })
    }

    private func metadataItems() -> [AVMetadataItem] {
        func entry(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let entry = AVMutableMetadataItem()
            entry.identifier = identifier
            entry.value = value as NSString
            entry.extendedLanguageTag = "und"
            return entry
        }
        var items = [entry(.commonIdentifierTitle, title)]
        if let subtitleLine { items.append(entry(.iTunesMetadataTrackSubTitle, subtitleLine)) }
        if !item.summary.isEmpty { items.append(entry(.commonIdentifierDescription, item.summary)) }
        return items
    }

    private func setChrome(_ visible: Bool) {
        withAnimation(.easeOut(duration: visible ? 0.12 : 0.18)) { chromeVisible = visible }
        applyTextStyle()
        if !visible { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard chromeVisible, isPlaying, !isScrubbing, menusOpen == 0, phase == .playing,
              !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            setChrome(false)
        }
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        if began {
            resumesAfterInterruption = isPlaying
            pause()
        } else if shouldResume, resumesAfterInterruption {
            play()
        }
    }

    /// Without Picture in Picture or AirPlay the sound plays on alone: a layer showing video would
    /// make the system pause it.
    private func enteredBackground() {
        guard !(pictureInPicture?.isActive ?? false), !isExternalPlayback else { return }
        layerView.playerLayer.player = nil
    }

    private func enteringForeground() {
        layerView.playerLayer.player = backend.player
    }

    // MARK: Helpers

    private func clamp(_ seconds: TimeInterval) -> TimeInterval {
        min(max(0, seconds), max(0, duration - 1))
    }

    private func streamIndex(_ id: Int) -> Int? {
        part?.streams.first { $0.id == id }?.index
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The one playback at a time. `presented` drives the full-screen player; `active` stays while Picture
/// in Picture carries the playback without it.
@MainActor @Observable
final class PlayerCenter {
    var presented: PlayerModel?
    private(set) var active: PlayerModel?
    let capabilities = PlaybackCapabilities()

    init() {
        RemuxSession.sweepStaleFiles()
        capabilities.startWatching()
    }

    func play(_ request: PlaybackRequest, session: AppSession) {
        guard let library = session.library else { return }
        stopAll()
        let model = PlayerModel(request: request, session: session, library: library, capabilities: capabilities)
        if let pictureInPicture = model.pictureInPicture {
            pictureInPicture.onStart = { [weak self, weak model] in
                guard let self, let model, presented === model else { return }
                presented = nil
            }
            pictureInPicture.onRestore = { [weak self, weak model] completion in
                guard let self, let model, active === model else {
                    completion(false)
                    return
                }
                presented = model
                // The screen has to host the picture again before the window shrinks into it.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    completion(true)
                }
            }
            pictureInPicture.onClose = { [weak self, weak model] in
                guard let self, let model, active === model, presented == nil else { return }
                model.close()
                active = nil
            }
        }
        active = model
        presented = model
        model.start()
    }

    func close(_ model: PlayerModel) {
        if presented === model { presented = nil }
        if active === model {
            model.close()
            active = nil
        }
    }

    /// The full-screen player went away: playback ends unless Picture in Picture carries it.
    func dismissed() {
        guard presented == nil, let model = active, !(model.pictureInPicture?.isActive ?? false) else { return }
        model.close()
        active = nil
    }

    func stopAll() {
        active?.close()
        active = nil
        presented = nil
    }
}
