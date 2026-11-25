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
    /// Whether the title plays by the anime rules: Plex's tags, or the viewer's word for the show.
    private(set) var treatsAsAnime = false
    /// The viewer's word on the show being anime, kept with its remembered tracks.
    private(set) var animeOverride = AnimeOverride.automatic
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
    /// Plex has the index but it did not load, so the player makes its own previews.
    private(set) var trickplayFailed = false
    /// The original part, never the loopback playlist. Its URL and headers are not logged.
    private var previewFile: ScrubPreviewSource?
    private(set) var offer: Offer?
    private(set) var countdown: Countdown?
    private(set) var cueText: AttributedString?
    /// Reveal as Spoken: how much shows of each word of `cueText` still appearing.
    private(set) var cueWords: [RevealedWord] = []
    /// Cues the file places itself (`{\an8}`), one block for each place; they draw apart from `cueText`.
    private(set) var placedCues: [PlacedCue] = []
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
        guard case .fixed(let fixed) = qualitySetting else { return autoRung.quality }
        guard let cap = dataCap, fixed == .original || fixed.rawValue > cap.rawValue else { return fixed }
        return cap
    }
    /// The quality as the player words it: Auto's rung may be a step of the title's curve, such as "3.2 Mbps 720p".
    var qualityTitle: String { qualitySetting == .auto ? autoRung.title : quality.title }
    /// Save Data's cap on this item while the phone is on a metered network (`savedDataCap`); Auto keeps under it.
    private(set) var dataCap: VideoQuality?
    private(set) var qualityCap: VideoQuality?
    /// Auto's rung on this item (docs/adaptive-playback.md); Original while Auto does not adapt.
    private(set) var autoRung = AutoRung.original
    /// Auto's estimate of the link to the server, for stats for nerds.
    private(set) var linkEstimateKbps: Int?
    /// Auto holds its lowest rung on a link that cannot sustain it; a wait on the network then says why.
    private(set) var belowQualityFloor = false
    var showsInfo = false
    var showsMore = false
    /// The Enhance Picture panel over the player, and the slider of it being dragged: while one is, the panel and
    /// the chrome step aside and the player draws that slider alone, under the finger.
    private(set) var showsEnhance = false
    var enhanceDrag: EnhanceDrag?
    var enhanceDragging: Bool { enhanceDrag != nil }
    var showsStats = false
    var showsEpisodes = false
    /// Find Subtitles for the playing item.
    let subtitleFinder = SubtitleFinder()

    let layerView = PlayerLayerView()
    /// The UI tests' stand-in for the picture.
    let stillImage: UIImage?
    let pictureInPicture: PictureInPicture?
    /// The picture enhancer of an AVPlayer-backed title; nil when another backend draws the picture.
    let enhance: EnhanceController?
    /// The full-screen player is up (not the bar, Picture in Picture or the glasses); set by `PlayerCenter`.
    @ObservationIgnored private var showsFullPlayer = false
    @ObservationIgnored private var inBackground = false

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
        var rung: AutoRung
        var choice: RouteChoice
        var stream: Stream
        var reporter: TimelineReporter
        var connection: PlexConnection?
        /// The server stream's offset; 0 for the file.
        var offset: TimeInterval
        var origin: TimeInterval
        /// The server stream's `start.m3u8`.
        var master: URL?
        var preparationDeadline: TimeInterval?
    }

    /// A route decided at one quality, taken on when its stream plays (`take`).
    private struct RouteChoice {
        var subtitle: SubtitleDecision
        var route: PlaybackRoute
        var enhancements: EnhancementState
        var isAnime: Bool
    }

    /// The skip past the intro being confirmed (`SkipCheck`), and the movie time it last looked at.
    @ObservationIgnored private var skipCheck: SkipCheck?
    @ObservationIgnored private var skipCheckAt: TimeInterval?
    /// Tallies for the diagnostic log's close summary, and the movie time of its last playhead sample.
    @ObservationIgnored private var diagSeeks = 0
    @ObservationIgnored private var diagStalls = 0
    @ObservationIgnored private var diagSampleAt: TimeInterval = -.infinity
    @ObservationIgnored private var diagOpenedAt = ContinuousClock.now
    @ObservationIgnored private var request: PlaybackRequest
    @ObservationIgnored private var isFirstItem = true
    @ObservationIgnored private var mediaIndex = 0
    @ObservationIgnored private var nowPlaying: NowPlaying?
    @ObservationIgnored private var queue: PlexPlayQueue?
    @ObservationIgnored private(set) var media: PlexMedia?
    @ObservationIgnored private(set) var part: PlexPart?
    @ObservationIgnored private var handAudio: Int?
    @ObservationIgnored private var handSubtitle: SubtitleChoice?
    @ObservationIgnored private var titleTags = TitleTags(isAnime: false, countries: [])
    @ObservationIgnored private var onDeviceFailed = false
    @ObservationIgnored private var wroteBack = false
    @ObservationIgnored private var serverAudio: Int?
    @ObservationIgnored private var serverSubtitle: Int?
    @ObservationIgnored private var recovery = StartRecovery()
    /// A stream that failed while it played is started again at the last played position (`StreamReconnect`).
    @ObservationIgnored private var reconnection = StreamReconnect()
    /// Set from the failure to the new stream playing: the stream let go meanwhile ends no playback on the server.
    @ObservationIgnored private var reconnecting = false
    @ObservationIgnored private var reconnectBegan: ContinuousClock.Instant?
    /// Fails a server stream that is not playing `StartRecovery.readyDeadline` after it went to the player.
    @ObservationIgnored private var startDeadline: Task<Void, Never>?
    @ObservationIgnored private var introCancelled = false
    /// The end of an intro just skipped. Until the picture reaches it, time from before the jump must not offer
    /// the intro again, which restarted its countdown instead of skipping.
    @ObservationIgnored private var skippedIntroEnd: Double?
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
    /// A far seek is waiting on the engine, which may replace the run under the playing item.
    @ObservationIgnored private var runSeekPending = false
    @ObservationIgnored private var remuxFinished = false
    @ObservationIgnored private var transcodeOffset: TimeInterval = 0
    /// The playing server stream's `start.m3u8`, for measuring its clock (`ServerStreamClock`).
    @ObservationIgnored private var transcodeMaster: URL?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seekSerial = 0
    @ObservationIgnored private var isSeeking = false
    /// When the wait for a seek or a new stream to land began; past 2 s the controls come back.
    @ObservationIgnored private var seekWaitStart: TimeInterval?
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
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    @ObservationIgnored private var prewarmedKey: String?
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var stageTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var stallWatch = StallWatch()
    /// Notices the server losing the conversion the stream plays from.
    @ObservationIgnored private var conversion = ConversionWatch()
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
    /// HomeLabber's quality curve for the playing version on this screen, asked for as the item starts. Nil when Auto
    /// is not picking, HomeLabber has not measured this version, or its answer came too late for the start.
    @ObservationIgnored private var qualityCurve: QualityCurve?
    @ObservationIgnored private var qualityTask: Task<Void, Never>?
    @ObservationIgnored private var moveTask: Task<Void, Never>?
    /// Auto asked for a rung and the move has not settled (`settleMove`).
    @ObservationIgnored private var movePending = false
    /// The move under way replaces a stream the server lost (`ConversionWatch`), not one Auto picked.
    @ObservationIgnored private var replacingLost = false
    @ObservationIgnored private var standby: Standby?
    /// The playing item's transfer totals at Auto's last look.
    @ObservationIgnored private var lastTransfer: (bytes: Int64, seconds: TimeInterval)?
    /// The longest wait on the network since Auto's last look.
    @ObservationIgnored private var longestWait: TimeInterval = 0
    @ObservationIgnored private var viewport = CGSize.zero
    @ObservationIgnored private var viewportScale: CGFloat = 1
    /// The item `loadItem` is fetching, until `begin` takes it: `item` is still the one before it.
    @ObservationIgnored private var loadingKey: String?
    /// The server address the link reading is for.
    @ObservationIgnored private var linkAddress: URL?
    /// How near the server is for the item by the measured link, decided as it starts or the network changes: a
    /// track change halfway through must not move the route as the reading ages. Stats for nerds shows it.
    @ObservationIgnored private(set) var reach = RouteReach.unmeasured
    /// The server was asked what it would make of the file's own stream (`ServerLimit`) since `reach` was decided.
    @ObservationIgnored private var serverLimitAsked = false
    /// The link was probed (`LinkProbe`) since `reach` was decided.
    @ObservationIgnored private var linkProbed = false
    /// The playing stream's reading of the link is taken (`noteLink`); `readingBase` is where its counting began.
    @ObservationIgnored private var linkNoted = false
    @ObservationIgnored private var readingBase: (bytes: Int64, seconds: TimeInterval)?

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
        var offersEnhance = backend.player != nil
        #if DEBUG
        // The still frame has no player, but the tests drive the Enhance Picture menu on it.
        offersEnhance = offersEnhance || FakePlex.root != nil
        #endif
        enhance = offersEnhance ? EnhanceController(layerView: layerView) : nil
        #if DEBUG
        // The still frame has no player layer, so no window to open: `-marquee.uitest.pip YES` offers one anyway,
        // for the tests that place its button.
        if FakePlex.isActive, UserDefaults.standard.bool(forKey: "marquee.uitest.pip") { canPictureInPicture = true }
        #endif
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
        subtitle?.track.map { .track($0.id) } ?? .off
    }

    /// The English track the rules would put on screen now: what the menu's On row turns on. Nil when the file
    /// has none.
    var automaticSubtitle: SubtitleTrack? {
        tracks.flatMap { TrackRules.automaticSubtitle(in: $0, audio: audio, isAnime: treatsAsAnime) }
    }

    /// Image subtitles keep their own size and position; the look's colour tints them.
    var subtitleIsImage: Bool { subtitle?.track?.isImageBased ?? false }

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
        Diag.beginPlayback()
        diagOpenedAt = .now
        Diag.event(.player, "open", [
            "item": request.item.ratingKey, "type": request.item.type.rawValue, "download": request.download != nil,
            "fromStart": request.fromStart, "startAt": request.startAt, "paused": request.startsPaused, "media": request.mediaIndex,
            "quality": "\(session.settings.quality)", "directPlay": "\(session.settings.directPlay)", "glasses": session.player.onGlasses,
        ], .notice)
        session.downloads.setPlaybackActive(true)
        backend.onEvent = { [weak self] event in self?.handle(event) }
        pictureInPicture?.onPossibleChange = { [weak self] possible in self?.canPictureInPicture = possible }
        pictureInPicture?.onActiveChange = { [weak self] _ in
            self?.textRendererChanged()
            self?.updateNowPlayingSight()
            self?.refreshEnhance()
        }
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
            // Leaving sight covers the Lock Screen, Control Center and the app switcher too.
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateNowPlayingSight(active: false) }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateNowPlayingSight(active: true) }
            },
        ]
        updateNowPlayingSight()
        enhanceSettingsChanged()
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
        let began = ContinuousClock.now
        Diag.event(.player, "close", [
            "at": time, "duration": duration, "phase": Self.diagPhase(phase), "route": route?.kind.rawValue, "seeks": diagSeeks,
            "stalls": diagStalls, "recoveries": recoveries?.count ?? 0, "watched": markedWatched, "start": startTiming.summary,
            "seconds": Diag.ms(since: diagOpenedAt) / 1000,
        ], .notice)
        report(.stopped)
        session.downloads.setPlaybackActive(false)
        generation += 1
        wordTiming?.stop()
        wordTiming = nil
        for task in [loadTask, queueTask, seekTask, eventsTask, countdownTask, hideTask, stageTask, stallTask, qualityTask, moveTask, prewarmTask, trickplayLoad?.task] {
            task?.cancel()
        }
        sideTasks.forEach { $0.cancel() }
        subtitleFinder.cancel()
        stopStream()
        backend.tearDown()
        enhance?.close()
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
        Diag.event(.player, "close.teardown", ["ms": Diag.ms(since: began)], .debug)
        Diag.endPlayback()
    }

    func retry() {
        Diag.event(.player, "retry", ["at": time, "route": route?.kind.rawValue], .notice)
        recovery.reset()
        reconnection.reset()
        if route == nil {
            loadItem(loadingKey ?? item.ratingKey)
        } else {
            enterLoading()
            restart(at: time)
        }
    }

    // MARK: Transport

    func play() {
        Diag.event(.player, "play", ["at": time, "phase": Self.diagPhase(phase)])
        wantsPlay = true
        resumesAfterInterruption = false
        if phase == .finished {
            replay()
        } else if phase == .playing {
            if castDevice != nil { session.cast.play() } else { backend.play() }
        }
    }

    func pause() {
        Diag.event(.player, "pause", ["at": time])
        wantsPlay = false
        resumesAfterInterruption = false
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

    /// A seek of the viewer's own, which ends any check on an intro skip. False when nothing plays to move.
    @discardableResult
    func seek(to requested: TimeInterval) -> Bool {
        if let check = skipCheck {
            Diag.event(.offers, "skip.check.end", ["reason": "seek", "end": check.target])
            skipCheck = nil
        }
        return move(to: requested, cause: "seek")
    }

    /// Moves playback to a movie time: within the stream when it holds that time, else by a new run or stream.
    private func move(to requested: TimeInterval, cause: String) -> Bool {
        guard phase == .playing || phase == .finished else {
            Diag.event(.player, "seek.refused", ["cause": cause, "to": requested, "phase": Self.diagPhase(phase)], .notice)
            return false
        }
        if phase == .finished { phase = .playing }
        abandonMove()
        let target = clamp(requested)
        let from = time
        time = target
        diagSeeks += 1
        func logged(_ path: String, written: TimeInterval? = nil, seekable: TimeInterval? = nil) {
            Diag.event(.player, "seek", [
                "cause": cause, "from": from, "to": target, "path": path, "written": written, "seekable": seekable,
            ])
        }
        if castDevice != nil {
            // A receiver that has finished holds nothing to seek in.
            if castProgress == nil || castProgress?.state == .stopped {
                logged("cast-restart")
                restart(at: target)
            } else {
                logged("cast")
                castSeekTarget = target
                session.cast.seek(to: target)
            }
            publishPosition()
            report()
            return true
        }
        if landing != nil {
            if farSeeking, case .remux(let remux) = stream {
                logged("far-again")
                farSeek(remux, to: target)
            } else {
                logged("landing")
                landing = target
            }
            return true
        }
        guard let origin else {
            Diag.event(.player, "seek.refused", ["cause": cause, "to": target, "reason": "no-origin"], .notice)
            return false
        }
        let local = target - origin
        switch stream {
        case .remux(let remux):
            let written = remux.progress.mediaSeconds
            // AVPlayer seeks only inside the item's seekable range. The remux's playlist is live until the whole
            // file is written, and a live range stops three target durations short of the playlist's end: with
            // 89.5 s written and 59.1 s seekable, a skip to 88.2 s was refused in 12 ms (0.1.51). The UI tests'
            // still frame has no item and follows what is written.
            let seekable = itemSeekableEnd
            if local >= 0, local <= min(written, seekable ?? written) - 1 {
                logged("item", written: written, seekable: seekable)
                seekItem(local)
            } else {
                logged("far", written: written, seekable: seekable)
                farSeek(remux, to: target)
            }
        case .transcode:
            if local >= 0, let length = backend.itemDuration, local <= length - 1 {
                logged("item", written: length)
                seekItem(local)
            } else {
                logged("restart")
                restart(at: target)
            }
        case .direct, nil:
            logged("item")
            seekItem(max(0, local))
        }
        publishPosition()
        report()
        return true
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

    func showChrome() {
        if !chromeVisible { setChrome(true) }
        scheduleHide()
    }

    /// A tap on the picture: the first one only brings the controls back. A tap reaching the picture
    /// means no menu is open, whatever the menus reported. Only a tap hides the controls from a paused
    /// picture, to look at it or zoom in; while the picture loads or waits they stay, as they carry the
    /// loading ring.
    func tapped() {
        menusOpen = 0
        userActed()
        if chromeVisible, phase == .playing, !isWaiting { setChrome(false) } else { showChrome() }
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

    var pictureEnhance: PictureEnhance { session.settings.pictureEnhance }

    /// Writes the setting the Settings page uses and retunes the playing video.
    func setEnhance(_ value: PictureEnhance) {
        guard value != session.settings.pictureEnhance else { return }
        session.settings.pictureEnhance = value
        enhanceSettingsChanged()
    }

    /// The panel stands in the player, not in a popover, so a dragged slider can leave the picture clear.
    func openEnhance() {
        guard !showsEnhance else { return }
        showsEnhance = true
        menuOpened()
    }

    func closeEnhance() {
        guard showsEnhance else { return }
        showsEnhance = false
        enhanceDrag = nil
        menuClosed()
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
        Diag.event(.player, "aspect", ["aspect": "\(aspect)"])
        self.aspect = aspect
        scheduleHide()
    }

    func setQuality(_ setting: QualitySetting) {
        scheduleHide()
        let playing = quality, playingTarget = autoTarget
        Diag.event(.player, "quality.set", ["setting": "\(setting)", "playing": "\(playing)"])
        qualityCap = nil
        if setting != session.settings.quality { session.settings.quality = setting }
        abandonMove()
        startAdapting(connection: streamConnection)
        if quality != playing || autoTarget != playingTarget { reroute(handPick: false) }
    }

    func setSpeed(_ speed: Float) {
        Diag.event(.player, "speed", ["speed": speed])
        self.speed = speed
        backend.rate = speed
        scheduleHide()
    }

    func toggleEnhancement(_ enhancement: AudioEnhancements) {
        session.settings.audioEnhancements.formSymmetricDifference(enhancement)
        Diag.event(.audio, "enhancement", ["toggled": "\(enhancement)", "now": "\(session.settings.audioEnhancements)"])
        scheduleHide()
        reroute(handPick: false)
    }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        Diag.event(.player, "pip.toggle", ["wasActive": pictureInPicture.isActive])
        if pictureInPicture.isActive { pictureInPicture.stop() } else { pictureInPicture.start() }
    }

    /// The profile's subtitle style changed.
    func styleChanged() {
        applyTextStyle()
        updateWordTiming()
        updateSubtitles(at: time)
    }

    // MARK: Offers

    /// `auto`: the countdown ran out, rather than a tap. The skip is confirmed once playback runs on (`checkSkip`).
    func skipIntro(auto: Bool = false) {
        guard case .skipIntro(let end)? = offer else {
            Diag.event(.offers, "skip.ignored", ["auto": auto, "offer": Self.diagOffer(offer)], .notice)
            return
        }
        Diag.event(.offers, "skip", [
            "auto": auto, "at": time, "end": end, "stream": diagStream, "playing": isPlaying, "buffering": isBuffering,
        ], .notice)
        cancelCountdown("skip")
        guard move(to: end, cause: auto ? "skip-intro-auto" : "skip-intro") else {
            // Nothing moved, so the offer stays to be taken again.
            Diag.event(.offers, "skip.refused", ["end": end, "phase": Self.diagPhase(phase)], .warning)
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { offer = nil }
        skippedIntroEnd = end
        skipCheck = SkipCheck(target: end)
        skipCheckAt = nil
    }

    func watchIntro() {
        Diag.event(.offers, "watch-intro", ["at": time])
        introCancelled = true
        cancelCountdown("watch-intro")
    }

    func watchCredits() {
        Diag.event(.offers, "watch-credits", ["at": time])
        creditsDismissed = true
        cancelCountdown("watch-credits")
        withAnimation(.easeOut(duration: 0.18)) { offer = nil }
    }

    /// Takes a long network wait's offer: this playback goes on at the lower quality.
    func playAtLowerQuality() {
        guard case .lowerQuality(let lower)? = offer else { return }
        Diag.event(.offers, "lower-quality.taken", ["quality": "\(lower)"], .notice)
        qualityCap = lower
        // Before the route is decided again, or the next look would offer a lower quality still.
        forgetWait()
        reroute(handPick: false)
    }

    // MARK: Tracks

    func pickAudio(_ track: AudioTrack) {
        guard track.id != audio?.id else { return }
        Diag.event(.audio, "pick", ["track": Self.diagAudio(track), "was": audio.map(Self.diagAudio)])
        handAudio = track.id
        remember()
        reroute(handPick: true)
    }

    func pickSubtitle(_ choice: SubtitleChoice) {
        guard choice != subtitleChoice else { return }
        Diag.event(.subtitles, "pick", ["choice": "\(choice)", "was": "\(subtitleChoice)"])
        handSubtitle = choice
        remember()
        reroute(handPick: true)
    }

    /// The viewer's word on the show being anime, kept for its other episodes; the tracks are chosen again.
    func pickAnime(_ choice: AnimeOverride) {
        guard choice != animeOverride else { return }
        Diag.event(.subtitles, "anime", ["choice": "\(choice)", "was": "\(animeOverride)"])
        animeOverride = choice
        remember()
        reroute(handPick: true)
    }

    // MARK: Loading

    private func loadItem(_ ratingKey: String) {
        stopStream()
        generation += 1
        let generation = generation
        loadingKey = ratingKey
        enterLoading()
        Diag.event(.player, "load", ["item": ratingKey])
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
        loadingKey = nil
        stallWatch = StallWatch()
        conversion = ConversionWatch()
        recoveries = nil
        subtitleFinder.itemChanged(to: full.ratingKey)
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
        Diag.event(.player, "item", list: diagItem(full, media: media, part: part, tracks: tracks, start: start))
        Diag.event(.offers, "markers", [
            "intro": Self.diagMarkers(full.markers(.intro)), "credits": Self.diagMarkers(full.markers(.credits)),
            "chapters": full.chapters.compactMap(\.title).joined(separator: "|"),
        ])
        publishItem()
        nextFromStart = false
        animeOverride = session.trackMemory(for: full)?.anime ?? .automatic
        // Plex's anime and country tags are read beside the link's measure.
        async let tagged = tags(of: full)
        // The measured link sets Auto's start and whether the phone reads the file itself.
        if request.download == nil {
            // HomeLabber's curve for this version is asked for while the connection is found.
            async let curve = measuredCurve(of: full, media: media)
            let connection = try? await library.connection.connection()
            guard generation == self.generation else { return }
            qualityCurve = await curve
            guard generation == self.generation else { return }
            startAdapting(connection: connection)
        }
        titleTags = await tagged
        guard generation == self.generation else { return }
        // Scene thumbnails load after the first picture (`arrived`).
        await decideRoute()
        startTiming.mark(.route)
        guard generation == self.generation else { return }
        await startStream(at: start, generation: generation)
    }

    private func routeLimits(connection: PlexConnection?, quality: VideoQuality, target: DownloadTarget?) -> RouteLimits {
        switch session.settings.directPlay {
        case .force:
            return RouteLimits(phoneOnly: true)
        case .disabled:
            return RouteLimits(serverReason: .directPlayOff, quality: quality, target: target)
        case .auto:
            // A file that failed on the phone earlier in this run goes straight to the server when reopened.
            let failedBefore = part.map { session.player.phoneFailures.contains($0.id) } ?? false
            return RouteLimits(
                serverReason: onDeviceFailed || failedBefore ? .onDeviceFailed : nil,
                quality: quality,
                target: target,
                // Decided as the item started, from the measured link (`startAdapting`).
                reach: reach,
                // Auto's rung already fits the link.
                linkKbps: adaptive == nil ? connection.flatMap { recentKbps(over: $0) } : nil
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
        if let castDevice {
            decideCastRoute(castDevice, tracks: tracks, media: media, part: part)
            return
        }
        var choice = await chooseRoute(tracks: tracks, media: media, part: part, quality: quality, target: autoTarget)
        guard owner == generation, !Task.isCancelled else { return }
        // Nothing measured the link lately: it is measured now, and the route and Auto's start go by the reading.
        if LinkProbe.isNeeded(route: choice.route, reach: reach), await probeLink(part: part) {
            guard owner == generation, !Task.isCancelled else { return }
            choice = await chooseRoute(tracks: tracks, media: media, part: part, quality: quality, target: autoTarget)
            guard owner == generation, !Task.isCancelled else { return }
        }
        take(choice)
        if case .sidecar(let track) = choice.route.subtitle { await loadSidecar(track) }
    }

    /// Whether Plex's tags make the playing title anime, and where it was made: its own, or its show's. A download
    /// answers from what was read when it was saved, since offline there is no server to ask.
    private func tags(of full: PlexMetadata) async -> TitleTags {
        if let download = request.download {
            return TitleTags(isAnime: download.isAnime ?? full.isAnime, countries: download.countries ?? full.countries)
        }
        return await session.anime.tags(full, in: library)
    }

    /// The route at `quality`, decided without changing the playing one.
    private func chooseRoute(
        tracks: MediaTracks, media: PlexMedia, part: PlexPart, quality: VideoQuality, target: DownloadTarget?
    ) async -> RouteChoice {
        let settings = session.settings
        let picked = TrackRules.pick(
            from: tracks, isAnime: titleTags.isAnime, countries: titleTags.countries,
            choices: TrackRules.Choices(audio: handAudio, subtitle: handSubtitle, memory: session.trackMemory(for: item))
        )
        let device = await capabilities.current()
        let connection = request.download == nil ? try? await library.connection.connection() : nil
        // A download plays on the phone or not at all: offline there is no server to convert it.
        var limits = request.download == nil
            ? routeLimits(connection: connection, quality: quality, target: target) : RouteLimits(phoneOnly: true)
        func decide() -> PlaybackRoute {
            PlaybackRouteDecider.decide(
                media: media, part: part, tracks: tracks, audio: picked.audio, subtitle: picked.subtitle, capabilities: device, limits: limits
            )
        }
        var route = decide()
        // The server's own limits win over the measured link: before the phone reads the original, the server is asked
        // what it would make of the file's video, and a stream it holds below the file's rate comes from it.
        if request.download == nil, case .nearByLink? = limits.reach, route.kind == .remux, !serverLimitAsked {
            serverLimitAsked = true
            if await serverHoldsBack(route, media: media) {
                reach = .remoteByServer
                limits.reach = reach
                route = decide()
            }
        }
        if request.download == nil, route.kind == .remux, isExternalPlayback, settings.directPlay != .force {
            limits.serverReason = .airPlay
            route = decide()
        }
        // Boost dialog and Normalize loudness are the server's: it copies the video and reworks the sound.
        // They never ride on a stream it re-encodes anyway.
        let offered = request.download == nil && session.serverInfo.hasPlexPass
        var block = enhancementBlock(base: route, audio: picked.audio, quality: quality)
        if offered, !settings.audioEnhancements.isEmpty, block == nil {
            limits.audioEnhancements = settings.audioEnhancements
            let enhanced = decide()
            if enhanced.reencodesVideo {
                block = "Your Plex server can't add this to this video right now."
            } else {
                route = enhanced
            }
        }
        let enhancements = EnhancementState(
            offered: offered,
            asked: settings.audioEnhancements,
            unavailable: block,
            note: !route.audioEnhancements.isEmpty && picked.subtitle.track != nil ? "Subtitles won't change." : nil
        )
        return RouteChoice(subtitle: picked.subtitle, route: route, enhancements: enhancements, isAnime: picked.isAnime)
    }

    /// Whether the server holds the file's stream below its own rate. Asked for the video as it is, its decision says
    /// what it would make (`ServerLimit`); one that fails or comes late holds nothing back.
    private func serverHoldsBack(_ route: PlaybackRoute, media: PlexMedia) async -> Bool {
        let asked = TranscodeRequest(item: item, mediaIndex: mediaIndex, route: route)
        let library = library
        guard let decision = await TimeLimit.answer(within: Self.decisionWait, { try? await library.transcodeDecision(asked) }),
              let output = decision.item.media.first else { return false }
        let held = ServerLimit.holdsBack(output: output, source: media)
        Diag.event(.player, "route.server-limit", [
            "held": held, "madeKbps": output.parts.first?.videoStream?.bitrate, "fileKbps": media.parts.first?.videoStream?.bitrate,
        ], held ? .notice : .debug)
        return held
    }

    private func take(_ choice: RouteChoice) {
        enhancements = choice.enhancements
        subtitle = choice.subtitle
        treatsAsAnime = choice.isAnime
        route = choice.route
        audio = choice.route.audio
        subtitleProblem = nil
        if case .notShown(let track) = choice.route.subtitle {
            subtitleProblem = Self.notShown(track, offline: request.download != nil)
        }
        var fields = diagRoute(choice)
        if qualitySetting == .auto { fields.append(("autoRung", "\(autoRung)")) }
        Diag.event(.player, "route", list: fields, .notice)
        if let subtitleProblem { Diag.event(.subtitles, "not-shown", ["problem": subtitleProblem], .notice) }
    }

    /// Why a subtitle the route can't draw is not on screen. A picture needs the server to burn it in, which only
    /// a pick allows; text is never burned in, so text inside the file waits for a route that plays the file itself.
    private static func notShown(_ track: SubtitleTrack, offline: Bool) -> String {
        if track.isImageBased {
            return offline
                ? "\(track.label) needs the server to burn it in, so it can't be shown offline."
                : "\(track.label) needs the server to burn it in; pick it again to allow that."
        }
        return offline
            ? "\(track.label) is inside the file, so it can't be shown offline."
            : "\(track.label) is inside the file, so it can't be shown while your Plex server converts the video. Find Subtitles adds one that can."
    }

    private func loadSidecar(_ track: SubtitleTrack) async {
        guard sidecarID != track.id else { return }
        let owner = generation
        let started = ContinuousClock.now
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
            guard owner == generation, !Task.isCancelled else { return }
            sidecar = loaded
            sidecarID = track.id
            Diag.event(.subtitles, "sidecar.loaded", [
                "track": Self.diagSubtitle(track), "cues": loaded.cues.count, "images": loaded.bitmaps != nil,
                "offline": request.download != nil, "ms": Diag.ms(since: started),
            ])
        } catch {
            guard owner == generation, !Task.isCancelled else { return }
            subtitleProblem = "\(track.label): \(Self.message(error))"
            Diag.event(.subtitles, "sidecar.failed", [
                "track": Self.diagSubtitle(track), "error": DiagFormat.describe(error), "ms": Diag.ms(since: started),
            ], .warning)
        }
    }

    // MARK: Streams

    private func startStream(at target: TimeInterval, generation: Int) async {
        guard let route, let part else { return }
        let started = ContinuousClock.now
        Diag.event(.player, "stream.start", ["at": target, "route": route.kind.rawValue, "cast": castDevice != nil])
        if castDevice != nil {
            await startCast(at: target, generation: generation)
            return
        }
        stopStream()
        loadStage = .opening
        landing = target
        // A landing can finish between two looks at a wait, which would then count on into the new stream.
        forgetWait()
        conversion.streamStarted()
        linkNoted = false
        readingBase = nil
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
                previewFile = ScrubPreviewSource(part: part.id, url: url, isLocal: url.isFileURL)
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
                previewFile = ScrubPreviewSource(part: part.id, url: source, isLocal: source.isFileURL, remuxHeaders: library.authorizationHeaders())
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
                transcodeMaster = url
                let connection = await library.connection.currentConnection
                guard generation == self.generation, !Task.isCancelled else {
                    try? await library.stopTranscode(session: session)
                    return
                }
                streamConnection = connection
                loadStage = .preparing
            }
            guard generation == self.generation, !Task.isCancelled else { return }
            applySubtitleSources()
            startTiming.mark(.stream)
            Diag.event(.player, "stream.open", ["stream": diagStream, "local": streamConnection?.isLocal, "ms": Diag.ms(since: started)])
            load(url)
            if case .transcode = stream { armStartDeadline(generation: generation) }
        } catch {
            guard generation == self.generation, !Task.isCancelled, !(error is CancellationError) else { return }
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
        enhance?.attach(playerItem)
    }

    /// Bounds the player's wait for a server transcode, the one start step without a timeout of its own: a
    /// transcode asked for away from home waited on "preparing" for good (2026-11-11). A file the phone
    /// plays fails by itself, and a late one must not count as one it cannot play.
    private func armStartDeadline(generation: Int) {
        startDeadline?.cancel()
        startDeadline = Task { [weak self] in
            try? await Task.sleep(for: StartRecovery.readyDeadline)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            let seconds = StartRecovery.readyDeadline.components.seconds
            streamFailed(PlaybackFailure(
                text: "\(library.server.name) didn't start the video in time.",
                detail: "Not ready \(seconds) s after the stream was opened"
            ))
        }
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
        options.bitmapSubtitleText = session.settings.textFromPictureSubtitles
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
                return HTTPRangeSource(
                    url: source, headers: headers, knownLength: length,
                    configuration: FakePlex.engineRangeConfiguration()
                )
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
                    Diag.event(.player, "remux.opened", [
                        "container": info.container, "duration": info.duration, "video": info.video.count, "audio": info.audio.count,
                        "subtitles": info.subtitles.count,
                    ])
                case .headerWritten(_, let entry):
                    Diag.event(.player, "remux.header", ["sampleEntry": entry], .debug)
                case .timeline(let origin):
                    Diag.event(.player, "remux.timeline", ["origin": origin, "first": self.origin == nil])
                    if self.origin == nil {
                        self.origin = origin
                        land()
                    }
                case .finished(let progress):
                    remuxFinished = true
                    Diag.event(.player, "remux.finished", ["written": progress.mediaSeconds])
                case .failed(let error, let progress):
                    Diag.event(.player, "remux.failed", ["error": DiagFormat.describe(error), "written": progress.mediaSeconds], .warning)
                    streamFailed(PlaybackFailure(text: error.localizedDescription, isRetryable: Self.isRetryable(error)))
                default:
                    break
                }
            }
        }
    }

    /// - Parameter measured: false when the stream's last reads say nothing of its link.
    private func stopStream(measured: Bool = true) {
        abandonMove()
        eventsTask?.cancel()
        eventsTask = nil
        seekTask?.cancel()
        seekTask = nil
        startDeadline?.cancel()
        startDeadline = nil
        // A seek let go with its task never reports back.
        isSeeking = false
        if measured { measureLink() }
        lastTransfer = nil
        longestWait = 0
        enhance?.detach()
        if pictureInPicture?.isActive ?? false { backend.hold() } else { backend.load(nil) }
        previewFile = nil
        itemReady = false
        farSeeking = false
        switch stream {
        case .remux(let remux):
            remux.stop()
        case .transcode(let session):
            // The stopped report would end the playback on the server and scrobble from a position mid-reconnect.
            end(transcode: session, reporter: reconnecting ? nil : reporter)
        case .direct, nil:
            break
        }
        stream = nil
        mediaInfo = nil
        stopCast()
    }

    /// Ends a server transcode the player let go of. The stopped report ends its playback on the server,
    /// which otherwise stayed open for minutes beside the player's next session (2026-11-11).
    private func end(transcode session: String, reporter: TimelineReporter?) {
        let library = library
        Task { try? await library.stopTranscode(session: session) }
        guard let reporter, duration > 0 else { return }
        let time = Int(time * 1000), length = Int(duration * 1000)
        Task { await reporter.update(.stopped, time: time, duration: length) }
    }

    /// Keeps what the ending stream measured of the link to its server, for the next route: the remux's
    /// reads from the file, or AVPlayer's segment downloads from the server. Direct play is not measured.
    private func measureLink() {
        // A stream from another address than the reading's says nothing of that link.
        guard let address = streamConnection?.uri, address == linkAddress else { return }
        var bitsPerSecond: Double?
        switch stream {
        case .remux(let remux):
            bitsPerSecond = remux.progress.sourceBytesPerSecond.map { $0 * 8 }
        case .transcode:
            bitsPerSecond = backend.player?.currentItem?.accessLog()?.events.last?.observedBitrate
        case .direct:
            break
        case nil:
            return
        }
        // Auto's estimate spans every stream of the item, not only this one's last reads.
        if let estimate = adaptive?.estimateKbps { bitsPerSecond = Double(estimate) * 1000 }
        guard let bitsPerSecond, bitsPerSecond > 0 else { return }
        session.player.links.record(
            Int(bitsPerSecond / 1000), to: address, at: ProcessInfo.processInfo.systemUptime, network: session.presenceNetworkRevision
        )
    }

    /// A new stream at `target` on the same route, keeping the screen as it is. The target is the landing from
    /// now on: the old stream's ticks would otherwise move the playhead back, and a seek meanwhile moves it.
    private func restart(at target: TimeInterval) {
        generation += 1
        let generation = generation
        loadTask?.cancel()
        landing = target
        isBuffering = true
        Diag.event(.player, "stream.restart", ["at": target, "stream": diagStream])
        loadTask = Task { [weak self] in
            guard let self else { return }
            await startStream(at: landing ?? target, generation: generation)
        }
    }

    /// A track change: decides again, then switches inside the stream or starts a new one.
    private func reroute(handPick: Bool, reconnect: Bool = false) {
        abandonMove()
        generation += 1
        let generation = generation
        loadTask?.cancel()
        Diag.event(.player, "reroute", ["handPick": handPick, "reconnect": reconnect, "at": time])
        loadTask = Task { [weak self] in
            guard let self else { return }
            let previous = streamKey
            await decideRoute()
            guard generation == self.generation, let route else { return }
            if reconnect || StreamKey(route) != previous || stream == nil {
                isBuffering = true
                // Where playback is now: a seek while the route was decided went to the old stream.
                await startStream(at: landing ?? time, generation: generation)
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
    /// A conversion the server lost is replaced beside the playing stream when this much is buffered ahead, taking
    /// over short of that buffer by the margin; with less it is replaced at once (`replaceLostConversion`).
    private static let recoveryBuffer: TimeInterval = 7
    private static let recoveryMargin: TimeInterval = 2
    /// How long the phone waits for the server's decision on the original before it plays the file itself.
    private static let decisionWait = Duration.seconds(4)
    /// What a reading of the link from the playing stream rests on: the bytes and the time they took.
    private static let readingBytes: Int64 = 1_000_000
    private static let readingSeconds: TimeInterval = 0.25

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
        // A mapped ladder holds the title's own steps, which the size of the picture on screen does not change.
        guard phase == .playing, let current = adaptive, !current.isMapped else { return }
        var resized = AdaptiveQuality(
            mediaKbps: media?.bitrate, linkKbps: current.estimateKbps, cap: dataCap,
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

    /// The network changed and the server's addresses were asked again: `connection` is the one that
    /// answered, if any. Playback and what Auto learned go on at the same address, under Save Data's cap for the
    /// new network; at another address the item starts again on the new link.
    func networkChanged(to connection: PlexConnection?) {
        guard request.download == nil, castDevice == nil, phase == .loading || phase == .playing else { return }
        Diag.event(.player, "network.changed", [
            "reachable": connection != nil, "local": connection?.isLocal, "sameAddress": connection?.uri == linkAddress,
            "phase": Self.diagPhase(phase),
        ], .notice)
        guard let connection else {
            // A playing stream stalls or fails by itself; a load would only wait out its requests.
            guard phase == .loading else { return }
            loadTask?.cancel()
            stopStream(measured: false)
            fail("\(library.server.name) could not be reached after the network changed.")
            return
        }
        guard connection.uri != linkAddress else { return dataCapMayHaveChanged() }
        if let loadingKey {
            loadItem(loadingKey)
            return
        }
        // The stream's last reads span the change, so they measure neither link.
        stopStream(measured: false)
        streamConnection = connection
        startAdapting(connection: connection)
        reroute(handPick: false, reconnect: true)
    }

    /// Auto's state for the item: the link as recently measured sets the start and `reach`.
    private func startAdapting(connection: PlexConnection?) {
        adaptive = nil
        lastTransfer = nil
        longestWait = 0
        linkEstimateKbps = nil
        belowQualityFloor = false
        autoRung = .original
        if let connection { linkAddress = connection.uri }
        serverLimitAsked = false
        linkProbed = false
        dataCap = session.settings.savesData && session.isMetered ? Self.savedDataCap : nil
        let linkKbps = connection.flatMap { recentKbps(over: $0) }
        reach = RouteReach.decide(connection: connection, mediaKbps: media?.bitrate, linkKbps: linkKbps)
        guard qualitySetting == .auto, !forcesDirectPlay, connection != nil else { return }
        let adaptive = AdaptiveQuality(
            mediaKbps: media?.bitrate, linkKbps: linkKbps, cap: dataCap, map: qualityCurve,
            source: sourcePicture, view: viewPicture,
            now: ProcessInfo.processInfo.systemUptime
        )
        self.adaptive = adaptive
        autoRung = adaptive.rung
    }

    /// The bitrate and picture size Auto's rung asks of the server when it is a step of the title's quality curve;
    /// nil for Original, a preset, or a quality the viewer fixed.
    private var autoTarget: DownloadTarget? {
        qualitySetting == .auto ? autoRung.target : nil
    }

    /// How long the start waits for HomeLabber's answer. A slower one is kept by the lookup's cache for the next item.
    private static let curveWait = Duration.seconds(1.5)

    /// HomeLabber's quality curve for the version playing, on this screen (`QualityMapAnswer.curve(for:screen:)`). It
    /// is asked for only while Auto picks the stream: a fixed quality is the viewer's own choice, and Force Direct
    /// Play keeps every file as it is.
    private func measuredCurve(of full: PlexMetadata, media: PlexMedia) async -> QualityCurve? {
        guard qualitySetting == .auto, !forcesDirectPlay else { return nil }
        let downloads = session.downloads
        let server = library.server.clientIdentifier
        let key = full.ratingKey
        let answer = await TimeLimit.answer(within: Self.curveWait) {
            await downloads.qualityMapAnswer(server: server, ratingKey: key)
        }
        return answer?.curve(for: media, screen: .current)
    }

    /// The highest quality Save Data plays at on mobile data, a hotspot or Low Data Mode: 720p at 4 Mbit/s, about
    /// 1.8 GB an hour where a 1080p original commonly takes 4 to 5.
    static let savedDataCap = VideoQuality.mbps4

    /// The phone moved on or off a metered network, or Save Data changed: the item goes on under the new cap.
    func dataCapMayHaveChanged() {
        guard request.download == nil, phase == .playing,
              (session.settings.savesData && session.isMetered ? Self.savedDataCap : nil) != dataCap else { return }
        let playing = quality, playingTarget = autoTarget
        abandonMove()
        startAdapting(connection: streamConnection)
        Diag.event(.player, "data.cap", ["cap": dataCap.map { "\($0)" }, "playing": "\(playing)", "now": "\(quality)"], .notice)
        if quality != playing || autoTarget != playingTarget { reroute(handPick: false) }
    }

    /// The reading of the link to `connection` that serves: recent, from this network, and not given up on (`LinkMemory`).
    private func recentKbps(over connection: PlexConnection) -> Int? {
        guard connection.uri == linkAddress else { return nil }
        return session.player.links.recent(
            to: connection.uri, at: ProcessInfo.processInfo.systemUptime, network: session.presenceNetworkRevision
        )
    }

    /// The phone failed to read the file over a link the measurement called fast enough: on this network the server
    /// streams from now on.
    private func distrustLink() {
        guard case .nearByLink = reach, let address = linkAddress else { return }
        session.player.links.distrust(address, network: session.presenceNetworkRevision)
        Diag.event(.player, "link.distrusted", [:], .notice)
    }

    /// Measures the link by reading the start of the file (`LinkProbe`), records the reading and starts Auto and
    /// `reach` again from it. True when the link was measured.
    private func probeLink(part: PlexPart) async -> Bool {
        guard request.download == nil, !forcesDirectPlay, !linkProbed, let address = linkAddress else { return false }
        let network = session.presenceNetworkRevision
        guard !session.player.links.isDistrusted(address, network: network) else { return false }
        linkProbed = true
        let started = ContinuousClock.now
        guard let connection = try? await library.connection.connection(), connection.uri == address,
              let url = try? await library.playbackURL(path: part.key) else { return false }
        let kbps = await LinkProbeRead.kbps(of: url, headers: library.authorizationHeaders())
        Diag.event(.player, "link.probe", ["kbps": kbps, "ms": Diag.ms(since: started)], .notice)
        guard let kbps, !Task.isCancelled, address == linkAddress, network == session.presenceNetworkRevision else { return false }
        session.player.links.record(kbps, to: address, at: ProcessInfo.processInfo.systemUptime, network: network)
        startAdapting(connection: connection)
        return true
    }

    private func watchQuality() {
        qualityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                lookAtStream()
                noteLink()
            }
        }
    }

    /// One look for Auto: the link's speed while data moved, the media in hand and the longest wait since the
    /// last look.
    private func lookAtStream() {
        guard var adaptive, phase == .playing, isPlaying, castDevice == nil, landing == nil, !isSeeking,
              !movePending else {
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
        belowQualityFloor = adaptive.belowFloor
        if let move { adapt(to: move) }
    }

    /// One reading of the link from the playing stream, for the next start to go by. The route went by the place when
    /// the link had no recent reading, and a stream that ends early or never ends leaves none. A server stream that
    /// re-encodes is held back by its encoder rather than the link, and says nothing of it.
    private func noteLink() {
        guard !linkNoted, request.download == nil, castDevice == nil, phase == .playing, isPlaying, landing == nil, !isSeeking,
              route?.reencodesVideo == false, let address = streamConnection?.uri, address == linkAddress else { return }
        switch stream {
        case .transcode, .direct: break
        case .remux, nil: return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let network = session.presenceNetworkRevision
        guard session.player.links.recent(to: address, at: now, network: network) == nil, let transfer = backend.transfer else { return }
        guard let base = readingBase, transfer.bytes >= base.bytes, transfer.seconds >= base.seconds else {
            readingBase = transfer
            return
        }
        let bytes = transfer.bytes - base.bytes, seconds = transfer.seconds - base.seconds
        guard bytes >= Self.readingBytes, seconds >= Self.readingSeconds else { return }
        let kbps = Int(Double(bytes) * 8 / 1000 / seconds)
        linkNoted = true
        session.player.links.record(kbps, to: address, at: now, network: network)
        Diag.event(.player, "link.measured", ["kbps": kbps, "stream": diagStream], .debug)
    }

    /// Moves Auto to `rung`: beside the playing stream when it can, else by a new stream at the playhead.
    private func adapt(to rung: AutoRung) {
        guard let tracks, let media, let part else { return settleMove(at: autoRung) }
        Diag.event(.player, "auto.move", ["from": "\(autoRung)", "to": "\(rung)", "estimateKbps": adaptive?.estimateKbps, "at": time], .notice)
        movePending = true
        moveTask = Task { [weak self] in
            guard let self else { return }
            let choice = await chooseRoute(tracks: tracks, media: media, part: part, quality: rung.quality, target: rung.target)
            guard !Task.isCancelled else { return }
            if StreamKey(choice.route) == streamKey {
                // The file plays the same at this rung.
                take(choice)
                return settleMove(at: rung)
            }
            if canSwitchBeside(to: choice, buffer: Self.switchBuffer), await prepareSwitch(to: choice, rung: rung) { return }
            guard !Task.isCancelled else { return }
            restartForMove(choice, rung: rung)
        }
    }

    /// The standby takes over only on the phone's own screen, from a stream with `buffer` seconds in hand, to a server
    /// stream or the file with the same sound and subtitle.
    private func canSwitchBeside(to choice: RouteChoice, buffer minimum: TimeInterval) -> Bool {
        guard let route, choice.route.kind != .remux, choice.route.audio?.id == route.audio?.id,
              choice.route.subtitle == route.subtitle, !(pictureInPicture?.isActive ?? false), !isExternalPlayback,
              UIApplication.shared.applicationState == .active
        else { return false }
        return (backend.bufferedAhead ?? 0) >= minimum
    }

    /// Opens the stream at `rung` on the standby player, primed at a movie time `lead` seconds ahead (the usual lead
    /// when nil), and arms the switch for when the playhead gets there. False, with nothing of it left, when that
    /// failed or came too late.
    private func prepareSwitch(to choice: RouteChoice, rung: AutoRung, lead: TimeInterval? = nil) async -> Bool {
        guard let part, let playingOrigin = origin else { return false }
        // A move given up meanwhile has dropped its standby; a later one may hold the next.
        func failed() -> Bool {
            if !Task.isCancelled { dropStandby() }
            return false
        }
        let at = time + (lead ?? Self.switchLead)
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
        if case .transcode(let id) = next.stream {
            let length = playerItem.duration.seconds
            next.master = url
            next.origin = await serverStreamOrigin(
                master: url, session: id, itemDuration: length.isFinite && length > 0 ? length : nil, offset: next.offset
            )
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
        Diag.event(.player, "auto.standby", ["rung": "\(rung)", "switchAt": at])
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
            end(transcode: session, reporter: reporter)
        case .direct, nil:
            break
        }
        stream = next.stream
        streamKey = StreamKey(next.choice.route)
        streamConnection = next.connection
        reporter = next.reporter
        transcodeOffset = next.offset
        transcodeMaster = next.master
        origin = next.origin
        mediaInfo = nil
        lastTransfer = nil
        take(next.choice)
        if let item = backend.player?.currentItem {
            streamText.attach(to: item)
            enhance?.attach(item)
        }
        let lost = replacingLost
        settleMove(at: next.rung)
        Diag.event(.player, lost ? "conversion.switched" : "auto.switched", ["rung": "\(next.rung)", "at": time, "stream": diagStream], .notice)
    }

    /// Moves Auto by a new stream at the playhead, keeping the screen as it is.
    private func restartForMove(_ choice: RouteChoice, rung: AutoRung) {
        // The lost stream's last reads say nothing of the link.
        let lost = replacingLost
        if lost { stopStream(measured: false) }
        take(choice)
        settleMove(at: rung)
        generation += 1
        let generation = generation
        loadTask?.cancel()
        Diag.event(.player, lost ? "conversion.restart" : "auto.restart", ["rung": "\(rung)", "at": time], .notice)
        isBuffering = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            if case .sidecar(let track) = choice.route.subtitle { await loadSidecar(track) }
            guard generation == self.generation else { return }
            // Where playback is now: the old stream plays on while the subtitles load, and a seek may move it.
            await startStream(at: landing ?? time, generation: generation)
        }
    }

    // MARK: Lost conversion

    /// The stream is a server conversion that plays: the one the server can lose.
    private var watchesConversion: Bool {
        guard !closed, phase == .playing, castDevice == nil, landing == nil, request.download == nil,
              case .transcode = stream else { return false }
        return true
    }

    /// A segment of the stream answered 404 (an entry in AVPlayer's error log). A move under way replaces the stream
    /// anyway, so what the old one answers meanwhile does not count.
    private func segmentNotFound() {
        guard watchesConversion, !movePending, standby == nil else { return }
        act(on: conversion.notFound(at: ProcessInfo.processInfo.systemUptime, bufferAhead: backend.bufferedAhead))
    }

    /// AVPlayer gave up on the missing segments and failed the item. True when the conversion is replaced.
    private func conversionFailed() -> Bool {
        guard watchesConversion else { return false }
        let verdict = conversion.failed(at: ProcessInfo.processInfo.systemUptime)
        guard case .recover = verdict else { return false }
        act(on: verdict, itemFailed: true)
        return true
    }

    private func act(on verdict: ConversionWatch.Verdict, itemFailed: Bool = false) {
        switch verdict {
        case .wait:
            break
        case .recover(let cause, let missed):
            Diag.event(.player, "conversion.lost", [
                "cause": cause.rawValue, "missed": missed, "ahead": backend.bufferedAhead, "at": time, "stream": diagStream,
            ], .warning)
            conversion.recovered(at: ProcessInfo.processInfo.systemUptime)
            replaceLostConversion(itemFailed: itemFailed)
        case .giveUp:
            Diag.event(.player, "conversion.lost", [
                "cause": "again", "ahead": backend.bufferedAhead, "at": time, "stream": diagStream,
            ], .warning)
            streamFailed(PlaybackFailure(
                text: "\(library.server.name) stopped sending the video.", detail: "The server lost the conversion again and again"
            ))
        }
    }

    /// Starts the conversion again where the playhead is. With enough of the old stream buffered, the new one is
    /// prepared beside it and takes over before it runs dry, so the picture does not stop; otherwise at once.
    private func replaceLostConversion(itemFailed: Bool) {
        let buffer = backend.bufferedAhead ?? 0
        guard !itemFailed, let route, let subtitle, buffer >= Self.recoveryBuffer else {
            // The lost stream's last reads say nothing of the link.
            Diag.event(.player, "conversion.restart", ["at": time], .notice)
            stopStream(measured: false)
            return restart(at: time)
        }
        let choice = RouteChoice(subtitle: subtitle, route: route, enhancements: enhancements, isAnime: treatsAsAnime)
        let rung = autoRung
        let lead = min(Self.switchLead, buffer - Self.recoveryMargin)
        movePending = true
        replacingLost = true
        moveTask = Task { [weak self] in
            guard let self else { return }
            if canSwitchBeside(to: choice, buffer: Self.recoveryBuffer), await prepareSwitch(to: choice, rung: rung, lead: lead) { return }
            guard !Task.isCancelled else { return }
            restartForMove(choice, rung: rung)
        }
    }

    /// Gives up the move under way, if any: playback stays at the rung it had.
    private func abandonMove() {
        if movePending || standby != nil { Diag.event(.player, "auto.abandoned", ["standby": standby != nil], .debug) }
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

    private func settleMove(at rung: AutoRung) {
        movePending = false
        replacingLost = false
        autoRung = rung
        adaptive?.moved(to: rung, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Where a server stream started at `offset` begins in the movie. Some servers list the whole film whatever
    /// the offset; the stream then starts at zero.
    private func transcodeOrigin(itemDuration: TimeInterval?, offset: TimeInterval) -> TimeInterval {
        if let length = itemDuration, duration > 0, length >= duration - 30 { return 0 }
        return offset
    }

    /// The same, measured from the segment the player starts in (`ServerStreamClock`): the playlist alone was
    /// 1.8 s off for a copied picture begun part-way, and subtitles showed that early. A stream from the start
    /// begins with the title, so it is not measured; a measure that fails, or lands further from the listed
    /// origin than the 10 s a segment spans, leaves the listed one.
    private func serverStreamOrigin(master: URL?, session: String, itemDuration: TimeInterval?, offset: TimeInterval) async -> TimeInterval {
        let listed = transcodeOrigin(itemDuration: itemDuration, offset: offset)
        guard offset > 0, let master else { return listed }
        let start = offset - listed
        let measured = (try? await library.serverStreamOrigin(master: master, session: session, startingAt: start)) ?? nil
        let kept = measured.flatMap { abs($0 - listed) <= 10 ? $0 : nil }
        Diag.event(.player, "stream.origin", ["listed": listed, "measured": measured, "start": start, "used": kept ?? listed])
        return kept ?? listed
    }

    /// Sets the playing server stream's origin once measured, then lands it.
    private func measureOrigin(of session: String) {
        let generation = generation, master = transcodeMaster, length = backend.itemDuration, offset = transcodeOffset
        Task { [weak self] in
            guard let self else { return }
            let measured = await serverStreamOrigin(master: master, session: session, itemDuration: length, offset: offset)
            guard generation == self.generation, case .transcode(let playing) = stream, playing == session, origin == nil else { return }
            origin = measured
            land()
        }
    }

    /// A remux run's failure a new run can get past: the source unreachable or its read failing, not a refusal
    /// that stays or a file the engine cannot make a stream of.
    private static func isRetryable(_ error: VideoEngineError) -> Bool {
        switch error {
        case .sourceUnreachable(let status): StreamReconnect.isRetryable(status: status)
        case .readFailed, .timedOut: true
        default: false
        }
    }

    /// A stream that fails while it plays starts again at the last played position, on the same route, after a
    /// growing wait, and shows as buffering throughout. False when the failure is of the kind that stays or the
    /// budget is spent: the failure then takes the way it always did.
    private func reconnect(after failure: PlaybackFailure, route: PlaybackRoute) -> Bool {
        guard phase == .playing, castDevice == nil, failure.isRetryable else { return false }
        guard case .reconnect(let attempt, let wait) = reconnection.failed(now: ProcessInfo.processInfo.systemUptime) else {
            reconnecting = false
            return false
        }
        // A stream that was itself starting by this reconnect has its landing as the position.
        let at = landing ?? time
        let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
        Diag.event(.player, "stream.reconnect", [
            "n": attempt, "after": seconds, "reason": failure.detail, "route": route.kind.rawValue, "at": at,
        ], .warning)
        if !reconnecting { reconnectBegan = .now }
        reconnecting = true
        generation += 1
        let generation = generation
        loadTask?.cancel()
        landing = at
        isBuffering = true
        let address = streamConnection
        // The lost stream's last reads say nothing of the link.
        stopStream(measured: false)
        loadTask = Task { [weak self] in
            guard let self else { return }
            if let address { await library.connection.reportFailure(of: address) }
            try? await Task.sleep(for: wait)
            guard generation == self.generation, !Task.isCancelled else { return }
            await startStream(at: at, generation: generation)
        }
        return true
    }

    private func streamFailed(_ failure: PlaybackFailure) {
        Diag.event(.player, "stream.failed", [
            "error": failure.text, "detail": failure.detail, "route": route?.kind.rawValue, "stream": diagStream, "at": time,
        ], .warning)
        if request.download != nil { fail(failure); return }
        guard !closed, phase != .finished, let route else {
            fail(failure)
            return
        }
        if reconnect(after: failure, route: route) { return }
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
            if route.kind == .remux { distrustLink() }
            Diag.event(.player, "recover", ["how": "server"], .notice)
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
            Diag.event(.player, "recover", ["how": "without-enhancements"], .notice)
            stopStream()
            enterLoading()
            loadTask = Task { [weak self] in
                guard let self else { return }
                await decideRoute()
                guard generation == self.generation else { return }
                await startStream(at: at, generation: generation)
            }
        case .serverTranscode:
            guard case .retry(let delay) = recovery.failed() else {
                fail(PlaybackFailure(text: "\(library.server.name) couldn't start the video.", detail: failure.detail))
                return
            }
            Diag.event(.player, "recover", ["how": "retry", "delay": delay], .notice)
            // The next try is a new session, on whichever address answers by then.
            let address = streamConnection
            stopStream()
            enterLoading()
            loadTask = Task { [weak self] in
                guard let self else { return }
                if let address { await library.connection.reportFailure(of: address) }
                try? await Task.sleep(for: delay)
                guard generation == self.generation, !Task.isCancelled else { return }
                await startStream(at: at, generation: generation)
            }
        }
    }

    private func fail(_ message: String) {
        fail(PlaybackFailure(text: message))
    }

    private func fail(_ failure: PlaybackFailure) {
        Diag.event(.player, "failed", ["error": failure.text, "detail": failure.detail, "at": time, "route": route?.kind.rawValue], .error)
        failureDetail = failure.detail
        let message = failure.text
        reconnecting = false
        // Work still under way for the failed stream, a landing among it, ends here.
        generation += 1
        stopStream()
        report(.stopped)
        stageTask?.cancel()
        showsStage = false
        cancelCountdown("failed")
        offer = nil
        skipCheck = nil
        landing = nil
        isBuffering = false
        phase = .failed(message)
        chromeVisible = true
    }

    private func enterLoading() {
        phase = .loading
        // Whatever the last item left, the next one loads with its controls up.
        showChrome()
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
        Diag.event(.player, "go", ["item": target.ratingKey, "from": item.ratingKey, "at": time], .notice)
        lastPreviousPress = nil
        report(.stopped)
        stopStream()
        handAudio = nil
        handSubtitle = nil
        onDeviceFailed = false
        fallback = nil
        failureDetail = nil
        wroteBack = false
        recovery.reset()
        reconnection.reset()
        reconnecting = false
        introCancelled = false
        skippedIntroEnd = nil
        skipCheck = nil
        creditsDismissed = false
        countdownStopped = false
        markedWatched = false
        cancelCountdown("next-item")
        offer = nil
        sidecar = nil
        sidecarID = nil
        route = nil
        subtitle = nil
        subtitleProblem = nil
        timing.reset()
        showsTiming = false
        trickplay = nil
        trickplayFailed = false
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
            if case .transcode(let session) = stream, origin == nil {
                measureOrigin(of: session)
            } else {
                land()
            }
        case .failed(let failure):
            if runSeekPending { return }
            if failure.isNotFound, conversionFailed() { return }
            streamFailed(failure)
        case .ended:
            if runSeekPending { return }
            ended()
        case .externalPlayback(let active):
            externalPlaybackChanged(active)
        case .presentationSize(let size):
            presentationSize = size
        case .switchDue:
            completeSwitch()
        case .segmentNotFound:
            segmentNotFound()
        }
    }

    /// Moves a new stream to where playback should be, once it is ready and its origin known, and picks its
    /// tracks. Only then does it show as playing, in the same turn as play is asked for.
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
            if abs(backend.itemTime - local) > 0.5 {
                let started = ContinuousClock.now
                let done = await backend.seek(to: local, precise: true)
                Diag.event(.player, "land.seek", [
                    "to": target, "now": backend.itemTime + origin, "ok": done, "ms": Diag.ms(since: started),
                ], done ? .debug : .notice)
            }
            guard generation == self.generation, serial == seekSerial, !Task.isCancelled else { return }
            await applySelection()
            guard generation == self.generation, serial == seekSerial, !Task.isCancelled else { return }
            // A seek made meanwhile moved the target.
            guard landing == target else { return land() }
            landing = nil
            farSeeking = false
            isBuffering = false
            arrived()
        }
    }

    private func arrived() {
        recovery.reset()
        stallWatch.streamStarted(now: ProcessInfo.processInfo.systemUptime)
        startDeadline?.cancel()
        startDeadline = nil
        phase = .playing
        stageTask?.cancel()
        showsStage = false
        if case .remux = stream {
            backend.player?.currentItem?.preferredForwardBufferDuration = RemuxSession.recommendedForwardBufferDuration
        }
        loadTrickplay(now: false)
        if !wroteBack {
            wroteBack = true
            writeBack()
        }
        if wantsPlay { backend.play() }
        let first = startTiming.milliseconds(.playing) == nil
        startTiming.mark(.playing)
        if let origin { time = backend.itemTime + origin }
        if first {
            Diag.event(.player, "started", ["timing": startTiming.summary, "at": time, "stream": diagStream, "paused": !wantsPlay], .notice)
        } else {
            Diag.event(.player, "landed", ["at": time, "stream": diagStream])
        }
        if reconnecting {
            reconnecting = false
            reconnection.landed(at: time)
            Diag.event(.player, "stream.reconnected", [
                "n": reconnection.attempts, "at": time, "route": route?.kind.rawValue, "ms": reconnectBegan.map { Diag.ms(since: $0) },
            ], .notice)
        }
        publishPosition()
        report()
        // A picture left paused, by a call during the load say, keeps its controls.
        if wantsPlay { scheduleHide() } else { showChrome() }
    }

    /// The end of the playing item's seekable range, in item time: 0 while it has none, nil without an AVPlayer.
    private var itemSeekableEnd: TimeInterval? {
        guard let item = backend.player?.currentItem else { return nil }
        guard let end = item.seekableTimeRanges.last?.timeRangeValue.end.seconds, end.isFinite else { return 0 }
        return end
    }

    private func seekItem(_ local: TimeInterval) {
        seekSerial += 1
        let serial = seekSerial
        isSeeking = true
        streamText.reset()
        seekTask?.cancel()
        let started = ContinuousClock.now
        seekTask = Task { [weak self] in
            guard let self else { return }
            let done = await backend.seek(to: local, precise: true)
            let now = backend.itemTime
            let short = !done || abs(now - local) > 1
            Diag.event(.player, "seek.result", ["to": local, "now": now, "ok": done, "ms": Diag.ms(since: started)], short ? .notice : .debug)
            guard serial == seekSerial else { return }
            isSeeking = false
            publishPosition()
        }
    }

    /// A seek outside what the item holds: the remux keeps its run when the target is already written, else it
    /// restarts there. Quick repeats wait for the last.
    private func farSeek(_ remux: RemuxSession, to target: TimeInterval) {
        landing = target
        farSeeking = true
        isBuffering = true
        seekSerial += 1
        let serial = seekSerial
        seekTask?.cancel()
        // An in-buffer seek this one overtakes never reports back: its serial is stale.
        isSeeking = false
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, serial == seekSerial, !Task.isCancelled, case .remux(let current) = stream, current === remux else { return }
            Diag.event(.player, "far.seek", ["to": target, "written": remux.progress.mediaSeconds])
            // The item stays up while the engine decides, and a replaced run ends it: that end is not a failure.
            runSeekPending = true
            defer { runSeekPending = false }
            do {
                let seek = try await remux.seekReusing(to: target)
                guard serial == seekSerial, case .remux(let current) = stream, current === remux else { return }
                if seek.reused {
                    // Same run, same item: it only needs to move.
                    Diag.event(.player, "seek.reused", ["to": target, "item": seek.itemTime], .debug)
                    land()
                    return
                }
                // The old item is let go first, so its end does not count as a failure.
                backend.load(nil)
                itemReady = false
                // The new run's timeline can arrive before this resumes, while the old origin still stood.
                origin = remux.timelineOrigin
                remuxFinished = false
                try await handOff(remux, landing: target)
                guard serial == seekSerial else { return }
                load(seek.url)
            } catch {
                guard serial == seekSerial, !(error is CancellationError) else { return }
                streamFailed(PlaybackFailure(text: Self.message(error)))
            }
        }
    }

    private func tick(_ itemTime: TimeInterval) {
        // AVPlayer's observer fires once more as a stream is let go, with `origin` still that stream's.
        // Outside playback a time is not this item's, and would raise the last item's offers again.
        guard phase == .playing, let origin, landing == nil else { return }
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
        reconnection.playing(at: movie)
        checkSkip(at: movie, pending: isBuffering || !isPlaying)
        sample(at: movie)
    }

    private func stateChanged(playing: Bool, buffering: Bool) {
        let wasPlaying = isPlaying
        if playing != wasPlaying || buffering != isBuffering {
            Diag.event(.player, "state", ["playing": playing, "buffering": buffering, "at": time], .debug)
        }
        isPlaying = playing
        refreshEnhance()
        isBuffering = buffering || landing != nil
        if case .remux(let remux) = stream { remux.setPlayerWaiting(buffering) }
        if playing, buffering { watchStall() } else { endStall() }
        if !playing || buffering {
            if case .upNext? = offer { interruptCountdown() } else { cancelCountdown(playing ? "buffering" : "paused") }
        } else {
            startCountdownIfDue()
        }
        report()
        publishPosition()
        // A pause from anywhere, the lock screen, a call or a lost route among them, brings the controls
        // back over the still picture.
        if playing { scheduleHide() } else if wasPlaying { showChrome() } else { hideTask?.cancel() }
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
        seekWaitStart = nil
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
        // A seek's own wait is the user's doing; the watch starts again once it is over. Past 2 s the
        // controls come back all the same, with the loading ring.
        guard landing == nil, !isSeeking else {
            waitsForNetwork = false
            let now = ProcessInfo.processInfo.systemUptime
            let start = seekWaitStart ?? now
            seekWaitStart = start
            if now - start >= 2 {
                hideTask?.cancel()
                if !chromeVisible { setChrome(true) }
            }
            return stallWatch.resume()
        }
        seekWaitStart = nil
        isStalled = true
        var run: StallWatch.Run?
        var paced = false
        if case .remux(let remux) = stream, let origin {
            let progress = remux.progress
            run = StallWatch.Run(produced: origin + progress.mediaSeconds, fetching: progress.isFetching, finished: progress.isFinished)
            paced = progress.isPaced
        }
        switch stallWatch.check(now: ProcessInfo.processInfo.systemUptime, position: time, run: run) {
        case .network(let seconds):
            longestWait = max(longestWait, seconds)
            guard seconds >= 2 else { return }
            // The standby cannot take over from a stalled stream. A conversion the server lost is started again at
            // once; Auto's next look moves by a new stream instead.
            if replacingLost {
                stopStream(measured: false)
                restart(at: time)
            } else if standby != nil {
                abandonMove()
            }
            if !waitsForNetwork {
                diagStalls += 1
                Diag.event(.player, "stall", ["at": time, "seconds": seconds, "stream": diagStream, "ahead": backend.bufferedAhead], .notice)
                withAnimation(.easeOut(duration: 0.18)) { waitsForNetwork = true }
            }
            hideTask?.cancel()
            if !chromeVisible { setChrome(true) }
            if seconds >= 10 { offerLowerQuality() }
        case .stuck(let ahead, let cause):
            let at = time
            recoveries = Recoveries(count: (recoveries?.count ?? 0) + 1, at: at, ahead: ahead, cause: cause)
            Diag.event(.player, "stall.recovered", ["at": at, "ahead": ahead, "paced": paced, "cause": cause.rawValue], .warning)
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
        cancelCountdown("lower-quality")
        withAnimation(.easeOut(duration: 0.22)) { offer = .lowerQuality(lower) }
        Diag.event(.offers, "lower-quality.shown", ["quality": "\(lower)", "at": time], .notice)
    }

    private func ended() {
        Diag.event(.player, "ended", ["at": time, "hasNext": queue?.item(after: item) != nil, "countdown": countdown != nil], .notice)
        if case .upNext? = offer, countdown != nil {
            next()
            return
        }
        if session.settings.autoplay.playsNextAtEnd(creditsWatched: creditsDismissed), queue?.item(after: item) != nil {
            next()
            return
        }
        if !markedWatched { markWatched() }
        report(.stopped)
        cancelCountdown("ended")
        offer = nil
        isPlaying = false
        phase = .finished
        showChrome()
        publishPosition()
    }

    private func externalPlaybackChanged(_ active: Bool) {
        Diag.event(.player, "external", ["active": active, "stream": diagStream], .notice)
        isExternalPlayback = active
        refreshEnhance()
        PlaybackCapabilities.externalPlaybackActive = active
        textRendererChanged()
        updateNowPlayingSight()
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
        placedCues = []
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
                // Over a remux that started with the file, it also rides in the stream for Picture in Picture; a file
                // picked later is only drawn here, so the stream is not restarted for it.
                textCues = sidecar.cues
            }
        case .inStream(let track) where route.kind == .remux && track.isImageBased:
            guard case .remux(let remux) = stream, let index = streamIndex(track.id) else { return }
            // With the text copy on, the stream has a second entry for the same index. The app draws the overlay
            // and never selects that rendition, so the two do not show together.
            overlayTrack = remux.subtitleStreams.first { $0.streamIndex == index && !$0.isRecognizedFromPicture }?.overlay
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
        let lines = textCues.isEmpty ? (line: streamLine(at: due), placed: [PlacedCue]()) : cueLines(at: due)
        if lines.line?.text != cueText { cueText = lines.line?.text }
        let words = lines.line?.words ?? []
        if words != cueWords { cueWords = words }
        if lines.placed != placedCues { placedCues = lines.placed }
    }

    /// What the sidecar shows at `movie`: the line in the viewer's look, and the cues the file places itself, one
    /// block for each place, so a sign at the top and the dialogue at the bottom show together.
    private func cueLines(at movie: TimeInterval) -> (line: ShownLine?, placed: [PlacedCue]) {
        let reveal = session.settings.subtitleStyle.reveal
        var line: ShownLine?
        var places: [CueAlignment] = []
        var placed: [CueAlignment: ShownLine] = [:]
        for cue in textCues where cue.start <= movie && movie < cue.end {
            if let alignment = cue.alignment {
                if placed[alignment] == nil { places.append(alignment) }
                placed[alignment, default: ShownLine()].add(cue.text, [], at: movie - cue.start)
                continue
            }
            let text = String(cue.text.characters)
            // SpeechDock's times once it has timed the cue, the estimate until then.
            let words = wordTiming?.starts(at: cue.start).flatMap { SubtitleReveal.measured(text, starts: $0, by: reveal) }
                ?? SubtitleReveal.estimate(text, duration: cue.end - cue.start, by: reveal)
            var shown = line ?? ShownLine()
            shown.add(cue.text, words, at: movie - cue.start)
            line = shown
        }
        return (line, places.compactMap { place in placed[place].map { PlacedCue(alignment: place, text: $0.text) } })
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

    /// Over a moving picture the controls step aside, so the lines being matched show where they always
    /// do; a paused picture keeps them.
    func openTiming() {
        guard canTimeSubtitles else { return }
        showsTiming = true
        if pictureMoves, !assistiveTechnologyRuns { setChrome(false) }
    }

    func closeTiming() {
        showsTiming = false
    }

    // MARK: Finding subtitles

    /// Bazarr, once its address and key are saved in Settings.
    var bazarr: BazarrClient? { session.bazarr.client }

    func findSubtitles() {
        subtitleFinder.find(in: self)
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
        if let end = skippedIntroEnd, movie >= end - 1 { skippedIntroEnd = nil }
        if skippedIntroEnd == nil, let intro = item.markers(.intro).first(where: { $0.contains(ms) }), Double(intro.end) / 1000 - movie > 1 {
            next = .skipIntro(end: Double(intro.end) / 1000)
        } else if !creditsDismissed, let credits = finalCredits, ms >= credits.start, let upcoming = queue?.item(after: item) {
            if session.settings.autoplay.atCredits == .playNow {
                // Binge mode: no card. The flag keeps later ticks from repeating the jump; `go` clears it for the next episode.
                guard offer == nil, phase == .playing, isPlaying, !isBuffering, !isScrubbing, menusOpen == 0 else { return }
                creditsDismissed = true
                Diag.event(.offers, "autoplay.now", ["next": upcoming.ratingKey, "at": movie], .notice)
                go(to: upcoming)
                return
            }
            next = .upNext(upcoming)
        }
        guard next != offer else { return }
        Diag.event(.offers, "offer", [
            "from": Self.diagOffer(offer), "to": Self.diagOffer(next), "at": movie, "skipped": skippedIntroEnd,
            "introCancelled": introCancelled,
        ])
        cancelCountdown("offer-changed")
        withAnimation(.easeOut(duration: 0.22)) { offer = next }
        startCountdownIfDue()
        if case .upNext(let upcoming)? = next { prewarmNext(upcoming) }
    }

    /// Reads the opening bytes of the next episode once, as its card appears, so the remux that starts it opens
    /// without a round trip. Only for a phone that already repackages this file itself (the next one usually takes
    /// the same route), not on a metered link or with Save Data, and never for downloads.
    private func prewarmNext(_ upcoming: PlexMetadata) {
        guard prewarmedKey != upcoming.ratingKey, request.download == nil, castDevice == nil, route?.kind == .remux,
              !session.isMetered, !session.settings.savesData,
              let path = upcoming.media.first?.parts.first?.key else { return }
        prewarmedKey = upcoming.ratingKey
        let headers = library.authorizationHeaders()
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            guard let self, let connection = try? await library.connection.connection(), !Task.isCancelled,
                  let url = PlexURL.make(base: connection.uri, path: path) else { return }
            let held = await EnginePrewarm.prewarm(url: url, headers: headers)
            Diag.event(.player, "prewarm", ["item": upcoming.ratingKey, "held": held], .debug)
        }
    }

    private func startCountdownIfDue() {
        guard countdown == nil, phase == .playing, isPlaying, !isBuffering else { return }
        let settings = session.settings
        switch offer {
        case .skipIntro?:
            guard settings.introSkipDelay > 0, !introCancelled else { return }
            runCountdown(TimeInterval(settings.introSkipDelay)) { [weak self] in self?.skipIntro(auto: true) }
        case .upNext?:
            guard case .countdown(let seconds) = settings.autoplay.atCredits, !countdownStopped, menusOpen == 0, !isScrubbing else { return }
            runCountdown(TimeInterval(seconds)) { [weak self] in self?.next() }
        case .lowerQuality?, nil:
            break
        }
    }

    private func runCountdown(_ length: TimeInterval, then action: @escaping @MainActor () -> Void) {
        Diag.event(.offers, "countdown.start", ["offer": Self.diagOffer(offer), "seconds": length, "at": time])
        countdown = Countdown(start: .now, length: length)
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length))
            guard let self, !Task.isCancelled, countdown != nil else { return }
            // Let go of the task first: the action's own `cancelCountdown` would otherwise cancel the task it runs in.
            countdownTask = nil
            countdown = nil
            Diag.event(.offers, "countdown.fire", ["offer": Self.diagOffer(offer), "at": time], .notice)
            action()
        }
    }

    private func cancelCountdown(_ reason: String) {
        if countdown != nil { Diag.event(.offers, "countdown.cancel", ["reason": reason, "offer": Self.diagOffer(offer), "at": time]) }
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    /// Pause, buffering, menus and any input stop the Up Next countdown until the next episode.
    private func interruptCountdown() {
        guard case .upNext? = offer, countdown != nil else { return }
        cancelCountdown("interrupted")
        countdownStopped = true
    }

    /// Confirms an intro skip once playback has run on (`SkipCheck`). A miss is tried once more; a second miss
    /// brings the Skip Intro offer back without its countdown, so a lost skip never leaves the intro playing
    /// with nothing to press.
    private func checkSkip(at movie: TimeInterval, pending: Bool) {
        guard var check = skipCheck else { return }
        let step = skipCheckAt.map { movie - $0 } ?? 0
        skipCheckAt = movie
        // Only steady playback counts: a jump is a seek or a new stream.
        let advanced = step > 0 && step <= 2 ? step : 0
        let verdict = check.check(playhead: movie, advanced: advanced, pending: pending)
        skipCheck = check
        switch verdict {
        case .waiting:
            break
        case .landed:
            skipCheck = nil
            Diag.event(.offers, "skip.landed", ["at": movie, "end": check.target, "retried": check.retried])
        case .retry:
            Diag.event(.offers, "skip.missed", list: diagSkipState(check, at: movie), .warning)
            skipCheckAt = nil
            if !move(to: check.target, cause: "skip-retry") {
                Diag.event(.offers, "skip.retry.refused", ["phase": Self.diagPhase(phase)], .warning)
            }
        case .missed:
            skipCheck = nil
            skippedIntroEnd = nil
            introCancelled = true
            Diag.event(.offers, "skip.gave-up", list: diagSkipState(check, at: movie), .error)
        }
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
        guard state == .stopped else {
            Task { await reporter.update(state, time: time, duration: length) }
            return
        }
        // Where the viewer stopped is what Plex's Continue Watching goes by.
        settle("stopped", touching: watchKeys) { await reporter.update(.stopped, time: time, duration: length) }
    }

    private func markWatched() {
        Diag.event(.player, "watched", ["at": time])
        markedWatched = true
        if request.download != nil { report(); return }
        let library = library, key = item.ratingKey
        settle("watched", touching: watchKeys) { (try? await library.markWatched(key)) != nil }
    }

    /// The item, its season and its show: what a change to its watch state touches.
    private var watchKeys: Set<String> {
        Set([item.ratingKey, item.parentRatingKey, item.grandparentRatingKey].compactMap(\.self))
    }

    /// Sends a change to the item's watch state and, once the server has it, has the screens showing the
    /// item refetch (`LibraryChanges`). Home loaded only at launch, so its Continue Watching stayed on the
    /// episode watched before the app opened, however many followed (2026-11-20). The send is held open
    /// with the app in the background: closing Picture in Picture there let iOS suspend the app before the
    /// stopped report went, and Plex kept the episode's old place in the row.
    private func settle(_ what: String, touching keys: Set<String>, send: @escaping @MainActor () async -> Bool) {
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "marquee-\(what)")
        let changes = session.changes, key = item.ratingKey
        Task {
            defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }
            let sent = await send()
            Diag.event(.player, "server.\(what)", ["item": key, "ok": sent])
            if sent { changes.record(keys) }
        }
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
        guard let tracks else { return }
        var memory = session.trackMemory(for: item) ?? TrackMemory()
        if let id = handAudio, let track = tracks.audioTrack(id: id) { memory.audio = RememberedAudio(track) }
        if let choice = handSubtitle { memory.subtitle = RememberedSubtitle(choice, in: tracks) }
        memory.anime = animeOverride
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

    /// The Now Playing entry, and with it the Dynamic Island's waveform, only while the picture is out of
    /// sight: the app behind something, Picture in Picture or AirPlay.
    private func updateNowPlayingSight(active: Bool = UIApplication.shared.applicationState == .active) {
        let inSight = active && !(pictureInPicture?.isActive ?? false) && !isExternalPlayback
        nowPlaying?.setInSight(inSight, time: time, rate: isPlaying && !isBuffering ? 1 : 0)
    }

    /// Where the scrub preview makes its own frames when Plex has no index: the file being played, for a
    /// title without an index, one that failed to load, or a download.
    var scrubPreviewSource: ScrubPreviewSource? {
        guard let previewFile, let part, castDevice == nil else { return nil }
        let isDownload = request.download != nil
        guard isDownload || !part.hasSceneThumbnails || trickplayFailed else { return nil }
        return previewFile
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
            guard !Task.isCancelled else { return }
            let data = try? await PlexFetch.data("/library/parts/\(part.id)/indexes/sd", library: library, session: urlSession)
            guard !Task.isCancelled, let self, item.ratingKey == key else { return }
            trickplay = data.flatMap { Trickplay(data: $0) }
            trickplayFailed = trickplay == nil
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

    /// The controls fade 3 s after the last input, only while the picture moves and nothing holds them. A
    /// still picture keeps them whatever stopped it, until a tap hides them.
    private func scheduleHide() {
        hideTask?.cancel()
        guard chromeVisible, canFade else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            // A pause, a wait or a new stream may have stopped the picture meanwhile.
            guard let self, !Task.isCancelled, canFade else { return }
            setChrome(false)
        }
    }

    private var canFade: Bool { pictureMoves && !isScrubbing && menusOpen == 0 && !assistiveTechnologyRuns }

    /// Playing, and not loading, waiting for data or landing a new stream.
    private var pictureMoves: Bool { phase == .playing && isPlaying && !isWaiting }

    /// With VoiceOver or Switch Control on, the controls never leave by themselves.
    private var assistiveTechnologyRuns: Bool { UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning }

    private func interrupted(began: Bool, shouldResume: Bool) {
        Diag.event(.audio, "interruption", ["began": began, "resume": shouldResume, "wantsPlay": wantsPlay], .notice)
        if began {
            // The wish to play is kept, not the player's state: a stream still loading, or one AVPlayer
            // paused before the news arrived, plays on all the same.
            let resumes = resumesAfterInterruption || wantsPlay
            pause()
            resumesAfterInterruption = resumes
        } else {
            let resumes = resumesAfterInterruption
            resumesAfterInterruption = false
            if shouldResume, resumes { play() }
        }
    }

    /// Without Picture in Picture or AirPlay the sound plays on alone: a layer showing video would
    /// make the system pause it.
    private func enteredBackground() {
        Diag.event(.player, "background", ["pip": pictureInPicture?.isActive ?? false, "external": isExternalPlayback])
        abandonMove()
        inBackground = true
        refreshEnhance()
        guard !(pictureInPicture?.isActive ?? false), !isExternalPlayback else { return }
        layerView.playerLayer.player = nil
    }

    private func enteringForeground() {
        layerView.playerLayer.player = backend.player
        inBackground = false
        refreshEnhance()
    }

    // MARK: Enhance picture

    /// The setting changed, or the player opened: starts, retunes or stops the enhancer.
    func enhanceSettingsChanged() {
        guard let enhance, !closed else { return }
        let setting = session.settings.pictureEnhance
        switch setting.upscaler {
        case .off: enhance.configure(.off)
        case .automatic: enhance.configure(EnhanceOptions(upscaler: .automatic, sharpen: setting.sharpen, deband: setting.deband))
        case .lineArt: enhance.configure(EnhanceOptions(upscaler: .lineArt, sharpen: setting.sharpen, deband: setting.deband))
        }
        refreshEnhance()
    }

    /// The enhancer works only while the picture plays in the full player, in the foreground, on the phone.
    /// Paused, in the bar, in Picture in Picture, on AirPlay or a cast receiver, the plain picture shows.
    private func refreshEnhance() {
        guard !closed else { return }
        let sees = isPlaying && showsFullPlayer && !inBackground && !isExternalPlayback && castDevice == nil
        enhance?.setActive(sees && !(pictureInPicture?.isActive ?? false))
    }

    func fullPlayerChanged(_ shown: Bool) {
        showsFullPlayer = shown
        refreshEnhance()
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

/// The one playback at a time, a film or a live channel. `presented` and `livePresented` drive the
/// full-screen players; `active` stays while Picture in Picture carries a film without one. A playback
/// minimised to the bar above the tab bar (DESIGN §8.6.1) has no screen and plays on in the bar.
@MainActor @Observable
final class PlayerCenter {
    /// What the bar above the tab bar plays.
    enum Docked {
        case film(PlayerModel)
        case live(LivePlaybackModel)
    }

    var presented: PlayerModel? {
        didSet {
            guard presented !== oldValue else { return }
            oldValue?.fullPlayerChanged(false)
            presented?.fullPlayerChanged(true)
        }
    }
    private(set) var active: PlayerModel?
    /// The live channel playing; `livePresented` is its full-screen player.
    private(set) var live: LivePlaybackModel?
    var livePresented: LivePlaybackModel?
    /// The playback was minimised and has not ended since. It stays set while the player is full screen
    /// again, so the bar is in place for the player to shrink into.
    private(set) var minimised = false
    /// The player opens out of the bar's picture: set by the bar, not by a start or Picture in Picture's
    /// restore. It holds for the whole presentation; a zoom added midway would rebuild the player's view.
    private(set) var zoomsFromBar = false
    /// The bar draws the picture only after the full-screen player has left. Both draw the same layer, and
    /// the bar taking it at once would blank the player while it shrinks into the bar.
    private(set) var barShowsPicture = false
    /// The film or channel whose full-screen cover is leaving after its close button. It ends once the cover
    /// has gone (`dismissed`, `liveDismissed`), so its teardown does not run under the dismiss animation or
    /// the first scroll after it.
    @ObservationIgnored private weak var closingFilm: PlayerModel?
    @ObservationIgnored private weak var closingLive: LivePlaybackModel?
    @ObservationIgnored private var closeFallback: Task<Void, Never>?
    let capabilities = PlaybackCapabilities()
    /// Parts that failed to play on the phone in this run; reopening one goes straight to the server.
    @ObservationIgnored var phoneFailures: Set<Int> = []
    /// What this run's streams measured of each link to a server (`LinkMemory`).
    @ObservationIgnored var links = LinkMemory()
    /// The XR glasses show the player in place of the phone (DESIGN §8.9). When they go, what played
    /// carries on on the phone, paused.
    var onGlasses = false {
        didSet {
            guard onGlasses != oldValue else { return }
            if onGlasses {
                presented = nil
            } else if let active {
                active.pause()
                // Back on the phone it opens full screen as a new presentation, not out of the bar.
                minimised = false
                zoomsFromBar = false
                barShowsPicture = false
                presented = active
            }
        }
    }

    init() {
        RemuxSession.sweepStaleFiles()
        capabilities.startWatching()
    }

    /// The playback in the bar above the tab bar; nil until one is minimised. A film the glasses show is
    /// theirs, while a live channel, which the glasses never take over, keeps its bar on the phone.
    var docked: Docked? {
        guard minimised else { return nil }
        if let active { return onGlasses ? nil : .film(active) }
        return live.map { Docked.live($0) }
    }

    /// Whether a player is open: full screen, minimised or in Picture in Picture.
    var isOpen: Bool { presented != nil || active != nil || live != nil }

    func play(_ request: PlaybackRequest, session: AppSession) {
        guard let library = session.library else { return }
        stopAll()
        let model = PlayerModel(request: request, session: session, library: library, capabilities: capabilities)
        if let pictureInPicture = model.pictureInPicture {
            pictureInPicture.onStart = { [weak self, weak model] in
                Diag.event(.player, "pip", ["state": "started"])
                guard let self, let model, presented === model else { return }
                presented = nil
            }
            pictureInPicture.onRestore = { [weak self, weak model] completion in
                Diag.event(.player, "pip", ["state": "restore"])
                guard let self, let model, active === model else {
                    completion(false)
                    return
                }
                zoomsFromBar = false
                barShowsPicture = false
                presented = model
                // The screen has to host the picture again before the window shrinks into it.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    completion(true)
                }
            }
            pictureInPicture.onClose = { [weak self, weak model] in
                Diag.event(.player, "pip", ["state": "closed"])
                guard let self, let model, active === model, presented == nil else { return }
                model.close()
                active = nil
                minimised = false
            }
        }
        active = model
        presented = onGlasses ? nil : model
        model.start()
    }

    /// A live channel opens full screen; whatever played before stops, a film in Picture in Picture too.
    func playLive(_ model: LivePlaybackModel) {
        stopAll()
        live = model
        livePresented = model
    }

    /// The player's own close button. With its cover up the playback is silenced and the cover leaves first;
    /// `dismissed()` ends it once the cover has gone. The stream, remux, audio session and Now Playing
    /// teardown is the heaviest work the player does on the main thread, and under the dismiss animation or
    /// the first scroll after it a freeze showed (Stashy measured 53 ms).
    func close(_ model: PlayerModel) {
        guard closingFilm !== model else { return }
        guard presented === model, active === model, !onGlasses else {
            end(model)
            return
        }
        model.pause()
        closingFilm = model
        minimised = false
        presented = nil
        endIfCoverStays()
    }

    /// The same for a live channel: held now, ended by `liveDismissed()`.
    func closeLive(_ model: LivePlaybackModel) {
        guard closingLive !== model else { return }
        guard livePresented === model, live === model else {
            endLive(model)
            return
        }
        model.silence()
        closingLive = model
        minimised = false
        livePresented = nil
        endIfCoverStays()
    }

    /// Ends the playback now: there is no cover to wait for (the bar's stop, the glasses, the tabs going).
    private func end(_ model: PlayerModel) {
        if presented === model { presented = nil }
        if active === model {
            model.close()
            active = nil
            minimised = false
        }
    }

    private func endLive(_ model: LivePlaybackModel) {
        if livePresented === model { livePresented = nil }
        if live === model {
            model.close()
            live = nil
            minimised = false
        }
    }

    /// `onDismiss` ends a closing playback. If SwiftUI never reports the cover's end, this does, so a held
    /// stream cannot keep its tuner or audio session open.
    private func endIfCoverStays() {
        closeFallback?.cancel()
        closeFallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if let model = closingFilm, model === active { dismissed() }
            if let model = closingLive, model === live { liveDismissed() }
        }
    }

    /// The full-screen player goes to the bar: the playback goes on and the screen is the app's again
    /// (the player's own disappearance gives a forced landscape back to the phone's hold). Only what is on
    /// screen minimises: a second call, as the cover leaves, would leave the bar without its picture.
    func minimise() {
        guard presented != nil || livePresented != nil else { return }
        Diag.event(.player, "minimise", ["film": active != nil])
        minimised = true
        barShowsPicture = false
        presented = nil
        livePresented = nil
    }

    /// The bar opens the player again, growing out of the bar's picture, with its controls up.
    func expand() {
        guard docked != nil, presented == nil, livePresented == nil else { return }
        Diag.event(.player, "expand", ["film": active != nil])
        barShowsPicture = false
        zoomsFromBar = true
        if let active {
            presented = active
            active.showChrome()
            // A window still up would keep the picture from coming back to the screen. Presented first, so
            // the window's closing is not taken for the end of the film.
            if let window = active.pictureInPicture, window.isActive { window.stop() }
        } else if let live {
            live.showChrome()
            livePresented = live
        }
    }

    /// The full-screen player went away: playback ends unless Picture in Picture carries it, or the
    /// player was minimised and the bar does.
    func dismissed() {
        guard !onGlasses, presented == nil, let model = active, !(model.pictureInPicture?.isActive ?? false) else { return }
        if minimised {
            barShowsPicture = true
            return
        }
        model.close()
        active = nil
    }

    /// The live player's screen went away: the channel stops and the tuner is freed unless the bar plays it.
    func liveDismissed() {
        guard livePresented == nil, let model = live else { return }
        if minimised {
            barShowsPicture = true
            return
        }
        model.close()
        live = nil
    }

    /// The tabs left the screen (sign-out, the server list). The live player's cover and the bar hang from
    /// them, so what they showed ends; a film's full-screen cover hangs from the root and stays.
    func tabsLeft() {
        if let live { endLive(live) }
        if presented == nil, minimised, let active { end(active) }
    }

    func stopAll() {
        active?.close()
        active = nil
        live?.close()
        live = nil
        presented = nil
        livePresented = nil
        minimised = false
        zoomsFromBar = false
        barShowsPicture = false
    }
}

