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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var session = session
        @Bindable var player = session.player
        let theme = store.theme(for: colorScheme)
            .adjusted(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency)
        let scheme = store.presentationScheme(for: theme)
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
        // Sign-in, the server list and the tabs fade into each other rather than cut (DESIGN §9 layer;
        // Reduce Motion keeps a short fade).
        .animation(reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.22), value: stage)
        .fullScreenCover(item: $player.presented, onDismiss: { session.player.dismissed() }) { model in
            PlayerView(model: model, outerTheme: theme, outerScheme: scheme ?? colorScheme)
        }
        .sheet(isPresented: $session.showsSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { session.showsSettings = false }
                                .accessibilityIdentifier("settings.done")
                        }
                    }
            }
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

    /// Which of the three screens the state shows, so a change within one, such as a refreshed server
    /// list, does not fade.
    private var stage: Int {
        switch session.state {
        case .signedOut, .signingIn, .failed: 0
        case .choosingServer: 1
        case .ready: 2
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
