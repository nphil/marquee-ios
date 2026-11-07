import UIKit
import QuartzCore

/// Shared feedback generators kept warm for low latency (DESIGN §9). Selection ticks are limited to
/// one per 12 ms: a fast drag across steps would otherwise smear into a continuous buzz.
@MainActor
enum Haptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static var lastTick: CFTimeInterval = 0

    /// The picker-style tick for choosing among discrete options (theme tiles, scrub frames, A–Z).
    static func selection() {
        let now = CACurrentMediaTime()
        guard now - lastTick >= 0.012 else { return }
        lastTick = now
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// The server confirmed a change. Never before the confirmation.
    static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    /// A change failed and was rolled back, or an entry was refused.
    static func error() {
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }

    /// Medium for play and pause; light for skips and track picks.
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = style == .medium ? mediumGenerator : lightGenerator
        generator.impactOccurred()
        generator.prepare()
    }
}
