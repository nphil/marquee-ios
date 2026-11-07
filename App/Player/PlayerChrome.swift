import AVKit
import MarqueeCore
import SwiftUI

/// The controls over the picture (DESIGN §8.6): close, title, AirPlay and Picture in Picture on top; the
/// transport in the middle; the scrubber, queue buttons and menus at the bottom. While the finger is
/// on the scrubber everything but the scrubber fades, so the preview has the picture to itself.
struct PlayerChrome: View {
    let model: PlayerModel
    let frames: TrickplayFrames
    let close: () -> Void
    /// The bottom controls' frame on screen.
    let bottomChanged: (CGRect) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .opacity(model.isScrubbing ? 0 : 1)
            Spacer(minLength: Space.s3)
            centre
                .opacity(model.isScrubbing ? 0 : 1)
            Spacer(minLength: Space.s3)
            bottom
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    bottomChanged(frame)
                }
        }
        .padding(.horizontal, Space.inset)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s2)
        .background {
            Scrims()
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.18), value: model.isScrubbing)
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: Space.s3) {
            Button(action: close) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(PlayerButtonStyle())
            .accessibilityLabel("Close player")
            .accessibilityIdentifier("player.close")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                if let line = model.subtitleLine {
                    Text(line)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.5) {
                Haptics.impact(.light)
                model.showsStats.toggle()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityAction(named: model.showsStats ? "Hide stats for nerds" : "Show stats for nerds") {
                model.showsStats.toggle()
            }

            AirPlayButton()
            if model.canPictureInPicture {
                Button {
                    model.togglePictureInPicture()
                } label: {
                    Image(systemName: "pip.enter")
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel("Picture in Picture")
                .accessibilityIdentifier("player.pip")
            }
        }
    }

    // MARK: Centre

    @ViewBuilder
    private var centre: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: Space.s3) {
                LoadingArc()
                Text(model.showsStage ? model.stageText : " ")
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
                    .animation(.easeOut(duration: 0.12), value: model.showsStage)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
            .accessibilityValue(model.showsStage ? model.stageText : "")
        case .failed(let message):
            FailureCard(message: message, close: close, retry: model.retry)
        case .finished:
            FinishedCard(model: model, close: close)
        case .playing:
            transport
        }
    }

    private var transport: some View {
        let seconds = Int(model.skipInterval)
        return HStack(spacing: Space.s8) {
            Button {
                Haptics.impact(.light)
                model.skip(by: -model.skipInterval)
            } label: {
                Image(systemName: "gobackward.\(seconds)")
            }
            .buttonStyle(PlayerButtonStyle())
            .accessibilityLabel("Skip back \(seconds) seconds")
            .accessibilityIdentifier("player.skipBack")

            Button {
                Haptics.impact(.medium)
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PlayerButtonStyle(prominent: true))
            .overlay {
                if model.isWaiting {
                    LoadingArc(diameter: 68)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("player.playPause")

            Button {
                Haptics.impact(.light)
                model.skip(by: model.skipInterval)
            } label: {
                Image(systemName: "goforward.\(seconds)")
            }
            .buttonStyle(PlayerButtonStyle())
            .accessibilityLabel("Skip forward \(seconds) seconds")
            .accessibilityIdentifier("player.skipForward")
        }
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottom: some View {
        switch model.phase {
        case .playing, .finished:
            VStack(spacing: Space.s1) {
                Scrubber(model: model, frames: frames)
                HStack(spacing: Space.s3) {
                    queueButtons
                    Spacer(minLength: 0)
                    TracksMenu(model: model)
                        .opacity(model.isScrubbing ? 0 : 1)
                    MoreMenu(model: model)
                        .opacity(model.isScrubbing ? 0 : 1)
                }
            }
        case .loading, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var queueButtons: some View {
        Group {
            Button {
                Haptics.impact(.light)
                model.previous()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(PlayerButtonStyle())
            .disabled(!model.canGoBack)
            .accessibilityLabel(model.time >= 5 || !model.hasPreviousItem ? "Restart" : "Previous episode")
            .accessibilityIdentifier("player.previous")

            Button {
                Haptics.impact(.light)
                model.next()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(PlayerButtonStyle())
            .disabled(!model.hasNext)
            .accessibilityLabel("Next episode")
            .accessibilityIdentifier("player.next")

            if model.isEpisode {
                Button {
                    model.showsEpisodes = true
                } label: {
                    Image(systemName: "rectangle.stack")
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel("Episodes")
                .accessibilityIdentifier("player.episodes")
            }
        }
        .opacity(model.isScrubbing ? 0 : 1)
    }
}

/// Black gradients at the top and bottom edges, .6 at the edge fading to clear, and a light wash over
/// the middle so glass controls stay readable over bright pictures.
private struct Scrims: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 160)
                Spacer(minLength: 0)
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
            }
        }
        .ignoresSafeArea()
    }
}

/// The one control size of the player: a 56 pt glass circle with a 26 pt semibold glyph. The prominent
/// one (play and pause) is a solid ink fill with a canvas glyph. Dimmed when disabled.
struct PlayerButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PlayerButtonLabel(configuration: configuration, prominent: prominent)
    }
}

private struct PlayerButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(prominent ? theme.canvas : theme.ink)
            .frame(width: 56, height: 56)
            .background(prominent ? theme.ink : theme.glass, in: Circle())
            .overlay {
                if !prominent { Circle().strokeBorder(theme.edge, lineWidth: 1) }
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.5)
            .pressed(configuration.isPressed, in: Circle())
    }
}

