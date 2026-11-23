import Foundation

/// The One Euro filter (Casiez, Roussel and Vogel, CHI 2012): heavy smoothing while the pointer creeps,
/// little lag once it moves fast.
public struct OneEuroFilter: Sendable {
    public var minimumCutoff: Double
    public var beta: Double
    public var derivativeCutoff = 1.0
    private var previous: Double?
    private var previousDerivative = 0.0

    public init(minimumCutoff: Double = 1.0, beta: Double = 0.007) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
    }

    public mutating func filter(_ value: Double, interval: Double) -> Double {
        guard let previous, interval > 0 else {
            self.previous = value
            return value
        }
        let derivative = (value - previous) / interval
        previousDerivative += Self.alpha(cutoff: derivativeCutoff, interval: interval) * (derivative - previousDerivative)
        let cutoff = minimumCutoff + beta * abs(previousDerivative)
        let filtered = previous + Self.alpha(cutoff: cutoff, interval: interval) * (value - previous)
        self.previous = filtered
        return filtered
    }

    public mutating func reset() {
        previous = nil
        previousDerivative = 0
    }

    private static func alpha(cutoff: Double, interval: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / interval)
    }
}

/// Air-mouse geometry and gain. Turning about gravity moves the pointer across; tilting about the
/// horizontal axis across the phone moves it up and down, however the phone is rolled.
public enum AirMouseMath {
    /// TV pixels per radian at an ordinary pointing speed.
    public static let gain = 2750.0
    /// Rotation below about this rate counts as hand tremor.
    public static let deadZone = 0.01

    public struct Vector: Sendable {
        public var x, y, z: Double

        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }

        public static func dot(_ a: Vector, _ b: Vector) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

        public var length: Double { Vector.dot(self, self).squareRoot() }

        public func scaled(_ factor: Double) -> Vector { Vector(x: x * factor, y: y * factor, z: z * factor) }

        public func minus(_ other: Vector) -> Vector { Vector(x: x - other.x, y: y - other.y, z: z - other.z) }
    }

    /// Pointer rates in radians a second, right and down positive, from the device-frame rotation rate
    /// and gravity.
    public static func pointerRates(rotation: Vector, gravity: Vector) -> (x: Double, y: Double) {
        let down = gravity.length > 0.1 ? gravity.scaled(1 / gravity.length) : Vector(x: 0, y: 0, z: -1)
        // Turning right is clockwise seen from above: positive about the downward axis.
        let yaw = Vector.dot(rotation, down)
        // The phone's x axis laid flat; tilting the top up is positive about it and moves the pointer up.
        let across = Vector(x: 1, y: 0, z: 0)
        let flat = across.minus(down.scaled(Vector.dot(across, down)))
        let pitch = flat.length > 0.1 ? Vector.dot(rotation, flat.scaled(1 / flat.length)) : rotation.x
        return (soften(yaw), -soften(pitch))
    }

    /// A soft dead zone: half strength at the threshold, untouched well above it.
    public static func soften(_ rate: Double) -> Double {
        let squared = rate * rate
        return rate * squared / (squared + deadZone * deadZone)
    }

    /// Slower turns move less per radian, for precision; faster ones more.
    public static func acceleration(_ speed: Double) -> Double {
        min(1.6, max(0.45, 0.45 + 0.35 * speed))
    }
}
