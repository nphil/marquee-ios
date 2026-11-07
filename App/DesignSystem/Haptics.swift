import UIKit
import QuartzCore

/// Shared feedback generators kept warm for low latency (DESIGN §9). Selection ticks are limited to
/// one per 12 ms: a fast drag across steps would otherwise smear into a continuous buzz.
@MainActor
enum Haptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static var lastTick: CFTimeInterval = 0

    /// The picker-style tick for choosing among discrete options (theme tiles, scrub frames, A–Z).
    static func selection() {
        let now = CACurrentMediaTime()
        guard now - lastTick >= 0.012 else { return }
        lastTick = now
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }
}
