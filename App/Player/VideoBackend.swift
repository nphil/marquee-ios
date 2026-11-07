import AVFoundation
import UIKit

/// What a backend reports to the player model.
enum BackendEvent {
    /// Ten times a second while playing, and after each seek; seconds on the item's timeline.
    case time(TimeInterval)
    case state(isPlaying: Bool, isBuffering: Bool)
    case ready
    case failed(PlaybackFailure)
    case ended
    case externalPlayback(Bool)
    /// The picture's size in pixels, adjusted for its pixel aspect.
    case presentationSize(CGSize)
}

/// Why a stream stopped: plain words for the screen, and the error's domain, code and AVPlayer's comment
/// for stats and Playback info, which say more than the words when a stream will not open.
struct PlaybackFailure: Equatable {
    let text: String
    let detail: String

    init(text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail ?? text
    }

    init(_ error: NSError?, comment: String? = nil) {
        guard let error else {
            self.init(text: "The player stopped without saying why.")
            return
        }
        let cause = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        var detail = "\(error.localizedDescription) (\(cause.domain) \(cause.code))"
        if let comment, !comment.isEmpty { detail += " " + comment }
        self.init(text: error.localizedDescription, detail: detail)
    }
}

/// Plays one stream for the player model: AVPlayer on a phone, a still frame in the UI tests.
@MainActor
protocol VideoBackend: AnyObject {
    /// The player behind the picture, Picture in Picture and AirPlay; nil for the still frame.
    var player: AVPlayer? { get }
    var onEvent: ((BackendEvent) -> Void)? { get set }
    var itemTime: TimeInterval { get }
    /// The loaded item's length once known; a server stream started at an offset may be shorter than
    /// the movie.
    var itemDuration: TimeInterval? { get }
    /// Replaces the stream; nil unloads it.
    func load(_ item: AVPlayerItem?)
    /// Playback speed, 1 for normal. Kept across loads, pauses and seeks.
    var rate: Float { get set }
    func play()
    func pause()
    func seek(to itemTime: TimeInterval, precise: Bool) async -> Bool
    /// Removes every observer; the backend is not used again.
    func tearDown()
}

@MainActor
final class AVPlayerBackend: VideoBackend {
    let avPlayer = AVPlayer()
    var player: AVPlayer? { avPlayer }
    var onEvent: ((BackendEvent) -> Void)?

    private var timeObserver: Any?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [any NSObjectProtocol] = []

    init() {
        avPlayer.allowsExternalPlayback = true
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.onEvent?(.time(seconds.isFinite ? seconds : 0)) }
        }
        playerObservations = [
            avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.stateChanged() }
            },
            avPlayer.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.externalChanged() }
            },
        ]
    }

    var itemTime: TimeInterval {
        let seconds = avPlayer.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var itemDuration: TimeInterval? {
        guard let seconds = avPlayer.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    var rate: Float = 1 {
        didSet {
            // `play()` starts at the default rate; a playing stream changes at once.
            avPlayer.defaultRate = rate
            if avPlayer.timeControlStatus != .paused { avPlayer.rate = rate }
        }
    }

    func load(_ item: AVPlayerItem?) {
        clearItem()
        // Keeps voices at their pitch away from normal speed.
        item?.audioTimePitchAlgorithm = .spectral
        avPlayer.replaceCurrentItem(with: item)
        guard let item else { return }
        itemObservations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.statusChanged() }
            },
            item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.sizeChanged() }
            },
        ]
        let center = NotificationCenter.default
        itemNotifications = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.ended) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let failure = PlaybackFailure(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
                MainActor.assumeIsolated { self?.onEvent?(.failed(failure)) }
            },
        ]
    }

    func play() {
        avPlayer.play()
    }

    func pause() {
        avPlayer.pause()
    }

    func seek(to itemTime: TimeInterval, precise: Bool) async -> Bool {
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        return await avPlayer.seek(
            to: CMTime(seconds: max(0, itemTime), preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    func tearDown() {
        avPlayer.pause()
        load(nil)
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playerObservations.forEach { $0.invalidate() }
        playerObservations = []
        onEvent = nil
    }

    private func clearItem() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations = []
        for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
        itemNotifications = []
    }

    private func stateChanged() {
        let status = avPlayer.timeControlStatus
        onEvent?(.state(isPlaying: status != .paused, isBuffering: status == .waitingToPlayAtSpecifiedRate))
    }

    private func externalChanged() {
        onEvent?(.externalPlayback(avPlayer.isExternalPlaybackActive))
    }

    private func statusChanged() {
        guard let item = avPlayer.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            onEvent?(.ready)
        case .failed:
            onEvent?(.failed(PlaybackFailure(item.error as NSError?, comment: item.errorLog()?.events.last?.errorComment)))
        default:
            break
        }
    }

    private func sizeChanged() {
        guard let size = avPlayer.currentItem?.presentationSize, size.width > 0 else { return }
        onEvent?(.presentationSize(size))
    }
}
