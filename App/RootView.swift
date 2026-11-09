import MarqueeCore
import SwiftUI

enum AppTab: Hashable {
    case home, library, liveTV, watchlist, search
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
        @Bindable var remote = session.remote
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
        .fullScreenCover(isPresented: $remote.isPresented) {
            TVRemoteScreen()
                .preferredColorScheme(scheme)
        }
        // The TV's pairing QR code carries a lumaremote:// link. The remote opens from here, so Settings,
        // a sheet over the same view, closes first.
        .onOpenURL { url in
            guard url.scheme == "lumaremote" else { return }
            session.showsSettings = false
            session.remote.open(url)
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
        .environment(\.posterLabels, session.settings.posterLabels)
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

/// The five tabs, each with its own navigation stack; Settings opens from Home's profile button. The
/// browse tabs share the toasts, the record of watch-state changes, the profile's watchlist and the way
/// into playback.
private struct MainTabs: View {
    @Environment(AppSession.self) private var session
    @Environment(ThemeStore.self) private var store
    @State private var selection: AppTab = .home
    @State private var toasts = ToastCenter()
    @State private var changes = LibraryChanges()

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                BrowseStack { HomeView() }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                BrowseStack { LibraryView() }
            }
            Tab("Live TV", systemImage: "play.tv", value: AppTab.liveTV) {
                BrowseStack { LiveTVView() }
            }
            Tab("Watchlist", systemImage: "bookmark", value: AppTab.watchlist) {
                BrowseStack { WatchlistView() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                BrowseStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Minimise on Scroll shrinks the bar while a page scrolls down; Hide on Scroll is each browse stack's
        // own (BrowseStack). Search keeps the bar still while its results scroll and the keyboard comes and goes.
        .tabBarMinimizeBehavior(store.tabBar == .minimise && selection != .search ? .onScrollDown : .never)
        .environment(toasts)
        .environment(changes)
        .onChange(of: session.server?.id) { changes.forgetDeletions() }
        .environment(\.plexWatchlist, session.plexTV.map { PlexWatchlist(http: $0.http) })
        .environment(\.sessionActions, SessionActions(
            startPlayback: { item, index, fromStart in session.play(item: item, mediaIndex: index, fromStart: fromStart) },
            signInAgain: { session.signOut() },
            canDeleteMedia: session.canDeleteMedia
        ))
    }
}
