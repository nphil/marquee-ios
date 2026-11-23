import MarqueeCore
import SwiftUI
import UIKit

/// The bar for a playback that was minimised, whichever kind is docked (DESIGN §8.6.1). It sits in each
/// tab's own inset (`miniBarInset`), not in the tab view's bottom accessory, which belongs to the TV
/// remote's mini bar; that gives way while this is up and returns when the playback ends.
struct DockedMiniPlayer: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        switch session.player.docked {
        case .film(let model)?:
            // One identity per playback, so a swipe's offset never carries over to the next bar.
            FilmMiniBar(model: model).id(model.id)
        case .live(let model)?:
            LiveMiniBar(model: model).id(model.id)
        case nil:
            EmptyView()
        }
    }
}

/// The one button for the transport: its glyph (nil while the playback starts, which shows a spinner),
/// its spoken name and what it does.
struct MiniPlayerControl {
    let glyph: String?
    let label: String
    let action: () -> Void
}

/// A film or an episode in the bar. The bar hosts the playback's own layer view, the one Picture in
/// Picture is attached to, so the picture carries on into Picture in Picture from here as from the player.
private struct FilmMiniBar: View {
    let model: PlayerModel
    @Environment(AppSession.self) private var session

    var body: some View {
        let center = session.player
        MiniPlayerBar(
            title: model.title,
            detail: detail,
            progress: model.duration > 0 ? min(max(model.time / model.duration, 0), 1) : nil,
            elsewhere: model.castDevice != nil || model.isExternalPlayback,
            control: control,
            expand: { center.expand() },
            stop: { center.close(model) }
        ) {
            if center.barShowsPicture {
                FilmPicture(model: model)
            } else {
                Color.black
            }
        }
    }

    /// Where it plays when that is not the phone, else the second line of the player's own bar: "S2 · E5 ·
    /// Name" for an episode, the year for a film.
    private var detail: String? {
        if let device = model.castDevice { return "Casting to \(device.name)" }
        if model.isExternalPlayback { return "Playing on AirPlay" }
        return model.subtitleLine
    }

    private var control: MiniPlayerControl {
        let center = session.player
        switch model.phase {
        case .loading:
            return MiniPlayerControl(glyph: nil, label: "Starting", action: { center.expand() })
        case .failed:
            return MiniPlayerControl(glyph: "exclamationmark.triangle", label: "Playback failed. Open the player", action: { center.expand() })
        case .finished:
            return MiniPlayerControl(glyph: "arrow.counterclockwise", label: "Replay", action: { model.replay() })
        case .playing:
            return MiniPlayerControl(glyph: model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "Pause" : "Play") {
                Haptics.impact(.medium)
                model.togglePlay()
            }
        }
    }
}

/// The film's own layer view, fitted into the picture's box as the player fits it into the screen: the
/// layer stretches to whatever it is given, so the box around it takes the video's shape.
private struct FilmPicture: View {
    let model: PlayerModel

    var body: some View {
        GeometryReader { proxy in
            let rect = VideoFrame.rect(aspect: .fit, video: model.presentationSize, in: proxy.size, displayScale: 1)
            ZStack(alignment: .topLeading) {
                Color.black
                Group {
                    if let still = model.stillImage {
                        Image(uiImage: still)
                            .resizable()
                    } else {
                        VideoSurface(view: model.layerView)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            }
        }
    }
}

/// A live channel in the bar: its programme, the channel and how far the programme has run.
private struct LiveMiniBar: View {
    let model: LivePlaybackModel
    @Environment(AppSession.self) private var session

    var body: some View {
        let center = session.player
        let channel = model.channel
        let airing = model.airings(on: channel).now
        MiniPlayerBar(
            title: airing?.title ?? channel.title,
            detail: airing.map { "\(channel.label) · \(LiveText.range($0))" } ?? channel.label,
            progress: airing.map { $0.progress(at: model.moment(on: channel)) },
            elsewhere: false,
            control: control,
            expand: { center.expand() },
            stop: { center.closeLive(model) }
        ) {
            if center.barShowsPicture {
                LiveVideoHost(view: model.source.videoView, fills: false)
            } else {
                Color.black
            }
        }
        .task {
            // The programme and its progress move every 30 s, as in the live player.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.store.tick()
            }
        }
    }

    private var control: MiniPlayerControl {
        let center = session.player
        switch model.state {
        case .failed:
            return MiniPlayerControl(glyph: "exclamationmark.triangle", label: "Playback failed. Open the player", action: { center.expand() })
        case .playing, .stalled:
            let paused = model.timeshift.isPaused
            return MiniPlayerControl(glyph: paused ? "play.fill" : "pause.fill", label: paused ? "Play" : "Pause") {
                Haptics.impact(.medium)
                model.togglePlay()
            }
        case .idle:
            // The stream ended, as when its Picture in Picture window was closed: the button tunes again.
            return MiniPlayerControl(glyph: "play.fill", label: "Play") {
                Haptics.impact(.medium)
                model.togglePlay()
            }
        default:
            return MiniPlayerControl(glyph: nil, label: "Tuning", action: { center.expand() })
        }
    }
}

/// The bar itself (DESIGN §8.6.1): the picture, the title and a second line, the transport and Close,
/// and a thin accent line along the bottom for how far the playback has run. A tap or a swipe up opens the
/// player; a swipe sideways stops the playback.
struct MiniPlayerBar<Picture: View>: View {
    let title: String
    let detail: String?
    /// 0...1, nil for none.
    let progress: Double?
    /// The picture plays elsewhere (AirPlay, a Chromecast): a glyph stands in for it.
    let elsewhere: Bool
    let control: MiniPlayerControl
    let expand: () -> Void
    let stop: () -> Void
    let picture: Picture

