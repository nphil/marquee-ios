/// Where a live stream plays against live, for pause, skip back and the LIVE button (docs/LIVE-TV.md §6.7).
/// Paused, the stream goes on into a buffer (the phone's on the Direct path, the server's on the Plex path), so the
/// tuner stays in use.
public struct LiveTimeshift: Sendable, Equatable {
    public var isPaused: Bool
    /// Seconds behind live, counting a pause; 0 at live.
    public var behindLive: Double
    /// How far back playback can go now; 0 where the stream cannot go back.
    public var reach: Double

    public init(isPaused: Bool = false, behindLive: Double = 0, reach: Double = 0) {
        self.isPaused = isPaused
        self.behindLive = behindLive
        self.reach = reach
    }

    /// Closer to live than this counts as live: the Plex player's live edge moves a segment at each playlist update.
    public static let liveTolerance = 3.0

    /// The LIVE button and the time behind live show; a paused stream always counts.
    public var isBehindLive: Bool { isPaused || behindLive >= Self.liveTolerance }

    public var canSkipBack: Bool { reach - behindLive >= 1 }

    /// How far behind live a skip of `seconds` lands (negative goes back): within what the buffer holds, and live once
    /// it would land within `liveTolerance` of it.
    public func skipped(by seconds: Double) -> Double {
        let target = min(behindLive - seconds, max(reach, behindLive))
        return target < Self.liveTolerance ? 0 : target
    }

    /// The Plex path's, read from its HLS player: `seekable`, the playlist's range in the player's time; `position`,
    /// the player's time; `liveOffset`, how far behind the range's end the player sits at live.
    public static func hls(seekable: ClosedRange<Double>?, position: Double, liveOffset: Double, isPaused: Bool) -> LiveTimeshift {
        guard let seekable else { return LiveTimeshift(isPaused: isPaused) }
        let live = liveEdge(seekable, liveOffset: liveOffset)
        return LiveTimeshift(
            isPaused: isPaused, behindLive: max(0, live - position), reach: max(0, live - seekable.lowerBound)
        )
    }

    /// The HLS player's time for `behindLive` seconds behind live, within the playlist's range.
    public static func hlsPosition(behindLive: Double, seekable: ClosedRange<Double>, liveOffset: Double) -> Double {
        max(seekable.lowerBound, liveEdge(seekable, liveOffset: liveOffset) - max(0, behindLive))
    }

    private static func liveEdge(_ seekable: ClosedRange<Double>, liveOffset: Double) -> Double {
        max(seekable.lowerBound, seekable.upperBound - max(0, liveOffset))
    }
}

/// Keeps an in-flight seek from resuming playback after a pause or a new stream.
@MainActor public final class LivePlaybackIntent {
    public private(set) var isPaused = false
    private var generation = 0

    public init() {}

    public func pause() { isPaused = true }
    public func resume() { isPaused = false }
    public func reset() {
        generation += 1
        isPaused = false
    }

    @discardableResult
    public func seek(_ operation: @escaping @MainActor () async -> Void, play: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        isPaused = false
        let mine = generation
        return Task {
            await operation()
            guard mine == generation, !isPaused else { return }
            play()
        }
    }
}
