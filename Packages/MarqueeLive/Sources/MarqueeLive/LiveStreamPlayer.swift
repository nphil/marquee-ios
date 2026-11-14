import AVFoundation
import LiveEngine
import Observation
import os
import UIKit

/// Plays a live MPEG-TS stream on a sample-buffer layer. The tuner's slate and the station's first picture go on
/// screen as stills, then motion and sound start together. Opening a URL while another plays is a channel change:
/// the new request goes out first, and the old picture stays until the new stream's first. The stream goes into a
/// timeshift buffer as it comes, so playback can pause and go back within it; the buffer is deleted with the stream.
@MainActor @Observable
public final class LiveStreamPlayer {
    public enum State: Sendable, Equatable {
        case idle
        /// Waiting for the stream's first picture; a stream being replaced stays on screen meanwhile.
        case opening
        /// The tuner's slate is on screen as a still.
        case slate
        /// The station's first picture is on screen as a still.
        case picture
        case playing
        /// Out of data: the last picture stays until the buffer refills.
        case stalled
        case failed(Failure)
    }

    public enum Failure: Sendable, Equatable {
        case refused(TunerRefusal)
        /// Nothing came for 5 s before the first picture.
        case noPicture
        /// The connection broke.
        case lost(String)
        /// The stream cannot be read or its pictures decoded.
        case unreadable(String)
        /// The tuner closed the stream.
        case ended
    }

    public private(set) var state = State.idle
    /// Called after every change of `state`.
    @ObservationIgnored public var onStateChange: ((State) -> Void)?
    /// The tuner's slate stands in for the station after a dropout.
    public private(set) var slateOnScreen = false
    public private(set) var audioTracks: [LiveAudioTrack] = []
    /// The current stream's, refreshed every second while it plays.
    public private(set) var diagnostics = LiveDiagnostics()
    /// The picture and sound hold while the stream goes on into the buffer; the tuner stays in use.
    public private(set) var isPaused = false
    /// Seconds behind live, counting a pause; 0 at live. Refreshed every second.
    public private(set) var behindLive = 0.0
    /// How far back playback can go now, in whole seconds. Refreshed every second.
    public private(set) var reach = 0.0
    /// The sound's own level, 0 to 1, on top of the system volume.
    public var volume: Float {
        get { output.audio.volume }
        set { output.audio.volume = newValue }
    }
    public let view: LiveVideoView
    /// Nil where the device has no Picture in Picture.
    @ObservationIgnored public private(set) var pictureInPicture: LivePictureInPicture?
    @ObservationIgnored public var options = VideoOptions()

    @ObservationIgnored private let output: SampleBufferOutput
    @ObservationIgnored private var pipeline: LivePipeline?
    /// The stream whose events count; every open, close and failure moves it on.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var signposts: Signposts?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var appObservers: AppObservers?
    /// A seek's pipeline has not played yet: the picture before it stays and the state does not move back to opening.
    @ObservationIgnored private var seeking = false
    /// The tune's milestones, kept in the diagnostics after seeks replaced its pipeline.
    @ObservationIgnored private var tuneTimings: LiveTimings?
    @ObservationIgnored private(set) var isInBackground = false
    @ObservationIgnored var isPictureInPictureActive = false {
        didSet { pipeline?.setVideoEnabled(showsVideo) }
    }

