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
    /// The top row's bottom edge and the bottom controls' top edge, on screen, for the scrims.
    @State private var topRow: CGFloat = 0
    @State private var bottomRow: CGFloat = .infinity

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .opacity(model.isScrubbing ? 0 : 1)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).maxY
                } action: { maxY in
                    topRow = maxY
                }
            Spacer(minLength: Space.s3)
            centre
                .opacity(model.isScrubbing ? 0 : 1)
            Spacer(minLength: Space.s3)
            bottom
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    bottomRow = frame.minY
                    bottomChanged(frame)
                }
        }
        .padding(.horizontal, Space.inset)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s2)
        .background {
            Scrims(topRow: topRow, bottomRow: bottomRow)
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
            .accessibilityIdentifier("player.title")
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
                LoadingArc(fraction: model.loadFraction)
                Text(model.showsStage ? model.stageText : " ")
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: model.showsStage)
                    .animation(.easeOut(duration: 0.2), value: model.stageText)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
            .accessibilityValue(model.showsStage ? stageValue : "")
        case .failed(let message):
            FailureCard(message: message, close: close, retry: model.retry)
        case .finished:
            FinishedCard(model: model, close: close)
        case .playing:
            // The Up Next card covers the middle of a phone on its side and carries its own play, so the
            // transport steps aside while it shows; Watch Credits brings it back. It leaves the tree: at
            // zero opacity its buttons stayed in the accessibility tree. The spacers keep the top and
            // bottom rows in place.
            if !upNextShowing {
                transport
                    .transition(.opacity)
            }
        }
    }

    private var stageValue: String {
        guard let fraction = model.loadFraction else { return model.stageText }
        return "\(model.stageText), \(Int(fraction * 100)) percent"
    }

    private var upNextShowing: Bool {
        guard case .upNext? = model.offer else { return false }
        return true
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

/// Black behind the top row and the bottom controls, fading to clear over 64 pt towards the middle, on a
/// light wash that keeps the glass controls readable over bright pictures. Under the title, glyphs and
/// time codes the two add up to .59 black (DESIGN §5.3 asks .55 or more).
struct Scrims: View {
    /// The top row's bottom edge and the bottom controls' top edge, in global coordinates.
    let topRow: CGFloat
    let bottomRow: CGFloat

    private static let wash = 0.18
    private static let edge = 0.5
    private static let fade: CGFloat = 64

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let top = min(frame.height, max(0, topRow - frame.minY))
            let bottom = min(frame.height - top, max(0, frame.maxY - bottomRow))
            let fade = min(Self.fade, (frame.height - top - bottom) / 2)
            VStack(spacing: 0) {
                Color.black.opacity(Self.edge)
                    .frame(height: top)
                LinearGradient(colors: [.black.opacity(Self.edge), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(Self.edge)], startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
                Color.black.opacity(Self.edge)
                    .frame(height: bottom)
            }
            .background(Color.black.opacity(Self.wash))
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
struct AirPlayButton: View {
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

/// Loading: an arc that turns while the wait has no measure, and fills to the real share of the start
/// buffer while a stream buffers. Reduce Motion holds it still.
struct LoadingArc: View {
    var diameter: CGFloat = 56
    /// The share of the start buffer in hand; nil turns the arc.
    var fraction: Double?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: fraction != nil || reduceMotion)) { context in
            ZStack {
                if fraction != nil {
                    Circle().stroke(theme.trackOff, lineWidth: 3)
                }
                Circle()
                    .trim(from: 0, to: fraction.map { max(0.02, $0) } ?? 0.22)
                    .stroke(theme.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(fraction == nil && !reduceMotion ? turn(at: context.date) : -90))
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    /// One turn every 1.2 s, from the top.
    private func turn(at date: Date) -> Double {
        -90 + date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
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
        // Opening upward, the automatic order reverses the list and the subtitle languages end up above
        // the Subtitles header; fixed reads Audio, then Subtitles, top down.
        .menuOrder(.fixed)
        .menuStyle(.button)
        .buttonStyle(PlayerButtonStyle())
        .disabled(model.tracks == nil)
        .accessibilityLabel("Audio and subtitles")
        .accessibilityIdentifier("player.tracks")
    }

    /// Sections hold toggles rather than inline pickers: an inline picker inside a section hides the
    /// section's header, which left the audio and subtitle lists unnamed.
    @ViewBuilder
    private func menuContent(_ tracks: MediaTracks) -> some View {
        if tracks.audio.count > 1 {
            Section("Audio") {
                ForEach(orderedAudio(tracks)) { track in
                    choice(track.label, detail: detail(track.badges), value: Optional(track.id), selection: $model.audioPick)
                }
            }
        }
        let groups = SubtitleGroup.make(tracks.visibleSubtitles, preferred: model.preferredSubtitleLanguage, audio: model.audio)
        Section("Subtitles") {
            choice("Off", value: SubtitleChoice.off, selection: $model.subtitlePick)
            if tracks.visibleSubtitles.contains(where: { $0.kind == .onScreenText }) {
                choice("On-Screen Text Only", value: SubtitleChoice.onScreenTextOnly, selection: $model.subtitlePick)
            }
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

    /// A language with one track goes without a header: its row already starts with the language.
    @ViewBuilder
    private func subtitleSection(_ group: SubtitleGroup) -> some View {
        if group.tracks.count == 1 {
            Section { subtitleRows(group) }
        } else {
            Section(group.name) { subtitleRows(group) }
        }
    }

    private func subtitleRows(_ group: SubtitleGroup) -> some View {
        ForEach(group.tracks) { track in
            choice(
                track.label,
                detail: detail(track.badges, imageFormat: track.imageFormat),
                value: SubtitleChoice.track(track.id),
                selection: $model.subtitlePick
            )
        }
    }

    /// A menu row with a checkmark while `selection` holds `value`; choosing it again keeps it.
    private func choice<Value: Equatable & Sendable>(
        _ title: String, detail: String? = nil, value: Value, selection: Binding<Value>
    ) -> some View {
        Toggle(isOn: Binding { selection.wrappedValue == value } set: { if $0 { selection.wrappedValue = value } }) {
            Text(title)
            if let detail { Text(detail) }
        }
    }

    /// The second line of a track row: "Captions", "Audio description", and the picture format of image
    /// subtitles (behaviour spec §3), so two "English" rows read apart.
    private func detail(_ badges: [TrackBadge], imageFormat: String? = nil) -> String? {
        let words = badges.map(\.rawValue) + [imageFormat].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: " · ")
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