    @Environment(\.theme) private var theme
    @Environment(\.sheetZoomNamespace) private var zoomNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.miniBarSize) private var size
    /// How far a sideways swipe has carried the bar.
    @State private var slide: CGFloat = 0

    /// A swipe up of this much opens the player; a swipe sideways of this much, or flung this far, stops it.
    private static var upDistance: CGFloat { 30 }
    private static var sideDistance: CGFloat { 90 }
    private static var sideFling: CGFloat { 240 }

    init(
        title: String, detail: String?, progress: Double?, elsewhere: Bool, control: MiniPlayerControl,
        expand: @escaping () -> Void, stop: @escaping () -> Void, @ViewBuilder picture: () -> Picture
    ) {
        self.title = title
        self.detail = detail
        self.progress = progress
        self.elsewhere = elsewhere
        self.control = control
        self.expand = expand
        self.stop = stop
        self.picture = picture()
    }

    private var fade: Double {
        1 - Double(min(abs(slide), 160)) / 320
    }

    var body: some View {
        HStack(spacing: Space.s2) {
            Button(action: expand) {
                HStack(spacing: Space.s3) {
                    tile
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .textRole(.label)
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        if let detail {
                            Text(detail)
                                .textRole(.caption)
                                .foregroundStyle(theme.ink2)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Size.target, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Opens the player.")
            .accessibilityIdentifier("miniplayer.expand")

            controlButton
            Button(action: stop) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.ink2)
                    .frame(width: Size.target, height: Size.target)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("miniplayer.close")
        }
        .padding(.horizontal, Space.s3)
        .frame(maxWidth: .infinity, minHeight: CGFloat(size.height))
        .overlay(alignment: .bottom) { line }
        .offset(x: slide)
        .opacity(fade)
        .simultaneousGesture(swipe)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniplayer")
    }

    private var tile: some View {
        ZStack {
            picture
                .allowsHitTesting(false)
            if elsewhere {
                theme.glassRaised
                Image(systemName: "airplayvideo")
                    .font(.callout)
                    .foregroundStyle(theme.ink)
            }
        }
        .frame(width: CGFloat(size.pictureWidth), height: CGFloat(size.pictureHeight))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .miniPlayerZoomSource(in: zoomNamespace)
        .accessibilityHidden(true)
    }

    private var controlButton: some View {
        Button(action: control.action) {
            Group {
                if let glyph = control.glyph {
                    Image(systemName: glyph)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.ink)
                } else {
                    ProgressView()
                        .tint(theme.ink2)
                }
            }
            .frame(width: Size.target, height: Size.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.label)
        .accessibilityIdentifier("miniplayer.control")
    }

    /// Inset from the glass's rounded corners, so the line sits in the straight part.
    @ViewBuilder
    private var line: some View {
        if let progress {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(theme.trackOff)
                    Rectangle().fill(theme.accent).frame(width: proxy.size.width * CGFloat(progress))
                }
            }
            .frame(height: Size.miniProgress)
            .clipShape(Capsule())
            .padding(.horizontal, Space.s5)
            .padding(.bottom, Space.s1 / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Up opens the player; sideways stops the playback, the bar following the finger.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let move = value.translation
                guard abs(move.width) > abs(move.height) else { return }
                slide = move.width
            }
            .onEnded { value in
                let move = value.translation
                if abs(move.height) > abs(move.width) {
                    if move.height < -Self.upDistance { expand() }
                } else if abs(move.width) > Self.sideDistance || abs(value.predictedEndTranslation.width) > Self.sideFling {
                    stop()
                    return
                }
                withAnimation(Motion.spring(reduceMotion: reduceMotion)) { slide = 0 }
            }
    }
}

extension View {
    /// The bar of a minimised playback, in the tab's own bottom inset above the tab bar. Only the selected
    /// tab shows it: the playback's layer view lives in one place at a time.
    func miniBarInset(isSelected: Bool) -> some View {
        modifier(MiniBarInset(isSelected: isSelected))
    }
}

/// The tab view's bottom accessory keeps its own 48 pt of glass whatever it holds (a 91 pt bar in it showed
/// 48 pt of glass and clipped the rest, in CI on the simulator), so the bar is ours: system glass with the
/// corners a 48 pt capsule has, always as tall as its width allows. [INFERENCE: when the tab bar minimises
/// on scroll the bar stays above it, big; that needs a phone check.]
private struct MiniBarInset: ViewModifier {
    let isSelected: Bool
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tab's width, measured before a bar shows, so the bar opens at its height and does not grow into it.
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let docked = session.player.docked != nil
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelected, docked {
                    DockedMiniPlayer()
                        .environment(\.miniBarSize, MiniBarSize(least: Size.target, margin: Size.miniMargin, width: width - Space.s5 * 2))
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .padding(.horizontal, Space.s5)
                        .padding(.bottom, Space.s2)
                        .transition(.opacity)
                }
            }
            // The bar fades as the playback is minimised and ended, and does not as the tabs change.
            .animation(Motion.spring(reduceMotion: reduceMotion), value: docked)
    }
}

extension EnvironmentValues {
    /// The bar's height and its picture's size, set where the bar is hosted from the width it has.
    @Entry var miniBarSize = MiniBarSize(least: Size.target, margin: Size.miniMargin, width: 0)
}
