import MarqueeCore
import SwiftUI

/// Video & playback (DESIGN §8.7, behaviour spec §4), saved for the active profile.
struct VideoPlaybackSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var confirmingForce = false

    var body: some View {
        @Bindable var session = session
        List {
            Section {
                Picker("Skip Interval", selection: $session.settings.skipInterval) {
                    ForEach(ProfileSettings.skipIntervals, id: \.self) { seconds in
                        Text(Self.seconds(seconds)).tag(seconds)
                    }
                }
                .accessibilityIdentifier("video.skipInterval")
            } footer: {
                Text("Skip back and skip forward jump by this much.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Picker("Skip Intro", selection: $session.settings.introSkipDelay) {
                    Text("Manually").tag(0)
                    ForEach(ProfileSettings.countdowns, id: \.self) { seconds in
                        Text("After \(Self.seconds(seconds))").tag(seconds)
                    }
                }
                .accessibilityIdentifier("video.introSkip")
                Picker("Next Episode", selection: $session.settings.nextEpisodeDelay) {
                    Text("Off").tag(0)
                    ForEach(ProfileSettings.countdowns, id: \.self) { seconds in
                        Text("After \(Self.seconds(seconds))").tag(seconds)
                    }
                }
                .accessibilityIdentifier("video.nextEpisode")
            } footer: {
                Text("Countdowns start only at intro and credits markers from Plex.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Picker("Direct Play", selection: directPlay) {
                    ForEach(DirectPlayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("video.directPlay")
                Picker("Default Aspect", selection: $session.settings.aspect) {
                    ForEach(VideoAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .accessibilityIdentifier("video.aspect")
            } footer: {
                Text(Self.explanation(of: session.settings.directPlay))
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                if session.settings.directPlay == .force {
                    LabeledContent("Default Quality", value: VideoQuality.original.title)
                        .accessibilityIdentifier("video.quality")
                } else {
                    Picker("Default Quality", selection: $session.settings.quality) {
                        ForEach(VideoQuality.allCases, id: \.self) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .accessibilityIdentifier("video.quality")
                }
            } footer: {
                Text(session.settings.directPlay == .force
                    ? "Forced Direct Play: original quality."
                    : "The highest quality a video plays at. Larger files are converted by your Plex server to fit. Also available in the player's More menu.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Toggle("Direct from Tuner", isOn: $session.settings.readsTunerDirectly)
                    .accessibilityIdentifier("video.readsTunerDirectly")
            } header: {
                Text("Live TV")
            } footer: {
                Text("At home, channels play straight from the HDHomeRun; away from home, or if that fails, they play through Plex.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Video & Playback")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Force Direct Play?", isPresented: $confirmingForce, titleVisibility: .visible) {
            Button("Force Direct Play") { session.settings.directPlay = .force }
                .accessibilityIdentifier("video.forceConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every file plays as it is, with no conversion by the server to fall back on.")
        }
    }

    /// Force asks first (behaviour spec §4); the other modes apply at once.
    private var directPlay: Binding<DirectPlayMode> {
        Binding {
            session.settings.directPlay
        } set: { mode in
            if mode == .force {
                confirmingForce = true
            } else {
                session.settings.directPlay = mode
            }
        }
    }

    private static func seconds(_ value: Int) -> String {
        "\(value) seconds"
    }

    private static func explanation(of mode: DirectPlayMode) -> String {
        switch mode {
        case .auto: "Files play as they are when the iPhone can, and the server converts the rest."
        case .disabled: "The server converts every file, even ones the iPhone could play as they are."
        case .force: "Every file plays as it is. A file the iPhone can't play fails instead of being converted."
        }
    }
}
