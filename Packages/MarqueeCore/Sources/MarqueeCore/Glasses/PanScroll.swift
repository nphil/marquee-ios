import Foundation

/// A finger's travel across the remote as a continuous position on the big screen, in focus steps.
///
/// The first 12 points lock an axis; from then on 52 points across or 70 points down is one step of
/// travel. The page shows `travel` as it is, so content follows the finger a fraction of a step at a time,
/// and the focus itself moves once the travel is more than half a step (plus a little hysteresis, so a
/// thumb resting on the boundary does not flicker) past the focused item. `taken` counts the whole steps
/// the focus has made; `fraction` is the rest, which the page draws as an offset.
public struct PanScroll: Sendable, Equatable {
    public enum Axis: Sendable, Equatable { case horizontal, vertical }

    public static let lockDistance = SwipeSteps.lockDistance
    public static let stepAcross = SwipeSteps.stepAcross
    public static let stepDown = SwipeSteps.stepDown
    /// How far past half a step the travel must go to take a step, so the boundary has some width.
    public static let hysteresis = 0.06

    public private(set) var axis: Axis?
    /// Travel along the axis, in steps; right and down are positive.
    public private(set) var travel = 0.0
    /// Whole steps the focus has made along the axis, signed.
    public private(set) var taken = 0
    /// The direction (+1 or -1) in which the focus could not step; the travel stays put there.
    public private(set) var blocked = 0

    public init() {}

    /// Points of finger travel that make one step on `axis`.
    public static func step(_ axis: Axis) -> Double {
        axis == .horizontal ? stepAcross : stepDown
    }

    /// The finger is `dx`, `dy` points from where it touched down, or travel has moved by inertia.
    /// Returns the whole steps to take now, signed; zero until the axis locks.
    public mutating func moved(dx: Double, dy: Double) -> Int {
        if axis == nil {
            guard max(abs(dx), abs(dy)) >= Self.lockDistance else { return 0 }
            axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
        }
        guard let axis else { return 0 }
        return advance(to: (axis == .horizontal ? dx : dy) / Self.step(axis))
    }

    /// Moves the travel to `steps` along the locked axis; the whole steps now due.
    public mutating func advance(to steps: Double) -> Int {
        travel = steps
        let gap = travel - Double(taken)
        let line = 0.5 + Self.hysteresis
        if blocked != 0, (gap > 0) == (blocked > 0), gap != 0 { return 0 }
        blocked = 0
        guard abs(gap) > line else { return 0 }
        // Whole steps past the line, counted from the focus.
        let count = Int((abs(gap) - line).rounded(.down)) + 1
        return gap > 0 ? count : -count
    }

    /// `count` steps were made (fewer than asked when the focus reached an end).
    public mutating func took(_ count: Int) {
        taken += count
    }

    /// The focus could not take a step in `direction` (+1 or -1): the end of the list.
    public mutating func refused(_ direction: Int) {
        blocked = direction > 0 ? 1 : -1
    }

    /// The part of the travel the focus has not yet taken, which the page draws as an offset: zero while the
    /// focus is held against an end.
    public var fraction: Double {
        let gap = travel - Double(taken)
        if blocked != 0, (gap > 0) == (blocked > 0) { return 0 }
        return min(max(gap, -0.5 - Self.hysteresis), 0.5 + Self.hysteresis)
    }

    /// The finger lifted or inertia ended: the steps still due to land on the nearest item.
    public func settling() -> Int {
        guard blocked == 0 else { return 0 }
        return Int(travel.rounded()) - taken
    }
}

/// Motion that slows as `UIScrollView` does: speed falls by 0.2 % every millisecond (its normal
/// deceleration rate of .998), so distance covered is the release speed over about 2.
public struct Coast: Sendable, Equatable {
    /// Speed kept each millisecond.
    public static let rate = 0.998
    /// Steps a second below which the motion has stopped.
    public static let stopSpeed = 0.25
    /// The furthest a throw goes, so one flick cannot cross a whole library.
    public static let longest = 40.0

    /// Where the motion started, in steps, and its release speed, steps a second.
    public let origin: Double
    public let speed: Double
    private static let decay = -1000 * log(rate)

    public init(from origin: Double, speed: Double) {
        self.origin = origin
        let ceiling = Self.longest * Self.decay
        self.speed = min(max(speed, -ceiling), ceiling)
    }

    /// How long until the speed falls below `stopSpeed`.
    public var duration: TimeInterval {
        let fast = abs(speed)
        return fast > Self.stopSpeed ? log(fast / Self.stopSpeed) / Self.decay : 0
    }

    /// Steps travelled `seconds` after the release.
    public func distance(at seconds: TimeInterval) -> Double {
        let time = min(max(seconds, 0), duration)
        return speed * (1 - exp(-Self.decay * time)) / Self.decay
    }

    public func position(at seconds: TimeInterval) -> Double {
        origin + distance(at: seconds)
    }

    /// Steps a second `seconds` after the release.
    public func velocity(at seconds: TimeInterval) -> Double {
        seconds >= duration ? 0 : speed * exp(-Self.decay * max(seconds, 0))
    }

    /// Where the motion comes to rest.
    public var end: Double { position(at: duration) }
}

