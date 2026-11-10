import AVFoundation
import MarqueeCore
import Observation
import SwiftUI
import UIKit
import VideoEngine

/// What Play asked for.
struct PlaybackRequest {
    var item: PlexMetadata
    var download: DownloadRecord?
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

    /// What a start waits for, in the order it passes through them.
    enum LoadStage: Equatable {
        case connecting
        case opening
        /// A server transcode, until AVPlayer can play it.
        case preparing
        /// The share of a remux's start lead in hand (`RemuxHandOff`).
        case buffering(Double)
        case starting
    }

    enum Offer: Equatable {
        case skipIntro(end: TimeInterval)
        case upNext(PlexMetadata)
        /// After 10 s waiting on the network: the same video at this quality, for the rest of this playback.
        case lowerQuality(VideoQuality)

        static func == (lhs: Offer, rhs: Offer) -> Bool {
            switch (lhs, rhs) {
            case let (.skipIntro(a), .skipIntro(b)): a == b
            case let (.upNext(a), .upNext(b)): a.ratingKey == b.ratingKey
            case let (.lowerQuality(a), .lowerQuality(b)): a == b
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

    /// The stuck remux runs restarted at the playhead on this item: how many, and the last one's place,
    /// output in hand and cause.
    struct Recoveries: Equatable {
        var count: Int
        var at: TimeInterval
        var ahead: TimeInterval
        var cause: StallWatch.Cause
    }

    /// The current-subtitle manager and provider-neutral search.
    enum SubtitleSheet: Identifiable {
        case subtitles
        case wrong
        case search

        var id: Self { self }
    }

    nonisolated let id = UUID()

    private(set) var item: PlexMetadata
    private(set) var phase: Phase = .loading
    /// A second into loading the stage word shows.
    private(set) var showsStage = false
    private(set) var loadStage: LoadStage = .connecting
    /// How long this item's start took to reach each step, for stats for nerds.
    private(set) var startTiming = StartTiming()
    private(set) var route: PlaybackRoute?
    /// Why the phone's own route was given up for the server's: the error's domain and code, for stats and
    /// Playback info. The banner says only that the server took over.
    private(set) var fallback: String?
    /// The technical side of a failure the card shows in plain words.
    private(set) var failureDetail: String?
    /// The address the stream comes from.
    private(set) var streamConnection: PlexConnection?
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
    /// Playback waits on data in mid-play: taps on the picture bring the controls rather than skip.
    private(set) var isStalled = false
    /// The wait has lasted 2 s on the link to the server; said under the ring.
    private(set) var waitsForNetwork = false
    private(set) var recoveries: Recoveries?
    private(set) var presentationSize: CGSize = .zero
    private(set) var isExternalPlayback = false
    private(set) var canPictureInPicture = false
    /// The Chromecast playing this item, while one does.
    private(set) var castDevice: CastDevice?
    private(set) var trickplay: Trickplay?
    private(set) var offer: Offer?
    private(set) var countdown: Countdown?
    private(set) var cueText: AttributedString?
    /// Reveal as Spoken: how much shows of each word of `cueText` still appearing.
    private(set) var cueWords: [RevealedWord] = []
    private(set) var bitmaps: [SubtitleBitmap] = []
    /// How far the subtitles are moved from their own times, for this item only.
    private(set) var timing = SubtitleTiming()
    /// The timing control over the picture.
    private(set) var showsTiming = false
    private(set) var skipFlash: SkipFlash?
    private(set) var mediaInfo: MediaInfo?
    private(set) var hasNext = false
    private(set) var hasPreviousItem = false
    private(set) var chromeVisible = true
    private(set) var isScrubbing = false
    private(set) var aspect: VideoAspect
    /// Playback speed, 1 for normal; back to normal for each new item.
    private(set) var speed: Float = 1
    /// Boost dialog and Normalize loudness for this video.
    private(set) var enhancements = EnhancementState()
    /// The server refused them on this item: off until the next one.
    @ObservationIgnored private var enhancementRefused = false

    struct EnhancementState: Equatable {
        /// The server is the owner's with Plex Pass; without it the toggles do not show.
        var offered = false
        var asked: AudioEnhancements = []
        /// Why they do not apply to this video; nil when they do.
        var unavailable: String?
        /// Under the toggles while one applies.
        var note: String?
    }

    /// The quality setting this playback follows: Settings', or the fixed quality a long wait on the network
    /// offered, which lasts for this playback (`qualityCap`). Picking one here changes Settings' too and lifts
    /// the cap.
    var qualitySetting: QualitySetting { qualityCap.map(QualitySetting.fixed) ?? session.settings.quality }
    /// The highest quality videos play at: the fixed one, or Auto's rung.
    var quality: VideoQuality {
        if case .fixed(let fixed) = qualitySetting { return fixed }
        return autoRung
    }
    private(set) var qualityCap: VideoQuality?
    /// Auto's rung on this item (docs/adaptive-playback.md); Original while Auto does not adapt.
    private(set) var autoRung = VideoQuality.original
    /// Where the phone is from the server, for Auto and stats for nerds.
    private(set) var place: NetworkPlace?
    /// Auto's estimate of the link to the server, for stats for nerds.
    private(set) var linkEstimateKbps: Int?
    private(set) var belowQualityFloor = false
    var showsInfo = false
    var showsStyle = false
    var showsStats = false
    var showsEpisodes = false
    var subtitleSheet: SubtitleSheet?
    /// The playing item's subtitle removal, search and downloads.
    private(set) var subtitleFix: SubtitleFix?

    let layerView = PlayerLayerView()
    /// The UI tests' stand-in for the picture.
    let stillImage: UIImage?
    let pictureInPicture: PictureInPicture?

    private unowned let session: AppSession
    let library: PlexLibrary
    let capabilities: PlaybackCapabilities
    private let backend: any VideoBackend
    private let audioSession = AudioSession()
    private let streamText = StreamText()

    private enum Stream {
        case direct
        case remux(RemuxSession)
        case transcode(String)
    }

    /// The stream Auto moves to, open on the backend's standby player until the playhead reaches its start.
    private struct Standby {
        var rung: VideoQuality
        var choice: RouteChoice
        var stream: Stream
        var reporter: TimelineReporter
        var connection: PlexConnection?
        /// The server stream's offset; 0 for the file.
        var offset: TimeInterval
        var origin: TimeInterval
        var preparationDeadline: TimeInterval?
    }

    /// A route decided at one quality, taken on when its stream plays (`take`).
    private struct RouteChoice {
        var subtitle: SubtitleDecision
        var route: PlaybackRoute
        var enhancements: EnhancementState
    }

    /// What a track change can switch inside the playing stream; anything else needs a new stream.
    private struct StreamKey: Equatable {
        var kind: PlaybackRoute.Kind
        var audio: Int?
        var burnedIn: Int?
        var remuxText: Int?
        var reencodes: Bool
        var bitrate: Int?
        var resolution: String?

        init(_ route: PlaybackRoute) {
            kind = route.kind
            audio = route.kind == .directPlay ? nil : route.audio?.id
            reencodes = route.reencodesVideo
            bitrate = route.maxVideoBitrateKbps
            resolution = route.videoResolution
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
    /// When Restart was last pressed on this item.
    @ObservationIgnored private var lastPreviousPress: Date?
    @ObservationIgnored private var landing: TimeInterval?
    @ObservationIgnored private var itemReady = false
    @ObservationIgnored private var farSeeking = false
    @ObservationIgnored private var remuxFinished = false
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
    @ObservationIgnored private var wordTiming: WordTiming?
    @ObservationIgnored private var lastSkip: (target: TimeInterval, at: Date, total: TimeInterval)?
    @ObservationIgnored private var menusOpen = 0
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var stageTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var stallWatch = StallWatch()
    @ObservationIgnored private var sideTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var trickplayLoad: (part: Int, task: Task<Void, Never>, waits: Bool)?
    @ObservationIgnored private var castProgress: CastProgress?
    @ObservationIgnored private var castTask: Task<Void, Never>?
    /// The server stream a Chromecast plays, stopped with the cast.
    @ObservationIgnored private var castSession: String?
    /// Where a seek sent the receiver, shown until its next status.
    @ObservationIgnored private var castSeekTarget: TimeInterval?
    /// The receiver could not open the file itself, so the server streams it.
    @ObservationIgnored private var castReceiverFailed = false
    /// Auto's rung keeper while it adapts: Auto picked and not Force Direct Play.
    @ObservationIgnored private var adaptive: AdaptiveQuality?
    @ObservationIgnored private var qualityTask: Task<Void, Never>?
    @ObservationIgnored private var moveTask: Task<Void, Never>?
    /// Auto asked for a rung and the move has not settled (`settleMove`).
    @ObservationIgnored private var movePending = false
    @ObservationIgnored private var standby: Standby?
    /// The playing item's transfer totals at Auto's last look.
    @ObservationIgnored private var lastTransfer: (bytes: Int64, seconds: TimeInterval)?
    /// The longest wait on the network since Auto's last look.
    @ObservationIgnored private var longestWait: TimeInterval = 0
    @ObservationIgnored private var viewport = CGSize.zero
    @ObservationIgnored private var viewportScale: CGFloat = 1
    @ObservationIgnored private var streamNetworkRevision = -1

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

    var stageText: String {
        switch loadStage {
        case .connecting: "Connecting to \(library.server.name)"
        case .opening: "Opening the file"
        case .preparing: "\(library.server.name) is preparing the video"
        case .buffering(let share): "Buffering \(Int(share * 100))%"
        case .starting: "Starting"
        }
    }

    /// The share of the wait in hand while one is measured; nil while the wait has no measure.
    var loadFraction: Double? {
        if case .buffering(let share) = loadStage { return share }
        return nil
    }

    var isWaiting: Bool { phase == .loading || isBuffering || landing != nil }

    /// What the next press of Restart does (`PreviousPress`): the start of this item, or the previous one.
    var previousAction: PreviousPress.Action {
        PreviousPress.action(
            position: time, sincePreviousPress: lastPreviousPress.map { Date.now.timeIntervalSince($0) },
            hasPreviousItem: hasPreviousItem
        )
    }

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

    /// Image subtitles keep their own size and position; the look's colour tints them.
    var subtitleIsImage: Bool { subtitle?.track?.isImageBased ?? false }

    /// The viewer's languages for the subtitle menu, most wanted first: the subtitle setting, the playing
    /// audio, the phone's own.
    var subtitleLanguages: [TrackLanguage] {
        [session.settings.subtitles.language] + [audio?.language].compactMap { $0 }
            + Locale.preferredLanguages.map { TrackLanguage(tag: $0) }
    }

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

    var qualityPick: QualitySetting {
        get { qualitySetting }
        set { setQuality(newValue) }
    }

    var speedPick: Float {
        get { speed }
        set { setSpeed(newValue) }
    }

    /// The picture is being re-encoded at Original quality, for the More menu's "Original · Converted".
    var isConverting: Bool { route?.reencodesVideo == true }
    var forcesDirectPlay: Bool { session.settings.directPlay == .force }

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
        session.downloads.setPlaybackActive(true)
        backend.onEvent = { [weak self] event in self?.handle(event) }
        pictureInPicture?.onPossibleChange = { [weak self] possible in self?.canPictureInPicture = possible }
        pictureInPicture?.onActiveChange = { [weak self] _ in self?.textRendererChanged() }
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
        if request.download == nil {
            session.cast.player = self
            session.cast.beginSearch()
        }
        loadItem(request.item.ratingKey)
        if request.download == nil { watchQuality() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        report(.stopped)
        session.downloads.setPlaybackActive(false)
        generation += 1
        wordTiming?.stop()
        wordTiming = nil
        for task in [loadTask, queueTask, seekTask, eventsTask, countdownTask, hideTask, stageTask, stallTask, qualityTask, moveTask, trickplayLoad?.task] {
            task?.cancel()
        }
        sideTasks.forEach { $0.cancel() }
        subtitleFix?.cancel()
        stopStream()
        backend.tearDown()
        pictureInPicture?.tearDown()
        layerView.playerLayer.player = nil
        nowPlaying?.end()
        audioSession.deactivate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        // Nothing would control the receiver once the player is gone.
        if request.download == nil {
            if session.cast.player === self { session.cast.player = nil }
            session.cast.disconnect()
            session.cast.endSearch()
        }
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
            if castDevice != nil { session.cast.play() } else { backend.play() }
        }
    }

    func pause() {
        wantsPlay = false
        abandonMove()
        if castDevice != nil { session.cast.pause() } else { backend.pause() }
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
        if castDevice == nil {
            backend.play()
        } else if castProgress?.state != .stopped {
            session.cast.play()
        }
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
        abandonMove()
        let target = clamp(requested)
        time = target
        if castDevice != nil {
            // A receiver that has finished holds nothing to seek in.
            if castProgress == nil || castProgress?.state == .stopped {
                restart(at: target)
            } else {
                castSeekTarget = target
                session.cast.seek(to: target)
            }
            publishPosition()
            report()
            return
        }
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
        if previousAction == .previousItem, let target = queue?.item(before: item) {
            go(to: target)
            return
        }
        lastPreviousPress = .now
        seek(to: 0)
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
        loadTrickplay(now: true)
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

    func setQuality(_ setting: QualitySetting) {
        scheduleHide()
        let playing = quality
        qualityCap = nil
        if setting != session.settings.quality { session.settings.quality = setting }
        abandonMove()
        startAdapting(connection: streamConnection)
        if quality != playing { reroute(handPick: false) }
    }

    func setSpeed(_ speed: Float) {
        self.speed = speed
        backend.rate = speed
        scheduleHide()
    }

    func toggleEnhancement(_ enhancement: AudioEnhancements) {
        session.settings.audioEnhancements.formSymmetricDifference(enhancement)
        scheduleHide()
        reroute(handPick: false)
    }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isActive { pictureInPicture.stop() } else { pictureInPicture.start() }
    }

    /// The profile's subtitle style changed.
    func styleChanged() {
        applyTextStyle()
        updateWordTiming()
        updateSubtitles(at: time)
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

    /// Takes a long network wait's offer: this playback goes on at the lower quality.
    func playAtLowerQuality() {
        guard case .lowerQuality(let lower)? = offer else { return }
        qualityCap = lower
        // Before the route is decided again, or the next look would offer a lower quality still.
        forgetWait()
        reroute(handPick: false)
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
        #if DEBUG
        if let held = Self.heldStage {
            stageTask?.cancel()
            loadStage = held
            showsStage = true
            return
        }
        #endif
        startTiming = StartTiming()
        speed = 1
        backend.rate = 1
        enhancementRefused = false
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                var full: PlexMetadata
                if let download = request.download {
                    full = try session.downloads.store.offlineItem(for: download)
                } else {
                    full = try await library.metadata(ratingKey)
                }
                guard generation == self.generation else { return }
                startTiming.mark(.metadata)
                if let queued = queue?.items.first(where: { $0.ratingKey == full.ratingKey }) {
                    full.playQueueItemID = queued.playQueueItemID
                } else if queue == nil && request.download == nil {
                    makeQueue(for: full)
                }
                await begin(full, generation: generation)
            } catch {
                guard generation == self.generation, !(error is CancellationError) else { return }
                fail(Self.message(error))
            }
        }
    }

    /// The play queue is made beside the start rather than before it: on the server it took 71–104 ms of
    /// every start. Next, Previous and the timeline's queue item follow when it arrives.
    private func makeQueue(for full: PlexMetadata) {
        queueTask?.cancel()
        queueTask = Task { [weak self] in
            guard let self else { return }
            guard let made = try? await library.createPlayQueue(for: full), !Task.isCancelled,
                  queue == nil, item.ratingKey == full.ratingKey else { return }
            queue = made
            startTiming.mark(.queue)
            hasNext = made.item(after: item) != nil
            hasPreviousItem = made.item(before: item) != nil
            nowPlaying?.setQueue(hasNext: hasNext, hasPrevious: hasPreviousItem)
            if let id = made.items.first(where: { $0.ratingKey == full.ratingKey })?.playQueueItemID {
                item.playQueueItemID = id
                await reporter?.queued(as: id)
            }
        }
    }

    #if DEBUG
    /// `-marquee.uitest.loadStage` holds the loading screen at one stage for the ring's screenshots:
    /// connecting, opening, preparing, starting, or buffering with its share, as in buffering:0.42.
    private static var heldStage: LoadStage? {
        guard FakePlex.isActive, let value = UserDefaults.standard.string(forKey: "marquee.uitest.loadStage") else { return nil }
        let parts = value.split(separator: ":").map(String.init)
        switch parts.first ?? "" {
        case "connecting": return .connecting
        case "opening": return .opening
        case "preparing": return .preparing
        case "starting": return .starting
        case "buffering": return .buffering(parts.count > 1 ? Double(parts[1]) ?? 0 : 0)
        default: return nil
        }
    }
    #endif

    private func begin(_ full: PlexMetadata, generation: Int) async {
        item = full
        stallWatch = StallWatch()
        recoveries = nil
        if subtitleFix?.ratingKey != full.ratingKey {
            subtitleFix?.cancel()
            subtitleFix = nil
            subtitleSheet = nil
        }
        mediaIndex = isFirstItem && (request.download == nil || request.download?.quality == .original) ? request.mediaIndex : 0
        if isFirstItem, request.download == nil, request.item.media.indices.contains(request.mediaIndex),
           request.item.media[request.mediaIndex].isDVRRecording {
            guard let index = full.index(ofMediaID: request.item.media[request.mediaIndex].id) else {
                fail("The recorded version is no longer available.")
                return
            }
            mediaIndex = index
        }
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
        // Where the phone is sets Auto's start and whether the remux may read the file over the link.
        if request.download == nil {
            let connection = try? await library.connection.connection()
            guard generation == self.generation else { return }
            startAdapting(connection: connection)
        }
        // Scene thumbnails load after the first picture (`arrived`).
        await decideRoute()
        startTiming.mark(.route)
        guard generation == self.generation else { return }
        await startStream(at: start, generation: generation)
    }

    private func routeLimits(connection: PlexConnection?, quality: VideoQuality) -> RouteLimits {
        switch session.settings.directPlay {
        case .force:
            return RouteLimits(phoneOnly: true)
        case .disabled:
            return RouteLimits(serverReason: .directPlayOff, quality: quality)
        case .auto:
            // A file that failed on the phone earlier in this run goes straight to the server when reopened.
            let failedBefore = part.map { session.player.phoneFailures.contains($0.id) } ?? false
            return RouteLimits(
                serverReason: onDeviceFailed || failedBefore ? .onDeviceFailed : nil,
                quality: quality,
                // Plex calls a LAN address reached through a VPN local; the place knows better.
                remoteConnection: place.map { !$0.isHome } ?? connection.map { !$0.isLocal } ?? false,
                // Auto's rung already fits the link.
                linkKbps: adaptive == nil ? connection.flatMap { session.player.linkKbps[$0.uri] } : nil
            )
        }
    }

    /// Why Boost dialog and Normalize loudness cannot apply to this video, given `base`, the route
    /// without them; nil when they can.
    private func enhancementBlock(base: PlaybackRoute, audio: AudioTrack?, quality: VideoQuality) -> String? {
        if session.settings.directPlay == .force {
            return "Not available while Force Direct Play is on. Set Direct Play to Auto in Settings to use it."
        }
        if quality != .original { return "Available only at Original quality." }
        if base.reencodesVideo { return "Not available while your Plex server converts this video." }
        if part?.videoStream?.dolbyVision?.profile == 5 { return "Not available for this Dolby Vision video." }
        if audio?.canNormalizeLoudness != true {
            return "Not ready for this video yet. Your Plex server needs to scan its sound first."
        }
        if enhancementRefused { return "Your Plex server couldn't turn this on for this video." }
        return nil
    }

    private func decideRoute() async {
        guard let tracks, let media, let part else { return }
        let owner = generation
        let network = session.presenceNetworkRevision
        if let castDevice {
            decideCastRoute(castDevice, tracks: tracks, media: media, part: part)
            return
        }
        let choice = await chooseRoute(tracks: tracks, media: media, part: part, quality: quality)
        guard owner == generation, network == session.presenceNetworkRevision, !Task.isCancelled else { return }
        take(choice)
        if case .sidecar(let track) = choice.route.subtitle { await loadSidecar(track) }
    }

    /// The route at `quality`, decided without changing the playing one.
    private func chooseRoute(tracks: MediaTracks, media: PlexMedia, part: PlexPart, quality: VideoQuality) async -> RouteChoice {
        let settings = session.settings
        let memory = settings.remembersTracks ? session.trackMemory(for: item) : nil
        let picked = AudioPicker.pick(in: tracks, handPick: handAudio, remembered: memory?.audio, preferredLanguage: settings.audioLanguage)
        let device = await capabilities.current()
        let connection = request.download == nil ? try? await library.connection.connection() : nil
        var limits = request.download == nil ? routeLimits(connection: connection, quality: quality) : RouteLimits()
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
        if request.download == nil, route.kind == .remux, isExternalPlayback, settings.directPlay != .force {
            limits.serverReason = .airPlay
            (decision, route) = decide(drawsImages: true)
        }
        // A server stream shows embedded image subtitles only burned in, which an automatic pick never
        // asks for; it moves to a text track instead.
        var drawsImages = true
        if route.kind == .serverTranscode, decision.source != .handPick, decision.source != .remembered,
           let track = decision.track, track.isImageBased, !track.isExternal {
            drawsImages = false
            (decision, route) = decide(drawsImages: false)
        }
        // Boost dialog and Normalize loudness are the server's: it copies the video and reworks the sound.
        // They never ride on a stream it re-encodes anyway.
        let offered = request.download == nil && session.serverInfo.hasPlexPass
        var block = enhancementBlock(base: route, audio: picked, quality: quality)
        if offered, !settings.audioEnhancements.isEmpty, block == nil {
            limits.audioEnhancements = settings.audioEnhancements
            let enhanced = decide(drawsImages: drawsImages)
            if enhanced.1.reencodesVideo {
                block = "Your Plex server can't add this to this video right now."
            } else {
                (decision, route) = enhanced
            }
        }
        let enhancements = EnhancementState(
            offered: offered,
            asked: settings.audioEnhancements,
            unavailable: block,
            note: !route.audioEnhancements.isEmpty && decision.track != nil ? "Subtitles won't change." : nil
        )
        return RouteChoice(subtitle: decision, route: route, enhancements: enhancements)
    }

    private func take(_ choice: RouteChoice) {
        enhancements = choice.enhancements
        subtitle = choice.subtitle
        route = choice.route
        audio = choice.route.audio
        subtitleProblem = nil
        if case .notShown(let track) = choice.route.subtitle {
            subtitleProblem = "\(track.label) needs the server to burn it in; pick it again to allow that."
        }
    }

    private func loadSidecar(_ track: SubtitleTrack) async {
        guard sidecarID != track.id else { return }
        let owner = generation
        let network = session.presenceNetworkRevision
        sidecar = nil
        sidecarID = nil
        let key = part?.streams.first(where: { $0.id == track.id })?.key ?? "/library/streams/\(track.id)"
        do {
            let loaded: SidecarContents
            if let download = request.download {
                guard let saved = download.subtitles.first(where: { $0.streamID == track.id }) else { throw CocoaError(.fileNoSuchFile) }
                loaded = try await SidecarLoader.load(track, fileURL: session.downloads.store.subtitleFile(for: download, saved))
            } else {
                loaded = try await SidecarLoader.load(track, key: key, library: library, session: session.transport.session)
            }
            guard owner == generation, network == session.presenceNetworkRevision, !Task.isCancelled else { return }
            sidecar = loaded
            sidecarID = track.id
        } catch {
            guard owner == generation, network == session.presenceNetworkRevision, !Task.isCancelled else { return }
            subtitleProblem = "\(track.label): \(Self.message(error))"
        }
    }

    // MARK: Streams

    private func startStream(at target: TimeInterval, generation: Int) async {
        guard let route, let part else { return }
        let networkRevision = session.presenceNetworkRevision
        if castDevice != nil {
            await startCast(at: target, generation: generation)
            return
        }
        stopStream()
        loadStage = .opening
        landing = target
        // A landing can finish between two looks at a wait, which would then count on into the new stream.
        forgetWait()
        origin = nil
        streamKey = StreamKey(route)
        do {
            let url: URL
            switch route.kind {
            case .directPlay:
                if let download = request.download {
                    guard let file = session.downloads.store.mediaFile(for: download) else { throw CocoaError(.fileNoSuchFile) }
                    url = file
                } else {
                    url = try await library.playbackURL(path: part.key)
                    let connection = await library.connection.currentConnection
                    guard generation == self.generation, !Task.isCancelled else { return }
                    streamConnection = connection
                    reporter = TimelineReporter(library: library, item: item)
                }
                stream = .direct
                origin = 0
            case .remux:
                let source: URL
                if let download = request.download {
                    guard let file = session.downloads.store.mediaFile(for: download) else { throw CocoaError(.fileNoSuchFile) }
                    source = file
                } else {
                    let connection = try await library.connection.connection()
                    guard generation == self.generation, !Task.isCancelled else { return }
                    guard let remote = PlexURL.make(base: connection.uri, path: part.key) else { throw URLError(.badURL) }
                    source = remote
                    streamConnection = connection
                    reporter = TimelineReporter(library: library, item: item)
                }
                let remux = makeRemux(source: source, part: part, route: route)
                stream = .remux(remux)
                listen(to: remux)
                remuxFinished = false
                url = try await remux.start(at: target)
                guard generation == self.generation, !Task.isCancelled else { remux.stop(); return }
                try await handOff(remux, landing: target)
            case .serverTranscode:
                guard request.download == nil else { throw URLError(.unsupportedURL) }
                try await selectForServer(route, part: part)
                guard generation == self.generation, !Task.isCancelled else { return }
                let session = UUID().uuidString
                stream = .transcode(session)
                transcodeOffset = target
                reporter = TimelineReporter(library: library, item: item, sessionIdentifier: session)
                url = try await library.transcodeURL(
                    TranscodeRequest(item: item, mediaIndex: mediaIndex, route: route, offset: target, session: session)
                )
                let connection = await library.connection.currentConnection
                guard generation == self.generation, !Task.isCancelled else {
                    try? await library.stopTranscode(session: session)
                    return
                }
                streamConnection = connection
                loadStage = .preparing
            }
            guard generation == self.generation, !Task.isCancelled,
                  request.download != nil || networkRevision == session.presenceNetworkRevision else { return }
            streamNetworkRevision = networkRevision
            applySubtitleSources()
            startTiming.mark(.stream)
            load(url)
        } catch {
            guard generation == self.generation, networkRevision == session.presenceNetworkRevision,
                  !Task.isCancelled, !(error is CancellationError) else { return }
            streamFailed(PlaybackFailure(text: Self.message(error)))
        }
    }

    /// Seconds of a remux AVPlayer holds before it starts; once playing, the engine's larger forward
    /// buffer applies (`arrived`).
    private static let startBuffer: TimeInterval = 3

    private func load(_ url: URL) {
        let playerItem = makeItem(url)
        if case .remux = stream { playerItem.preferredForwardBufferDuration = Self.startBuffer }
        streamText.attach(to: playerItem)
        itemReady = false
        backend.load(playerItem)
    }

    private func makeItem(_ url: URL) -> AVPlayerItem {
        let playerItem = AVPlayerItem(asset: AVURLAsset(url: url))
        playerItem.textStyleRules = textStyleRules
        playerItem.externalMetadata = metadataItems()
        return playerItem
    }

    /// Holds a remux run's playlist until AVPlayer can start from its first read (`RemuxHandOff`),
    /// showing the share of the lead in hand.
    private func handOff(_ remux: RemuxSession, landing target: TimeInterval) async throws {
        let gate = RemuxHandOff(landing: target)
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            guard case .remux(let current) = stream, current === remux else { throw CancellationError() }
            let progress = remux.progress
            let decision = gate.decide(
                origin: remux.timelineOrigin, mediaSeconds: progress.mediaSeconds, isPaced: progress.isPaced,
                finished: remuxFinished, elapsed: clock.now - start
            )
            switch decision {
            case .wait(let share):
                loadStage = share.map { LoadStage.buffering($0) } ?? .opening
                try await Task.sleep(for: .milliseconds(50))
            case .handOver(let reason):
                if startTiming.handOff == nil {
                    let held = Int(((clock.now - start) / .milliseconds(1)).rounded())
                    startTiming.handOff = "playlist held \(held) ms (\(reason.rawValue))"
                }
                loadStage = .starting
                return
            }
        }
    }

    private func makeRemux(source: URL, part: PlexPart, route: PlaybackRoute) -> RemuxSession {
        var options = RemuxOptions()
        if let audio = route.audio, let index = streamIndex(audio.id) { options.audio = AudioPolicy(preferredIndex: index) }
        if let vision = part.videoStream?.dolbyVision {
            // LoopbackHLS, which declares the record type, also has a SubtitleTrack; importing it would
            // make MarqueeCore's ambiguous here.
            options.dolbyVisionFallback = .init(
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
            sourceFactory: {
                if source.isFileURL { return try FileRangeSource(fileURL: source) }
                return HTTPRangeSource(url: source, headers: headers, knownLength: length)
            },
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
                case .finished:
                    remuxFinished = true
                case .failed(let error, _):
                    streamFailed(PlaybackFailure(text: error.localizedDescription))
                default:
                    break
                }
            }
        }
    }

