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

    var body: some View {
        HStack(spacing: Space.s1) {
            tvButton
            HeaderButton(symbol: "power", label: model.connection == .connected ? "Power" : "Wake the TV", emphasized: true) {
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
            HeaderButton(symbol: "xmark", label: "Close remote") {
                session.remote.isPresented = false
            }
            .accessibilityIdentifier("remote.close")
        }
        .padding(.horizontal, Space.s2)
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
                            .textRole(.headline)
                            .foregroundStyle(theme.ink)
                    }
                    Text(model.panelStatus)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, Space.s2)
            .frame(maxWidth: .infinity, minHeight: Size.target, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose a TV")
        .accessibilityIdentifier("remote.tvpicker")
    }
}

/// A round header button: the raised control fill, or the accent for the one that matters.
struct HeaderButton: View {
    let symbol: String
    let label: String
    var emphasized = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(HeaderButtonStyle(emphasized: emphasized))
        .accessibilityLabel(Text(label))
        .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    let emphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        HeaderButtonLabel(configuration: configuration, emphasized: emphasized)
    }
}

private struct HeaderButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let emphasized: Bool

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: RemoteSize.glyph, weight: .semibold))
            .foregroundStyle(emphasized ? theme.accentInk : theme.ink)
            .frame(width: Size.target, height: Size.target)
            .background(emphasized ? theme.accent : theme.glassRaised, in: Circle())
            .overlay(Circle().strokeBorder(theme.edge, lineWidth: 1))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.5)
            .pressed(configuration.isPressed, in: Circle())
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
