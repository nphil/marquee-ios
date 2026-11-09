import Foundation

/// The receiver's media status, as the Cast SDK reports it.
public struct CastStatus: Sendable, Equatable {
    public enum Player: Sendable, Equatable {
        case idle(IdleReason)
        case loading, buffering, playing, paused, unknown
    }

    public enum IdleReason: Sendable, Equatable {
        case none, finished, cancelled, interrupted, error
    }

    /// The receiver's id for the loaded item; every load gets a higher one.
    public var mediaSessionID: Int
    public var player: Player
    /// Seconds into the item when the status was read.
    public var position: TimeInterval
    public var rate: Double

    public init(mediaSessionID: Int, player: Player, position: TimeInterval, rate: Double = 1) {
        self.mediaSessionID = mediaSessionID
        self.player = player
        self.position = position
        self.rate = rate
    }
}

/// Follows one load on a receiver: where the item is between status updates, the state Plex's timeline
/// gets, and how the item ended. The receiver reports on changes and every few seconds, so while playing
/// the position runs on from the last report at its rate.
public struct CastProgress: Sendable {
    public enum End: Sendable, Equatable {
        /// Played to the end.
        case finished
        /// The receiver could not play it.
        case failed
        /// Stopped from elsewhere: the receiver's remote, or another sender's load.
        case stopped
    }

    public private(set) var state: PlaybackState = .buffering
    /// The item this load replaced, whose last statuses still arrive for a moment and end idle.
    private let replaced: Int?
    private var anchor: TimeInterval
    private var anchorTime: TimeInterval
    private var rate: Double = 0

    /// A load starting at `position`, made while the receiver held `replaced`; `now` is a monotonic
    /// clock in seconds.
    public init(startingAt position: TimeInterval, replacing replaced: Int?, now: TimeInterval) {
        self.replaced = replaced
        anchor = position
        anchorTime = now
    }

    /// The position at `now`.
    public func position(at now: TimeInterval) -> TimeInterval {
        state == .playing ? anchor + max(0, now - anchorTime) * rate : anchor
    }

    /// Takes in a status read at `now`; returns how the item ended, once it has.
    public mutating func update(_ status: CastStatus, now: TimeInterval) -> End? {
        if let replaced, status.mediaSessionID <= replaced { return nil }
        let next: PlaybackState
        switch status.player {
        case .playing: next = .playing
        case .paused: next = .paused
        case .loading, .buffering: next = .buffering
        case .unknown, .idle(.none): return nil
        case .idle(let reason):
            anchor = position(at: now)
            anchorTime = now
            state = .stopped
            switch reason {
            case .finished: return .finished
            case .error: return .failed
            case .none, .cancelled, .interrupted: return .stopped
            }
        }
        anchor = status.position
        anchorTime = now
        rate = status.rate
        state = next
        return nil
    }
}
