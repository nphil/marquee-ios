import AVFoundation
import MarqueeCore
import Observation
import os
import UIKit

/// Live TV through the server (docs/LIVE-TV.md §1.3): Plex tunes the channel and serves HLS, which
/// AVPlayer plays. The server converts MPEG-2 to H.264, so a station takes about 3 s to appear; on a
/// channel change the last picture stays up meanwhile.
///
/// Each tune is one server session that holds a tuner until the stop cancels its grab, and the next
/// tune waits for that: a one-tuner device has nothing to tune with until the old session lets go.
/// Tunes run one after another for the same reason; a tune overtaken by a later one is ended as soon
/// as it returns.
@MainActor @Observable
final class PlexLiveSource: LiveVideoSource {
    private(set) var state: LiveState = .idle
    private(set) var status: String?
    private(set) var diagnosticsLine: String?
    private(set) var timeshift = LiveTimeshift()
    let videoView: UIView

    @ObservationIgnored private let live: PlexLiveTV
    @ObservationIgnored private let backend: any VideoBackend
    /// The AVPlayer's layer; nil for the UI tests' still frame.
    @ObservationIgnored private let layerView: PlayerLayerView?
    /// Bumped by every play, stop and failure; work started under an older value gives way.
    @ObservationIgnored private var generation = 0
    /// The generation whose item the backend holds; events from any other item are dropped.
    @ObservationIgnored private var loaded = -1
    @ObservationIgnored private var current: Stream?
    /// Opens and ends, one at a time.
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var timeline: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var isExternal = false
    @ObservationIgnored private var saidThroughPlex = false
    @ObservationIgnored private let intent = LivePlaybackIntent()
    private var isPaused: Bool { intent.isPaused }

    private static let signposter = OSSignposter(subsystem: "com.nphil.marquee", category: "LiveTV")
    private static let log = Logger(subsystem: "com.nphil.marquee", category: "LiveTV")

    /// One tune and the transcode that reads it.
    private struct Stream {
        let channel: LiveChannel
        let started = ContinuousClock.now
        let playingInterval: OSSignpostIntervalState
        var session: PlexLiveSession?
        var tuned: Duration?
        var playing: Duration?
        var size: CGSize?

        var milliseconds: Int { Int((ContinuousClock.now - started) / .milliseconds(1)) }
    }

    init(live: PlexLiveTV) {
        self.live = live
        #if DEBUG
        if let root = FakePlex.root {
            let still = StillFrameBackend(root: root)
            backend = still
            let image = UIImageView(image: still.image)
            image.contentMode = .scaleAspectFit
            image.backgroundColor = .black
            videoView = image
            layerView = nil
            backend.onEvent = nil
            return
        }
        #endif
        let player = AVPlayerBackend()
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player.player
        backend = player
        layerView = view
        videoView = view
    }

    // MARK: LiveSource

    func play(_ channel: LiveChannel) async {
        generation += 1
        let mine = generation
        backend.onEvent = { [weak self] event in self?.handle(event) }
        // The old picture stays up, silent, until the new one arrives.
        backend.pause()
        timeline?.cancel()
        endTimeshift()
        state = .opening
        diagnosticsLine = nil
        show("Tuning \(channel.number)")
        observeApp()
        let previous = queue
        let work = Task {
            await previous?.value
            await self.open(channel, generation: mine)
        }
        queue = work
        await work.value
    }

    func stop() {
        generation += 1
        backend.pause()
        timeline?.cancel()
        endTimeshift()
        state = .idle
        show(nil)
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
        layerView?.playerLayer.player = backend.player
        endCurrent()
    }

    /// AVPlayer holds the position while the server's HLS window moves on (§6.7); the paused timeline keeps the
    /// session open.
    func pause() {
        guard (loaded == generation || state == .opening), !isPaused else { return }
        intent.pause()
        backend.pause()
        refreshTimeshift()
        Task { await report() }
    }

    func resume() {
        guard (loaded == generation || state == .opening), isPaused else { return }
        intent.resume()
        if loaded == generation { backend.play() }
        refreshTimeshift()
        Task { await report() }
    }

