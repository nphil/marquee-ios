import AVKit
import Combine
import MarqueeCore
import SwiftUI

/// The controls over the picture (DESIGN §8.6): close, title and AirPlay on top; the transport in the
/// middle; the scrubber, the tracks menu and More at the bottom. Everything else lives in More. While
/// the finger is on the scrubber everything but the scrubber fades, so the preview has the picture to
/// itself.
struct PlayerChrome: View {
    let model: PlayerModel
    let frames: TrickplayFrames
    let close: () -> Void
    /// The bottom controls' frame on screen.
    let bottomChanged: (CGRect) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The top row's bottom edge and the bottom controls' top edge, on screen, for the scrims.
    @State private var topRow: CGFloat = 0
    @State private var bottomRow: CGFloat = .infinity
    /// The bottom controls' bottom edge: the lowest a menu from the top row may reach.
    @State private var bottomEdge: CGFloat = 0

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
                    bottomEdge = frame.maxY
                    bottomChanged(frame)
                }
        }
        .padding(.horizontal, Space.inset)
        // On its side the phone has no top safe area and only the home indicator's below, so the rows would
        // sit 8 pt from the edge.
        .padding(.vertical, verticalSizeClass == .compact ? Space.s4 : Space.s2)
        .background {
            Scrims(topRow: topRow, bottomRow: bottomRow)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.18), value: model.isScrubbing)
        .overlayPreferenceValue(SeekPreviewKey.self) { SeekPreviewLayer(state: $0) }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: Space.s3) {
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(PlayerButtonStyle())
            .accessibilityLabel("Close")
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

            // Apple's player puts Picture in Picture beside the route button, top trailing.
            if model.canPictureInPicture, model.castDevice == nil {
                Button {
                    model.togglePictureInPicture()
                } label: {
                    Image(systemName: "pip.enter")
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel("Picture in Picture")
                .accessibilityIdentifier("player.pip")
            }
            RouteButton(model: model, menuRoom: menuRoom)
        }
    }

    /// Height below the top row for the route menu: down to the bottom controls' edge, less the popover's
    /// arrow and a margin. Before the first layout, a height that fits a phone on its side.
    private var menuRoom: CGFloat {
        bottomEdge > topRow ? bottomEdge - topRow - Space.s6 : 240
    }

    // MARK: Centre

    @ViewBuilder
    private var centre: some View {
        switch model.phase {
        case .loading:
            LoadingStage(model: model)
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
                    // Full width, so the caption wraps only on a screen too narrow for its line: two lines
                    // under the transport's width reached the scrubber at large text sizes.
                    .frame(maxWidth: .infinity)
                    // A zero-height frame on the transport's bottom edge: the caption hangs below it, outside
                    // the transport's layout, so the buttons stay put. A bottom alignment guide left it on them.
                    .overlay(alignment: .bottom) { networkWait.frame(height: 0, alignment: .top) }
                    .transition(.opacity)
            }
        }
    }

    private var upNextShowing: Bool {
        guard case .upNext? = model.offer else { return false }
        return true
    }

    /// Under the ring until an offer takes the band below the transport, where the two would meet at large
    /// text sizes or on a small phone.
    @ViewBuilder
    private var networkWait: some View {
        if model.waitsForNetwork || model.belowQualityFloor, model.offer == nil {
            Text(model.belowQualityFloor ? "Keeping picture quality; buffering may be needed." : "Waiting for the network")
                .textRole(.label)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s3)
                .allowsHitTesting(false)
                .accessibilityIdentifier(model.belowQualityFloor ? "player.qualityFloor" : "player.networkWait")
                .transition(.opacity)
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
                    LoadingArc(diameter: 68, fraction: model.loadFraction)
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

    /// Restart, Episodes and Next, icon only on the leading side; a movie has none of them.
    @ViewBuilder
    private var queueControls: some View {
        if model.isEpisode || model.hasPreviousItem || model.hasNext {
            HStack(spacing: Space.s3) {
                Button {
                    Haptics.impact(.light)
                    model.previous()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel(model.previousAction == .restart ? "Restart" : "Previous episode")
                .accessibilityIdentifier("player.previous")
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
            }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        switch model.phase {
        case .playing, .finished:
            VStack(spacing: Space.s1) {
                Scrubber(model: model, frames: frames)
                HStack(spacing: Space.s3) {
                    queueControls
                        .opacity(model.isScrubbing ? 0 : 1)
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

/// The one control size of the player: a `Size.control` glass circle with the player glyph. The
/// prominent one (play and pause) is a solid ink fill with a canvas glyph. Dimmed when disabled.
struct PlayerButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PlayerControlFace(prominent: prominent, isPressed: configuration.isPressed))
            .accessibilityShowsLargeContentViewer()
    }
}

/// A player control's glyph in its circle, for the button style and under a UIKit control.
struct PlayerControlFace: ViewModifier {
    var prominent = false
    let isPressed: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .modifier(PlayerGlyph())
            .foregroundStyle(prominent ? theme.canvas : theme.ink)
            .frame(width: Size.control, height: Size.control)
            .background(prominent ? theme.ink : theme.glass, in: Circle())
            .overlay {
                if !prominent { Circle().strokeBorder(theme.edge, lineWidth: 1) }
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.5)
            .pressed(isPressed, in: Circle())
    }
}

/// Every player glyph, the route glyph included, is `Size.controlGlyph` semibold. It grows with
/// Dynamic Type up to `Size.controlGlyphMax`, half the circle; the circles keep their size so the
/// controls still fit a 375 pt-tall screen, and past the cap the large content viewer shows the glyph.
private struct PlayerGlyph: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var size = Size.controlGlyph

    func body(content: Content) -> some View {
        content
            .font(.system(size: min(size, Size.controlGlyphMax), weight: .semibold))
            .imageScale(.medium)
    }
}

/// AirPlay in the player's glass circle, its glyph drawn like every other control's and in accent while
/// sound and picture go to a receiver. The system route picker lies over it, tinted clear, and takes
/// the tap; it prefers video receivers.
struct AirPlayButton: View {
    @Environment(\.theme) private var theme
    @State private var routedAway = false

    var body: some View {
        Image(systemName: "airplayvideo")
            .modifier(PlayerGlyph())
            .foregroundStyle(routedAway ? theme.accent : theme.ink)
            .frame(width: Size.control, height: Size.control)
            .background(theme.glass, in: Circle())
            .overlay(Circle().strokeBorder(theme.edge, lineWidth: 1))
            .accessibilityHidden(true)
            .overlay { RoutePicker() }
            .accessibilityIdentifier("player.airplay")
            .onAppear { routedAway = Self.isRoutedAway }
            // Route changes arrive on a background queue.
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main)) { _ in
                routedAway = Self.isRoutedAway
            }
    }

    private static var isRoutedAway: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.backgroundColor = .clear
        view.tintColor = .clear
        view.activeTintColor = .clear
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// AirPlay, or with the Chromecast plugin on the Cast mark, in accent while a Chromecast plays. Its
/// popover lists this iPhone, the Chromecasts found and the system's AirPlay and Bluetooth picker.
struct RouteButton: View {
    let model: PlayerModel
    /// The height the route menu may take below the button.
    let menuRoom: CGFloat
    @Environment(AppSession.self) private var session
    @State private var showsRoutes = false

    var body: some View {
        if session.cast.isEnabled {
            Button {
                Haptics.impact(.light)
                showsRoutes = true
            } label: {
                CastGlyph(connected: model.castDevice != nil)
            }
            .buttonStyle(PlayerButtonStyle())
            .accessibilityLabel(model.castDevice.map { "Playing on \($0.name)" } ?? "Play On")
            .accessibilityIdentifier("player.route")
            .popover(isPresented: $showsRoutes) {
                RouteList(room: menuRoom) { showsRoutes = false }
                    .presentationCompactAdaptation(.popover)
            }
            .onChange(of: showsRoutes) { _, shown in
                if shown { model.menuOpened() } else { model.menuClosed() }
            }
        } else {
            AirPlayButton()
        }
    }
}

private struct CastGlyph: View {
    let connected: Bool
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var size = Size.controlGlyph

    var body: some View {
        let side = min(size, Size.controlGlyphMax)
        CastMark(connected: connected)
            .foregroundStyle(connected ? theme.accent : theme.ink)
            .frame(width: side, height: side)
    }
}

/// The route button's popover. Picking a Chromecast keeps it open until the receiver connects. It takes
/// the room below the top row and scrolls when the rows are taller, so a phone on its side never clips
/// the first or last row.
private struct RouteList: View {
    let room: CGFloat
    let dismiss: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var glyphColumn = Size.menuGlyph
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let measured = rows
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        Group {
            if contentHeight > room {
                ScrollView { measured }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: room)
            } else {
                measured
            }
        }
        .frame(minWidth: 260)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("route.menu")
        .presentationBackground(theme.sheet)
        .onChange(of: session.cast.link) { _, link in
            if case .connected = link { dismiss() }
        }
    }

    private var rows: some View {
        let cast = session.cast
        return VStack(alignment: .leading, spacing: 0) {
            row("This iPhone", systemImage: "iphone", state: cast.link == .none ? .chosen : .idle, id: "route.phone") {
                cast.disconnect()
                dismiss()
            }
            ForEach(cast.devices) { device in
                row(device.name, systemImage: "tv", state: Self.state(of: device, link: cast.link), id: "route.\(device.id)") {
                    cast.connect(device)
                }
            }
            if cast.devices.isEmpty {
                // Under the labels above, not under their icons.
                Text("Looking for Chromecasts…")
                    .textRole(.caption)
                    .foregroundStyle(theme.ink2)
                    .padding(.leading, Space.s4 + glyphColumn + Space.s3)
                    .padding(.trailing, Space.s4)
                    .padding(.vertical, Space.s3)
            }
            Divider()
                .overlay(theme.edge)
            RouteRowLabel(title: "AirPlay & Bluetooth", systemImage: "airplayvideo", state: .idle)
                .overlay { RoutePicker() }
                .accessibilityIdentifier("route.airplay")
        }
    }

    private static func state(of device: CastDevice, link: CastCenter.Link) -> RouteRowLabel.Mark {
        switch link {
        case .connected(let current) where current == device: .chosen
        case .connecting(let current) where current == device: .connecting
        default: .idle
        }
    }

    private func row(_ title: String, systemImage: String, state: RouteRowLabel.Mark, id: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            RouteRowLabel(title: title, systemImage: systemImage, state: state)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(state == .chosen ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// One row of the route menu: every icon in one column, so the labels start on one line, and the mark of
/// the chosen row (or the spinner of the one connecting) in a column of the same width at the trailing
/// margin.
private struct RouteRowLabel: View {
    enum Mark { case idle, connecting, chosen }

    let title: String
    let systemImage: String
    let state: Mark
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var column = Size.menuGlyph

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .frame(width: column)
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch state {
                case .chosen:
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.accent)
                case .connecting:
                    ProgressView()
                        .tint(theme.ink2)
                case .idle:
                    Color.clear
                }
            }
            .frame(width: column, alignment: .trailing)
        }
        .textRole(.body)
        .foregroundStyle(theme.ink)
        .padding(.horizontal, Space.s4)
        .frame(minHeight: Size.target)
        .contentShape(Rectangle())
    }
}