/// The system AirPlay route picker in the player's glass circle; it prefers video receivers.
private struct AirPlayButton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        RoutePicker(tint: UIColor(theme.ink), active: UIColor(theme.accent))
            .frame(width: 56, height: 56)
            .background(theme.glass, in: Circle())
            .overlay(Circle().strokeBorder(theme.edge, lineWidth: 1))
            .accessibilityIdentifier("player.airplay")
    }
}

private struct RoutePicker: UIViewRepresentable {
    let tint: UIColor
    let active: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = active
    }
}

/// A short arc that marks loading; static, as DESIGN §8.6 asks, with the stage word doing the talking.
struct LoadingArc: View {
    var diameter: CGFloat = 56
    @Environment(\.theme) private var theme

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(theme.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

// MARK: - Menus

/// Audio and subtitles in one native menu, as Apple's own player has them (DESIGN §8.6, Tracks menu).
struct TracksMenu: View {
    @Bindable var model: PlayerModel

    var body: some View {
        Menu {
            if let tracks = model.tracks {
                menuContent(tracks)
            }
        } label: {
            Image(systemName: "captions.bubble")
        }
        .menuStyle(.button)
        .buttonStyle(PlayerButtonStyle())
        .disabled(model.tracks == nil)
        .accessibilityLabel("Audio and subtitles")
        .accessibilityIdentifier("player.tracks")
    }

    @ViewBuilder
    private func menuContent(_ tracks: MediaTracks) -> some View {
        if tracks.audio.count > 1 {
            Section("Audio") {
                Picker("Audio", selection: $model.audioPick) {
                    ForEach(orderedAudio(tracks)) { track in
                        Text(track.label).tag(Optional(track.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        let groups = SubtitleGroup.make(tracks.visibleSubtitles, preferred: model.preferredSubtitleLanguage, audio: model.audio)
        Section("Subtitles") {
            Picker("Subtitles", selection: $model.subtitlePick) {
                Text("Off").tag(SubtitleChoice.off)
                if tracks.visibleSubtitles.contains(where: { $0.kind == .onScreenText }) {
                    Text("On-Screen Text Only").tag(SubtitleChoice.onScreenTextOnly)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        // The one section every tracks menu has reports the menu opening and closing.
        .onAppear { model.menuOpened() }
        .onDisappear { model.menuClosed() }
        let shown = groups.count <= 3 ? groups : Array(groups.prefix(2))
        ForEach(shown) { group in
            subtitleSection(group)
        }
        if groups.count > 3 {
            Menu("Other Languages (\(groups.count - 2))") {
                ForEach(groups.dropFirst(2)) { group in
                    subtitleSection(group)
                }
            }
        }
        Section {
            Button {
                model.showsStyle = true
            } label: {
                if model.subtitleIsImage {
                    Text("Subtitle Style")
                    Text("Image subtitles can't be restyled")
                } else {
                    Label("Subtitle Style", systemImage: "textformat")
                }
            }
            .disabled(model.subtitleIsImage)
            if let problem = model.subtitleProblem {
                Text(problem)
            }
        }
    }

    private func subtitleSection(_ group: SubtitleGroup) -> some View {
        Section(group.name) {
            Picker(group.name, selection: $model.subtitlePick) {
                ForEach(group.tracks) { track in
                    Text(track.label).tag(SubtitleChoice.track(track.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// Tracks in the wanted language first, then the file's order.
    private func orderedAudio(_ tracks: MediaTracks) -> [AudioTrack] {
        guard let code = model.preferredAudioLanguage?.code else { return tracks.audio }
        let wanted = tracks.audio.filter { $0.language.code == code }
        return wanted + tracks.audio.filter { $0.language.code != code }
    }
}

/// One language's subtitles, ranked Full, SDH, Forced, Commentary (behaviour spec §3).
struct SubtitleGroup: Identifiable {
    let id: String
    let name: String
    let tracks: [SubtitleTrack]

    /// The subtitle language setting first, then the playing audio's language, then the file's order.
    static func make(_ tracks: [SubtitleTrack], preferred: TrackLanguage, audio: AudioTrack?) -> [SubtitleGroup] {
        var order: [String] = []
        var members: [String: [SubtitleTrack]] = [:]
        var names: [String: String] = [:]
        for track in tracks {
            let key = track.language.code ?? "und"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(track)
            names[key] = names[key] ?? track.languageName
        }
        let first = [preferred.code, audio?.language.code].compactMap { $0 }
        order.sort { lhs, rhs in
            let l = first.firstIndex(of: lhs) ?? Int.max, r = first.firstIndex(of: rhs) ?? Int.max
            return l < r
        }
        return order.map { key in
            let sorted = (members[key] ?? []).enumerated().sorted { a, b in
                a.element.kind == b.element.kind ? a.offset < b.offset : a.element.kind < b.element.kind
            }.map(\.element)
            return SubtitleGroup(id: key, name: names[key] ?? "Unknown", tracks: sorted)
        }
    }
}

/// Aspect, playback info and the stats overlay.
struct MoreMenu: View {
    @Bindable var model: PlayerModel

    var body: some View {
        Menu {
            Section {
                Picker(selection: $model.aspectPick) {
                    ForEach(VideoAspect.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                } label: {
                    Label("Aspect", systemImage: "aspectratio")
                    Text(model.aspect.title)
                }
                .pickerStyle(.menu)
            }
            .onAppear { model.menuOpened() }
            .onDisappear { model.menuClosed() }
            Section {
                Button {
                    model.showsInfo = true
                } label: {
                    Label("Playback Info", systemImage: "info.circle")
                }
                Toggle(isOn: $model.showsStats) {
                    Label("Stats for Nerds", systemImage: "chart.bar.xaxis")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel("More")
        .accessibilityIdentifier("player.more")
    }
}
