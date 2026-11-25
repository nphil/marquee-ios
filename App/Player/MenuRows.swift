import SwiftUI

/// The metrics of a native iOS menu, shared by the More popover and the Enhance Picture panel: rows of at least
/// 44 pt with 12 pt above and below their text, 16 pt from the sides, and the text styles of a system menu.
/// Colours are the system's.
enum MenuMetrics {
    static let rowHeight: CGFloat = 44
    static let margin: CGFloat = 16
    static let vertical: CGFloat = 12
    /// Space kept above the first row and under the last when a page scrolls.
    static let edge: CGFloat = 8
    /// The icon column of a row at the default text size; it scales with Dynamic Type.
    static let glyph: CGFloat = 24
}

/// The head of a menu page: a back chevron and the page's title, as a compact navigation row.
struct MenuHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chevron.backward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, MenuMetrics.margin)
                .padding(.vertical, MenuMetrics.vertical)
                .frame(minHeight: MenuMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("Back")
            Divider()
        }
    }
}
