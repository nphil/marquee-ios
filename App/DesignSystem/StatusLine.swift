import SwiftUI

/// One line of outcome under a control: a symbol in its role's colour, then the words, which carry the
/// meaning on their own.
struct StatusLine: View {
    let symbol: String
    let tint: Color
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(theme.ink)
        }
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
    }
}

struct ProblemLine: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        StatusLine(symbol: "exclamationmark.circle.fill", tint: theme.danger, text: text)
    }
}
