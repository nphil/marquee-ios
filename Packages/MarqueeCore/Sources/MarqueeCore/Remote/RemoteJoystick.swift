import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum DpadKey: Sendable { case up, down, left, right, ok }

/// Turns a thumb's deflection into arrow steps, paced to what the TV's focus navigation lets through: its own
/// held-key repeat waits 300 ms, then allows a step every 100 ms. Light deflection crawls at `slow` per step and
/// full deflection runs at `fast`; the rate between follows an exponential curve so each part of the travel feels
/// evenly faster. The caller supplies the clock and gets back at most one step per call, so a stalled frame never
/// bursts.
public struct JoystickRepeater: Sendable {
    /// The arrow the stick is leaning on, for lighting it; nil while the stick rests.
    public private(set) var held: DpadKey?
    private var since: TimeInterval = 0
    private var last: TimeInterval = 0
    private var phase: CGFloat = 0
    private var repeating = false

    public init() {}

    public static let deadIn: CGFloat = 0.22
    public static let deadOut: CGFloat = 0.14
    public static let lead: CGFloat = 1.25
    public static let quickAt: CGFloat = 0.6
    public static let maxCarry: CGFloat = 0.5
    public static let slow: TimeInterval = 0.36
    public static let fast: TimeInterval = 0.08
    public static let holdOff: TimeInterval = 0.3
    public static let quickHoldOff: TimeInterval = 0.14

    /// `dx` and `dy` are the deflection, each in -1...1 with the stick's reach as the unit. Returns the step to
    /// send, if one is due.
    public mutating func update(now: TimeInterval, dx: CGFloat, dy: CGFloat) -> DpadKey? {
        let magnitude = hypot(dx, dy)
        guard let current = held else {
            if magnitude < Self.deadIn { return nil }
            return begin(now: now, dx: dx, dy: dy)
        }
        if magnitude < Self.deadOut {
            release()
            return nil
        }
        if switches(from: current, dx: dx, dy: dy) { return begin(now: now, dx: dx, dy: dy) }
        let elapsed = now - last
        last = now
        let strength = Self.strength(magnitude)
        if !repeating {
            if now - since < (strength >= Self.quickAt ? Self.quickHoldOff : Self.holdOff) { return nil }
            repeating = true
            phase = 0
            return current
        }
        phase += CGFloat(elapsed / Self.period(strength: strength))
        if phase < 1 { return nil }
        // The wait already served carries over, up to half a period, so a stalled frame is not followed by a burst.
        phase = min(phase - 1, Self.maxCarry)
        return current
    }

    public mutating func release() {
        held = nil
        repeating = false
        phase = 0
    }

    private mutating func begin(now: TimeInterval, dx: CGFloat, dy: CGFloat) -> DpadKey {
        let key = Self.dominant(dx: dx, dy: dy)
        held = key
        since = now
        last = now
        repeating = false
        phase = 0
        return key
    }

    /// Another axis must lead by `lead` before the stick changes direction, so a wobble across the diagonal stays put.
    private func switches(from current: DpadKey, dx: CGFloat, dy: CGFloat) -> Bool {
        let candidate = Self.dominant(dx: dx, dy: dy)
        if candidate == current { return false }
        func horizontal(_ key: DpadKey) -> Bool { key == .left || key == .right }
        if horizontal(current) == horizontal(candidate) { return true }
        return horizontal(candidate) ? abs(dx) >= Self.lead * abs(dy) : abs(dy) >= Self.lead * abs(dx)
    }

    public static func dominant(dx: CGFloat, dy: CGFloat) -> DpadKey {
        if abs(dx) >= abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    /// 0 at the edge of the dead zone, 1 at full reach.
    public static func strength(_ magnitude: CGFloat) -> CGFloat {
        min(max((magnitude - deadIn) / (1 - deadIn), 0), 1)
    }

    /// Seconds between steps at `strength`.
    public static func period(strength: CGFloat) -> TimeInterval {
        slow * pow(fast / slow, Double(strength))
    }
}

/// The D-pad disc's proportions and the joystick's reach, as shares of the disc's radius.
public enum DpadGeometry {
    /// The OK button's share of the disc.
    public static let okRadius: CGFloat = 0.42
    /// How far past the rim a touch still counts, so a thumb at the edge is not lost.
    public static let discSlack: CGFloat = 1.1
    public static let stickReach: CGFloat = 0.62
    public static let knobRadius: CGFloat = 0.26
}

/// The key a touch at `point`, in points from the disc's centre, lands on: OK in the middle, otherwise the arrow it
/// leans toward. Nil off the disc.
public func dpadKey(at point: CGPoint, radius: CGFloat) -> DpadKey? {
    let distance = hypot(point.x, point.y)
    if distance > radius * DpadGeometry.discSlack { return nil }
    if distance <= radius * DpadGeometry.okRadius { return .ok }
    return JoystickRepeater.dominant(dx: point.x, dy: point.y)
}

/// The stick's deflection for a thumb `thumb` points from the centre, with `reach` points as full deflection; its
/// length never passes 1.
public func stickDeflection(thumb: CGPoint, reach: CGFloat) -> CGPoint {
    guard reach > 0 else { return .zero }
    let scaled = CGPoint(x: thumb.x / reach, y: thumb.y / reach)
    let length = hypot(scaled.x, scaled.y)
    return length > 1 ? CGPoint(x: scaled.x / length, y: scaled.y / length) : scaled
}
