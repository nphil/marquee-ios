import MarqueeCore
import SwiftUI

/// What Play and Resume show until the player is built: an honest note, never a fake player.
struct PlaybackNoticeView: View {
    let item: PlexMetadata

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: Space.s4) {
                Image(systemName: "play.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(theme.ink2)
                    .accessibilityHidden(true)
                Text(item.title)
                    .textRole(.title)
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.center)
                Text("Playback arrives in the next build.")
                    .textRole(.body)
                    .foregroundStyle(theme.ink2)
                    .multilineTextAlignment(.center)
                Button {
                    dismiss()
                } label: {
                    Text("OK").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill)
                .accessibilityIdentifier("playbackNotice.ok")
            }
            .padding(Space.s6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("playbackNotice")
    }
}
