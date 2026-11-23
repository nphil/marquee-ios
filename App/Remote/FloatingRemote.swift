import MarqueeCore
import SwiftUI
import UIKit

extension Theme {
    /// The floating remote's own fill: the opaque sheet colour over the canvas (DESIGN §6, L4). The button and the
    /// panel it grows into share it, so the one becomes the other without a change of colour.
    var remotePanel: Color { roles.sheet.over(roles.canvas).color }
}

/// The floating LumaTV remote: a button that rests at the screen's edge over the tabs, and the panel that grows
/// out of it. It hangs over the tabs, so the player's cover and the sheets stay above it.
struct FloatingRemote: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if session.remote.isEnabled { RemoteHost() }
    }
}

/// Owns the transient state and the keyboard's place, and gives the layer the window's size.
private struct RemoteHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = RemoteStage()
    @State private var keyboardTop: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            RemoteLayer(size: proxy.size, keyboardTop: keyboardTop)
        }
        .ignoresSafeArea()
        .environment(stage)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(Motion.spring(reduceMotion: reduceMotion)) { keyboardTop = frame.minY }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(Motion.spring(reduceMotion: reduceMotion)) { keyboardTop = nil }
        }
    }
}

/// Places the button, the panel and, while the button is dragged, the spots it can rest at.
private struct RemoteLayer: View {
    let size: CGSize
    let keyboardTop: CGFloat?

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    /// 0 is the button, 1 the open panel.
    @State private var progress: CGFloat = 0
    /// Under Reduce Motion the panel fades in and out where it is, instead of growing.
    @State private var fade = 1.0

    /// The dim and the restore, in seconds: a slow fade down, a quick one up.
    private static let dimIn = Animation.easeInOut(duration: 0.6)
    private static let dimOut = Animation.easeOut(duration: 0.15)

    var body: some View {
        let remote = session.remote
        // The window's own insets: a SwiftUI proxy's bottom one grows with the keyboard.
        let insets = GlassesCenter.phoneScene()?.keyWindow?.safeAreaInsets ?? .zero
        let space = RemoteSpace(
            size: size, top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right,
            chrome: remote.bottomChrome, keyboardTop: keyboardTop
        )
        let dock = space.orbRect(for: remote.dock, size: Size.target)
        let orb = stage.drag.map { CGRect(origin: $0, size: dock.size) } ?? dock
        let showsOrb = remote.access == .floatingButton && session.place == .home && !session.glasses.isConnected
        // With no button on screen, the panel grows from a point above the bottom bar.
        let origin = showsOrb ? orb : Self.point(in: space)
        let panel = stage.shown ? stage.panel(in: space) : RemoteStage.openingPanel(remote, in: space)
        ZStack(alignment: .topLeading) {
            if stage.drag != nil {
                DockSpots(space: space)
            }
            if showsOrb || stage.shown {
                Group {
                    if stage.shown { RemotePanel(size: panel.size) }
                }
                .modifier(RemoteContainer(progress: progress, from: origin, to: panel, fromButton: showsOrb, lifted: stage.drag != nil, theme: theme))
                .opacity(stage.shown ? fade : (stage.dimmed ? OrbDimming.dimmedOpacity : 1))
                .animation(stage.dimmed ? Self.dimIn : Self.dimOut, value: stage.dimmed)
                .allowsHitTesting(stage.shown)
                .accessibilityHidden(!stage.shown)
            }
            if showsOrb && !stage.shown {
                OrbTouch(home: dock, space: space)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: RemoteStage.coordinates)
        .onChange(of: space, initial: true) { _, space in stage.space = space }
        .onChange(of: remote.isPresented, initial: true) { _, presented in
            if presented { open(space) } else { close() }
        }
        .onChange(of: stage.path.isEmpty) { _, atFace in
            if !atFace { stage.editing = false }
        }
    }

    /// Where a panel with no button to grow from starts: bottom centre, above the bar.
    private static func point(in space: RemoteSpace) -> CGRect {
        CGRect(
            x: space.safe.midX - Size.target / 2,
            y: min(space.barTop, space.safe.maxY) - RemoteMetrics.margin - Size.target,
            width: Size.target, height: Size.target
        )
    }

    private func open(_ space: RemoteSpace) {
        stage.dimmed = false
        stage.editing = false
        if stage.live == nil {
            stage.path = []
            stage.live = RemoteStage.openingPanel(session.remote, in: space)
        }
        stage.shown = true
        if reduceMotion {
            fade = 0
            progress = 1
            withAnimation(Motion.spring(reduceMotion: true)) { fade = 1 }
        } else {
            withAnimation(Motion.spring(reduceMotion: false)) { progress = 1 }
        }
    }

    private func close() {
        guard stage.shown else { return }
        stage.editing = false
        if reduceMotion {
            withAnimation(Motion.spring(reduceMotion: true), completionCriteria: .logicallyComplete) {
                fade = 0
            } completion: {
                finishClose()
            }
        } else {
            withAnimation(Motion.spring(reduceMotion: false), completionCriteria: .logicallyComplete) {
                progress = 0
            } completion: {
                finishClose()
            }
        }
    }

    /// The panel is gone from the screen. A panel asked for again while it shrank stays.
    private func finishClose() {
        guard !session.remote.isPresented else { return }
        stage.shown = false
        stage.live = nil
        stage.path = []
        progress = 0
        fade = 1
    }
}

// MARK: - The button's touch

/// The finger's side of the button: a tap opens the panel, and a drag carries the button to the nearest spot.
private struct OrbTouch: View {
    let home: CGRect
    let space: RemoteSpace

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var pressing = false

