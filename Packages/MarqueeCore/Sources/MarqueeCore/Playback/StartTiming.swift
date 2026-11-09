import Foundation

/// How long one start took to reach each step, from the moment the player began loading the item,
/// for the stats overlay's Start line. A step counts its first arrival only, so a later restart of the
/// stream leaves the start's times as they were.
public struct StartTiming: Sendable {
    public enum Step: String, Sendable, CaseIterable {
        /// The item's full metadata is in.
        case metadata
        /// The play queue is in.
        case queue
        /// The route is decided.
        case route
        /// The stream's address goes to the player.
        case stream
        /// The player can play.
        case ready
        /// The player is at the start point and plays, unless the start is paused.
        case playing
    }

    private let start: ContinuousClock.Instant
    private var marks: [Step: Duration] = [:]
    /// When a remux's playlist went to the player, and why then.
    public var handOff: String?

    public init(start: ContinuousClock.Instant = .now) {
        self.start = start
    }

    public mutating func mark(_ step: Step, at now: ContinuousClock.Instant = .now) {
        guard marks[step] == nil else { return }
        marks[step] = now - start
    }

    /// Milliseconds from the start to `step`, once reached.
    public func milliseconds(_ step: Step) -> Int? {
        marks[step].map { Int(($0 / .milliseconds(1)).rounded()) }
    }

    /// The steps reached, in the order reached: "metadata 12 · route 15 · stream 16 · playing 52 ms".
    public var summary: String {
        let reached = Step.allCases.enumerated()
            .compactMap { order, step in milliseconds(step).map { (step: step, ms: $0, order: order) } }
            .sorted { ($0.ms, $0.order) < ($1.ms, $1.order) }
        guard !reached.isEmpty else { return "–" }
        var text = reached.map { "\($0.step.rawValue) \($0.ms)" }.joined(separator: " · ") + " ms"
        if let handOff { text += " · \(handOff)" }
        return text
    }
}
