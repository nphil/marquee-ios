/// How deep the jitter buffer aims to be: 0.30 s to start, ×1.5 at every underrun up to 1.5 s, 10 % less for each
/// minute without one, back to 0.30 s (SiliconDust's client rules, https://info.hdhomerun.com/info/http_api).
public struct JitterTarget: Sendable, Equatable {
    public static let floor = 0.30
    public static let ceiling = 1.5

    public private(set) var seconds = JitterTarget.floor
    /// When the target last grew or shrank, in monotonic seconds.
    private var changedAt: Double?

    public init() {}

    public mutating func underrun(at now: Double) {
        seconds = min(Self.ceiling, seconds * 1.5)
        changedAt = now
    }

    /// Shrinks the target once a minute without underruns.
    public mutating func update(at now: Double) {
        guard let changedAt else {
            self.changedAt = now
            return
        }
        guard now - changedAt >= 60 else { return }
        seconds = max(Self.floor, seconds * 0.9)
        self.changedAt = now
    }
}

/// The playback rate that brings the buffer's depth to the target: within ±0.5 % while the error is under 0.5 s,
/// within ±2 % beyond it. The audio renderer's time-pitch algorithm keeps voices natural at these rates.
public struct ClockServo: Sendable, Equatable {
    /// More than this far off is not steered back: the player drops to the newest picture instead.
    public static let reanchorError = 2.0

    public private(set) var rate = 1.0
    /// The buffer's depth, smoothed over about a second of 0.1 s updates.
    public private(set) var buffered: Double?

    public init() {}

    public enum Decision: Equatable, Sendable {
        case keep
        case rate(Double)
        case reanchor
    }

    /// Takes one measurement of the buffer's depth; returns a new rate only when it differs by 0.1 % or more,
    /// so the renderer is not retimed for noise.
    public mutating func update(buffered sample: Double, target: Double) -> Decision {
        let smoothed = buffered.map { $0 + 0.1 * (sample - $0) } ?? sample
        buffered = smoothed
        let error = smoothed - target
        if abs(error) > Self.reanchorError { return .reanchor }
        let wanted = abs(error) <= 0.5 ? 1 + min(max(error * 0.01, -0.005), 0.005) : 1 + min(max(error * 0.04, -0.02), 0.02)
        guard abs(wanted - rate) >= 0.001 else { return .keep }
        rate = wanted
        return .rate(wanted)
    }

    /// Starts again from rate 1 with no history, after an underrun or a new anchor.
    public mutating func reset() {
        rate = 1
        buffered = nil
    }
}
