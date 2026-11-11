import SwiftUI

extension View {
    /// A leading title that opens a menu: an explicit button at the bar's leading edge, set in the display
    /// face with a chevron, because `toolbarTitleMenu` showed no chevron and opened nothing in the
    /// inline-large bar. The bar is inline and its principal slot holds an empty view, which is what hides
    /// the system's own title: `toolbar(removing: .title)` left the inline-large title standing beside the
    /// button (0.1.33) and removed a menu placed in the `.title` slot (0.1.31). `navigationTitle` stays for
    /// back buttons and the UI tests' bar queries. Callers set no title display mode of their own on this
    /// path, so nothing overrides the inline one.
    ///
    /// Once the page has scrolled the button drops to the headline size, as the system's inline titles do.
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
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
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
