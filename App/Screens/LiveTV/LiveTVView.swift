import SwiftUI

/// The Live TV tab. The guide and channels arrive in a later build; until then the tab says so.
struct LiveTVView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        EmptyState(
            title: "Live TV is on its way",
            message: "Channels and the guide arrive in a later build.",
            systemImage: "antenna.radiowaves.left.and.right"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .navigationTitle("Live TV")
        .accessibilityIdentifier("livetv.placeholder")
    }
}