/// Google's Cast mark (Material Symbols "cast", Apache 2.0) drawn on its 24-point grid; `connected`
/// fills the screen, as "cast_connected" does.
struct CastMark: Shape {
    var connected = false

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        // The screen, open at the bottom left for the waves.
        path.move(to: p(21, 3))
        path.addLine(to: p(3, 3))
        path.addCurve(to: p(1, 5), control1: p(1.9, 3), control2: p(1, 3.9))
        path.addLine(to: p(1, 8))
        path.addLine(to: p(3, 8))
        path.addLine(to: p(3, 5))
        path.addLine(to: p(21, 5))
        path.addLine(to: p(21, 19))
        path.addLine(to: p(14, 19))
        path.addLine(to: p(14, 21))
        path.addLine(to: p(21, 21))
        path.addCurve(to: p(23, 19), control1: p(22.1, 21), control2: p(23, 20.1))
        path.addLine(to: p(23, 5))
        path.addCurve(to: p(21, 3), control1: p(23, 3.9), control2: p(22.1, 3))
        path.closeSubpath()
        // The dot and the two waves.
        path.move(to: p(1, 18))
        path.addLine(to: p(1, 21))
        path.addLine(to: p(4, 21))
        path.addCurve(to: p(1, 18), control1: p(4, 19.34), control2: p(2.66, 18))
        path.closeSubpath()
        path.move(to: p(1, 14))
        path.addLine(to: p(1, 16))
        path.addCurve(to: p(6, 21), control1: p(3.76, 16), control2: p(6, 18.24))
        path.addLine(to: p(8, 21))
        path.addCurve(to: p(1, 14), control1: p(8, 17.13), control2: p(4.87, 14))
        path.closeSubpath()
        path.move(to: p(1, 10))
        path.addLine(to: p(1, 12))
        path.addCurve(to: p(10, 21), control1: p(5.97, 12), control2: p(10, 16.03))
        path.addLine(to: p(12, 21))
        path.addCurve(to: p(1, 10), control1: p(12, 14.92), control2: p(7.08, 10))
        path.closeSubpath()
        if connected {
            path.move(to: p(19, 7))
            path.addLine(to: p(5, 7))
            path.addLine(to: p(5, 8.63))
            path.addCurve(to: p(13.37, 17), control1: p(8.96, 9.91), control2: p(12.09, 13.04))
            path.addLine(to: p(19, 17))
            path.closeSubpath()
        }
        return path
    }
}