/// A value that eases to its target without overshooting: critically damped, so a jump of the target
/// settles in about `4 / omega` seconds and a steady drift is followed `2 / omega` seconds behind.
public struct CriticalSpring: Sendable, Equatable {
    public var value: Double
    public var velocity = 0.0

    public init(_ value: Double) {
        self.value = value
    }

    /// Advances by `dt` seconds toward `target`, exactly for any `dt`.
    public mutating func step(toward target: Double, omega: Double, dt: TimeInterval) {
        guard dt > 0 else { return }
        let offset = value - target
        let carry = velocity + omega * offset
        let fade = exp(-omega * dt)
        value = target + (offset + carry * dt) * fade
        velocity = (velocity - carry * omega * dt) * fade
    }

    /// Close enough to rest that the motion can stop.
    public func isSettled(at target: Double, within distance: Double = 0.002) -> Bool {
        abs(value - target) < distance && abs(velocity) < distance * 4
    }
}

/// Where the finger is, guessed a little ahead: the host draws a frame later than the touch happened, and
/// a link adds delay that varies, so it extends the last two readings by the time since the newer one, up
/// to a cap, rather than showing the late reading as it arrived.
public struct FingerTrack: Sendable, Equatable {
    /// The furthest ahead of the newest reading the guess reaches.
    public static let reach: TimeInterval = 0.034
    public static let silence: TimeInterval = 0.08

    private struct Reading: Sendable, Equatable {
        var position: Double
        var time: TimeInterval
    }

    private var latest: Reading?
    private var hasSpeed = false
    /// Steps a second, smoothed over the last few readings.
    public private(set) var speed = 0.0

    public init() {}

    public var position: Double? { latest?.position }

    /// A reading of `position` taken at `time`; readings out of order are dropped.
    public mutating func add(_ position: Double, at time: TimeInterval) {
        if let latest {
            guard time > latest.time else { return }
            let gap = time - latest.time
            // A long pause is a new movement, not a slow one.
            let fresh = gap < 0.1 ? (position - latest.position) / gap : 0
            speed = hasSpeed ? speed * 0.5 + fresh * 0.5 : fresh
            hasSpeed = true
        }
        latest = Reading(position: position, time: time)
    }

    /// The position at `time` (a moment after the newest reading), looking `lead` seconds further on. After
    /// `silence` with no reading the thumb is taken to have stopped, and the newest reading stands.
    public func predicted(at time: TimeInterval, lead: TimeInterval) -> Double? {
        guard let latest else { return nil }
        let age = max(time - latest.time, 0)
        guard age <= Self.silence else { return latest.position }
        return latest.position + speed * min(age + lead, Self.reach)
    }
}

/// The delays from a touch to its effect on the big screen, kept as the last few hundred to read their
/// median and 95th percentile.
public struct LatencyStats: Sendable, Equatable {
    public static let capacity = 240

    private var samples: [Double] = []
    private var next = 0
    public private(set) var count = 0

    public init() {}

    /// A delay in seconds; negative or non-finite ones (a clock that moved) are dropped.
    public mutating func add(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        if samples.count < Self.capacity {
            samples.append(seconds)
        } else {
            samples[next] = seconds
            next = (next + 1) % Self.capacity
        }
        count += 1
    }

    /// The delay `fraction` (0 to 1) of the kept samples were at or under; nil with none.
    public func percentile(_ fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let index = Int((Double(sorted.count - 1) * min(max(fraction, 0), 1)).rounded())
        return sorted[index]
    }

    public var median: Double? { percentile(0.5) }
    public var p95: Double? { percentile(0.95) }

    /// "p50 8 ms · p95 14 ms", or nil with no samples.
    public var summary: String? {
        guard let median, let p95 else { return nil }
        return "p50 \(Int((median * 1000).rounded())) ms · p95 \(Int((p95 * 1000).rounded())) ms"
    }
}

/// How two phones' clocks differ, from a ping and its answer: the controlling phone stamps each input in its
/// own time, and the driving phone reads the stamp in its own. The best (shortest) round trip seen is the
/// one trusted, as the least delayed, and the offset is taken as if both ways took half of it.
public struct ClockOffset: Sendable, Equatable {
    /// The driving phone's clock minus the controlling phone's, seconds; nil until one answer has come.
    public private(set) var offset: Double?
    /// The shortest round trip seen, seconds.
    public private(set) var roundTrip: Double?

    public init() {}

    /// The ping left at `sent` and the answer came back at `received`, both by the controlling phone's clock;
    /// the driving phone read its own clock as `remote` when it answered.
    public mutating func add(sent: Double, remote: Double, received: Double) {
        let trip = received - sent
        guard trip >= 0, trip.isFinite, remote.isFinite else { return }
        // A trip well over the best is a delayed answer, whose midpoint says little; the best itself ages,
        // so a link that got slower is not ignored for good.
        if let best = roundTrip, offset != nil, trip > best * 2 + 0.005 {
            roundTrip = best * 1.05
            return
        }
        roundTrip = min(roundTrip.map { $0 * 1.05 } ?? trip, trip)
        offset = remote - (sent + trip / 2)
    }

    /// A time on the controlling phone's clock as the driving phone's.
    public func hostTime(_ time: Double) -> Double? {
        offset.map { time + $0 }
    }
}
