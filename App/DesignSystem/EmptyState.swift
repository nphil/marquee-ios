import SwiftUI

/// A screen with nothing to show yet: an SF Symbol, a title and one short line (DESIGN §11),
/// centred on the canvas.
struct EmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title).textRole(.title)
            } icon: {
                Image(systemName: systemImage)
            }
        } description: {
            Text(message).textRole(.body)
        }
        .foregroundStyle(theme.ink, theme.ink2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
    }
}
