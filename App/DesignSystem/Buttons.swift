import SwiftUI

/// The accent pill (DESIGN §12): 48 pt high, accent fill, accentInk label. Put `.frame(maxWidth: .infinity)`
/// on the label for the full-width Play pill.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration)
    }
}

/// A round 48 pt icon button on the raised control fill (DESIGN §6, L3). The label is a bare SF Symbol;
/// give the button an accessible name that says what it does.
struct RoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundLabel(configuration: configuration)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
}

extension ButtonStyle where Self == RoundButtonStyle {
    static var round: RoundButtonStyle { RoundButtonStyle() }
}

private struct PillLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .textRole(.headline)
            .foregroundStyle(theme.accentInk)
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s2)
            .frame(minHeight: Size.target)
            .background(theme.accent, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .pressed(configuration.isPressed, in: Capsule())
    }
}

private struct RoundLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.title3)
            .foregroundStyle(theme.ink)
            .frame(width: Size.target, height: Size.target)
            .background(theme.glassRaised, in: Circle())
            .overlay(Circle().strokeBorder(theme.edge, lineWidth: 1))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.5)
            .pressed(configuration.isPressed, in: Circle())
    }
}

extension View {
    /// Press feedback (DESIGN §9): scale .97 over 90 ms, or a wash in place of the scale under Reduce Motion.
    func pressed(_ isPressed: Bool, in shape: some Shape) -> some View {
        modifier(PressFeedback(isPressed: isPressed, shape: shape))
    }
}

private struct PressFeedback<S: Shape>: ViewModifier {
    let isPressed: Bool
    let shape: S
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.overlay(shape.fill(theme.focus.opacity(isPressed ? (theme.mode == .dark ? 0.07 : 0.06) : 0)))
        } else {
            content
                .scaleEffect(isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.09), value: isPressed)
        }
    }
}
