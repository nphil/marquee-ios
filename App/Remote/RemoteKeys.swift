import LumaRemoteCore
import LumaRemoteKit
import SwiftUI

/// The remote's sizes that the shared tokens do not name.
enum RemoteSize {
    /// Glyphs on keys, pads and the panel's header buttons.
    static let glyph = Space.s6
    /// A finger that slides this far from where it landed has left the key.
    static let slideOff: CGFloat = 28
    /// A control that cannot be used yet: the kit's measured dimming.
    static let unavailable = 0.38
}

extension View {
    /// Fixes a child of the panel's face at a layout rectangle, which is in points from the panel's corner.
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
    }
}

enum RemoteKeyStyle {
    case raised
    /// One key that is on, such as Mute while the TV is muted.
    case accent
}

/// A key's cap: a raised rounded rectangle around its glyph, filled with the focus colour while pressed. It
/// fills the rectangle it is given, which the panel's layout sets.
struct RemoteKeyCap: ViewModifier {
    var style: RemoteKeyStyle
    var pressed: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        content
            .font(.system(size: RemoteSize.glyph, weight: .semibold))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(theme.edge, lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: pressed)
    }

    private var fill: Color {
        if pressed { theme.focus } else if style == .accent { theme.accent } else { theme.glassRaised }
    }

    private var ink: Color {
        if !isEnabled { theme.ink3 } else if pressed { theme.focusInk } else if style == .accent { theme.accentInk } else { theme.ink }
    }
}

/// A plain button drawn as a key.
struct RemoteKeyButtonStyle: ButtonStyle {
    var style = RemoteKeyStyle.raised

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(RemoteKeyCap(style: style, pressed: configuration.isPressed))
    }
}

/// A remote key: its wire key, glyph and spoken name.
struct RemoteKeySpec {
    let key: RemoteKey
    let symbol: String
    let label: String
}

/// Sends a key from a finger on the view, as the physical remote would: down when the finger lands, then a tap,
/// a repeat or a long press by how long it stays. Sliding off lets go without pressing.
struct RemoteKeyPress: ViewModifier {
    let key: RemoteKey
    @Binding var pressed: Bool

    @Environment(RemoteModel.self) private var model
    @GestureState private var touching = false
    @State private var slidOff = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { value in
                        if !pressed, !slidOff {
                            pressed = true
                            model.feedback.press()
                            model.pressBegan(key)
                        } else if pressed, hypot(value.translation.width, value.translation.height) > RemoteSize.slideOff {
                            pressed = false
                            slidOff = true
                            model.pressCancelled(key)
                        }
                    }
                    .onEnded { _ in finish(cancelled: false) }
            )
            // A gesture the system takes over, such as a pull for Control Centre, ends without onEnded.
            .onChange(of: touching) { _, touching in
                if !touching { finish(cancelled: true) }
            }
    }

    private func finish(cancelled: Bool) {
        if pressed {
            if cancelled { model.pressCancelled(key) } else { model.pressEnded(key) }
        }
        pressed = false
        slidOff = false
    }
}

extension View {
    /// One VoiceOver button for a glyph-only control, with the large content viewer at the biggest text sizes.
    func remoteKeyAccessibility(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
            .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
    }
}

/// A key that presses, holds and repeats like the remote's. `value` takes the glyph's place, as the volume does
/// on the mute key.
struct RemoteKeyButton: View {
    let spec: RemoteKeySpec
    var style = RemoteKeyStyle.raised
    var value: String?

    @Environment(RemoteModel.self) private var model
    @State private var pressed = false

    var body: some View {
        face
            .modifier(RemoteKeyCap(style: style, pressed: pressed))
            .modifier(RemoteKeyPress(key: spec.key, pressed: $pressed))
            .remoteKeyAccessibility(spec.label, symbol: spec.symbol) { model.tap(spec.key) }
            .accessibilityIdentifier("remote.key.\(spec.key.rawValue)")
    }

    @ViewBuilder private var face: some View {
        if let value {
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            Image(systemName: spec.symbol)
        }
    }
}

/// A key that runs `action` on a tap.
struct RemoteActionKey: View {
    let symbol: String
    let label: String
    var style = RemoteKeyStyle.raised
    let action: () -> Void

    @Environment(RemoteModel.self) private var model

    var body: some View {
        Button {
            model.feedback.press()
            action()
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(RemoteKeyButtonStyle(style: style))
        .accessibilityLabel(Text(label))
        .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
    }
}
