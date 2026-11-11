import SwiftUI
import UIKit

/// The type scale from DESIGN §4.3: Manrope for display and titles, the system font for the rest.
/// Every role scales with the iPhone's text size.
enum TextRole {
    case display, title, headline, body, label, caption
}

extension View {
    func textRole(_ role: TextRole) -> some View {
        modifier(TextRoleModifier(role: role))
    }
}

/// Manrope's cuts by PostScript name. The bundled file is a variable font whose named instances
/// carry these names.
enum Manrope: String {
    case medium = "Manrope-Medium"
    case semiBold = "Manrope-SemiBold"
    case bold = "Manrope-Bold"

    /// One cut heavier, for the Bold Text setting.
    var bolder: Manrope {
        switch self {
        case .medium: .semiBold
        case .semiBold, .bold: .bold
        }
    }

    /// `base` points at the default text size, scaled as `style` scales and capped at `cap`.
    @MainActor
    static func size(_ base: CGFloat, as style: UIFont.TextStyle, at typeSize: DynamicTypeSize, cap: DynamicTypeSize? = nil) -> CGFloat {
        let capped = cap.map { min(typeSize, $0) } ?? typeSize
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(capped))
        return UIFontMetrics(forTextStyle: style).scaledValue(for: base, compatibleWith: traits)
    }
}

private struct TextRoleModifier: ViewModifier {
    let role: TextRole
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    @ViewBuilder
    func body(content: Content) -> some View {
        switch role {
        case .display:
            // Capped at accessibility 3 so a hero title still fits beside its art.
            manrope(content, cut: .medium, size: Manrope.size(34, as: .largeTitle, at: typeSize, cap: .accessibility3), tracking: -0.02, lineHeight: 1.0)
        case .title:
            manrope(content, cut: .semiBold, size: Manrope.size(24, as: .title2, at: typeSize), tracking: -0.01, lineHeight: 1.25)
        case .headline:
            content.font(.headline)
        case .body:
            content.font(.body).lineHeight(.multiple(factor: 1.45))
        case .label:
            content.font(.subheadline.weight(.medium)).lineHeight(.multiple(factor: 1.3))
        case .caption:
            content.font(.caption).lineHeight(.multiple(factor: 1.3))
        }
    }

    /// Tracking is in em, so it is multiplied by the scaled size.
    private func manrope(_ content: Content, cut: Manrope, size: CGFloat, tracking: CGFloat, lineHeight: CGFloat) -> some View {
        let face = legibilityWeight == .bold ? cut.bolder : cut
        return content
            .font(.custom(face.rawValue, fixedSize: size))
            .tracking(tracking * size)
            .lineHeight(.multiple(factor: lineHeight))
    }
}

/// The glasses' type scale (DESIGN §8.12), in points of the 1920 × 1080 canvas. Fixed: the phone's
/// text size does not reach a screen sized for reading from across the room. Bold Text still applies.
enum GlassesText {
    case display, title, headline, body, label, caption

    var size: CGFloat {
        switch self {
        case .display: 76
        case .title: 52
        case .headline: 40
        case .body: 32
        case .label: 28
        case .caption: 24
        }
    }
}

extension View {
    func glassesText(_ role: GlassesText) -> some View {
        modifier(GlassesTextModifier(role: role))
    }
}

private struct GlassesTextModifier: ViewModifier {
    let role: GlassesText
    @Environment(\.legibilityWeight) private var legibilityWeight

    @ViewBuilder
    func body(content: Content) -> some View {
        let bold = legibilityWeight == .bold
        switch role {
        case .display, .title, .headline:
            let cut: Manrope = role == .headline ? .semiBold : .bold
            content
                .font(.custom((bold ? cut.bolder : cut).rawValue, fixedSize: role.size))
                .tracking(-0.01 * role.size)
        case .body, .label, .caption:
            content.font(.system(size: role.size, weight: bold ? .semibold : (role == .label ? .medium : .regular)))
        }
    }
}