    private func stopStream() {
        abandonMove()
        eventsTask?.cancel()
        eventsTask = nil
        seekTask?.cancel()
        seekTask = nil
        measureLink()
        lastTransfer = nil
        longestWait = 0
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
        stopCast()
    }

    /// Keeps what the ending stream measured of the link to its server, for the next route: the remux's
    /// reads from the file, or AVPlayer's segment downloads from the server. Direct play is not measured.
    private func measureLink() {
        guard streamNetworkRevision == session.presenceNetworkRevision,
              let address = streamConnection?.uri else { return }
        var bitsPerSecond: Double?
        switch stream {
        case .remux(let remux):
            bitsPerSecond = remux.progress.sourceBytesPerSecond.map { $0 * 8 }
        case .transcode:
            bitsPerSecond = backend.player?.currentItem?.accessLog()?.events.last?.observedBitrate
        case .direct, nil:
            break
        }
        // Auto's estimate spans every stream of the item, not only this one's last reads.
        if let estimate = adaptive?.estimateKbps { bitsPerSecond = Double(estimate) * 1000 }
        guard let bitsPerSecond, bitsPerSecond > 0 else { return }
        session.player.linkKbps[address] = Int(bitsPerSecond / 1000)
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
    private func reroute(handPick: Bool, reconnect: Bool = false) {
        abandonMove()
        generation += 1
        let generation = generation
        loadTask?.cancel()
        let at = time
        loadTask = Task { [weak self] in
            guard let self else { return }
            let previous = streamKey
            await decideRoute()
            guard generation == self.generation, let route else { return }
            if reconnect || StreamKey(route) != previous || stream == nil {
                isBuffering = true
                await startStream(at: at, generation: generation)
            } else {
                applySubtitleSources()
                // Paused, no time update comes to draw the new subtitle's line.
                updateSubtitles(at: time)
                await applySelection()
            }
            if handPick { writeBack() }
        }
    }

    // MARK: Auto quality

    /// How far past the playhead the standby takes over, and the buffer the playing stream needs to get there.
    private static let switchLead: TimeInterval = 8
    private static let switchBuffer: TimeInterval = 9

    private var sourcePicture: AdaptiveQuality.Picture? {
        guard let width = media?.width, let height = media?.height, width > 0, height > 0 else { return nil }
        return AdaptiveQuality.Picture(width: width, height: height)
    }

    private var viewPicture: AdaptiveQuality.Picture? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let source = CGSize(width: CGFloat(media?.width ?? 16), height: CGFloat(media?.height ?? 9))
        let frame = VideoFrame.rect(aspect: aspect, video: source, in: viewport, displayScale: viewportScale)
        return AdaptiveQuality.Picture(
            width: max(1, Int(frame.width * viewportScale)), height: max(1, Int(frame.height * viewportScale))
        )
    }