    /// A finger that travels less than this has tapped.
    private static let slop: CGFloat = 8

    private struct DimKey: Equatable {
        let touches: Int
        let dragging: Bool
        let pressing: Bool
    }

    var body: some View {
        let remote = session.remote
        let rect = stage.drag.map { CGRect(origin: $0, size: home.size) } ?? home
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .contentShape(Circle())
            .gesture(drag(remote))
            .accessibilityElement()
            .accessibilityLabel("TV Remote")
            .accessibilityHint("Opens the TV remote.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { open(remote) }
            .accessibilityAction(named: "Move to left edge") { move(.start, remote) }
            .accessibilityAction(named: "Move to right edge") { move(.end, remote) }
            .accessibilityIdentifier("remote.button")
            .position(x: rect.midX, y: rect.midY)
            .onChange(of: pressing) { _, pressing in
                stage.touch()
                // The system took the touch away mid-drag: no end came, so the button settles where it is.
                if !pressing, let origin = stage.drag { settle(at: origin, velocity: .zero, remote) }
            }
            // The panel-care rule: after OrbDimming.dwell seconds untouched the button dims; any touch restores it.
            .task(id: DimKey(touches: stage.touches, dragging: stage.drag != nil, pressing: pressing)) {
                stage.dimmed = false
                guard stage.drag == nil, !pressing else { return }
                try? await Task.sleep(for: .seconds(OrbDimming.dwell))
                guard !Task.isCancelled else { return }
                stage.dimmed = OrbDimming.isDimmed(overContent: true, panelOpen: false, idle: OrbDimming.dwell)
            }
    }

    private func drag(_ remote: TVRemote) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(RemoteStage.coordinates))
            .updating($pressing) { _, pressing, _ in pressing = true }
            .onChanged { value in
                let travel = hypot(value.translation.width, value.translation.height)
                guard stage.drag != nil || travel > Self.slop else { return }
                let reach = space.safe
                let next = CGPoint(
                    x: min(max(home.minX + value.translation.width, reach.minX), max(reach.minX, reach.maxX - home.width)),
                    y: min(max(home.minY + value.translation.height, reach.minY), max(reach.minY, reach.maxY - home.height))
                )
                if stage.drag == nil {
                    // Lifting the button off its spot: a haptic marks it and the button grows a little.
                    remote.model.feedback.press()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { stage.drag = next }
                } else {
                    stage.drag = next
                }
            }
            .onEnded { value in
                guard let origin = stage.drag else {
                    open(remote)
                    return
                }
                settle(at: origin, velocity: CGPoint(x: value.velocity.width, y: value.velocity.height), remote)
            }
    }

    private func open(_ remote: TVRemote) {
        stage.touch()
        remote.model.feedback.tick()
        remote.present()
    }

    /// The finger let go: the button glides to the spot nearest where it would have come to rest.
    private func settle(at origin: CGPoint, velocity: CGPoint, _ remote: TVRemote) {
        let centre = CGPoint(x: origin.x + home.width / 2, y: origin.y + home.height / 2)
        let target = nearestDock(
            center: projectedCenter(center: centre, velocity: velocity), field: space.orbField, size: home.width
        )
        remote.model.feedback.tick()
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            remote.setDock(target)
            stage.drag = nil
        }
    }

    private func move(_ side: DockSide, _ remote: TVRemote) {
        stage.touch()
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            remote.setDock(RemoteDock(side: side, row: remote.dock.row))
        }
    }
}

