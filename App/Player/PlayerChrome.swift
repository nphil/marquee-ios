import AVKit
import Combine
import MarqueeCore
import SwiftUI

/// The controls over the picture (DESIGN §8.6): close, minimise, title and AirPlay on top, with Picture in
/// Picture where the row is wide enough for it; the transport in the middle; the scrubber, the tracks menu
/// and More at the bottom. Everything else lives in More. While the finger is on the scrubber everything
/// but the scrubber fades, so the preview has the picture to itself.
struct PlayerChrome: View {
    let model: PlayerModel
    /// Handed down by the player screen, as for `OfferView`: the transport steps aside for Up Next by it, and
    /// the network caption shows by both.
    let offer: PlayerModel.Offer?
    let waitsForNetwork: Bool
    let frames: TrickplayFrames
    let close: () -> Void
    /// Minimise to the bar above the tab bar (DESIGN §8.6.1).
    let minimise: () -> Void
    /// The bottom controls' frame on screen.
    let bottomChanged: (CGRect) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The top row's bottom edge and the bottom controls' top edge, on screen, for the scrims.
    @State private var topRow: CGFloat = 0
    @State private var bottomRow: CGFloat = .infinity
    /// The bottom controls' bottom edge: the lowest a menu from the top row may reach.
    @State private var bottomEdge: CGFloat = 0
    /// The top row's width as it lays out. Whether Picture in Picture has room beside the other buttons
    /// follows it, not the device (DESIGN §8.6 item 2).
    @State private var topWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .opacity(model.isScrubbing ? 0 : 1)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).maxY
                } action: { maxY in
                    topRow = maxY
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    topWidth = width
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

            Button(action: minimise) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(PlayerButtonStyle())
            .accessibilityLabel("Minimise")
            .accessibilityIdentifier("player.minimise")

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

            // Apple's player puts Picture in Picture beside the route button, top trailing. A row too
            // narrow for it, a phone upright, has it in More.
            if offersPictureInPicture, topRowFitsPictureInPicture {
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

    /// The video can go to a window and nothing is cast.
    private var offersPictureInPicture: Bool { model.canPictureInPicture && model.castDevice == nil }

    /// What the title keeps beside four buttons. A row that cannot spare it carries Picture in Picture in
    /// More: 150 pt is a 390 pt phone upright with three buttons (154 pt), and a phone on its side or an
    /// iPad has more.
    private static let titleRoom: CGFloat = 150

    private var topRowFitsPictureInPicture: Bool {
        topWidth >= 4 * Size.control + 4 * Space.s3 + Self.titleRoom
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
        guard case .upNext? = offer else { return false }
        return true
    }

    /// Under the ring until an offer takes the band below the transport, where the two would meet at large
    /// text sizes or on a small phone.
    @ViewBuilder
    private var networkWait: some View {
        if waitsForNetwork, offer == nil {
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
                    MoreMenu(model: model, carriesPictureInPicture: offersPictureInPicture && !topRowFitsPictureInPicture, room: menuRoom)
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

/// Audio and subtitles (DESIGN §8.6, Tracks menu). The subtitles are On or Off, with Style beside them and one
/// Advanced row for the rest; the audio is the track that plays and one Advanced row. One set of rules
/// (`TrackRules`) chooses the tracks, so no language is asked for here, and nothing covers the picture.
struct TracksMenu: View {
    let model: PlayerModel
    @Environment(AppSession.self) private var session

    var body: some View {
        // Opening upward, the automatic order reverses the list; fixed reads the subtitles, the audio and
        // then the tools, top down.
        PlayerMenuButton(
            model: model, systemImage: "captions.bubble", label: "Audio and subtitles", identifier: "player.tracks",
            order: .fixed, menu: menu
        )
        .disabled(model.tracks == nil)
    }

    private var menu: UIMenu {
        var sections: [UIMenuElement] = []
        if let tracks = model.tracks {
            sections.append(UIMenu.section("player.tracks.subtitles", title: "Subtitles", subtitleRows(tracks)))
            if tracks.audio.count > 1 {
                sections.append(UIMenu.section("player.tracks.audio", title: "Audio", audioRows(tracks)))
            }
        }
        return UIMenu(identifier: UIMenu.Identifier(rawValue: "player.tracks"), children: sections)
    }

    /// On and Off, then Style and one Advanced row. On puts the rules' English track on screen, or finds one when
    /// the file has none. Style stays but dims, with the reason, while the server draws the subtitle into the picture.
    private func subtitleRows(_ tracks: MediaTracks) -> [UIMenuElement] {
        let showing = model.subtitle?.track
        let drawnByServer = model.subtitleDrawnByServer
        let finder = model.subtitleFinder
        let waiting = showing == nil && model.automaticSubtitle == nil
        var rows: [UIMenuElement] = [
            UIAction.choice(
                "On", detail: waiting ? (finder.isSearching ? finder.status?.detail : "None yet. Choose to find them.") : nil,
                isOn: showing != nil, isEnabled: !(waiting && finder.isSearching)
            ) { [model] in
                guard model.subtitle?.track == nil else { return }
                if model.automaticSubtitle != nil { model.subtitlePick = .automatic } else { model.findSubtitles() }
            },
            UIAction.choice("Off", isOn: showing == nil) { [model] in
                if model.subtitlePick != .off { model.subtitlePick = .off }
            },
            style(drawnByServer: drawnByServer),
            advancedSubtitles(tracks, drawnByServer: drawnByServer),
        ]
        if let drawnByServer { rows.append(UIAction.note(drawnByServer)) }
        if let problem = model.subtitleProblem { rows.append(UIAction.note(problem)) }
        return rows
    }

    /// Every subtitle track of the file, Find Subtitles, Subtitle Timing and the show's anime setting. Timing
    /// dims, with the reason, while the server draws the subtitle; it shows only while a subtitle is on.
    private func advancedSubtitles(_ tracks: MediaTracks, drawnByServer: String?) -> UIMenuElement {
        let showing = model.subtitle?.track
        let finder = model.subtitleFinder
        var sections: [UIMenuElement] = []
        let choices = tracks.visibleSubtitles.map { track in
            let id = track.id
            return UIAction.choice(track.label, detail: detail(track.badges, imageFormat: track.imageFormat), isOn: showing?.id == id) { [model] in
                if model.subtitle?.track?.id != id { model.subtitlePick = .track(id) }
            }
        }
        if !choices.isEmpty { sections.append(UIMenu.section("player.tracks.subtitles.choices", choices)) }
        var tools: [UIMenuElement] = [
            UIAction.row(
                "Find English Subtitles", systemImage: "magnifyingglass", value: finder.isSearching ? finder.status?.detail : nil,
                identifier: "player.tracks.find", isEnabled: !finder.isSearching
            ) { [model] in
                model.findSubtitles()
            },
        ]
        if model.canTimeSubtitles || drawnByServer != nil {
            tools.append(UIAction.row(
                "Subtitle Timing", systemImage: "clock", value: model.timingText, identifier: "player.tracks.timing",
                isEnabled: drawnByServer == nil
            ) { [model] in
                model.openTiming()
            })
        }
        sections.append(UIMenu.section("player.tracks.subtitles.tools", tools))
        sections.append(UIMenu.section("player.tracks.subtitles.anime", [animeMenu]))
        return UIMenu.submenu("player.tracks.subtitles.advanced", title: "Advanced", systemImage: "ellipsis.circle", value: "", sections)
    }

    /// Whether the show plays by the anime rules: the English dub with its own subtitles. Automatic follows Plex's tags.
    private var animeMenu: UIMenuElement {
        UIMenu.submenu(
            "player.tracks.anime", title: "Anime", systemImage: "tv", value: model.animeOverride.title,
            [AnimeOverride.automatic, .anime, .notAnime].map { option in
                UIAction.choice(option.title, isOn: model.animeOverride == option) { [model] in
                    model.pickAnime(option)
                }
            }
        )
    }

    /// The audio that plays, and every track of the file under Advanced.
    private func audioRows(_ tracks: MediaTracks) -> [UIMenuElement] {
        let playing = model.audioPick
        var rows: [UIMenuElement] = []
        if let current = model.audio {
            rows.append(UIAction.choice(current.label, detail: detail(current.badges), isOn: true) {})
        }
        rows.append(UIMenu.submenu(
            "player.tracks.audio.choices", title: "Advanced", systemImage: "ellipsis.circle", value: "",
            tracks.audio.map { track in
                let id = track.id
                // Choosing the playing track again keeps it.
                return UIAction.choice(track.label, detail: detail(track.badges), isOn: playing == id) { [model] in
                    if model.audioPick != id { model.audioPick = id }
                }
            }
        ))
        return rows
    }

    /// The look's main settings, each a submenu whose choices apply at once and keep the menu up, so the
    /// subtitles behind it show the change. The rest of the look is in Settings. Image subtitles take
    /// only a tint.
    private func style(drawnByServer: String?) -> UIMenuElement {
        guard drawnByServer == nil else {
            return UIAction.row("Subtitle Style", systemImage: "textformat", identifier: "player.tracks.style", isEnabled: false) {}
        }
        let look = session.settings.subtitleStyle
        guard !model.subtitleIsImage else {
            return UIMenu.submenu("player.tracks.style", title: "Subtitle Style", systemImage: "textformat", value: look.colour.title, [
                styleChoices("colour", "Colour", \.colour, SubtitleLook.TextColour.allCases, \.title),
                keepingOpen(UIAction.choice("Soften Brightness", isOn: look.blendsWithVideo) { [session] in
                    session.settings.subtitleStyle.blendsWithVideo.toggle()
                }),
                UIAction.note("These subtitles are pictures: their size and position are the file's."),
            ])
        }
        let lookName = look.isCustom ? "Custom" : look.preset.title
        let presets = UIMenu.submenu(
            "player.tracks.style.look", title: "Look", value: lookName,
            SubtitleLook.Preset.allCases.map { preset in
                keepingOpen(UIAction.choice(preset.title, isOn: !look.isCustom && look.preset == preset) { [session] in
                    session.settings.subtitleStyle.apply(preset)
                })
            }
        )
        return UIMenu.submenu("player.tracks.style", title: "Subtitle Style", systemImage: "textformat", value: lookName, [
            presets,
            styleChoices("size", "Size", \.size, SubtitleLook.sizes) { "\($0)%" },
            styleChoices("colour", "Colour", \.colour, SubtitleLook.TextColour.allCases, \.title),
            styleChoices("position", "Position", \.anchor, SubtitleLook.Anchor.allCases, \.title),
            styleChoices("reveal", "Reveal as Spoken", \.reveal, SubtitleLook.Reveal.allCases, \.title),
        ])
    }

    /// One look setting's values, the current one ticked.
    private func styleChoices<Value: Equatable>(
        _ id: String, _ title: String, _ setting: WritableKeyPath<SubtitleLook, Value>, _ values: [Value], _ label: (Value) -> String
    ) -> UIMenu {
        let current = session.settings.subtitleStyle[keyPath: setting]
        return UIMenu.submenu("player.tracks.style.\(id)", title: title, value: label(current), values.map { value in
            keepingOpen(UIAction.choice(label(value), isOn: value == current) { [session] in
                session.settings.subtitleStyle[keyPath: setting] = value
            })
        })
    }

    private func keepingOpen(_ action: UIAction) -> UIAction {
        action.attributes.insert(.keepsMenuPresented)
        return action
    }

    /// The second line of a track row: "Captions", "Audio description", and the picture format of image
    /// subtitles (behaviour spec §3).
    private func detail(_ badges: [TrackBadge], imageFormat: String? = nil) -> String? {
        let words = badges.map(\.rawValue) + [imageFormat].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }
}

private extension AnimeOverride {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .anime: "Anime"
        case .notAnime: "Not Anime"
        }
    }
}

/// Everything the chrome keeps off its edges (DESIGN §8.6), in three groups: the picture's quality and
/// aspect, speed and the audio enhancements, playback info and stats for nerds. Picture in Picture joins
/// the first group when the top row has no room for its button.
struct MoreMenu: View {
    let model: PlayerModel
    var carriesPictureInPicture = false
    /// Height the popover may take; it scrolls when its rows are taller.
    let room: CGFloat
    @State private var shows = false
    /// The button's trailing edge, which stands for the screen's width.
    @State private var screenWidth: CGFloat = 0
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            Haptics.impact(.light)
            shows = true
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel("More")
        .accessibilityIdentifier("player.more")
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { screenWidth = $0 }
        // The popover hangs over the button: the controls it would cover stay clear.
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            MorePanel(model: model, carriesPictureInPicture: carriesPictureInPicture, room: room, width: panelWidth) { shows = false }
                .presentationCompactAdaptation(.popover)
                .presentationBackground(theme.sheet)
        }
        .onChange(of: shows) { _, shown in
            if shown { model.menuOpened() } else { model.menuClosed() }
        }
    }

    /// 300 pt on a phone on its side, at most 70% of the width of one held upright.
    private var panelWidth: CGFloat {
        screenWidth > 0 ? min(300, screenWidth * 0.7) : 280
    }

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func title(of speed: Float) -> String {
        speed == 1 ? "Normal" : speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// The More popover: the three groups of rows, each opening its choices in place under a back row, so
/// every level is the same width and the same hairline rhythm. Colours come from the theme only.
private struct MorePanel: View {
    enum Page { case root, quality, aspect, speed, enhancements }

    let model: PlayerModel
    let carriesPictureInPicture: Bool
    let room: CGFloat
    let width: CGFloat
    let dismiss: () -> Void
    @State private var page = Page.root
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    @Environment(\.theme) private var theme

    var body: some View {
        let measured = content
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
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.more.menu")
    }

    /// Pages slide as a navigation stack's do, on one spring that the panel's height follows; Reduce Motion cross-fades.
    private func go(_ next: Page) {
        forward = next != .root
        withAnimation(.snappy(duration: 0.35)) { page = next }
    }

    private var slide: AnyTransition {
        reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading)
    }

    private var content: some View {
        pageRows
            .id(page)
            .transition(slide)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
    }

    @ViewBuilder
    private var pageRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .root: root
            case .quality:
                back("Quality")
                ForEach(QualitySetting.all, id: \.self) { setting in
                    choice(setting.title, isOn: model.qualitySetting == setting) { model.qualityPick = setting }
                }
            case .aspect:
                back("Aspect")
                ForEach(VideoAspect.allCases, id: \.self) { aspect in
                    choice(aspect.title, isOn: model.aspect == aspect) { model.aspectPick = aspect }
                }
            case .speed:
                back("Speed")
                ForEach(MoreMenu.speeds, id: \.self) { speed in
                    choice(MoreMenu.title(of: speed), isOn: model.speed == speed) { model.speedPick = speed }
                }
            case .enhancements:
                back("Audio Enhancements")
                let state = model.enhancements
                choice("Boost dialog", isOn: state.asked.contains(.boostDialog), isEnabled: state.unavailable == nil, closes: false) {
                    model.toggleEnhancement(.boostDialog)
                }
                choice("Normalize loudness", isOn: state.asked.contains(.normalizeLoudness), isEnabled: state.unavailable == nil, closes: false) {
                    model.toggleEnhancement(.normalizeLoudness)
                }
                if let text = state.unavailable ?? state.note { note(text) }
            }
        }
    }

    // MARK: Root

    @ViewBuilder
    private var root: some View {
        if carriesPictureInPicture {
            action("Picture in Picture", systemImage: "pip.enter", id: "player.pip") { model.togglePictureInPicture() }
        }
        if model.forcesDirectPlay {
            RowFace(title: "Quality", systemImage: "dial.medium", value: qualityValue, chevron: false)
                .opacity(0.5)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Quality")
                .accessibilityValue(qualityValue)
                .accessibilityIdentifier("player.quality")
        } else {
            open("Quality", systemImage: "dial.medium", value: qualityValue, id: "player.quality", page: .quality)
        }
        if model.quality == .original, model.isConverting { note("Your Plex server is converting this video.") }
        if model.castDevice == nil {
            open("Aspect", systemImage: "aspectratio", value: model.aspect.title, id: "player.aspect", page: .aspect)
        }
        if model.castDevice == nil || model.enhancements.offered { rule }
        if model.castDevice == nil {
            open("Speed", systemImage: "gauge.with.dots.needle.67percent", value: MoreMenu.title(of: model.speed), id: "player.speed", page: .speed)
        }
        if model.enhancements.offered {
            open("Audio Enhancements", systemImage: "waveform", value: enhancementValue, id: "player.enhancements", page: .enhancements)
        }
        rule
        action("Playback Info", systemImage: "info.circle", id: "player.info.open") { model.showsInfo = true }
        action("Stats for Nerds", systemImage: "chart.bar.xaxis", id: "player.stats.toggle", checked: model.showsStats) {
            model.showsStats.toggle()
        }
        if ReportCenter.shared.isAvailable {
            action("Report a Problem", systemImage: "exclamationmark.bubble", id: "player.report") {
                // The action runs while the popover is still closing; the screenshot waits until it has gone.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    ReportCenter.shared.open(from: .player, screenshot: ReportCenter.capture())
                }
            }
        }
    }

    private var rule: some View {
        Divider().overlay(theme.edge)
    }

    /// A row that opens `page`, with the current value before its chevron.
    private func open(_ title: String, systemImage: String, value: String, id: String, page next: Page) -> some View {
        Button {
            Haptics.impact(.light)
            go(next)
        } label: {
            RowFace(title: title, systemImage: systemImage, value: value, chevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }

    /// A row that does something and closes the popover; a checkmark marks a toggle that is on.
    private func action(_ title: String, systemImage: String, id: String, checked: Bool? = nil, run: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            dismiss()
            run()
        } label: {
            RowFace(title: title, systemImage: systemImage, value: nil, chevron: false, checked: checked)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(checked == true ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: Choices

    private func back(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.impact(.light)
                go(.root)
            } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chevron.backward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    Text(title)
                        .textRole(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.s4)
                .frame(minHeight: Size.target)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("Back")
            rule
        }
    }

    private func choice(_ title: String, isOn: Bool, isEnabled: Bool = true, closes: Bool = true, pick: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            pick()
            if closes { dismiss() }
        } label: {
            HStack(spacing: Space.s3) {
                Text(title)
                    .textRole(.body)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, Space.s4)
            .frame(minHeight: Size.target)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Words among the rows: why something cannot be chosen.
    private func note(_ text: String) -> some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(theme.ink2)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Values

    /// The enhancements asked for, or Off.
    private var enhancementValue: String {
        let all: [(AudioEnhancements, String)] = [(.boostDialog, "Boost dialog"), (.normalizeLoudness, "Normalize loudness")]
        let asked = all.filter { model.enhancements.asked.contains($0.0) }.map { $0.1 }
        return asked.isEmpty ? "Off" : asked.joined(separator: ", ")
    }

    private var qualityValue: String {
        if model.forcesDirectPlay { return "Original" }
        if model.qualitySetting == .auto { return "Auto · " + model.qualityTitle }
        return model.quality == .original && model.isConverting ? "Original · Converted" : model.quality.title
    }
}

/// One row: icon, title on one line, then the value in secondary ink and a chevron. At accessibility text
/// sizes the value drops under the title.
private struct RowFace: View {
    let title: String
    let systemImage: String
    let value: String?
    let chevron: Bool
    var checked: Bool?
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var column = Size.menuGlyph

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.accent)
                .frame(width: column)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    titleText
                    valueText
                }
                Spacer(minLength: 0)
            } else {
                titleText
                    .layoutPriority(1)
                Spacer(minLength: Space.s2)
                valueText
            }
            if chevron {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.ink3)
            }
            if checked == true {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, Space.s4)
        .frame(minHeight: Size.target)
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text(title)
            .textRole(.body)
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    @ViewBuilder
    private var valueText: some View {
        if let value {
            Text(value)
                .textRole(.body)
                .foregroundStyle(theme.ink2)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.8)
        }
    }
}
