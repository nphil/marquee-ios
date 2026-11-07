import SwiftUI

/// A screen with nothing to show: an SF Symbol, a title, one short line and at most one action
/// (DESIGN §11), centred on the canvas. Without a symbol it shows a spinner: the screen is waiting.
/// Laid out by hand because ContentUnavailableView bolds its title past the type scale's SemiBold.
struct EmptyState: View {
    struct Action {
        let title: String
        let systemImage: String
        let perform: @MainActor () -> Void
    }

    let title: String
    let message: String
    let systemImage: String?
    var action: Action?

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 44

    var body: some View {
        VStack(spacing: Space.s3) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: iconSize))
                        .foregroundStyle(theme.ink2)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .padding(.bottom, Space.s1)
            .accessibilityHidden(true)
            Text(title)
                .textRole(.title)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .textRole(.body)
                .foregroundStyle(theme.ink2)
            if let action {
                Button(action: action.perform) {
                    Label(action.title, systemImage: action.systemImage)
                }
                .buttonStyle(.pill)
                .padding(.top, Space.s3)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Space.s7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
    }
}