    func viewportChanged(size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0, scale > 0 else { return }
        viewport = size
        viewportScale = scale
        guard phase == .playing, let current = adaptive, let place else { return }
        var resized = AdaptiveQuality(
            place: place, mediaKbps: media?.bitrate, linkKbps: current.estimateKbps,
            source: sourcePicture, view: viewPicture, now: ProcessInfo.processInfo.systemUptime
        )
        guard resized.floor != current.floor else { return }
        abandonMove()
        let target = resized.ladder.contains(autoRung) ? autoRung : resized.floor
        resized.moved(to: target, at: ProcessInfo.processInfo.systemUptime)
        adaptive = resized
        belowQualityFloor = false
        if target != autoRung { adapt(to: target) }
    }

    func invalidateNetworkMeasurements() {
        guard request.download == nil, castDevice == nil else { return }
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        if !itemReady { stopStream() }
        abandonMove()
        adaptive = nil
        lastTransfer = nil
        longestWait = 0
        linkEstimateKbps = nil
        belowQualityFloor = false
        place = .unknown
    }

    func networkConnectionChanged(to connection: PlexConnection?) {
        guard request.download == nil, castDevice == nil, let connection,
              phase == .loading || phase == .playing else { return }
        guard media != nil, part != nil else {
            loadItem(item.ratingKey)
            return
        }
        startAdapting(connection: connection)
        reroute(handPick: false, reconnect: true)
    }


