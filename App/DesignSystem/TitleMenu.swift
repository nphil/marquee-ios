import SwiftUI

extension View {
    /// A leading title that opens a menu: an explicit button at the bar's leading edge, set in the display
    /// face with a chevron, because `toolbarTitleMenu` showed no chevron and opened nothing in the
    /// inline-large bar. The system's own title is removed (`toolbar(removing: .title)`), otherwise the bar
    /// draws it again under the button; `navigationTitle` stays for back buttons. The button cannot sit in
    /// the `.title` slot: removing the title removes that slot's item too, and the page showed no title.
    ///
    /// Once the page has scrolled the button drops to the headline size, as the system's inline titles do.
    /// `ToolbarItemPlacement.largeTitle` is documented for the bar's out-of-line title, which `inlineLarge`
    /// has none of, so the scroll offset tells the two states apart.
    func titleMenu<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        modifier(TitleMenuModifier(title: title, items: items()))
    }
}

private struct TitleMenuModifier<Items: View>: ViewModifier {
    let title: String
    let items: Items
    @Environment(\.theme) private var theme
    @State private var scrolled = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > Self.collapseOffset
            } action: { _, isScrolled in
                scrolled = isScrolled
            }
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        items
                    } label: {
                        HStack(spacing: Space.s2) {
                            // Truncates before it reaches the trailing buttons; the chevron never shrinks.
                            Text(title)
                                .textRole(scrolled ? .headline : .display)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.down")
                                .font(.footnote.weight(.semibold))
                                .fixedSize()
                        }
                        .foregroundStyle(theme.ink)
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("title.menu")
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }

    /// Points of scroll after which the title counts as collapsed.
    private static var collapseOffset: CGFloat { 8 }
}
