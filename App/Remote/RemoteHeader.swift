import LumaRemoteCore
import LumaRemoteKit
import MarqueeCore
import SwiftUI

/// The face's header band: the TV and its state, which open the TV list, then Power, Arrange and Close. A drag on
/// the band, buttons included, carries the whole panel.
struct RemoteHeader: View {
    let width: CGFloat

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model
    @Environment(\.theme) private var theme

    /// Below this width the TV's name leaves the header and only its state stays.
    private static let nameMinWidth: CGFloat = 300

    /// The room a header button's hit area keeps beyond its drawn circle.
    private static let hitSlack = (HeaderButton.hit - HeaderButton.disc) / 2

    var body: some View {
        HStack(spacing: 0) {
            tvButton
            HeaderButton(
                symbol: "power", label: model.connection == .connected ? "Power" : "Wake the TV",
                look: model.connection == .connected && model.state.power == .on ? .tinted : .raised
            ) {
                model.power()
            }
            .disabled(model.current == nil)
            .accessibilityIdentifier("remote.power")
            // Without a TV there is nothing to arrange.
            if model.current != nil {
                HeaderButton(symbol: "slider.horizontal.3", label: "Arrange") {
                    model.feedback.click()
                    stage.editing = true
                }
                .accessibilityIdentifier("remote.arrange")
            }
            HeaderButton(symbol: "xmark.circle.fill", label: "Close remote", look: .bare) {
                session.remote.isPresented = false
            }
            .accessibilityIdentifier("remote.close")
        }
        // The drawn circles, not their hit areas, sit on the card's inset.
        .padding(.leading, RemoteMetrics.inset)
        .padding(.trailing, RemoteMetrics.inset - Self.hitSlack)
        .frame(width: width, height: RemoteMetrics.header)
        .movesPanel(minimumDistance: 6)
    }

    private var tvButton: some View {
        Button {
            stage.path.append(.tvs)
        } label: {
            HStack(spacing: Space.s2) {
                Circle()
                    .fill(model.panelStatusColour(theme))
                    .frame(width: Space.s2, height: Space.s2)
                VStack(alignment: .leading, spacing: 0) {
                    if width >= Self.nameMinWidth, let tv = model.current {
                        Text(tv.name)
                            .font(.headline)
                            .foregroundStyle(theme.ink)
                    }
                    Text(model.panelStatus)
                        .font(.footnote)
                        .foregroundStyle(theme.ink2)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: HeaderButton.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose a TV")
        .accessibilityIdentifier("remote.tvpicker")
    }
}

/// A small round header button: a 32 pt circle in a 44 pt hit area. `tinted` colours the glyph with the accent
/// for a state that is on, `accent` fills the circle for the one action that finishes a task, and `bare` is the
/// standard dismiss glyph without a circle of its own.
struct HeaderButton: View {
    enum Look { case raised, tinted, accent, bare }

    static let disc: CGFloat = 32
    static let hit: CGFloat = 44

    let symbol: String
    let label: String
    var look = Look.raised
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(HeaderButtonStyle(look: look))
        .accessibilityLabel(Text(label))
        .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    let look: HeaderButton.Look

    func makeBody(configuration: Configuration) -> some View {
        HeaderButtonLabel(configuration: configuration, look: look)
    }
}

private struct HeaderButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let look: HeaderButton.Look

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let disc = HeaderButton.disc
        configuration.label
            .font(.system(size: look == .bare ? disc - 4 : 15, weight: .semibold))
            .symbolRenderingMode(look == .bare ? .hierarchical : .monochrome)
            .foregroundStyle(ink)
            .frame(width: disc, height: disc)
            .background(fill, in: Circle())
            .frame(width: HeaderButton.hit, height: HeaderButton.hit)
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }

    private var ink: Color {
        switch look {
        case .raised: theme.ink
        case .tinted: theme.accentText
        case .accent: theme.accentInk
        case .bare: theme.ink3
        }
    }

    private var fill: Color {
        switch look {
        case .raised, .tinted: theme.glassRaised
        case .accent: theme.accent
        case .bare: .clear
        }
    }
}

// MARK: Dragging the panel

extension View {
    /// A finger on the view carries the whole panel. A positive `minimumDistance` lets taps through to what is
    /// under the finger.
    func movesPanel(minimumDistance: CGFloat = 0) -> some View {
        modifier(PanelDrag(minimumDistance: minimumDistance, handle: nil))
    }

    /// A finger on the view drags one edge or corner of the panel.
    func resizesPanel(_ handle: PanelHandle) -> some View {
        modifier(PanelDrag(minimumDistance: 0, handle: handle))
    }
}

/// A finger that moves or resizes the panel. Each change is the whole drag so far applied to the panel as it was
/// when the finger landed, so the result does not depend on the order or the number of the changes; when the
/// finger lifts the panel snaps to the grid, stays inside the room there is and is saved.
struct PanelDrag: ViewModifier {
    let minimumDistance: CGFloat
    /// The edge or corner this finger drags, or nil for one that carries the whole panel.
    let handle: PanelHandle?

    @Environment(AppSession.self) private var session
    @Environment(RemoteStage.self) private var stage
    @Environment(RemoteModel.self) private var model
    @GestureState private var touching = false
    @State private var start: CGRect?

    func body(content: Content) -> some View {
        content
            // High priority, so a drag that starts on a button still carries the panel and the button is not
            // pressed when the finger lifts. Measured in the window: a named space defined outside the
            // navigation stack need not resolve inside it, and a space that moves with the panel would skew
            // the drag.
            .highPriorityGesture(
                DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { value in
                        guard let from = start ?? stage.live else { return }
                        if start == nil {
                            start = from
                            if handle != nil { model.feedback.tick() }
                        }
                        let delta = CGPoint(x: value.translation.width, y: value.translation.height)
                        let bounds = stage.space.panelBounds
                        stage.live = if let handle {
                            resizePanel(from, handle: handle, delta: delta, bounds: bounds, minSize: RemoteMetrics.minPanel)
                        } else {
                            movePanel(from, by: delta, in: bounds)
                        }
                    }
                    .onEnded { _ in finish() }
            )
            // A gesture the system takes over ends without onEnded.
            .onChange(of: touching) { _, touching in
                if !touching { finish() }
            }
    }

    private func finish() {
        guard start != nil else { return }
        start = nil
        stage.settle(session.remote)
    }
}
