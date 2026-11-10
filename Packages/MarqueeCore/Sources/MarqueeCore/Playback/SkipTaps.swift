import Foundation

/// Which third of the picture a tap landed in.
public enum TapSide: Sendable, Equatable {
    case back, centre, forward

    public init(x: Double, width: Double) {
        self = x < width / 3 ? .back : x > width * 2 / 3 ? .forward : .centre
    }
}

/// What a tap on the player's picture does with the skip gesture. `doubleTap` skips only on a true
/// double-tap and every single tap shows or hides the controls; `chained` also lets taps that follow a
/// skip on the same side within `chainWindow` skip at once (behaviour spec §4).
public enum SkipTapMode: String, Codable, CaseIterable, Sendable {
    case doubleTap, chained

    public var title: String {
        switch self {
        case .doubleTap: "Double-Tap"
        case .chained: "Double-Tap, Then Keep Tapping"
        }
    }
}

/// Tells taps apart by hand: a pure state machine, so the rule is tested with plain times.
public struct SkipTaps: Sendable {
    public enum Action: Sendable, Equatable {
        /// Skip back or forward by the interval.
        case skip(TapSide)
        /// A double-tap in the middle: fit or fill.
        case toggleAspect
        /// A first tap: show or hide the controls unless a second tap follows within `doubleTapWindow`.
        case single
    }

    /// A second tap within this many seconds of the first, on the same side, is a double-tap.
    public static let doubleTapWindow: TimeInterval = 0.3
    /// After a skip, taps on the same side within this many seconds keep skipping (chained mode only).
    public static let chainWindow: TimeInterval = 1.5

    public var mode: SkipTapMode
    private var lastTap: (at: TimeInterval, side: TapSide)?
    private var chain: (side: TapSide, until: TimeInterval)?

    public init(mode: SkipTapMode) {
        self.mode = mode
    }

    /// `now` is any steady clock in seconds.
    public mutating func tap(_ side: TapSide, at now: TimeInterval) -> Action {
        if mode == .chained, let chain, now < chain.until, chain.side == side, side != .centre {
            lastTap = nil
            self.chain = (side, now + Self.chainWindow)
            return .skip(side)
        }
        if let last = lastTap, now - last.at < Self.doubleTapWindow, last.side == side {
            lastTap = nil
            if side == .centre { return .toggleAspect }
            chain = mode == .chained ? (side, now + Self.chainWindow) : nil
            return .skip(side)
        }
        lastTap = (now, side)
        return .single
    }

    /// Forgets a pending tap and any chain, for a tap that must only bring the controls.
    public mutating func reset() {
        lastTap = nil
        chain = nil
    }
}
