import Foundation

/// What a wait in mid-play waits on, looked at while it lasts. A paced remux once stopped while AVPlayer
/// stopped reloading its playlist, and both waited for good (2026-11-09): a run that does nothing, or a
/// player that sits on what it has, is restarted rather than waited on.
public struct StallWatch: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// The wait is for the link to the server, `seconds` long so far.
        case network(seconds: TimeInterval)
        /// The remux run is stuck: a new run at the playhead plays on. `ahead` is its output past the playhead.
        case stuck(ahead: TimeInterval, cause: Cause)
        /// A run restarted within a second of this playhead left the player stuck here again.
        case giveUp
    }

    public enum Cause: String, Sendable {
        /// The run neither read from its source nor added output for a second.
        case idle
        /// The player waited a second with 30 s of output in hand.
        case unplayed
    }

    /// The remux run feeding the player.
    public struct Run: Sendable {
        /// The end of its output, on the movie's timeline.
        public var produced: TimeInterval
        /// A read from the source is under way, also one waiting for the link to come back.
        public var fetching: Bool

        public init(produced: TimeInterval, fetching: Bool) {
            self.produced = produced
            self.fetching = fetching
        }
    }

    /// How long a run may do nothing, or a player sit on ample output, before it counts as stuck.
    static let patience: TimeInterval = 1
    /// Output past the playhead that a working player plays from: three 10 s segments.
    static let ample: TimeInterval = 30

    private struct Wait {
        var start: TimeInterval
        /// When the run last read or added output, and where its output ended then.
        var active: TimeInterval
        var produced: TimeInterval?
    }

    private var wait: Wait?
    private var lastRestart: TimeInterval?

    public init() {}

    /// - Parameters:
    ///   - now: Seconds on a monotonic clock.
    ///   - position: The playhead, on the movie's timeline.
    ///   - run: The remux run; nil for a stream from the server or the file itself, whose every wait is
    ///     the network's.
    public mutating func check(now: TimeInterval, position: TimeInterval, run: Run?) -> Verdict {
        var wait = self.wait ?? Wait(start: now, active: now, produced: run?.produced)
        if let run, run.fetching || run.produced != wait.produced {
            wait.active = now
            wait.produced = run.produced
        }
        let waited = now - wait.start
        let ahead = run.map { $0.produced - position } ?? 0
        let cause: Cause? = if run == nil {
            nil
        } else if waited >= Self.patience, ahead >= Self.ample {
            .unplayed
        } else if now - wait.active >= Self.patience {
            .idle
        } else {
            nil
        }
        guard let cause else {
            self.wait = wait
            return .network(seconds: waited)
        }
        self.wait = nil
        if let lastRestart, abs(position - lastRestart) < 1 { return .giveUp }
        lastRestart = position
        return .stuck(ahead: ahead, cause: cause)
    }

    /// Playback no longer waits; the next wait counts from its own start. The last restart's place stays.
    public mutating func resume() {
        wait = nil
    }
}
