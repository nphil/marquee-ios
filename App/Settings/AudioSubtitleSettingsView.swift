import MarqueeCore
import SwiftUI

/// Audio & subtitles (DESIGN §8.7, behaviour spec §3). One set of rules picks the tracks for every profile,
/// so the one setting here is how the subtitles look.
struct AudioSubtitleSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SubtitleStyleView()
                } label: {
                    let look = session.settings.subtitleStyle
                    LabeledContent("Subtitle Style") {
                        Text(look.isCustom ? "Custom" : look.preset.title)
                            .foregroundStyle(theme.ink2)
                    }
                }
                .accessibilityIdentifier("subtitles.style")
            } footer: {
                Text("English subtitles are on by default. Anime plays the English dub with its own subtitles; everything else keeps its original audio. A choice made in the player's Audio and subtitles menu is remembered for that show or movie.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Audio & Subtitles")
        .navigationBarTitleDisplayMode(.inline)
    }
}