/// The spots the button can rest at, drawn while it is carried; the nearest one is ringed.
private struct DockSpots: View {
    let space: RemoteSpace

    @Environment(RemoteStage.self) private var stage
    @Environment(\.theme) private var theme

    private static let dot: CGFloat = 6

    var body: some View {
        let size = Size.target
        let near = stage.drag.map {
            nearestDock(center: CGPoint(x: $0.x + size / 2, y: $0.y + size / 2), field: space.orbField, size: size)
        }
        Canvas { context, _ in
            for spot in RemoteDock.all {
                let rect = space.orbRect(for: spot, size: size)
                if spot == near {
                    context.stroke(Path(ellipseIn: rect), with: .color(theme.accent), lineWidth: 2)
                } else {
                    let dot = CGRect(x: rect.midX - Self.dot / 2, y: rect.midY - Self.dot / 2, width: Self.dot, height: Self.dot)
                    context.fill(Path(ellipseIn: dot), with: .color(theme.ink3.opacity(0.5)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The button that becomes the panel

/// One surface that is the button at 0 and the panel at 1, and everything between. Its rectangle and corners
/// move from the button's to the panel's; the glyph fades out as the panel's face fades in, laid out at its
/// full size under the surface's clip. Rectangles are animated data, so a button that glides to a new spot or a
/// panel that refits for the keyboard moves the same way.
private struct RemoteContainer: ViewModifier, Animatable {
    var progress: CGFloat
    var from: CGRect
    var to: CGRect
    /// False when no button is on screen: the surface then fades in as it grows.
    let fromButton: Bool
    let lifted: Bool
    /// Passed in rather than read from the environment, so the modifier stays off the main actor as `Animatable` is.
    let theme: Theme

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGRect.AnimatableData, CGRect.AnimatableData>> {
        get { AnimatablePair(progress, AnimatablePair(from.animatableData, to.animatableData)) }
        set {
            progress = newValue.first
            from.animatableData = newValue.second.first
            to.animatableData = newValue.second.second
        }
    }

    /// Where in the growth the glyph is gone and the face begins to appear.
    private static let handover: CGFloat = 0.35
    private static let lift: CGFloat = 1.06

    func body(content: Content) -> some View {
        let t = min(max(progress, 0), 1)
        let rect = CGRect(
            x: from.minX + (to.minX - from.minX) * t, y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t
        )
        let closed = Size.target / 2
        let open = min(Radius.sheet, min(to.width, to.height) / 2)
        let shape = RoundedRectangle(cornerRadius: closed + (open - closed) * t, style: .continuous)
        let reveal = min(max((t - Self.handover) / (1 - Self.handover), 0), 1)
        ZStack(alignment: .topLeading) {
            theme.remotePanel
            Image(systemName: "appletvremote.gen4.fill")
                // 40% of the disc, the player controls' glyph proportion.
                .font(.system(size: Size.target * Size.controlGlyph / Size.control, weight: .semibold))
                .foregroundStyle(theme.accentText)
                .frame(width: Size.target, height: Size.target)
                .opacity(1 - min(t / Self.handover, 1))
            content
                .frame(width: to.width, height: to.height, alignment: .topLeading)
                .opacity(reveal)
                .offset(y: (1 - reveal) * Space.s2)
                .allowsHitTesting(reveal >= 1)
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay {
            ZStack {
                shape.strokeBorder(theme.edgeRaised, lineWidth: 1).opacity(1 - t)
                shape.strokeBorder(theme.edge, lineWidth: 1).opacity(t)
            }
        }
        // Light themes' soft rest shadow (DESIGN §6); the carried button lifts a little more. Dark themes
        // separate by their edge alone.
        .shadow(
            color: theme.mode == .light ? theme.ink.opacity(lifted ? 0.16 : 0.08) : .clear,
            radius: lifted ? 4 : 2, y: lifted ? 4 : 2
        )
        .scaleEffect(lifted ? Self.lift : 1)
        .opacity(fromButton ? 1 : min(t / Self.handover, 1))
        .position(x: rect.midX, y: rect.midY)
    }
}