    public init() {
        view = LiveVideoView(frame: .zero)
        output = SampleBufferOutput(layer: view.displayLayer)
        pictureInPicture = LivePictureInPicture(player: self)
        let center = NotificationCenter.default
        appObservers = AppObservers([
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setInBackground(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setInBackground(false) }
            },
        ])
    }

    /// Closed, failed or never opened.
    public var isStopped: Bool { pipeline == nil }

    /// Opens the tuner's stream (`…/auto/v<channel>`); while another plays, this is a channel change.
    public func open(_ url: URL) {
        self.url = url
        start(LiveFeed(url: url, buffer: .temporary()), name: url.absoluteString)
    }

    /// Plays bytes the caller writes into `buffer`: a recording, in tests and screenshots.
    public func play(_ buffer: TimeshiftBuffer) {
        url = nil
        start(LiveFeed(buffer: buffer), name: "recording")
    }

    /// Ends the stream, frees the tuner and deletes the buffer; the last picture stays. `resume()` opens the same URL
    /// again.
    public func close() {
        if let pipeline { end(pipeline) }
        move(to: .idle)
        slateOnScreen = false
    }

    /// Holds the picture and sound. The stream goes on into the buffer, so `resume()` plays on from the same picture.
    public func pause() {
        guard let pipeline, !isPaused else { return }
        pipeline.setPaused(true)
        isPaused = true
        LiveLog.line("pause")
        pictureInPicture?.playbackChanged()
    }

    /// Plays on after `pause()`; after `close()` or a failure, opens the last URL again.
    public func resume() {
        guard let pipeline else {
            if let url { open(url) }
            return
        }
        guard isPaused else { return }
        pipeline.setPaused(false)
        isPaused = false
        LiveLog.line("play", ["behind": LiveLog.seconds(pipeline.behindLive)])
        refreshTimeshift()
        pictureInPicture?.playbackChanged()
    }

    /// Plays from `delay` seconds behind live, within what the buffer holds; 0 is live. The picture on screen stays
    /// until the new position's first, and playback goes on from there even if it was paused.
    public func seek(behindLive delay: Double) {
        guard let current = pipeline, state != .opening else { return }
        if tuneTimings == nil { tuneTimings = current.diagnostics.timings }
        start(current.feed, behindLive: max(0, delay), name: "seek", seek: true)
    }

    private func start(_ feed: LiveFeed, behindLive delay: Double = 0, name: String, seek: Bool = false) {
        generation += 1
        let id = generation
        let previous = pipeline
        ticker?.cancel()
        signposts?.abandon()
        signposts = seek ? nil : Signposts(changing: previous != nil)
        let pipeline = LivePipeline(feed: feed, behindLive: delay, output: output, options: options, replacing: previous) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.handle(event, from: id) }
            }
        }
        self.pipeline = pipeline
        pipeline.setVideoEnabled(showsVideo)
        seeking = seek
        isPaused = false
        if seek {
            LiveLog.line("seek", ["behind": LiveLog.seconds(delay)])
        } else {
            move(to: .opening)
            slateOnScreen = false
            audioTracks = []
            diagnostics = LiveDiagnostics()
            tuneTimings = nil
            LiveLog.line("open", ["url": name, "change": previous == nil ? "no" : "yes"])
        }
        pipeline.start()
        refreshTimeshift()
        startTicker()
        pictureInPicture?.playbackChanged()
    }

    /// Stops `pipeline`, keeping its last picture and its diagnostics, and deletes the buffer.
    private func end(_ pipeline: LivePipeline) {
        generation += 1
        ticker?.cancel()
        signposts?.abandon()
        signposts = nil
        diagnostics = snapshot(of: pipeline)
        LiveLog.line("close", ["line": diagnostics.line])
        pipeline.stop()
        self.pipeline = nil
        seeking = false
        tuneTimings = nil
        isPaused = false
        behindLive = 0
        reach = 0
        // The pipeline's output gate is closed once `stop()` returns, so nothing races these.
        output.setRate(0, time: nil)
        output.flush(keepingImage: true)
        pictureInPicture?.playbackChanged()
    }

    private func fail(_ failure: Failure) {
        if let pipeline { end(pipeline) }
        move(to: .failed(failure))
        slateOnScreen = false
    }

    private func move(to new: State) {
        guard new != state else { return }
        state = new
        onStateChange?(new)
    }

    /// The events of the stream on screen; a replaced or closed stream's are dropped.
    func handle(_ event: LivePipeline.Event, from id: Int) {
        guard id == generation else { return }
        let timings = pipeline?.diagnostics.timings ?? LiveTimings()
        switch event {
        case .connected:
            signposts?.connected()
            LiveLog.line("connected", ["after": LiveLog.seconds(timings.response)])
        case .refused(let refusal):
            LiveLog.line("refused", ["status": "\(refusal.status)", "code": refusal.code.map { "\($0)" } ?? "-", "text": refusal.text])
            LiveLog.signposter.emitEvent("refusal", "\(refusal.code ?? refusal.status)")
            fail(.refused(refusal))
        case .noPicture:
            LiveLog.line("failed", ["reason": "no picture in \(Int(LivePipeline.firstPictureTimeout)) s"])
            fail(.noPicture)
        case .lost(let message):
            LiveLog.line("lost", ["reason": message])
            fail(.lost(message))
        case .failed(let message):
            LiveLog.line("failed", ["reason": message])
            fail(.unreadable(message))
        case .ended:
            LiveLog.line("ended")
            fail(.ended)
        case .engine(let event):
            handle(event, timings: timings)
        }
        refreshDiagnostics()
    }

    private func handle(_ event: LiveEvent, timings: LiveTimings) {
        switch event {
        case .phase(let phase):
            if seeking {
                // The picture before the seek stays up until the new position plays.
                guard phase == .playing else { return }
                seeking = false
                LiveLog.line("seeked", ["after": LiveLog.seconds(timings.sound)])
                move(to: .playing)
                return
            }
            let resumed = state == .stalled && phase == .playing
            move(to: State(phase))
            signposts?.reached(phase)
            switch phase {
            case .opening: break
            case .slate: LiveLog.line("slate", ["after": LiveLog.seconds(timings.slate)])
            case .picture: LiveLog.line("picture", ["after": LiveLog.seconds(timings.picture)])
            case .playing: LiveLog.line(resumed ? "resumed" : "sound", ["after": LiveLog.seconds(timings.sound)])
            case .stalled: LiveLog.line("stalled")
            }
        case .slateOnScreen(let on):
            slateOnScreen = on
            LiveLog.line(on ? "slate-in" : "slate-out")
        case .shape(let shape):
            LiveLog.line("shape", ["picture": shape])
            LiveLog.signposter.emitEvent("shape", "\(shape, privacy: .public)")
        case .underrun:
            LiveLog.line("underrun")
            LiveLog.signposter.emitEvent("underrun")
        case .reanchor:
            LiveLog.line("reanchor")
            LiveLog.signposter.emitEvent("reanchor")
        case .servo(let rate):
            LiveLog.line("servo", ["rate": String(format: "%.3f", rate)])
            LiveLog.signposter.emitEvent("servo", "\(rate)")
        case .audioTracks(let tracks):
            audioTracks = tracks
            LiveLog.line("tracks", ["audio": tracks.map { "\($0.id):\($0.codec)/\($0.language ?? "-")" }.joined(separator: ",")])
        case .failed:
            // The pipeline reports these as its own `.failed`.
            break
        }
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshDiagnostics()
                self.refreshTimeshift()
            }
        }
    }

    private func refreshDiagnostics() {
        guard let pipeline else { return }
        let now = snapshot(of: pipeline)
        if now != diagnostics { diagnostics = now }
    }

    /// The pipeline's diagnostics with the tune's milestones, which a seek's pipeline does not have.
    private func snapshot(of pipeline: LivePipeline) -> LiveDiagnostics {
        var now = pipeline.diagnostics
        if let tuneTimings { now.timings = tuneTimings }
        return now
    }

    private func refreshTimeshift() {
        guard let pipeline else { return }
        let behind = pipeline.behindLive
        if behind != behindLive { behindLive = behind }
        let held = pipeline.feed.buffer.reach.rounded(.down)
        if held != reach { reach = held }
    }

    // MARK: Background

    /// In the background without Picture in Picture the sound plays on alone; pictures resume at the next intra
    /// picture on return.
    private var showsVideo: Bool { !isInBackground || isPictureInPictureActive }

    private func setInBackground(_ background: Bool) {
        isInBackground = background
        pipeline?.setVideoEnabled(showsVideo)
    }
}

