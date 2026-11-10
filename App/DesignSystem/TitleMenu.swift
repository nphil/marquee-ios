import SwiftUI

extension View {
    /// A leading title that opens a menu. The menu is an explicit button in the bar's title slot, set in
    /// the display face with a chevron, because `toolbarTitleMenu` showed no chevron and opened nothing in
    /// the inline-large bar.
    func titleMenu<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        modifier(TitleMenuModifier(title: title, items: items()))
    }
}

private struct TitleMenuModifier<Items: View>: ViewModifier {
    let title: String
    let items: Items
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .title) {
                Menu {
                    items
                } label: {
                    HStack(spacing: Space.s2) {
                        Text(title).textRole(.display)
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(theme.ink)
                }
                .menuIndicator(.hidden)
                .accessibilityLabel(title)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}
