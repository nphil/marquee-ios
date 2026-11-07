import MarqueeCore
import SwiftUI

enum AppTab: Hashable {
    case home, library, watchlist, settings, search
}

/// Sign-in until a server is chosen, then five tabs (DESIGN §7), all drawn in the active theme.
struct RootView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        @Bindable var session = session
        let theme = store.theme(for: colorScheme)
            .adjusted(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency)
        // Matching the system leaves the scheme to the iPhone; a fixed theme forces its own. The
        // modifier applies to the nearest presentation, so each sheet sets it as well.
        let scheme = store.matchSystem ? nil : theme.mode.colorScheme
        Group {
            switch session.state {
            case .ready:
                MainTabs()
            case .choosingServer:
                NavigationStack { ServerListView(isRoot: true) }
            case .signedOut, .signingIn, .failed:
                SignInView()
            }
        }
        .sheet(item: $session.playbackNotice) { item in
            PlaybackNoticeView(item: item)
                .preferredColorScheme(scheme)
        }
        .sheet(isPresented: $session.showsProfileSwitcher) {
            ProfileSwitcher()
                .preferredColorScheme(scheme)
        }
        .environment(\.theme, theme)
        // Here rather than on the tabs, so the sheets above resolve artwork too.
        .environment(\.plexLibrary, session.library)
        .tint(theme.accentText)
        .preferredColorScheme(scheme)
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

/// The five tabs, each with its own navigation stack.
private struct MainTabs: View {
    @State private var selection: AppTab = .home

    var body: some View {
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
    }
}