extension LiveStreamPlayer.State {
    init(_ phase: LivePhase) {
        self = switch phase {
        case .opening: .opening
        case .slate: .slate
        case .picture: .picture
        case .playing: .playing
        case .stalled: .stalled
        }
    }
}

/// The signpost intervals of one tune, each from the request to its milestone (docs/LIVE-TV.md §4.3).
private struct Signposts {
    private let id = LiveLog.signposter.makeSignpostID()
    private var open: OSSignpostIntervalState?
    private var slate: OSSignpostIntervalState?
    private var picture: OSSignpostIntervalState?
    private var sound: OSSignpostIntervalState?
    private var change: OSSignpostIntervalState?

    init(changing: Bool) {
        let signposter = LiveLog.signposter
        open = signposter.beginInterval("live.open", id: id)
        slate = signposter.beginInterval("live.slate", id: id)
        picture = signposter.beginInterval("live.picture", id: id)
        sound = signposter.beginInterval("live.sound", id: id)
        if changing { change = signposter.beginInterval("live.change", id: id) }
    }

    mutating func connected() {
        if let open { LiveLog.signposter.endInterval("live.open", open) }
        open = nil
    }

    mutating func reached(_ phase: LivePhase) {
        let signposter = LiveLog.signposter
        switch phase {
        case .slate:
            if let slate { signposter.endInterval("live.slate", slate) }
            slate = nil
            if let change { signposter.endInterval("live.change", change) }
            change = nil
        case .picture:
            // H.264 and HEVC stations come without a slate.
            if let slate { signposter.endInterval("live.slate", slate, "none") }
            slate = nil
            if let picture { signposter.endInterval("live.picture", picture) }
            picture = nil
            if let change { signposter.endInterval("live.change", change) }
            change = nil
        case .playing:
            if let sound { signposter.endInterval("live.sound", sound) }
            sound = nil
        case .opening, .stalled:
            break
        }
    }

    /// The tune ended or was replaced before reaching every milestone.
    mutating func abandon() {
        let signposter = LiveLog.signposter
        if let open { signposter.endInterval("live.open", open, "abandoned") }
        if let slate { signposter.endInterval("live.slate", slate, "abandoned") }
        if let picture { signposter.endInterval("live.picture", picture, "abandoned") }
        if let sound { signposter.endInterval("live.sound", sound, "abandoned") }
        if let change { signposter.endInterval("live.change", change, "abandoned") }
        self = Signposts()
    }

    private init() {}
}

/// Removes its notification observers when released.
private final class AppObservers {
    private let tokens: [any NSObjectProtocol]

    init(_ tokens: [any NSObjectProtocol]) {
        self.tokens = tokens
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