/// The loading screen's middle: the arc and, a second in, what the start waits for.
struct LoadingStage: View {
    let model: PlayerModel
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Space.s3) {
            LoadingArc(fraction: model.loadFraction)
            Text(model.showsStage ? model.stageText : " ")
                .textRole(.label)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.ink2)
                .contentTransition(.opacity)
                // A new stage fades in; the share counting up within one changes in place.
                .animation(reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.2), value: step)
                .animation(.easeOut(duration: 0.12), value: model.showsStage)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityValue(model.showsStage ? model.stageText : "")
    }

    /// The stage without its share.
    private var step: Int {
        switch model.loadStage {
        case .connecting: 0
        case .opening: 1
        case .preparing: 2
        case .buffering: 3
        case .starting: 4
        }
    }
}

/// Loading: an arc that turns while the wait has no measure, and a ring that fills to the measured share
/// while one is known. The two cross-fade and the fill follows the share. Reduce Motion holds the arc
/// still and cuts the cross-fade to 120 ms.
struct LoadingArc: View {
    var diameter: CGFloat = 56
    /// The share of the wait in hand; nil turns the arc.
    var fraction: Double?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The last share, kept while the ring fades out.
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            if fraction == nil {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    arc(to: 0.22)
                        .rotationEffect(.degrees(reduceMotion ? -90 : turn(at: context.date)))
                }
                .transition(.opacity)
            } else {
                ZStack {
                    Circle().stroke(theme.trackOff, lineWidth: Self.line)
                    arc(to: max(0.02, shown))
                        .rotationEffect(.degrees(-90))
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.12) : .easeInOut(duration: 0.25), value: fraction == nil)
        .frame(width: diameter, height: diameter)
        .onChange(of: fraction, initial: true) { old, new in
            guard let new else { return }
            let share = min(1, max(0, new))
            // A ring fading in starts at its share rather than filling from the last one.
            if old == nil || reduceMotion {
                shown = share
            } else {
                withAnimation(.linear(duration: 0.15)) { shown = share }
            }
        }
        .accessibilityHidden(true)
    }

    private static let line: CGFloat = 3

    private func arc(to end: Double) -> some View {
        Circle()
            .trim(from: 0, to: end)
            .stroke(theme.ink, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
    }

    /// One turn every 1.2 s, from the top.
    private func turn(at date: Date) -> Double {
        -90 + date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
    }
}

