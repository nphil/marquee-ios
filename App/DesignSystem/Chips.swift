import SwiftUI

/// A solid chip (DESIGN §5.2, §12): canvas fill with an ink2 outline, never glass, so it reads the same
/// over a faded hero or a plain canvas. Its words carry the meaning, never its colour.
struct Chip: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(title)
            .textRole(.label)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s1)
            .background(theme.canvas, in: Capsule())
            .overlay { Capsule().strokeBorder(theme.ink2, lineWidth: 1) }
    }
}

/// A chip for a filter that is on, with `xmark` to turn it off; the whole 48 pt height takes the tap
/// (DESIGN §8.2).
struct FilterChip: View {
    let title: String
    let remove: @MainActor () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: remove) {
            HStack(spacing: Space.s2) {
                Text(title)
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .textRole(.label)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .background(theme.canvas, in: Capsule())
            .overlay { Capsule().strokeBorder(theme.ink2, lineWidth: 1) }
            .frame(minHeight: Size.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Removes this filter")
    }
}

extension View {
    /// Tells the system a menu label is a capsule, so the highlight it draws while the menu opens follows
    /// the capsule rather than flashing a square slab.
    func capsuleMenuLabel() -> some View {
        contentShape(.contextMenuPreview, Capsule())
    }
}

/// The label of a pill-shaped menu such as "Season 2" (DESIGN §8.4): a solid chip with a menu chevron and
/// the full 48 pt height for the tap.
struct MenuPill: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.s2) {
            Text(title)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
        }
        .textRole(.headline)
        .foregroundStyle(theme.ink)
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .background(theme.canvas, in: Capsule())
        .overlay { Capsule().strokeBorder(theme.ink2, lineWidth: 1) }
        .frame(minHeight: Size.target)
        .contentShape(Rectangle())
    }
}

/// Chips in rows that wrap, so a long set never clips at large text sizes.
struct ChipFlow: Layout {
    var spacing: CGFloat = Space.s2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> (frames: [CGRect], size: CGSize) {
        let limit = width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > limit {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
}