    func seek(behindLive delay: Double) {
        guard loaded == generation else { return }
        guard let item = backend.player?.currentItem, let seekable = Self.seekable(item) else {
            // No window to move in yet: LIVE plays on from the pause.
            resume()
            return
        }
        let target = LiveTimeshift.hlsPosition(behindLive: delay, seekable: seekable, liveOffset: Self.liveOffset(item))
        intent.seek({ [backend] in
            _ = await backend.seek(to: target, precise: false)
        }, play: { [weak self] in
            guard let self else { return }
            self.backend.play()
            self.refreshTimeshift()
        })
    }

    /// Waits until the session a `stop()` let go of has ended on the server. A one-tuner device refuses
    /// any other reader until then.
    func finishEnding() async {
        await queue?.value
    }

    // MARK: Opening

    private func open(_ channel: LiveChannel, generation mine: Int) async {
        if let old = current {
            current = nil
            await Self.finish(old, live: live)
        }
        guard mine == generation else { return }
        let playingInterval = Self.signposter.beginInterval("plex.playing", id: Self.signposter.makeSignpostID())
        var stream = Stream(channel: channel, playingInterval: playingInterval)
        current = stream
        do {
            let tuneInterval = Self.signposter.beginInterval("plex.tune", id: Self.signposter.makeSignpostID())
            let session = try await live.tune(channel)
            Self.signposter.endInterval("plex.tune", tuneInterval)
            stream.session = session
            stream.tuned = ContinuousClock.now - stream.started
            // Recorded before the check, so whichever runs next ends this session.
            current = stream
            guard mine == generation else { return }
            diagnosticsLine = Self.diagnostics(stream)
            let url = try await live.streamURL(TranscodeRequest(live: session))
            guard mine == generation else { return }
            loaded = mine
            backend.load(AVPlayerItem(asset: AVURLAsset(url: url)))
            if !isPaused { backend.play() }
            startTimeline()
        } catch {
            guard mine == generation else { return }
            fail(Self.liveError(error))
        }
    }

    private func handle(_ event: BackendEvent) {
        guard loaded == generation, var stream = current, stream.session != nil else { return }
        switch event {
        case .state(let isPlaying, let isBuffering):
            guard isPlaying else { return }
            if !isBuffering {
                if stream.playing == nil {
                    stream.playing = ContinuousClock.now - stream.started
                    current = stream
                    Self.signposter.endInterval("plex.playing", stream.playingInterval)
                    started(stream)
                }
                state = .playing
            } else if stream.playing != nil {
                state = .stalled
            }
        case .presentationSize(let size):
            stream.size = size
            current = stream
            diagnosticsLine = Self.diagnostics(stream)
        case .failed(let failure):
            fail(.network(failure.text))
        case .ended:
            fail(.server(status: 0, message: "Plex ended the stream."))
        case .externalPlayback(let active):
            isExternal = active
        case .time, .ready, .switchDue:
            break
        }
    }

    /// The first picture: the diagnostics line is complete, and the first time this player plays, the
    /// status label says which way the stream came.
    private func started(_ stream: Stream) {
        let line = Self.diagnostics(stream)
        diagnosticsLine = line
        Self.log.info("\(line, privacy: .public)")
        Task { await self.report() }
        if saidThroughPlex {
            show(nil)
        } else {
            saidThroughPlex = true
            show("Playing through Plex", for: .seconds(4))
        }
    }

    private func fail(_ error: LiveError) {
        generation += 1
        backend.pause()
        timeline?.cancel()
        endTimeshift()
        show(nil)
        state = .failed(error)
        endCurrent()
    }

    /// Ends the current session once the work before it is done; the task holds the source until then,
    /// so closing the player still frees the tuner.
    private func endCurrent() {
        let previous = queue
        queue = Task {
            await previous?.value
            guard let old = self.current else { return }
            self.current = nil
            await Self.finish(old, live: self.live)
        }
    }

    private static func finish(_ stream: Stream, live: PlexLiveTV) async {
        guard let session = stream.session else { return }
        try? await live.reportTimeline(LiveTimelineUpdate(session: session, state: .stopped, time: stream.milliseconds))
        try? await live.stopStream(session)
    }

    // MARK: Timeline

