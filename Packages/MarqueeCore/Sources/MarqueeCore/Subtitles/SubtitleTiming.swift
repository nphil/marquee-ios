import Foundation

/// How far the subtitles are moved from their authored times, for the playing item only.
///
/// A positive offset shows each line later. Every track can be delayed: the player holds lines back.
/// Showing lines earlier needs them before they are due, which only a downloaded file (whose lines are all
/// read up front) has, so a track inside the stream stays at zero or later.
public struct SubtitleTiming: Sendable, Equatable {
    public static let step: TimeInterval = 0.1
    public static let limit: TimeInterval = 60

    /// Tenths of a second, so repeated steps never drift.
    public private(set) var tenths: Int = 0

    public init(seconds: TimeInterval = 0) {
        tenths = Int((seconds / Self.step).rounded())
    }

    public var seconds: TimeInterval { TimeInterval(tenths) * Self.step }
    public var isOriginal: Bool { tenths == 0 }

    /// One step later (`direction` 1) or earlier (-1), kept inside what the track allows.
    public mutating func nudge(_ direction: Int, canGoEarlier: Bool) {
        tenths = Self.clamped(tenths + direction.signum(), canGoEarlier: canGoEarlier)
    }

    /// Keeps the offset inside what a newly chosen track allows.
    public mutating func fit(canGoEarlier: Bool) {
        tenths = Self.clamped(tenths, canGoEarlier: canGoEarlier)
    }

    public mutating func reset() {
        tenths = 0
    }

    public func canNudge(_ direction: Int, canGoEarlier: Bool) -> Bool {
        Self.clamped(tenths + direction.signum(), canGoEarlier: canGoEarlier) != tenths
    }

    /// "0.3 s", "1.5 s", "1 min".
    public var magnitude: String {
        let value = abs(tenths)
        if value >= 600 { return "1 min" }
        return value % 10 == 0 ? "\(value / 10) s" : "\(value / 10).\(value % 10) s"
    }

    private static func clamped(_ tenths: Int, canGoEarlier: Bool) -> Int {
        let bound = Int(limit / step)
        return min(bound, max(canGoEarlier ? -bound : 0, tenths))
    }
}