    /// Auto's state for the item: where the phone is and the link as last measured set the start.
    private func startAdapting(connection: PlexConnection?) {
        adaptive = nil
        lastTransfer = nil
        longestWait = 0
        linkEstimateKbps = nil
        belowQualityFloor = false
        autoRung = .original
        if let connection { place = networkPlace(of: connection) }
        guard qualitySetting == .auto, !forcesDirectPlay, let connection, let place else { return }
        let adaptive = AdaptiveQuality(
            place: place, mediaKbps: media?.bitrate, linkKbps: session.player.linkKbps[connection.uri],
            source: sourcePicture, view: viewPicture,
            now: ProcessInfo.processInfo.systemUptime
        )
        self.adaptive = adaptive
        autoRung = adaptive.rung
    }

    /// Where the phone is from the server at `connection`. The UI tests' fake server is at home when its address
    /// is local.
    private func networkPlace(of connection: PlexConnection) -> NetworkPlace {
        if FakePlex.isActive { return connection.isLocal ? .home : .away(.remote) }
        let path = session.pathMetrics.path(to: connection.uri, revision: session.presenceNetworkRevision)
        return .of(
            connection, onPhoneNetwork: NetworkPath.isOnAttachedNetwork(connection.ipAddress),
            localAddress: path?.localAddress, roundTrip: path?.roundTrip
        )
    }

