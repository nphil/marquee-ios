import MarqueeCore
import SwiftUI

/// Video & playback (DESIGN §8.7, behaviour spec §4), saved for the active profile.
struct VideoPlaybackSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                Picker("Skip Gesture", selection: $session.settings.skipTaps) {
                    ForEach(SkipTapMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("video.skipTaps")
            } footer: {
                Text("Skip back and skip forward jump by this much. Double-tap the left or right of the picture to skip. With Double-Tap, a single tap always shows or hides the controls.")
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
            } footer: {
                Text(Self.explanation(of: session.settings.directPlay))
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Picker("Default Aspect", selection: $session.settings.aspect) {
                    ForEach(VideoAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .accessibilityIdentifier("video.aspect")
                Picker("Video Orientation", selection: $session.settings.videoOrientation) {
                    ForEach(VideoOrientation.allCases, id: \.self) { orientation in
                        Text(orientation.title).tag(orientation)
                    }
                }
                .accessibilityIdentifier("video.orientation")
            }
            .listRowBackground(theme.sheet)

            Section {
                if session.settings.directPlay == .force {
                    LabeledContent("Default Quality", value: VideoQuality.original.title)
                        .accessibilityIdentifier("video.quality")
                } else {
                    Picker("Default Quality", selection: $session.settings.quality) {
                        ForEach(QualitySetting.all, id: \.self) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .accessibilityIdentifier("video.quality")
                }
            } footer: {
                Text(session.settings.directPlay == .force
                    ? "Forced Direct Play: original quality."
                    : "Auto plays the original at home and adjusts to the connection away from home. A fixed quality is the highest a video plays at: your Plex server converts larger files to fit. Also in the player's More menu.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Toggle("Play Trailers Automatically", isOn: $session.settings.playsTrailers)
                    .accessibilityIdentifier("video.playsTrailers")
            } footer: {
                Text("After a moment on a title, play its trailer with sound. It waits while Low Power Mode, Reduce Motion or a cellular connection is on, and plays silently over other audio.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Toggle("Play Theme Music", isOn: $session.settings.playsThemeMusic.animation(Motion.spring(reduceMotion: reduceMotion)))
                    .accessibilityIdentifier("video.playsThemeMusic")
                if session.settings.playsThemeMusic {
                    Slider(value: $session.settings.themeMusicVolume, in: 0...1) {
                        Text("Theme Music Volume")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(theme.ink2)
                            .accessibilityHidden(true)
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(theme.ink2)
                            .accessibilityHidden(true)
                    }
                    .accessibilityIdentifier("video.themeMusicVolume")
                }
            } footer: {
                Text("A show's theme plays on its page and its seasons', fading out when the page closes or a video starts. It waits while other audio plays, and Silent mode silences it.")
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
