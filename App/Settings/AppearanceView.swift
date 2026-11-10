import MarqueeCore
import SwiftUI

/// Settings › Appearance (DESIGN §8.7): one row for each thing that changes how Marquee looks, each on its
/// own page except the scroll bars switch. Saved with the theme, not per profile.
struct AppearanceView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                row("Theme", value: theme.name, id: "appearance.theme") { ThemeView() }
                row(
                    "Tab Bar",
                    value: "\(store.tabLayout.tabs(available: Destination.available(in: session)).count) Tabs",
                    id: "appearance.tabBar"
                ) { TabBarView() }
                row("Header Style", value: store.headerStyle.name, id: "appearance.headerStyle") { HeaderStyleView() }
            }
            .listRowBackground(theme.sheet)

            Section {
                Toggle("Show Scroll Bars", isOn: Binding(
                    get: { store.showsScrollBars },
                    set: { store.setShowsScrollBars($0) }
                ))
                .tint(theme.accent)
                .accessibilityIdentifier("appearance.scrollBars")
            } footer: {
                Text("The Library's A–Z rail shows either way.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row<Page: View>(_ title: String, value: String, id: String, @ViewBuilder page: @escaping () -> Page) -> some View {
        NavigationLink {
            page()
        } label: {
            LabeledContent {
                Text(value).foregroundStyle(theme.ink2)
            } label: {
                Text(title)
            }
        }
        .accessibilityIdentifier(id)
    }
}
