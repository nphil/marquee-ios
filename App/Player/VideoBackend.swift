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
    /// The playing item reached the time `armSwitch` set: the standby stream is due.
    case switchDue
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

/// Plays one stream for the player model: AVPlayer on a phone, a still frame in the UI tests. For Auto
/// quality's switch (docs/adaptive-playback.md) it can hold a second stream ready beside the playing one.
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
    /// Bytes the playing item has fetched and the time spent fetching them; nil when unknown.
    var transfer: (bytes: Int64, seconds: TimeInterval)? { get }
    /// Seconds of media loaded past the playhead; nil when unknown.
    var bufferedAhead: TimeInterval? { get }
    /// Opens `item` on a second, silent player while the playing one carries on; false when it fails, is
    /// discarded first, or the backend cannot hold a second stream.
    func openStandby(_ item: AVPlayerItem) async -> Bool
    /// Holds the standby at `itemTime`, primed to play; returns its player, or nil when that failed.
    func prerollStandby(at itemTime: TimeInterval) async -> AVPlayer?
    /// Reports `.switchDue` when the playing item reaches `itemTime`.
    func armSwitch(at itemTime: TimeInterval)
    /// Plays the standby in place of the playing stream, which is let go.
    func switchToStandby()
    func discardStandby()
    /// Removes every observer; the backend is not used again.
    func tearDown()
}

extension AVPlayerItem {
    /// Seconds loaded past the playhead.
    var bufferedAhead: TimeInterval {
        let now = currentTime()
        for value in loadedTimeRanges {
            let range = value.timeRangeValue
            if range.containsTime(now) { return max(0, (range.end - now).seconds) }
        }
        return 0
    }
}

@MainActor
final class AVPlayerBackend: VideoBackend {
    /// The player on screen; a switch to the standby replaces it.
    private(set) var avPlayer = AVPlayer()
    var player: AVPlayer? { avPlayer }
    var onEvent: ((BackendEvent) -> Void)?

    private var timeObserver: Any?
    private var switchObserver: Any?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [any NSObjectProtocol] = []
    /// The second, silent player holding the next stream (`openStandby`).
    private var standby: AVPlayer?

    init() {
        avPlayer.allowsExternalPlayback = true
        observePlayer()
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
        if let item { observe(item) }
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

    var transfer: (bytes: Int64, seconds: TimeInterval)? {
        guard let events = avPlayer.currentItem?.accessLog()?.events else { return nil }
        var bytes: Int64 = 0
        var seconds: TimeInterval = 0
        // Each event counts from its own start; negative values are unknown.
        for event in events {
            bytes += max(0, event.numberOfBytesTransferred)
            seconds += max(0, event.transferDuration)
        }
        return (bytes, seconds)
    }

    var bufferedAhead: TimeInterval? { avPlayer.currentItem?.bufferedAhead }

    func openStandby(_ item: AVPlayerItem) async -> Bool {
        discardStandby()
        item.audioTimePitchAlgorithm = .spectral
        let next = AVPlayer(playerItem: item)
        next.isMuted = true
        next.allowsExternalPlayback = true
        standby = next
        // The model discards a standby that misses its preparation deadline.
        while item.status == .unknown {
            try? await Task.sleep(for: .milliseconds(100))
            guard standby === next, !Task.isCancelled else { return false }
        }
        return item.status == .readyToPlay && standby === next
    }

    func prerollStandby(at itemTime: TimeInterval) async -> AVPlayer? {
        guard let next = standby else { return nil }
        let time = CMTime(seconds: max(0, itemTime), preferredTimescale: 600)
        guard await next.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero), standby === next,
              // Preroll raises an exception on a player that is not ready or not paused.
              next.status == .readyToPlay, next.rate == 0
        else { return nil }
        guard await next.preroll(atRate: rate), standby === next else { return nil }
        return next
    }

    func armSwitch(at itemTime: TimeInterval) {
        if let switchObserver { avPlayer.removeTimeObserver(switchObserver) }
        let time = NSValue(time: CMTime(seconds: itemTime, preferredTimescale: 600))
        switchObserver = avPlayer.addBoundaryTimeObserver(forTimes: [time], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.onEvent?(.switchDue) }
        }
    }

    func switchToStandby() {
        guard let next = standby else { return }
        standby = nil
        let old = avPlayer
        // Unobserved first, so the old player's pause does not read as the playback pausing.
        stopObservingPlayer()
        clearItem()
        old.pause()
        old.replaceCurrentItem(with: nil)
        avPlayer = next
        next.defaultRate = rate
        next.isMuted = false
        observePlayer()
        if let item = next.currentItem { observe(item) }
        next.play()
        sizeChanged()
    }

    func discardStandby() {
        if let switchObserver { avPlayer.removeTimeObserver(switchObserver) }
        switchObserver = nil
        standby?.cancelPendingPrerolls()
        standby?.replaceCurrentItem(with: nil)
        standby = nil
    }

    func tearDown() {
        discardStandby()
        avPlayer.pause()
        load(nil)
        stopObservingPlayer()
        onEvent = nil
    }

    private func observePlayer() {
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

    private func stopObservingPlayer() {
        for observer in [timeObserver, switchObserver].compactMap({ $0 }) { avPlayer.removeTimeObserver(observer) }
        timeObserver = nil
        switchObserver = nil
        playerObservations.forEach { $0.invalidate() }
        playerObservations = []
    }

    private func observe(_ item: AVPlayerItem) {
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
