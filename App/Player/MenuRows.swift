import SwiftUI
import UIKit

/// The metrics of a native iOS menu, shared by the More popover and the Enhance Picture panel: rows of at least
/// 44 pt with 12 pt above and below their text, 16 pt from the sides, and the text styles of a system menu.
/// Colours come from the theme only.
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
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chevron.backward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(theme.ink)
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
            Divider().overlay(theme.edge)
        }
    }
}

/// Gives the popover this view is in the theme's surface colour for its arrow as well. `presentationBackground`
/// paints the rectangle only; the arrow takes the presentation controller's `backgroundColor`.
struct PopoverArrowTint: UIViewRepresentable {
    let color: Color
    @Environment(\.self) private var environment

    func makeUIView(context: Context) -> TintView { TintView() }

    func updateUIView(_ view: TintView, context: Context) {
        view.color = UIColor(cgColor: color.resolve(in: environment).cgColor)
        view.apply()
    }

    final class TintView: UIView {
        var color = UIColor.clear

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    var chain: UIViewController? = controller
                    while let link = chain {
                        if let popover = link.presentationController as? UIPopoverPresentationController {
                            popover.backgroundColor = color
                            return
                        }
                        chain = link.parent
                    }
                    return
                }
                responder = current.next
            }
        }
    }
}
