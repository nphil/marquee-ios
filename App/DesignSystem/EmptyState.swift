import SwiftUI

/// A screen with nothing to show yet: an SF Symbol, a title and one short line (DESIGN §11),
/// centred on the canvas. Laid out by hand because ContentUnavailableView bolds its title past the
/// type scale's SemiBold.
struct EmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 44

    var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize))
                .foregroundStyle(theme.ink2)
                .padding(.bottom, Space.s1)
                .accessibilityHidden(true)
            Text(title)
                .textRole(.title)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .textRole(.body)
                .foregroundStyle(theme.ink2)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Space.s7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
    }
}