    /// Every second while the stream is open, where it plays against live; every 10 s the timeline, as Plex's own
    /// app reports (§1.3).
    private func startTimeline() {
        timeline?.cancel()
        timeline = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refreshTimeshift()
                ticks += 1
                if ticks.isMultiple(of: 10) { Task { await self.report() } }
            }
        }
    }

    private func report() async {
        guard let stream = current, let session = stream.session else { return }
        let playback: PlaybackState = isPaused ? .paused : state == .playing ? .playing : .buffering
        let update = LiveTimelineUpdate(session: session, state: playback, time: stream.milliseconds)
        try? await live.reportTimeline(update)
    }

    // MARK: Timeshift

    private func refreshTimeshift() {
        var now = LiveTimeshift(isPaused: isPaused)
        if let item = backend.player?.currentItem {
            now = LiveTimeshift.hls(
                seekable: Self.seekable(item), position: item.currentTime().seconds, liveOffset: Self.liveOffset(item),
                isPaused: isPaused
            )
        }
        if now != timeshift { timeshift = now }
    }

    private func endTimeshift() {
        intent.reset()
        timeshift = LiveTimeshift()
    }

    /// The playlist's range in the player's time: the server's window of the stream.
    private static func seekable(_ item: AVPlayerItem) -> ClosedRange<Double>? {
        guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let start = range.start.seconds, end = range.end.seconds
        return start.isFinite && end.isFinite && end >= start ? start...end : nil
    }

    /// How far behind the window's end the player sits at live.
    private static func liveOffset(_ item: AVPlayerItem) -> Double {
        let offset = item.recommendedTimeOffsetFromLive.seconds
        return offset.isFinite ? offset : 0
    }

    // MARK: Status

    private func show(_ text: String?, for duration: Duration? = nil) {
        statusTask?.cancel()
        status = text
        guard let duration else { return }
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            self.status = nil
        }
    }

    // MARK: Background

    /// Without AirPlay the sound plays on alone in the background: a layer showing video would make the
    /// system pause it.
    private func observeApp() {
        guard observers.isEmpty, layerView != nil else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteringForeground() }
            },
        ]
    }

    private func enteredBackground() {
        guard !isExternal else { return }
        layerView?.playerLayer.player = nil
    }

    private func enteringForeground() {
        layerView?.playerLayer.player = backend.player
    }

    // MARK: Words

    static func liveError(_ error: any Error) -> LiveError {
        switch error {
        case let error as LiveError:
            return error
        case PlexError.server(let status, let message):
            return .server(status: status, message: message)
        case PlexError.unauthorized:
            return .server(status: 401, message: "Plex didn't let this profile watch live TV.")
        case PlexError.unreachable(let failure):
            return .network(failure == .offline ? "the phone is offline" : failure == .timedOut ? "Plex took too long to answer" : "Plex can't be reached")
        case PlexError.decoding:
            return .server(status: 200, message: "Plex answered the tune in a way Marquee can't read.")
        default:
            return .network(error.localizedDescription)
        }
    }

    /// "2.1 plex · tune 1.41 s · playing 3.02 s · MPEG-2 480i → H.264 704×480" (§4.3).
    private static func diagnostics(_ stream: Stream) -> String {
        var parts = ["\(stream.channel.number) plex"]
        if let tuned = stream.tuned { parts.append("tune \(seconds(tuned))") }
        if let playing = stream.playing { parts.append("playing \(seconds(playing))") }
        if let session = stream.session { parts.append(video(session, size: stream.size)) }
        return parts.joined(separator: " · ")
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f s", duration / .seconds(1))
    }

    private static func video(_ session: PlexLiveSession, size: CGSize?) -> String {
        let shown = size.map { " \(Int($0.width))×\(Int($0.height))" } ?? ""
        let codec = session.videoCodec?.lowercased() ?? ""
        let name = switch codec {
        case "h264": "H.264"
        case "hevc", "h265": "HEVC"
        case "mpeg2video": "MPEG-2"
        case "": "video"
        default: codec.uppercased()
        }
        if session.phoneDecodesVideo { return name + shown }
        let scan = session.videoHeight.map { " \($0)\(session.isInterlaced ? "i" : "p")" } ?? ""
        return "\(name)\(scan) → H.264\(shown)"
    }
}
