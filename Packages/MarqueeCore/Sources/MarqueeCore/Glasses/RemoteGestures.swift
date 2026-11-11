import Foundation

/// Turns a finger's travel across the phone remote into focus steps.
///
/// The first 12 points pick an axis and lock it, so a diagonal thumb never moves both ways. After that
/// every 52 points across or 70 points down is one step, and sliding back takes steps back. A flick
/// that took no step yet still moves one; a hard flick coasts on (`coast(speed:)`).
public struct SwipeSteps: Sendable {
    public enum Axis: Sendable, Equatable { case horizontal, vertical }

    public static let lockDistance = 12.0
    public static let stepAcross = 52.0
    public static let stepDown = 70.0
    /// Release speed (points a second) above which a short flick still counts as one step.
    public static let flickSpeed = 300.0
    /// Release speed above which the focus keeps moving after the finger lifts.
    public static let coastSpeed = 1000.0
    /// The coast stops once it has slowed below this.
    public static let stopSpeed = 350.0
    /// How much speed each coasting step keeps.
    public static let friction = 0.85
    /// The quickest a coast steps, so every step can still be seen and felt.
    public static let shortestGap: TimeInterval = 0.05
    public static let longestCoast = 40

    public private(set) var axis: Axis?
    /// Steps taken so far along the axis, signed: right and down are positive.
    public private(set) var taken = 0

    public init() {}

    /// The finger is `dx`, `dy` points from where it touched down; returns the steps to take now, in order.
    public mutating func moved(dx: Double, dy: Double) -> [FocusMove] {
        if axis == nil {
            guard max(abs(dx), abs(dy)) >= Self.lockDistance else { return [] }
            axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
        }
        let horizontal = axis == .horizontal
        let travel = horizontal ? dx : dy
        let target = Int(travel / (horizontal ? Self.stepAcross : Self.stepDown))
        var moves: [FocusMove] = []
        while taken != target {
            let forward = target > taken
            taken += forward ? 1 : -1
            moves.append(horizontal ? (forward ? .right : .left) : (forward ? .down : .up))
        }
        return moves
    }

    /// The finger lifted moving at `vx`, `vy` points a second: the one step a short flick earns, and the
    /// direction and speed a hard flick coasts on with.
    public func released(vx: Double, vy: Double) -> (step: FocusMove?, coast: (move: FocusMove, speed: Double)?) {
        let horizontal = axis.map { $0 == .horizontal } ?? (abs(vx) >= abs(vy))
        let speed = horizontal ? vx : vy
        guard abs(speed) >= Self.flickSpeed else { return (nil, nil) }
        let move: FocusMove = horizontal ? (speed > 0 ? .right : .left) : (speed > 0 ? .down : .up)
        // A flick against the steps already taken is the thumb returning, not a new throw.
        if taken != 0, (taken > 0) != (speed > 0) { return (nil, nil) }
        let step = taken == 0 ? move : nil
        let coast = abs(speed) >= Self.coastSpeed ? (move, abs(speed)) : nil
        return (step, coast)
    }

    /// When each coasting step falls, in seconds after the release: quick at first, slowing as it goes.
    public static func coast(speed: Double, step: Double) -> [TimeInterval] {
        guard speed >= coastSpeed, step > 0 else { return [] }
        var times: [TimeInterval] = []
        var current = speed
        var clock: TimeInterval = 0
        while current >= stopSpeed, times.count < longestCoast {
            clock += max(step / current, shortestGap)
            times.append(clock)
            current *= friction
        }
        return times
    }
}

/// Press and hold, then slide: the playhead follows the thumb, the phone's whole width standing for
/// up to ten minutes, and every ten seconds crossed is one detent the remote plays as a click.
public struct Scrub: Sendable {
    public enum Tick: Sendable, Equatable { case none, detent, end }

    public static let detent: TimeInterval = 10
    public static let widestSpan: TimeInterval = 600

    public let origin: TimeInterval
    public let duration: TimeInterval
    /// Seconds the phone's width stands for.
    public let span: TimeInterval
    public private(set) var time: TimeInterval
    private var slide: TimeInterval = 0
    private var nudge: TimeInterval = 0
    private var mark: Int
    private var atEnd = false

    public init(at origin: TimeInterval, duration: TimeInterval) {
        let duration = max(duration, 0)
        self.duration = duration
        self.origin = min(max(origin, 0), duration)
        span = min(duration, Self.widestSpan)
        time = self.origin
        mark = Int((self.origin / Self.detent).rounded(.down))
    }

    /// The thumb has slid `dx` of a `width`-point surface since the hold began.
    public mutating func slid(_ dx: Double, of width: Double) -> Tick {
        guard width > 0 else { return .none }
        slide = dx / width * span
        return settle()
    }

    /// Tilt's fine adjustment, added on top of the thumb's slide.
    public mutating func nudge(by seconds: TimeInterval) -> Tick {
        nudge += seconds
        // Held against an end, tilt stops pushing so tilting back answers at once.
        let reach = origin + slide + nudge
        if reach < 0 { nudge -= reach }
        if reach > duration { nudge -= reach - duration }
        return settle()
    }

    private mutating func settle() -> Tick {
        time = min(max(origin + slide + nudge, 0), duration)
        let ended = time <= 0 || time >= duration
        let next = Int((time / Self.detent).rounded(.down))
        let crossed = next != mark
        mark = next
        defer { atEnd = ended }
        if ended { return atEnd ? .none : .end }
        return crossed ? .detent : .none
    }
}

/// Tilting the phone while the thumb is held keeps things moving: scrolling on a page, fine scrubbing
/// in the player. The angle counts from where the phone was when the thumb went down, and the dead zone
/// keeps a hand's tremor from moving anything. Lifting the thumb stops it.
public struct TiltDrive: Sendable {
    /// About 8 degrees.
    public static let deadZone = 0.14
    /// About 34 degrees: beyond this the rate stays at its top.
    public static let fullTilt = 0.6

    /// Steps or seconds a second at full tilt.
    public let topRate: Double
    private var carry = 0.0

    public init(topRate: Double) {
        self.topRate = topRate
    }

    /// From -1 to 1: zero inside the dead zone, then rising gently so small tilts stay fine.
    public static func level(_ angle: Double) -> Double {
        let reach = abs(angle) - deadZone
        guard reach > 0 else { return 0 }
        let fraction = min(reach / (fullTilt - deadZone), 1)
        return (angle < 0 ? -1 : 1) * fraction * fraction
    }

    /// The amount to move for `seconds` held at `angle`.
    public func amount(at angle: Double, for seconds: TimeInterval) -> Double {
        Self.level(angle) * topRate * max(seconds, 0)
    }

    /// Whole steps due after `seconds` held at `angle`; the remainder waits for the next reading.
    public mutating func steps(at angle: Double, for seconds: TimeInterval) -> Int {
        let level = Self.level(angle)
        guard level != 0 else {
            carry = 0
            return 0
        }
        carry += level * topRate * max(seconds, 0)
        let whole = Int(carry)
        carry -= Double(whole)
        return whole
    }
}