// MARK: - Menus

/// Audio choices stay in the native menu; subtitles open their own sheet.
struct TracksMenu: View {
    let model: PlayerModel

    var body: some View {
        // Opening upward, the automatic order reverses the list and the Subtitles row ends up above the
        // Audio header; fixed reads Audio, then Subtitles, top down.
        PlayerMenuButton(
            model: model, systemImage: "captions.bubble", label: "Audio and subtitles", identifier: "player.tracks",
            order: .fixed, menu: menu
        )
        .disabled(model.tracks == nil)
    }

    private var menu: UIMenu {
        var sections: [UIMenuElement] = []
        if let tracks = model.tracks {
            if tracks.audio.count > 1 {
                let playing = model.audioPick
                sections.append(UIMenu.section("player.tracks.audio", title: "Audio", orderedAudio(tracks).map { track in
                    let id = track.id
                    // Choosing the playing track again keeps it.
                    return UIAction.choice(track.label, detail: detail(track.badges), isOn: playing == id) { [model] in
                        if model.audioPick != id { model.audioPick = id }
                    }
                }))
            }
            let subtitles = UIAction(title: "Subtitles…") { [model] _ in model.openSubtitleFix(.subtitles) }
            subtitles.accessibilityIdentifier = "player.tracks.subtitles"
            sections.append(UIMenu.section("player.tracks.more", [subtitles]))
        }
        return UIMenu(identifier: UIMenu.Identifier(rawValue: "player.tracks"), children: sections)
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

/// Everything the chrome keeps off its edges (DESIGN §8.6): aspect, quality and speed, the audio
/// enhancements, playback info and stats for nerds.
struct MoreMenu: View {
    let model: PlayerModel

    var body: some View {
        PlayerMenuButton(model: model, systemImage: "ellipsis", label: "More", identifier: "player.more", menu: menu)
    }

    private var menu: UIMenu {
        var sections: [UIMenuElement] = []
        if model.castDevice == nil {
            let shown = model.aspect
            sections.append(UIMenu.section("player.more.picture", [
                UIMenu.submenu("player.aspect", title: "Aspect", systemImage: "aspectratio", value: shown.title, VideoAspect.allCases.map { aspect in
                    UIAction.choice(aspect.title, isOn: shown == aspect) { [model] in model.aspectPick = aspect }
                }),
            ]))
        }
        sections.append(UIMenu.section("player.more.playback", playback))
        sections.append(UIMenu.section("player.more.panels", [
            UIAction(title: "Playback Info", image: UIImage(systemName: "info.circle")) { [model] _ in model.showsInfo = true },
            UIAction.choice("Stats for Nerds", systemImage: "chart.bar.xaxis", isOn: model.showsStats) { [model] in
                model.showsStats.toggle()
            },
        ]))
        return UIMenu(identifier: UIMenu.Identifier(rawValue: "player.more"), children: sections)
    }

    /// Quality, the note that the server converts the picture, speed and the audio enhancements.
    private var playback: [UIMenuElement] {
        var rows: [UIMenuElement] = []
        if model.forcesDirectPlay {
            // UIKit has no disabled submenu, so the quality stands as a row that opens nothing.
            let quality = UIAction(title: "Quality", subtitle: qualityValue, image: UIImage(systemName: "dial.medium"), attributes: .disabled) { _ in }
            quality.accessibilityIdentifier = "player.quality"
            rows.append(quality)
        } else {
            let shown = model.qualitySetting
            rows.append(UIMenu.submenu("player.quality", title: "Quality", systemImage: "dial.medium", value: qualityValue, QualitySetting.all.map { setting in
                UIAction.choice(setting.title, isOn: shown == setting) { [model] in model.qualityPick = setting }
            }))
        }
        if model.quality == .original, model.isConverting {
            rows.append(UIAction.note("Your Plex server is converting this video."))
        }
        if model.castDevice == nil {
            let shown = model.speed
            rows.append(UIMenu.submenu(
                "player.speed", title: "Playback Speed", systemImage: "gauge.with.dots.needle.67percent", value: Self.title(of: shown),
                Self.speeds.map { speed in
                    UIAction.choice(Self.title(of: speed), isOn: shown == speed) { [model] in model.speedPick = speed }
                }
            ))
        }
        if model.enhancements.offered {
            rows.append(UIMenu.submenu(
                "player.enhancements", title: "Audio Enhancements", systemImage: "waveform", value: enhancementValue,
                enhancementRows(model.enhancements)
            ))
        }
        return rows
    }

    /// Boost dialog and Normalize loudness, shown only for a Plex Pass server; the reason they cannot
    /// apply to this video stands under them.
    private func enhancementRows(_ state: PlayerModel.EnhancementState) -> [UIMenuElement] {
        var rows: [UIMenuElement] = [
            enhancementToggle("Boost dialog", .boostDialog, state),
            enhancementToggle("Normalize loudness", .normalizeLoudness, state),
        ]
        if let text = state.unavailable ?? state.note {
            rows.append(UIAction.note(text))
        }
        return rows
    }

    private func enhancementToggle(_ title: String, _ enhancement: AudioEnhancements, _ state: PlayerModel.EnhancementState) -> UIAction {
        UIAction.choice(title, isOn: state.asked.contains(enhancement), isEnabled: state.unavailable == nil) { [model] in
            model.toggleEnhancement(enhancement)
        }
    }

    /// The enhancements asked for, or Off.
    private var enhancementValue: String {
        let all: [(AudioEnhancements, String)] = [(.boostDialog, "Boost dialog"), (.normalizeLoudness, "Normalize loudness")]
        let asked = all.filter { model.enhancements.asked.contains($0.0) }.map { $0.1 }
        return asked.isEmpty ? "Off" : asked.joined(separator: ", ")
    }

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func title(of speed: Float) -> String {
        speed == 1 ? "Normal" : speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private var qualityValue: String {
        if model.forcesDirectPlay { return "Original" }
        if model.qualitySetting == .auto { return "Auto · " + model.quality.title }
        return model.quality == .original && model.isConverting ? "Original · Converted" : model.quality.title
    }
}
