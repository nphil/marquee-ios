import SwiftUI

/// A 3:4 preview of a theme drawn from its own roles (DESIGN §8.7): canvas, two ink lines and a
/// sheet panel holding an accent pill and three 2:3 posters. Shapes only, so a grid of them
/// scrolls smoothly.
struct ThemePreview: View {
    let theme: Theme
    var cornerRadius: CGFloat = Radius.tile

    @Environment(\.theme) private var active

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    drawing(width: proxy.size.width)
                }
            }
            .background(theme.canvas, in: shape)
            .clipShape(shape)
            // Decoration only: it keeps a light preview's boundary visible on a light page.
            .overlay { shape.strokeBorder(active.trackOff, lineWidth: 1) }
            .accessibilityHidden(true)
    }

    /// Proportions of the tile width, so the same drawing works from a 42 pt row thumbnail up.
    private func drawing(width w: CGFloat) -> some View {
        let margin = w * 0.1
        let gap = w * 0.06
        let poster = CGSize(width: w * 0.2, height: w * 0.3)
        return VStack(alignment: .leading, spacing: gap) {
            Capsule().fill(theme.ink).frame(width: w * 0.5, height: w * 0.05)
            Capsule().fill(theme.ink2).frame(width: w * 0.32, height: w * 0.04)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: gap) {
                Capsule().fill(theme.accent).frame(width: w * 0.3, height: w * 0.08)
                HStack(spacing: w * 0.04) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: w * 0.03, style: .continuous)
                            .fill(theme.trackOff)
                            .frame(width: poster.width, height: poster.height)
                    }
                }
            }
            .padding(gap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.sheet,
                in: RoundedRectangle(cornerRadius: Radius.inner(cornerRadius, inset: margin), style: .continuous)
            )
        }
        .padding(margin)
    }
}

/// A selectable theme in the picker grid: the preview, its name underneath, and when chosen a ring
/// in the focus colour plus a check mark, so the choice never rests on colour alone.
struct ThemeTile: View {
    let theme: Theme
    let isSelected: Bool
    let select: @MainActor () -> Void

    @Environment(\.theme) private var active
    @ScaledMetric(relativeTo: .caption) private var badge: CGFloat = 24

    /// The ring sits this far outside the preview; every tile is inset by it so selected and
    /// unselected tiles stay the same size.
    private let ringOutset: CGFloat = 4

    var body: some View {
        Button(action: select) {
            VStack(spacing: Space.s2) {
                ThemePreview(theme: theme)
                    .padding(ringOutset)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Radius.tile + ringOutset, style: .continuous)
                                .strokeBorder(active.focus, lineWidth: 3)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(active.focusInk)
                                .frame(width: badge, height: badge)
                                .background(active.focus, in: Circle())
                                .offset(x: -Space.s2, y: Space.s2)
                                .accessibilityHidden(true)
                        }
                    }
                Text(theme.name)
                    .textRole(.caption)
                    .foregroundStyle(isSelected ? active.ink : active.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("theme.\(theme.id)")
    }
}