    private func watchQuality() {
        qualityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                lookAtStream()
            }
        }
    }

    /// One look for Auto: the link's speed while data moved, the media in hand and the longest wait since the
    /// last look.
    private func lookAtStream() {
        guard var adaptive, phase == .playing, isPlaying, castDevice == nil, landing == nil, !isSeeking,
              streamNetworkRevision == session.presenceNetworkRevision, !movePending else {
            lastTransfer = nil
            longestWait = 0
            return
        }
        var look = AdaptiveQuality.Look(
            now: ProcessInfo.processInfo.systemUptime, waitingSeconds: longestWait, streamID: adaptive.streamID
        )
        longestWait = 0
        switch stream {
        case .remux(let remux):
            // The remux reads the file from the server; the player reads from the phone.
            let progress = remux.progress
            if progress.isFetching, let rate = progress.sourceBytesPerSecond {
                look.throughputKbps = Int(rate * 8 / 1000)
                look.transferSeconds = 2
            }
            look.bufferSeconds = max(0, progress.mediaSeconds - backend.itemTime)
        case .transcode, .direct:
            if let transfer = backend.transfer {
                if let last = lastTransfer, transfer.seconds > last.seconds, transfer.bytes > last.bytes {
                    let seconds = transfer.seconds - last.seconds
                    look.throughputKbps = Int(Double(transfer.bytes - last.bytes) * 8 / 1000 / seconds)
                    look.transferSeconds = seconds
                }
                lastTransfer = transfer
            }
            look.bufferSeconds = backend.bufferedAhead
        case nil:
            return
        }
        let move = adaptive.observe(look)
        self.adaptive = adaptive
        linkEstimateKbps = adaptive.estimateKbps
        if belowQualityFloor != adaptive.belowFloor {
            belowQualityFloor = adaptive.belowFloor
            if belowQualityFloor { showChrome() } else { scheduleHide() }
        }
        if let move { adapt(to: move) }
    }

    /// Moves Auto to `rung`: beside the playing stream when it can, else by a new stream at the playhead.
    private func adapt(to rung: VideoQuality) {
        guard let tracks, let media, let part else { return settleMove(at: autoRung) }
        movePending = true
        moveTask = Task { [weak self] in
            guard let self else { return }
            let choice = await chooseRoute(tracks: tracks, media: media, part: part, quality: rung)
            guard !Task.isCancelled else { return }
            if StreamKey(choice.route) == streamKey {
                // The file plays the same at this rung.
                take(choice)
                return settleMove(at: rung)
            }
            if canSwitchBeside(to: choice), await prepareSwitch(to: choice, rung: rung) { return }
            guard !Task.isCancelled else { return }
            restartForMove(choice, rung: rung)
        }
    }

    /// The standby takes over only on the phone's own screen, from a stream with enough in hand, to a server
    /// stream or the file with the same sound and subtitle.
    private func canSwitchBeside(to choice: RouteChoice) -> Bool {
        guard let route, choice.route.kind != .remux, choice.route.audio?.id == route.audio?.id,
              choice.route.subtitle == route.subtitle, !(pictureInPicture?.isActive ?? false), !isExternalPlayback,
              UIApplication.shared.applicationState == .active
        else { return false }
        return (backend.bufferedAhead ?? 0) >= Self.switchBuffer
    }

    /// Opens the stream at `rung` on the standby player, primed at a movie time a few seconds ahead, and arms the
    /// switch for when the playhead gets there. False, with nothing of it left, when that failed or came too late.
    private func prepareSwitch(to choice: RouteChoice, rung: VideoQuality) async -> Bool {
        guard let part, let playingOrigin = origin else { return false }
        // A move given up meanwhile has dropped its standby; a later one may hold the next.
        func failed() -> Bool {
            if !Task.isCancelled { dropStandby() }
            return false
        }
        let at = time + Self.switchLead
        let url: URL
        do {
            if choice.route.kind == .serverTranscode {
                try await selectForServer(choice.route, part: part)
                guard !Task.isCancelled, time < at - 1 else { return false }
                let id = UUID().uuidString
                // Held before the request, so that a move given up stops the server's work.
                standby = Standby(
                    rung: rung, choice: choice, stream: .transcode(id),
                    reporter: TimelineReporter(library: library, item: item, sessionIdentifier: id), offset: at, origin: at,
                    preparationDeadline: at - 1
                )
                url = try await library.transcodeURL(
                    TranscodeRequest(item: item, mediaIndex: mediaIndex, route: choice.route, offset: at, session: id)
                )
            } else {
                standby = Standby(
                    rung: rung, choice: choice, stream: .direct, reporter: TimelineReporter(library: library, item: item),
                    offset: 0, origin: 0, preparationDeadline: at - 1
                )
                url = try await library.playbackURL(path: part.key)
            }
        } catch {
            return failed()
        }
        guard !Task.isCancelled, standby != nil, time < at - 1 else { return failed() }
        let playerItem = makeItem(url)
        guard !Task.isCancelled, await backend.openStandby(playerItem), !Task.isCancelled, var next = standby else {
            return failed()
        }
        if case .transcode = next.stream {
            let length = playerItem.duration.seconds
            next.origin = transcodeOrigin(itemDuration: length.isFinite && length > 0 ? length : nil, offset: next.offset)
        }
        next.connection = await library.connection.currentConnection
        await applySelection(choice.route, to: playerItem)
        guard !Task.isCancelled, standby != nil, time < at - 1,
              let player = await backend.prerollStandby(at: at - next.origin),
              !Task.isCancelled, standby != nil, time < at - 0.5
        else { return failed() }
        next.preparationDeadline = nil
        standby = next
        layerView.prepareStandby(player)
        backend.armSwitch(at: at - playingOrigin)
        return true
    }

    /// The playhead reached the standby's start: the standby plays on in place of the playing stream.
    private func completeSwitch() {
        guard let next = standby else { return }
        guard !(pictureInPicture?.isActive ?? false), !isExternalPlayback, UIApplication.shared.applicationState == .active else {
            return abandonMove()
        }
        standby = nil
        moveTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        layerView.switchToStandby()
        backend.switchToStandby()
        switch stream {
        case .remux(let remux):
            remux.stop()
        case .transcode(let session):
            let library = library
            Task { try? await library.stopTranscode(session: session) }
        case .direct, nil:
            break
        }
        stream = next.stream
        streamKey = StreamKey(next.choice.route)
        streamConnection = next.connection
        reporter = next.reporter
        transcodeOffset = next.offset
        origin = next.origin
        mediaInfo = nil
        lastTransfer = nil
        take(next.choice)
        if let item = backend.player?.currentItem { streamText.attach(to: item) }
        settleMove(at: next.rung)
    }

    /// Moves Auto by a new stream at the playhead, keeping the screen as it is.
    private func restartForMove(_ choice: RouteChoice, rung: VideoQuality) {
        take(choice)
        settleMove(at: rung)
        generation += 1
        let generation = generation
        loadTask?.cancel()
        let at = time
        isBuffering = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            if case .sidecar(let track) = choice.route.subtitle { await loadSidecar(track) }
            guard generation == self.generation else { return }
            await startStream(at: at, generation: generation)
        }
    }

    /// Gives up the move under way, if any: playback stays at the rung it had.
    private func abandonMove() {
        moveTask?.cancel()
        moveTask = nil
        dropStandby()
        if movePending { settleMove(at: autoRung) }
    }

    /// Lets go of the standby stream, stopping the server's work on it.
    private func dropStandby() {
        backend.discardStandby()
        layerView.discardStandby()
        guard let standby else { return }
        self.standby = nil
        if case .transcode(let session) = standby.stream {
            let library = library
            Task { try? await library.stopTranscode(session: session) }
        }
    }

    private func settleMove(at rung: VideoQuality) {
        movePending = false
        autoRung = rung
        adaptive?.moved(to: rung, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Where a server stream started at `offset` begins in the movie. Some servers list the whole film whatever
    /// the offset; the stream then starts at zero.
    private func transcodeOrigin(itemDuration: TimeInterval?, offset: TimeInterval) -> TimeInterval {
        if let length = itemDuration, duration > 0, length >= duration - 30 { return 0 }
        return offset
    }

    private func streamFailed(_ failure: PlaybackFailure) {
        if request.download != nil { fail(failure); return }
        guard !closed, phase != .finished, let route else {
            fail(failure)
            return
        }
        let at = time
        generation += 1
        let generation = generation
        loadTask?.cancel()
        switch route.kind {
        case .directPlay, .remux:
            guard session.settings.directPlay != .force, !onDeviceFailed else {
                fail(failure)
                return
            }
            onDeviceFailed = true
            if let part { session.player.phoneFailures.insert(part.id) }
            fallback = failure.detail
            stopStream()
            enterLoading()
            loadTask = Task { [weak self] in
                guard let self else { return }
                await decideRoute()
                guard generation == self.generation else { return }
                await startStream(at: at, generation: generation)
            }
        case .serverTranscode where !route.audioEnhancements.isEmpty && !enhancementRefused:
            // Refused with the sound reworked: the same video plays without it.
            enhancementRefused = true
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
                fail(failure)
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
        fail(PlaybackFailure(text: message))
    }

    private func fail(_ failure: PlaybackFailure) {
        failureDetail = failure.detail
        let message = failure.text
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
        loadStage = route == nil ? .connecting : .opening
        showsStage = false
        stageTask?.cancel()
        stageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, phase == .loading else { return }
            showsStage = true
        }
    }

    private func go(to target: PlexMetadata) {
        lastPreviousPress = nil
        report(.stopped)
        stopStream()
        handAudio = nil
        handSubtitle = nil
        onDeviceFailed = false
        fallback = nil
        failureDetail = nil
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
        timing.reset()
        showsTiming = false
        trickplay = nil
        trickplayLoad?.task.cancel()
        trickplayLoad = nil
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
            startTiming.mark(.ready)
            loadStage = .starting
            if case .transcode = stream, origin == nil {
                origin = transcodeOrigin(itemDuration: backend.itemDuration, offset: transcodeOffset)
            }
            land()
        case .failed(let failure):
            streamFailed(failure)
        case .ended:
            ended()
        case .externalPlayback(let active):
            externalPlaybackChanged(active)
        case .presentationSize(let size):
            presentationSize = size
        case .switchDue:
            completeSwitch()
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
            // AVPlayer can join a growing playlist part-way rather than at its start.
            if abs(backend.itemTime - local) > 0.5 { _ = await backend.seek(to: local, precise: true) }
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
        if case .remux = stream {
            backend.player?.currentItem?.preferredForwardBufferDuration = RemuxSession.recommendedForwardBufferDuration
        }
        loadTrickplay(now: false)
        await applySelection()
        if !wroteBack {
            wroteBack = true
            writeBack()
        }
        if wantsPlay { backend.play() }
        startTiming.mark(.playing)
        if let origin { time = backend.itemTime + origin }
        publishPosition()
        report()
        if wasLoading { scheduleHide() }
    }

    private func seekItem(_ local: TimeInterval) {
        seekSerial += 1
        let serial = seekSerial
        isSeeking = true
        streamText.reset()
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
                remuxFinished = false
                let url = try await remux.seek(to: target)
                guard serial == seekSerial, case .remux(let current) = stream, current === remux else { return }
                try await handOff(remux, landing: target)
                guard serial == seekSerial else { return }
                load(url)
            } catch {
                guard serial == seekSerial, !(error is CancellationError) else { return }
                streamFailed(PlaybackFailure(text: Self.message(error)))
            }
        }
    }

    private func tick(_ itemTime: TimeInterval) {
        guard let origin, landing == nil else { return }
        if case .remux(let remux) = stream { remux.updatePlayhead(itemTime) }
        guard !isSeeking else { return }
        let movie = itemTime + origin
        if !isScrubbing { time = movie }
        if let next = standby, let deadline = next.preparationDeadline, movie >= deadline {
            moveTask?.cancel()
            moveTask = nil
            dropStandby()
            restartForMove(next.choice, rung: next.rung)
        }
        updateSubtitles(at: movie)
        updateOffers(at: movie)
        if !markedWatched, duration > 0, movie >= duration * 0.9 { markWatched() }
        if Date.now.timeIntervalSince(lastReport) >= 1 { report() }
    }

    private func stateChanged(playing: Bool, buffering: Bool) {
        isPlaying = playing
        isBuffering = buffering || landing != nil
        if case .remux(let remux) = stream { remux.setPlayerWaiting(buffering) }
        if playing, buffering { watchStall() } else { endStall() }
        if !playing || buffering {
            if case .upNext? = offer { interruptCountdown() } else { cancelCountdown() }
        } else {
            startCountdownIfDue()
        }
        report()
        publishPosition()
        if playing { scheduleHide() } else { hideTask?.cancel() }
    }

    /// While playback waits in mid-play, looks at once and then every half second (`StallWatch`).
    private func watchStall() {
        guard stallTask == nil else { return }
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                checkStall()
            }
        }
        checkStall()
    }

    private func endStall() {
        stallTask?.cancel()
        stallTask = nil
        isStalled = false
        forgetWait()
    }

    /// The wait so far no longer counts: playback moved on, or a new stream's own wait counts from its start.
    private func forgetWait() {
        stallWatch.resume()
        waitsForNetwork = false
        if case .lowerQuality? = offer { withAnimation(.easeOut(duration: 0.18)) { offer = nil } }
    }

    private func checkStall() {
        guard !closed, phase == .playing, castDevice == nil, isPlaying, isBuffering else { return endStall() }
        // A seek's own wait is the user's doing; the watch starts again once it is over.
        guard landing == nil, !isSeeking else {
            waitsForNetwork = false
            return stallWatch.resume()
        }
        isStalled = true
        var run: StallWatch.Run?
        var paced = false
        if case .remux(let remux) = stream, let origin {
            let progress = remux.progress
            run = StallWatch.Run(produced: origin + progress.mediaSeconds, fetching: progress.isFetching)
            paced = progress.isPaced
        }
        switch stallWatch.check(now: ProcessInfo.processInfo.systemUptime, position: time, run: run) {
        case .network(let seconds):
            longestWait = max(longestWait, seconds)
            guard seconds >= 2 else { return }
            // The standby cannot take over from a stalled stream; Auto's next look moves by a new stream instead.
            if standby != nil { abandonMove() }
            if !waitsForNetwork { withAnimation(.easeOut(duration: 0.18)) { waitsForNetwork = true } }
            hideTask?.cancel()
            if !chromeVisible { setChrome(true) }
            if seconds >= 10 { offerLowerQuality() }
        case .stuck(let ahead, let cause):
            let at = time
            recoveries = Recoveries(count: (recoveries?.count ?? 0) + 1, at: at, ahead: ahead, cause: cause)
            EngineLog.logger.event("stall.recovered", [
                ("at", String(format: "%.1f", at)), ("ahead", String(format: "%.1f", ahead)), ("paced", String(paced)),
                ("cause", cause.rawValue),
            ])
            waitsForNetwork = false
            restart(at: at)
        case .giveUp:
            streamFailed(PlaybackFailure(text: "The video stopped arriving from \(library.server.name)."))
        }
    }

    /// A quality at half the rate playing now or below, unless Auto picks the rung or Settings have every file
    /// play as it is.
    private func offerLowerQuality() {
        if case .lowerQuality? = offer { return }
        guard case .fixed = qualitySetting, !forcesDirectPlay,
              let lower = quality.lower(mediaKbps: media?.bitrate) else { return }
        cancelCountdown()
        withAnimation(.easeOut(duration: 0.22)) { offer = .lowerQuality(lower) }
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
        textRendererChanged()
        // An AirPlay receiver cannot reach the remux's address on the phone.
        guard active, case .remux = stream, session.settings.directPlay != .force else { return }
        reroute(handPick: false)
    }

    // MARK: Subtitles

    private func applySubtitleSources() {
        textCues = []
        overlayTrack = nil
        cueText = nil
        cueWords = []
        bitmaps = []
        updateWordTiming()
        timing.fit(canGoEarlier: timingCanGoEarlier)
        if !canTimeSubtitles { showsTiming = false }
        guard let route else { return }
        switch route.subtitle {
        case .sidecar(let track):
            guard sidecarID == track.id, let sidecar else { return }
            if let images = sidecar.bitmaps {
                overlayTrack = images
            } else {
                // Over a remux the file also rides in the stream, for AVPlayer to draw in Picture in Picture.
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
        guard let playerItem = backend.player?.currentItem, let route else { return }
        await applySelection(route, to: playerItem)
    }

    private func applySelection(_ route: PlaybackRoute, to playerItem: AVPlayerItem) async {
        guard let tracks else { return }
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
        // A positive offset shows each line later: what shows now was due that long ago.
        let due = movie - timing.seconds
        if let overlayTrack {
            let shown = overlayTrack.bitmaps(at: due)
            if shown.map(\.start) != bitmaps.map(\.start) || shown.map(\.y) != bitmaps.map(\.y) { bitmaps = shown }
        }
        wordTiming?.ask(due: due, offset: timing.seconds)
        let line = textCues.isEmpty ? streamLine(at: due) : cueLine(at: due)
        if line?.text != cueText { cueText = line?.text }
        let words = line?.words ?? []
        if words != cueWords { cueWords = words }
    }

    private func cueLine(at movie: TimeInterval) -> ShownLine? {
        let reveal = session.settings.subtitleStyle.reveal
        var line: ShownLine?
        for cue in textCues where cue.start <= movie && movie < cue.end {
            let text = String(cue.text.characters)
            // SpeechDock's times once it has timed the cue, the estimate until then.
            let words = wordTiming?.starts(at: cue.start).flatMap { SubtitleReveal.measured(text, starts: $0, by: reveal) }
                ?? SubtitleReveal.estimate(text, duration: cue.end - cue.start, by: reveal)
            var shown = line ?? ShownLine()
            shown.add(cue.text, words, at: movie - cue.start)
            line = shown
        }
        return line
    }

    private func streamLine(at movie: TimeInterval) -> ShownLine? {
        guard !playerDrawsText, let origin, let showing = streamText.line(at: movie - origin) else { return nil }
        let text = String(showing.text.characters)
        // A line in the stream arrives as it starts, so its end is seldom known yet.
        let duration = showing.end.map { $0 - showing.start } ?? SubtitleReveal.spoken(text)
        var line = ShownLine()
        line.add(showing.text, SubtitleReveal.estimate(text, duration: duration, by: session.settings.subtitleStyle.reveal), at: movie - origin - showing.start)
        return line
    }

    /// The text showing and, for Reveal as Spoken, how much shows of each word still appearing.
    private struct ShownLine {
        var text = AttributedString()
        var words: [RevealedWord] = []
        private var shown: Set<String> = []

        /// Adds a cue below the lines before it, its words `elapsed` seconds into their reveal. A cue whose
        /// text is already showing is skipped: files and streams repeat a cue over the same time, and two
        /// copies of one line stacked are never meant.
        mutating func add(_ cue: AttributedString, _ timed: [SubtitleReveal.Word], at elapsed: TimeInterval) {
            guard shown.insert(String(cue.characters)).inserted else { return }
            if !text.characters.isEmpty { text += AttributedString("\n") }
            let base = text.characters.count
            text += cue
            for word in timed {
                let visibility = SubtitleReveal.visibility(of: word, at: elapsed)
                if visibility < 1 { words.append(RevealedWord(offset: base + word.offset, length: word.length, visibility: visibility)) }
            }
        }
    }

    /// SpeechDock times an English text file over English audio while Reveal as Spoken is on; any other
    /// subtitle keeps the estimate.
    private func updateWordTiming() {
        guard request.download == nil else { return }
        guard session.settings.subtitleStyle.reveal != .off, let client = session.speechDock.client,
              case .sidecar(let track)? = route?.subtitle, sidecarID == track.id, sidecar?.bitmaps == nil,
              let media, let audio = route?.audio,
              let identity = SpeechDock.identity(server: library.server.id, ratingKey: item.ratingKey, media: media, audio: audio.id, subtitle: track.id) else {
            wordTiming?.stop()
            wordTiming = nil
            return
        }
        guard wordTiming?.identity != identity || wordTiming?.origin != client.origin else { return }
        wordTiming?.stop()
        wordTiming = WordTiming(
            client: client, identity: identity, path: "/library/streams/\(track.id)?encoding=utf-8&format=srt",
            library: library, session: session.transport.session
        ) { [weak self] in
            guard let self else { return }
            updateSubtitles(at: time)
        }
    }

    /// AVPlayer draws the stream's text where Marquee's overlay is not seen: in Picture in Picture and on an
    /// AirPlay screen.
    private var playerDrawsText: Bool { isExternalPlayback || (pictureInPicture?.isActive ?? false) }

    private var textStyleRules: [AVTextStyleRule]? {
        playerDrawsText ? CaptionStyle.rules(for: session.settings.subtitleStyle, lifted: chromeVisible) : nil
    }

    private func textRendererChanged() {
        streamText.playerDraws = playerDrawsText
        applyTextStyle()
        updateSubtitles(at: time)
    }

    private func applyTextStyle() {
        backend.player?.currentItem?.textStyleRules = textStyleRules
    }

    // MARK: Subtitle timing

    /// The subtitle on screen is drawn on the phone, so its timing can move.
    var canTimeSubtitles: Bool {
        switch route?.subtitle {
        case .sidecar?, .inStream?: true
        default: false
        }
    }

    /// Why Timing and Style can't reach the subtitle on screen: the server draws it into the picture.
    var subtitleDrawnByServer: String? {
        guard let route, case .burnedIn = route.subtitle else { return nil }
        let convertsAudio = route.reasons.contains { if case .audio = $0 { true } else { false } }
        return convertsAudio ? "Drawn by your server while it converts the audio." : "Drawn by your server at this quality."
    }

    /// "Original timing", "Subtitles 0.3 s later".
    var timingText: String {
        if timing.isOriginal { return "Original timing" }
        return "Subtitles \(timing.magnitude) \(timing.seconds > 0 ? "later" : "earlier")"
    }

    /// Only a downloaded file's lines are all read up front, so only they can be shown early.
    private var timingCanGoEarlier: Bool {
        if case .sidecar? = route?.subtitle { return true }
        return false
    }

    func canNudgeTiming(_ direction: Int) -> Bool {
        timing.canNudge(direction, canGoEarlier: timingCanGoEarlier)
    }

    /// One step later (1) or earlier (-1).
    func nudgeTiming(_ direction: Int) {
        guard canNudgeTiming(direction) else { return }
        timing.nudge(direction, canGoEarlier: timingCanGoEarlier)
        Haptics.selection()
        updateSubtitles(at: time)
    }

    func resetTiming() {
        guard !timing.isOriginal else { return }
        timing.reset()
        Haptics.impact(.light)
        updateSubtitles(at: time)
    }

    /// The controls step aside, so the lines being matched show where they always do.
    func openTiming() {
        guard canTimeSubtitles else { return }
        showsTiming = true
        if !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning { setChrome(false) }
    }

    func closeTiming() {
        showsTiming = false
    }

    // MARK: Wrong subtitles

    /// Bazarr, once its address and key are saved in Settings.
    var bazarr: BazarrClient? { session.bazarr.client }

    func openSubtitleFix(_ sheet: SubtitleSheet) {
        if subtitleFix == nil {
            let showing = subtitle?.track?.language.code.map { TrackLanguage(code: $0) }
            subtitleFix = SubtitleFix(model: self, language: showing ?? session.settings.subtitles.language)
        }
        subtitleFix?.open()
        subtitleSheet = sheet
    }

    /// Reads the item again for its subtitle files. Nil once another item or file plays.
    func reloadTracks() async throws -> MediaTracks? {
        guard let fresh = try await reloadPart() else { return nil }
        if fresh != part { setPart(fresh) }
        return tracks
    }

    /// Puts a track on screen as a pick from the menu would; true once it shows.
    func show(_ track: SubtitleTrack) async -> Bool {
        pickSubtitle(.track(track.id))
        await loadTask?.value
        return subtitle?.track?.id == track.id && subtitleProblem == nil
    }

    /// A subtitle file was deleted from the server: it leaves the menu, and the screen if it was showing.
    func removed(_ track: SubtitleTrack) async {
        let key = item.ratingKey
        let reloaded: PlexPart?
        do { reloaded = try await reloadPart() } catch { reloaded = part }
        guard key == item.ratingKey, var fresh = reloaded else { return }
        fresh.streams.removeAll { $0.id == track.id }
        setPart(fresh)
        if handSubtitle == .track(track.id) { handSubtitle = nil }
        if sidecarID == track.id {
            sidecar = nil
            sidecarID = nil
        }
        if subtitle?.track?.id == track.id { reroute(handPick: false) }
    }

    /// What Bazarr is asked to find: the movie, or the episode by its show.
    func bazarrLookup() async -> BazarrLookup {
        let item = item, file = part?.file
        guard item.type == .episode else {
            let ids = (try? await library.externalIDs(item.ratingKey)) ?? []
            return BazarrLookup(title: item.title, year: item.year, externalIDs: ids, file: file)
        }
        var ids: [String] = []
        if let show = item.grandparentRatingKey { ids = (try? await library.externalIDs(show)) ?? [] }
        return BazarrLookup(
            title: item.grandparentTitle ?? item.title, year: nil, externalIDs: ids,
            season: item.parentIndex, episode: item.index, file: file
        )
    }

    /// The playing file as the server lists it now; nil once another item or file plays.
    private func reloadPart() async throws -> PlexPart? {
        guard let partID = part?.id else { return nil }
        let key = item.ratingKey
        let full = try await library.metadata(key)
        guard key == item.ratingKey, part?.id == partID else { return nil }
        return full.media.lazy.flatMap(\.parts).first { $0.id == partID }
    }

    private func setPart(_ fresh: PlexPart) {
        if let index = media?.parts.firstIndex(where: { $0.id == fresh.id }) { media?.parts[index] = fresh }
        part = fresh
        tracks = MediaTracks(part: fresh)
    }

    // MARK: Offers

    private var finalCredits: PlexMarker? {
        let credits = item.markers(.credits)
        return credits.first(where: \.isFinal) ?? credits.last
    }

    private func updateOffers(at movie: TimeInterval) {
        // The lower-quality offer lasts as long as the wait that brought it (`endStall`).
        if case .lowerQuality? = offer { return }
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
        case .lowerQuality?, nil:
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
        if let download = request.download {
            guard duration > 0 else { return }
            lastReport = .now
            session.downloads.updateWatch(id: download.id, position: Int(time * 1000), duration: Int(duration * 1000))
            return
        }
        guard let reporter, duration > 0 else { return }
        lastReport = .now
        let state = state ?? (isBuffering ? .buffering : isPlaying ? .playing : .paused)
        let time = Int(self.time * 1000), length = Int(duration * 1000)
        Task { await reporter.update(state, time: time, duration: length) }
    }

    private func markWatched() {
        markedWatched = true
        if request.download != nil { report(); return }
        let library = library, key = item.ratingKey
        Task { try? await library.markWatched(key) }
    }

    /// Saves the playing tracks as the part's selection, once per fresh playback on the phone and per
    /// hand pick. Server streams set it before they start.
    private func writeBack() {
        guard request.download == nil else { return }
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
        if let download = request.download {
            if let image = UIImage(contentsOfFile: session.downloads.store.posterFile(for: download).path) {
                nowPlaying?.setArtwork(image)
            }
            return
        }
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

    /// Scene thumbnails wait for the picture, then ten seconds more for the stream's buffer, so they never
    /// share the link with the start: one episode's index was 7.3 MB, 8.8 s over a 10 Mbit/s path. A scrub
    /// fetches them at once.
    private func loadTrickplay(now: Bool) {
        guard request.download == nil else { return }
        guard trickplay == nil, let part, part.hasSceneThumbnails else { return }
        if let load = trickplayLoad, load.part == part.id, !(now && load.waits) { return }
        trickplayLoad?.task.cancel()
        let library = library, urlSession = session.transport.session, key = item.ratingKey
        let task = Task(priority: .utility) { [weak self] in
            if !now { try? await Task.sleep(for: .seconds(10)) }
            guard !Task.isCancelled,
                  let data = try? await PlexFetch.data("/library/parts/\(part.id)/indexes/sd", library: library, session: urlSession),
                  let self, item.ratingKey == key else { return }
            trickplay = Trickplay(data: data)
        }
        trickplayLoad = (part.id, task, !now)
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
        guard chromeVisible, isPlaying, !belowQualityFloor, !isScrubbing, menusOpen == 0, phase == .playing,
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
        abandonMove()
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

extension AppSession {
    func playDownload(_ record: DownloadRecord) {
        guard record.phase == .done else { return }
        do {
            let item = try downloads.store.offlineItem(for: record)
            player.play(PlaybackRequest(item: item, download: record, startAt: Double(record.watch.offset) / 1000), session: self)
        } catch {
            downloads.error = error.localizedDescription
        }
    }
}

/// The one playback at a time. `presented` drives the full-screen player; `active` stays while Picture
/// in Picture carries the playback without it.
@MainActor @Observable
final class PlayerCenter {
    var presented: PlayerModel?
    private(set) var active: PlayerModel?
    let capabilities = PlaybackCapabilities()
    /// Parts that failed to play on the phone in this run; reopening one goes straight to the server.
    @ObservationIgnored var phoneFailures: Set<Int> = []
    /// The link to each server address as the last stream from it measured, in kbit/s.
    @ObservationIgnored var linkKbps: [URL: Int] = [:]

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

// MARK: Chromecast

extension PlayerModel: CastPlayer {
    func castConnected(_ device: CastDevice) {
        guard !closed else { return }
        castDevice = device
        castReceiverFailed = false
        // An item still loading decides for the receiver once it has its tracks.
        guard route != nil else { return }
        if case .failed = phase { enterLoading() }
        report(.stopped)
        stopStream()
        isPlaying = false
        isBuffering = true
        reroute(handPick: false)
    }

    /// Back on the phone, paused where the receiver was.
    func castDisconnected() {
        guard castDevice != nil, !closed else { return }
        if let castProgress, castProgress.state != .stopped { time = clamp(castProgress.position(at: Self.uptime)) }
        report(.stopped)
        stopStream()
        castDevice = nil
        castReceiverFailed = false
        wantsPlay = false
        isPlaying = false
        guard route != nil else { return }
        if case .failed = phase { return }
        isBuffering = true
        reroute(handPick: false)
    }

    func castStatus(_ status: CastStatus) {
        guard castDevice != nil, var progress = castProgress else { return }
        let end = progress.update(status, now: Self.uptime)
        castProgress = progress
        castSeekTarget = nil
        switch end {
        case .finished:
            castTask?.cancel()
            ended()
        case .failed:
            if route?.kind == .directPlay, !castReceiverFailed {
                castReceiverFailed = true
                reroute(handPick: false)
            } else {
                fail("The Chromecast couldn't play this video.")
            }
        case .stopped:
            // Stopped on the TV, or another sender cast to it.
            session.cast.disconnect(stopping: false)
        case nil:
            guard progress.state != .stopped else { return }
            if phase == .loading, progress.state != .buffering {
                retries = 0
                phase = .playing
                stageTask?.cancel()
                showsStage = false
                startTiming.mark(.playing)
            }
            let playing = progress.state == .playing, buffering = progress.state == .buffering
            if playing != isPlaying || buffering != isBuffering { stateChanged(playing: playing, buffering: buffering) }
        }
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The receiver's route: subtitles are burned in, as the Default Media Receiver draws none of Plex's.
    private func decideCastRoute(_ device: CastDevice, tracks: MediaTracks, media: PlexMedia, part: PlexPart) {
        let settings = session.settings
        let memory = settings.remembersTracks ? session.trackMemory(for: item) : nil
        let picked = AudioPicker.pick(in: tracks, handPick: handAudio, remembered: memory?.audio, preferredLanguage: settings.audioLanguage)
        let decision = SubtitlePicker.decide(
            tracks: tracks, audio: picked, handPick: handSubtitle, remembered: memory?.subtitle,
            settings: settings.subtitles, canDrawImageSubtitles: true
        )
        let reason: RouteReason? = castReceiverFailed ? .receiverFailed : settings.directPlay == .disabled ? .directPlayOff : nil
        let route = CastRouteDecider.decide(
            media: media, part: part, tracks: tracks, audio: picked, subtitle: decision,
            receiver: CastReceiver(modelName: device.model), limits: RouteLimits(serverReason: reason, quality: quality)
        )
        enhancements = EnhancementState()
        subtitle = decision
        self.route = route
        audio = route.audio
        subtitleProblem = nil
    }

    /// Hands the receiver the file, or the server's stream of it from the start, with a transient token
    /// in place of the account's; it starts at `target` itself.
    private func startCast(at target: TimeInterval, generation: Int) async {
        guard let route, let part else { return }
        stopStream()
        loadStage = .opening
        landing = nil
        origin = nil
        streamKey = StreamKey(route)
        do {
            let token = try await library.transientToken()
            let connection = try await library.connection.connection()
            guard generation == self.generation, castDevice != nil else { return }
            let base = CastStream.address(current: connection, among: library.server.connections).uri
            let stream: CastStream?
            if route.kind == .directPlay {
                stream = CastStream.file(part: part, base: base, token: token)
                reporter = TimelineReporter(library: library, item: item)
            } else {
                try await selectForServer(route, part: part)
                guard generation == self.generation else { return }
                let id = UUID().uuidString
                castSession = id
                stream = CastStream.transcode(
                    TranscodeRequest(item: item, mediaIndex: mediaIndex, route: route, offset: 0, session: id),
                    base: base, identity: session.identity, isLocal: connection.isLocal, token: token
                )
                reporter = TimelineReporter(library: library, item: item, sessionIdentifier: id)
            }
            guard let stream else { throw URLError(.badURL) }
            streamConnection = connection
            let poster = (isEpisode ? (item.grandparentThumb ?? item.thumb) : item.thumb).flatMap {
                PlexURL.make(base: base, path: $0, query: [URLQueryItem(name: PlexHeader.token, value: token)])
            }
            castProgress = CastProgress(startingAt: target, replacing: session.cast.mediaSessionID, now: Self.uptime)
            session.cast.load(CastLoad(
                stream: stream, title: title, subtitle: subtitleLine, poster: poster, isEpisode: isEpisode,
                duration: duration, startAt: target, autoplay: wantsPlay
            ))
            startTiming.mark(.stream)
            castTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.castTicked()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            fail(PlaybackFailure(text: Self.message(error)))
        }
    }

    /// Between statuses the position runs on from the last one.
    private func castTicked() {
        guard let castProgress, castProgress.state != .stopped else { return }
        let position = castSeekTarget ?? castProgress.position(at: Self.uptime)
        let movie = duration > 0 ? min(position, duration) : position
        if !isScrubbing { time = movie }
        guard phase == .playing else { return }
        updateOffers(at: movie)
        if !markedWatched, duration > 0, movie >= duration * 0.9 { markWatched() }
        if Date.now.timeIntervalSince(lastReport) >= 1 { report() }
    }

    private func stopCast() {
        castTask?.cancel()
        castTask = nil
        castProgress = nil
        castSeekTarget = nil
        if let castSession {
            let library = library
            Task { try? await library.stopTranscode(session: castSession) }
            self.castSession = nil
        }
    }
}
