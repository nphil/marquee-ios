import Foundation

/// Two-finger scroll momentum, computed on the phone: the release velocity decays like a UIKit scroll view's.
public struct ScrollMomentum: Sendable {
    /// Points a second.
    public var velocityX: Double
    public var velocityY: Double
    /// UIScrollView's normal deceleration, 0.998 a millisecond.
    public static let decayPerSecond = pow(0.998, 1000.0)
    public static let stopSpeed = 20.0

    public init(velocityX: Double, velocityY: Double) {
        self.velocityX = velocityX
        self.velocityY = velocityY
    }

    /// The movement over `interval`, or nil once it has stopped.
    public mutating func step(interval: Double) -> (dx: Double, dy: Double)? {
        guard (velocityX * velocityX + velocityY * velocityY).squareRoot() > Self.stopSpeed else { return nil }
        let decay = pow(Self.decayPerSecond, interval)
        // The distance travelled while the speed falls from v to v·decay.
        let factor = (decay - 1) / log(Self.decayPerSecond)
        let movement = (velocityX * factor, velocityY * factor)
        velocityX *= decay
        velocityY *= decay
        return movement
    }
}

/// Fingers on the touchpad, turned into pointer actions. Positions are in points, times in seconds,
/// and motion out in TV pixels.
public struct TrackpadTracker: Sendable {
    public enum Output: Equatable, Sendable {
        case move(dx: Double, dy: Double)
        /// Positive scrolls right and down, as the pointer report counts it.
        case scroll(dx: Double, dy: Double)
        case scrolling(Bool)
        case click
        case press
        case release
        case back
        /// Two fingers left the pad still moving: scroll on at this many pixels a second, then stop.
        case fling(dx: Double, dy: Double)
    }

    public static let tapTravel = 10.0
    public static let tapTime = 0.25
    /// A touch this soon after a tap drags once it moves.
    public static let dragWindow = 0.3
    public static let scrollGain = 2.0
    /// Below this release speed, in pixels a second, scrolling just stops.
    public static let flingSpeed = 150.0
    /// Fingers that rested this long before lifting were no longer moving, whatever their last speed.
    public static let restBeforeLift = 0.1

    /// The setting that scales motion, 0.5–2.
    public var speed = 1.0

    private enum Phase: Sendable {
        case idle
        case one
        /// A touch right after a tap: a drag once it moves, another click if it lifts.
        case dragReady
        case dragging
        case two
    }

    private var phase = Phase.idle
    private var startTime = 0.0
    private var lastX = 0.0
    private var lastY = 0.0
    private var lastTime = 0.0
    private var touches = 0
    /// Fingers on the pad at the last update.
    private var fingers = 0
    private var travel = 0.0
    private var lastTap: Double?
    private var velocityX = 0.0
    private var velocityY = 0.0

    public init() {}

    /// Pixels per point: slow strokes are precise, quick ones cross the screen.
    public static func gain(speed pointsPerSecond: Double) -> Double {
        min(4, max(1.2, 1.2 + pointsPerSecond / 500))
    }

    /// The fingers changed: `count` on the pad now, their centre at `x`, `y`.
    public mutating func update(count: Int, x: Double, y: Double, time: Double) -> [Output] {
        switch phase {
        case .idle:
            guard count > 0 else { return [] }
            begin(count: count, x: x, y: y, time: time)
            if count >= 2 {
                phase = .two
                return [.scrolling(true)]
            }
            if let lastTap, time - lastTap <= Self.dragWindow {
                phase = .dragReady
            } else {
                phase = .one
            }
            return []
        case .one, .dragReady, .dragging:
            if count == 0 { return lift(time: time) }
            if count >= 2, phase != .dragging {
                phase = .two
                touches = count
                fingers = count
                anchor(x: x, y: y, time: time)
                return [.scrolling(true)]
            }
            if count != fingers {
                // The centre jumps when a finger joins a drag: carry on from the new one.
                fingers = count
                anchor(x: x, y: y, time: time)
                return []
            }
            return moveOne(x: x, y: y, time: time)
        case .two:
            touches = max(touches, count)
            if count == 0 { return lift(time: time) }
            // A finger joining or leaving moves the centre without scrolling, and one finger left alone
            // waits for the other.
            if count != fingers || count == 1 {
                fingers = count
                anchor(x: x, y: y, time: time)
                return []
            }
            return scrollTwo(x: x, y: y, time: time)
        }
    }

    private mutating func begin(count: Int, x: Double, y: Double, time: Double) {
        startTime = time
        touches = count
        fingers = count
        travel = 0
        velocityX = 0
        velocityY = 0
        anchor(x: x, y: y, time: time)
    }

    private mutating func anchor(x: Double, y: Double, time: Double) {
        lastX = x
        lastY = y
        lastTime = time
    }

    private mutating func moveOne(x: Double, y: Double, time: Double) -> [Output] {
        let dx = x - lastX
        let dy = y - lastY
        let interval = max(time - lastTime, 0.001)
        anchor(x: x, y: y, time: time)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return [] }
        travel += distance
        var outputs: [Output] = []
        if phase == .dragReady, travel > Self.tapTravel {
            phase = .dragging
            lastTap = nil
            outputs.append(.press)
        }
        let gain = Self.gain(speed: distance / interval) * speed
        outputs.append(.move(dx: dx * gain, dy: dy * gain))
        return outputs
    }

    private mutating func scrollTwo(x: Double, y: Double, time: Double) -> [Output] {
        let dx = x - lastX
        let dy = y - lastY
        let interval = max(time - lastTime, 0.001)
        anchor(x: x, y: y, time: time)
        travel += (dx * dx + dy * dy).squareRoot()
        // Content follows the fingers, so scrolling runs against them.
        let scrollX = -dx * Self.scrollGain * speed
        let scrollY = -dy * Self.scrollGain * speed
        // Smoothed over the last few samples, so the release speed is not one jittery sample.
        velocityX = velocityX * 0.5 + scrollX / interval * 0.5
        velocityY = velocityY * 0.5 + scrollY / interval * 0.5
        return scrollX == 0 && scrollY == 0 ? [] : [.scroll(dx: scrollX, dy: scrollY)]
    }

    private mutating func lift(time: Double) -> [Output] {
        let quick = travel <= Self.tapTravel && time - startTime <= Self.tapTime
        let ended = phase
        phase = .idle
        switch ended {
        case .idle:
            return []
        case .one:
            guard quick else { return [] }
            lastTap = time
            return [.click]
        case .dragReady:
            lastTap = nil
            return travel <= Self.tapTravel ? [.click] : []
        case .dragging:
            return [.release]
        case .two:
            lastTap = nil
            if quick, touches >= 2 { return [.scrolling(false), .back] }
            if time - lastTime <= Self.restBeforeLift,
               (velocityX * velocityX + velocityY * velocityY).squareRoot() >= Self.flingSpeed {
                return [.fling(dx: velocityX, dy: velocityY)]
            }
            return [.scrolling(false)]
        }
    }
}
