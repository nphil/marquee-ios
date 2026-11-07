import MarqueeCore
import SwiftUI

/// Audio & subtitles (DESIGN §8.7, behaviour spec §3), saved for the active profile.
struct AudioSubtitleSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var session = session
        List {
            Section {
                NavigationLink {
                    LanguagePickerView(title: "Audio Language", noneTitle: "File Default", selection: $session.settings.audioLanguage)
                } label: {
                    LabeledContent("Audio Language") {
                        Text(session.settings.audioLanguage?.name ?? "File Default")
                            .foregroundStyle(theme.ink2)
                    }
                }
                .accessibilityIdentifier("audio.language")
            }
            .listRowBackground(theme.sheet)

            Section {
                Picker("Subtitles", selection: $session.settings.subtitles.defaultMode) {
                    ForEach(SubtitleDefault.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("subtitles.mode")
                NavigationLink {
                    LanguagePickerView(title: "Subtitle Language", noneTitle: nil, selection: subtitleLanguage)
                } label: {
                    LabeledContent("Subtitle Language") {
                        Text(session.settings.subtitles.language.name ?? "")
                            .foregroundStyle(theme.ink2)
                    }
                }
                .accessibilityIdentifier("subtitles.language")
                Toggle("Follow the Audio", isOn: $session.settings.subtitles.followsAudio)
                    .tint(theme.accent)
                    .accessibilityIdentifier("subtitles.followsAudio")
            } footer: {
                Text("Following the audio picks the dub transcript for audio in the subtitle language, and the full translation for any other audio.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Toggle("Remember Choices", isOn: $session.settings.remembersTracks)
                    .tint(theme.accent)
                    .accessibilityIdentifier("tracks.remember")
            } footer: {
                Text("Audio and subtitles picked for a show or movie return next time, for this profile and server.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                NavigationLink("Subtitle Style") {
                    SubtitleStyleView()
                }
                .accessibilityIdentifier("subtitles.style")
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Audio & Subtitles")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The subtitle language is never empty, so the picker offers no "none" row.
    private var subtitleLanguage: Binding<TrackLanguage?> {
        Binding {
            session.settings.subtitles.language
        } set: { language in
            if let language { session.settings.subtitles.language = language }
        }
    }
}

extension SubtitleDefault {
    var title: String {
        switch self {
        case .off: "Off"
        case .foreignAudio: "With Foreign Audio"
        case .always: "Always"
        case .onScreenTextOnly: "On-Screen Text Only"
        }
    }
}
