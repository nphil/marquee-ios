import SwiftUI

enum AppTab: Hashable {
    case home, library, watchlist, settings, search
}

/// Five tabs, each with its own navigation stack (DESIGN §7), drawn in the active theme.
struct RootView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @State private var selection: AppTab = .home

    var body: some View {
        let theme = store.theme(for: colorScheme)
            .adjusted(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency)
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                NavigationStack { LibraryView() }
            }
            Tab("Watchlist", systemImage: "bookmark", value: AppTab.watchlist) {
                NavigationStack { WatchlistView() }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack { SettingsView() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // The bar tucks away while scrolling the browse tabs and stays put elsewhere.
        .tabBarMinimizeBehavior(selection == .home || selection == .library ? .onScrollDown : .never)
        .environment(\.theme, theme)
        .tint(theme.accentText)
        // Matching the system leaves the scheme to the iPhone; a fixed theme forces its own.
        .preferredColorScheme(store.matchSystem ? nil : theme.mode.colorScheme)
        .onChange(of: BarInputs(theme: theme, typeSize: typeSize, boldText: legibilityWeight == .bold), initial: true) { _, inputs in
            NavigationBarStyle.apply(inputs.theme, typeSize: inputs.typeSize, boldText: inputs.boldText)
        }
    }

    /// Everything the navigation bar titles depend on.
    private struct BarInputs: Equatable {
        let theme: Theme
        let typeSize: DynamicTypeSize
        let boldText: Bool
    }
}
