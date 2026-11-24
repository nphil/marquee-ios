import Foundation

/// When a LumaTV stream ends under a viewer who did not change the channel (the converter steps aside, the TV
/// restarts it), the app reopens the same channel, at most `limit` times in `window` seconds. A reopen that ends again
/// within `quick` seconds is followed by one more without the conversion; after the limit playback stops.
public struct TunerReopen: Sendable {
    public static let limit = 2
    public static let window: TimeInterval = 60
    public static let quick: TimeInterval = 5

    public struct Decision: Equatable, Sendable {
        public var reopen: Bool
        /// The reopen's number within the window, 1-based.
        public var n: Int
        public var withoutTranscode: Bool
    }

    private var reopened: [TimeInterval] = []

    public init() {}

    /// The stream ended at `now` (monotonic seconds).
    public mutating func ended(at now: TimeInterval) -> Decision {
        reopened.removeAll { now - $0 > Self.window }
        guard reopened.count < Self.limit else { return Decision(reopen: false, n: reopened.count, withoutTranscode: false) }
        let endedQuickly = reopened.last.map { now - $0 <= Self.quick } ?? false
        reopened.append(now)
        return Decision(reopen: true, n: reopened.count, withoutTranscode: reopened.count == 2 && endedQuickly)
    }
}
