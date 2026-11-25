import MarqueeCore
import SwiftUI
import UIKit

extension Theme {
    /// The remote's own fill: the opaque sheet colour over the canvas (DESIGN §6, L4). The Home button and the
    /// panel that grows out of it share it, so the one becomes the other without a change of colour.
    var remotePanel: Color { roles.sheet.over(roles.canvas).color }
}

/// The LumaTV remote's panel, floating over the tabs: it grows out of the Home button, or from above the tab
/// bar when the Mini Bar opened it. The player's cover and the sheets stay above it.
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

/// Places the panel and grows it from the Home button, or from a point above the tab bar when the Mini Bar or a
/// pairing link opened it.
private struct RemoteLayer: View {
    let size: CGSize
    let keyboardTop: CGFloat?

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 is the button, 1 the open panel.
    @State private var progress: CGFloat = 0
    /// Under Reduce Motion the panel fades in and out where it is, instead of growing.
    @State private var fade = 1.0

    var body: some View {
        let remote = session.remote
        // The window's own insets: a SwiftUI proxy's bottom one grows with the keyboard.
        let insets = GlassesCenter.phoneScene()?.keyWindow?.safeAreaInsets ?? .zero
        let space = RemoteSpace(
            size: size, top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right,
            keyboardTop: keyboardTop
        )
        let button = remote.origin.flatMap { $0.isEmpty ? nil : $0 }
        let panel = stage.shown ? stage.panel(in: space) : RemoteStage.openingPanel(remote, in: space)
        ZStack(alignment: .topLeading) {
            if stage.shown {
                RemotePanel(size: panel.size)
                    .modifier(RemoteContainer(progress: progress, from: button ?? Self.point(in: space), to: panel, fromButton: button != nil))
                    .opacity(fade)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: space, initial: true) { _, space in stage.space = space }
        .onChange(of: remote.isPresented, initial: true) { _, presented in
            if presented { open(space) } else { close() }
        }
        .onChange(of: stage.path.isEmpty) { _, atFace in
            if !atFace { stage.editing = false }
        }
    }

    /// Where a panel with no button to grow from starts: bottom centre of the safe area.
    private static func point(in space: RemoteSpace) -> CGRect {
        CGRect(
            x: space.safe.midX - Size.target / 2,
            y: space.safe.maxY - RemoteMetrics.margin - Size.target,
            width: Size.target, height: Size.target
        )
    }

    private func open(_ space: RemoteSpace) {
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

// MARK: - The button that becomes the panel

/// One surface that is the button at 0 and the panel at 1, and everything between. Its rectangle and corners
/// move from the button's to the panel's; the glyph fades out as the panel's face fades in, laid out at its
/// full size under the surface's clip. Every value is an ordinary modifier parameter, so the animation that
/// changes `progress` also carries a panel that refits for the keyboard. A custom `Animatable` conformance
/// would cross into the main actor, which Swift 6 rejects.
private struct RemoteContainer: ViewModifier {
    let progress: CGFloat
    let from: CGRect
    let to: CGRect
    /// False when no button opened the panel: the surface then fades in as it grows.
    let fromButton: Bool

    @Environment(\.theme) private var theme

    /// Where in the growth the glyph is gone and the face begins to appear.
    private static let handover: CGFloat = 0.35

    func body(content: Content) -> some View {
        let t = min(max(progress, 0), 1)
        let rect = CGRect(
            x: from.minX + (to.minX - from.minX) * t, y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t
        )
        let disc = min(from.width, from.height)
        let closed = disc / 2
        let open = min(Radius.sheet, min(to.width, to.height) / 2)
        let shape = RoundedRectangle(cornerRadius: closed + (open - closed) * t, style: .continuous)
        let reveal = min(max((t - Self.handover) / (1 - Self.handover), 0), 1)
        ZStack(alignment: .topLeading) {
            theme.remotePanel
            Image(systemName: "appletvremote.gen4.fill")
                // 40% of the disc, the player controls' glyph proportion.
                .font(.system(size: disc * Size.controlGlyph / Size.control, weight: .semibold))
                .foregroundStyle(theme.accentText)
                .frame(width: disc, height: disc)
                .opacity(fromButton ? 1 - min(t / Self.handover, 1) : 0)
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
        // Light themes' soft rest shadow (DESIGN §6). Dark themes separate by their edge alone.
        .shadow(color: theme.mode == .light ? theme.ink.opacity(0.08) : .clear, radius: 2, y: 2)
        .opacity(fromButton ? 1 : min(t / Self.handover, 1))
        .position(x: rect.midX, y: rect.midY)
    }
}
