import MarqueeCore
import SwiftUI
import UIKit

/// How each record state is drawn (docs/LIVE-TV.md §6.10): its symbol and its role colour.
extension RecordingMark {
    var symbol: String {
        switch self {
        case .scheduled, .series: "record.circle"
        case .recording: "record.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .recorded: "checkmark.circle"
        }
    }

    func color(in theme: Theme) -> Color {
        switch self {
        case .scheduled, .series, .recording: theme.live
        case .failed: theme.danger
        case .recorded: theme.positive
        }
    }

    func uiColor(in theme: Theme) -> UIColor {
        switch self {
        case .scheduled, .series, .recording: theme.roles.live.uiColor
        case .failed: theme.roles.danger.uiColor
        case .recorded: theme.roles.positive.uiColor
        }
    }
}

/// The record state beside a programme. Recording pulses once a second, and holds still under Reduce
/// Motion.
struct RecordGlyph: View {
    let mark: RecordingMark
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: mark.symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(mark.color(in: theme))
            .symbolEffect(.pulse, options: .repeating, isActive: mark == .recording && !reduceMotion)
            .accessibilityHidden(true)
    }
}
