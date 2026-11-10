import MarqueeCore
import LumaRemoteCore
import SwiftUI

private struct PresenceInputs: Equatable {
    let enabled: Bool
    let foreground: Bool
    let tv: PairedTV?
    let network: Int
    let networkReady: Bool
}

/// Sign-in until a server is chosen, then the tabs the person chose (DESIGN §7), all drawn in the active theme.
struct RootView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var sheetNamespace

    var body: some View {
        @Bindable var session = session
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
        .fullScreenCover(item: playerCover(overSettings: false), onDismiss: { session.player.dismissed() }) { model in
            PlayerView(model: model, outerTheme: theme, outerScheme: scheme ?? colorScheme)
        }
        .sheet(isPresented: $remote.isPresented) {
            TVRemoteScreen()
                .preferredColorScheme(scheme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .sheetZoom(from: .remote, in: sheetNamespace, enabled: remote.zoomsFromButton && !reduceMotion)
        }
        // The TV's pairing QR code carries a lumaremote:// link. The remote opens from here, so Settings,
        // a sheet over the same view, closes first.
        .onOpenURL { url in
            guard url.scheme == "lumaremote" else { return }
            session.showsSettings = false
            session.remote.open(url)
        }
        .sheet(isPresented: $session.showsSettings, onDismiss: {
            if remote.opensAfterSettings {
                remote.opensAfterSettings = false
                remote.present()
            }
        }) {
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
            .fullScreenCover(item: playerCover(overSettings: true), onDismiss: { session.player.dismissed() }) { model in
                PlayerView(model: model, outerTheme: theme, outerScheme: scheme ?? colorScheme)
            }
            .sheetZoom(from: .settings, in: sheetNamespace, enabled: !reduceMotion)
        }
        .environment(\.sheetZoomNamespace, sheetNamespace)
        .environment(\.theme, theme)
        // Here rather than on the tabs, so the sheets above resolve artwork too.
        .environment(\.plexLibrary, session.library)
        .environment(\.posterLabels, session.settings.posterLabels)
        // Show Scroll Bars (DESIGN §8.7) reaches the sheets from here too; the A–Z rail is its own control.
        .scrollIndicators(store.showsScrollBars ? .automatic : .hidden)
        .tint(theme.accentText)
        .preferredColorScheme(scheme)
        .task(id: PresenceInputs(enabled: remote.isEnabled, foreground: scenePhase == .active,
                                 tv: remote.model.current, network: session.presenceNetworkRevision,
                                 networkReady: session.presencePath != nil)) {
            await session.trackPresence(enabled: remote.isEnabled, foreground: scenePhase == .active, tv: remote.model.current)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: remote.setForeground(true)
            case .background: remote.setForeground(false)
            default: break
            }
        }
        .onChange(of: BarInputs(theme: theme, typeSize: typeSize, boldText: legibilityWeight == .bold), initial: true) { _, inputs in
            NavigationBarStyle.apply(inputs.theme, typeSize: inputs.typeSize, boldText: inputs.boldText)
        }
    }

    /// The player's cover hangs from the root and again inside Settings, and the player goes to whichever
    /// is on top. A cover on the root alone takes the Settings sheet down to show itself, so a download
    /// played from Settings would close onto Home instead of back onto the downloads.
    private func playerCover(overSettings: Bool) -> Binding<PlayerModel?> {
        let session = session
        return Binding(
            get: { session.showsSettings == overSettings ? session.player.presented : nil },
            set: { session.player.presented = $0 }
        )
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

/// The tabs the person chose (DESIGN §7), each with its own navigation stack; the first opens at launch.
/// Settings opens from Home's profile button. The browse tabs share the toasts, the record of watch-state
/// changes, the profile's watchlist and the way into playback.
private struct MainTabs: View {
    @Environment(AppSession.self) private var session
    @Environment(ThemeStore.self) private var store
    /// Nil until a tab is picked; a picked tab that leaves the bar gives way to the first.
    @State private var picked: Destination?
    @State private var toasts = ToastCenter()
    @State private var changes = LibraryChanges()

    var body: some View {
        let tabs = store.tabLayout.tabs(available: Destination.available(in: session))
        let selection = picked.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first ?? .home
        TabView(selection: Binding(get: { selection }, set: { picked = $0 })) {
            ForEach(tabs) { destination in
                Tab(destination.title, systemImage: destination.systemImage, value: destination, role: destination == .search ? .search : nil) {
                    BrowseStack { destination.page() }
                }
                .badge(destination.badge(in: session))
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewBottomAccessory(isEnabled: session.remote.isEnabled && session.remote.access == .miniBar && session.place == .home) {
            TVRemoteMiniBar()
        }
        // Minimise on Scroll shrinks the bar while a page scrolls down; Hide on Scroll is each browse stack's
        // own (BrowseStack). Search keeps the bar still while its results scroll and the keyboard comes and goes.
        .tabBarMinimizeBehavior(store.tabBar == .minimise && selection != .search ? .onScrollDown : .never)
        .environment(\.tabSelection, TabSelection(tabs: tabs, select: { picked = $0 }))
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