// MARK: Chromecast

extension PlayerModel: CastPlayer {
    func castConnected(_ device: CastDevice) {
        guard !closed else { return }
        Diag.event(.player, "cast.connected", ["model": device.model, "at": time], .notice)
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
        Diag.event(.player, "cast.disconnected", ["at": time], .notice)
        if let castProgress, castProgress.state != .stopped { time = clamp(castProgress.position(at: Self.uptime)) }
        report(.stopped)
        stopStream()
        castDevice = nil
        castReceiverFailed = false
        wantsPlay = false
        isPlaying = false
        showChrome()
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
            Diag.event(.player, "cast.finished")
            castTask?.cancel()
            ended()
        case .failed:
            Diag.event(.player, "cast.failed", ["route": route?.kind.rawValue, "retried": castReceiverFailed], .warning)
            if route?.kind == .directPlay, !castReceiverFailed {
                castReceiverFailed = true
                reroute(handPick: false)
            } else {
                fail("The Chromecast couldn't play this video.")
            }
        case .stopped:
            Diag.event(.player, "cast.stopped", ["at": time], .notice)
            // Stopped on the TV, or another sender cast to it.
            session.cast.disconnect(stopping: false)
        case nil:
            guard progress.state != .stopped else { return }
            if phase == .loading, progress.state != .buffering {
                recovery.reset()
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

    /// The receiver's route, the audio and subtitle chosen by the same rules. The Default Media Receiver draws none
    /// of Plex's subtitles, so only a picture track the viewer picked is burned in; text is not shown.
    private func decideCastRoute(_ device: CastDevice, tracks: MediaTracks, media: PlexMedia, part: PlexPart) {
        let settings = session.settings
        let picked = TrackRules.pick(
            from: tracks, isAnime: titleTags.isAnime, countries: titleTags.countries,
            choices: TrackRules.Choices(audio: handAudio, subtitle: handSubtitle, memory: session.trackMemory(for: item))
        )
        let reason: RouteReason? = castReceiverFailed ? .receiverFailed : settings.directPlay == .disabled ? .directPlayOff : nil
        let route = CastRouteDecider.decide(
            media: media, part: part, tracks: tracks, audio: picked.audio, subtitle: picked.subtitle,
            receiver: CastReceiver(modelName: device.model), limits: RouteLimits(serverReason: reason, quality: quality)
        )
        enhancements = EnhancementState()
        subtitle = picked.subtitle
        treatsAsAnime = picked.isAnime
        self.route = route
        audio = route.audio
        subtitleProblem = nil
        if case .notShown = route.subtitle { subtitleProblem = "Text subtitles aren't shown while casting." }
    }

    /// Hands the receiver the file, or the server's stream of it from the start, with a transient token
    /// in place of the account's; it starts at `target` itself.
    private func startCast(at target: TimeInterval, generation: Int) async {
        guard let route, let part else { return }
        Diag.event(.player, "cast.load", ["at": target, "route": route.kind.rawValue], .notice)
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
        // A seek's target stands in for the position until the receiver reports one.
        if castSeekTarget == nil { checkSkip(at: movie, pending: isBuffering || !isPlaying) }
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

// MARK: Diagnostics

extension PlayerModel {
    /// The stream playing, for the log.
    private var diagStream: String {
        switch stream {
        case .direct: "direct"
        case .remux: "remux"
        case .transcode: "transcode"
        case nil: "none"
        }
    }

    private static func diagPhase(_ phase: Phase) -> String {
        switch phase {
        case .loading: "loading"
        case .playing: "playing"
        case .finished: "finished"
        case .failed: "failed"
        }
    }

    static func diagOffer(_ offer: Offer?) -> String {
        switch offer {
        case .skipIntro(let end)?: "skip-intro to " + DiagFormat.seconds(end, digits: 1)
        case .upNext(let next)?: "up-next " + next.ratingKey
        case .lowerQuality(let quality)?: "lower-quality \(quality)"
        case nil: "none"
        }
    }

    private static func diagAudio(_ track: AudioTrack) -> String {
        "\(track.id) \(track.codec)\(track.channels.map { " \($0)ch" } ?? "") \(track.language.code ?? "und")"
    }

    private static func diagSubtitle(_ track: SubtitleTrack) -> String {
        "\(track.id) \(track.codec) \(track.language.code ?? "und")\(track.isExternal ? " external" : "")\(track.isImageBased ? " image" : "")"
    }

    private static func diagDelivery(_ delivery: SubtitleDelivery) -> String {
        switch delivery {
        case .none: "none"
        case .sidecar(let track): "sidecar " + diagSubtitle(track)
        case .inStream(let track): "in-stream " + diagSubtitle(track)
        case .burnedIn(let track): "burned-in " + diagSubtitle(track)
        case .notShown(let track): "not-shown " + diagSubtitle(track)
        }
    }

    /// "73.5-163.2 chapter, 1290-1420 final", in seconds.
    private static func diagMarkers(_ markers: [PlexMarker]) -> String {
        guard !markers.isEmpty else { return "none" }
        return markers.map { marker in
            let span = DiagFormat.seconds(Double(marker.start) / 1000, digits: 1) + "-" + DiagFormat.seconds(Double(marker.end) / 1000, digits: 1)
            return span + (marker.isFinal ? " final" : "") + (marker.fromChapter ? " chapter" : "")
        }.joined(separator: ", ")
    }

    private func diagItem(_ full: PlexMetadata, media: PlexMedia, part: PlexPart, tracks: MediaTracks, start: TimeInterval) -> [(String, Any?)] {
        var fields: [(String, Any?)] = [("item", full.ratingKey), ("type", full.type.rawValue)]
        if full.type == .episode {
            fields.append(("show", full.grandparentTitle))
            fields.append(("episode", full.episodeCode))
        }
        let size = media.width.flatMap { width in media.height.map { "\(width)x\($0)" } }
        fields += [
            ("title", full.title), ("duration", duration), ("start", start), ("container", media.container),
            ("video", [media.videoCodec, media.videoResolution, media.videoProfile, media.videoFrameRate].compactMap { $0 }.joined(separator: " ")),
            ("size", size), ("kbps", media.bitrate), ("audioTracks", tracks.audio.count), ("subtitleTracks", tracks.subtitles.count),
            ("serverAudio", serverAudio), ("serverSubtitle", serverSubtitle), ("part", part.id),
        ]
        if let vision = part.videoStream?.dolbyVision { fields.append(("dolbyVision", vision.profile)) }
        return fields
    }

    /// The route as decided: how it plays and why, and what it does to the sound and the subtitles.
    private func diagRoute(_ choice: RouteChoice) -> [(String, Any?)] {
        let route = choice.route
        var fields: [(String, Any?)] = [
            ("kind", route.kind.rawValue),
            ("why", route.reasons.isEmpty ? "plays as it is" : route.reasons.map(\.description).joined(separator: "; ")),
            ("audio", route.audio.map(Self.diagAudio) ?? "none"),
            ("audioAction", route.kind == .directPlay ? "file" : route.convertsAudio ? "convert" : "copy"),
            ("subtitle", Self.diagDelivery(route.subtitle)),
            ("subtitleWhy", "\(choice.subtitle.source)"),
        ]
        if route.audioIsStandIn { fields.append(("audioStandIn", true)) }
        if choice.isAnime { fields.append(("anime", true)) }
        if route.reencodesVideo { fields.append(("reencodes", true)) }
        if let kbps = route.maxVideoBitrateKbps { fields.append(("kbps", kbps)) }
        if let resolution = route.videoResolution { fields.append(("resolution", resolution)) }
        if request.download == nil { fields.append(("reach", Self.describe(reach))) }
        if let dataCap { fields.append(("dataCap", "\(dataCap)")) }
        if !route.audioEnhancements.isEmpty { fields.append(("enhancements", "\(route.audioEnhancements)")) }
        if let blocked = choice.enhancements.unavailable { fields.append(("enhancementsBlocked", blocked)) }
        return fields
    }

    /// How the measured link decided the route, for logs and stats for nerds.
    static func describe(_ reach: RouteReach) -> String {
        switch reach {
        case .nearByLink(let kbps): "fast enough, \(kbps) kbps"
        case .unmeasured: "not measured"
        case .relay: "Plex relay"
        case .remoteByLink(let kbps, let needs): "too slow, \(kbps) of \(needs) kbps"
        case .remoteByServer: "held back by the server"
        }
    }

    /// The state a missed intro skip is judged in.
    private func diagSkipState(_ check: SkipCheck, at movie: TimeInterval) -> [(String, Any?)] {
        var fields: [(String, Any?)] = [
            ("at", movie), ("end", check.target), ("retried", check.retried), ("stream", diagStream),
            ("route", route?.kind.rawValue), ("origin", origin), ("itemTime", backend.itemTime), ("playing", isPlaying),
            ("buffering", isBuffering), ("rate", backend.rate), ("standby", standby != nil),
        ]
        if case .remux(let remux) = stream {
            fields.append(("written", remux.progress.mediaSeconds))
            fields.append(("paced", remux.progress.isPaced))
        }
        if let item = backend.player?.currentItem {
            fields.append(("seekable", item.seekableTimeRanges.last.map { range in
                let span = range.timeRangeValue
                return DiagFormat.seconds(span.start.seconds, digits: 1) + "-" + DiagFormat.seconds(span.end.seconds, digits: 1)
            }))
        }
        return fields
    }

    /// A playhead sample every 10 s of movie time, in Detailed logs only.
    private func sample(at movie: TimeInterval) {
        guard Diag.detailed, abs(movie - diagSampleAt) >= 10 else { return }
        diagSampleAt = movie
        var fields: [(String, Any?)] = [
            ("at", movie), ("ahead", backend.bufferedAhead), ("rate", backend.rate), ("stream", diagStream),
            ("estimateKbps", linkEstimateKbps),
        ]
        if case .remux(let remux) = stream { fields.append(("written", remux.progress.mediaSeconds)) }
        if let event = backend.player?.currentItem?.accessLog()?.events.last {
            fields.append(("dropped", event.numberOfDroppedVideoFrames))
            let observed = event.observedBitrate
            if observed.isFinite, observed > 0 { fields.append(("observedKbps", Int(observed / 1000))) }
        }
        Diag.event(.player, "playhead", list: fields, .debug)
    }
}
